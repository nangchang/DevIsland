import XCTest
@testable import DevIsland

final class OpenPeonEventMapperTests: XCTestCase {
    func testApprovalEventsMapToInputRequired() {
        XCTAssertEqual(map("PermissionRequest"), .inputRequired)
        XCTAssertEqual(map("BeforeTool"), .inputRequired)
        XCTAssertEqual(map("Elicitation"), .inputRequired)
    }

    func testCompletionEventsMapToTaskComplete() {
        XCTAssertEqual(map("Stop"), .taskComplete)
        XCTAssertEqual(map("AfterAgent"), .taskComplete)
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
