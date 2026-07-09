import XCTest
@testable import DevIsland

/// BridgeInstaller가 Claude/Codex 설정 파일을 패치한 결과가 hook_events.json
/// 매니페스트 기반으로 바뀐 뒤에도 리팩토링 이전과 **바이트 단위로 동일**함을
/// 골든 fixture로 고정한다. fixture는 리팩토링 직전(main) 코드 출력에서 캡처했다.
/// scripts/hook_events.json → HookEventManifest → patch → 출력 전 구간을 검증하므로,
/// 매니페스트 파일을 잘못 수정하면 이 테스트가 잡아낸다.
final class BridgeInstallerManifestTests: XCTestCase {
    private static let bridgePath = "/BRIDGE"

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DevIslandTests
            .deletingLastPathComponent()  // repo root
    }

    private func manifest() throws -> BridgeInstaller.HookEventManifest {
        let url = repoRoot().appendingPathComponent("scripts/hook_events.json")
        return try BridgeInstaller.HookEventManifest.load(from: url)
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    /// 빈 설정 파일에 패치를 적용한 뒤 출력 문자열을 돌려준다.
    private func patchedOutput(_ patch: (URL, String) throws -> Void) throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try patch(tmp, Self.bridgePath)
        return try String(contentsOf: tmp, encoding: .utf8)
    }

    private func assertMatchesGolden(_ output: String, fixture name: String) throws {
        let golden = try String(contentsOf: fixtureURL(name), encoding: .utf8)
        XCTAssertEqual(output, golden, "\(name) 출력이 골든과 다름 — 의도치 않은 동작 변경일 수 있음. 의도한 매니페스트 변경이면 골든 fixture를 재기록할 것")
    }

    func testClaudeSettingsMatchesGolden() throws {
        let claude = try manifest().provider("claude")
        let output = try patchedOutput { url, bridge in
            try BridgeInstaller.patchClaudeSettings(at: url, bridgePath: bridge, events: claude)
        }
        try assertMatchesGolden(output, fixture: "claude_settings_golden.json")
    }

    func testCodexHooksMatchesGolden() throws {
        let codex = try manifest().provider("codex")
        let output = try patchedOutput { url, bridge in
            try BridgeInstaller.patchCodexHooks(at: url, bridgePath: bridge, events: codex)
        }
        try assertMatchesGolden(output, fixture: "codex_hooks_golden.json")
    }
}
