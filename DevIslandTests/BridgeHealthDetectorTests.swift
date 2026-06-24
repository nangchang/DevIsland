import XCTest
@testable import DevIsland

final class BridgeHealthDetectorTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BridgeHealthTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - Claude

    func test_claude_not_installed_when_file_missing() {
        let status = BridgeHealthDetector.hookStatus(for: .claude, homeDirectory: tmp)
        XCTAssertFalse(status.settingsFileExists)
        XCTAssertFalse(status.isInstalled)
    }

    func test_claude_not_installed_when_bridge_absent() {
        write(to: ".claude/settings.json",
              contents: #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hello"}]}]}}"#)
        let status = BridgeHealthDetector.hookStatus(for: .claude, homeDirectory: tmp)
        XCTAssertTrue(status.settingsFileExists)
        XCTAssertFalse(status.isInstalled)
    }

    func test_claude_installed_when_bridge_in_command() {
        write(to: ".claude/settings.json",
              contents: #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"/path/devisland-bridge.sh\" --source claude"}]}]}}"#)
        let status = BridgeHealthDetector.hookStatus(for: .claude, homeDirectory: tmp)
        XCTAssertTrue(status.settingsFileExists)
        XCTAssertTrue(status.isInstalled)
    }

    // MARK: - Codex

    func test_codex_not_installed_when_file_missing() {
        let status = BridgeHealthDetector.hookStatus(for: .codex, homeDirectory: tmp)
        XCTAssertFalse(status.settingsFileExists)
        XCTAssertFalse(status.isInstalled)
    }

    func test_codex_installed_when_bridge_in_hooks_json() {
        write(to: ".codex/hooks.json",
              contents: #"{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"command":"\"/path/devisland-bridge.sh\" --source codex"}]}]}}"#)
        let status = BridgeHealthDetector.hookStatus(for: .codex, homeDirectory: tmp)
        XCTAssertTrue(status.isInstalled)
    }

    // MARK: - Gemini

    func test_gemini_not_installed_when_file_missing() {
        let status = BridgeHealthDetector.hookStatus(for: .gemini, homeDirectory: tmp)
        XCTAssertFalse(status.settingsFileExists)
        XCTAssertFalse(status.isInstalled)
    }

    func test_gemini_installed_when_bridge_in_settings() {
        write(to: ".gemini/settings.json",
              contents: #"{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"command":"\"/path/devisland-bridge.sh\" --source gemini"}]}]}}"#)
        let status = BridgeHealthDetector.hookStatus(for: .gemini, homeDirectory: tmp)
        XCTAssertTrue(status.isInstalled)
    }

    // MARK: - All statuses

    func test_all_statuses_covers_all_providers() {
        let statuses = BridgeHealthDetector.allHookStatuses(homeDirectory: tmp)
        XCTAssertEqual(statuses.count, BridgeHookProvider.allCases.count)
    }

    func test_all_statuses_each_provider_present() {
        let statuses = BridgeHealthDetector.allHookStatuses(homeDirectory: tmp)
        let providers = statuses.map { $0.provider }
        for provider in BridgeHookProvider.allCases {
            XCTAssertTrue(providers.contains { p in
                switch (p, provider) {
                case (.claude, .claude), (.codex, .codex), (.gemini, .gemini): return true
                default: return false
                }
            }, "Missing provider: \(provider)")
        }
    }

    // MARK: - Helpers

    private func write(to relativePath: String, contents: String) {
        let url = tmp.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
