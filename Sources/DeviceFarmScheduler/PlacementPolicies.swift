/// Chooses the next (job, host) pair to dispatch.
///
/// Three conformances ship with this module, and two of them are here to lose.
/// `AffinityFirstPolicy` and `StrictFairnessPolicy` are the two answers a farm
/// arrives at independently — one from the cache team, one from the platform
/// team — and each is defensible on its own terms. Shipping them as real,
/// measurable policies rather than as strawmen in a blog post is the point:
/// the tests run all three over the same recorded workload and the numbers, not
/// the argument, decide.
public protocol PlacementPolicy: Sendable {
    var name: String { get }

    /// The next placement to carry out, or `nil` when nothing can be dispatched
    /// at `state.tick`.
    ///
    /// Takes `inout` state because fair policies have to *spend* something to
    /// dispatch — the deficit accounting is part of the decision, not a side
    /// effect of it.
    func nextPlacement(in state: inout SchedulerState) -> Placement?
}

// MARK: - Shared affinity scan

extension SchedulerState {
    /// Best (job, host) pair among `candidates`, ranked by how much of the job's
    /// chain the host already holds, then by age.
    ///
    /// Returns `nil` when no idle host can hold any candidate's chain at all.
    func bestAffinityPlacement(among candidates: [Job]) -> Placement? {
        let idle = idleHosts(at: tick)
        guard !idle.isEmpty, !candidates.isEmpty else { return nil }

        var best: (placement: Placement, rank: Int, enqueued: Int, job: JobID, host: HostID)?

        for job in candidates {
            // A chain the catalog cannot price is a chain no host can restore.
            guard let chain = catalog.chain(for: job.snapshot) else { continue }
            let chainBytes = Saturating.sum(chain.map(\.bytes))

            for host in idle {
                guard chainBytes <= host.store.capacityBytes else { continue }
                let warmDepth = host.store.deepestResidentLayer(for: job.snapshot)
                let rank = warmDepth?.rawValue ?? -1

                let candidate = Placement(job: job.id, host: host.id, warmDepth: warmDepth)
                guard let current = best else {
                    best = (candidate, rank, job.enqueuedTick, job.id, host.id)
                    continue
                }

                // Warmer wins; then older; then lowest job id, then lowest host
                // id. The last two exist only so replaying the same trace twice
                // produces the same schedule.
                let wins: Bool
                if rank != current.rank {
                    wins = rank > current.rank
                } else if job.enqueuedTick != current.enqueued {
                    wins = job.enqueuedTick < current.enqueued
                } else if job.id != current.job {
                    wins = job.id < current.job
                } else {
                    wins = host.id < current.host
                }
                if wins {
                    best = (candidate, rank, job.enqueuedTick, job.id, host.id)
                }
            }
        }
        return best?.placement
    }
}

// MARK: - The policy this kit argues for

/// Fairness as the outer loop, snapshot affinity as the inner one — with a
/// bounded delay before fairness is allowed to force an expensive placement.
///
/// ### The claim
///
/// Affinity and fairness are not two objectives to be traded off with a tuning
/// knob. They answer different questions. *Which tenant* is served next is a
/// fairness question and nothing else — letting cache warmth answer it starves
/// the small tenant, because a small tenant is by definition the one whose
/// snapshots are rarely resident. *Which of that tenant's jobs, on which host*
/// is purely an efficiency question — answering it by queue order throws away
/// the only cheap thing the farm has.
///
/// ### Why layering alone is not enough
///
/// That layering, implemented literally, does not work, and the measurement in
/// `PlacementPolicyTests` is what showed it: a plain DRR-outer/affinity-inner
/// policy lands a warm hit rate barely better than strict round-robin. The
/// reason is that the inner loop can only choose among *one tenant's* jobs, and
/// the expensive decision — whether to rewrite a host's 6 GiB base image — is
/// forced by which tenant's turn it is. Round-robin across tenants that live on
/// different OS builds makes hosts ping-pong between them, and no amount of
/// cleverness inside a single tenant's turn can undo that.
///
/// ### Delay scheduling
///
/// The fix is Zaharia et al.'s delay scheduling, from the Hadoop Fair Scheduler:
/// a tenant whose turn has come but whose only available host would need an OS
/// flip *passes*, keeps its credit, and waits for a host that already holds its
/// build. It may only pass `maxSkips` times in a row; after that it is served
/// cold regardless, which is what preserves the starvation bound. The farm gives
/// up a few seconds of idle host time to avoid a three-minute restore, and the
/// fleet self-organises: hosts settle onto OS builds instead of thrashing
/// between them.
///
/// `maxSkips: 0` reduces this to the naive layering described above, and there
/// is a test that asserts the hit rate collapses when you do that — so the
/// delay-scheduling component is load-bearing by measurement, not by assertion.
public struct LayeredAffinityFairPolicy: PlacementPolicy {
    public let name = "Layered (DRR + delay scheduling)"

