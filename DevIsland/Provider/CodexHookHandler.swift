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
        case "permissionrequest" where context.decision == "approved" || context.decision == "denied":
            return permissionRequestOutput(allow: context.allow, denialMessage: context.denialMessage)
        default:
            return ["continue": .bool(true)]
        }
    }
}
