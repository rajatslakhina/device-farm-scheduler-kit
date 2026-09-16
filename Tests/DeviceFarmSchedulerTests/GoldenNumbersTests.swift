import XCTest
@testable import DeviceFarmScheduler

/// Every number quoted in the README, pinned.
///
/// The rest of the suite asserts *orderings* — this policy beats that one on
/// this column — which is the right shape for the claims being made but leaves
/// the actual figures free to drift. A README that says "58%" while the code now
/// produces 44% is a broken README that CI reports as green, and "everything
/// below comes from the test suite" becomes a lie the moment nothing checks it.
///
/// So these are golden values. If one changes, this file fails, and whoever
/// changed it has to update the prose in the same commit. That is the entire
/// point; there is no cleverness here.
final class GoldenNumbersTests: XCTestCase {

    // MARK: - The 8-host reference workload

    private func referenceReports() -> [PolicyReport] {
        FarmSimulation.compareShippedPolicies(spec: ReferenceWorkload.makeSpec())
    }

    func testWorkloadShapeIsPinned() {
        let spec = ReferenceWorkload.makeSpec()
        let trace = spec.arrivalTrace()
        XCTAssertEqual(trace.flatMap { $0 }.count, 251, "README: \"251 runs\"")
        XCTAssertEqual(spec.hostCount, 8, "README: \"8 hosts\"")
        XCTAssertEqual(spec.horizonTicks, 1_800, "README: \"30-minute window\"")
        XCTAssertEqual(trace.filter { !$0.isEmpty }.count, 60, "README: 60 bursts")
        XCTAssertEqual(
            Set(trace.filter { !$0.isEmpty }.map(\.count)).sorted(), [2, 3, 4, 5, 6],
            "README: \"bursts of 2-6\""
        )
    }

    func testLayeredPolicyNumbersArePinned() {
        guard let r = referenceReports().first else { return XCTFail("no reports") }
        XCTAssertEqual(r.dispatched, 240, "README table: runs started")
        XCTAssertEqual(r.warmHitRatePercent, 62, "README table: warm hit rate")
        XCTAssertEqual(r.totalRestoreMillis / 60_000, 48, "README table: restore paid (min)")
        XCTAssertEqual(r.worstTenantWaitTicks, 348, "README table: worst wait")
        XCTAssertEqual(r.worstTenant, ReferenceWorkload.checkout, "README: worst-served tenant")
        XCTAssertEqual(r.jobsLeftQueued, 11)
        XCTAssertEqual(r.worstWait(for: ReferenceWorkload.payments), 344)
        XCTAssertEqual(r.dispatched(for: ReferenceWorkload.payments), 18)
    }

    func testAffinityFirstNumbersArePinned() {
        let reports = referenceReports()
        guard reports.indices.contains(1) else { return XCTFail("no affinity report") }
        let r = reports[1]
        XCTAssertEqual(r.dispatched, 248)
        XCTAssertEqual(r.warmHitRatePercent, 83, "README table: affinity-first hit rate")
        XCTAssertEqual(r.totalRestoreMillis / 60_000, 49)
        XCTAssertEqual(r.worstTenantWaitTicks, 659, "README table: affinity-first worst wait")
        XCTAssertEqual(
            r.worstTenant, ReferenceWorkload.payments,
            "README: under affinity-first the SMALLEST tenant is the worst-served one"
        )
    }

    func testStrictFairnessNumbersArePinned() {
        let reports = referenceReports()
        guard reports.indices.contains(2) else { return XCTFail("no fairness report") }
        let r = reports[2]
        XCTAssertEqual(r.dispatched, 140)
        XCTAssertEqual(r.warmHitRatePercent, 25, "README table: strict fairness hit rate")
        XCTAssertEqual(r.totalRestoreMillis / 60_000, 139)
        XCTAssertEqual(r.worstTenantWaitTicks, 1_080)
        XCTAssertEqual(r.worstTenant, ReferenceWorkload.checkout)
    }

    func testNaiveLayeringNumbersArePinned() {
        let spec = ReferenceWorkload.makeSpec()
        let r = FarmSimulation.run(
            spec: spec, policy: LayeredAffinityFairPolicy(maxSkips: 0), trace: spec.arrivalTrace()
        )
        XCTAssertEqual(r.dispatched, 142)
        XCTAssertEqual(r.warmHitRatePercent, 38, "README pull-quote: naive layering lands 38%")
        XCTAssertEqual(r.totalRestoreMillis / 60_000, 137)
        XCTAssertEqual(r.worstTenantWaitTicks, 1_080)
    }

