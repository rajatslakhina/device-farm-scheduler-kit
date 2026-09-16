/// The concurrency boundary for a live farm.
///
/// ### Why the decision logic is *not* in here
///
/// Everything this actor owns is a value type with synchronous methods, and that
/// is the design, not an accident of implementation. Actor reentrancy bites when
/// a method suspends: `await` inside an actor releases the actor, another caller
/// interleaves, and the state you read before the suspension no longer describes
/// the state you write after it. Scheduling is exactly the shape of code where
/// that goes wrong quietly — a placement computed against six idle hosts,
/// applied after two of them were taken.
///
/// So no method on this actor contains an `await`. There is no suspension point
/// between reading `state` and writing it, which means the interleaving cannot
/// happen — by construction rather than by convention. That is a property you
/// can check with `grep`, which is the kind of invariant worth having. Anything
/// genuinely asynchronous (talking to a hypervisor, uploading an artifact) is
/// the caller's job, outside the actor, with the result handed back in.
public actor FarmCoordinator {

    public private(set) var state: SchedulerState
    public private(set) var leases: LeaseManager
    public private(set) var ledger: RunLedger
    private let admission: AdmissionController
    private let policy: any PlacementPolicy

    /// Runs dispatched but not yet finished, so a reclaim can requeue them.
    private var inFlight: [RunID: Job] = [:]
    /// Run identity preserved across a retry. See `tick(to:)`.
    private var retryRunForJob: [JobID: RunID] = [:]
    private var nextRunID: Int = 0

    public init(
        state: SchedulerState,
        policy: some PlacementPolicy,
        admission: AdmissionController,
        leaseTTLTicks: Int
    ) {
        self.state = state
        self.policy = policy
        self.admission = admission
        self.leases = LeaseManager(ttlTicks: leaseTTLTicks)
        self.ledger = RunLedger()
    }

    /// Offers a job to the farm. Synchronous end to end — no suspension point.
    public func submit(_ job: Job) -> AdmissionDecision {
        let decision = admission.decide(job, given: state)
        if decision.isAdmitted { state.enqueue(job) }
        return decision
    }

    /// Moves the clock, reclaims dead leases, and dispatches what it can.
    ///
    /// Returns the leases granted this tick. A job whose lease was reclaimed is
    /// re-enqueued carrying its *original* `enqueuedTick`. It goes to the back
    /// of the tenant's array, but both shipped policies order candidates by
    /// `enqueuedTick` rather than by array position, so it keeps its place in
    /// line — losing a host is the farm's fault, not the job's.
    @discardableResult
    public func tick(to newTick: Int) -> [RunLease] {
        state.advance(to: newTick)

        for expired in leases.reclaimExpired(at: state.tick) {
            // Both halves are required. Requeuing without releasing the host
            // leaks a host on every reclaim; releasing without requeuing loses
            // the run.
            state.forceRelease(host: expired.host, at: state.tick)
            if let job = inFlight.removeValue(forKey: expired.run) {
                // The run keeps its identity across the retry. Two reasons, and
                // the second is the load-bearing one: the CI job waiting on this
                // run wants exactly one verdict, and reusing the id is what
                // makes the fencing token mean anything — a zombie that resumes
                // is then competing for the *same* run and gets rejected,
                // instead of quietly writing a pass to an id nobody reads.
                retryRunForJob[job.id] = expired.run
                state.enqueue(job)
            }
        }

        var granted: [RunLease] = []
        let maxDispatches = max(1, state.hosts.count)
        var count = 0
        while count < maxDispatches {
            guard let placement = policy.nextPlacement(in: &state) else { break }
            // Captured *before* dispatch: dispatching removes the job from its
            // queue, so looking it up afterwards would always come back nil and
            // silently disable requeue-on-reclaim.
            let queuedJob = state.job(with: placement.job)
            guard state.dispatch(placement) != nil else { break }
            count += 1

            let run: RunID
            if let retried = retryRunForJob.removeValue(forKey: placement.job) {
                run = retried
            } else {
                run = RunID(nextRunID)
                nextRunID = Saturating.add(nextRunID, 1)
            }
            if let job = queuedJob {
                inFlight[run] = job
            }
            granted.append(leases.grant(run: run, host: placement.host, at: state.tick))
        }
        return granted
    }

    public func heartbeat(run: RunID, token: FencingToken) -> Bool {
        leases.heartbeat(run: run, token: token, at: state.tick)
    }

    /// Records a run's verdict. Rejected unless the caller still holds the lease.
    public func complete(
        run: RunID,
        verdict: RunResult.Verdict,
        token: FencingToken
    ) -> RunLedger.Outcome {
        let outcome = ledger.record(
            RunResult(run: run, verdict: verdict, recordedTick: state.tick),
            presenting: token
        )
        if LedgerAudit.wasAccepted(outcome) {
            inFlight.removeValue(forKey: run)
            _ = leases.release(run: run, token: token)
        }
        return outcome
    }

    public func auditLedger() -> [LedgerAudit.Violation] {
        LedgerAudit.violations(in: ledger.trace)
    }

    public func auditHosts() -> [SnapshotStoreAudit.Violation] {
        state.hosts.flatMap { SnapshotStoreAudit.violations(of: $0.store) }
    }
}
