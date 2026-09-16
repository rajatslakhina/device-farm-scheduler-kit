import XCTest
@testable import DeviceFarmScheduler

/// The central claim of this kit, measured on one fixed workload.
///
/// All three policies replay the *same* arrival trace. A difference in the
/// reports is therefore a difference in the policies and nothing else — which is
/// the only reason any of these numbers mean anything.
final class PlacementPolicyTests: XCTestCase {

    private func reports() -> (layered: PolicyReport, affinity: PolicyReport, fair: PolicyReport) {
        let all = FarmSimulation.compareShippedPolicies(spec: ReferenceWorkload.makeSpec())
        XCTAssertEqual(all.count, 3)
        // Falling back to the first element would silently compare a policy
        // against itself, so index presence is asserted rather than defaulted.
        guard all.indices.contains(2) else {
            fatalError("compareShippedPolicies must return exactly three reports")
        }
        return (all[0], all[1], all[2])
    }

    /// Determinism against *fixed expected values*, not against a second call.
    ///
    /// Comparing two calls in one process is the classic vacuous determinism
    /// test: it passes for any pure function, including one that ignores the
    /// seed entirely, and it cannot detect the hazard this codebase actually
    /// defends against — Swift's per-process Dictionary hash seed is constant,
    /// so dictionary-iteration nondeterminism is invisible within a process.
    /// Pinning the first and last job of the trace catches a changed generator,
    /// a changed seed, and a changed weighting; it is checked across processes
    /// by CI running the suite on both Linux and macOS.
    func testArrivalTraceMatchesFixedExpectedValues() {
        let jobs = ReferenceWorkload.makeSpec().arrivalTrace().flatMap { $0 }
        XCTAssertEqual(jobs.count, 251)

        guard let first = jobs.first, let last = jobs.last else {
            return XCTFail("workload produced no jobs")
        }
        XCTAssertEqual(first.id, JobID(0))
        XCTAssertEqual(first.tenant, ReferenceWorkload.search)
        XCTAssertEqual(first.snapshot, ReferenceWorkload.searchEmpty)
        XCTAssertEqual(first.serviceTicks, 27)
        XCTAssertEqual(first.enqueuedTick, 0)

        XCTAssertEqual(last.id, JobID(250))
        XCTAssertEqual(last.enqueuedTick, 1_770)

        // Ordering within a tick is part of the contract: a stable schedule
        // needs a stable trace, not merely a reproducible multiset.
        XCTAssertEqual(jobs.map(\.id.rawValue), Array(0..<251))
    }

    /// The three shipped policies must genuinely see one shared trace. This
    /// drives `compareShippedPolicies` — the thing that does the sharing — and
    /// checks the jobs each policy accounted for add up to the same workload.
    func testAllThreePoliciesAccountForTheSameWorkload() {
        let spec = ReferenceWorkload.makeSpec()
        let total = spec.arrivalTrace().flatMap { $0 }.count
        for report in FarmSimulation.compareShippedPolicies(spec: spec) {
            XCTAssertEqual(
                Saturating.add(report.dispatched, report.jobsLeftQueued), total,
                "\(report.policyName) lost or invented jobs"
            )
        }
    }

    /// Affinity-first is expected to punish the small tenant. The harm shows up
    /// as tail latency rather than as total starvation — the farm does get to
    /// `payments` eventually, it just gets to it last, every time.
    ///
    /// If this ever stops failing in that direction, the workload has stopped
    /// exercising the pathology and every other claim here is worthless.
    func testAffinityFirstPushesTheSmallTenantIntoTheTail() {
        let (layered, affinity, _) = reports()
        let small = ReferenceWorkload.payments

        XCTAssertGreaterThan(
            affinity.worstWait(for: small),
            layered.worstWait(for: small),
            "affinity-first was expected to make \(small) wait longer than the layered policy"
        )
        // The crisp qualitative difference: under affinity-first the smallest
        // tenant is the worst-served one; under the layered policy it is not.
        XCTAssertEqual(
            affinity.worstTenant, small,
            "affinity-first was expected to leave the small tenant worst-served"
        )
        XCTAssertNotEqual(
            layered.worstTenant, small,
            "the layered policy left the small tenant worst-served"
        )
    }

    /// Strict fairness is expected to buy that fairness with restore time.
    func testStrictFairnessPaysMoreRestoreTimeThanLayered() {
        let (layered, _, fair) = reports()
        XCTAssertGreaterThan(
            fair.totalRestoreMillis,
            layered.totalRestoreMillis,
            "strict fairness was expected to pay more restore time than the layered policy"
        )
        XCTAssertLessThan(
            fair.warmHitRatePercent,
            layered.warmHitRatePercent,
            "strict fairness was expected to land a lower warm hit rate"
        )
        XCTAssertLessThan(
            fair.dispatched,
            layered.dispatched,
            "restore time spent on OS flips should cost strict fairness real throughput"
        )
    }

