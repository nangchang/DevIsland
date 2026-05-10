import XCTest
@testable import DevIsland

final class HookEventNormalizerTests: XCTestCase {
    func testNormalizedNameRemovesSeparatorsAndLowercases() {
        XCTAssertEqual(HookEventNormalizer.normalizedName("BeforeTool"), "beforetool")
        XCTAssertEqual(HookEventNormalizer.normalizedName("Pre-Tool-Use"), "pretooluse")
        XCTAssertEqual(HookEventNormalizer.normalizedName("SESSION_START"), "sessionstart")
    }

    func testExplicitSourceWinsAgentDetection() {
        let json: [String: Any] = [
            "cli_source": "codex",
            "hook_event_name": "BeforeTool"
        ]

        XCTAssertEqual(HookEventNormalizer.agentKind(from: json, terminalTitle: "Gemini"), .codex)
    }

    func testAgentDetectionFromHookShape() {
        XCTAssertEqual(
            HookEventNormalizer.agentKind(from: ["hook_event_name": "BeforeTool"], terminalTitle: "Terminal"),
            .gemini
        )
        XCTAssertEqual(
            HookEventNormalizer.agentKind(from: ["event": "PreToolUse"], terminalTitle: "Terminal"),
            .codex
        )
        XCTAssertEqual(
            HookEventNormalizer.agentKind(
                from: ["hook_event_name": "PermissionRequest", "permission_type": "tool"],
                terminalTitle: "Terminal"
            ),
            .claudeCode
        )
    }

    func testApprovalEventClassificationIsProviderSpecific() {
        XCTAssertTrue(HookEventNormalizer.isApprovalEvent("permissionrequest", for: .claudeCode))
        XCTAssertTrue(HookEventNormalizer.isApprovalEvent("elicitation", for: .claudeCode))
        XCTAssertTrue(HookEventNormalizer.isApprovalEvent("permissionrequest", for: .codex))
        XCTAssertTrue(HookEventNormalizer.isApprovalEvent("beforetool", for: .gemini))
        XCTAssertFalse(HookEventNormalizer.isApprovalEvent("pretooluse", for: .claudeCode))
        XCTAssertFalse(HookEventNormalizer.isApprovalEvent("beforetool", for: .codex))
    }

    func testUserQuestionToolNormalization() {
        XCTAssertTrue(HookEventNormalizer.isUserQuestionTool("ask_user"))
        XCTAssertTrue(HookEventNormalizer.isUserQuestionTool("AskUserQuestion"))
        XCTAssertTrue(HookEventNormalizer.isUserQuestionTool("request-user-input"))
        XCTAssertFalse(HookEventNormalizer.isUserQuestionTool("ExitPlanMode"))
        XCTAssertFalse(HookEventNormalizer.isUserQuestionTool("write_file"))
    }
}
