import XCTest
@testable import DeviceFarmScheduler

final class PoolSizerTests: XCTestCase {

    func testEmptyHistogramRecommendsNoWarmHosts() {
        let result = PoolSizer.size(
            histogram: ArrivalHistogram(counts: []),
            model: PoolCostModel(idleHostCostPerInterval: 1, coldStartCostPerJob: 100)
        )
        XCTAssertEqual(result.recommendedDepth, 0)
        XCTAssertEqual(result.curve.count, 1)
    }

    func testAllZeroHistogramRecommendsNoWarmHosts() {
        let result = PoolSizer.size(
            histogram: ArrivalHistogram(counts: [0, 0, 0]),
            model: PoolCostModel(idleHostCostPerInterval: 1, coldStartCostPerJob: 100)
        )
        XCTAssertEqual(result.recommendedDepth, 0)
    }

    /// Hand-computable case: 10 intervals, every one with exactly 4 arrivals.
    /// idle cost 1/host/interval, cold start cost 5.
    ///   depth 0 -> 0 + 40*5 = 200
    ///   depth 1 -> 10 + 30*5 = 160
    ///   depth 2 -> 20 + 20*5 = 120
    ///   depth 3 -> 30 + 10*5 = 80
    ///   depth 4 -> 40 + 0    = 40   <- minimum
    func testKnownAnswerCurve() {
        let histogram = ArrivalHistogram(counts: [0, 0, 0, 0, 10])
        let model = PoolCostModel(idleHostCostPerInterval: 1, coldStartCostPerJob: 5)
        let result = PoolSizer.size(histogram: histogram, model: model)

        XCTAssertEqual(result.curve.map(\.totalCost), [200, 160, 120, 80, 40])
        XCTAssertEqual(result.recommendedDepth, 4)
        XCTAssertEqual(result.minimumCost, 40)
    }

    /// When holding a host is expensive relative to a cold start, the answer
    /// flips to zero — which is the whole reason to evaluate rather than assume.
    func testExpensiveIdleHostsPushTheAnswerToZero() {
        let histogram = ArrivalHistogram(counts: [0, 0, 0, 0, 10])
        let model = PoolCostModel(idleHostCostPerInterval: 100, coldStartCostPerJob: 1)
        let result = PoolSizer.size(histogram: histogram, model: model)
        XCTAssertEqual(result.recommendedDepth, 0)
    }

    func testTieBreaksTowardTheSmallerDepth() {
        // 10 intervals of exactly 2 arrivals; idle 5, cold start 5.
        //   depth 0 -> 0  + 20*5 = 100
        //   depth 1 -> 50 + 10*5 = 100  (tie)
        //   depth 2 -> 100 + 0   = 100  (tie)
        let histogram = ArrivalHistogram(counts: [0, 0, 10])
        let model = PoolCostModel(idleHostCostPerInterval: 5, coldStartCostPerJob: 5)
        let result = PoolSizer.size(histogram: histogram, model: model)
        XCTAssertEqual(result.curve.map(\.totalCost), [100, 100, 100])
        XCTAssertEqual(result.recommendedDepth, 0, "a tie must resolve to the cheaper commitment")
    }

    func testColdStartsAreMonotonicallyNonIncreasingInDepth() {
        let histogram = ReferenceWorkload.makeArrivalHistogram()
        var previous = Int.max
        for depth in 0...max(1, histogram.maxObserved) {
            let value = histogram.expectedColdStarts(atDepth: depth)
            XCTAssertLessThanOrEqual(value, previous, "cold starts rose when depth grew")
            previous = value
        }
        XCTAssertEqual(histogram.expectedColdStarts(atDepth: histogram.maxObserved), 0)
    }

    func testNegativeDepthIsTreatedAsZero() {
        let histogram = ArrivalHistogram(counts: [0, 0, 5])
        XCTAssertEqual(
            histogram.expectedColdStarts(atDepth: -7),
            histogram.expectedColdStarts(atDepth: 0)
        )
    }

    func testObservationInitClampsAndBuckets() {
        let histogram = ArrivalHistogram(observations: [0, 1, 1, 3, -5])
        // The negative observation is clamped to zero, joining the existing zero.
        XCTAssertEqual(histogram.counts, [2, 2, 0, 1])
        XCTAssertEqual(histogram.totalIntervals, 5)
        XCTAssertEqual(histogram.maxObserved, 3)
    }

