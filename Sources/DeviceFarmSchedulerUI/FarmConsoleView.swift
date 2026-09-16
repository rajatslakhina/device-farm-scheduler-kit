#if canImport(SwiftUI)
import SwiftUI
import DeviceFarmScheduler

/// The console: one workload, three policies, side by side.
///
/// The design goal is that the argument is visible without reading the README.
/// Switching the policy picker moves two numbers in opposite directions — hit
/// rate and worst wait — and the per-tenant table underneath shows which tenant
/// paid for it.
public struct FarmConsoleView: View {

    @State private var model: FarmConsoleModel

    public init(configuration: FarmConsoleConfiguration) {
        _model = State(wrappedValue: FarmConsoleModel(configuration: configuration))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    policyPicker
                    if let report = model.selectedReport {
                        kpiGrid(for: report)
                        admissionBanner
                        tenantTable(for: report)
                    } else {
                        ContentUnavailableView(
                            "No run yet",
                            systemImage: "clock.badge.questionmark",
                            description: Text("The workload produced no dispatches.")
                        )
                    }
                    comparisonSection
                    sizingSection
                }
                .padding(20)
            }
            .navigationTitle("Device Farm")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.configuration.title)
                .font(.title2.weight(.semibold))
            Text(model.configuration.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Policy picker

    private var policyPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PLACEMENT POLICY")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Picker("Policy", selection: $model.selectedIndex) {
                ForEach(Array(model.policyNames.enumerated()), id: \.offset) { index, name in
                    Text(shortName(for: index, fallback: name)).tag(index)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func shortName(for index: Int, fallback: String) -> String {
        switch index {
        case 0: return "Layered"
        case 1: return "Affinity"
        case 2: return "Fair"
        default: return fallback
        }
    }

    // MARK: - KPIs

    private func kpiGrid(for report: PolicyReport) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            kpiCard(
                title: "Warm hit rate",
                value: "\(report.warmHitRatePercent)%",
                detail: "\(report.warmDispatches) of \(report.dispatched) started with no restore",
                tint: .green
            )
            kpiCard(
                title: "Worst tenant wait",
                value: "\(report.worstTenantWaitTicks)s",
                detail: report.worstTenant.map { "\($0) waited longest" } ?? "no waits recorded",
                tint: .orange
            )
            kpiCard(
                title: "Restore time paid",
                value: "\(model.restoreMinutes(report.totalRestoreMillis)) min",
                detail: "\(report.coldDispatches) cold starts across the fleet",
                tint: .red
            )
            kpiCard(
                title: "Still queued",
                value: "\(report.jobsLeftQueued)",
                detail: "runs unserved when the window closed",
                tint: report.jobsLeftQueued > 0 ? .purple : .secondary
            )
        }
    }

    private func kpiCard(title: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Admission promise

    /// What the farm promised at submit time, against what it delivered.
    private var admissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: model.breachesWaitBudget
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.seal.fill"
            )
            .foregroundStyle(model.breachesWaitBudget ? .orange : .green)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.breachesWaitBudget
                        ? "Wait budget missed by \(model.waitBudgetOverrunTicks)s"
                        : "Within the \(model.waitBudgetTicks)s wait budget"
                )
                .font(.footnote.weight(.semibold))
                Text(
                    "AdmissionController quotes every caller a \(model.waitBudgetTicks)s "
                        + "budget at submit time. This is what the policy actually delivered."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            (model.breachesWaitBudget ? Color.orange : Color.green).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    // MARK: - Per-tenant

    private func tenantTable(for report: PolicyReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PER TENANT")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(model.tenantOrder, id: \.self) { tenant in
                HStack(spacing: 10) {
                    Text(tenant.rawValue)
                        .font(.callout.weight(.medium))
                        .frame(width: 92, alignment: .leading)
                        .lineLimit(1)

                    ProgressBar(fraction: model.waitFraction(report.worstWait(for: tenant)))
                        .frame(height: 8)

                    Text("\(report.worstWait(for: tenant))s")
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                Text(
                    "ran \(report.dispatched(for: tenant)) · "
                        + "\(report.stillQueued(for: tenant)) left queued"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 92)
            }
        }
    }

    // MARK: - Comparison

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ALL THREE, SAME TRACE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(
                "One arrival trace, replayed three times. The two baselines each "
                    + "win one column and lose the other."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(model.reports.enumerated()), id: \.offset) { index, report in
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.policyName)
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 8) {
                        Label("\(report.warmHitRatePercent)%", systemImage: "flame.fill")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.green)
                            .frame(width: 74, alignment: .leading)
                        ProgressBar(fraction: model.hitRateFraction(report.warmHitRatePercent))
                            .frame(height: 6)
                    }
                    HStack(spacing: 8) {
                        Label("\(report.worstTenantWaitTicks)s", systemImage: "hourglass")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                            .frame(width: 74, alignment: .leading)
                        ProgressBar(
                            fraction: model.waitFraction(report.worstTenantWaitTicks),
                            tint: .orange
                        )
                        .frame(height: 6)
                    }
                }
                .padding(10)
                .background(
                    (index == model.selectedIndex ? Color.accentColor.opacity(0.10) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        }
    }

    // MARK: - Pool sizing

    private var sizingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WARM POOL DEPTH")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(
                "Cost evaluated at every depth against the observed arrival "
                    + "histogram — not a fitted distribution."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(model.sizing.curve, id: \.depth) { point in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                point.depth == model.sizing.recommendedDepth
                                    ? Color.accentColor
                                    : Color.secondary.opacity(0.35)
                            )
                            .frame(height: barHeight(for: point))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 96)
            .accessibilityLabel(
                "Cost curve, cheapest at depth \(model.sizing.recommendedDepth)"
            )

            Text("Recommended depth: \(model.sizing.recommendedDepth) warm hosts")
                .font(.footnote.weight(.semibold))
        }
    }

    private func barHeight(for point: PoolCostPoint) -> CGFloat {
        let maxCost = model.sizing.curve.map(\.totalCost).max() ?? 0
        guard maxCost > 0 else { return 2 }
        let ratio = Double(point.totalCost) / Double(maxCost)
        guard ratio.isFinite else { return 2 }
        return max(2, CGFloat(min(1.0, max(0.0, ratio)) * 92))
    }
}

/// A fill bar that never divides by zero and never renders a negative width.
struct ProgressBar: View {
    let fraction: Double
    var tint: Color = .green

    var body: some View {
        GeometryReader { proxy in
            let clamped = fraction.isFinite ? min(1.0, max(0.0, fraction)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, proxy.size.width * clamped))
            }
        }
    }
}

#Preview {
    FarmConsoleView(
        configuration: FarmConsoleConfiguration(
            title: "Reference workload",
            subtitle: "8 hosts · 2 OS builds · 3 tenants · bursty agent fan-out",
            spec: ReferenceWorkload.makeSpec(),
            costModel: ReferenceWorkload.makeCostModel(),
            admissionPolicy: ReferenceWorkload.makeAdmissionPolicy(),
            observationWindowTicks: ReferenceWorkload.observationWindowTicks
        )
    )
}
#endif
