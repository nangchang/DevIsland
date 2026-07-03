import SwiftUI

@MainActor
final class PTYTranscriptViewModel: ObservableObject {
    @Published var sessions: [String] = []
    @Published var selectedSession: String?
    @Published var messages: [PTYMessage] = []
    @Published var errorMessage: String?

    private let appState: AppState

    init(appState: AppState? = nil) {
        self.appState = appState ?? .shared
        refresh()
    }

    func refresh() {
        do {
            let all = try appState.ptyMessages(limit: 1000)
            var seen: [String] = []
            var seenSet: Set<String> = []
            for msg in all {
                if !seenSet.contains(msg.sessionId) {
                    seen.append(msg.sessionId)
                    seenSet.insert(msg.sessionId)
                }
            }
            sessions = seen
            if let selected = selectedSession, seenSet.contains(selected) {
                loadMessages(for: selected)
            } else {
                selectedSession = seen.first
                if let first = seen.first {
                    loadMessages(for: first)
                } else {
                    messages = []
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectSession(_ sessionId: String) {
        selectedSession = sessionId
        loadMessages(for: sessionId)
    }

    private func loadMessages(for sessionId: String) {
        do {
            messages = try appState.ptyMessages(sessionId: sessionId, limit: 500).reversed()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PTYTranscriptWindowView: View {
    @StateObject private var viewModel: PTYTranscriptViewModel

    init(appState: AppState? = nil) {
        _viewModel = StateObject(wrappedValue: PTYTranscriptViewModel(appState: appState))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(12)
            }
            content
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label("PTY Transcript", systemImage: "terminal")
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
            List(viewModel.sessions, id: \.self, selection: Binding(
                get: { viewModel.selectedSession },
                set: { if let s = $0 { viewModel.selectSession(s) } }
            )) { sessionId in
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionId)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
                .tag(sessionId)
            }
            .frame(minWidth: 200, idealWidth: 240)

            PTYMessageList(messages: viewModel.messages)
                .frame(minWidth: 480)
        }
    }
}

private struct PTYMessageList: View {
    let messages: [PTYMessage]

    var body: some View {
        Group {
            if messages.isEmpty {
                ContentUnavailableView("No PTY Messages", systemImage: "terminal")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(messages) { msg in
                            PTYMessageRow(message: msg)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct PTYMessageRow: View {
    let message: PTYMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.direction == .output ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(message.direction == .output ? Color.secondary : Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.timestamp.string(from: message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(message.direction == .input ? Color.accentColor.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}
