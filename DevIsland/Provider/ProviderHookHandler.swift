import Foundation

/// Context passed to every ProviderHookHandler. Bundles the decision, normalized event,
/// and all provider-specific parameters so each handler receives exactly what it needs.
struct ProviderHookContext {
    let decision: String
    let normalizedEvent: String
    let approvalScope: RuleScope?
    let toolName: String?
    let ruleContent: String?
    let toolInput: [String: AnyJSON]?
    let claudeSessionApprovalMode: ClaudeSessionApprovalMode
    let claudePersistentApprovalDestination: ClaudePersistentApprovalDestination
    let denialMessage: String

    var allow: Bool { decision == "approved" }
}

/// Per-provider hook response formatter.
///
/// Each conformer owns the mapping from (decision, event) → hook JSON for one CLI.
/// New CLIs: add a conforming type and register it in ProviderAdapter._handlers.
protocol ProviderHookHandler {
    var kind: ProviderKind { get }
    func providerOutput(context: ProviderHookContext) -> [String: AnyJSON]?
}

