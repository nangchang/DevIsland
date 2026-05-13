import SwiftUI

@MainActor
final class ReplayLogViewModel: ObservableObject {
    @Published var entries: [ReplayLogEntry] = []
    @Published var selectedEntryID: ReplayLogEntry.ID?
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let appState: AppState

    init(appState: AppState = .shared) {
        self.appState = appState
        refresh()
    }

    var selectedEntry: ReplayLogEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    func refresh() {
        do {
            entries = try appState.replayLogEntries()
            if selectedEntryID == nil || !entries.contains(where: { $0.id == selectedEntryID }) {
                selectedEntryID = entries.first?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createRule(action: RuleAction) {
        guard let selectedEntry else { return }
        do {
            try appState.addPersistentRule(from: selectedEntry, action: action)
            statusMessage = "\(selectedEntry.provider.rawValue) \(selectedEntry.toolName) \(action.rawValue) rule saved"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ReplayLogWindowView: View {
    @StateObject private var viewModel = ReplayLogViewModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(12)
            }
            if let statusMessage = viewModel.statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            content
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label("Replay Log", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Spacer()
            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(12)
    }

    private var content: some View {
        HSplitView {
            List(viewModel.entries, selection: $viewModel.selectedEntryID) { entry in
                ReplayLogRow(entry: entry)
                    .tag(entry.id)
            }
            .frame(minWidth: 320, idealWidth: 380)

            ReplayLogDetail(
                entry: viewModel.selectedEntry,
                createRule: viewModel.createRule
            )
            .frame(minWidth: 420)
        }
    }
}

private struct ReplayLogRow: View {
    let entry: ReplayLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.provider.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.eventName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let decisionAction = entry.decisionAction {
                    Text(decisionAction.rawValue)
                        .font(.caption)
                        .foregroundStyle(color(for: decisionAction))
                }
            }
            Text(entry.toolName.isEmpty ? "Unknown tool" : entry.toolName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(entry.sessionId)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Self.timestamp.string(from: entry.receivedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func color(for action: RuleAction) -> Color {
        switch action {
        case .allow: return .green
        case .deny: return .red
        case .prompt: return .secondary
        }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct ReplayLogDetail: View {
    let entry: ReplayLogEntry?
    let createRule: (RuleAction) -> Void

    var body: some View {
        Group {
            if let entry {
                VStack(alignment: .leading, spacing: 14) {
                    header(entry)
                    Divider()
                    decision(entry)
                    Divider()
                    payload(entry)
                    Spacer(minLength: 0)
                }
                .padding(16)
            } else {
                ContentUnavailableView("No Replay Events", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    private func header(_ entry: ReplayLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.toolName.isEmpty ? "Unknown tool" : entry.toolName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 8) {
                    Button("Allow Rule") { createRule(.allow) }
                        .disabled(entry.toolName.isEmpty)
                    Button("Deny Rule") { createRule(.deny) }
                        .disabled(entry.toolName.isEmpty)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                detailRow("Provider", entry.provider.rawValue)
                detailRow("Event", entry.eventName)
                detailRow("Session", entry.sessionId)
                detailRow("Received", Self.timestamp.string(from: entry.receivedAt))
                if let requestId = entry.requestId {
                    detailRow("Request ID", requestId)
                }
            }
        }
    }

    private func decision(_ entry: ReplayLogEntry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            detailRow("Decision", entry.decisionAction?.rawValue ?? "none")
            detailRow("Source", entry.decisionSource?.rawValue ?? "none")
            if let decidedAt = entry.decidedAt {
                detailRow("Decided", Self.timestamp.string(from: decidedAt))
            }
            if let reason = entry.decisionReason {
                detailRow("Reason", reason)
            }
        }
    }

    private func payload(_ entry: ReplayLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payload")
                .font(.headline)
            ScrollView {
                Text(entry.payloadJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