    /// Each baseline loses a different column; the layered policy has to beat
    /// each one on the column that baseline loses.
    func testLayeredPolicyBeatsEachBaselineOnTheColumnThatBaselineLoses() {
        let (layered, affinity, fair) = reports()

        // Against strict fairness: efficiency.
        XCTAssertGreaterThan(layered.warmHitRatePercent, fair.warmHitRatePercent)
        XCTAssertLessThan(layered.totalRestoreMillis, fair.totalRestoreMillis)

        // Against affinity-first: fairness.
        XCTAssertLessThan(layered.worstTenantWaitTicks, affinity.worstTenantWaitTicks)

        // And it serves every tenant, which is the property affinity-first lacks.
        for tenant in [
            ReferenceWorkload.checkout, ReferenceWorkload.search, ReferenceWorkload.payments,
        ] {
            XCTAssertGreaterThan(
                layered.dispatched(for: tenant), 0,
                "layered policy never served \(tenant)"
            )
        }
    }

    /// The honest other half: fairness is not free. Affinity-first keeps a
    /// higher warm hit rate, and pretending otherwise would be the easiest way
    /// to make this kit's headline claim look better than it is.
    func testAffinityFirstStillWinsTheHitRateColumn() {
        let (layered, affinity, _) = reports()
        XCTAssertGreaterThan(
            affinity.warmHitRatePercent,
            layered.warmHitRatePercent,
            "if the layered policy ever wins this column outright, the README's "
                + "\"fairness costs hit rate\" framing needs rewriting"
        )
    }

    func testProtectedSmallTenantIsNotTheOneLeftHoldingTheBacklog() {
        let (layered, _, _) = reports()
        XCTAssertLessThanOrEqual(
            layered.stillQueued(for: ReferenceWorkload.payments),
            layered.stillQueued(for: ReferenceWorkload.checkout),
            "the protected small tenant ended up with the largest backlog"
        )
    }

    // MARK: - Delay scheduling is load-bearing

    /// `maxSkips: 0` is the naive DRR-outer/affinity-inner policy — the one that
    /// sounds right and does not work. Shipping this comparison as a test is the
    /// only way "delay scheduling is what makes the layering pay" is a measured
    /// claim rather than a paragraph of prose.
    func testRemovingDelaySchedulingCollapsesTheHitRate() {
        let spec = ReferenceWorkload.makeSpec()
        let trace = spec.arrivalTrace()

        let tuned = FarmSimulation.run(
            spec: spec, policy: LayeredAffinityFairPolicy(), trace: trace
        )
        let naive = FarmSimulation.run(
            spec: spec, policy: LayeredAffinityFairPolicy(maxSkips: 0), trace: trace
        )
        let fair = FarmSimulation.run(
            spec: spec, policy: StrictFairnessPolicy(), trace: trace
        )

        XCTAssertLessThan(
            naive.warmHitRatePercent, tuned.warmHitRatePercent,
            "removing delay scheduling should cost warm hits"
        )
        XCTAssertGreaterThan(
            naive.totalRestoreMillis, tuned.totalRestoreMillis,
            "removing delay scheduling should cost restore time"
        )
        XCTAssertLessThan(
            naive.dispatched, tuned.dispatched,
            "removing delay scheduling should cost throughput"
        )
        // And the point of the comparison: without it, layering buys almost
        // nothing over plain round-robin.
        XCTAssertLessThan(
            abs(naive.warmHitRatePercent - fair.warmHitRatePercent),
            tuned.warmHitRatePercent - fair.warmHitRatePercent,
            "naive layering should sit close to strict fairness, not close to the tuned policy"
        )
    }

    /// The skip bound's full sweep, including the direction of the real
    /// trade-off, is pinned in `GoldenNumbersTests.testSkipBoundSweepShapeIsStable`.
    /// An earlier version of this file compared exactly two settings and
    /// presented the result as a law; the sweep showed the curve is not
    /// monotonic below the knee, so the two-point version was measuring a
    /// coincidence.

