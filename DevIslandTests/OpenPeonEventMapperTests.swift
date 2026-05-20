import XCTest
@testable import DevIsland

final class OpenPeonEventMapperTests: XCTestCase {
    func testApprovalEventsMapToInputRequired() {
        XCTAssertEqual(map("PermissionRequest", for: .claudeCode), .inputRequired)
        XCTAssertEqual(map("Elicitation", for: .claudeCode), .inputRequired)
        XCTAssertEqual(map("AfterAgent", for: .gemini), .inputRequired)
        XCTAssertEqual(map("PermissionRequest", for: .codex), .inputRequired)
    }

    func testAcknowledgeEventsMapToTaskAcknowledge() {
        XCTAssertEqual(map("PreToolUse", for: .codex), .taskAcknowledge)
        XCTAssertEqual(map("PreToolUse", for: .claudeCode), .taskAcknowledge)
        XCTAssertEqual(map("BeforeTool", for: .gemini), .taskAcknowledge)
    }

    func testCompletionEventsMapToTaskComplete() {
        XCTAssertEqual(map("Stop", for: .gemini), .taskComplete)
        XCTAssertEqual(map("Stop", for: .claudeCode), .taskComplete)
        XCTAssertEqual(map("Stop", for: .codex), .taskComplete)
        XCTAssertNil(map("PostToolUse", for: .codex))
        XCTAssertNil(map("PostToolUse", for: .claudeCode))
    }

    func testPreCompactMapsToResourceLimit() {
        XCTAssertEqual(map("PreCompact", for: .gemini), .resourceLimit)
    }

