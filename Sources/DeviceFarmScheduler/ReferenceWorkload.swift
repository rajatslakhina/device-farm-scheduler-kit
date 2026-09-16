/// A single named workload used by the tests, the demo app, and every number
/// quoted in the README.
///
/// Having exactly one fixture is the point. A comparison between scheduling
/// policies is trivially riggable by choosing the workload afterwards, so the
/// workload is fixed first, defined here, seeded, and shared — the tests assert
/// against it and the demo app renders the same run. If a claim in the README
/// stops being true, a test fails.
///
/// ### The shape, and why
///
/// Two OS builds, because a fleet is never on one. The `.os` layer is 6 GiB and
/// takes three minutes to restore, against a host store of 8 GiB — so a host
/// can hold exactly one OS build's world at a time, and moving a host between
/// OS builds is the single most expensive thing the farm can do. That is not a
/// contrived constraint; it is the actual economics of DFU-restoring firmware.
///
/// Three tenants at 60/30/10 of arrivals. `payments` is the small one, and it is
/// the only tenant whose chain lives on the *other* OS build — which is exactly
/// the position a small team ends up in, and exactly what makes it invisible to
/// a policy that ranks by cache warmth.
///
/// Arrivals are bursty: nothing for a minute, then five runs at once. That is
/// agent fan-out — one PR, one matrix, twenty runs enqueued in the same second —
/// and it is the load pattern that makes the choice of policy matter at all.
public enum ReferenceWorkload {

    // MARK: - Tenants

    public static let checkout = TenantID("checkout")
    public static let search = TenantID("search")
    public static let payments = TenantID("payments")

    // MARK: - Builds

    public static let osMain = "iOS-27.0-23A1"
    public static let osNext = "iOS-27.1-23B2"

    // MARK: - Snapshot keys

    public static let checkoutBasket = SnapshotKey(
        osBuild: osMain, appBuild: "checkout-4711", accountSeed: "seed-basket"
    )
    public static let checkoutGuest = SnapshotKey(
        osBuild: osMain, appBuild: "checkout-4711", accountSeed: "seed-guest"
    )
    public static let searchEmpty = SnapshotKey(
        osBuild: osMain, appBuild: "search-2210", accountSeed: "seed-empty"
    )
    public static let searchHistory = SnapshotKey(
        osBuild: osMain, appBuild: "search-2210", accountSeed: "seed-history"
    )
    public static let paymentsCard = SnapshotKey(
        osBuild: osNext, appBuild: "payments-88", accountSeed: "seed-card"
    )

    public static let allKeys: [SnapshotKey] = [
        checkoutBasket, checkoutGuest, searchEmpty, searchHistory, paymentsCard,
    ]

    // MARK: - Layer economics

    /// 6 GiB restored firmware, three minutes to lay down.
    public static let osLayerBytes = 6 * 1024 * 1024 * 1024
    public static let osLayerRebuildMillis = 180_000
    /// ~900 MiB app image, 25s to install and settle.
    public static let appLayerBytes = 900 * 1024 * 1024
    public static let appLayerRebuildMillis = 25_000
    /// ~200 MiB of seeded account state, 6s to apply.
    public static let accountLayerBytes = 200 * 1024 * 1024
    public static let accountLayerRebuildMillis = 6_000

    /// Host store size: one OS build's world, and not two.
    public static let hostCapacityBytes = 8 * 1024 * 1024 * 1024

    public static func makeCatalog() -> SnapshotCatalog {
        var catalog = SnapshotCatalog()
        var seen = Set<LayerID>()
        for key in allKeys {
            for layer in SnapshotLayer.allCases {
                let id = key.layerID(layer)
                guard seen.insert(id).inserted else { continue }
                let bytes: Int
                let millis: Int
                switch layer {
                case .os:
                    bytes = osLayerBytes
                    millis = osLayerRebuildMillis
                case .app:
                    bytes = appLayerBytes
                    millis = appLayerRebuildMillis
                case .account:
                    bytes = accountLayerBytes
                    millis = accountLayerRebuildMillis
                }
                catalog.register(LayerDescriptor(id: id, bytes: bytes, rebuildMillis: millis))
            }
        }
        return catalog
    }

    // MARK: - The workload

    public static func makeSpec() -> WorkloadSpec {
        WorkloadSpec(
            tenants: [
                TenantProfile(
                    id: checkout,
                    // DRR quanta are in the same unit as service time, and each
                    // is >= that tenant's longest job so a single large run can
                    // always eventually be afforded.
                    quantum: 90,
                    snapshots: [checkoutBasket, checkoutGuest],
                    arrivalWeight: 12,
                    serviceTicks: 30...70
                ),
                TenantProfile(
                    id: search,
                    quantum: 60,
                    snapshots: [searchEmpty, searchHistory],
                    arrivalWeight: 6,
                    serviceTicks: 25...55
                ),
                TenantProfile(
                    id: payments,
                    quantum: 25,
                    snapshots: [paymentsCard],
                    arrivalWeight: 2,
                    serviceTicks: 35...80
                ),
            ],
            catalog: makeCatalog(),
            // 30 minutes of farm time at one tick per second.
            horizonTicks: 1_800,
            hostCount: 8,
            hostCapacityBytes: hostCapacityBytes,
            baseArrivalsPerTick: 0,
            burstEveryTicks: 30,
            // 2 to 6 runs per burst: one PR's device matrix, and matrices are
            // not all the same size.
            burstSize: 2,
            burstJitter: 4,
            seed: 0xD0FA_5CED_F00D
        )
    }

    /// How long a stretch of time counts as one observation for pool sizing.
    ///
    /// This is not a cosmetic choice. Bucket per tick and the question becomes
    /// "how many jobs arrived in this one second" — answered "zero" in 97% of
    /// buckets, from which the sizer correctly concludes that no warm pool is
    /// ever worth its idle cost. That answer is right about the model and wrong
    /// about the farm. The window has to match the timescale over which a host
    /// usefully stays warm, which is why it is an explicit parameter here rather
    /// than an implicit one buried in the data.
    public static let observationWindowTicks = 30

    /// Arrival histogram matching the workload's burst pattern, for the sizer.
    public static func makeArrivalHistogram() -> ArrivalHistogram {
        ArrivalHistogram(
            trace: makeSpec().arrivalTrace(),
            windowTicks: observationWindowTicks
        )
    }

    public static func makeCostModel() -> PoolCostModel {
        // One warm host costs 3 units per interval to hold; one cold start costs
        // 40 units of engineer-waiting. The ratio is what the sizer reads.
        PoolCostModel(idleHostCostPerInterval: 3, coldStartCostPerJob: 40)
    }

    public static func makeAdmissionPolicy() -> AdmissionPolicy {
        AdmissionPolicy(maxQueueDepth: 240, maxQueuedPerTenant: 96, waitBudgetTicks: 300)
    }
}