    /// The README's headline sentence is an arithmetic claim about two other
    /// numbers. Checking the subtraction is cheap and it is exactly the sort of
    /// thing that goes stale silently.
    func testPullQuoteArithmeticHolds() {
        let spec = ReferenceWorkload.makeSpec()
        let reports = referenceReports()
        guard let layered = reports.first, reports.indices.contains(2) else {
            return XCTFail("no reports")
        }
        let fair = reports[2]
        let naive = FarmSimulation.run(
            spec: spec, policy: LayeredAffinityFairPolicy(maxSkips: 0), trace: spec.arrivalTrace()
        )
        XCTAssertEqual(
            naive.warmHitRatePercent - fair.warmHitRatePercent, 13,
            "README: naive layering is thirteen points above pure round-robin"
        )
        XCTAssertEqual(
            reports.indices.contains(1) ? reports[1].warmHitRatePercent - naive.warmHitRatePercent : 0,
            45,
            "README: and 45 points below what the cache can give you"
        )
        XCTAssertEqual(
            layered.warmHitRatePercent - naive.warmHitRatePercent, 24,
            "README: delay scheduling takes 38% to 62%"
        )
    }

    /// The README's sharpest claim: the layered policy takes more than twice as
    /// many misses as affinity-first and still pays less restore time, because
    /// delay scheduling changes *which* misses you take rather than how many.
    func testLayeredTakesMoreButCheaperMissesThanAffinityFirst() {
        let reports = referenceReports()
        guard let layered = reports.first, reports.indices.contains(1) else {
            return XCTFail("no reports")
        }
        let affinity = reports[1]

        XCTAssertEqual(layered.coldDispatches, 91, "README: 91 misses")
        XCTAssertEqual(affinity.coldDispatches, 42, "README: against 42")
        XCTAssertGreaterThan(layered.coldDispatches, affinity.coldDispatches * 2)

        XCTAssertLessThan(
            layered.totalRestoreMillis, affinity.totalRestoreMillis,
            "README: more misses, less restore time"
        )

        let layeredAverage = layered.totalRestoreMillis / max(1, layered.coldDispatches)
        let affinityAverage = affinity.totalRestoreMillis / max(1, affinity.coldDispatches)
        XCTAssertEqual(layeredAverage / 1_000, 32, "README: its average miss costs 32 s")
        XCTAssertEqual(affinityAverage / 1_000, 70, "README: affinity-first's costs 70 s")
    }

    // MARK: - Pool sizing

    func testReferenceSizingIsPinned() {
        let histogram = ReferenceWorkload.makeArrivalHistogram()
        XCTAssertEqual(histogram.totalIntervals, 60, "README: 60 observation windows")
        XCTAssertEqual(histogram.counts, [0, 0, 8, 11, 16, 12, 13])
        XCTAssertEqual(histogram.maxObserved, 6)

        let sizing = PoolSizer.size(
            histogram: histogram, model: ReferenceWorkload.makeCostModel()
        )
        XCTAssertEqual(
            sizing.curve.map(\.totalCost), [10_040, 7_820, 5_600, 3_700, 2_240, 1_420, 1_080],
            "README quotes this curve verbatim"
        )
        XCTAssertEqual(sizing.recommendedDepth, 6)
    }

    /// The window is the decision the sizer's whole argument rests on, so the
    /// wrong answer is pinned too — it is what the UI produced before the bug
    /// was found, and pinning it stops the fix from silently regressing.
    func testPerTickBucketingProducesTheWrongAnswer() {
        let spec = ReferenceWorkload.makeSpec()
        let perTick = ArrivalHistogram(trace: spec.arrivalTrace(), windowTicks: 1)
        let sizing = PoolSizer.size(histogram: perTick, model: ReferenceWorkload.makeCostModel())
        XCTAssertEqual(
            sizing.recommendedDepth, 0,
            "bucketing per tick should recommend no warm pool at all — this is the "
                + "failure mode the windowed histogram exists to avoid"
        )
        XCTAssertNotEqual(
            sizing.recommendedDepth,
            PoolSizer.size(
                histogram: ReferenceWorkload.makeArrivalHistogram(),
                model: ReferenceWorkload.makeCostModel()
            ).recommendedDepth,
            "if these ever agree, the window has stopped mattering and the README is wrong"
        )
    }

    // MARK: - The snapshot store differential

