/// One host's resident set of snapshot layers, with an eviction policy that
/// understands the copy-on-write chain.
///
/// ## Why not LRU
///
/// LRU is the reflex answer and it is wrong here, for a reason that only shows
/// up once layers are shared. A run mounts a `.account` layer; that is the thing
/// the hypervisor touches, so that is the thing a naive store stamps with a
/// timestamp. The `.os` base image underneath it is *never* directly mounted by
/// anything, so its last-used stamp stays frozen at the moment it was admitted.
/// Global LRU therefore evicts, in order: the layer with the longest idle time,
/// which is the base image — the single most expensive layer to rebuild and the
/// one every other resident layer is written on top of. One eviction orphans
/// every descendant and converts the whole host into a cold host.
///
/// `SnapshotStore` fixes both halves of that:
///
/// 1. **Only leaves are evictable.** A layer with a resident child is never a
///    candidate, so the resident set is always a valid forest and a descendant
///    can never be orphaned. Evicting a leaf can promote its parent to a leaf,
///    so the plan is computed iteratively rather than as a single sort.
/// 2. **Rank by retained value, not by age.** A candidate's score is its rebuild
///    cost scaled by recency and divided by the bytes it occupies — the store
///    gives up the layer that returns the least saved time per byte freed, which
///    is the quantity it actually wants to maximise.
///
/// Reads never mutate the chain's shape, so `touch` stamps the whole chain: the
/// base image *is* being used when its descendant is mounted, and recording that
/// truthfully is half the fix.
public struct SnapshotStore: Sendable, Equatable {

    /// A layer currently on disk.
    public struct Resident: Sendable, Equatable {
        public let descriptor: LayerDescriptor
        public var lastUsedTick: Int

        public init(descriptor: LayerDescriptor, lastUsedTick: Int) {
            self.descriptor = descriptor
            self.lastUsedTick = lastUsedTick
        }
    }

    /// Total bytes this host will hold before it has to evict.
    public let capacityBytes: Int

    /// How many ticks of idleness it takes for recency to stop protecting a
    /// layer. Clamped to at least 1 so the recency term can never be zero.
    public let recencyWindowTicks: Int

    private var residents: [LayerID: Resident]

    public init(capacityBytes: Int, recencyWindowTicks: Int = 64) {
        self.capacityBytes = max(0, capacityBytes)
        self.recencyWindowTicks = max(1, recencyWindowTicks)
        self.residents = [:]
    }

    // MARK: - Inspection

    public var residentIDs: Set<LayerID> { Set(residents.keys) }

    public var residentCount: Int { residents.count }

    public var residentBytes: Int {
        Saturating.sum(residents.values.map(\.descriptor.bytes))
    }

    public var freeBytes: Int {
        max(0, Saturating.subtract(capacityBytes, residentBytes))
    }

    public func contains(_ id: LayerID) -> Bool { residents[id] != nil }

    public func lastUsedTick(of id: LayerID) -> Int? { residents[id]?.lastUsedTick }

    /// Number of resident layers whose parent is `id`.
    public func residentChildCount(of id: LayerID) -> Int {
        residents.values.reduce(0) { count, resident in
            resident.descriptor.id.parentID == id ? count + 1 : count
        }
    }

    /// The deepest layer of `key` that is resident, counting only a *contiguous*
    /// prefix from the base image up.
    ///
    /// Contiguity is what makes this answer meaningful: a resident `.account`
    /// layer whose `.app` parent is missing is not bootable, so reporting it as
    /// warm would hand the scheduler a placement that then pays a full restore.
    /// The store's own invariant makes that state unreachable; this method does
    /// not rely on it.
    public func deepestResidentLayer(for key: SnapshotKey) -> SnapshotLayer? {
        var deepest: SnapshotLayer?
        for layer in SnapshotLayer.allCases {
            guard residents[key.layerID(layer)] != nil else { break }
            deepest = layer
        }
        return deepest
    }