    /// Consecutive turns a tenant may pass up before it is served cold anyway.
    /// This is the fairness bound: no tenant is ever delayed more than this many
    /// of its own turns.
    ///
    /// The default of 24 comes from an actual sweep on the reference workload,
    /// shipped as `testSkipBoundSweepShapeIsStable`. The shape is not the tidy
    /// monotonic trade-off theory suggests, and the numbers are worth stating:
    ///
    /// ```
    /// maxSkips   started   warm    restore   worst wait   worst-served
    ///        0       142    38%    137 min       1080 s   checkout
    ///        8       222    54%     68 min        364 s   checkout
    ///       12       220    58%     67 min        404 s   checkout
    ///       24       240    62%     48 min        348 s   checkout   <- default
    ///       40       238    60%     48 min        660 s   payments
    ///       64       235    60%     48 min        858 s   payments
    /// ```
    ///
    /// Below the knee the metrics move together rather than trading off, so
    /// there is no tuning dilemma there — 24 simply dominates every smaller
    /// value on all five. The genuine trade-off only appears *past* it: from
    /// about 28 onward the worst-served tenant flips to the smallest one and
    /// its wait climbs without bound, which is delay scheduling degenerating
    /// into the starvation it exists to prevent.
    public let maxSkips: Int

    /// The warmth a placement must already have for the tenant to take it
    /// without hesitating. `.os` means "this host already runs my OS build" —
    /// the boundary that separates a ~30 second restore from a ~3 minute one.
    public let acceptThreshold: SnapshotLayer

    public init(maxSkips: Int = 24, acceptThreshold: SnapshotLayer = .os) {
        self.maxSkips = max(0, maxSkips)
        self.acceptThreshold = acceptThreshold
    }

    public func nextPlacement(in state: inout SchedulerState) -> Placement? {
        // No idle host means no decision to make. Returning early matters for
        // correctness, not just speed: crediting quanta on a tick where nothing
        // could have been dispatched inflates every tenant's deficit equally and
        // silently dissolves the fairness bound.
        guard state.hasIdleHost, state.queuedJobCount > 0 else { return nil }
        guard !state.tenantOrder.isEmpty else { return nil }

        let tenantCount = state.tenantOrder.count
        // Two full sweeps: one to credit quanta, one to dispatch for a tenant
        // whose deficit only became sufficient during the first.
        let maxVisits = Saturating.multiply(tenantCount, 2)

        var visits = 0
        while visits < maxVisits {
            visits += 1

            let cursor = Saturating.remainder(state.roundRobinCursor, tenantCount)
            // `remainder` of a non-negative cursor by a positive count is in
            // 0..<tenantCount, so this subscript is in range.
            let tenant = state.tenantOrder[max(0, cursor)]
            state.roundRobinCursor = Saturating.remainder(Saturating.add(cursor, 1), tenantCount)

            let backlog = state.queue(for: tenant)
            guard !backlog.isEmpty else {
                // Standard DRR: an empty queue forfeits credit. Without this a
                // tenant banks deficit while idle and bursts on return.
                state.deficits[tenant] = 0
                state.affinitySkips[tenant] = 0
                continue
            }

            let credited = Saturating.add(
                state.deficits[tenant] ?? 0,
                state.quantum(for: tenant)
            )
            let deficit = min(credited, state.deficitCeiling(for: tenant))
            state.deficits[tenant] = deficit

            let affordable = backlog.filter { $0.serviceTicks <= deficit }
            guard !affordable.isEmpty else { continue }

            guard let placement = state.bestAffinityPlacement(among: affordable) else { continue }
            guard let job = backlog.first(where: { $0.id == placement.job }) else { continue }

            let warmth = placement.warmDepth?.rawValue ?? -1
            if warmth >= acceptThreshold.rawValue {
                state.affinitySkips[tenant] = 0
                state.deficits[tenant] = Saturating.subtract(deficit, job.serviceTicks)
                return placement
            }

            let skips = state.affinitySkips[tenant] ?? 0
            if skips < maxSkips {
                // Pass, keeping the credit. The tenant is still owed this turn;
                // it is declining to spend it on a host that would have to
                // rewrite its base image.
                state.affinitySkips[tenant] = Saturating.add(skips, 1)
                continue
            }

            // Waited long enough. Take the cold placement — this branch is what
            // bounds the wait, and removing it is what turns delay scheduling
            // into starvation.
            state.affinitySkips[tenant] = 0
            state.deficits[tenant] = Saturating.subtract(deficit, job.serviceTicks)
            return placement
        }
        return nil
    }
}

