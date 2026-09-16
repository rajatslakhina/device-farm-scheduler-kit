#if canImport(SwiftUI)
import SwiftUI
import DeviceFarmScheduler

/// Everything the console needs, supplied by the host app.
///
/// The view takes this as a parameter rather than building its own: the workload
/// a team wants to reason about is theirs, not the library's, and a UI module
/// that hardcodes a fixture is a UI module you can only ever use for a demo.
public struct FarmConsoleConfiguration: Sendable {
    public let title: String
    public let subtitle: String
    public let spec: WorkloadSpec
    public let costModel: PoolCostModel
    public let admissionPolicy: AdmissionPolicy

    /// How long a stretch of time counts as one observation for pool sizing.
    ///
    /// Required, with no default, because getting it wrong is silent: bucket
    /// per tick and the sizer answers a question about seconds instead of about
    /// bursts, recommends a depth of zero, and draws a rising curve that looks
    /// like a finished chart. See `ArrivalHistogram.init(trace:windowTicks:)`.
    public let observationWindowTicks: Int

    public init(
        title: String,
        subtitle: String,
        spec: WorkloadSpec,
        costModel: PoolCostModel,
        admissionPolicy: AdmissionPolicy,
        observationWindowTicks: Int
    ) {
        self.title = title
        self.subtitle = subtitle
        self.spec = spec
        self.costModel = costModel
        self.admissionPolicy = admissionPolicy
        self.observationWindowTicks = max(1, observationWindowTicks)
    }
}

/// Drives the console: runs all three policies over one identical trace and
/// keeps the results for side-by-side reading.
@MainActor
@Observable
public final class FarmConsoleModel {

    public let configuration: FarmConsoleConfiguration
    public private(set) var reports: [PolicyReport] = []
    public private(set) var sizing: PoolSizingResult
    public private(set) var tenantOrder: [TenantID]
    public var selectedIndex: Int = 0

    public init(configuration: FarmConsoleConfiguration) {
        self.configuration = configuration
        // De-duplicated: these become `ForEach` identities, and `SchedulerState`
        // already collapses duplicate tenant ids via `uniquingKeysWith`. A spec
        // carrying two profiles with the same id would otherwise render two rows
        // sharing one identity.
        self.tenantOrder = Array(Set(configuration.spec.tenants.map(\.id))).sorted()

        // Bucketed into observation windows, not per tick. Per-tick bucketing
        // is the failure this kit's own README names, and shipping it here
        // would have put the bug in the one place a user actually sees.
        let histogram = ArrivalHistogram(
            trace: configuration.spec.arrivalTrace(),
            windowTicks: configuration.observationWindowTicks
        )
        self.sizing = PoolSizer.size(histogram: histogram, model: configuration.costModel)

        // Computed eagerly so the first frame already has real numbers. The
        // whole replay is a few hundred thousand integer operations — cheap
        // enough that adding a loading state would cost more than it saves.
        self.reports = FarmSimulation.compareShippedPolicies(spec: configuration.spec)
    }

    public var selectedReport: PolicyReport? {
        reports.indices.contains(selectedIndex) ? reports[selectedIndex] : reports.first
    }

    public var policyNames: [String] { reports.map(\.policyName) }

    /// The layered policy's report, used as the comparison baseline.
    public var layeredReport: PolicyReport? { reports.first }

    /// Highest worst-wait across all policies, for scaling the comparison bars.
    public var waitScale: Int {
        max(1, reports.map(\.worstTenantWaitTicks).max() ?? 1)
    }

    /// Fraction of `waitScale`, clamped to 0...1 and safe against an empty run.
    public func waitFraction(_ ticks: Int) -> Double {
        let scale = waitScale
        guard scale > 0 else { return 0 }
        let ratio = Double(ticks) / Double(scale)
        guard ratio.isFinite else { return 0 }
        return min(1.0, max(0.0, ratio))
    }

    public func hitRateFraction(_ percent: Int) -> Double {
        min(1.0, max(0.0, Double(Saturating.clamp(percent, to: 0...100)) / 100.0))
    }

    /// Minutes of restore time, for a number a human can hold.
    public func restoreMinutes(_ millis: Int) -> Int {
        Saturating.divide(millis, by: 60_000)
    }

    // MARK: - Admission

    /// The wait budget configured on `AdmissionController`.
    ///
    /// Shown next to what the policy actually delivered, because an estimate
    /// nobody ever checks against an outcome is not a service level.
    ///
    /// **Important, and stated in the UI too:** `FarmSimulation` deliberately
    /// does *not* apply admission control — it enqueues every arrival. So this
    /// compares the budget the farm would have quoted against the wait an
    /// unrestricted run produced. That is the useful comparison for choosing a
    /// policy (you see the unclipped cost), and it is emphatically not a report
    /// that admission control ran and held. On this configuration the same
    /// policy's per-tenant backlog also exceeds `maxQueuedPerTenant`, which is
    /// another way of saying the same thing.
    public var waitBudgetTicks: Int {
        configuration.admissionPolicy.waitBudgetTicks
    }

    /// Per-tenant queue cap from the same policy, for the same disclosure.
    public var maxQueuedPerTenant: Int {
        configuration.admissionPolicy.maxQueuedPerTenant
    }

    /// Whether the unrestricted run left any tenant holding more work than
    /// admission control would have accepted.
    public var exceedsTenantQuota: Bool {
        guard let report = selectedReport else { return false }
        return tenantOrder.contains { report.stillQueued(for: $0) > maxQueuedPerTenant }
    }

    /// Whether the selected policy blew through that promise.
    public var breachesWaitBudget: Bool {
        (selectedReport?.worstTenantWaitTicks ?? 0) > waitBudgetTicks
    }

    /// How far past the promise the worst-served tenant ended up, in ticks.
    public var waitBudgetOverrunTicks: Int {
        max(0, Saturating.subtract(selectedReport?.worstTenantWaitTicks ?? 0, waitBudgetTicks))
    }

    /// Headline for the admission banner.
    ///
    /// Built here rather than inline in the view for a boring but real reason:
    /// concatenating this many string fragments and a ternary inside a
    /// `Text(...)` inside an `HStack` defeats the SwiftUI type-checker — it
    /// fails with "unable to type-check this expression in reasonable time",
    /// which is a compile error, not a warning. Plain `String` properties on
    /// the model type-check instantly and the view just interpolates them.
    public var admissionHeadline: String {
        breachesWaitBudget
            ? "Wait budget missed by \(waitBudgetOverrunTicks)s"
            : "Within the \(waitBudgetTicks)s wait budget"
    }

    /// Body text for the admission banner, including the disclosure that this
    /// replay does not apply admission control at all.
    public var admissionDetail: String {
        var text = "This replay admits every arrival — admission control is not applied — "
        text += "so you are seeing the unclipped cost against the \(waitBudgetTicks)s budget "
        text += "AdmissionController would have quoted."
        if exceedsTenantQuota {
            text += " A tenant also ends up holding more than the "
            text += "\(maxQueuedPerTenant)-job per-tenant cap."
        }
        return text
    }
}
#endif
