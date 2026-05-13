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
}
