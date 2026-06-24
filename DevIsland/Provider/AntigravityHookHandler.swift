import Foundation

struct AntigravityHookHandler: ProviderHookHandler {
    let kind: ProviderKind = .antigravity

    func providerOutput(context: ProviderHookContext) -> [String: AnyJSON]? {
        if context.decision == "pass" { return [:] }
        guard context.normalizedEvent == "pretooluse" else { return [:] }
        return GeminiPromptPolicy.beforeToolOutput(allow: context.allow, denialMessage: context.denialMessage)
    }
}
