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

    public init(
        title: String,
        subtitle: String,
        spec: WorkloadSpec,
        costModel: PoolCostModel,
        admissionPolicy: AdmissionPolicy
    ) {
        self.title = title
        self.subtitle = subtitle
        self.spec = spec
        self.costModel = costModel
        self.admissionPolicy = admissionPolicy
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
        self.tenantOrder = configuration.spec.tenants.map(\.id).sorted()

        let histogram = ArrivalHistogram(
            observations: configuration.spec.arrivalTrace().map(\.count)
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
}
#endif
