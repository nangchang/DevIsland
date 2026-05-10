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
        toolInput: [String: AnyJSON]? = nil,
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
            toolInput: toolInput,
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
        toolInput: [String: AnyJSON]? = nil,
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

        if provider == .claude, event == "PreToolUse" {
            return claudePreToolUseOutput(
                allow: allow,
                toolName: toolName,
                toolInput: toolInput,
                denialMessage: denialMessage
            )
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

    private static func claudePreToolUseOutput(
        allow: Bool,
        toolName: String?,
        toolInput: [String: AnyJSON]?,
        denialMessage: String
    ) -> [String: AnyJSON] {
        var hookOutput: [String: AnyJSON] = [
            "hookEventName": .string("PreToolUse"),
            "permissionDecision": .string(allow ? "allow" : "deny")
        ]
        if !allow {
            hookOutput["permissionDecisionReason"] = .string(denialMessage)
        }
        if allow,
           let updatedInput = claudeUpdatedInput(for: toolName, toolInput: toolInput) {
            hookOutput["updatedInput"] = updatedInput
        }
        return ["hookSpecificOutput": .object(hookOutput)]
    }

    private static func claudeUpdatedInput(for toolName: String?, toolInput: [String: AnyJSON]?) -> AnyJSON? {
        guard let toolName else { return nil }
        switch HookEventNormalizer.normalizedName(toolName) {
        case "askuserquestion":
            var input = toolInput ?? [:]
            if input["answers"] == nil {
                input["answers"] = .object([:])
            }
            return .object(input)
        case "exitplanmode":
            return toolInput.map(AnyJSON.object)
        default:
            return nil
        }
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
