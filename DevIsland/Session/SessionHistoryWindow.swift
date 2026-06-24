import SwiftUI
import AppKit

// MARK: - ViewModel

enum SessionHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case favorites

    var id: String { rawValue }
}

enum SessionHistoryEntry: Identifiable {
    case live(ActiveSession)
    case closed(ClosedSessionRecord)

    var id: String { "\(isLive ? "live" : "closed")-\(sessionId)" }
    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    var sessionId: String {
        switch self {
        case .live(let session): return session.id
        case .closed(let record): return record.sessionId
        }
    }

    var provider: ProviderKind {
        switch self {
        case .live(let session): return session.agentKind.providerKind
        case .closed(let record): return record.provider
        }
    }

    var workspaceRoot: String? {
        switch self {
        case .live(let session): return session.workspaceRoot
        case .closed(let record): return record.workspaceRoot
        }
    }

    var terminalApp: String? {
        switch self {
        case .live(let session): return session.terminal.app.isEmpty ? nil : session.terminal.app
        case .closed(let record): return record.terminalApp
        }
    }

    var terminalTitle: String? {
        switch self {
        case .live(let session): return session.terminalTitle.isEmpty ? nil : session.terminalTitle
        case .closed(let record): return record.terminalTitle
        }
    }

    var endedAt: Date? {
        if case .closed(let record) = self { return record.endedAt }
        return nil
    }

    var resumeCommand: String {
        switch self {
        case .live(let session): return session.resumeCommand
        case .closed(let record): return record.resumeCommand
        }
    }

    func newSessionCommand(for provider: ProviderKind) -> String {
        switch self {
        case .live(let session):
            return session.newSessionCommand(for: provider.buddyKind)
        case .closed(let record):
            return record.newSessionCommand(for: provider)
        }
    }
}

@MainActor
final class SessionHistoryViewModel: ObservableObject {
    @Published var closedRecords: [ClosedSessionRecord] = []
    @Published var searchText: String = ""
    @Published var filter: SessionHistoryFilter = .all
    @Published var errorMessage: String?

    private let appState: AppState

    init(appState: AppState = .shared) {
        self.appState = appState
        refresh()
    }

    func entries(activeSessions: [ActiveSession]) -> [SessionHistoryEntry] {
        let activeIds = Set(activeSessions.map(\.id))
        let live = activeSessions.map(SessionHistoryEntry.live)
        let closed = closedRecords
            .filter { !activeIds.contains($0.sessionId) }
            .map(SessionHistoryEntry.closed)
        return live + closed
    }

    func filtered(activeSessions: [ActiveSession]) -> [SessionHistoryEntry] {
        entries(activeSessions: activeSessions).filter { entry in
            let matchesFavorite = filter == .all || appState.isSessionFavorite(entry.sessionId)
            let matchesSearch = searchText.isEmpty
                || entry.sessionId.localizedCaseInsensitiveContains(searchText)
                || (entry.workspaceRoot?.localizedCaseInsensitiveContains(searchText) ?? false)
                || (entry.terminalTitle?.localizedCaseInsensitiveContains(searchText) ?? false)
                || entry.provider.rawValue.localizedCaseInsensitiveContains(searchText)
                || (appState.sessionLabels[entry.sessionId]?.localizedCaseInsensitiveContains(searchText) ?? false)
                || (appState.sessionDescriptions[entry.sessionId]?.localizedCaseInsensitiveContains(searchText) ?? false)
            return matchesFavorite && matchesSearch
        }
    }

