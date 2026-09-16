import XCTest
@testable import DeviceFarmScheduler

/// A ledger with the guard removed, so the audit has something to catch.
///
/// This is the shape of the first implementation anyone writes: results come in,
/// results get stored. It is not a strawman — nothing about a result submitted
/// by a zombie host *looks* wrong, which is exactly why a check on the payload
/// can never work and a check on the token can.
struct PermissiveLedger {
    private(set) var trace: [RunLedger.Entry] = []
    private(set) var results: [RunID: RunResult] = [:]

    mutating func record(_ result: RunResult, presenting token: FencingToken) {
        results[result.run] = result
        trace.append(RunLedger.Entry(result: result, token: token, outcome: .recorded))
    }
}

final class LeaseAndLedgerTests: XCTestCase {

    private let run = RunID(1)
    private let hostA = HostID("host-a")
    private let hostB = HostID("host-b")

    // MARK: - Leases

    func testHeartbeatWithTheWrongTokenFails() {
        var manager = LeaseManager(ttlTicks: 30)
        let lease = manager.grant(run: run, host: hostA, at: 0)

        XCTAssertTrue(manager.heartbeat(run: run, token: lease.token, at: 10))
        XCTAssertFalse(
            manager.heartbeat(run: run, token: FencingToken(9_999), at: 10),
            "a token nobody granted must not extend a lease"
        )
    }

    func testHeartbeatExtendsTheDeadline() {
        var manager = LeaseManager(ttlTicks: 30)
        let lease = manager.grant(run: run, host: hostA, at: 0)
        XCTAssertEqual(lease.expiresTick, 30)

        XCTAssertTrue(manager.heartbeat(run: run, token: lease.token, at: 25))
        XCTAssertEqual(manager.lease(for: run)?.expiresTick, 55)
        XCTAssertTrue(manager.reclaimExpired(at: 54).isEmpty)
    }

    func testLeaseExpiresExactlyAtItsDeadline() {
        var manager = LeaseManager(ttlTicks: 30)
        _ = manager.grant(run: run, host: hostA, at: 0)
        XCTAssertTrue(manager.reclaimExpired(at: 29).isEmpty, "expired a tick early")
        XCTAssertEqual(manager.reclaimExpired(at: 30).count, 1, "did not expire on the deadline")
        XCTAssertEqual(manager.activeLeaseCount, 0)
    }

    func testHeartbeatOnAnAlreadyExpiredLeaseFails() {
        var manager = LeaseManager(ttlTicks: 10)
        let lease = manager.grant(run: run, host: hostA, at: 0)
        XCTAssertFalse(
            manager.heartbeat(run: run, token: lease.token, at: 10),
            "a lease past its deadline must not be revivable by its old holder"
        )
    }

    func testZeroTTLIsFlooredRatherThanExpiringInstantly() {
        var manager = LeaseManager(ttlTicks: 0)
        let lease = manager.grant(run: run, host: hostA, at: 0)
        XCTAssertGreaterThan(lease.expiresTick, lease.grantedTick)
    }

    func testTokensAreStrictlyIncreasing() {
        var manager = LeaseManager(ttlTicks: 10)
        let first = manager.grant(run: run, host: hostA, at: 0)
        let second = manager.grant(run: RunID(2), host: hostB, at: 0)
        let third = manager.grant(run: run, host: hostB, at: 1)
        XCTAssertLessThan(first.token, second.token)
        XCTAssertLessThan(second.token, third.token)
    }

    func testFencingTokenSaturatesRatherThanWrapping() {
        // Wrapping would make an ancient token compare as newer than a current
        // one — the exact inversion the token exists to prevent.
        let maxToken = FencingToken(UInt64.max)
        XCTAssertEqual(maxToken.next, maxToken)
        XCTAssertFalse(maxToken.next < maxToken)
    }

    // MARK: - Exactly-once result capture

