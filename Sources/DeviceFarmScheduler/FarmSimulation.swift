/// Seeded splitmix64. Deterministic on every platform, which is the whole point:
/// a farm's scheduling decisions have to be replayable, and a comparison between
/// policies is only evidence if all three saw the identical arrival trace.
public struct DeterministicRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `range`, without trapping on any range the caller can express.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        // Saturating subtraction keeps this safe even for Int.min...Int.max.
        let span = UInt64(max(0, Saturating.subtract(range.upperBound, range.lowerBound))) &+ 1
        // `span` is at least 1 here, so the modulus cannot divide by zero, and
        // the result is < 2^63 so the Int conversion is always in range.
        let offset = Int(next() % span)
        return Saturating.clamp(Saturating.add(range.lowerBound, offset), to: range)
    }

    /// An element of `values`, or `nil` when it is empty.
    public mutating func pick<T>(from values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        let index = int(in: 0...(values.count - 1))
        return values.indices.contains(index) ? values[index] : values.first
    }
}

/// One tenant's shape: how much it runs, and across how many distinct snapshots.
public struct TenantProfile: Sendable {
    public let id: TenantID
    /// Share of host time this tenant earns per DRR round.
    public let quantum: Int
    /// The distinct snapshot chains this tenant's matrix uses.
    public let snapshots: [SnapshotKey]
    /// Relative share of arrivals. A tenant with weight 1 against one with
    /// weight 14 is the small tenant this kit is worried about.
    public let arrivalWeight: Int
    public let serviceTicks: ClosedRange<Int>

    /// Ceiling on a single tenant's arrival weight.
    ///
    /// Weights are expanded into a pick list, so an unbounded weight is an
    /// unbounded allocation from a public initializer taking a plain `Int`.
    /// `ArrivalHistogram` guards the same hazard the same way; a relative weight
    /// beyond this is a typo, not a workload.
    public static let maxArrivalWeight = 4096

    public init(
        id: TenantID,
        quantum: Int,
        snapshots: [SnapshotKey],
        arrivalWeight: Int,
        serviceTicks: ClosedRange<Int>
    ) {
        self.id = id
        self.quantum = max(1, quantum)
        self.snapshots = snapshots
        self.arrivalWeight = Saturating.clamp(
            arrivalWeight, to: 0...TenantProfile.maxArrivalWeight
        )
        self.serviceTicks = serviceTicks
    }
}

/// A reproducible workload.
///
/// Arrivals are deliberately not smooth. The pattern is a low background rate
/// punctuated by bursts, because that is what a farm in front of an agent-driven
/// repo actually sees: a human opens one PR and the agent fans out twenty runs
/// against the device matrix in the same second. Smoothing that away would make
/// every policy look equally good, which is exactly the mistake a simulation is
/// supposed to stop you making.
public struct WorkloadSpec: Sendable {
    public let tenants: [TenantProfile]
    public let catalog: SnapshotCatalog
    public let horizonTicks: Int
    public let hostCount: Int
    public let hostCapacityBytes: Int
    public let baseArrivalsPerTick: Int
    public let burstEveryTicks: Int
    public let burstSize: Int
    /// Extra arrivals a burst may carry, drawn uniformly from `0...burstJitter`.
    ///
    /// Without jitter every burst is the same size, the arrival histogram has a
    /// single non-zero bucket, and pool sizing becomes arithmetic rather than a
    /// decision — which would make the sizer look far more confident than it
    /// deserves to on any real workload.
    public let burstJitter: Int
    public let seed: UInt64

    /// Ceiling on the simulated horizon. The trace is materialised as one array
    /// entry per tick, so an unbounded horizon is an unbounded allocation from a
    /// public initializer. A quarter of a million ticks is ~3 days of farm time
    /// at one tick per second — past any window worth replaying.
    public static let maxHorizonTicks = 250_000

    /// Ceiling on fleet size, for the same reason: `makeState` allocates a host
    /// per unit.
    public static let maxHostCount = 4096

    /// Ceiling on arrivals generated for a single tick, covering
    /// `baseArrivalsPerTick`, `burstSize` and `burstJitter`. A burst larger than
    /// this is a typo, not a workload.
    public static let maxArrivalsPerTick = 4096

    /// Ceiling on distinct tenants. `weightedTenants` expands each tenant by its
    /// arrival weight, so the pick list is bounded by
    /// `maxTenants × maxArrivalWeight` rather than by nothing.
    public static let maxTenants = 1024

