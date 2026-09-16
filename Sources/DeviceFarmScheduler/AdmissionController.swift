/// Limits on what the farm will take on.
public struct AdmissionPolicy: Sendable, Equatable {
    /// Total queued jobs across all tenants before the farm stops accepting.
    public let maxQueueDepth: Int
    /// Queued jobs one tenant may hold. This is the device-matrix guard: one
    /// repo fanning out a 40-entry matrix must not be able to fill the queue.
    public let maxQueuedPerTenant: Int
    /// Wait the farm is willing to promise. Past this, work is still admitted
    /// but the caller is told the number, which is the part that matters.
    public let waitBudgetTicks: Int

    public init(maxQueueDepth: Int, maxQueuedPerTenant: Int, waitBudgetTicks: Int) {
        self.maxQueueDepth = max(0, maxQueueDepth)
        self.maxQueuedPerTenant = max(0, maxQueuedPerTenant)
        self.waitBudgetTicks = max(0, waitBudgetTicks)
    }
}

public enum AdmissionDecision: Sendable, Equatable {
    /// Accepted, expected to start within the wait budget.
    case admit(estimatedWaitTicks: Int)
    /// Accepted, but the estimate is past the budget. The caller gets the number
    /// rather than a silent queue.
    case admitOverBudget(estimatedWaitTicks: Int, budgetTicks: Int)
    case rejectQueueFull(depth: Int, limit: Int)
    case rejectTenantQuota(queued: Int, limit: Int)
    /// The chain has no price in the catalog, so no host can be asked to restore
    /// it. Rejecting beats queueing work that can never start.
    case rejectUnknownSnapshot(SnapshotKey)

    public var isAdmitted: Bool {
        switch self {
        case .admit, .admitOverBudget: return true
        case .rejectQueueFull, .rejectTenantQuota, .rejectUnknownSnapshot: return false
        }
    }

    public var estimatedWaitTicks: Int? {
        switch self {
        case let .admit(wait): return wait
        case let .admitOverBudget(wait, _): return wait
        case .rejectQueueFull, .rejectTenantQuota, .rejectUnknownSnapshot: return nil
        }
    }
}

/// Decides what the farm refuses.
///
/// The framing this kit argues for: a scheduler's interesting decision is not
/// "which job runs next" — every scheduler answers that. It is "what do we
/// decline, and what do we tell the caller". A farm that accepts everything and
/// queues it has not avoided the capacity problem, it has moved the problem to a
/// place where nobody can see it, and turned a fast, actionable rejection into a
/// forty-minute silence that a CI dashboard reports as "running".
public struct AdmissionController: Sendable {
    public let policy: AdmissionPolicy

    public init(policy: AdmissionPolicy) {
        self.policy = policy
    }

    public func decide(_ job: Job, given state: SchedulerState) -> AdmissionDecision {
        guard state.catalog.chain(for: job.snapshot) != nil else {
            return .rejectUnknownSnapshot(job.snapshot)
        }

        let depth = state.queuedJobCount
        guard depth < policy.maxQueueDepth else {
            return .rejectQueueFull(depth: depth, limit: policy.maxQueueDepth)
        }

        let tenantQueued = state.queue(for: job.tenant).count
        guard tenantQueued < policy.maxQueuedPerTenant else {
            return .rejectTenantQuota(queued: tenantQueued, limit: policy.maxQueuedPerTenant)
        }

        let wait = estimatedWaitTicks(for: job, given: state)
        return wait <= policy.waitBudgetTicks
            ? .admit(estimatedWaitTicks: wait)
            : .admitOverBudget(estimatedWaitTicks: wait, budgetTicks: policy.waitBudgetTicks)
    }

    /// First-order wait estimate, and deliberately labelled as such.
    ///
    /// The model: this tenant's queued service time has to drain, and under DRR
    /// the tenant receives roughly `quantum / Σquanta` of the fleet's capacity.
    /// It ignores restore cost, which makes it optimistic, and it ignores future
    /// arrivals, which makes it optimistic again. Both are stated here rather
    /// than hidden, because an estimate whose error direction is documented is
    /// usable and one whose isn't, is not.
    public func estimatedWaitTicks(for job: Job, given state: SchedulerState) -> Int {
        let idleNow = state.idleHosts(at: state.tick).count
        let tenantBacklog = state.queue(for: job.tenant)
        guard !tenantBacklog.isEmpty || idleNow == 0 else { return 0 }

        let backlogTicks = Saturating.sum(tenantBacklog.map(\.serviceTicks))
        let hostCount = max(1, state.hosts.count)

        let totalQuanta = Saturating.sum(state.tenantOrder.map { state.quantum(for: $0) })
        let share = state.quantum(for: job.tenant)
        // Effective parallelism this tenant can expect, floored at 1 so a tiny
        // share never divides the estimate to zero.
        let effectiveHosts = max(
            1,
            Saturating.divide(Saturating.multiply(hostCount, share), by: max(1, totalQuanta))
        )
        return Saturating.divide(backlogTicks, by: effectiveHosts)
    }
}
