import Foundation

struct ProviderAdapter {
    static let denialMessage = "DevIsland에서 거절되었습니다."

    static func providerOutput(
        decision: String?,
        event: String,
        source: String,
        approvalScope: RuleScope? = nil,
        toolName: String? = nil,
        ruleContent: String? = nil,
        claudeSessionApprovalMode: ClaudeSessionApprovalMode = .nativePermissions,
        claudePersistentApprovalDestination: ClaudePersistentApprovalDestination = .userSettings,
        denialMessage: String = Self.denialMessage
    ) -> [String: AnyJSON]? {
        providerOutput(
            decision: decision,
            event: event,
            provider: ProviderKind(source: source),
            approvalScope: approvalScope,
            toolName: toolName,
            ruleContent: ruleContent,
            claudeSessionApprovalMode: claudeSessionApprovalMode,
            claudePersistentApprovalDestination: claudePersistentApprovalDestination,
            denialMessage: denialMessage
        )
    }

    static func providerOutput(
        decision: String?,
        event: String,
        provider: ProviderKind,
        approvalScope: RuleScope? = nil,
        toolName: String? = nil,
        ruleContent: String? = nil,
        claudeSessionApprovalMode: ClaudeSessionApprovalMode = .nativePermissions,
        claudePersistentApprovalDestination: ClaudePersistentApprovalDestination = .userSettings,
        denialMessage: String = Self.denialMessage
    ) -> [String: AnyJSON]? {
        guard let decision else { return nil }

        if decision == "pass" {
            if provider == .claude {
                return [
                    "continue": .bool(true),
                    "suppressOutput": .bool(true)
                ]
            }
            return [:]
        }

        let allow = decision == "approved"
        if provider == .gemini {
            var output: [String: AnyJSON] = [
                "decision": .string(allow ? "allow" : "deny")
            ]
            if !allow {
                output["reason"] = .string(denialMessage)
            }
            return output
        }

        if provider == .codex {
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
            if allow, provider == .claude,
               let permissionUpdate = claudePermissionUpdate(
                   approvalScope: approvalScope,
                   toolName: toolName,
                   ruleContent: ruleContent,
                   sessionApprovalMode: claudeSessionApprovalMode,
                   persistentDestination: claudePersistentApprovalDestination
               ) {
                hookDecision["updatedPermissions"] = .array([permissionUpdate])
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

    private static func claudePermissionUpdate(
        approvalScope: RuleScope?,
        toolName: String?,
        ruleContent: String?,
        sessionApprovalMode: ClaudeSessionApprovalMode,
        persistentDestination: ClaudePersistentApprovalDestination
    ) -> AnyJSON? {
        guard let approvalScope,
              let toolName,
              !toolName.isEmpty else {
            return nil
        }

        let destination: String
        switch approvalScope {
        case .session:
            guard sessionApprovalMode != .appSessionCache else { return nil }
            destination = "session"
        case .persistent:
            destination = persistentDestination.rawValue
        case .once:
            return nil
        }

        return .object([
            "type": .string("addRules"),
            "rules": .array([
                .object([
                    "toolName": .string(toolName),
                    "ruleContent": .string(nonEmpty(ruleContent) ?? toolName)
                ])
            ]),
            "behavior": .string("allow"),
            "destination": .string(destination)
        ])
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