    public init(
        tenants: [TenantProfile],
        catalog: SnapshotCatalog,
        horizonTicks: Int,
        hostCount: Int,
        hostCapacityBytes: Int,
        baseArrivalsPerTick: Int,
        burstEveryTicks: Int,
        burstSize: Int,
        burstJitter: Int = 0,
        seed: UInt64
    ) {
        self.burstJitter = max(0, burstJitter)
        self.tenants = Array(tenants.prefix(WorkloadSpec.maxTenants))
        self.catalog = catalog
        self.horizonTicks = Saturating.clamp(horizonTicks, to: 0...WorkloadSpec.maxHorizonTicks)
        self.hostCount = Saturating.clamp(hostCount, to: 0...WorkloadSpec.maxHostCount)
        self.hostCapacityBytes = max(0, hostCapacityBytes)
        // Every one of these feeds `arrivalTrace`'s per-tick batch, which
        // reserves capacity for `base + burstSize + jitter` and then loops that
        // many times. Clamping to `max(0, …)` alone leaves a public initializer
        // taking a plain `Int` able to request an `Int.max`-element allocation —
        // the identical hazard `maxArrivalWeight` and `maxHorizonTicks` exist
        // to close, missed here on the first pass.
        self.baseArrivalsPerTick = Saturating.clamp(
            baseArrivalsPerTick, to: 0...WorkloadSpec.maxArrivalsPerTick
        )
        self.burstEveryTicks = max(1, burstEveryTicks)
        self.burstSize = Saturating.clamp(burstSize, to: 0...WorkloadSpec.maxArrivalsPerTick)
        self.seed = seed
    }

    /// Tenants expanded into a weighted pick list.
    private var weightedTenants: [TenantProfile] {
        tenants.flatMap { profile in
            Array(repeating: profile, count: profile.arrivalWeight)
        }
    }

    /// The arrival trace: `trace[tick]` is what showed up at that tick.
    ///
    /// Generated once and replayed for every policy, so a difference in the
    /// reports is a difference in the policies and nothing else.
    public func arrivalTrace() -> [[Job]] {
        var rng = DeterministicRandom(seed: seed)
        let pool = weightedTenants
        var trace: [[Job]] = Array(repeating: [], count: horizonTicks)
        guard !pool.isEmpty, horizonTicks > 0 else { return trace }

        var nextJobID = 0
        for tick in 0..<horizonTicks {
            let isBurst = Saturating.remainder(tick, burstEveryTicks) == 0
            let jitter = (isBurst && burstJitter > 0)
                ? rng.int(in: 0...min(burstJitter, WorkloadSpec.maxArrivalsPerTick))
                : 0
            let arrivals = isBurst
                ? Saturating.add(Saturating.add(baseArrivalsPerTick, burstSize), jitter)
                : baseArrivalsPerTick

            var batch: [Job] = []
            batch.reserveCapacity(max(0, arrivals))
            var remaining = arrivals
            while remaining > 0 {
                remaining -= 1
                guard let profile = rng.pick(from: pool),
                      let snapshot = rng.pick(from: profile.snapshots) else { continue }
                let service = rng.int(in: profile.serviceTicks)
                batch.append(
                    Job(
                        id: JobID(nextJobID),
                        tenant: profile.id,
                        snapshot: snapshot,
                        serviceTicks: service,
                        enqueuedTick: tick
                    )
                )
                nextJobID = Saturating.add(nextJobID, 1)
            }
            // `tick` is drawn from `0..<horizonTicks` and `trace` has exactly
            // `horizonTicks` elements, so this subscript is in range.
            if trace.indices.contains(tick) { trace[tick] = batch }
        }
        return trace
    }

    /// A fresh scheduler state for this workload.
    public func makeState() -> SchedulerState {
        let hosts = (0..<hostCount).map { index in
            Host(
                id: HostID("host-\(index)"),
                store: SnapshotStore(capacityBytes: hostCapacityBytes)
            )
        }
        let quanta = Dictionary(
            tenants.map { ($0.id, $0.quantum) },
            uniquingKeysWith: { first, _ in first }
        )
        return SchedulerState(hosts: hosts, catalog: catalog, quanta: quanta)
    }
}

/// Wait-time summary for one tenant.
///
/// Jobs that never ran are tracked separately and deliberately. Measuring only
/// dispatched jobs is the classic way to make a starving policy look healthy: a
/// tenant that is never served has no dispatched jobs, therefore no recorded
/// waits, therefore a max wait of zero — a perfect score for the exact failure
/// the metric exists to catch. `worstWaitTicks` is the number to quote, and it
/// counts the age of work that is still sitting in the queue at the horizon.
public struct WaitStats: Sendable, Equatable {
    public var dispatched: Int = 0
    public var totalWaitTicks: Int = 0
    public var maxDispatchedWaitTicks: Int = 0
    public var stillQueued: Int = 0
    public var maxQueuedAgeTicks: Int = 0

    public var meanWaitTicks: Int {
        Saturating.divide(totalWaitTicks, by: max(1, dispatched))
    }

    /// The honest headline: worst time any of this tenant's jobs spent waiting,
    /// whether or not it ever got a host.
    public var worstWaitTicks: Int {
        max(maxDispatchedWaitTicks, maxQueuedAgeTicks)
    }

