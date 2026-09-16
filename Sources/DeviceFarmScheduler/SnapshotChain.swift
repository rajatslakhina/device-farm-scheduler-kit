/// The copy-on-write layer stack a virtualized-iPhone run boots from.
///
/// A run is only cheap when its snapshot is already resident on the host it
/// lands on. "Its snapshot" is not one blob — it is a three-link chain, where
/// each link is written on top of the one below it:
///
/// ```
/// .os       restored iOS firmware for one build            (expensive, shared by everyone)
/// .app      that image with one app build installed        (moderate, shared by one repo)
/// .account  that image with one seeded account state       (cheap, shared by one test matrix)
/// ```
///
/// The ordering is load-bearing. A `.account` layer's blocks are deltas against
/// its `.app` parent, which are deltas against `.os`. Dropping a parent while a
/// child is resident does not free the child — it *corrupts* it. Every policy in
/// this module is written against that constraint rather than around it.
public enum SnapshotLayer: Int, Sendable, Hashable, CaseIterable, Comparable, CustomStringConvertible {
    case os = 0
    case app = 1
    case account = 2

    public static func < (lhs: SnapshotLayer, rhs: SnapshotLayer) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .os: return "os"
        case .app: return "app"
        case .account: return "account"
        }
    }

    /// The layer this one is written on top of, or `nil` for the base image.
    public var parent: SnapshotLayer? {
        SnapshotLayer(rawValue: rawValue - 1)
    }
}

/// The triple that decides whether a queued job can start in seconds or minutes.
public struct SnapshotKey: Hashable, Sendable, CustomStringConvertible {
    public let osBuild: String
    public let appBuild: String
    public let accountSeed: String

    public init(osBuild: String, appBuild: String, accountSeed: String) {
        self.osBuild = osBuild
        self.appBuild = appBuild
        self.accountSeed = accountSeed
    }

    public var description: String { "\(osBuild)/\(appBuild)/\(accountSeed)" }

    /// The identity of one link of this key's chain.
    public func layerID(_ layer: SnapshotLayer) -> LayerID {
        switch layer {
        case .os:
            return LayerID(layer: .os, path: osBuild)
        case .app:
            return LayerID(layer: .app, path: "\(osBuild)|\(appBuild)")
        case .account:
            return LayerID(layer: .account, path: "\(osBuild)|\(appBuild)|\(accountSeed)")
        }
    }

    /// The chain from base image to seeded account, in restore order.
    public var chain: [LayerID] {
        SnapshotLayer.allCases.map { layerID($0) }
    }
}

/// Content-addressed identity of one layer.
///
/// Two keys that share an `osBuild` share the *same* `.os` layer — that sharing
/// is the entire economic argument for a snapshot store, and it is why eviction
/// cannot be reasoned about one key at a time.
public struct LayerID: Hashable, Sendable, CustomStringConvertible {
    public let layer: SnapshotLayer
    public let path: String

    public init(layer: SnapshotLayer, path: String) {
        self.layer = layer
        self.path = path
    }

    public var description: String { "\(layer):\(path)" }

    /// The identity of this layer's parent, derived from the path prefix.
    public var parentID: LayerID? {
        guard let parentLayer = layer.parent else { return nil }
        // `path` is built by `SnapshotKey.layerID` as pipe-joined components,
        // one per layer, so the parent's path is this path minus its last
        // component. `dropLast()` on an empty collection is well-defined.
        let components = path.split(separator: "|", omittingEmptySubsequences: false)
        let parentComponents = components.dropLast()
        guard !parentComponents.isEmpty else { return nil }
        return LayerID(layer: parentLayer, path: parentComponents.joined(separator: "|"))
    }
}

/// Size and rebuild cost of one layer.
public struct LayerDescriptor: Hashable, Sendable {
    public let id: LayerID
    /// Bytes this layer occupies on the host, as reported by the hypervisor.
    public let bytes: Int
    /// Wall-clock milliseconds to reproduce this layer if it is not resident.
    public let rebuildMillis: Int

    public init(id: LayerID, bytes: Int, rebuildMillis: Int) {
        self.id = id
        // Both values come from outside; clamp rather than trust.
        self.bytes = max(0, bytes)
        self.rebuildMillis = max(0, rebuildMillis)
    }
}

/// Where layer sizes and rebuild costs come from.
///
/// Held separately from the store so the same catalog can be consulted by a
/// host that has the layer and one that does not — a scheduler has to price a
/// miss before it decides to take one.
public struct SnapshotCatalog: Sendable {
    private var descriptors: [LayerID: LayerDescriptor]

    public init(descriptors: [LayerDescriptor] = []) {
        self.descriptors = Dictionary(
            descriptors.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    public mutating func register(_ descriptor: LayerDescriptor) {
        descriptors[descriptor.id] = descriptor
    }

    public func descriptor(for id: LayerID) -> LayerDescriptor? {
        descriptors[id]
    }

    /// Descriptors for a key's full chain, in restore order.
    ///
    /// Returns `nil` if any link is unknown: a partially priced chain is not
    /// something a scheduler should silently treat as cheap.
    public func chain(for key: SnapshotKey) -> [LayerDescriptor]? {
        var result: [LayerDescriptor] = []
        result.reserveCapacity(SnapshotLayer.allCases.count)
        for id in key.chain {
            guard let descriptor = descriptors[id] else { return nil }
            result.append(descriptor)
        }
        return result
    }

    /// Total milliseconds to rebuild every link of `key`'s chain from nothing.
    public func fullRebuildMillis(for key: SnapshotKey) -> Int {
        Saturating.sum(key.chain.map { descriptors[$0]?.rebuildMillis ?? 0 })
    }
}
