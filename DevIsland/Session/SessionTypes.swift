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
    var terminal: TerminalContext
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
    /// Shell-escaped command to start a fresh session of the given provider kind in this
    /// workspace. Unlike `resumeCommand`, no `--resume` flag is included.
    func newSessionCommand(for provider: BuddyKind) -> String {
        let executable: String?
        switch provider {
        case .claudeCode:  executable = "claude"
        case .codex:       executable = "codex"
        case .gemini:      executable = "gemini"
        case .antigravity: executable = "agy"
        case .island:      executable = nil
        }
        return Self.makeResumeCommand(executable: executable, workspaceRoot: workspaceRoot)
    }

    /// Host-generated, shell-escaped command to resume this session. Shared by the notch UI
    /// and the plugin `session.copyResumeCommand` host command so the plugin never builds
    /// shell strings itself (the host owns sanitization). Empty string means "nothing to copy"
    /// (e.g. an `island` session with no workspace root).
    var resumeCommand: String {
        switch agentKind {
        case .claudeCode:  return Self.makeResumeCommand(executable: "claude", sessionID: id, workspaceRoot: workspaceRoot)
        case .codex:       return Self.makeResumeCommand(executable: "codex", sessionID: id, workspaceRoot: workspaceRoot)
        case .gemini:      return Self.makeResumeCommand(executable: "gemini", workspaceRoot: workspaceRoot)
        case .antigravity: return Self.makeResumeCommand(executable: "agy", workspaceRoot: workspaceRoot)
        case .island:      return Self.makeResumeCommand(workspaceRoot: workspaceRoot)
        }
    }

    static func makeResumeCommand(
        executable: String? = nil,
        sessionID: String? = nil,
        workspaceRoot: String?
    ) -> String {
        var commands: [String] = []
        if let workspaceRoot, !workspaceRoot.isEmpty {
            commands.append("cd \(shellQuote(workspaceRoot))")
        }
        if let executable {
            let resumeArgument = sessionID.map { " --resume \(shellQuote($0))" } ?? ""
            commands.append(executable + resumeArgument)
        }
        return commands.joined(separator: " && ")
    }

    private static func shellQuote(_ value: String) -> String {
        // POSIX single-quote escaping: wrap in single quotes and rewrite any embedded single
        // quote as '\''. Inside single quotes every character is literal, so command
        // substitution (`$(...)`, backticks) and variable expansion can't execute when the
        // copied command is pasted into a shell. Double quotes would still evaluate $/`/$().
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

extension ClosedSessionRecord {
    var resumeCommand: String {
        switch provider {
        case .claude:      return ActiveSession.makeResumeCommand(executable: "claude", sessionID: sessionId, workspaceRoot: workspaceRoot)
        case .codex:       return ActiveSession.makeResumeCommand(executable: "codex", sessionID: sessionId, workspaceRoot: workspaceRoot)
        case .gemini:      return ActiveSession.makeResumeCommand(executable: "gemini", workspaceRoot: workspaceRoot)
        case .antigravity: return ActiveSession.makeResumeCommand(executable: "agy", workspaceRoot: workspaceRoot)
        case .any:         return ActiveSession.makeResumeCommand(workspaceRoot: workspaceRoot)
        }
    }

    /// Shell-escaped command to start a fresh session of the given provider in this workspace.
    func newSessionCommand(for provider: ProviderKind) -> String {
        let executable: String?
        switch provider {
        case .claude:      executable = "claude"
        case .codex:       executable = "codex"
        case .gemini:      executable = "gemini"
        case .antigravity: executable = "agy"
        case .any:         executable = nil
        }
        return ActiveSession.makeResumeCommand(executable: executable, workspaceRoot: workspaceRoot)
    }
}