    func testAbsurdObservationDoesNotAllocateUnbounded() {
        let histogram = ArrivalHistogram(observations: [Int.max, 1])
        XCTAssertLessThanOrEqual(histogram.counts.count, ArrivalHistogram.maxTrackedArrivals + 1)
        XCTAssertEqual(histogram.totalIntervals, 2)
    }

    /// The recommendation has to actually be the cheapest point on the curve it
    /// returns — a check that fails if the search and the reported curve ever
    /// drift apart.
    func testRecommendationIsTheArgminOfItsOwnCurve() {
        let histogram = ReferenceWorkload.makeArrivalHistogram()
        let result = PoolSizer.size(histogram: histogram, model: ReferenceWorkload.makeCostModel())
        guard let cheapest = result.curve.map(\.totalCost).min() else {
            return XCTFail("empty curve")
        }
        XCTAssertEqual(result.minimumCost, cheapest)
        for point in result.curve where point.totalCost == cheapest {
            XCTAssertGreaterThanOrEqual(point.depth, result.recommendedDepth)
        }
    }

    /// A deliberately wrong sizer — "always provision for the worst burst ever
    /// seen" — must come out strictly more expensive. Without this, "the sizer
    /// picks a good depth" is an untested adjective.
    ///
    /// The histogram is deliberately long-tailed: 90 ordinary windows of 4
    /// arrivals and 10 spikes of 20. That tail is the whole reason "provision
    /// for the peak" is tempting, and the whole reason it is wrong — you would
    /// hold 20 hosts warm to serve a shape that occurs 10% of the time.
    func testAlwaysProvisionForPeakIsStrictlyWorseThanTheEvaluatedOptimum() {
        var counts = [Int](repeating: 0, count: 21)
        counts[4] = 90
        counts[20] = 10
        let histogram = ArrivalHistogram(counts: counts)
        let model = PoolCostModel(idleHostCostPerInterval: 10, coldStartCostPerJob: 40)
        let result = PoolSizer.size(histogram: histogram, model: model)

        let peakDepth = histogram.maxObserved
        XCTAssertEqual(peakDepth, 20)
        guard let peakPoint = result.curve.first(where: { $0.depth == peakDepth }) else {
            return XCTFail("peak depth \(peakDepth) missing from the curve")
        }
        XCTAssertLessThan(
            result.minimumCost, peakPoint.totalCost,
            "provisioning for the peak should cost more than the evaluated optimum"
        )
        XCTAssertLessThan(result.recommendedDepth, peakDepth)
    }

    /// The reference workload's own curve, checked for internal consistency
    /// rather than for a particular answer — the answer is a property of the
    /// cost model, and the cost model is the user's to choose.
    func testReferenceWorkloadProducesAUsableCurve() {
        let histogram = ReferenceWorkload.makeArrivalHistogram()
        XCTAssertFalse(histogram.isEmpty)
        let result = PoolSizer.size(histogram: histogram, model: ReferenceWorkload.makeCostModel())
        XCTAssertEqual(result.curve.count, Saturating.add(histogram.maxObserved, 1))
        XCTAssertGreaterThanOrEqual(result.recommendedDepth, 0)
        XCTAssertLessThanOrEqual(result.recommendedDepth, histogram.maxObserved)
    }
}

final class AdmissionControllerTests: XCTestCase {

    private func state(queueing count: Int, tenant: TenantID) -> SchedulerState {
        var state = SchedulerState(
            hosts: [
                Host(
                    id: HostID("h0"),
                    store: SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
                )
            ],
            catalog: ReferenceWorkload.makeCatalog(),
            quanta: [ReferenceWorkload.checkout: 90, ReferenceWorkload.payments: 45]
        )
        for index in 0..<count {
            state.enqueue(
                Job(
                    id: JobID(index),
                    tenant: tenant,
                    snapshot: ReferenceWorkload.checkoutBasket,
                    serviceTicks: 40,
                    enqueuedTick: 0
                )
            )
        }
        return state
    }

    private func job(_ id: Int, tenant: TenantID, snapshot: SnapshotKey) -> Job {
        Job(id: JobID(id), tenant: tenant, snapshot: snapshot, serviceTicks: 40, enqueuedTick: 0)
    }

