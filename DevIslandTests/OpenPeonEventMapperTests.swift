import XCTest
@testable import DevIsland

final class OpenPeonEventMapperTests: XCTestCase {
    func testApprovalEventsMapToInputRequired() {
        XCTAssertEqual(map("PermissionRequest"), .inputRequired)
        XCTAssertEqual(map("AfterAgent"), .inputRequired)
        XCTAssertEqual(map("Elicitation"), .inputRequired)
    }

    func testAcknowledgeEventsMapToTaskAcknowledge() {
        XCTAssertEqual(map("PreToolUse"), .taskAcknowledge)
        XCTAssertEqual(map("BeforeTool"), .taskAcknowledge)
    }

    func testCompletionEventsMapToTaskComplete() {
        XCTAssertEqual(map("Stop"), .taskComplete)
    }

    func testPreCompactMapsToResourceLimit() {
        XCTAssertEqual(map("PreCompact"), .resourceLimit)
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
                agentKind: .claudeCode,
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

    private func map(_ event: String) -> CESPCategory? {
        CESPEventMapper.category(
            event: event,
            normalizedEvent: HookEventNormalizer.normalizedName(event),
            agentKind: .claudeCode,
            toolName: "",
            notificationType: "",
            message: "",
            payload: nil
        )
    }
}