    func testCodexPostToolUseSuccessFalseIsTaskError() {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_response": [
                "success": false,
                "error": "compilation failed"
            ]
        ]

        XCTAssertEqual(
            CESPEventMapper.category(
                event: "PostToolUse",
                normalizedEvent: "posttooluse",
                agentKind: .codex,
                toolName: "Bash",
                notificationType: "",
                message: "",
                payload: payload
            ),
            .taskError
        )
    }

    func testCodexPostToolUseStatusErrorIsTaskError() {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_response": ["status": "error"]
        ]

        XCTAssertEqual(
            CESPEventMapper.category(
                event: "PostToolUse",
                normalizedEvent: "posttooluse",
                agentKind: .codex,
                toolName: "Bash",
                notificationType: "",
                message: "",
                payload: payload
            ),
            .taskError
        )
    }

    func testClaudePostToolUseFailureMapsToTaskError() {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUseFailure",
            "error": "Tool execution failed",
            "is_interrupt": false
        ]

        XCTAssertEqual(
            CESPEventMapper.category(
                event: "PostToolUseFailure",
                normalizedEvent: "posttoolusefailure",
                agentKind: .claudeCode,
                toolName: "Bash",
                notificationType: "",
                message: "Tool execution failed",
                payload: payload
            ),
            .taskError
        )
    }

    func testClaudePostToolUseOutputDoesNotMapToSoundEvent() {
        // Claude reports real tool failures through PostToolUseFailure; PostToolUse
        // output can contain compiler/test error text without producing sound feedback.
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_response": [
                "stdout": "** TEST FAILED **\nerror: compiler diagnostic",
                "stderr": "",
                "interrupted": false
            ]
        ]

        XCTAssertNil(
            CESPEventMapper.category(
                event: "PostToolUse",
                normalizedEvent: "posttooluse",
                agentKind: .claudeCode,
                toolName: "Bash",
                notificationType: "",
                message: "** TEST FAILED **\nerror: compiler diagnostic",
                payload: payload
            ),
            "Claude PostToolUse does not produce sound feedback; PostToolUseFailure carries tool execution failures"
        )
    }

    func testCodexPostToolUseWithMessageDescribingErrorDoesNotMapToSoundEvent() {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_response": [
                "success": true,
                "stdout": "The command succeeded after an initial error.",
                "stderr": ""
            ]
        ]
        XCTAssertEqual(
            CESPEventMapper.category(
                event: "PostToolUse",
                normalizedEvent: "posttooluse",
                agentKind: .codex,
                toolName: "Bash",
                notificationType: "",
                message: "The command succeeded after an initial error.",
                payload: payload
            ),
            nil,
            "Codex PostToolUse is per-tool output and should not trigger completion or error sound without structured failure"
        )
    }

    func testCodexPostToolUseObjectOutputDescribingErrorDoesNotMapToSoundEvent() {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_response": [
                "stdout": "error: build failed",
                "stderr": "timeout while retrying",
                "output": "task.error documentation",
                "diagnostics": ["error": "reported in command output"]
            ]
        ]

        XCTAssertEqual(
            CESPEventMapper.category(
                event: "PostToolUse",
                normalizedEvent: "posttooluse",
                agentKind: .codex,
                toolName: "Bash",
                notificationType: "",
                message: "error: build failed",
                payload: payload
            ),
            nil,
            "Codex tool_response output fields are not structured failure signals or completion signals"
        )
    }

    func testCodexPostToolUseStringResponseDescribingErrorDoesNotMapToSoundEvent() {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_response": "docs mention task.error, failed checks, and timeout handling"
        ]

        XCTAssertEqual(
            CESPEventMapper.category(
                event: "PostToolUse",
                normalizedEvent: "posttooluse",
                agentKind: .codex,
                toolName: "Bash",
                notificationType: "",
                message: "docs mention task.error, failed checks, and timeout handling",
                payload: payload
            ),
            nil,
            "Codex string tool_response is command output, not a structured failure or completion signal"
        )
    }

    func testCodexPostToolUseEmptyErrorValueDoesNotMapToSoundEvent() {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_response": [
                "success": true,
                "error": NSNull(),
                "errors": [],
                "failed": false
            ]
        ]

        XCTAssertEqual(
            CESPEventMapper.category(
                event: "PostToolUse",
                normalizedEvent: "posttooluse",
                agentKind: .codex,
                toolName: "Bash",
                notificationType: "",
                message: "",
                payload: payload
            ),
            nil
        )
    }

    func testNotificationInputRequiredMapsToInputRequired() {
        XCTAssertEqual(
            CESPEventMapper.category(
                event: "Notification",
                normalizedEvent: "notification",
                agentKind: .claudeCode,
                toolName: "",
                notificationType: "input_required",
                message: "",
                payload: nil
            ),
            .inputRequired
        )
    }

    func testClaudeNotificationWithMessageDescribingErrorIsNotTaskError() {
        let payload: [String: Any] = [
            "notification_type": "info",
            "message": "I will fix the syntax error."
        ]
        XCTAssertNil(
            CESPEventMapper.category(
                event: "Notification",
                normalizedEvent: "notification",
                agentKind: .claudeCode,
                toolName: "",
                notificationType: "info",
                message: "I will fix the syntax error.",
                payload: payload
            ),
            "Descriptive messages about errors should not trigger taskError sound for Claude"
        )
    }

    func testClaudeNotificationWithActualErrorTypeIsTaskError() {
        XCTAssertEqual(
            CESPEventMapper.category(
                event: "Notification",
                normalizedEvent: "notification",
                agentKind: .claudeCode,
                toolName: "",
                notificationType: "error",
                message: "Fatal error occurred",
                payload: nil
            ),
            .taskError,
            "Actual error notification type should trigger taskError"
        )
    }

    func testClaudeNotificationWithMachineReadableErrorInPayloadIsTaskError() {
        let payload: [String: Any] = [
            "error_details": ["code": 500, "reason": "Internal server error"],
            "message": "Just checking in..."
        ]
        XCTAssertEqual(
            CESPEventMapper.category(
                event: "Notification",
                normalizedEvent: "notification",
                agentKind: .claudeCode,
                toolName: "",
                notificationType: "info",
                message: "Just checking in...",
                payload: payload
            ),
            .taskError,
            "Machine-readable failure in payload (even in nested fields) should trigger taskError"
        )
    }

    // MARK: - containsFailureKeyword policy

    func testFailureKeywordsMatch() {
        XCTAssertTrue(CESPEventMapper.isFailurePayload(nil, message: "error"))
        XCTAssertTrue(CESPEventMapper.isFailurePayload(nil, message: "errors found"))
        XCTAssertTrue(CESPEventMapper.isFailurePayload(nil, message: "2 errors found"))
        XCTAssertTrue(CESPEventMapper.isFailurePayload(nil, message: "Build failed."))
        XCTAssertTrue(CESPEventMapper.isFailurePayload(nil, message: "request timeout"))
        XCTAssertTrue(CESPEventMapper.isFailurePayload(nil, message: "error:"))
    }

    func testNonFailureKeywordsDoNotMatch() {
        XCTAssertFalse(CESPEventMapper.isFailurePayload(nil, message: "No errors found"))
        XCTAssertFalse(CESPEventMapper.isFailurePayload(nil, message: "no error"))
        XCTAssertFalse(CESPEventMapper.isFailurePayload(nil, message: "no timeout"))
        XCTAssertFalse(CESPEventMapper.isFailurePayload(nil, message: "terror"))
        XCTAssertFalse(CESPEventMapper.isFailurePayload(nil, message: "All tests passed"))
        XCTAssertFalse(CESPEventMapper.isFailurePayload(nil, message: ""))
        // \b treats _ as a word char: snake_case and camelCase are not matched at the
        // message level.
        XCTAssertFalse(CESPEventMapper.isFailurePayload(nil, message: "error_code"))
        XCTAssertFalse(CESPEventMapper.isFailurePayload(nil, message: "timeout_error"))
        XCTAssertFalse(CESPEventMapper.isFailurePayload(nil, message: "NullPointerException"))
    }

    private func map(_ event: String, for agent: BuddyKind = .claudeCode) -> CESPCategory? {
        CESPEventMapper.category(
            event: event,
            normalizedEvent: HookEventNormalizer.normalizedName(event),
            agentKind: agent,
            toolName: "",
            notificationType: "",
            message: "",
            payload: nil
        )
    }
}
