import Foundation

/// Facade over ApprovalProxyController for durable rule CRUD and Codex JSON sync.
///
/// AppState owns an instance; call methods via appState.ruleService.
final class ApprovalRuleService {
    private let approvalProxy: ApprovalProxyController?
    private let persistenceQueue: DispatchQueue
    private let codexRuleSyncAdapter: CodexRuleSyncAdapter

    init(
        approvalProxy: ApprovalProxyController?,
        persistenceQueue: DispatchQueue,
        codexRuleSyncAdapter: CodexRuleSyncAdapter = CodexJSONRuleSyncAdapter()
    ) {
        self.approvalProxy = approvalProxy
        self.persistenceQueue = persistenceQueue
        self.codexRuleSyncAdapter = codexRuleSyncAdapter
    }

    // MARK: - Codex Rules

    func codexPersistentRules() throws -> [ApprovalRule] {
        guard let approvalProxy else { return [] }
        return try approvalProxy.store.rules(provider: .codex, scope: .persistent)
    }

    func addCodexPersistentRule(toolName: String, action: RuleAction) throws {
        guard let approvalProxy else { return }
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try approvalProxy.store.insertRule(ApprovalRule(
            id: SQLiteApprovalStore.deterministicRuleID(
                provider: .codex,
                toolName: trimmed,
                scope: .persistent,
                workspaceRoot: nil
            ),
            provider: .codex,
            toolName: trimmed,
            action: action,
            scope: .persistent
        ))
    }

    func deleteCodexPersistentRule(_ rule: ApprovalRule) throws {
        guard let approvalProxy else { return }
        try approvalProxy.store.deleteRule(id: rule.id)
    }

    func syncCodexPersistentRules() throws -> CodexRuleSyncResult {
        try codexRuleSyncAdapter.sync(rules: codexPersistentRules(), generatedAt: Date())
    }

    // MARK: - Persistent Rules (from Replay)

    func addPersistentRule(from entry: ReplayLogEntry, action: RuleAction) throws {
        guard let approvalProxy else { return }
        let toolName = entry.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else { return }
        try approvalProxy.store.insertRule(ApprovalRule(
            id: SQLiteApprovalStore.deterministicRuleID(
                provider: entry.provider,
                toolName: toolName,
                scope: .persistent,
                workspaceRoot: nil
            ),
            provider: entry.provider,
            toolName: toolName,
            action: action,
            scope: .persistent
        ))
    }
}