    /// `acceptThreshold` has to actually change what gets accepted.
    ///
    /// Asserting only that the farm still dispatches something would pass for an
    /// implementation that ignored the parameter entirely, so this checks the
    /// property the parameter names: a stricter threshold refuses more warm-ish
    /// placements, which shows up as strictly more skipping and therefore fewer
    /// runs started in the same window.
    func testStricterAcceptThresholdRefusesMorePlacements() {
        let spec = ReferenceWorkload.makeSpec()
        let trace = spec.arrivalTrace()

        let osThreshold = FarmSimulation.run(
            spec: spec,
            policy: LayeredAffinityFairPolicy(maxSkips: 24, acceptThreshold: .os),
            trace: trace
        )
        let accountThreshold = FarmSimulation.run(
            spec: spec,
            policy: LayeredAffinityFairPolicy(maxSkips: 24, acceptThreshold: .account),
            trace: trace
        )

        XCTAssertNotEqual(
            accountThreshold, osThreshold,
            "the two thresholds produced identical runs — acceptThreshold is being ignored"
        )
        XCTAssertLessThan(
            accountThreshold.dispatched, osThreshold.dispatched,
            "holding out for a fully-seeded host should cost throughput"
        )
        // And it must not deadlock: the skip bound still forces progress.
        XCTAssertGreaterThan(accountThreshold.dispatched, 0)
    }

    // MARK: - Edge cases

    func testNoHostsProducesNoPlacementsAndDoesNotSpin() {
        var state = SchedulerState(
            hosts: [],
            catalog: ReferenceWorkload.makeCatalog(),
            quanta: [ReferenceWorkload.checkout: 10]
        )
        state.enqueue(
            Job(
                id: JobID(1),
                tenant: ReferenceWorkload.checkout,
                snapshot: ReferenceWorkload.checkoutBasket,
                serviceTicks: 5,
                enqueuedTick: 0
            )
        )
        var layered = LayeredAffinityFairPolicy()
        XCTAssertNil(layered.nextPlacement(in: &state))
        var affinity = AffinityFirstPolicy()
        XCTAssertNil(affinity.nextPlacement(in: &state))
        var fair = StrictFairnessPolicy()
        XCTAssertNil(fair.nextPlacement(in: &state))
    }

    func testEmptyQueueProducesNoPlacements() {
        var state = SchedulerState(
            hosts: [
                Host(
                    id: HostID("h0"),
                    store: SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
                )
            ],
            catalog: ReferenceWorkload.makeCatalog(),
            quanta: [ReferenceWorkload.checkout: 10]
        )
        var layered = LayeredAffinityFairPolicy()
        XCTAssertNil(layered.nextPlacement(in: &state))
    }

    func testIdleTenantForfeitsBankedDeficit() {
        var state = SchedulerState(
            // Too small to hold any chain, so the sweep visits every tenant
            // instead of returning on the first placeable one.
            hosts: [Host(id: HostID("h0"), store: SnapshotStore(capacityBytes: 1_024))],
            catalog: ReferenceWorkload.makeCatalog(),
            quanta: [ReferenceWorkload.checkout: 50, ReferenceWorkload.payments: 50]
        )
        state.deficits[ReferenceWorkload.payments] = 500

        state.enqueue(
            Job(
                id: JobID(1),
                tenant: ReferenceWorkload.checkout,
                snapshot: ReferenceWorkload.checkoutBasket,
                serviceTicks: 10,
                enqueuedTick: 0
            )
        )

        var policy = LayeredAffinityFairPolicy()
        _ = policy.nextPlacement(in: &state)
        XCTAssertEqual(
            state.deficits[ReferenceWorkload.payments], 0,
            "an idle tenant must forfeit banked deficit rather than bursting on return"
        )
    }

    func testDeficitIsCappedAtTheCeiling() {
        let quantum = 50
        var state = SchedulerState(
            // A host far too small to hold the chain, so the job is never
            // placed and the deficit has nothing to spend itself on.
            hosts: [Host(id: HostID("h0"), store: SnapshotStore(capacityBytes: 1_024))],
            catalog: ReferenceWorkload.makeCatalog(),
            quanta: [ReferenceWorkload.checkout: quantum],
            deficitCeilingMultiplier: 2
        )
        state.enqueue(
            Job(
                id: JobID(1),
                tenant: ReferenceWorkload.checkout,
                snapshot: ReferenceWorkload.checkoutBasket,
                serviceTicks: 10,
                enqueuedTick: 0
            )
        )

        var policy = LayeredAffinityFairPolicy()
        for _ in 0..<50 { _ = policy.nextPlacement(in: &state) }

        XCTAssertEqual(
            state.deficits[ReferenceWorkload.checkout],
            quantum * 2,
            "deficit must saturate at the ceiling instead of accumulating without bound"
        )
    }

