import XCTest
@testable import DeviceFarmScheduler

final class SnapshotStoreTests: XCTestCase {

    private let catalog = ReferenceWorkload.makeCatalog()

    // MARK: - Basic behaviour

    func testAdmitMakesWholeChainResidentAndReportsWarmDepth() {
        var store = SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
        XCTAssertNil(store.deepestResidentLayer(for: ReferenceWorkload.checkoutBasket))

        let result = store.admit(ReferenceWorkload.checkoutBasket, catalog: catalog, at: 0)
        XCTAssertTrue(result.admitted)
        XCTAssertEqual(result.restored.count, 3)
        XCTAssertEqual(store.deepestResidentLayer(for: ReferenceWorkload.checkoutBasket), .account)
        XCTAssertEqual(
            store.restoreCostMillis(for: ReferenceWorkload.checkoutBasket, catalog: catalog),
            0
        )
    }

    func testSiblingKeyReusesSharedParentsAndOnlyPaysForTheLeaf() {
        var store = SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
        store.admit(ReferenceWorkload.checkoutBasket, catalog: catalog, at: 0)

        // `checkoutGuest` shares the os and app layers, so only the account
        // layer should need restoring.
        let cost = store.restoreCostMillis(for: ReferenceWorkload.checkoutGuest, catalog: catalog)
        XCTAssertEqual(cost, ReferenceWorkload.accountLayerRebuildMillis)
        XCTAssertEqual(store.deepestResidentLayer(for: ReferenceWorkload.checkoutGuest), .app)

        let result = store.admit(ReferenceWorkload.checkoutGuest, catalog: catalog, at: 1)
        XCTAssertTrue(result.admitted)
        XCTAssertEqual(result.restored, [ReferenceWorkload.checkoutGuest.layerID(.account)])
    }

    func testTouchStampsTheWholeChainNotJustTheLeaf() {
        var store = SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
        store.admit(ReferenceWorkload.checkoutBasket, catalog: catalog, at: 0)
        store.touch(ReferenceWorkload.checkoutBasket, at: 50)

        for layer in SnapshotLayer.allCases {
            let id = ReferenceWorkload.checkoutBasket.layerID(layer)
            XCTAssertEqual(store.lastUsedTick(of: id), 50, "layer \(layer) kept a stale stamp")
        }
    }

    func testChainLargerThanCapacityIsRefusedWithoutMutating() {
        // Capacity smaller than the 6 GiB base image.
        var store = SnapshotStore(capacityBytes: 1024)
        let result = store.admit(ReferenceWorkload.checkoutBasket, catalog: catalog, at: 0)
        XCTAssertFalse(result.admitted)
        XCTAssertEqual(store.residentCount, 0, "a refused admission must not evict or restore")
    }

    func testUnknownChainIsRefused() {
        var store = SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
        let stranger = SnapshotKey(osBuild: "nope", appBuild: "nope", accountSeed: "nope")
        let result = store.admit(stranger, catalog: catalog, at: 0)
        XCTAssertFalse(result.admitted)
        XCTAssertEqual(store.residentCount, 0)
    }

    func testEmptyStoreIsSafeToQuery() {
        let store = SnapshotStore(capacityBytes: 0)
        XCTAssertNil(store.deepestResidentLayer(for: ReferenceWorkload.paymentsCard))
        XCTAssertNil(store.evictionCandidate(at: 0))
        XCTAssertEqual(store.residentBytes, 0)
        XCTAssertEqual(store.freeBytes, 0)
        XCTAssertTrue(SnapshotStoreAudit.violations(of: store).isEmpty)
    }

    // MARK: - The orphan invariant

    func testEvictionNeverOrphansAChild() {
        var store = SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
        store.admit(ReferenceWorkload.checkoutBasket, catalog: catalog, at: 0)
        store.admit(ReferenceWorkload.checkoutGuest, catalog: catalog, at: 1)

        // Force pressure by asking for a chain on the *other* OS build, which
        // cannot fit alongside the first.
        store.admit(ReferenceWorkload.paymentsCard, catalog: catalog, at: 2)

        XCTAssertTrue(
            SnapshotStoreAudit.violations(of: store).isEmpty,
            "store left an orphaned layer: \(SnapshotStoreAudit.violations(of: store))"
        )
        XCTAssertLessThanOrEqual(store.residentBytes, store.capacityBytes)
    }

