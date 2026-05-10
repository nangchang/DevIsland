import XCTest
@testable import DevIsland

final class ApprovalProxyControllerTests: XCTestCase {
    private var tempDir: URL!
    private var databaseURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApprovalProxyControllerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseURL = tempDir.appendingPathComponent("approval-proxy.sqlite3")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        databaseURL = nil
        super.tearDown()
    }

    func testRecordsEventEvaluatesPolicyAndRecordsDecision() throws {
        let controller = try ApprovalProxyController(databaseURL: databaseURL)
        try controller.store.upsertSessionApproval(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell",
            action: .allow,
            expiresAt: nil
        )

        let eventId = try controller.recordHookEvent(
            requestId: "request-1",
            provider: .codex,
            sessionId: "session-1",
            eventName: "PermissionRequest",
            toolName: "shell",
            payloadJSON: #"{"hook_event_name":"PermissionRequest"}"#
        )
        let request = ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell"
        )
        let decision = try controller.evaluate(request)
        let decisionId = try controller.recordDecision(
            hookEventId: eventId,
            request: request,
            decision: decision,
            reason: "matched test session cache"
        )

        XCTAssertEqual(decision.action, .allow)
        XCTAssertEqual(decision.source, .sessionCache)
        XCTAssertGreaterThan(decisionId, 0)
    }
}
