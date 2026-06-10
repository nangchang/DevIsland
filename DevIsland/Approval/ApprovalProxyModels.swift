import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case any
    case claude
    case codex
    case gemini
    case antigravity

    var id: String { rawValue }

    init(source: String) {
        switch source.lowercased() {
        case "claude", "claudecode", "claude_code":
            self = .claude
        case "codex", "openai":
            self = .codex
        case "gemini":
            self = .gemini
        case "antigravity":
            self = .antigravity
        default:
            self = .any
        }
    }
}

enum MatchKind: String, Codable, CaseIterable, Identifiable {
    /// Phase 3 persists every planned match kind so settings/rule UI can share the
    /// model early. SQLiteApprovalStore intentionally evaluates only `exact`
    /// persistent rules until the dedicated matcher work lands in a later phase.
    case exact
    case glob
    case regex
    case commandPrefix
    case pathPrefix

    var id: String { rawValue }
}

enum RuleAction: String, Codable, CaseIterable, Identifiable {
    case allow
    case deny
    case prompt

    var id: String { rawValue }
}

enum RuleScope: String, Codable, CaseIterable, Identifiable {
    case once
    case session
    case persistent

    var id: String { rawValue }
}

struct ApprovalRule: Identifiable, Codable, Equatable {
    var id: UUID
    var provider: ProviderKind
    var toolName: String
    var matchKind: MatchKind
    var pattern: String
    var action: RuleAction
    var scope: RuleScope
    var riskFloor: ToolRiskLevel?
    var workspaceRoot: String?
    var createdAt: Date
    var expiresAt: Date?
    var enabled: Bool

    init(
        id: UUID = UUID(),
        provider: ProviderKind,
        toolName: String,
        matchKind: MatchKind = .exact,
        pattern: String? = nil,
        action: RuleAction,
        scope: RuleScope,
        riskFloor: ToolRiskLevel? = nil,
        workspaceRoot: String? = nil,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.toolName = toolName
        self.matchKind = matchKind
        self.pattern = pattern ?? toolName
        self.action = action
        self.scope = scope
        self.riskFloor = riskFloor
        self.workspaceRoot = workspaceRoot
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.enabled = enabled
    }
}

struct ApprovalPolicyRequest {
    var provider: ProviderKind
    var sessionId: String
    var toolName: String
    var workspaceRoot: String?
    var toolInput: [String: Any]?
    var now: Date

    init(
        provider: ProviderKind,
        sessionId: String,
        toolName: String,
        workspaceRoot: String? = nil,
        toolInput: [String: Any]? = nil,
        now: Date = Date()
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.toolName = toolName
        self.workspaceRoot = workspaceRoot
        self.toolInput = toolInput
        self.now = now
    }
}

extension ApprovalPolicyRequest: Equatable {
    static func == (lhs: ApprovalPolicyRequest, rhs: ApprovalPolicyRequest) -> Bool {
        lhs.provider == rhs.provider &&
        lhs.sessionId == rhs.sessionId &&
        lhs.toolName == rhs.toolName &&
        lhs.workspaceRoot == rhs.workspaceRoot &&
        lhs.now == rhs.now &&
        toolInputEqual(lhs.toolInput, rhs.toolInput)
    }

    private static func toolInputEqual(_ lhs: [String: Any]?, _ rhs: [String: Any]?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.some, .none), (.none, .some): return false
        case let (.some(l), .some(r)):
            guard JSONSerialization.isValidJSONObject(l), JSONSerialization.isValidJSONObject(r),
                  let ld = try? JSONSerialization.data(withJSONObject: l, options: .sortedKeys),
                  let rd = try? JSONSerialization.data(withJSONObject: r, options: .sortedKeys)
            else { return false }
            return ld == rd
        }
    }
}

struct ApprovalPolicyDecision: Equatable {
    enum Source: String {
        case persistentRule
        case sessionCache
        case fallback
        case user
        case automatic
    }

    var action: RuleAction
    var source: Source
    var ruleId: UUID?

    static let prompt = ApprovalPolicyDecision(action: .prompt, source: .fallback, ruleId: nil)
}

struct ReplayLogEntry: Identifiable, Equatable {
    let id: Int64
    var requestId: String?
    var provider: ProviderKind
    var sessionId: String
    var eventName: String
    var toolName: String
    var payloadJSON: String
    var receivedAt: Date
    var decisionAction: RuleAction?
    var decisionSource: ApprovalPolicyDecision.Source?
    var decisionReason: String?
    var decidedAt: Date?
}

struct OpenSessionRecord {
    let sessionId: String
    let provider: ProviderKind
    let lastPayloadJSON: String
    let lastEventName: String
    let lastToolName: String
    let lastActiveAt: Date
    let startAt: Date
}

struct ClosedSessionRecord: Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let provider: ProviderKind
    let lastPayloadJSON: String
    let lastEventName: String
    let lastToolName: String
    let startAt: Date
    let endedAt: Date
    let workspaceRoot: String?
    let terminalApp: String?
    let terminalTitle: String?
}

// MARK: - PTY

enum PTYDirection: String, Codable, CaseIterable {
    case output
    case input
}

struct PTYMessage: Identifiable, Equatable {
    let id: Int64
    let sessionId: String
    let provider: ProviderKind
    let direction: PTYDirection
    let content: String
    let createdAt: Date
}

struct PTYAutoInjectPattern: Codable, Identifiable, Equatable {
    var id: UUID
    var pattern: String
    var response: String

    init(id: UUID = UUID(), pattern: String, response: String) {
        self.id = id
        self.pattern = pattern
        self.response = response
    }
}
