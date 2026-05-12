import XCTest
@testable import DevIsland

final class CodexRuleSyncAdapterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRuleSyncAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testJSONAdapterExportsProvidedRules() throws {
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
                    id: UUID(),
                    provider: .codex,
                    toolName: "apply_patch",
                    action: .deny,
                    scope: .persistent
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(result.url, snapshotURL)
        XCTAssertEqual(result.ruleCount, 2)

        let data = try Data(contentsOf: snapshotURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CodexRuleSyncSnapshot.self, from: data)

        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(snapshot.rules.map(\.toolName), ["apply_patch", "shell"])
        XCTAssertTrue(snapshot.rules.contains { $0.id == codexRuleID && $0.action == .allow })
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

    func testJSONAdapterOverwritesExistingSnapshotWithRestrictedPermissions() throws {
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
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let result = try adapter.sync(
            rules: [],
            generatedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(result.ruleCount, 0)

        let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CodexRuleSyncSnapshot.self, from: Data(contentsOf: snapshotURL))
        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertTrue(snapshot.rules.isEmpty)
    }
}
