import XCTest
@testable import DeviceFarmScheduler

final class FarmCoordinatorTests: XCTestCase {

    /// These tests are about leases, reclaim and the ledger, not about placement
    /// quality, so they use `maxSkips: 0`. With delay scheduling on, a farm
    /// whose hosts all start empty correctly declines to dispatch for the first
    /// several turns — right behaviour, and pure noise for what is under test.
    private func makeCoordinator(
        hostCount: Int = 2,
        leaseTTL: Int = 30,
        policy: some PlacementPolicy = LayeredAffinityFairPolicy(maxSkips: 0)
    ) -> FarmCoordinator {
        let hosts = (0..<hostCount).map { index in
            Host(
                id: HostID("host-\(index)"),
                store: SnapshotStore(capacityBytes: ReferenceWorkload.hostCapacityBytes)
            )
        }
        let state = SchedulerState(
            hosts: hosts,
            catalog: ReferenceWorkload.makeCatalog(),
            quanta: [
                ReferenceWorkload.checkout: 90,
                ReferenceWorkload.payments: 45,
            ]
        )
        return FarmCoordinator(
            state: state,
            policy: policy,
            admission: AdmissionController(policy: ReferenceWorkload.makeAdmissionPolicy()),
            leaseTTLTicks: leaseTTL
        )
    }

    private func job(_ id: Int, tenant: TenantID, snapshot: SnapshotKey, service: Int = 20) -> Job {
        Job(
            id: JobID(id),
            tenant: tenant,
            snapshot: snapshot,
            serviceTicks: service,
            enqueuedTick: 0
        )
    }

    func testSubmitAdmitsAndDispatches() async {
        let coordinator = makeCoordinator()
        let decision = await coordinator.submit(
            job(1, tenant: ReferenceWorkload.checkout, snapshot: ReferenceWorkload.checkoutBasket)
        )
        XCTAssertTrue(decision.isAdmitted)

        let granted = await coordinator.tick(to: 0)
        XCTAssertEqual(granted.count, 1)
        let queued = await coordinator.state.queuedJobCount
        XCTAssertEqual(queued, 0)
    }

    func testRejectedSubmissionIsNotQueued() async {
        let coordinator = makeCoordinator()
        let stranger = SnapshotKey(osBuild: "?", appBuild: "?", accountSeed: "?")
        let decision = await coordinator.submit(
            job(1, tenant: ReferenceWorkload.checkout, snapshot: stranger)
        )
        XCTAssertFalse(decision.isAdmitted)
        let queued = await coordinator.state.queuedJobCount
        XCTAssertEqual(queued, 0, "a rejected job must not silently enter the queue")
    }

    /// Three separate bugs are covered here, and each one silently degrades a
    /// farm rather than breaking it loudly:
    ///
    /// 1. The dispatched job must be captured *before* dispatch removes it from
    ///    the queue, or a reclaim has nothing to requeue and the run vanishes.
    /// 2. The reclaim must release the host. The first dispatch marks it busy
    ///    until well past tick 20, so the retry below can only happen if the
    ///    host was genuinely taken back — otherwise one wedged guest removes a
    ///    host from the fleet permanently.
    /// 3. The retry must keep the run's identity, so the zombie's token is
    ///    stale rather than merely irrelevant.
    func testExpiredLeaseIsReclaimedAndTheRunIsRetriedOnTheSameHost() async {
        let coordinator = makeCoordinator(hostCount: 1, leaseTTL: 10)
        _ = await coordinator.submit(
            job(
                1,
                tenant: ReferenceWorkload.checkout,
                snapshot: ReferenceWorkload.checkoutBasket,
                service: 150
            )
        )

        let first = await coordinator.tick(to: 0)
        guard let firstLease = first.first else { return XCTFail("no lease granted") }
        let afterDispatch = await coordinator.state.queuedJobCount
        XCTAssertEqual(afterDispatch, 0)

        // No heartbeat: the lease lapses, the host is taken back, and the run is
        // retried in the same sweep.
        let second = await coordinator.tick(to: 20)
        guard let secondLease = second.first else {
            return XCTFail("the reclaimed run was never retried")
        }

        XCTAssertEqual(
            secondLease.run, firstLease.run,
            "the retry was given a new run id, which orphans the old holder's token"
        )
        XCTAssertGreaterThan(
            secondLease.token, firstLease.token,
            "the retry must carry a strictly newer fencing token"
        )
        let stillQueued = await coordinator.state.queuedJobCount
        XCTAssertEqual(stillQueued, 0)
        let active = await coordinator.leases.activeLeaseCount
        XCTAssertEqual(active, 1)
    }

