import XCTest
@testable import DevIsland

final class HookEventClassifierTests: XCTestCase {
    private func classify(_ json: String) throws -> HookEventClassification {
        guard case .parsed(let h) = HookEventHandler.parse(json) else {
            throw XCTSkip("message did not parse into a hook event")
        }
        return HookEventClassifier.classify(h)
    }

    func testStopEventClassification() throws {
        let c = try classify("""
        { "hook_event_name": "SessionEnd", "cli_source": "claude", "session_id": "s1" }
        """)
        XCTAssertTrue(c.isStop)
        XCTAssertFalse(c.isApproval)
        XCTAssertFalse(c.isNotification)
    }

    func testClaudePermissionRequestIsApproval() throws {
        let c = try classify("""
        { "hook_event_name": "PermissionRequest", "cli_source": "claude", "session_id": "s1", "tool_name": "Bash" }
        """)
        XCTAssertTrue(c.isApproval)
        XCTAssertFalse(c.isStop)
        XCTAssertFalse(c.isNotification)
        XCTAssertFalse(c.isClaudeQuestionRequest)
        XCTAssertEqual(c.replayToolName, "Bash")
    }

    func testGeminiBeforeToolIsApproval() throws {
        let c = try classify("""
        { "hook_event_name": "BeforeTool", "cli_source": "gemini", "session_id": "s1", "tool_name": "run_shell_command" }
        """)
        XCTAssertTrue(c.isApproval)
        XCTAssertFalse(c.isNotification)
    }

    func testCodexPreToolUseIsNotificationAndStatusOnly() throws {
        let c = try classify("""
        { "hook_event_name": "PreToolUse", "cli_source": "codex", "session_id": "s1", "tool_name": "shell" }
        """)
        XCTAssertFalse(c.isApproval)
        XCTAssertTrue(c.isNotification)
        XCTAssertTrue(c.isCodexStatusOnlyLifecycleEvent)
    }

    func testNotificationEventClassification() throws {
        let c = try classify("""
        { "hook_event_name": "PostToolUse", "cli_source": "claude", "session_id": "s1", "tool_name": "Read" }
        """)
        XCTAssertTrue(c.isNotification)
        XCTAssertFalse(c.isApproval)
        XCTAssertFalse(c.isStop)
    }

    func testClaudeAskUserQuestionClassification() throws {
        let c = try classify("""
        {
            "hook_event_name": "PreToolUse",
            "cli_source": "claude",
            "session_id": "s1",
            "tool_name": "AskUserQuestion",
            "tool_input": { "questions": [ { "question": "Q?", "options": [ { "label": "A" } ] } ] }
        }
        """)
        XCTAssertTrue(c.isUserQuestionTool)
        XCTAssertTrue(c.isClaudeQuestionRequest)
        XCTAssertNotNil(c.claudeQuestion)
        XCTAssertTrue(c.isApproval)
    }

    func testDisplayToolNameFallbackForElicitationWithServer() throws {
        let c = try classify("""
        { "hook_event_name": "Elicitation", "cli_source": "claude", "session_id": "s1", "mcp_server_name": "github" }
        """)
        XCTAssertEqual(c.displayToolName, "Elicitation (github)")
        XCTAssertEqual(c.replayToolName, "Elicitation (github)")
    }

    func testDisplayToolNameFallbackForElicitationWithoutServer() throws {
        let c = try classify("""
        { "hook_event_name": "Elicitation", "cli_source": "claude", "session_id": "s1" }
        """)
        XCTAssertEqual(c.displayToolName, "Elicitation")
    }

    func testDisplayToolNameFallbackForUserPromptSubmit() throws {
        let c = try classify("""
        { "hook_event_name": "UserPromptSubmit", "cli_source": "claude", "session_id": "s1", "prompt": "hi" }
        """)
        XCTAssertEqual(c.displayToolName, "User Prompt")
        XCTAssertEqual(c.replayToolName, "User Prompt")
        XCTAssertTrue(c.isNotification)
    }
}
