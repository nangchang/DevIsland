import XCTest
@testable import DevIsland

private final class SpyCodexRuleSyncAdapter: CodexRuleSyncAdapter {
    var capturedRules: [ApprovalRule] = []
    var capturedDate: Date?
    var resultURL: URL = URL(fileURLWithPath: "/tmp/codex-rules.json")
    var errorToThrow: Error?

    func sync(rules: [ApprovalRule], generatedAt: Date) throws -> CodexRuleSyncResult {
        capturedRules = rules
        capturedDate = generatedAt
        if let error = errorToThrow { throw error }
        return CodexRuleSyncResult(url: resultURL, ruleCount: rules.count)
    }
}

final class ApprovalRuleServiceTests: XCTestCase {
    private var tempDir: URL!
    private var controller: ApprovalProxyController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApprovalRuleServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        controller = try ApprovalProxyController(
            databaseURL: tempDir.appendingPathComponent("rules.sqlite3")
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        controller = nil
        super.tearDown()
    }

    private func makeService(adapter: CodexRuleSyncAdapter = SpyCodexRuleSyncAdapter()) -> ApprovalRuleService {
        ApprovalRuleService(
            approvalProxy: controller,
            codexRuleSyncAdapter: adapter
        )
    }

    // MARK: - nil proxy guard

    func testAllOperationsNoOpWhenProxyIsNil() throws {
        let service = ApprovalRuleService(approvalProxy: nil)
        XCTAssertNoThrow(try service.addCodexPersistentRule(toolName: "shell", action: .allow))
        XCTAssertNoThrow(try service.deleteCodexPersistentRule(ApprovalRule(provider: .codex, toolName: "shell", action: .allow, scope: .persistent)))
        XCTAssertNoThrow(try service.addPersistentRule(from: makeReplayEntry(toolName: "shell"), action: .allow))
        let rules = try service.codexPersistentRules()
        XCTAssertTrue(rules.isEmpty)
    }

    // MARK: - Codex rules round-trip

    func testAddAndListCodexPersistentRule() throws {
        let service = makeService()
        try service.addCodexPersistentRule(toolName: "shell", action: .allow)
        let rules = try service.codexPersistentRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.toolName, "shell")
        XCTAssertEqual(rules.first?.action, .allow)
        XCTAssertEqual(rules.first?.provider, .codex)
    }

    func testAddCodexRuleTrimsWhitespace() throws {
        let service = makeService()
        try service.addCodexPersistentRule(toolName: "  shell  ", action: .deny)
        let rules = try service.codexPersistentRules()
        XCTAssertEqual(rules.first?.toolName, "shell")
    }

    func testAddCodexRuleIgnoresEmptyToolName() throws {
        let service = makeService()
        try service.addCodexPersistentRule(toolName: "   ", action: .allow)
        let rules = try service.codexPersistentRules()
        XCTAssertTrue(rules.isEmpty)
    }

    func testDeleteCodexPersistentRule() throws {
        let service = makeService()
        try service.addCodexPersistentRule(toolName: "shell", action: .allow)
        let rules = try service.codexPersistentRules()
        XCTAssertEqual(rules.count, 1)
        let rule = try XCTUnwrap(rules.first)
        try service.deleteCodexPersistentRule(rule)
        XCTAssertTrue((try service.codexPersistentRules()).isEmpty)
    }

    func testAddMultipleCodexRulesAndListAll() throws {
        let service = makeService()
        try service.addCodexPersistentRule(toolName: "shell", action: .allow)
        try service.addCodexPersistentRule(toolName: "write_file", action: .deny)
        let rules = try service.codexPersistentRules()
        XCTAssertEqual(rules.count, 2)
        let toolNames = Set(rules.map(\.toolName))
        XCTAssertEqual(toolNames, ["shell", "write_file"])
    }

    // MARK: - addPersistentRule from ReplayLogEntry

    func testAddPersistentRuleFromReplayEntry() throws {
        let service = makeService()
        let entry = makeReplayEntry(toolName: "npm_test", provider: .codex)
        try service.addPersistentRule(from: entry, action: .allow)
        let rules = try service.codexPersistentRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.toolName, "npm_test")
        XCTAssertEqual(rules.first?.provider, .codex)
    }

    func testAddPersistentRuleTrimsToolName() throws {
        let service = makeService()
        let entry = makeReplayEntry(toolName: "  shell  ")
        try service.addPersistentRule(from: entry, action: .allow)
        let rules = try service.codexPersistentRules()
        XCTAssertEqual(rules.first?.toolName, "shell")
    }

    func testAddPersistentRuleIgnoresEmptyToolName() throws {
        let service = makeService()
        let entry = makeReplayEntry(toolName: "   ")
        XCTAssertNoThrow(try service.addPersistentRule(from: entry, action: .allow))
        XCTAssertTrue((try service.codexPersistentRules()).isEmpty)
    }

    // MARK: - syncCodexPersistentRules

    func testSyncPassesCurrentRulesToAdapter() throws {
        let spy = SpyCodexRuleSyncAdapter()
        let service = ApprovalRuleService(
            approvalProxy: controller,
            codexRuleSyncAdapter: spy
        )
        try service.addCodexPersistentRule(toolName: "shell", action: .allow)
        let result = try service.syncCodexPersistentRules()

        XCTAssertEqual(result.ruleCount, 1)
        XCTAssertEqual(spy.capturedRules.count, 1)
        XCTAssertEqual(spy.capturedRules.first?.toolName, "shell")
    }

    func testSyncWithNoRulesPassesEmptyArray() throws {
        let spy = SpyCodexRuleSyncAdapter()
        let service = ApprovalRuleService(
            approvalProxy: controller,
            codexRuleSyncAdapter: spy
        )
        let result = try service.syncCodexPersistentRules()
        XCTAssertEqual(result.ruleCount, 0)
        XCTAssertTrue(spy.capturedRules.isEmpty)
    }

    func testSyncPropagatesAdapterError() throws {
        let spy = SpyCodexRuleSyncAdapter()
        spy.errorToThrow = NSError(domain: "test", code: 42, userInfo: nil)
        let service = ApprovalRuleService(
            approvalProxy: controller,
            codexRuleSyncAdapter: spy
        )
        XCTAssertThrowsError(try service.syncCodexPersistentRules()) { error in
            XCTAssertEqual((error as NSError).code, 42)
        }
    }

    // MARK: - Helpers

    private func makeReplayEntry(toolName: String, provider: ProviderKind = .codex) -> ReplayLogEntry {
        ReplayLogEntry(
            id: Int64.random(in: 1...10000),
            requestId: UUID().uuidString,
            provider: provider,
            sessionId: UUID().uuidString,
            eventName: "PermissionRequest",
            toolName: toolName,
            payloadJSON: "{}",
            receivedAt: Date(),
            decisionAction: nil,
            decisionSource: nil,
            decisionReason: nil,
            decidedAt: nil
        )
    }
}