    func testHeartbeatPreventsReclaim() async {
        let coordinator = makeCoordinator(hostCount: 1, leaseTTL: 10)
        _ = await coordinator.submit(
            job(
                1,
                tenant: ReferenceWorkload.checkout,
                snapshot: ReferenceWorkload.checkoutBasket,
                service: 150
            )
        )
        let granted = await coordinator.tick(to: 0)
        guard let lease = granted.first else { return XCTFail("no lease granted") }

        let beat = await coordinator.heartbeat(run: lease.run, token: lease.token)
        XCTAssertTrue(beat)

        _ = await coordinator.tick(to: 9)
        let queued = await coordinator.state.queuedJobCount
        XCTAssertEqual(queued, 0, "a run with a live heartbeat was reclaimed")
    }

    func testCompletingWithAStaleTokenIsRejectedEndToEnd() async {
        let coordinator = makeCoordinator(hostCount: 1, leaseTTL: 10)
        _ = await coordinator.submit(
            job(
                1,
                tenant: ReferenceWorkload.checkout,
                snapshot: ReferenceWorkload.checkoutBasket,
                service: 150
            )
        )
        let first = await coordinator.tick(to: 0)
        guard let oldLease = first.first else { return XCTFail("no lease granted") }

        // Let it lapse; the run is reclaimed and retried with a newer token.
        let second = await coordinator.tick(to: 20)
        guard let newLease = second.first else { return XCTFail("run was not re-dispatched") }
        XCTAssertEqual(newLease.run, oldLease.run)
        XCTAssertGreaterThan(newLease.token, oldLease.token)

        let currentHolder = await coordinator.complete(
            run: newLease.run, verdict: .failed, token: newLease.token
        )
        XCTAssertEqual(currentHolder, .recorded)

        let zombie = await coordinator.complete(
            run: oldLease.run, verdict: .passed, token: oldLease.token
        )
        XCTAssertFalse(LedgerAudit.wasAccepted(zombie))

        let violations = await coordinator.auditLedger()
        XCTAssertTrue(violations.isEmpty, "\(violations)")
    }

    func testFullRunLeavesCleanLedgerAndHostAudits() async {
        let coordinator = makeCoordinator(hostCount: 3, leaseTTL: 200)
        for index in 0..<12 {
            let snapshot = index % 3 == 0
                ? ReferenceWorkload.paymentsCard
                : ReferenceWorkload.checkoutBasket
            let tenant = index % 3 == 0 ? ReferenceWorkload.payments : ReferenceWorkload.checkout
            _ = await coordinator.submit(
                job(index, tenant: tenant, snapshot: snapshot, service: 15)
            )
        }

        for tick in stride(from: 0, through: 600, by: 5) {
            let granted = await coordinator.tick(to: tick)
            for lease in granted {
                _ = await coordinator.complete(
                    run: lease.run, verdict: .passed, token: lease.token
                )
            }
        }

        let ledgerViolations = await coordinator.auditLedger()
        XCTAssertTrue(ledgerViolations.isEmpty, "\(ledgerViolations)")
        let hostViolations = await coordinator.auditHosts()
        XCTAssertTrue(hostViolations.isEmpty, "\(hostViolations)")

        let recorded = await coordinator.ledger.recordedRunCount
        XCTAssertGreaterThan(recorded, 0, "no run ever completed")
    }
}
