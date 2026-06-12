import XCTest
@testable import DevIsland

final class ApprovalQueuePolicyTests: XCTestCase {
    private func sampleQuestion() -> ClaudeQuestionRequest {
        let parsed = ClaudeQuestionRequest.parse(toolInput: [
            "questions": [["question": "Q?", "options": [["label": "A"]]]]
        ])
        return parsed!
    }

    private func request(
        event: String = "PermissionRequest",
        agent: BuddyKind = .claudeCode,
        tool: String = "Bash",
        rawTool: String? = nil,
        message: String = "msg",
        question: ClaudeQuestionRequest? = nil,
        sessionId: String = "s1"
    ) -> PendingRequest {
        PendingRequest(
            hookEventId: nil,
            sessionId: sessionId,
            agentKind: agent,
            eventName: event,
            toolName: tool,
            rawToolName: rawTool ?? tool,
            workspaceRoot: nil,
            isReplay: false,
            message: message,
            claudeQuestion: question,
            responseHandler: { _ in },
            receivedAt: Date()
        )
    }

    // MARK: isPriority

    func testApprovalRequestIsPriorityAndQuestionIsNot() {
        XCTAssertTrue(ApprovalQueuePolicy.isPriority(request()))
        XCTAssertFalse(ApprovalQueuePolicy.isPriority(
            request(event: "PreToolUse", tool: "AskUserQuestion", rawTool: "AskUserQuestion", question: sampleQuestion())
        ))
    }

    // MARK: isValidApprovalRequest

    func testValidApprovalRequestForClaudePermissionWithTool() {
        XCTAssertTrue(ApprovalQueuePolicy.isValidApprovalRequest(request()))
    }

    func testInvalidWhenApprovalEventButToolAndMessageEmpty() {
        XCTAssertFalse(ApprovalQueuePolicy.isValidApprovalRequest(request(tool: "", message: "")))
    }

    func testValidWhenApprovalEventToolEmptyButMessagePresent() {
        XCTAssertTrue(ApprovalQueuePolicy.isValidApprovalRequest(request(tool: "", message: "do thing")))
    }

    func testInvalidWhenEventIsNotApprovalEvent() {
        XCTAssertFalse(ApprovalQueuePolicy.isValidApprovalRequest(request(event: "PostToolUse")))
    }

    func testQuestionValidOnlyForClaudePreToolUseQuestionTool() {
        let q = sampleQuestion()
        XCTAssertTrue(ApprovalQueuePolicy.isValidApprovalRequest(
            request(event: "PreToolUse", tool: "AskUserQuestion", rawTool: "AskUserQuestion", question: q)
        ))
        // wrong event
        XCTAssertFalse(ApprovalQueuePolicy.isValidApprovalRequest(
            request(event: "PermissionRequest", tool: "AskUserQuestion", rawTool: "AskUserQuestion", question: q)
        ))
        // wrong agent
        XCTAssertFalse(ApprovalQueuePolicy.isValidApprovalRequest(
            request(event: "PreToolUse", agent: .codex, tool: "AskUserQuestion", rawTool: "AskUserQuestion", question: q)
        ))
    }

    // MARK: nextToDisplay

    func testWindowedPriorityRequestWinsOverEarlierNonWindowedPriority() {
        let nonWindowed = request(sessionId: "s1")
        let windowed = request(sessionId: "s-window")
        let next = ApprovalQueuePolicy.nextToDisplay(in: [nonWindowed, windowed]) { $0 == "s-window" }
        XCTAssertEqual(next?.id, windowed.id)
    }

    func testFirstPriorityWinsWhenNoWindow() {
        let q = request(event: "PreToolUse", tool: "AskUserQuestion", rawTool: "AskUserQuestion", question: sampleQuestion())
        let approval = request(sessionId: "s2")
        let next = ApprovalQueuePolicy.nextToDisplay(in: [q, approval]) { _ in false }
        XCTAssertEqual(next?.id, approval.id)
    }

    func testQuestionReturnedWhenNoApprovalRequestInQueue() {
        let q = request(event: "PreToolUse", tool: "AskUserQuestion", rawTool: "AskUserQuestion", question: sampleQuestion())
        let next = ApprovalQueuePolicy.nextToDisplay(in: [q]) { _ in false }
        XCTAssertEqual(next?.id, q.id)
    }

    func testEmptyQueueReturnsNil() {
        XCTAssertNil(ApprovalQueuePolicy.nextToDisplay(in: []) { _ in true })
    }

    // MARK: showingIsLowerPriority

    func testPriorityPreemptsShowingQuestion() {
        let showingQuestion = request(event: "PreToolUse", tool: "AskUserQuestion", rawTool: "AskUserQuestion", question: sampleQuestion())
        let incoming = request(sessionId: "s2")
        XCTAssertTrue(ApprovalQueuePolicy.showingIsLowerPriority(
            than: incoming, showingRequestId: showingQuestion.id, queue: [showingQuestion, incoming]
        ))
    }

    func testPriorityDoesNotPreemptShowingPriority() {
        let showingApproval = request(sessionId: "s1")
        let incoming = request(sessionId: "s2")
        XCTAssertFalse(ApprovalQueuePolicy.showingIsLowerPriority(
            than: incoming, showingRequestId: showingApproval.id, queue: [showingApproval, incoming]
        ))
    }

    func testIncomingQuestionNeverPreempts() {
        let showingApproval = request(sessionId: "s1")
        let incomingQuestion = request(event: "PreToolUse", tool: "AskUserQuestion", rawTool: "AskUserQuestion", question: sampleQuestion())
        XCTAssertFalse(ApprovalQueuePolicy.showingIsLowerPriority(
            than: incomingQuestion, showingRequestId: showingApproval.id, queue: [showingApproval, incomingQuestion]
        ))
    }

    func testNoPreemptionWhenNothingShowing() {
        let incoming = request(sessionId: "s2")
        XCTAssertFalse(ApprovalQueuePolicy.showingIsLowerPriority(
            than: incoming, showingRequestId: nil, queue: [incoming]
        ))
    }
}