    func testEvictionCandidateIsAlwaysALeaf() {
        var store = SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
        store.admit(ReferenceWorkload.checkoutBasket, catalog: catalog, at: 0)
        store.admit(ReferenceWorkload.checkoutGuest, catalog: catalog, at: 1)

        guard let candidate = store.evictionCandidate(at: 100) else {
            return XCTFail("expected a candidate with three resident chains")
        }
        XCTAssertEqual(
            store.residentChildCount(of: candidate), 0,
            "\(candidate) has resident children and must not be evictable"
        )
        XCTAssertEqual(candidate.layer, .account, "only the leaves should be eligible")
    }

    func testEvictionIsIterativeAndCanPromoteAParentToALeaf() {
        // Small synthetic sizes so the arithmetic is readable: one chain of
        // 600 + 90 + 20 exactly fills a 710-byte store.
        let key = SnapshotKey(osBuild: "os", appBuild: "app", accountSeed: "acct")
        var tiny = SnapshotCatalog()
        tiny.register(LayerDescriptor(id: key.layerID(.os), bytes: 600, rebuildMillis: 6_000))
        tiny.register(LayerDescriptor(id: key.layerID(.app), bytes: 90, rebuildMillis: 900))
        tiny.register(LayerDescriptor(id: key.layerID(.account), bytes: 20, rebuildMillis: 200))

        var store = SnapshotStore(capacityBytes: 710)
        store.admit(key, catalog: tiny, at: 0)
        XCTAssertEqual(store.freeBytes, 0)

        // 110 > the 20-byte leaf, so the 90-byte app layer has to go too — and
        // it is only eligible once its child has been removed.
        let freed = store.evict(toFree: 110, at: 100)
        XCTAssertEqual(freed.count, 2)
        XCTAssertEqual(freed.first?.layer, .account, "the leaf must be dropped before its parent")
        XCTAssertEqual(freed.last?.layer, .app)
        XCTAssertTrue(store.contains(key.layerID(.os)), "the shared base image should survive")
        XCTAssertTrue(SnapshotStoreAudit.violations(of: store).isEmpty)
    }

    // MARK: - The audit itself

    /// The checks are only evidence if they can fail. These feed the auditor a
    /// resident set no correct store would produce and assert it complains.
    func testAuditDetectsAnOrphanedLayer() {
        let key = ReferenceWorkload.checkoutBasket
        // Account layer resident, its app parent missing: exactly what a global
        // LRU eviction leaves behind.
        let broken: Set<LayerID> = [key.layerID(.os), key.layerID(.account)]
        let violations = SnapshotStoreAudit.violations(
            residentIDs: broken,
            residentBytes: 100,
            capacityBytes: 1000
        )
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(
            violations.first,
            .orphanedLayer(key.layerID(.account), missingParent: key.layerID(.app))
        )
    }

    func testAuditDetectsOverCapacity() {
        let violations = SnapshotStoreAudit.violations(
            residentIDs: [],
            residentBytes: 4096,
            capacityBytes: 1024
        )
        XCTAssertEqual(violations, [.overCapacity(residentBytes: 4096, capacityBytes: 1024)])
    }

    func testAuditPassesAWellFormedSet() {
        let key = ReferenceWorkload.checkoutBasket
        let healthy = Set(key.chain)
        XCTAssertTrue(
            SnapshotStoreAudit.violations(
                residentIDs: healthy,
                residentBytes: 10,
                capacityBytes: 1000
            ).isEmpty
        )
    }

    // MARK: - Differential: naive LRU versus this store

    // MARK: - Differential: naive LRU versus this store

    /// A hot pair of keys, punctuated by cold one-offs that create pressure.
    ///
    /// The skew matters. A trace that cycles uniformly through every key gives
    /// no store anything worth keeping, and both policies come out identical —
    /// which is what the first version of this test measured, and why it was
    /// replaced. Real farm traffic is skewed: a couple of configurations run
    /// constantly and the rest show up occasionally, and a cache is only
    /// interesting against that shape.
    private static let differentialTrace: [SnapshotKey] = {
        func key(_ app: String, _ seed: String) -> SnapshotKey {
            SnapshotKey(osBuild: ReferenceWorkload.osMain, appBuild: app, accountSeed: seed)
        }
        let hotA = key("app-a", "seed-1")
        let hotB = key("app-a", "seed-2")
        let cycle = [
            hotA, hotB, hotA,
            key("app-b", "seed-3"),
            hotA, hotB,
            key("app-c", "seed-4"),
            hotA, hotB,
            key("app-d", "seed-5"),
            hotA, hotB,
        ]
        return cycle + cycle + cycle
    }()