// MARK: - Baseline: cache team's answer

/// Always dispatch whichever queued job is warmest, on whichever host holds it.
///
/// Maximises snapshot hit rate by construction and is completely indifferent to
/// who is waiting. The failure mode is not subtle once you look for it: the
/// tenants whose snapshots are resident are the ones that just ran, so warmth
/// is a proxy for "has been running a lot", and this policy hands the farm to
/// whoever already had it. A small tenant's chain is never resident, so it never
/// wins a comparison, so it never runs, so its chain is never resident.
public struct AffinityFirstPolicy: PlacementPolicy {
    public let name = "Affinity-first (no fairness)"

    public init() {}

    public func nextPlacement(in state: inout SchedulerState) -> Placement? {
        guard state.hasIdleHost else { return nil }
        let allQueued = state.tenantOrder.flatMap { state.queue(for: $0) }
        guard !allQueued.isEmpty else { return nil }
        return state.bestAffinityPlacement(among: allQueued)
    }
}

// MARK: - Baseline: platform team's answer

/// Strict round-robin over tenants, oldest job first, next host in rotation.
///
/// Perfectly fair and perfectly cache-hostile. Rotating hosts spreads each
/// tenant's chains across the whole fleet, so every host ends up holding a
/// little of everything, every store runs at capacity, and the eviction pressure
/// this creates is self-inflicted: the same total working set would have fit
/// comfortably if each chain had stayed on fewer hosts.
public struct StrictFairnessPolicy: PlacementPolicy {
    public let name = "Strict fairness (no affinity)"

    public init() {}

    public func nextPlacement(in state: inout SchedulerState) -> Placement? {
        guard state.hasIdleHost, state.queuedJobCount > 0 else { return nil }
        let tenantCount = state.tenantOrder.count
        guard tenantCount > 0, !state.hosts.isEmpty else { return nil }

        var visits = 0
        while visits < tenantCount {
            visits += 1

            let cursor = Saturating.remainder(state.roundRobinCursor, tenantCount)
            let tenant = state.tenantOrder[max(0, cursor)]
            state.roundRobinCursor = Saturating.remainder(Saturating.add(cursor, 1), tenantCount)

            let backlog = state.queue(for: tenant)
            guard let job = backlog.min(by: { lhs, rhs in
                lhs.enqueuedTick != rhs.enqueuedTick
                    ? lhs.enqueuedTick < rhs.enqueuedTick
                    : lhs.id < rhs.id
            }) else { continue }

            guard let chain = state.catalog.chain(for: job.snapshot) else { continue }
            let chainBytes = Saturating.sum(chain.map(\.bytes))

            // Next idle host in rotation, scanning at most one full lap.
            let hostCount = state.hosts.count
            var offset = 0
            while offset < hostCount {
                let index = Saturating.remainder(
                    Saturating.add(Saturating.remainder(state.hostCursor, hostCount), offset),
                    hostCount
                )
                offset += 1
                // `remainder` by a positive `hostCount` of non-negative operands
                // lands in 0..<hostCount, so this subscript is in range.
                let host = state.hosts[max(0, index)]
                guard host.isIdle(at: state.tick), chainBytes <= host.store.capacityBytes else {
                    continue
                }
                state.hostCursor = Saturating.remainder(Saturating.add(index, 1), hostCount)
                return Placement(
                    job: job.id,
                    host: host.id,
                    warmDepth: host.store.deepestResidentLayer(for: job.snapshot)
                )
            }
        }
        return nil
    }
}
