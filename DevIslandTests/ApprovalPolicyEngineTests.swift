import XCTest
@testable import DevIsland

final class ApprovalPolicyEngineTests: XCTestCase {
    private var tempDir: URL!
    private var databaseURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApprovalPolicyEngineTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseURL = tempDir.appendingPathComponent("approval-proxy.sqlite3")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        databaseURL = nil
        super.tearDown()
    }

    func testPersistentRulePrecedesSessionCache() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.upsertSessionApproval(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell",
            action: .allow,
            expiresAt: nil
        )
        try store.insertRule(ApprovalRule(
            provider: .codex,
            toolName: "shell",
            action: .deny,
            scope: .persistent
        ))

        let decision = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell"
        ))

        XCTAssertEqual(decision.action, .deny)
        XCTAssertEqual(decision.source, .persistentRule)
    }

    func testFallsBackToPromptWhenNoRuleMatches() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        let decision = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell"
        ))

        XCTAssertEqual(decision, .prompt)
    }

    func testSessionDenyBeatesPersistentAllow() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .codex,
            toolName: "shell",
            action: .allow,
            scope: .persistent
        ))
        try store.upsertSessionApproval(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell",
            action: .deny,
            expiresAt: nil
        )

        let decision = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell"
        ))

        XCTAssertEqual(decision.action, .deny)
        XCTAssertEqual(decision.source, .sessionCache)
    }

    func testCommandPrefixMatchesAgainstToolInput() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "run_shell_command",
            matchKind: .commandPrefix,
            pattern: "git ",
            action: .allow,
            scope: .persistent
        ))

        let allowed = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command",
            toolInput: ["command": "git status"]
        ))
        XCTAssertEqual(allowed.action, .allow)

        let denied = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command",
            toolInput: ["command": "rm -rf /"]
        ))
        XCTAssertEqual(denied, .prompt)

        // No toolInput → no match
        let noInput = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command"
        ))
        XCTAssertEqual(noInput, .prompt)
    }

    func testPathPrefixMatchesAgainstToolInput() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "write_file",
            matchKind: .pathPrefix,
            pattern: "/tmp/",
            action: .allow,
            scope: .persistent
        ))

        let allowed = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "write_file",
            toolInput: ["file_path": "/tmp/output.txt"]
        ))
        XCTAssertEqual(allowed.action, .allow)

        let denied = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "write_file",
            toolInput: ["file_path": "/etc/passwd"]
        ))
        XCTAssertEqual(denied, .prompt)
    }
}
