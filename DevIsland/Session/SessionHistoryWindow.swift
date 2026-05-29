import SwiftUI
import AppKit

// MARK: - ViewModel

@MainActor
final class SessionHistoryViewModel: ObservableObject {
    @Published var records: [ClosedSessionRecord] = []
    @Published var searchText: String = ""
    @Published var errorMessage: String?

    private let appState: AppState

    init(appState: AppState = .shared) {
        self.appState = appState
        refresh()
    }

    var filtered: [ClosedSessionRecord] {
        guard !searchText.isEmpty else { return records }
        return records.filter {
            $0.sessionId.localizedCaseInsensitiveContains(searchText)
            || ($0.workspaceRoot?.localizedCaseInsensitiveContains(searchText) ?? false)
            || ($0.terminalTitle?.localizedCaseInsensitiveContains(searchText) ?? false)
            || $0.provider.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    func refresh() {
        do {
            records = try appState.closedSessionRecords(
                retentionDays: SettingsStore.shared.settings.replayRetentionDays
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resumeCommand(for record: ClosedSessionRecord) -> String {
        let cd = record.workspaceRoot.map { shellCdPrefix($0) } ?? ""
        switch record.provider {
        case .claude: return "\(cd)claude --resume \(record.sessionId)"
        case .codex:  return "\(cd)codex --resume \(record.sessionId)"
        case .gemini: return "\(cd)gemini"
        case .any:    return cd.isEmpty ? "" : String(cd.dropLast(4))
        }
    }

    func autoTerminalName(for record: ClosedSessionRecord) -> String {
        TerminalFocuser.resolvedTerminalName(
            preferred: SettingsStore.shared.settings.preferredTerminal,
            sessionTerminal: record.terminalApp
        ) ?? "?"
    }

    func openInTerminal(_ record: ClosedSessionRecord, appName: String? = nil) {
        let name = appName ?? autoTerminalName(for: record)
        TerminalFocuser.openNewWindow(appName: name, command: resumeCommand(for: record))
    }

    private func shellCdPrefix(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        return "cd \"\(escaped)\" && "
    }
}

// MARK: - Window View

struct SessionHistoryWindowView: View {
    @StateObject private var viewModel: SessionHistoryViewModel
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var appState = AppState.shared

    init(appState: AppState = .shared) {
        _viewModel = StateObject(wrappedValue: SessionHistoryViewModel(appState: appState))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let err = viewModel.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(12)
            }
            if viewModel.filtered.isEmpty {
                ContentUnavailableView(
                    l10n.historyEmpty,
                    systemImage: "clock.arrow.circlepath"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sessionList
            }
        }
        .frame(minWidth: 700, minHeight: 400)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField(l10n.historySearch, text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Spacer()

            Text(l10n.historyCount(viewModel.filtered.count))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(l10n.historyRefresh)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sessionList: some View {
        Table(viewModel.filtered) {
            TableColumn(l10n.historyColAgent) { record in
                HStack(spacing: 4) {
                    Image(systemName: providerIcon(record.provider))
                        .foregroundStyle(providerColor(record.provider))
                    Text(record.provider.rawValue)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .width(90)

            TableColumn(l10n.historyColPath) { record in
                if let path = record.workspaceRoot {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }

            TableColumn(l10n.historyColLabel) { record in
                if let label = appState.sessionLabels[record.sessionId] {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(label)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .width(120)

            TableColumn(l10n.historyColTitle) { record in
                Text(record.terminalTitle ?? "—")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(record.terminalTitle == nil ? .secondary : .primary)
            }
            .width(120)

            TableColumn(l10n.historyColEnded) { record in
                Text(record.endedAt, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .width(100)

            TableColumn(l10n.historyColSession) { record in
                Text(String(record.sessionId.prefix(8)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(80)
        }
        .contextMenu(forSelectionType: ClosedSessionRecord.ID.self) { ids in
            if let id = ids.first,
               let record = viewModel.records.first(where: { $0.id == id }) {
                Button {
                    AppState.shared.promptRenameSession(
                        record.sessionId,
                        currentLabel: appState.sessionLabels[record.sessionId]
                    )
                } label: {
                    Label(l10n.menuRenameSession, systemImage: "pencil")
                }

                Divider()

                if let path = record.workspaceRoot {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    } label: {
                        Label(l10n.menuOpenInFinder, systemImage: "folder")
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    } label: {
                        Label(l10n.menuCopyPath, systemImage: "doc.on.clipboard")
                    }

                    Divider()
                }

                let installed = TerminalFocuser.installedTerminals
                let auto = viewModel.autoTerminalName(for: record)
                Menu {
                    Button { viewModel.openInTerminal(record) } label: {
                        Label(l10n.menuTerminalAuto(auto), systemImage: "terminal")
                    }
                    if !installed.isEmpty {
                        Divider()
                        ForEach(installed, id: \.name) { terminal in
                            Button { viewModel.openInTerminal(record, appName: terminal.name) } label: {
                                Label(terminal.name, systemImage: terminal.name == auto ? "checkmark" : "terminal")
                            }
                        }
                    }
                } label: {
                    Label(l10n.menuOpenInTerminal, systemImage: "terminal")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        viewModel.resumeCommand(for: record),
                        forType: .string
                    )
                } label: {
                    Label(l10n.menuCopyResumeCommand, systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    private func providerIcon(_ provider: ProviderKind) -> String {
        switch provider {
        case .claude: return "c.circle.fill"
        case .codex:  return "o.circle.fill"
        case .gemini: return "g.circle.fill"
        case .any:    return "circle.fill"
        }
    }

    private func providerColor(_ provider: ProviderKind) -> Color {
        switch provider {
        case .claude: return Color(red: 0.8, green: 0.5, blue: 0.2)
        case .codex:  return Color(red: 0.2, green: 0.7, blue: 0.4)
        case .gemini: return Color(red: 0.2, green: 0.5, blue: 0.9)
        case .any:    return .secondary
        }
    }
}
