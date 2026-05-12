import XCTest
@testable import DevIsland

final class SQLiteApprovalStoreTests: XCTestCase {
    private var tempDir: URL!
    private var databaseURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteApprovalStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseURL = tempDir.appendingPathComponent("approval-proxy.sqlite3")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        databaseURL = nil
        super.tearDown()
    }

    func testMigrationCreatesApprovalProxyTables() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)

        let tables = try store.tableNames()

        XCTAssertTrue(tables.contains("rules"))
        XCTAssertTrue(tables.contains("session_cache"))
        XCTAssertTrue(tables.contains("hook_events"))
        XCTAssertTrue(tables.contains("approval_decisions"))
        XCTAssertTrue(tables.contains("pty_messages"))
        XCTAssertTrue(tables.contains("settings"))
        XCTAssertEqual(try store.schemaVersion(), SQLiteApprovalStore.currentSchemaVersion)
    }

    func testDatabaseFileUsesRestrictedPermissions() throws {
        _ = try SQLiteApprovalStore(databaseURL: databaseURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber

        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testSessionCacheDecisionMatchesProviderSessionAndTool() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        try store.upsertSessionApproval(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell",
            action: .allow,
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )

        let decision = try store.sessionDecision(for: ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell",
            now: Date(timeIntervalSince1970: 1_000)
        ))

        XCTAssertEqual(decision?.action, .allow)
        XCTAssertEqual(decision?.source, .sessionCache)
    }

    func testExpiredSessionCacheDoesNotMatch() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        try store.upsertSessionApproval(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell",
            action: .allow,
            expiresAt: Date(timeIntervalSince1970: 500)
        )

        let decision = try store.sessionDecision(for: ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell",
            now: Date(timeIntervalSince1970: 1_000)
        ))

        XCTAssertNil(decision)
    }

    func testPersistentRuleDecisionMatchesExactTool() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let ruleId = UUID()
        try store.insertRule(ApprovalRule(
            id: ruleId,
            provider: .claude,
            toolName: "Bash",
            action: .deny,
            scope: .persistent
        ))

        let decision = try store.persistentDecision(for: ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "session-1",
            toolName: "Bash"
        ))

        XCTAssertEqual(decision?.action, .deny)
        XCTAssertEqual(decision?.source, .persistentRule)
        XCTAssertEqual(decision?.ruleId, ruleId)
    }

    func testRulesCanBeListedAndDeleted() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let codexRuleId = UUID()
        let claudeRuleId = UUID()
        try store.insertRule(ApprovalRule(
            id: codexRuleId,
            provider: .codex,
            toolName: "shell",
            action: .allow,
            scope: .persistent
        ))
        try store.insertRule(ApprovalRule(
            id: claudeRuleId,
            provider: .claude,
            toolName: "Bash",
            action: .deny,
            scope: .persistent
        ))

        let codexRules = try store.rules(provider: .codex, scope: .persistent)
        XCTAssertEqual(codexRules.map(\.id), [codexRuleId])
        XCTAssertEqual(codexRules.first?.toolName, "shell")

        try store.deleteRule(id: codexRuleId)
        XCTAssertTrue(try store.rules(provider: .codex, scope: .persistent).isEmpty)
        XCTAssertEqual(try store.rules(provider: .claude, scope: .persistent).first?.id, claudeRuleId)
    }

    func testDeterministicRuleIDIsStableForProviderToolScopeAndWorkspace() {
        let first = SQLiteApprovalStore.deterministicRuleID(
            provider: .codex,
            toolName: "shell",
            scope: .persistent,
            workspaceRoot: "/tmp/project"
        )
        let second = SQLiteApprovalStore.deterministicRuleID(
            provider: .codex,
            toolName: "shell",
            scope: .persistent,
            workspaceRoot: "/tmp/project"
        )
        let differentWorkspace = SQLiteApprovalStore.deterministicRuleID(
            provider: .codex,
            toolName: "shell",
            scope: .persistent,
            workspaceRoot: "/tmp/other"
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, differentWorkspace)
    }

    func testNonExactPersistentRuleIsPersistedButNotEvaluatedInPhase3() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "Bash",
            matchKind: .commandPrefix,
            pattern: "npm",
            action: .allow,
            scope: .persistent
        ))

        let decision = try store.persistentDecision(for: ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "session-1",
            toolName: "Bash"
        ))

        XCTAssertNil(decision)
    }

    func testHookEventAndDecisionAreInserted() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)

        let eventId = try store.insertHookEvent(
            requestId: "request-1",
            provider: .gemini,
            sessionId: "session-1",
            eventName: "BeforeTool",
            toolName: "write_file",
            payloadJSON: #"{"hook_event_name":"BeforeTool"}"#
        )
        let decisionId = try store.insertDecision(
            hookEventId: eventId,
            provider: .gemini,
            sessionId: "session-1",
            toolName: "write_file",
            action: .deny,
            source: .fallback,
            reason: "test"
        )

        XCTAssertGreaterThan(eventId, 0)
        XCTAssertGreaterThan(decisionId, 0)
    }
}
