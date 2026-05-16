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
        XCTAssertEqual(map("PostToolUse", for: .codex), .taskComplete)
    }

    func testPreCompactMapsToResourceLimit() {
        XCTAssertEqual(map("PreCompact", for: .gemini), .resourceLimit)
    }

    func testFailurePostToolUseMapsToTaskError() {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_response": ["success": false]
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
        XCTAssertNil(
            CESPEventMapper.category(
                event: "Notification",
                normalizedEvent: "notification",
                agentKind: .claudeCode,
                toolName: "",
                notificationType: "info",
                message: "I will fix the syntax error.",
                payload: nil
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
        let payload: [String: Any] = ["error": "System crash"]
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
            "Machine-readable failure in payload should trigger taskError even if type is generic"
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