    mutating func record(waitTicks: Int) {
        dispatched = Saturating.add(dispatched, 1)
        totalWaitTicks = Saturating.add(totalWaitTicks, waitTicks)
        maxDispatchedWaitTicks = max(maxDispatchedWaitTicks, waitTicks)
    }

    mutating func recordUnserved(ageTicks: Int) {
        stillQueued = Saturating.add(stillQueued, 1)
        maxQueuedAgeTicks = max(maxQueuedAgeTicks, ageTicks)
    }
}

/// What one policy did with one workload.
public struct PolicyReport: Sendable, Equatable {
    public let policyName: String
    public let dispatched: Int
    public let warmDispatches: Int
    public let totalRestoreMillis: Int
    public let waitByTenant: [TenantID: WaitStats]
    public let jobsLeftQueued: Int

    /// Percentage of dispatches that paid no restore at all, 0...100.
    public var warmHitRatePercent: Int {
        guard dispatched > 0 else { return 0 }
        return Saturating.divide(Saturating.multiply(warmDispatches, 100), by: dispatched)
    }

    /// Dispatches that paid some restore.
    public var coldDispatches: Int { Saturating.subtract(dispatched, warmDispatches) }

    /// Worst wait any tenant suffered, counting never-served work. The fairness
    /// headline.
    public var worstTenantWaitTicks: Int {
        waitByTenant.values.map(\.worstWaitTicks).max() ?? 0
    }

    /// The tenant that waited longest.
    public var worstTenant: TenantID? {
        waitByTenant
            .sorted { lhs, rhs in
                lhs.value.worstWaitTicks != rhs.value.worstWaitTicks
                    ? lhs.value.worstWaitTicks > rhs.value.worstWaitTicks
                    : lhs.key < rhs.key
            }
            .first?
            .key
    }

    /// Worst wait for one tenant, counting jobs that never got a host.
    public func worstWait(for tenant: TenantID) -> Int {
        waitByTenant[tenant]?.worstWaitTicks ?? 0
    }

    public func dispatched(for tenant: TenantID) -> Int {
        waitByTenant[tenant]?.dispatched ?? 0
    }

    public func stillQueued(for tenant: TenantID) -> Int {
        waitByTenant[tenant]?.stillQueued ?? 0
    }
}

public enum FarmSimulation {

    /// Replays `trace` through `policy` and reports what happened.
    public static func run(
        spec: WorkloadSpec,
        policy: some PlacementPolicy,
        trace: [[Job]]
    ) -> PolicyReport {
        var state = spec.makeState()
        var waits: [TenantID: WaitStats] = [:]
        var dispatched = 0
        var warm = 0
        var restoreMillis = 0

        for tick in 0..<spec.horizonTicks {
            state.advance(to: tick)
            if trace.indices.contains(tick) {
                state.enqueue(contentsOf: trace[tick])
            }

            // Bounded inner loop: each successful dispatch consumes an idle
            // host, and there are finitely many, so the guard is belt-and-braces
            // against a policy that returns a placement `dispatch` rejects.
            var dispatchesThisTick = 0
            let maxDispatchesThisTick = max(1, spec.hostCount)
            while dispatchesThisTick < maxDispatchesThisTick {
                guard let placement = policy.nextPlacement(in: &state) else { break }
                guard let outcome = state.dispatch(placement) else { break }
                dispatchesThisTick += 1

                dispatched = Saturating.add(dispatched, 1)
                if outcome.wasFullyWarm { warm = Saturating.add(warm, 1) }
                restoreMillis = Saturating.add(restoreMillis, outcome.restoreMillis)
                waits[outcome.tenant, default: WaitStats()].record(waitTicks: outcome.waitTicks)
            }
        }

        // Charge the horizon for everything still waiting, so a policy cannot
        // score well by simply never serving a tenant.
        for tenant in state.tenantOrder {
            for job in state.queue(for: tenant) {
                let age = max(0, Saturating.subtract(spec.horizonTicks, job.enqueuedTick))
                waits[tenant, default: WaitStats()].recordUnserved(ageTicks: age)
            }
        }

        return PolicyReport(
            policyName: policy.name,
            dispatched: dispatched,
            warmDispatches: warm,
            totalRestoreMillis: restoreMillis,
            waitByTenant: waits,
            jobsLeftQueued: state.queuedJobCount
        )
    }

    /// Runs all three shipped policies over one identical trace.
    ///
    /// Order is fixed — layered, affinity-first, strict-fairness — so callers
    /// (including the demo app's segmented control) can index it stably.
    public static func compareShippedPolicies(spec: WorkloadSpec) -> [PolicyReport] {
        let trace = spec.arrivalTrace()
        return [
            run(spec: spec, policy: LayeredAffinityFairPolicy(), trace: trace),
            run(spec: spec, policy: AffinityFirstPolicy(), trace: trace),
            run(spec: spec, policy: StrictFairnessPolicy(), trace: trace),
        ]
    }
}
