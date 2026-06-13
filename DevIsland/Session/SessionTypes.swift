import Foundation

struct PendingRequest: Identifiable {
    let id = UUID()
    let hookEventId: Int64?
    let sessionId: String
    let agentKind: BuddyKind
    let eventName: String
    let toolName: String
    let rawToolName: String
    let workspaceRoot: String?
    let isReplay: Bool
    let message: String
    let claudeQuestion: ClaudeQuestionRequest?
    let responseHandler: (String) -> Void
    let receivedAt: Date
}

struct PendingItem: Identifiable, Equatable {
    let id: UUID
    let toolName: String
    let message: String
    let sessionId: String
    let terminalTitle: String
    let terminalWindowId: String
    let terminalTabIndex: String
    let terminalTmuxPane: String
    let terminalTmuxSocket: String
    let terminalTmuxClient: String
    let receivedAt: Date
}

enum SessionStatus: Equatable {
    case idle
    case pending
    case timeoutBypassed(Date)
    case autoApproved(Date)
    case policyApproved(Date)
    case policyDenied(Date)

    var isTimeoutBypassed: Bool {
        if case .timeoutBypassed = self { return true }
        return false
    }
}

struct ActiveSession: Identifiable, Equatable {
    let id: String // full sessionId
    var terminalTitle: String
    var agentKind: BuddyKind
    var terminalApp: String
    var terminalTTY: String
    var terminalWindowId: String
    var terminalTabIndex: String
    var terminalTmuxPane: String
    var terminalTmuxSocket: String
    var terminalTmuxClient: String
    var lastToolName: String
    var lastEventName: String
    var lastMessage: String
    let startTime: Date
    var lastActiveAt: Date
    var isPending: Bool
    var isLifecycleTracked: Bool
    var isSubAgentSession: Bool
    var isAutoEditActive: Bool
    var isUnread: Bool
    var hasMissedApproval: Bool
    var status: SessionStatus
    var parentSessionId: String?
    var workspaceRoot: String?
}

extension ActiveSession {
    /// Host-generated, shell-escaped command to resume this session. Shared by the notch UI
    /// and the plugin `session.copyResumeCommand` host command so the plugin never builds
    /// shell strings itself (the host owns sanitization). Empty string means "nothing to copy"
    /// (e.g. an `island` session with no workspace root).
    var resumeCommand: String {
        let cd = workspaceRoot.map { Self.shellCdPrefix($0) } ?? ""
        switch agentKind {
        case .claudeCode:  return "\(cd)claude --resume \(id)"
        case .codex:       return "\(cd)codex --resume \(id)"
        case .gemini:      return "\(cd)gemini"
        case .antigravity: return "\(cd)agy"
        case .island:      return cd.isEmpty ? "" : String(cd.dropLast(4)) // cd only
        }
    }

    private static func shellCdPrefix(_ path: String) -> String {
        // POSIX single-quote escaping: wrap in single quotes and rewrite any embedded single
        // quote as '\''. Inside single quotes every character is literal, so command
        // substitution (`$(...)`, backticks) and variable expansion can't execute when the
        // copied command is pasted into a shell. Double quotes would still evaluate $/`/$().
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "cd '\(escaped)' && "
    }
}
