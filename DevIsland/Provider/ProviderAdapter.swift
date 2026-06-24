import Foundation

// ProviderAdapter routes approval decisions to the per-CLI handler registered in _handlers.
// To add a new CLI: create a ProviderHookHandler conformer and append it to _handlers below.
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

    // MARK: - Handler registry

    private static let _handlers: [any ProviderHookHandler] = [
        ClaudeHookHandler(),
        CodexHookHandler(),
        GeminiHookHandler(),
        AntigravityHookHandler(),
    ]

    private static func handler(for kind: ProviderKind) -> (any ProviderHookHandler)? {
        _handlers.first { $0.kind == kind }
    }

    // MARK: - Public API (source string overload)

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

    // MARK: - Public API (ProviderKind overload)

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
        let context = ProviderHookContext(
            decision: decision,
            normalizedEvent: normalizedEvent,
            approvalScope: approvalScope,
            toolName: toolName,
            ruleContent: ruleContent,
            toolInput: toolInput,
            claudeSessionApprovalMode: claudeSessionApprovalMode,
            claudePersistentApprovalDestination: claudePersistentApprovalDestination,
            denialMessage: denialMessage
        )

        if let matched = handler(for: provider) {
            return matched.providerOutput(context: context)
        }
        return defaultOutput(context: context)
    }

    // MARK: - Default fallback for unregistered providers

    private static func defaultOutput(context: ProviderHookContext) -> [String: AnyJSON]? {
        if context.decision == "pass" { return [:] }
        if context.normalizedEvent == "permissionrequest",
           context.decision == "approved" || context.decision == "denied" {
            return permissionRequestOutput(allow: context.allow, denialMessage: context.denialMessage)
        }
        return ["continue": .bool(true), "suppressOutput": .bool(true)]
    }
}
