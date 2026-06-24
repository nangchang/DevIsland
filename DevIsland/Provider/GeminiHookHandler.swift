import Foundation

struct GeminiHookHandler: ProviderHookHandler {
    let kind: ProviderKind = .gemini

    func providerOutput(context: ProviderHookContext) -> [String: AnyJSON]? {
        if context.decision == "pass" { return [:] }
        return GeminiPromptPolicy.beforeToolOutput(allow: context.allow, denialMessage: context.denialMessage)
    }
}
