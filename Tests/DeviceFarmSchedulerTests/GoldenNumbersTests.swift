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

    /// The README's "answered 'zero' in 97% of buckets" figure, which motivates
    /// the whole observation-window design and was previously unpinned prose.
    func testPerTickBucketsAreEmptyNinetySevenPercentOfTheTime() {
        let trace = ReferenceWorkload.makeSpec().arrivalTrace()
        XCTAssertEqual(trace.count, 1_800)
        let empty = trace.filter(\.isEmpty).count
        XCTAssertEqual(empty, 1_740)
        XCTAssertEqual(empty * 100 / trace.count, 96, "96.7% rounds down to 96, quoted as 97%")
    }

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

        // REFUSAL CLIFF: below ~7 100 a whole chain no longer fits, and
        // `SnapshotStore.admit` refuses it outright rather than evicting toward
        // a resident set that still could not boot. Every mount then pays a full
        // cold restore, and the naive store — which admits partial, unbootable
        // garbage — scores *better* on this metric. That is correct behaviour
        // measured by the wrong yardstick, and the README says so.
        let cliff = restoreCosts(capacity: 7_000)
        XCTAssertEqual(cliff.naive, 871_000)
        XCTAssertEqual(cliff.good, 7_596_000)
        XCTAssertGreaterThan(
            cliff.good, cliff.naive,
            "below the fit threshold the chain-aware store is expected to look worse"
        )

        // STARVED: room for one chain but not a second working set, so neither
        // policy has a choice left and both pay the same. Two distinct tie
        // values here, which an earlier version of this README collapsed into
        // one range: 871 s at 7 100–7 200 and 829 s at 7 300–7 900.
        let starvedHigh = restoreCosts(capacity: 7_100)
        XCTAssertEqual(starvedHigh.good, starvedHigh.naive)
        XCTAssertEqual(starvedHigh.good, 871_000)

        let starved = restoreCosts(capacity: 7_300)
        XCTAssertEqual(
            starved.good, starved.naive,
            "with no room to keep a second working set, eviction policy cannot matter"
        )
        XCTAssertEqual(starved.good, 829_000)

        // PRESSURE: the regime the README's headline number comes from.
        let underPressure = restoreCosts(capacity: 8_000)
        XCTAssertEqual(underPressure.naive, 829_000)
        XCTAssertEqual(underPressure.good, 640_000)
        XCTAssertLessThan(underPressure.good, underPressure.naive)

        // ADVERSE: at one capacity the chain-aware store is genuinely worse.
        // The README admits this; asserting it is what makes the admission
        // checkable rather than decorative.
        let adverse = restoreCosts(capacity: 9_000)
        XCTAssertEqual(adverse.naive, 620_000)
        XCTAssertEqual(adverse.good, 628_000)
        XCTAssertGreaterThan(
            adverse.good, adverse.naive,
            "if chain-aware stops losing here, delete the caveat rather than "
                + "leaving a false admission in the README"
        )

        // And a second win band above it, which is why the curve cannot be
        // summarised as "wins under pressure, loses with slack".
        let aboveAdverse = restoreCosts(capacity: 10_000)
        XCTAssertLessThan(aboveAdverse.good, aboveAdverse.naive)

        // SLACK: genuinely enough room for the whole working set. Here the two
        // converge for the right reason — nothing is ever evicted.
        let roomy = restoreCosts(capacity: 11_000)
        XCTAssertEqual(
            roomy.good, roomy.naive,
            "with room for the entire working set, no eviction happens and the "
                + "policies are indistinguishable"
        )
        XCTAssertEqual(roomy.good, 310_000)
        XCTAssertLessThan(
            roomy.good, underPressure.good,
            "the slack regime should be cheaper than the pressure regime"
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

        // Layered row, every cell the demo README prints.
        XCTAssertEqual(reports[0].dispatched, 182)
        XCTAssertEqual(reports[0].warmHitRatePercent, 56)
        XCTAssertEqual(reports[0].totalRestoreMillis / 60_000, 38)
        XCTAssertEqual(reports[0].worstTenantWaitTicks, 752)
        XCTAssertEqual(reports[0].worstTenant, ReferenceWorkload.checkout)
        XCTAssertEqual(reports[0].dispatched(for: ReferenceWorkload.payments), 15)
        XCTAssertEqual(reports[0].stillQueued(for: ReferenceWorkload.payments), 5)

        // Affinity-first row, including the per-tenant table.
        XCTAssertEqual(reports[1].dispatched, 192)
        XCTAssertEqual(reports[1].warmHitRatePercent, 91, "demo README: a 91% hit rate...")
        XCTAssertEqual(reports[1].totalRestoreMillis / 60_000, 27)
        XCTAssertEqual(reports[1].worstTenantWaitTicks, 1_410)
        XCTAssertEqual(reports[1].worstTenant, ReferenceWorkload.payments)
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
        XCTAssertEqual(reports[1].stillQueued(for: ReferenceWorkload.checkout), 10)
        XCTAssertEqual(reports[1].worstWait(for: ReferenceWorkload.checkout), 496)

        // Strict fairness row.
        XCTAssertEqual(reports[2].dispatched, 94)
        XCTAssertEqual(reports[2].warmHitRatePercent, 32)
        XCTAssertEqual(reports[2].totalRestoreMillis / 60_000, 111)
        XCTAssertEqual(reports[2].worstTenantWaitTicks, 1_320)
        XCTAssertEqual(reports[2].worstTenant, ReferenceWorkload.checkout)

        // The demo README's admission paragraph: the layered run's worst wait
        // exceeds the configured budget, and a tenant exceeds the per-tenant cap.
        let policy = ReferenceWorkload.makeAdmissionPolicy()
        XCTAssertEqual(policy.waitBudgetTicks, 300)
        XCTAssertGreaterThan(
            reports[0].worstTenantWaitTicks, policy.waitBudgetTicks,
            "demo README claims the console reports a wait-budget miss on this fleet"
        )
        XCTAssertEqual(policy.maxQueuedPerTenant, 96)
        XCTAssertEqual(
            reports[2].stillQueued(for: ReferenceWorkload.checkout), 119,
            "demo README: checkout's backlog reaches 119 under strict fairness"
        )
        XCTAssertGreaterThan(
            reports[2].stillQueued(for: ReferenceWorkload.checkout), policy.maxQueuedPerTenant,
            "an unrestricted replay should exceed the quota admission control would enforce"
        )
    }

    /// The naive-layering row's worst-served tenant, which the library README
    /// prints and nothing else pinned.
    func testNaiveLayeringWorstServedTenantIsPinned() {
        let spec = ReferenceWorkload.makeSpec()
        let r = FarmSimulation.run(
            spec: spec, policy: LayeredAffinityFairPolicy(maxSkips: 0), trace: spec.arrivalTrace()
        )
        XCTAssertEqual(r.worstTenant, ReferenceWorkload.checkout)
        XCTAssertEqual(r.jobsLeftQueued, 109)
    }

    // MARK: - The skip-bound sweep

    /// `maxSkips: 24` is the shipped default and the README says it came from a
    /// sweep. This is the sweep — **every** value in `0...32`, not a flattering
    /// subset.
    ///
    /// An earlier version of this test iterated `[0, 8, 12, 20]`, which happen
    /// to be four values the default beats, and concluded the default
    /// "dominates every smaller value". It does not: 21, 22 and 23 all deliver
    /// a better worst-case wait. That is asserted below, so the README's caveat
    /// cannot quietly stop being true. A test that only visits the points which
    /// confirm the claim is the same defect as having no test.
    func testSkipBoundSweepShapeIsStable() {
        let spec = ReferenceWorkload.makeSpec()
        let trace = spec.arrivalTrace()

        func run(_ skips: Int) -> PolicyReport {
            FarmSimulation.run(
                spec: spec, policy: LayeredAffinityFairPolicy(maxSkips: skips), trace: trace
            )
        }

        let sweep = (0...32).map { (skips: $0, report: run($0)) }
        guard let shipped = sweep.first(where: { $0.skips == 24 })?.report else {
            return XCTFail("24 missing from the sweep")
        }

        // The two columns the default genuinely wins, across the whole range.
        for point in sweep where point.skips != 24 {
            XCTAssertGreaterThanOrEqual(
                shipped.dispatched, point.report.dispatched,
                "maxSkips 24 should start the most runs; \(point.skips) started more"
            )
            XCTAssertGreaterThanOrEqual(
                shipped.warmHitRatePercent, point.report.warmHitRatePercent,
                "maxSkips 24 should land the best hit rate; \(point.skips) was higher"
            )
        }
        XCTAssertEqual(shipped.dispatched, 240)
        XCTAssertEqual(shipped.warmHitRatePercent, 62)

        // The two columns it does NOT win. Pinned so the honesty is enforced
        // and cannot quietly drift into an unqualified "dominates".
        let bestWorstWait = sweep.min {
            $0.report.worstTenantWaitTicks < $1.report.worstTenantWaitTicks
        }
        XCTAssertEqual(bestWorstWait?.skips, 23, "23 holds the best worst-case wait")
        XCTAssertEqual(bestWorstWait?.report.worstTenantWaitTicks, 327)
        XCTAssertEqual(shipped.worstTenantWaitTicks, 348)

        let leastRestore = sweep.min { $0.report.totalRestoreMillis < $1.report.totalRestoreMillis }
        XCTAssertEqual(leastRestore?.skips, 30, "30 pays the least restore time")
        XCTAssertEqual(leastRestore?.report.totalRestoreMillis, 2_913_000)
        XCTAssertEqual(shipped.totalRestoreMillis, 2_921_000)
        XCTAssertGreaterThan(
            shipped.totalRestoreMillis, leastRestore?.report.totalRestoreMillis ?? Int.max,
            "the shipped default does not win the restore column either, and the README says so"
        )
        // ...by 8 seconds across a 30-minute window, which is the point: the
        // differences in this band are noise, not a ranking.
        XCTAssertEqual((shipped.totalRestoreMillis - 2_913_000) / 1_000, 8)

        // The curve is noisy rather than monotonic, which is the README's point.
        // If it ever becomes monotonic, the prose describing it as noise is wrong.
        let waits = sweep.filter { (10...24).contains($0.skips) }.map(\.report.worstTenantWaitTicks)
        XCTAssertFalse(
            waits == waits.sorted() || waits == waits.sorted(by: >),
            "worst-case wait over 10...24 was expected to be non-monotonic"
        )

        // Stable at the extremes: mechanism off is worst on every axis.
        guard let off = sweep.first(where: { $0.skips == 0 })?.report else {
            return XCTFail("0 missing from the sweep")
        }
        XCTAssertLessThan(off.warmHitRatePercent, shipped.warmHitRatePercent)
        XCTAssertLessThan(off.dispatched, shipped.dispatched)
        XCTAssertGreaterThan(off.totalRestoreMillis, shipped.totalRestoreMillis)
        XCTAssertGreaterThan(off.worstTenantWaitTicks, shipped.worstTenantWaitTicks)

        // Past ~25 the smallest tenant becomes the worst-served one and stays
        // that way through the range the README describes.
        for skips in 25...32 {
            XCTAssertEqual(
                sweep.first(where: { $0.skips == skips })?.report.worstTenant,
                ReferenceWorkload.payments,
                "at maxSkips \(skips) the small tenant should be worst-served"
            )
        }
        XCTAssertEqual(shipped.worstTenant, ReferenceWorkload.checkout)

        // And a far-out value shows the degeneration the doc comment describes.
        let excessive = run(64)
        XCTAssertEqual(excessive.worstTenant, ReferenceWorkload.payments)
        XCTAssertEqual(excessive.worstTenantWaitTicks, 858)
        XCTAssertLessThan(
            excessive.dispatched(for: ReferenceWorkload.payments),
            shipped.dispatched(for: ReferenceWorkload.payments)
        )
    }
}
