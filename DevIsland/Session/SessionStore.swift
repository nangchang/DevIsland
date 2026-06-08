import Foundation
import Combine

/// Neutral description of a session list change. Contains a pre-mutation snapshot
/// so callers can act on the session state regardless of insertion or removal order.
/// SessionStore never imports PluginHost or any plugin type — consumers map this to
/// their own domain events.
enum SessionStoreChange {
    case started(ActiveSession)
    case updated(ActiveSession)
    case ended(ActiveSession)  // snapshot captured before removal
}

/// Owns the live session list, pending approval queue, and per-session auto-approve cache.
///
/// AppState holds an instance and delegates all session-level state mutations here.
/// SwiftUI views that render session data must observe this object directly —
/// SwiftUI does not propagate changes through a nested ObservableObject automatically.
final class SessionStore: ObservableObject {
    @Published var activeSessions: [ActiveSession] = [] {
        didSet {
            if let selected = selectedSessionId, !activeSessions.contains(where: { $0.id == selected }) {
                selectedSessionId = activeSessions.first?.id
            }
        }
    }
    @Published var selectedSessionId: String?
    @Published var pendingItems: [PendingItem] = []
    @Published var sessionAutoApproveTypes: [String: Set<String>] = [:]

    private(set) var pendingQueue: [PendingRequest] = []

    var pendingCount: Int { pendingItems.count }

    /// Called on the main thread after each session insert/update, and after each removal
    /// (with a pre-removal snapshot so the removed session's data is still accessible).
    var onSessionChanged: ((SessionStoreChange) -> Void)?

    private let timeoutDuration: Double
    private let lifecycleSessionTimeout: Double

    static let genericTitles: Set<String> = ["Terminal", "iTerm", "Ghostty", "Warp", ""]

    init(timeoutDuration: Double = 120, lifecycleSessionTimeout: Double = 24 * 60 * 60) {
        self.timeoutDuration = timeoutDuration
        self.lifecycleSessionTimeout = lifecycleSessionTimeout
    }

    // MARK: - Session list

    func updateActiveSession(
        sessionId: String,
        terminalTitle: String,
        agentKind: BuddyKind,
        terminalApp: String,
        terminalTTY: String,
        terminalWindowId: String,
        terminalTabIndex: String,
        terminalTmuxPane: String,
        terminalTmuxSocket: String,
        terminalTmuxClient: String,
        toolName: String,
        eventName: String,
        message: String,
        isPending: Bool,
        preserveMessage: Bool = false,
        isLifecycleTracked: Bool = false,
        isSubAgentSession: Bool = false,
        parentSessionId: String? = nil,
        status: SessionStatus? = nil,
        workspaceRoot: String? = nil,
        startTime: Date? = nil
    ) {
        if let index = activeSessions.firstIndex(where: { $0.id == sessionId }) {
            let shouldUpdateTitle = !Self.genericTitles.contains(terminalTitle)
                || Self.genericTitles.contains(activeSessions[index].terminalTitle)
            if shouldUpdateTitle {
                activeSessions[index].terminalTitle = terminalTitle
            }
            activeSessions[index].agentKind = agentKind
            if !terminalApp.isEmpty { activeSessions[index].terminalApp = terminalApp }
            if !terminalTTY.isEmpty { activeSessions[index].terminalTTY = terminalTTY }
            if !terminalWindowId.isEmpty { activeSessions[index].terminalWindowId = terminalWindowId }
            if !terminalTabIndex.isEmpty { activeSessions[index].terminalTabIndex = terminalTabIndex }
            if !terminalTmuxPane.isEmpty { activeSessions[index].terminalTmuxPane = terminalTmuxPane }
            if !terminalTmuxSocket.isEmpty { activeSessions[index].terminalTmuxSocket = terminalTmuxSocket }
            if !terminalTmuxClient.isEmpty { activeSessions[index].terminalTmuxClient = terminalTmuxClient }
            activeSessions[index].lastToolName = toolName
            activeSessions[index].lastEventName = eventName
            if !preserveMessage { activeSessions[index].lastMessage = message }
            activeSessions[index].lastActiveAt = Date()
            activeSessions[index].isPending = isPending
            activeSessions[index].status = status ?? (isPending ? .pending : .idle)
            if isLifecycleTracked { activeSessions[index].isLifecycleTracked = true }
            if isSubAgentSession { activeSessions[index].isSubAgentSession = true }
            if let pid = parentSessionId { activeSessions[index].parentSessionId = pid }
            if let root = workspaceRoot, activeSessions[index].workspaceRoot == nil {
                activeSessions[index].workspaceRoot = root
            }
            onSessionChanged?(.updated(activeSessions[index]))
        } else {
            let session = ActiveSession(
                id: sessionId,
                terminalTitle: terminalTitle,
                agentKind: agentKind,
                terminalApp: terminalApp,
                terminalTTY: terminalTTY,
                terminalWindowId: terminalWindowId,
                terminalTabIndex: terminalTabIndex,
                terminalTmuxPane: terminalTmuxPane,
                terminalTmuxSocket: terminalTmuxSocket,
                terminalTmuxClient: terminalTmuxClient,
                lastToolName: toolName,
                lastEventName: eventName,
                lastMessage: message,
                startTime: startTime ?? Date(),
                lastActiveAt: Date(),
                isPending: isPending,
                isLifecycleTracked: isLifecycleTracked,
                isSubAgentSession: isSubAgentSession,
                isAutoEditActive: false,
                isUnread: false,
                hasMissedApproval: false,
                status: status ?? (isPending ? .pending : .idle),
                parentSessionId: parentSessionId,
                workspaceRoot: workspaceRoot
            )
            activeSessions.insert(session, at: 0)
            onSessionChanged?(.started(session))
        }
    }

