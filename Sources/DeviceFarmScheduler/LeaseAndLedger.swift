/// A monotonically increasing stamp handed out with every lease.
///
/// This is Kleppmann's fencing token, applied to a device farm rather than to a
/// distributed lock service — no novelty claimed, and the reason it is needed
/// here is specific: a virtualized host can be paused by its hypervisor, lose
/// its network, or be reclaimed for over-running, and in every one of those
/// cases the *guest* has no idea it stopped being the owner. Something outside
/// the guest has to be able to tell.
public struct FencingToken: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) { self.value = value }

    public static func < (lhs: FencingToken, rhs: FencingToken) -> Bool {
        lhs.value < rhs.value
    }

    public var description: String { "fence-\(value)" }

    /// The next token. Saturates at `UInt64.max` rather than wrapping: wrapping
    /// would make an ancient token compare as newer than a current one, which is
    /// precisely the failure this type exists to prevent.
    public var next: FencingToken {
        value == UInt64.max ? self : FencingToken(value + 1)
    }
}

public struct RunID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public var description: String { "run-\(rawValue)" }
    public static func < (lhs: RunID, rhs: RunID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The right to run one job on one host, for a bounded time.
public struct RunLease: Hashable, Sendable {
    public let run: RunID
    public let host: HostID
    public let token: FencingToken
    public let grantedTick: Int
    public let expiresTick: Int

    public func isExpired(at tick: Int) -> Bool { tick >= expiresTick }
}

/// Grants leases, tracks heartbeats, and reclaims hosts whose runner went quiet.
///
/// The TTL is doing the real work. A farm cannot distinguish "the guest is
/// wedged" from "the guest is slow" from "the network is slow", and waiting for
/// certainty means a host stays pinned forever. So the manager does not try: it
/// reclaims on a deadline and relies on the fencing token to make the reclaim
/// *safe* rather than merely fast.
public struct LeaseManager: Sendable {
    /// Ticks a lease survives without a heartbeat.
    public let ttlTicks: Int

    private var active: [RunID: RunLease]
    private var nextToken: FencingToken

    public init(ttlTicks: Int, firstToken: FencingToken = FencingToken(1)) {
        // A zero or negative TTL expires every lease the instant it is granted.
        self.ttlTicks = max(1, ttlTicks)
        self.active = [:]
        self.nextToken = firstToken
    }

    public var activeLeaseCount: Int { active.count }

    public func lease(for run: RunID) -> RunLease? { active[run] }

    /// Grants a lease, superseding any existing one for the same run.
    ///
    /// Superseding rather than refusing is deliberate: the caller only asks for
    /// a second lease on a run after deciding the first holder is gone, and
    /// refusing would leave the run stuck behind a host nobody can reach. The
    /// old holder is not told — it finds out when its result is rejected.
    public mutating func grant(run: RunID, host: HostID, at tick: Int) -> RunLease {
        let token = nextToken
        nextToken = token.next
        let lease = RunLease(
            run: run,
            host: host,
            token: token,
            grantedTick: tick,
            expiresTick: Saturating.add(tick, ttlTicks)
        )
        active[run] = lease
        return lease
    }

    /// Extends a lease if the caller still holds it.
    ///
    /// Returns `false` when the presented token is not the current one — which
    /// is exactly what a resumed, already-reclaimed runner sees, and is its only
    /// signal to stop working.
    public mutating func heartbeat(
        run: RunID,
        token: FencingToken,
        at tick: Int
    ) -> Bool {
        guard let current = active[run], current.token == token else { return false }
        guard !current.isExpired(at: tick) else { return false }
        active[run] = RunLease(
            run: current.run,
            host: current.host,
            token: current.token,
            grantedTick: current.grantedTick,
            expiresTick: Saturating.add(tick, ttlTicks)
        )
        return true
    }

    /// Drops every lease past its deadline and returns them, sorted by run id
    /// so a reclaim sweep is reproducible.
    public mutating func reclaimExpired(at tick: Int) -> [RunLease] {
        let expired = active.values
            .filter { $0.isExpired(at: tick) }
            .sorted { $0.run < $1.run }
        for lease in expired { active.removeValue(forKey: lease.run) }
        return expired
    }

    public mutating func release(run: RunID, token: FencingToken) -> Bool {
        guard let current = active[run], current.token == token else { return false }
        active.removeValue(forKey: run)
        return true
    }
}

/// The result of one run.
public struct RunResult: Hashable, Sendable {
    public enum Verdict: String, Hashable, Sendable {
        case passed
        case failed
        case infrastructureError
    }

    public let run: RunID
    public let verdict: Verdict
    public let recordedTick: Int

    public init(run: RunID, verdict: Verdict, recordedTick: Int) {
        self.run = run
        self.verdict = verdict
        self.recordedTick = recordedTick
    }
}

/// Where results land, with exactly-once semantics enforced by fencing token.
///
/// The property that matters: **a host that lost its lease can never report
/// green.** A paused guest that resumes after its lease was reclaimed still
/// holds a valid-looking result object and a plausible-looking token, and it
/// will try to submit. The ledger rejects it because the token is stale, not
/// because anything about the result looked wrong — there is nothing about the
/// result that *could* look wrong.
///
/// ### The trade-off, stated
///
/// A strictly-higher token supersedes an already-recorded result. The
/// alternative — first write wins — sounds safer and is worse: a zombie that
/// briefly outruns the reclaim sweep pins a stale verdict that the legitimate
/// current holder can then never correct. Since only the current lease holder
/// can possess the highest token, "highest token wins" is the rule that makes
/// the current owner authoritative, which is what the farm actually wants.
public struct RunLedger: Sendable {

    public enum Outcome: Sendable, Equatable {
        case recorded
        case superseded(previous: RunResult)
        case rejectedStaleToken(presented: FencingToken, highestSeen: FencingToken)
        case rejectedDuplicate(token: FencingToken)
    }

    /// One attempted write, kept so a run's history can be audited afterwards.
    public struct Entry: Sendable, Equatable {
        public let result: RunResult
        public let token: FencingToken
        public let outcome: Outcome
    }

    private var finalResults: [RunID: RunResult]
    private var highestToken: [RunID: FencingToken]
    public private(set) var trace: [Entry]

    public init() {
        self.finalResults = [:]
        self.highestToken = [:]
        self.trace = []
    }

    public func result(for run: RunID) -> RunResult? { finalResults[run] }

    public var recordedRunCount: Int { finalResults.count }

    @discardableResult
    public mutating func record(
        _ result: RunResult,
        presenting token: FencingToken
    ) -> Outcome {
        let outcome: Outcome

        if let seen = highestToken[result.run] {
            if token > seen {
                let previous = finalResults[result.run]
                highestToken[result.run] = token
                finalResults[result.run] = result
                outcome = previous.map { Outcome.superseded(previous: $0) } ?? .recorded
            } else if token == seen {
                outcome = .rejectedDuplicate(token: token)
            } else {
                outcome = .rejectedStaleToken(presented: token, highestSeen: seen)
            }
        } else {
            highestToken[result.run] = token
            finalResults[result.run] = result
            outcome = .recorded
        }

        trace.append(Entry(result: result, token: token, outcome: outcome))
        return outcome
    }
}

/// Standalone verification of the ledger's exactly-once claim.
///
/// Separate from `RunLedger` on purpose: a checker that can only be pointed at
/// the implementation it is checking proves nothing. This one consumes a trace
/// of attempted writes and their outcomes, so the tests can hand it a trace
/// produced by a deliberately permissive ledger and confirm it reports the
/// violation — which is the only evidence that a clean report means anything.
public enum LedgerAudit {

    public enum Violation: Sendable, Equatable, CustomStringConvertible {
        /// A write was accepted whose token did not exceed one already accepted.
        case acceptedNonMonotonicToken(run: RunID, accepted: FencingToken, after: FencingToken)
        /// The same token was accepted twice for one run.
        case acceptedDuplicateToken(run: RunID, token: FencingToken)

        public var description: String {
            switch self {
            case let .acceptedNonMonotonicToken(run, accepted, after):
                return "\(run): accepted \(accepted) after \(after) had already been accepted"
            case let .acceptedDuplicateToken(run, token):
                return "\(run): accepted \(token) twice"
            }
        }
    }

    /// Whether an outcome means the write landed.
    public static func wasAccepted(_ outcome: RunLedger.Outcome) -> Bool {
        switch outcome {
        case .recorded, .superseded: return true
        case .rejectedStaleToken, .rejectedDuplicate: return false
        }
    }

    /// Every violation of exactly-once semantics visible in `trace`.
    public static func violations(in trace: [RunLedger.Entry]) -> [Violation] {
        var highestAccepted: [RunID: FencingToken] = [:]
        var found: [Violation] = []

        for entry in trace where wasAccepted(entry.outcome) {
            let run = entry.result.run
            guard let previous = highestAccepted[run] else {
                highestAccepted[run] = entry.token
                continue
            }
            if entry.token == previous {
                found.append(.acceptedDuplicateToken(run: run, token: entry.token))
            } else if entry.token < previous {
                found.append(
                    .acceptedNonMonotonicToken(run: run, accepted: entry.token, after: previous)
                )
            } else {
                highestAccepted[run] = entry.token
            }
        }
        return found
    }
}
