import Foundation

struct HookEventNormalizer {
    static let approvalEventsByAgent: [BuddyKind: Set<String>] = [
        .claudeCode: ["permissionrequest"],
        .codex: ["permissionrequest"],
        .gemini: ["beforetool"]
    ]

    static let userQuestionTools: Set<String> = [
        "ask_user",
        "askuser",
        "request_user_input",
        "requestuserinput"
    ]

    static func normalizedName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    static func agentKind(from json: [String: Any], terminalTitle: String) -> BuddyKind {
        if let explicitSource = json["cli_source"] as? String, !explicitSource.isEmpty {
            switch explicitSource {
            case "gemini": return .gemini
            case "codex": return .codex
            case "claude": return .claudeCode
            default: break
            }
        }

        let event = (json["hook_event_name"] as? String) ?? (json["event"] as? String) ?? ""
        switch normalizedName(event) {
        case "beforetool":
            return .gemini
        case "pretooluse":
            return .codex
        case "permissionrequest":
            if json["tool_name"] != nil { return .codex }
            if json["permission_type"] != nil { return .claudeCode }
            return .claudeCode
        default:
            break
        }

        let candidateKeys = [
            "agent", "agent_name", "agentName", "source", "client",
            "app", "application", "cli", "model", "model_name"
        ]
        let candidates = candidateKeys.compactMap { json[$0] as? String } + [terminalTitle]
        return BuddyKind(from: candidates.joined(separator: " "))
    }

    static func isApprovalEvent(_ normalizedEvent: String, for agentKind: BuddyKind) -> Bool {
        approvalEventsByAgent[agentKind]?.contains(normalizedEvent) == true
    }

    static func isUserQuestionTool(_ toolName: String) -> Bool {
        userQuestionTools.contains(normalizedName(toolName))
    }
}