    func refresh() {
        let days = SettingsStore.shared.settings.replayRetentionDays
        Task {
            do {
                let fetched = try await Task.detached(priority: .userInitiated) { [appState] in
                    try appState.closedSessionRecords(retentionDays: days)
                }.value
                closedRecords = fetched
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func resumeCommand(for entry: SessionHistoryEntry) -> String {
        entry.resumeCommand
    }

    func autoTerminalName(for entry: SessionHistoryEntry) -> String {
        TerminalFocuser.resolvedTerminalName(
            preferred: SettingsStore.shared.settings.preferredTerminal,
            sessionTerminal: entry.terminalApp
        ) ?? "?"
    }

    func openInTerminal(_ entry: SessionHistoryEntry, appName: String? = nil) {
        let name = appName ?? autoTerminalName(for: entry)
        TerminalFocuser.openNewWindow(appName: name, command: resumeCommand(for: entry))
    }

    func startNewSession(_ entry: SessionHistoryEntry, provider: ProviderKind) {
        let name = autoTerminalName(for: entry)
        TerminalFocuser.openNewWindow(appName: name, command: entry.newSessionCommand(for: provider))
    }
}

// MARK: - Window View

struct SessionHistoryWindowView: View {
    @StateObject private var viewModel: SessionHistoryViewModel
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var sessionStore = AppState.shared.sessionStore

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
            if viewModel.filtered(activeSessions: sessionStore.activeSessions).isEmpty {
                ContentUnavailableView(
                    l10n.historyEmpty,
                    systemImage: "clock.arrow.circlepath"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sessionList
            }
        }
        .frame(minWidth: 760, minHeight: 400)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField(l10n.historySearch, text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Picker("", selection: $viewModel.filter) {
                Text(l10n.historyFilterAll).tag(SessionHistoryFilter.all)
                Text(l10n.historyFilterFavorites).tag(SessionHistoryFilter.favorites)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Spacer()

            Text(l10n.historyCount(viewModel.filtered(activeSessions: sessionStore.activeSessions).count))
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
        Table(viewModel.filtered(activeSessions: sessionStore.activeSessions)) {
            TableColumn(l10n.historyColFavorite) { entry in
                Button {
                    appState.toggleSessionFavorite(entry.sessionId)
                } label: {
                    Image(systemName: appState.isSessionFavorite(entry.sessionId) ? "star.fill" : "star")
                        .foregroundStyle(appState.isSessionFavorite(entry.sessionId) ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(appState.isSessionFavorite(entry.sessionId) ? l10n.menuRemoveFavorite : l10n.menuAddFavorite)
            }
            .width(44)

            TableColumn(l10n.historyColStatus) { entry in
                Text(entry.isLive ? l10n.historyStatusLive : l10n.historyStatusEnded)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(entry.isLive ? Color.green : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((entry.isLive ? Color.green : Color.secondary).opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .width(72)

            TableColumn(l10n.historyColAgent) { entry in
                HStack(spacing: 4) {
                    Image(systemName: providerIcon(entry.provider))
                        .foregroundStyle(providerColor(entry.provider))
                    Text(entry.provider.rawValue)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .width(90)

            TableColumn(l10n.historyColPath) { entry in
                if let path = entry.workspaceRoot {
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

            TableColumn(l10n.historyColLabel) { entry in
                if let label = appState.sessionLabels[entry.sessionId] {
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

            TableColumn(l10n.historyColDescription) { entry in
                if let description = appState.sessionDescriptions[entry.sessionId], !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(description)
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn(l10n.historyColTitle) { entry in
                Text(entry.terminalTitle ?? "—")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(entry.terminalTitle == nil ? .secondary : .primary)
            }
            .width(120)

            TableColumn(l10n.historyColEnded) { entry in
                if let endedAt = entry.endedAt {
                    Text(endedAt, style: .relative)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .width(100)

            TableColumn(l10n.historyColSession) { entry in
                Text(String(entry.sessionId.prefix(8)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(80)
        }
        .contextMenu(forSelectionType: SessionHistoryEntry.ID.self) { ids in
            if let id = ids.first,
               let entry = viewModel.entries(activeSessions: sessionStore.activeSessions).first(where: { $0.id == id }) {
                Button {
                    AppState.shared.promptRenameSession(
                        entry.sessionId,
                        currentLabel: appState.sessionLabels[entry.sessionId]
                    )
                } label: {
                    Label(l10n.menuRenameSession, systemImage: "pencil")
                }

                Button {
                    AppState.shared.promptEditSessionDescription(
                        entry.sessionId,
                        currentDescription: appState.sessionDescriptions[entry.sessionId]
                    )
                } label: {
                    Label(l10n.menuEditSessionDescription, systemImage: "text.bubble")
                }

                Button {
                    AppState.shared.toggleSessionFavorite(entry.sessionId)
                } label: {
                    Label(
                        appState.isSessionFavorite(entry.sessionId) ? l10n.menuRemoveFavorite : l10n.menuAddFavorite,
                        systemImage: appState.isSessionFavorite(entry.sessionId) ? "star.slash" : "star"
                    )
                }

                Divider()

                if let path = entry.workspaceRoot {
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
                let auto = viewModel.autoTerminalName(for: entry)
                Menu {
                    Button { viewModel.openInTerminal(entry) } label: {
                        Label(l10n.menuTerminalAuto(auto), systemImage: "terminal")
                    }
                    if !installed.isEmpty {
                        Divider()
                        ForEach(installed, id: \.name) { terminal in
                            Button { viewModel.openInTerminal(entry, appName: terminal.name) } label: {
                                Label(terminal.name, systemImage: terminal.name == auto ? "checkmark" : "terminal")
                            }
                        }
                    }
                } label: {
                    Label(l10n.menuOpenInTerminal, systemImage: "terminal")
                }

                if let root = entry.workspaceRoot, !root.isEmpty {
                    let providers: [(ProviderKind, String)] = [
                        (.claude, "Claude"), (.codex, "Codex"),
                        (.gemini, "Gemini"), (.antigravity, "Antigravity"),
                    ]
                    Menu {
                        ForEach(providers, id: \.0) { provider, name in
                            Button { viewModel.startNewSession(entry, provider: provider) } label: {
                                Label(name, systemImage: "terminal")
                            }
                        }
                    } label: {
                        Label(l10n.menuStartNewSession, systemImage: "plus.square.on.square")
                    }
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        viewModel.resumeCommand(for: entry),
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
        case .antigravity: return "a.circle.fill"
        case .any:    return "circle.fill"
        }
    }

    private func providerColor(_ provider: ProviderKind) -> Color {
        switch provider {
        case .claude: return Color(red: 0.8, green: 0.5, blue: 0.2)
        case .codex:  return Color(red: 0.2, green: 0.7, blue: 0.4)
        case .gemini: return Color(red: 0.2, green: 0.5, blue: 0.9)
        case .antigravity: return Color(red: 0.05, green: 0.70, blue: 0.60)
        case .any:    return .secondary
        }
    }
}

private extension BuddyKind {
    var providerKind: ProviderKind {
        switch self {
        case .claudeCode: return .claude
        case .codex: return .codex
        case .gemini: return .gemini
        case .antigravity: return .antigravity
        case .island: return .any
        }
    }
}

private extension ProviderKind {
    var buddyKind: BuddyKind {
        switch self {
        case .claude: return .claudeCode
        case .codex: return .codex
        case .gemini: return .gemini
        case .antigravity: return .antigravity
        case .any: return .island
        }
    }
}
