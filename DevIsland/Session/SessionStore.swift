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

    /// Derives a display title for a restored session from its stored hook payload:
    /// an explicit non-generic terminal title, else the cwd's last path component,
    /// else "Session".
    static func restoredTitle(fromPayload json: [String: Any]) -> String {
        if let title = json["terminal_title"] as? String, !genericTitles.contains(title) {
            return title
        }
        // 빈 cwd를 URL(fileURLWithPath:)에 넘기면 프로세스의 현재 디렉토리로 해석돼
        // 엉뚱한 이름이 잡히므로 비어 있지 않을 때만 경로 컴포넌트를 사용한다.
        if let cwd = json["cwd"] as? String, !cwd.isEmpty {
            let label = URL(fileURLWithPath: cwd).lastPathComponent
            return (!label.isEmpty && label != "/") ? label : "Session"
        }
        return "Session"
    }

    init(timeoutDuration: Double = 120, lifecycleSessionTimeout: Double = 24 * 60 * 60) {
        self.timeoutDuration = timeoutDuration
        self.lifecycleSessionTimeout = lifecycleSessionTimeout
    }

    // MARK: - Session list

    func updateActiveSession(
        sessionId: String,
        terminalTitle: String,
        agentKind: BuddyKind,
        terminal: TerminalContext,
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
        startTime: Date? = nil,
        lastActiveAt: Date? = nil
    ) {
        if let index = activeSessions.firstIndex(where: { $0.id == sessionId }) {
            let shouldUpdateTitle = !Self.genericTitles.contains(terminalTitle)
                || Self.genericTitles.contains(activeSessions[index].terminalTitle)
            if shouldUpdateTitle {
                activeSessions[index].terminalTitle = terminalTitle
            }
            activeSessions[index].agentKind = agentKind
            activeSessions[index].terminal.merge(terminal)
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
                terminal: terminal,
                lastToolName: toolName,
                lastEventName: eventName,
                lastMessage: message,
                startTime: startTime ?? Date(),
                lastActiveAt: lastActiveAt ?? Date(),
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
        terminal: TerminalContext
    ) -> [String] {
        let ids = activeSessions
            .filter { session in
                session.agentKind == .codex &&
                    session.id != newSessionId &&
                    !session.isSubAgentSession &&
                    session.terminal.isSameIdentity(as: terminal)
            }
            .map(\.id)

        guard !ids.isEmpty else { return [] }
        let snapshots = activeSessions.filter { ids.contains($0.id) }
        ids.forEach { sessionAutoApproveTypes.removeValue(forKey: $0) }
        activeSessions.removeAll { ids.contains($0.id) }
        snapshots.forEach { onSessionChanged?(.ended($0)) }
        return ids
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