    /// The permanent-starvation bug the stretching ceiling exists to prevent.
    /// With a fixed `quantum × multiplier` ceiling, a job costing more than that
    /// is skipped on every round forever while still appearing merely "queued".
    func testOversizedJobIsEventuallyDispatchedRatherThanStarvedForever() {
        let quantum = 50
        var state = SchedulerState(
            hosts: [
                Host(
                    id: HostID("h0"),
                    store: SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
                )
            ],
            catalog: ReferenceWorkload.makeCatalog(),
            quanta: [ReferenceWorkload.checkout: quantum],
            deficitCeilingMultiplier: 2
        )
        // 400 is far above the base ceiling of 50 × 2 = 100.
        let oversized = 400
        state.enqueue(
            Job(
                id: JobID(1),
                tenant: ReferenceWorkload.checkout,
                snapshot: ReferenceWorkload.checkoutBasket,
                serviceTicks: oversized,
                enqueuedTick: 0
            )
        )
        XCTAssertGreaterThanOrEqual(
            state.deficitCeiling(for: ReferenceWorkload.checkout), oversized,
            "the ceiling must stretch to the largest waiting job"
        )

        var policy = LayeredAffinityFairPolicy()
        var placed: Placement?
        for _ in 0..<64 where placed == nil {
            placed = policy.nextPlacement(in: &state)
        }
        XCTAssertNotNil(placed, "an oversized job was never dispatched")
    }

    func testJobTooLargeForAnyHostIsNeverPlaced() {
        var state = SchedulerState(
            hosts: [Host(id: HostID("h0"), store: SnapshotStore(capacityBytes: 1_024))],
            catalog: ReferenceWorkload.makeCatalog(),
            quanta: [ReferenceWorkload.checkout: 100]
        )
        state.enqueue(
            Job(
                id: JobID(1),
                tenant: ReferenceWorkload.checkout,
                snapshot: ReferenceWorkload.checkoutBasket,
                serviceTicks: 5,
                enqueuedTick: 0
            )
        )
        var policy = LayeredAffinityFairPolicy()
        XCTAssertNil(
            policy.nextPlacement(in: &state),
            "a chain that cannot fit on any host must not be placed"
        )
        XCTAssertEqual(state.queuedJobCount, 1, "the job must stay queued, not vanish")
    }

    func testUnknownTenantIsRegisteredRatherThanDropped() {
        var state = SchedulerState(
            hosts: [
                Host(
                    id: HostID("h0"),
                    store: SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
                )
            ],
            catalog: ReferenceWorkload.makeCatalog(),
            quanta: [ReferenceWorkload.checkout: 100]
        )
        let stranger = TenantID("brand-new-repo")
        state.enqueue(
            Job(
                id: JobID(9),
                tenant: stranger,
                snapshot: ReferenceWorkload.searchEmpty,
                serviceTicks: 10,
                enqueuedTick: 0
            )
        )
        XCTAssertTrue(state.tenantOrder.contains(stranger))
        XCTAssertEqual(state.queue(for: stranger).count, 1)

        // `maxSkips: 0` so the assertion is about registration, not about delay
        // scheduling correctly declining a cold host on an empty fleet.
        var policy = LayeredAffinityFairPolicy(maxSkips: 0)
        XCTAssertNotNil(policy.nextPlacement(in: &state))
    }

    func testDispatchRejectsAStalePlacement() {
        var state = SchedulerState(
            hosts: [
                Host(
                    id: HostID("h0"),
                    store: SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
                )
            ],
            catalog: ReferenceWorkload.makeCatalog(),
            quanta: [ReferenceWorkload.checkout: 100]
        )
        let ghost = Placement(job: JobID(404), host: HostID("h0"), warmDepth: nil)
        XCTAssertNil(state.dispatch(ghost))

        let wrongHost = Placement(job: JobID(1), host: HostID("nope"), warmDepth: nil)
        XCTAssertNil(state.dispatch(wrongHost))
    }

    /// Audited after *every* tick, not just at the end.
    ///
    /// An end-state-only check is the exact weakness the store's own
    /// differential test identifies and avoids: a later admission restores
    /// whatever was orphaned, so a run that spent most of its life holding
    /// unbootable layers can still finish with a clean resident set.
    func testNoHostEverHoldsAnInvalidResidentSet() {
        let spec = ReferenceWorkload.makeSpec()
        var state = spec.makeState()
        let trace = spec.arrivalTrace()
        var policy = LayeredAffinityFairPolicy()
        var auditedTicks = 0

        for tick in 0..<spec.horizonTicks {
            state.advance(to: tick)
            if trace.indices.contains(tick) { state.enqueue(contentsOf: trace[tick]) }
            var guardCounter = 0
            while guardCounter < spec.hostCount {
                guardCounter += 1
                guard let placement = policy.nextPlacement(in: &state),
                      state.dispatch(placement) != nil else { break }
            }

            for host in state.hosts {
                let violations = SnapshotStoreAudit.violations(of: host.store)
                if !violations.isEmpty {
                    return XCTFail("\(host.id) at tick \(tick): \(violations)")
                }
            }
            auditedTicks += 1
        }

        XCTAssertEqual(auditedTicks, spec.horizonTicks, "the audit loop exited early")
    }
}
