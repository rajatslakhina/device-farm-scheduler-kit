import Foundation
@testable import DeviceFarmScheduler

/// The store this kit argues against, implemented properly so the argument can
/// be measured rather than asserted.
///
/// Two differences from `SnapshotStore`, and both are the choices a reasonable
/// engineer makes on the first pass:
///
/// 1. `touch` stamps only the layer the run actually mounted — the `.account`
///    leaf — because that is the layer the hypervisor opened. Nothing else
///    "was used", so nothing else gets a timestamp.
/// 2. Eviction is global LRU over every resident layer, because that is what
///    LRU means.
///
/// Together they guarantee the base image is always the oldest thing in the
/// store and therefore always the first thing evicted.
struct NaiveLRUStore {
    let capacityBytes: Int
    private(set) var residents: [LayerID: SnapshotStore.Resident] = [:]

    init(capacityBytes: Int) {
        self.capacityBytes = capacityBytes
    }

    var residentIDs: Set<LayerID> { Set(residents.keys) }

    var residentBytes: Int {
        residents.values.reduce(0) { $0 + $1.descriptor.bytes }
    }

    func contains(_ id: LayerID) -> Bool { residents[id] != nil }

    /// Same contiguity rule as the real store, so the comparison is about
    /// eviction policy and nothing else.
    func deepestResidentLayer(for key: SnapshotKey) -> SnapshotLayer? {
        var deepest: SnapshotLayer?
        for layer in SnapshotLayer.allCases {
            guard residents[key.layerID(layer)] != nil else { break }
            deepest = layer
        }
        return deepest
    }

    @discardableResult
    mutating func admit(_ key: SnapshotKey, catalog: SnapshotCatalog, at tick: Int) -> [LayerID] {
        guard let chain = catalog.chain(for: key) else { return [] }
        var evicted: [LayerID] = []

        let missing = chain.filter { residents[$0.id] == nil }
        let needed = missing.reduce(0) { $0 + $1.bytes }
        let protectedIDs = Set(chain.map(\.id))

        // Global LRU: oldest stamp loses, children or no children.
        var guardCounter = 0
        while capacityBytes - residentBytes < needed && guardCounter < 512 {
            guardCounter += 1
            let victim = residents
                .filter { !protectedIDs.contains($0.key) }
                .min { lhs, rhs in
                    lhs.value.lastUsedTick != rhs.value.lastUsedTick
                        ? lhs.value.lastUsedTick < rhs.value.lastUsedTick
                        : lhs.key.path < rhs.key.path
                }
            guard let victim else { break }
            residents.removeValue(forKey: victim.key)
            evicted.append(victim.key)
        }

        for descriptor in chain where residents[descriptor.id] == nil {
            residents[descriptor.id] = SnapshotStore.Resident(
                descriptor: descriptor,
                lastUsedTick: tick
            )
        }
        touchLeafOnly(key, at: tick)
        return evicted
    }

    /// Stamps only the mounted leaf — the bug, stated plainly.
    mutating func touchLeafOnly(_ key: SnapshotKey, at tick: Int) {
        let leaf = key.layerID(.account)
        residents[leaf]?.lastUsedTick = tick
    }
}