    private static func differentialCatalog() -> SnapshotCatalog {
        var catalog = SnapshotCatalog()
        var seen = Set<LayerID>()
        for key in differentialTrace {
            for layer in SnapshotLayer.allCases {
                let id = key.layerID(layer)
                guard seen.insert(id).inserted else { continue }
                let bytes: Int
                let millis: Int
                switch layer {
                case .os: bytes = 6_000; millis = 180_000
                case .app: bytes = 900; millis = 25_000
                case .account: bytes = 200; millis = 6_000
                }
                catalog.register(LayerDescriptor(id: id, bytes: bytes, rebuildMillis: millis))
            }
        }
        return catalog
    }

    /// Base image plus two app layers plus one account layer.
    ///
    /// The number is chosen to put the store under real pressure. Give it enough
    /// room and both policies look fine, which is worth knowing: this is a
    /// pressure-regime result, not a universal one, and the README says so.
    private static let differentialCapacity = 8_000

    /// Bytes held that cannot boot anything, because an ancestor is missing.
    private static func unusableBytes(in residentIDs: Set<LayerID>) -> Int {
        SnapshotStoreAudit.violations(
            residentIDs: residentIDs,
            residentBytes: 0,
            capacityBytes: Int.max
        )
        .reduce(0) { total, violation in
            guard case let .orphanedLayer(id, _) = violation else { return total }
            switch id.layer {
            case .os: return total + 6_000
            case .app: return total + 900
            case .account: return total + 200
            }
        }
    }

    /// The headline claim, measured. Both stores replay the identical mount
    /// trace, so any difference is the eviction policy and nothing else.
    ///
    /// Checked after *every* step rather than only at the end: a later admission
    /// restores whatever was orphaned, so an end-state-only check can come back
    /// clean while the store spent most of the run holding unbootable layers.
    func testNaiveLRUOrphansALayerAndThisStoreNeverDoes() {
        let catalog = Self.differentialCatalog()
        var naive = NaiveLRUStore(capacityBytes: Self.differentialCapacity)
        var good = SnapshotStore(capacityBytes: Self.differentialCapacity)

        var naiveOrphanSteps = 0
        var naivePeakUnusableBytes = 0

        for (index, key) in Self.differentialTrace.enumerated() {
            naive.admit(key, catalog: catalog, at: index)
            good.admit(key, catalog: catalog, at: index)

            let wasted = Self.unusableBytes(in: naive.residentIDs)
            if wasted > 0 { naiveOrphanSteps += 1 }
            naivePeakUnusableBytes = max(naivePeakUnusableBytes, wasted)

            XCTAssertTrue(
                SnapshotStoreAudit.violations(of: good).isEmpty,
                "SnapshotStore orphaned a layer at step \(index): "
                    + "\(SnapshotStoreAudit.violations(of: good))"
            )
            XCTAssertLessThanOrEqual(good.residentBytes, good.capacityBytes)
        }

        XCTAssertGreaterThan(
            naiveOrphanSteps, 0,
            "global LRU was expected to orphan a layer on this trace but never did — "
                + "if that ever becomes true, this comparison proves nothing"
        )
        XCTAssertGreaterThan(
            naivePeakUnusableBytes, 0,
            "global LRU was expected to hold unbootable bytes"
        )
    }

    /// The economic consequence: restore time actually paid.
    func testChainAwareEvictionPaysLessRestoreTimeThanNaiveLRU() {
        let catalog = Self.differentialCatalog()
        var naive = NaiveLRUStore(capacityBytes: Self.differentialCapacity)
        var good = SnapshotStore(capacityBytes: Self.differentialCapacity)

        var naiveMillis = 0
        var goodMillis = 0

        for (index, key) in Self.differentialTrace.enumerated() {
            naiveMillis += Self.restoreCost(
                for: key, warmDepth: naive.deepestResidentLayer(for: key)
            )
            goodMillis += good.restoreCostMillis(for: key, catalog: catalog)
            naive.admit(key, catalog: catalog, at: index)
            good.admit(key, catalog: catalog, at: index)
        }

        XCTAssertLessThan(
            goodMillis, naiveMillis,
            "chain-aware eviction should pay less restore time "
                + "(\(goodMillis)ms vs \(naiveMillis)ms)"
        )
        // The base image is the expensive layer; keeping it is the whole point.
        XCTAssertTrue(
            good.contains(LayerID(layer: .os, path: ReferenceWorkload.osMain)),
            "chain-aware store dropped the shared base image"
        )
    }

    /// Same cost model the real store uses, applied to the naive store's answer.
    private static func restoreCost(for key: SnapshotKey, warmDepth: SnapshotLayer?) -> Int {
        let depth = warmDepth?.rawValue ?? -1
        var cost = 0
        for layer in SnapshotLayer.allCases where layer.rawValue > depth {
            switch layer {
            case .os: cost += 180_000
            case .app: cost += 25_000
            case .account: cost += 6_000
            }
        }
        return cost
    }
}
