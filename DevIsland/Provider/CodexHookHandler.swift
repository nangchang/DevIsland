import Foundation

struct CodexHookHandler: ProviderHookHandler {
    let kind: ProviderKind = .codex

    func providerOutput(context: ProviderHookContext) -> [String: AnyJSON]? {
        if context.decision == "pass" { return [:] }

        switch context.normalizedEvent {
        case "pretooluse":
            guard !context.allow else { return [:] }
            return [
                "hookSpecificOutput": .object([
                    "hookEventName": .string("PreToolUse"),
                    "permissionDecision": .string("deny"),
                    "permissionDecisionReason": .string(context.denialMessage)
                ])
            ]
        case "permissionrequest":
            if context.decision == "timeout" { return [:] }
            guard context.decision == "approved" || context.decision == "denied" else { return ["continue": .bool(true)] }
            return ProviderAdapter.permissionRequestOutput(allow: context.allow, denialMessage: context.denialMessage)
        default:
            return ["continue": .bool(true)]
        }
    }
}