    /// Milliseconds of restore work a run of `key` would pay on this host right
    /// now, given `catalog`. Zero means fully warm.
    public func restoreCostMillis(for key: SnapshotKey, catalog: SnapshotCatalog) -> Int {
        let warmDepth = deepestResidentLayer(for: key)?.rawValue ?? -1
        var cost = 0
        for layer in SnapshotLayer.allCases where layer.rawValue > warmDepth {
            let id = key.layerID(layer)
            cost = Saturating.add(cost, catalog.descriptor(for: id)?.rebuildMillis ?? 0)
        }
        return cost
    }

    // MARK: - Mutation

    /// Records that every link of `key`'s resident prefix was used at `tick`.
    ///
    /// Stamping the whole prefix rather than just the mounted leaf is the first
    /// half of the fix described in this type's documentation.
    public mutating func touch(_ key: SnapshotKey, at tick: Int) {
        for layer in SnapshotLayer.allCases {
            let id = key.layerID(layer)
            guard residents[id] != nil else { break }
            residents[id]?.lastUsedTick = tick
        }
    }

    /// Outcome of trying to make a chain resident.
    public struct AdmissionResult: Sendable, Equatable {
        /// Layers that had to be written, in restore order.
        public let restored: [LayerID]
        /// Layers given up to make room, in the order they were dropped.
        public let evicted: [LayerID]
        /// Whether the full chain is resident now.
        public let admitted: Bool
    }

    /// Makes `key`'s full chain resident, evicting leaves as needed.
    ///
    /// Returns `admitted: false` without mutating anything when the chain is
    /// unknown to `catalog` or is larger than the host's entire capacity —
    /// a host that cannot ever hold a chain should refuse the placement, not
    /// thrash its whole resident set discovering that.
    @discardableResult
    public mutating func admit(
        _ key: SnapshotKey,
        catalog: SnapshotCatalog,
        at tick: Int
    ) -> AdmissionResult {
        guard let chain = catalog.chain(for: key) else {
            return AdmissionResult(restored: [], evicted: [], admitted: false)
        }

        let chainBytes = Saturating.sum(chain.map(\.bytes))
        guard chainBytes <= capacityBytes else {
            return AdmissionResult(restored: [], evicted: [], admitted: false)
        }

        let missing = chain.filter { residents[$0.id] == nil }
        guard !missing.isEmpty else {
            touch(key, at: tick)
            return AdmissionResult(restored: [], evicted: [], admitted: true)
        }

        let neededBytes = Saturating.sum(missing.map(\.bytes))
        let protectedIDs = Set(chain.map(\.id))
        let evicted = evict(toFree: neededBytes, at: tick, protecting: protectedIDs)

        // Restore in chain order so a parent is always written before its child.
        var restored: [LayerID] = []
        restored.reserveCapacity(missing.count)
        for descriptor in chain where residents[descriptor.id] == nil {
            residents[descriptor.id] = Resident(descriptor: descriptor, lastUsedTick: tick)
            restored.append(descriptor.id)
        }

        touch(key, at: tick)
        return AdmissionResult(restored: restored, evicted: evicted, admitted: true)
    }

    /// Drops leaves until at least `bytes` are free, never orphaning a child and
    /// never touching anything in `protecting`.
    ///
    /// Iterative by necessity: evicting a leaf can promote its parent to a leaf,
    /// and the promoted parent is frequently the right next choice.
    @discardableResult
    public mutating func evict(
        toFree bytes: Int,
        at tick: Int,
        protecting protectedIDs: Set<LayerID> = []
    ) -> [LayerID] {
        guard bytes > 0 else { return [] }
        var dropped: [LayerID] = []

        // Bounded by the resident count: each pass removes exactly one layer, so
        // this cannot spin even if scoring ever returned a degenerate answer.
        let maxPasses = residents.count
        var pass = 0
        while freeBytes < bytes && pass < maxPasses {
            pass += 1
            guard let victim = evictionCandidate(at: tick, protecting: protectedIDs) else { break }
            residents.removeValue(forKey: victim)
            dropped.append(victim)
        }
        return dropped
    }