    func testStoreDifferentialNumbersArePinned() {
        let catalog = SnapshotStoreTests.differentialCatalogForGolden()
        let trace = SnapshotStoreTests.differentialTraceForGolden()
        XCTAssertEqual(trace.count, 36, "README: \"over 36 mounts\"")

        var naive = NaiveLRUStore(capacityBytes: 8_000)
        var good = SnapshotStore(capacityBytes: 8_000)
        var naiveMillis = 0
        var goodMillis = 0
        var orphanSteps = 0

        for (index, key) in trace.enumerated() {
            let depth = naive.deepestResidentLayer(for: key)?.rawValue ?? -1
            for layer in SnapshotLayer.allCases where layer.rawValue > depth {
                switch layer {
                case .os: naiveMillis += 180_000
                case .app: naiveMillis += 25_000
                case .account: naiveMillis += 6_000
                }
            }
            goodMillis += good.restoreCostMillis(for: key, catalog: catalog)
            naive.admit(key, catalog: catalog, at: index)
            good.admit(key, catalog: catalog, at: index)

            let violations = SnapshotStoreAudit.violations(
                residentIDs: naive.residentIDs, residentBytes: 0, capacityBytes: Int.max
            )
            if !violations.isEmpty { orphanSteps += 1 }
        }

        XCTAssertEqual(naiveMillis, 829_000, "README: global LRU pays 829 s")
        XCTAssertEqual(goodMillis, 640_000, "README: chain-aware pays 640 s")
        XCTAssertEqual(orphanSteps, 33, "README: \"unbootable layers on 33 of 36 steps\"")
        XCTAssertEqual(
            (naiveMillis - goodMillis) * 100 / goodMillis, 29, "README: \"29% more restore time\""
        )
    }

    /// The README says this is a *pressure-regime* result and admits the
    /// chain-aware store is marginally worse at one capacity. Both halves of
    /// that sentence are checked here, so the honesty is enforced rather than
    /// merely intended.
    func testStoreAdvantageIsCapacityDependentAsDocumented() {
        let catalog = SnapshotStoreTests.differentialCatalogForGolden()
        let trace = SnapshotStoreTests.differentialTraceForGolden()

        func restoreCosts(capacity: Int) -> (naive: Int, good: Int) {
            var naive = NaiveLRUStore(capacityBytes: capacity)
            var good = SnapshotStore(capacityBytes: capacity)
            var naiveMillis = 0
            var goodMillis = 0
            for (index, key) in trace.enumerated() {
                let depth = naive.deepestResidentLayer(for: key)?.rawValue ?? -1
                for layer in SnapshotLayer.allCases where layer.rawValue > depth {
                    switch layer {
                    case .os: naiveMillis += 180_000
                    case .app: naiveMillis += 25_000
                    case .account: naiveMillis += 6_000
                    }
                }
                goodMillis += good.restoreCostMillis(for: key, catalog: catalog)
                naive.admit(key, catalog: catalog, at: index)
                good.admit(key, catalog: catalog, at: index)
            }
            return (naiveMillis, goodMillis)
        }

        // Under pressure: chain-aware wins.
        let underPressure = restoreCosts(capacity: 8_000)
        XCTAssertLessThan(underPressure.good, underPressure.naive)

        // With slack, the two converge and the eviction policy stops mattering.
        let roomy = restoreCosts(capacity: 7_300)
        XCTAssertEqual(
            roomy.good, roomy.naive,
            "with a working set that never forces a cross-app eviction, both policies "
                + "should pay identically — this is why the README calls the result "
                + "pressure-regime rather than universal"
        )

        // And at one capacity in the sweep the chain-aware store is worse. The
        // README says so; this is what makes that admission checkable.
        let adverse = restoreCosts(capacity: 9_000)
        XCTAssertGreaterThan(
            adverse.good, adverse.naive,
            "README admits chain-aware loses at one capacity — if that stops being "
                + "true, delete the caveat rather than leaving a false admission"
        )
    }

    // MARK: - The demo app's six-host fleet