    func testStaleTokenCannotReportGreen() {
        var manager = LeaseManager(ttlTicks: 10)
        var ledger = RunLedger()

        // Host A takes the run, then goes quiet.
        let leaseA = manager.grant(run: run, host: hostA, at: 0)
        XCTAssertEqual(manager.reclaimExpired(at: 10).count, 1)

        // Host B picks it up and fails the run.
        let leaseB = manager.grant(run: run, host: hostB, at: 10)
        let bOutcome = ledger.record(
            RunResult(run: run, verdict: .failed, recordedTick: 40),
            presenting: leaseB.token
        )
        XCTAssertEqual(bOutcome, .recorded)

        // Host A wakes up and tries to report a pass.
        let aOutcome = ledger.record(
            RunResult(run: run, verdict: .passed, recordedTick: 41),
            presenting: leaseA.token
        )
        XCTAssertEqual(
            aOutcome,
            .rejectedStaleToken(presented: leaseA.token, highestSeen: leaseB.token)
        )
        XCTAssertEqual(
            ledger.result(for: run)?.verdict, .failed,
            "a reclaimed host overwrote the current holder's verdict"
        )
    }

    func testDuplicateSubmissionOfTheSameTokenIsRejected() {
        var ledger = RunLedger()
        let token = FencingToken(5)
        XCTAssertEqual(
            ledger.record(RunResult(run: run, verdict: .passed, recordedTick: 1), presenting: token),
            .recorded
        )
        XCTAssertEqual(
            ledger.record(RunResult(run: run, verdict: .passed, recordedTick: 2), presenting: token),
            .rejectedDuplicate(token: token)
        )
        XCTAssertEqual(ledger.recordedRunCount, 1)
    }

    func testHigherTokenSupersedesAndSaysSo() {
        var ledger = RunLedger()
        let first = RunResult(run: run, verdict: .passed, recordedTick: 1)
        XCTAssertEqual(ledger.record(first, presenting: FencingToken(1)), .recorded)

        let outcome = ledger.record(
            RunResult(run: run, verdict: .failed, recordedTick: 2),
            presenting: FencingToken(2)
        )
        XCTAssertEqual(outcome, .superseded(previous: first))
        XCTAssertEqual(ledger.result(for: run)?.verdict, .failed)
    }

    func testDistinctRunsDoNotShareTokenHistory() {
        var ledger = RunLedger()
        XCTAssertEqual(
            ledger.record(
                RunResult(run: RunID(1), verdict: .passed, recordedTick: 1),
                presenting: FencingToken(10)
            ),
            .recorded
        )
        // A *lower* token for a different run is still that run's first write.
        XCTAssertEqual(
            ledger.record(
                RunResult(run: RunID(2), verdict: .passed, recordedTick: 1),
                presenting: FencingToken(3)
            ),
            .recorded
        )
        XCTAssertEqual(ledger.recordedRunCount, 2)
    }

    // MARK: - The audit itself

    /// The audit is only evidence if it can fail. This runs the identical
    /// zombie scenario through a ledger with the guard removed and asserts the
    /// checker reports the violation.
    func testAuditCatchesAPermissiveLedger() {
        var permissive = PermissiveLedger()
        permissive.record(
            RunResult(run: run, verdict: .failed, recordedTick: 40),
            presenting: FencingToken(2)
        )
        permissive.record(
            RunResult(run: run, verdict: .passed, recordedTick: 41),
            presenting: FencingToken(1)
        )

        let violations = LedgerAudit.violations(in: permissive.trace)
        XCTAssertEqual(
            violations,
            [.acceptedNonMonotonicToken(run: run, accepted: FencingToken(1), after: FencingToken(2))]
        )
        XCTAssertEqual(
            permissive.results[run]?.verdict, .passed,
            "the permissive ledger was expected to let the zombie win — if it does not, "
                + "this test is no longer demonstrating the bug it claims to"
        )
    }

    func testAuditCatchesADuplicateAcceptance() {
        var permissive = PermissiveLedger()
        let token = FencingToken(7)
        permissive.record(RunResult(run: run, verdict: .passed, recordedTick: 1), presenting: token)
        permissive.record(RunResult(run: run, verdict: .failed, recordedTick: 2), presenting: token)

        XCTAssertEqual(
            LedgerAudit.violations(in: permissive.trace),
            [.acceptedDuplicateToken(run: run, token: token)]
        )
    }

    func testAuditPassesTheRealLedgerOnTheSameScenario() {
        var ledger = RunLedger()
        ledger.record(
            RunResult(run: run, verdict: .failed, recordedTick: 40),
            presenting: FencingToken(2)
        )
        ledger.record(
            RunResult(run: run, verdict: .passed, recordedTick: 41),
            presenting: FencingToken(1)
        )
        XCTAssertTrue(LedgerAudit.violations(in: ledger.trace).isEmpty)
        XCTAssertTrue(LedgerAudit.violations(in: []).isEmpty)
    }
}
