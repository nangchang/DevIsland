import XCTest
@testable import DevIsland

final class CodexRuleSyncAdapterTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRuleSyncAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testJSONAdapterExportsOnlyCodexPersistentRules() throws {
        let snapshotURL = tempDir.appendingPathComponent("codex-rules.snapshot.json")
        let adapter = CodexJSONRuleSyncAdapter(snapshotURL: snapshotURL)
        let codexRuleID = UUID()
        let result = try adapter.sync(
            rules: [
                ApprovalRule(
                    id: codexRuleID,
                    provider: .codex,
                    toolName: "shell",
                    action: .allow,
                    scope: .persistent
                ),
                ApprovalRule(
                    provider: .codex,
                    toolName: "apply_patch",
                    action: .allow,
                    scope: .session
                ),
                ApprovalRule(
                    provider: .claude,
                    toolName: "Bash",
                    action: .deny,
                    scope: .persistent
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(result.url, snapshotURL)
        XCTAssertEqual(result.ruleCount, 1)

        let data = try Data(contentsOf: snapshotURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CodexRuleSyncSnapshot.self, from: data)

        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(snapshot.rules.map(\.id), [codexRuleID])
        XCTAssertEqual(snapshot.rules.first?.toolName, "shell")
        XCTAssertEqual(snapshot.rules.first?.action, .allow)
    }

    func testJSONAdapterUsesRestrictedFilePermissions() throws {
        let snapshotURL = tempDir.appendingPathComponent("codex-rules.snapshot.json")
        let adapter = CodexJSONRuleSyncAdapter(snapshotURL: snapshotURL)

        _ = try adapter.sync(
            rules: [
                ApprovalRule(
                    provider: .codex,
                    toolName: "shell",
                    action: .allow,
                    scope: .persistent
                )
            ],
            generatedAt: Date()
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
