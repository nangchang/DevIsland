import Foundation

struct ProviderAdapter {
    static let denialMessage = "DevIsland에서 거절되었습니다."

    static func providerOutput(
        decision: String?,
        event: String,
        source: String,
        denialMessage: String = Self.denialMessage
    ) -> [String: AnyJSON]? {
        guard let decision else { return nil }

        if decision == "pass" {
            if source == "claude" {
                return [
                    "continue": .bool(true),
                    "suppressOutput": .bool(true)
                ]
            }
            return [:]
        }

        let allow = decision == "approved"
        if source == "gemini" {
            var output: [String: AnyJSON] = [
                "decision": .string(allow ? "allow" : "deny")
            ]
            if !allow {
                output["reason"] = .string(denialMessage)
            }
            return output
        }

        if source == "codex" {
            if event == "PreToolUse" {
                if allow { return [:] }
                return [
                    "hookSpecificOutput": .object([
                        "hookEventName": .string("PreToolUse"),
                        "permissionDecision": .string("deny"),
                        "permissionDecisionReason": .string(denialMessage)
                    ])
                ]
            }
            if event != "PermissionRequest" {
                return ["continue": .bool(true)]
            }
        }

        if event == "PermissionRequest", decision == "approved" || decision == "denied" {
            var hookDecision: [String: AnyJSON] = [
                "behavior": .string(allow ? "allow" : "deny")
            ]
            if !allow {
                hookDecision["message"] = .string(denialMessage)
            }
            return [
                "hookSpecificOutput": .object([
                    "hookEventName": .string("PermissionRequest"),
                    "decision": .object(hookDecision)
                ])
            ]
        }

        return [
            "continue": .bool(true),
            "suppressOutput": .bool(true)
        ]
    }
}
