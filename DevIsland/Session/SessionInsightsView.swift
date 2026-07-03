import SwiftUI

// MARK: - ViewModel

@MainActor
final class SessionInsightsViewModel: ObservableObject {
    @Published var summary: SessionInsightsSummary?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let appState: AppState

    init(appState: AppState? = nil) {
        self.appState = appState ?? .shared
    }

    func refresh() {
        isLoading = true
        let days = SettingsStore.shared.settings.replayRetentionDays
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { [appState] in
                    try appState.sessionInsightsSummary(retentionDays: days)
                }.value
                summary = result
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - View

struct SessionInsightsView: View {
    @StateObject private var viewModel: SessionInsightsViewModel
    @ObservedObject private var l10n = L10n.shared

    init(appState: AppState? = nil) {
        _viewModel = StateObject(wrappedValue: SessionInsightsViewModel(appState: appState))
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = viewModel.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let summary = viewModel.summary {
                content(summary)
            } else {
                Color.clear
            }
        }
        .onAppear { viewModel.refresh() }
    }

    private var isLoading: Bool { viewModel.isLoading && viewModel.summary == nil }

    private func content(_ s: SessionInsightsSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                metricsRow(s)
                Divider()
                approvalsSection(s)
                Divider()
                topToolsSection(s)
                Spacer(minLength: 0)
                Text(l10n.insightsRetentionNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
    }

    // MARK: Metrics row

    private func metricsRow(_ s: SessionInsightsSummary) -> some View {
        HStack(spacing: 16) {
            metricCard(
                value: "\(s.todayClosedSessions)",
                label: l10n.insightsTodaySessions,
                icon: "calendar"
            )
            metricCard(
                value: "\(s.totalClosedSessions)",
                label: l10n.insightsTotalSessions,
                icon: "clock.arrow.circlepath"
            )
            metricCard(
                value: durationString(s.averageDurationSeconds),
                label: l10n.insightsAvgDuration,
                icon: "timer"
            )
        }
    }

    private func metricCard(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(value == "—" ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Approvals

    private func approvalsSection(_ s: SessionInsightsSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.insightsApprovals)
                .font(.headline)
            if s.totalDecisions == 0 {
                Text(l10n.insightsNoData)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                approvalBar(s)
                HStack(spacing: 20) {
                    approvalLegend(
                        label: l10n.insightsManualApproved,
                        count: s.manualApproved,
                        total: s.totalDecisions,
                        color: .green
                    )
                    approvalLegend(
                        label: l10n.insightsManualDenied,
                        count: s.manualDenied,
                        total: s.totalDecisions,
                        color: .red
                    )
                    approvalLegend(
                        label: l10n.insightsAutoApproved,
                        count: s.autoApproved,
                        total: s.totalDecisions,
                        color: .blue
                    )
                    if s.autoDenied > 0 {
                        approvalLegend(
                            label: l10n.insightsAutoDenied,
                            count: s.autoDenied,
                            total: s.totalDecisions,
                            color: .orange
                        )
                    }
                }
            }
        }
    }

    private func approvalBar(_ s: SessionInsightsSummary) -> some View {
        GeometryReader { geo in
            let total = Double(s.totalDecisions)
            let spacing: CGFloat = 2
            let segments = [s.manualApproved, s.manualDenied, s.autoApproved, s.autoDenied]
                .filter { $0 > 0 }.count
            let totalSpacing = CGFloat(max(0, segments - 1)) * spacing
            let available = max(0, geo.size.width - totalSpacing)
            let approvedW = available * Double(s.manualApproved) / total
            let deniedW   = available * Double(s.manualDenied)   / total
            let autoW     = available * Double(s.autoApproved)   / total
            let autoDeniedW = available * Double(s.autoDenied)   / total
            HStack(spacing: spacing) {
                if s.manualApproved > 0 {
                    RoundedRectangle(cornerRadius: 3).fill(Color.green).frame(width: approvedW)
                }
                if s.manualDenied > 0 {
                    RoundedRectangle(cornerRadius: 3).fill(Color.red).frame(width: deniedW)
                }
                if s.autoApproved > 0 {
                    RoundedRectangle(cornerRadius: 3).fill(Color.blue).frame(width: autoW)
                }
                if s.autoDenied > 0 {
                    RoundedRectangle(cornerRadius: 3).fill(Color.orange).frame(width: autoDeniedW)
                }
            }
        }
        .frame(height: 12)
    }

    private func approvalLegend(label: String, count: Int, total: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text("\(count)").font(.system(size: 13, weight: .semibold))
                Text(percentString(count, of: total)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Top tools

    private func topToolsSection(_ s: SessionInsightsSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.insightsTopTools)
                .font(.headline)
            if s.topApprovedTools.isEmpty {
                Text(l10n.insightsNoData)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                let maxCount = s.topApprovedTools.first?.count ?? 1
                VStack(spacing: 6) {
                    ForEach(s.topApprovedTools, id: \.tool) { item in
                        toolRow(item: item, maxCount: maxCount)
                    }
                }
            }
        }
    }

    private func toolRow(item: (tool: String, count: Int), maxCount: Int) -> some View {
        GeometryReader { geo in
            let spacing: CGFloat = 8
            let available = max(0, geo.size.width - spacing * 2)
            let labelW    = available * 0.35
            let barContainerW = available * 0.60
            let countW    = available * 0.05
            let barW      = barContainerW * Double(item.count) / Double(maxCount)
            HStack(spacing: spacing) {
                Text(item.tool)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: labelW, alignment: .leading)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green.opacity(0.15))
                        .frame(width: barContainerW)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green.opacity(0.6))
                        .frame(width: barW)
                }
                .frame(height: 14)
                Text("\(item.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: countW, alignment: .trailing)
            }
        }
        .frame(height: 20)
    }

    // MARK: Helpers

    private func durationString(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    private func percentString(_ count: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int(round(Double(count) / Double(total) * 100)))%"
    }
}