    /// Removes older Codex sessions that belong to the same terminal identity as a new SessionStart.
    /// Codex does not emit SessionEnd, so a new start in the same terminal is the best lifecycle boundary.
    @discardableResult
    func removeSupersededCodexSessions(
        newSessionId: String,
        terminalApp: String,
        terminalTTY: String,
        terminalWindowId: String,
        terminalTabIndex: String,
        terminalTmuxPane: String,
        terminalTmuxSocket: String,
        terminalTmuxClient: String
    ) -> [String] {
        let ids = activeSessions
            .filter { session in
                session.agentKind == .codex &&
                    session.id != newSessionId &&
                    !session.isSubAgentSession &&
                    Self.sameTerminalIdentity(
                        session,
                        terminalApp: terminalApp,
                        terminalTTY: terminalTTY,
                        terminalWindowId: terminalWindowId,
                        terminalTabIndex: terminalTabIndex,
                        terminalTmuxPane: terminalTmuxPane,
                        terminalTmuxSocket: terminalTmuxSocket,
                        terminalTmuxClient: terminalTmuxClient
                    )
            }
            .map(\.id)

        guard !ids.isEmpty else { return [] }
        let snapshots = activeSessions.filter { ids.contains($0.id) }
        ids.forEach { sessionAutoApproveTypes.removeValue(forKey: $0) }
        activeSessions.removeAll { ids.contains($0.id) }
        snapshots.forEach { onSessionChanged?(.ended($0)) }
        return ids
    }

    private static func sameTerminalIdentity(
        _ session: ActiveSession,
        terminalApp: String,
        terminalTTY: String,
        terminalWindowId: String,
        terminalTabIndex: String,
        terminalTmuxPane: String,
        terminalTmuxSocket: String,
        terminalTmuxClient: String
    ) -> Bool {
        if !session.terminalTmuxPane.isEmpty,
           !terminalTmuxPane.isEmpty,
           session.terminalTmuxPane == terminalTmuxPane,
           session.terminalTmuxSocket == terminalTmuxSocket,
           session.terminalTmuxClient == terminalTmuxClient {
            return true
        }

        if !session.terminalTmuxPane.isEmpty || !terminalTmuxPane.isEmpty {
            return false
        }

        if !session.terminalTTY.isEmpty,
           !terminalTTY.isEmpty,
           session.terminalTTY == terminalTTY {
            return true
        }

        if !session.terminalApp.isEmpty,
           !terminalApp.isEmpty,
           !session.terminalWindowId.isEmpty,
           !terminalWindowId.isEmpty,
           session.terminalApp == terminalApp,
           session.terminalWindowId == terminalWindowId,
           session.terminalTabIndex == terminalTabIndex {
            return true
        }

        return false
    }

    /// Prunes sessions that have been inactive beyond their threshold.
    /// Returns the session IDs that were removed so the caller can clean up associated resources (e.g. PTY buffers).
    @discardableResult
    func pruneInactiveSessions() -> [String] {
        let now = Date()
        let sessionsToPrune = activeSessions.filter { session in
            let inactiveFor = now.timeIntervalSince(session.lastActiveAt)
            let max = session.isLifecycleTracked ? lifecycleSessionTimeout : timeoutDuration
            return !session.isPending && inactiveFor > max
        }
        for session in sessionsToPrune {
            sessionAutoApproveTypes.removeValue(forKey: session.id)
        }
        let ids = sessionsToPrune.map(\.id)
        activeSessions.removeAll { s in ids.contains(s.id) }
        sessionsToPrune.forEach { onSessionChanged?(.ended($0)) }
        return ids
    }

    // MARK: - Pending queue

    func appendPending(request: PendingRequest, item: PendingItem) {
        pendingQueue.append(request)
        pendingItems.append(item)
    }

    /// Removes and returns the first pending request and its display item (ID-matched).
    @discardableResult
    func removeFirstPending() -> PendingRequest? {
        guard !pendingQueue.isEmpty else { return nil }
        let request = pendingQueue.removeFirst()
        pendingItems.removeAll { $0.id == request.id }
        return request
    }

    /// Removes and returns the pending request with the matching ID.
    @discardableResult
    func removePending(id: UUID) -> PendingRequest? {
        guard let index = pendingQueue.firstIndex(where: { $0.id == id }) else { return nil }
        let request = pendingQueue.remove(at: index)
        pendingItems.removeAll { $0.id == id }
        return request
    }

    /// Removes all pending requests for `sessionId`. Returns the removed requests.
    func removeAllPending(sessionId: String) -> [PendingRequest] {
        let removed = pendingQueue.filter { $0.sessionId == sessionId }
        pendingQueue.removeAll { $0.sessionId == sessionId }
        pendingItems.removeAll { $0.sessionId == sessionId }
        return removed
    }

    func setUnread(_ unread: Bool, sessionId: String) {
        guard let index = activeSessions.firstIndex(where: { $0.id == sessionId }) else { return }
        activeSessions[index].isUnread = unread
    }

    func setMissedApproval(_ missed: Bool, sessionId: String) {
        guard let index = activeSessions.firstIndex(where: { $0.id == sessionId }) else { return }
        activeSessions[index].hasMissedApproval = missed
    }

    /// Removes `sessionId` from activeSessions and clears session-scoped auto-approve cache.
    func removeSession(id sessionId: String) {
        let snapshot = activeSessions.first { $0.id == sessionId }
        sessionAutoApproveTypes.removeValue(forKey: sessionId)
        activeSessions.removeAll { $0.id == sessionId }
        if let snapshot {
            onSessionChanged?(.ended(snapshot))
        }
    }
}