    /// The layer this store would give up next, or `nil` if nothing is eligible.
    public func evictionCandidate(
        at tick: Int,
        protecting protectedIDs: Set<LayerID> = []
    ) -> LayerID? {
        var best: (id: LayerID, score: Int)?
        for (id, resident) in residents {
            guard !protectedIDs.contains(id) else { continue }
            // The orphan invariant: a layer with a resident child is not a leaf
            // and is therefore never a candidate, whatever its score would be.
            guard residentChildCount(of: id) == 0 else { continue }

            let score = retentionScore(for: resident, at: tick)
            guard let current = best else {
                best = (id, score)
                continue
            }
            // Lowest retained value loses. Ties broken on the path so the choice
            // is deterministic across runs and platforms — dictionary iteration
            // order is not stable and a farm's decisions have to be replayable.
            if score < current.score || (score == current.score && id.path < current.id.path) {
                best = (id, score)
            }
        }
        return best?.id
    }

    /// Value this store keeps by *not* evicting `resident`: rebuild time saved
    /// per byte held, scaled by how recently it was used.
    ///
    /// Reported in milliseconds-saved per mebibyte so the numbers stay in a
    /// range a human can read in a dashboard.
    public func retentionScore(for resident: Resident, at tick: Int) -> Int {
        let age = max(0, Saturating.subtract(tick, resident.lastUsedTick))
        // Clamped to at least 1: a layer older than the window keeps a floor of
        // value from its rebuild cost rather than collapsing to zero, which
        // would make an expensive cold base image indistinguishable from a
        // cheap one.
        let recency = max(1, Saturating.subtract(recencyWindowTicks, age))
        let value = Saturating.multiply(resident.descriptor.rebuildMillis, recency)
        let mebibytes = max(1, Saturating.divide(resident.descriptor.bytes, by: 1 << 20))
        return Saturating.divide(value, by: mebibytes)
    }
}

// MARK: - Invariant checking

/// Standalone verification of the properties `SnapshotStore` claims.
///
/// Deliberately not a method on the store: the point is to be able to check a
/// resident set that some *other* implementation produced. The tests use it
/// exactly that way — they build a store state the way a naive LRU policy would
/// leave it and assert that these checks fail on it, which is the only way to
/// know the checks are doing work.
public enum SnapshotStoreAudit {

    public enum Violation: Sendable, Equatable, CustomStringConvertible {
        /// A resident layer whose parent is missing: unbootable, and silently so.
        case orphanedLayer(LayerID, missingParent: LayerID)
        /// More bytes resident than the host can hold.
        case overCapacity(residentBytes: Int, capacityBytes: Int)

        public var description: String {
            switch self {
            case let .orphanedLayer(id, parent):
                return "orphaned layer \(id): parent \(parent) is not resident"
            case let .overCapacity(resident, capacity):
                return "over capacity: \(resident) bytes resident, \(capacity) allowed"
            }
        }
    }

    /// Every violation present in `residentIDs`, given a capacity and sizes.
    public static func violations(
        residentIDs: Set<LayerID>,
        residentBytes: Int,
        capacityBytes: Int
    ) -> [Violation] {
        var found: [Violation] = []

        // Sorted for a deterministic report; a flaky diagnostic is worse than none.
        for id in residentIDs.sorted(by: { $0.description < $1.description }) {
            guard let parent = id.parentID else { continue }
            if !residentIDs.contains(parent) {
                found.append(.orphanedLayer(id, missingParent: parent))
            }
        }

        if residentBytes > capacityBytes {
            found.append(.overCapacity(residentBytes: residentBytes, capacityBytes: capacityBytes))
        }
        return found
    }

    /// Convenience overload for auditing a real store.
    public static func violations(of store: SnapshotStore) -> [Violation] {
        violations(
            residentIDs: store.residentIDs,
            residentBytes: store.residentBytes,
            capacityBytes: store.capacityBytes
        )
    }
}
