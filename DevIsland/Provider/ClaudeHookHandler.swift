import Foundation

struct ClaudeHookHandler: ProviderHookHandler {
    let kind: ProviderKind = .claude

    func providerOutput(context: ProviderHookContext) -> [String: AnyJSON]? {
        if context.decision == "pass" {
            return context.normalizedEvent != "permissionrequest"
                ? ["continue": .bool(true), "suppressOutput": .bool(true)]
                : [:]
        }

        switch context.normalizedEvent {
        case "userpromptsubmit":
            return userPromptSubmitOutput(context: context)
        case "elicitation":
            return elicitationOutput(allow: context.allow)
        case "pretooluse":
            return preToolUseOutput(context: context)
        case "permissionrequest" where context.decision == "approved" || context.decision == "denied":
            return permissionRequestOutput(allow: context.allow, denialMessage: context.denialMessage,
                                          context: context)
        default:
            return ["continue": .bool(true), "suppressOutput": .bool(true)]
        }
    }

    // MARK: - Event-specific outputs

    private func userPromptSubmitOutput(context: ProviderHookContext) -> [String: AnyJSON] {
        guard !context.allow else {
            return ["continue": .bool(true), "suppressOutput": .bool(true)]
        }
        return ["decision": .string("block"), "reason": .string(context.denialMessage)]
    }

    private func elicitationOutput(allow: Bool) -> [String: AnyJSON] {
        guard !allow else {
            return ["continue": .bool(true), "suppressOutput": .bool(true)]
        }
        return [
            "hookSpecificOutput": .object([
                "hookEventName": .string("Elicitation"),
                "action": .string("decline")
            ])
        ]
    }

    private func preToolUseOutput(context: ProviderHookContext) -> [String: AnyJSON] {
        let updatedInput = context.allow ? updatedInput(for: context.toolName, toolInput: context.toolInput) : nil
        if context.allow, updatedInput == nil {
            return ["continue": .bool(true), "suppressOutput": .bool(true)]
        }

        var hookOutput: [String: AnyJSON] = [
            "hookEventName": .string("PreToolUse"),
            "permissionDecision": .string(context.allow ? "allow" : "deny")
        ]
        if !context.allow {
            hookOutput["permissionDecisionReason"] = .string(context.denialMessage)
        }
        if let updatedInput {
            hookOutput["updatedInput"] = updatedInput
        }
        return ["hookSpecificOutput": .object(hookOutput)]
    }

    private func permissionRequestOutput(
        allow: Bool,
        denialMessage: String,
        context: ProviderHookContext
    ) -> [String: AnyJSON] {
        var hookDecision: [String: AnyJSON] = ["behavior": .string(allow ? "allow" : "deny")]
        if !allow {
            hookDecision["message"] = .string(denialMessage)
        }
        if allow, let update = permissionUpdate(context: context) {
            hookDecision["updatedPermissions"] = .array([update])
        }
        return [
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(hookDecision)
            ])
        ]
    }

    // MARK: - Tool-specific input passthrough

    private func updatedInput(for toolName: String?, toolInput: [String: AnyJSON]?) -> AnyJSON? {
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

    // MARK: - Permission persistence

    private func permissionUpdate(context: ProviderHookContext) -> AnyJSON? {
        guard let approvalScope = context.approvalScope,
              let toolName = context.toolName,
              !toolName.isEmpty else {
            return nil
        }

        let destination: String
        switch approvalScope {
        case .session:
            guard context.claudeSessionApprovalMode != .appSessionCache else { return nil }
            destination = "session"
        case .persistent:
            destination = context.claudePersistentApprovalDestination.rawValue
        case .once:
            return nil
        }

        return .object([
            "type": .string("addRules"),
            "rules": .array([
                .object([
                    "toolName": .string(toolName),
                    "ruleContent": .string(nonEmpty(context.ruleContent) ?? toolName)
                ])
            ]),
            "behavior": .string("allow"),
            "destination": .string(destination)
        ])
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
