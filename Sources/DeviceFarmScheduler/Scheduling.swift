/// Identity of a team or repo competing for the farm.
public struct TenantID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (lhs: TenantID, rhs: TenantID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identity of one virtualized-iPhone host.
public struct HostID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (lhs: HostID, rhs: HostID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identity of one queued run.
public struct JobID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public var description: String { "job-\(rawValue)" }
    public static func < (lhs: JobID, rhs: JobID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One unit of work: run this app build, on this OS build, against this seeded
/// account, on behalf of this tenant.
public struct Job: Sendable, Hashable, Identifiable {
    public let id: JobID
    public let tenant: TenantID
    public let snapshot: SnapshotKey
    /// Ticks of host time the run itself is expected to occupy, excluding any
    /// restore. Also the deficit cost the tenant pays to be dispatched.
    public let serviceTicks: Int
    public let enqueuedTick: Int

    public init(
        id: JobID,
        tenant: TenantID,
        snapshot: SnapshotKey,
        serviceTicks: Int,
        enqueuedTick: Int
    ) {
        self.id = id
        self.tenant = tenant
        self.snapshot = snapshot
        // A zero-cost job would let a tenant dispatch without ever spending
        // deficit, which breaks the fairness bound. Floor at 1.
        self.serviceTicks = max(1, serviceTicks)
        self.enqueuedTick = enqueuedTick
    }
}

/// One virtualized-iPhone host and whatever it currently holds.
public struct Host: Sendable, Identifiable {
    public let id: HostID
    public var store: SnapshotStore
    /// Tick at which this host becomes free. A host is idle when this is `<=`
    /// the current tick.
    public var busyUntilTick: Int
    public private(set) var currentJob: JobID?

    public init(id: HostID, store: SnapshotStore, busyUntilTick: Int = 0) {
        self.id = id
        self.store = store
        self.busyUntilTick = busyUntilTick
        self.currentJob = nil
    }

    public func isIdle(at tick: Int) -> Bool { busyUntilTick <= tick }

    public mutating func begin(job: JobID, until tick: Int) {
        currentJob = job
        busyUntilTick = tick
    }

    public mutating func release(at tick: Int) {
        if busyUntilTick <= tick { currentJob = nil }
    }
}

/// A chosen (job, host) pair and how warm it is.
public struct Placement: Sendable, Hashable {
    public let job: JobID
    public let host: HostID
    /// Deepest layer of the job's chain already resident on the host, or `nil`
    /// when the host holds nothing usable and the run pays a full restore.
    public let warmDepth: SnapshotLayer?

    public init(job: JobID, host: HostID, warmDepth: SnapshotLayer?) {
        self.job = job
        self.host = host
        self.warmDepth = warmDepth
    }

    public var isFullyWarm: Bool { warmDepth == .account }
}

/// What actually happened when a placement was carried out.
public struct DispatchOutcome: Sendable, Hashable {
    public let placement: Placement
    public let job: JobID
    public let tenant: TenantID
    /// Ticks the job spent queued before it started.
    public let waitTicks: Int
    /// Milliseconds of restore work paid before the run could start.
    public let restoreMillis: Int
    public let startedTick: Int
    public let completesTick: Int

    public var wasFullyWarm: Bool { restoreMillis == 0 }
}

/// The whole scheduler's mutable state.
///
/// A plain value type on purpose. Placement decisions are the part of a farm
/// that has to be auditable — "why did job 4412 wait nine minutes" is a question
/// someone will ask — and a synchronous, deterministic state machine can be
/// replayed from a recorded arrival trace to answer it exactly. Concurrency
/// lives at the edge, in whatever drives the hosts, not in the decision logic.
/// `FarmCoordinator` is the actor that owns one of these for a live farm.
public struct SchedulerState: Sendable {
    public var tick: Int
    public var hosts: [Host]
    public var catalog: SnapshotCatalog

    /// Per-tenant FIFO backlog.
    public private(set) var queues: [TenantID: [Job]]
    /// Stable service order for round-robin. Sorted, so replay is deterministic.
    public private(set) var tenantOrder: [TenantID]
    /// Deficit round-robin accounting.
    public internal(set) var deficits: [TenantID: Int]
    /// Per-tenant quantum: the share of host time a tenant earns per round.
    public private(set) var quanta: [TenantID: Int]
    /// Index into `tenantOrder` for the next round-robin visit.
    public internal(set) var roundRobinCursor: Int
    /// Consecutive turns each tenant has passed up while waiting for a host
    /// that already holds its OS build. See `LayeredAffinityFairPolicy`.
    public internal(set) var affinitySkips: [TenantID: Int] = [:]
    /// Index into `hosts` used by policies that rotate hosts rather than
    /// choosing them by affinity.
    public internal(set) var hostCursor: Int

    /// Ceiling on accumulated deficit, as a multiple of a tenant's quantum.
    ///
    /// Without it, a tenant that is idle for an hour banks an hour of credit and
    /// then monopolises the farm the moment it wakes up — technically fair over
    /// an infinite horizon and useless over the one anybody cares about.
    public var deficitCeilingMultiplier: Int

    public init(
        tick: Int = 0,
        hosts: [Host],
        catalog: SnapshotCatalog,
        quanta: [TenantID: Int],
        deficitCeilingMultiplier: Int = 4
    ) {
        self.tick = tick
        self.hosts = hosts
        self.catalog = catalog
        self.queues = [:]
        // Sorted for replay determinism; dictionary key order is not stable.
        self.tenantOrder = quanta.keys.sorted()
        self.deficits = quanta.keys.reduce(into: [:]) { $0[$1] = 0 }
        self.quanta = quanta.mapValues { max(1, $0) }
        self.roundRobinCursor = 0
        self.hostCursor = 0
        self.deficitCeilingMultiplier = max(1, deficitCeilingMultiplier)
    }

    // MARK: - Queue management

    public var queuedJobCount: Int {
        queues.values.reduce(0) { Saturating.add($0, $1.count) }
    }

    public func queue(for tenant: TenantID) -> [Job] { queues[tenant] ?? [] }

    public mutating func enqueue(_ job: Job) {
        if quanta[job.tenant] == nil {
            // A tenant that was never configured still has to be served, or an
            // unknown repo's jobs vanish silently. Register it with the median
            // quantum so it competes on ordinary terms.
            let existing = quanta.values.sorted()
            let median = existing.isEmpty
                ? 1
                : existing[existing.count / 2] // count > 0, so the index is in range
            quanta[job.tenant] = max(1, median)
            deficits[job.tenant] = 0
            tenantOrder = (tenantOrder + [job.tenant]).sorted()
        }
        queues[job.tenant, default: []].append(job)
    }

    public mutating func enqueue(contentsOf jobs: [Job]) {
        for job in jobs { enqueue(job) }
    }

    public func job(with id: JobID) -> Job? {
        for jobs in queues.values {
            if let match = jobs.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    @discardableResult
    mutating func removeJob(_ id: JobID, from tenant: TenantID) -> Job? {
        guard var jobs = queues[tenant],
              let index = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        let job = jobs.remove(at: index)
        queues[tenant] = jobs
        return job
    }

    public func quantum(for tenant: TenantID) -> Int { quanta[tenant] ?? 1 }

    /// Ceiling on a tenant's accumulated deficit.
    ///
    /// The base is `quantum × multiplier`, but it stretches to the largest job
    /// the tenant currently has waiting. Without the stretch there is a silent
    /// permanent-starvation bug: a run whose service cost exceeds the ceiling
    /// can never be afforded, so it is passed over on every single round,
    /// forever, while the queue reports it as merely "waiting". Classic DRR
    /// avoids this by requiring the quantum to be at least the maximum packet
    /// size; a farm cannot make that promise, because the size of the largest
    /// job is a property of somebody else's test suite. So the ceiling adapts
    /// instead.
    public func deficitCeiling(for tenant: TenantID) -> Int {
        let base = Saturating.multiply(quantum(for: tenant), deficitCeilingMultiplier)
        let largestWaiting = queue(for: tenant).map(\.serviceTicks).max() ?? 0
        return max(base, largestWaiting)
    }

    // MARK: - Host management

    public func idleHosts(at tick: Int) -> [Host] {
        hosts.filter { $0.isIdle(at: tick) }
    }

    public var hasIdleHost: Bool {
        hosts.contains { $0.isIdle(at: tick) }
    }

    mutating func hostIndex(of id: HostID) -> Int? {
        hosts.firstIndex { $0.id == id }
    }

    /// Takes a host back immediately, whatever it thought it was doing.
    ///
    /// Needed when a lease is reclaimed. Requeuing the job without this leaves
    /// the host marked busy until a run that no longer exists would have
    /// finished — so a single wedged guest permanently removes a host from the
    /// fleet, and the farm quietly shrinks every time one dies.
    public mutating func forceRelease(host id: HostID, at tick: Int) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].busyUntilTick = tick
        hosts[index].release(at: tick)
    }

    /// Advances to `newTick`, releasing any host whose run has finished.
    public mutating func advance(to newTick: Int) {
        tick = max(tick, newTick)
        for index in hosts.indices {
            hosts[index].release(at: tick)
        }
    }

    // MARK: - Dispatch

    /// Carries out a placement: restores whatever is missing, marks the host
    /// busy, removes the job from its queue.
    ///
    /// Returns `nil` — mutating nothing — if the placement no longer refers to a
    /// real queued job and idle host, which is what a stale plan looks like.
    @discardableResult
    public mutating func dispatch(_ placement: Placement) -> DispatchOutcome? {
        guard let hostIdx = hosts.firstIndex(where: { $0.id == placement.host }),
              hosts[hostIdx].isIdle(at: tick) else { return nil }

        var matchedJob: Job?
        for tenant in tenantOrder {
            if let candidate = queues[tenant]?.first(where: { $0.id == placement.job }) {
                matchedJob = candidate
                break
            }
        }
        guard let job = matchedJob else { return nil }

        let restoreMillis = hosts[hostIdx].store.restoreCostMillis(for: job.snapshot, catalog: catalog)
        let result = hosts[hostIdx].store.admit(job.snapshot, catalog: catalog, at: tick)
        guard result.admitted else { return nil }

        // Restore time is charged to the host in ticks. One tick is one second
        // of farm time throughout this module; see `FarmSimulation`.
        let restoreTicks = Saturating.divide(Saturating.add(restoreMillis, 999), by: 1000)
        let completes = Saturating.add(tick, Saturating.add(job.serviceTicks, restoreTicks))

        hosts[hostIdx].begin(job: job.id, until: completes)
        removeJob(job.id, from: job.tenant)

        return DispatchOutcome(
            placement: placement,
            job: job.id,
            tenant: job.tenant,
            waitTicks: max(0, Saturating.subtract(tick, job.enqueuedTick)),
            restoreMillis: restoreMillis,
            startedTick: tick,
            completesTick: completes
        )
    }
}