    func testUnknownSnapshotIsRejectedRatherThanQueuedForever() {
        let controller = AdmissionController(
            policy: AdmissionPolicy(maxQueueDepth: 10, maxQueuedPerTenant: 10, waitBudgetTicks: 100)
        )
        let stranger = SnapshotKey(osBuild: "?", appBuild: "?", accountSeed: "?")
        let decision = controller.decide(
            job(1, tenant: ReferenceWorkload.checkout, snapshot: stranger),
            given: state(queueing: 0, tenant: ReferenceWorkload.checkout)
        )
        XCTAssertEqual(decision, .rejectUnknownSnapshot(stranger))
        XCTAssertFalse(decision.isAdmitted)
        XCTAssertNil(decision.estimatedWaitTicks)
    }

    func testTenantQuotaStopsOneMatrixFillingTheQueue() {
        let controller = AdmissionController(
            policy: AdmissionPolicy(maxQueueDepth: 100, maxQueuedPerTenant: 3, waitBudgetTicks: 1_000)
        )
        let decision = controller.decide(
            job(99, tenant: ReferenceWorkload.checkout, snapshot: ReferenceWorkload.checkoutBasket),
            given: state(queueing: 3, tenant: ReferenceWorkload.checkout)
        )
        XCTAssertEqual(decision, .rejectTenantQuota(queued: 3, limit: 3))
    }

    func testGlobalDepthLimitRejectsEvenWithinTenantQuota() {
        let controller = AdmissionController(
            policy: AdmissionPolicy(maxQueueDepth: 3, maxQueuedPerTenant: 100, waitBudgetTicks: 1_000)
        )
        let decision = controller.decide(
            job(99, tenant: ReferenceWorkload.checkout, snapshot: ReferenceWorkload.checkoutBasket),
            given: state(queueing: 3, tenant: ReferenceWorkload.checkout)
        )
        XCTAssertEqual(decision, .rejectQueueFull(depth: 3, limit: 3))
    }

    func testOverBudgetAdmissionStatesTheNumberInsteadOfSilentlyQueueing() {
        let controller = AdmissionController(
            policy: AdmissionPolicy(maxQueueDepth: 500, maxQueuedPerTenant: 500, waitBudgetTicks: 10)
        )
        let decision = controller.decide(
            job(99, tenant: ReferenceWorkload.checkout, snapshot: ReferenceWorkload.checkoutBasket),
            given: state(queueing: 40, tenant: ReferenceWorkload.checkout)
        )
        XCTAssertTrue(decision.isAdmitted)
        guard case let .admitOverBudget(wait, budget) = decision else {
            return XCTFail("expected an over-budget admission, got \(decision)")
        }
        XCTAssertEqual(budget, 10)
        XCTAssertGreaterThan(wait, budget)
    }

    func testZeroQuotaPolicyRejectsEverythingRatherThanTrapping() {
        let controller = AdmissionController(
            policy: AdmissionPolicy(maxQueueDepth: 0, maxQueuedPerTenant: 0, waitBudgetTicks: 0)
        )
        let decision = controller.decide(
            job(1, tenant: ReferenceWorkload.checkout, snapshot: ReferenceWorkload.checkoutBasket),
            given: state(queueing: 0, tenant: ReferenceWorkload.checkout)
        )
        XCTAssertEqual(decision, .rejectQueueFull(depth: 0, limit: 0))
    }

    func testWaitEstimateGrowsWithBacklog() {
        let controller = AdmissionController(
            policy: AdmissionPolicy(maxQueueDepth: 500, maxQueuedPerTenant: 500, waitBudgetTicks: 10_000)
        )
        let candidate = job(
            99,
            tenant: ReferenceWorkload.checkout,
            snapshot: ReferenceWorkload.checkoutBasket
        )
        let shallow = controller.estimatedWaitTicks(
            for: candidate,
            given: state(queueing: 4, tenant: ReferenceWorkload.checkout)
        )
        let deep = controller.estimatedWaitTicks(
            for: candidate,
            given: state(queueing: 40, tenant: ReferenceWorkload.checkout)
        )
        XCTAssertGreaterThan(deep, shallow)
    }
}