    /// The companion app ships a deliberately tighter fleet, and its README
    /// quotes numbers this package produces. Pinned here because the demo repo
    /// has no test target of its own to pin them in.
    func testDemoAppSixHostNumbersArePinned() {
        let reference = ReferenceWorkload.makeSpec()
        let spec = WorkloadSpec(
            tenants: reference.tenants,
            catalog: reference.catalog,
            horizonTicks: reference.horizonTicks,
            hostCount: 6,
            hostCapacityBytes: reference.hostCapacityBytes,
            baseArrivalsPerTick: reference.baseArrivalsPerTick,
            burstEveryTicks: reference.burstEveryTicks,
            burstSize: reference.burstSize,
            burstJitter: reference.burstJitter,
            seed: reference.seed
        )
        let reports = FarmSimulation.compareShippedPolicies(spec: spec)
        guard reports.count == 3 else { return XCTFail("expected three reports") }

        XCTAssertEqual(reports[0].dispatched, 182)
        XCTAssertEqual(reports[0].warmHitRatePercent, 56)
        XCTAssertEqual(reports[0].worstTenantWaitTicks, 752)
        XCTAssertEqual(reports[0].dispatched(for: ReferenceWorkload.payments), 15)

        XCTAssertEqual(reports[1].dispatched, 192)
        XCTAssertEqual(reports[1].warmHitRatePercent, 91, "demo README: a 91% hit rate...")
        XCTAssertEqual(
            reports[1].dispatched(for: ReferenceWorkload.payments), 2,
            "...while the smallest tenant runs twice in thirty minutes"
        )
        XCTAssertEqual(reports[1].stillQueued(for: ReferenceWorkload.payments), 18)
        XCTAssertEqual(reports[1].worstWait(for: ReferenceWorkload.payments), 1_410)
        XCTAssertEqual(reports[1].dispatched(for: ReferenceWorkload.search), 44)
        XCTAssertEqual(reports[1].stillQueued(for: ReferenceWorkload.search), 31)
        XCTAssertEqual(reports[1].worstWait(for: ReferenceWorkload.search), 1_320)
        XCTAssertEqual(reports[1].dispatched(for: ReferenceWorkload.checkout), 146)

        XCTAssertEqual(reports[2].dispatched, 94)
        XCTAssertEqual(reports[2].warmHitRatePercent, 32)
    }

    // MARK: - The skip-bound sweep

    /// `maxSkips: 24` is the shipped default and the README says it came from a
    /// sweep. This is the sweep.
    ///
    /// The shape is the claim, and it is not the tidy monotonic trade-off theory
    /// predicts: below the knee the metrics improve *together*, and the real
    /// trade-off only appears past it, where the smallest tenant becomes the
    /// worst-served one and its wait grows without bound.
    func testSkipBoundSweepShapeIsStable() {
        let spec = ReferenceWorkload.makeSpec()
        let trace = spec.arrivalTrace()

        func run(_ skips: Int) -> PolicyReport {
            FarmSimulation.run(
                spec: spec, policy: LayeredAffinityFairPolicy(maxSkips: skips), trace: trace
            )
        }

        let none = run(0)
        let shipped = run(24)
        let excessive = run(64)

        // The default dominates every smaller value on every metric, which is
        // why there is no trade-off to argue about below the knee.
        for smaller in [0, 8, 12, 20] {
            let other = run(smaller)
            XCTAssertGreaterThanOrEqual(
                shipped.dispatched, other.dispatched,
                "maxSkips 24 should not start fewer runs than \(smaller)"
            )
            XCTAssertGreaterThanOrEqual(
                shipped.warmHitRatePercent, other.warmHitRatePercent,
                "maxSkips 24 should not land a lower hit rate than \(smaller)"
            )
            XCTAssertLessThanOrEqual(
                shipped.totalRestoreMillis, other.totalRestoreMillis,
                "maxSkips 24 should not pay more restore time than \(smaller)"
            )
            XCTAssertLessThanOrEqual(
                shipped.worstTenantWaitTicks, other.worstTenantWaitTicks,
                "maxSkips 24 should not make anyone wait longer than \(smaller)"
            )
        }

        // Past the knee, delay scheduling degenerates into the starvation it
        // exists to prevent — and it lands on the smallest tenant.
        XCTAssertGreaterThan(excessive.worstTenantWaitTicks, shipped.worstTenantWaitTicks)
        XCTAssertEqual(
            excessive.worstTenant, ReferenceWorkload.payments,
            "an unbounded skip budget should starve the small tenant"
        )
        XCTAssertEqual(shipped.worstTenant, ReferenceWorkload.checkout)
        XCTAssertLessThan(
            excessive.dispatched(for: ReferenceWorkload.payments),
            shipped.dispatched(for: ReferenceWorkload.payments)
        )

        // And the floor: removing the mechanism is worse than any setting of it.
        XCTAssertLessThan(none.warmHitRatePercent, shipped.warmHitRatePercent)
    }
}
