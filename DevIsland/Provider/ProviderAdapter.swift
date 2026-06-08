import Foundation

// ProviderAdapter formats approval decisions into the per-CLI hook response JSON
// expected by Claude Code, Codex, and Gemini CLI.
//
// Claude-specific output is handled by helpers below (claudePreToolUseOutput,
// claudeUserPromptSubmitOutput, etc.) and ClaudeAdapter in the same file.
//
struct ProviderAdapter {
    static var denialMessage: String {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let isKorean: Bool
        if lang == "korean" {
            isKorean = true
        } else if lang == "english" {
            isKorean = false
        } else {
            isKorean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        }
        return isKorean ? "DevIsland에서 거절되었습니다." : "Denied by DevIsland."
    }

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

        let normalizedEvent = HookEventNormalizer.normalizedName(event)

        if decision == "pass" {
            if provider == .claude && normalizedEvent != "permissionrequest" {
                return [
                    "continue": .bool(true),
                    "suppressOutput": .bool(true)
                ]
            }
            // For Gemini, returning [:] (which formats as {} in bridge) means
            // the hook does not veto (deny) the action. The Gemini CLI will then
            // follow its own configured approval behavior (interactive prompt or --auto-approve).
            return [:]
        }

        let allow = decision == "approved"
        if provider == .gemini {
            return GeminiPromptPolicy.beforeToolOutput(allow: allow, denialMessage: denialMessage)
        }

        if provider == .codex {
            if normalizedEvent == "pretooluse" {
                if allow { return [:] }
                return [
                    "hookSpecificOutput": .object([
                        "hookEventName": .string("PreToolUse"),
                        "permissionDecision": .string("deny"),
                        "permissionDecisionReason": .string(denialMessage)
                    ])
                ]
            }
            if normalizedEvent != "permissionrequest" {
                return ["continue": .bool(true)]
            }
        }

        if provider == .claude, normalizedEvent == "userpromptsubmit" {
            return claudeUserPromptSubmitOutput(allow: allow, denialMessage: denialMessage)
        }

        if provider == .claude, normalizedEvent == "elicitation" {
            return claudeElicitationOutput(allow: allow)
        }

        if provider == .claude, normalizedEvent == "pretooluse" {
            return claudePreToolUseOutput(
                allow: allow,
                toolName: toolName,
                toolInput: toolInput,
                denialMessage: denialMessage
            )
        }

        if normalizedEvent == "permissionrequest", decision == "approved" || decision == "denied" {
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
        let updatedInput = allow ? claudeUpdatedInput(for: toolName, toolInput: toolInput) : nil
        if allow, updatedInput == nil {
            return [
                "continue": .bool(true),
                "suppressOutput": .bool(true)
            ]
        }

        var hookOutput: [String: AnyJSON] = [
            "hookEventName": .string("PreToolUse"),
            "permissionDecision": .string(allow ? "allow" : "deny")
        ]
        if !allow {
            hookOutput["permissionDecisionReason"] = .string(denialMessage)
        }
        if let updatedInput {
            hookOutput["updatedInput"] = updatedInput
        }
        return ["hookSpecificOutput": .object(hookOutput)]
    }

    private static func claudeUserPromptSubmitOutput(allow: Bool, denialMessage: String) -> [String: AnyJSON] {
        guard !allow else {
            return [
                "continue": .bool(true),
                "suppressOutput": .bool(true)
            ]
        }
        return [
            "decision": .string("block"),
            "reason": .string(denialMessage)
        ]
    }

    private static func claudeElicitationOutput(allow: Bool) -> [String: AnyJSON] {
        guard !allow else {
            return [
                "continue": .bool(true),
                "suppressOutput": .bool(true)
            ]
        }
        return [
            "hookSpecificOutput": .object([
                "hookEventName": .string("Elicitation"),
                "action": .string("decline")
            ])
        ]
    }

    private static func claudeUpdatedInput(for toolName: String?, toolInput: [String: AnyJSON]?) -> AnyJSON? {
        guard let toolName else { return nil }
        switch HookEventNormalizer.normalizedName(toolName) {
        case "askuserquestion":
            guard let input = toolInput, input["answers"] != nil else { return nil }
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
