import XCTest
@testable import DevIsland

/// ApprovalFlowContext test double: presentation state the coordinator drives,
/// plus counters for the UI side effects it requests.
private final class FlowContextSpy: ApprovalFlowContext {
    var displayState = ApprovalDisplayState()
    var timeoutProgress: Double = 1.0
    var isNotchExpanded = false
    var isExpandingFromRequest = false

    var syncDisplayCallCount = 0
    var suggestedToolNames: [String] = []
    var clearSuggestionCallCount = 0
    var decidedEvents: [(sessionID: String, approved: Bool, toolName: String, scope: String)] = []

    func syncDisplayToSelectedSession() { syncDisplayCallCount += 1 }
    func updateAlwaysAllowSuggestion(toolName: String) { suggestedToolNames.append(toolName) }
    func clearAlwaysAllowSuggestion() { clearSuggestionCallCount += 1 }
    func emitApprovalDecided(sessionID: String, approved: Bool, toolName: String, scope: String) {
        decidedEvents.append((sessionID, approved, toolName, scope))
    }
}

@MainActor
final class ApprovalFlowCoordinatorTests: XCTestCase {
    private var coordinator: ApprovalFlowCoordinator!
    private var context: FlowContextSpy!
    private var sessionStore: SessionStore!
    private var claudeQuestionState: ClaudeQuestionState!
    private var mockDefaults: UserDefaults!
    // frontmostCheck는 @Sendable로 백그라운드 스레드(Task.detached)에서 호출되므로
    // nonisolated(unsafe) — 테스트가 값을 설정한 뒤 읽기만 하고 동시 변경은 없다.
    private nonisolated(unsafe) var isTerminalFrontmost = false

    override func setUp() {
        super.setUp()
        mockDefaults = UserDefaults(suiteName: "ApprovalFlowCoordinatorTests")
        mockDefaults.removePersistentDomain(forName: "ApprovalFlowCoordinatorTests")

        sessionStore = SessionStore()
        claudeQuestionState = ClaudeQuestionState()
        context = FlowContextSpy()
        isTerminalFrontmost = false
        coordinator = ApprovalFlowCoordinator(
            sessionStore: sessionStore,
            claudeQuestionState: claudeQuestionState,
            replayRecorder: ReplayRecorder(
                proxy: nil,
                queue: DispatchQueue(label: "ApprovalFlowCoordinatorTests")
            ),
            approvalProxy: nil,
            persistenceQueue: DispatchQueue(label: "ApprovalFlowCoordinatorTests.persistence"),
            userDefaults: mockDefaults,
            frontmostCheck: { [weak self] _ in self?.isTerminalFrontmost ?? false }
        )
        coordinator.context = context
    }

    override func tearDown() {
        coordinator = nil
        context = nil
        sessionStore = nil
        claudeQuestionState = nil
        mockDefaults.removePersistentDomain(forName: "ApprovalFlowCoordinatorTests")
        mockDefaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: @escaping () -> Bool
    ) {
        let expectation = expectation(description: "waitUntil")
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() {
                expectation.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
            }
        }
        poll()
        wait(for: [expectation], timeout: timeout + 1.0)
    }

    private func parseResponse(_ response: String) -> [String: Any]? {
        guard let data = response.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func makeHook(
        sessionId: String,
        toolName: String = "bash",
        eventName: String = "PermissionRequest"
    ) -> ParsedHookEvent {
        ParsedHookEvent(
            requestId: nil,
            parsedJSON: [:],
            sessionId: sessionId,
            event: eventName,
            toolName: toolName,
            displayToolName: toolName,
            displayMsg: "Run \(toolName)",
            agentKind: .claudeCode,
            terminalTitle: "Terminal",
            terminal: TerminalContext(),
            workspaceRoot: nil,
            toolInput: nil,
            isSubAgentSession: false,
            parentSessionId: nil,
            isReplayPayload: false,
            isPlanAction: false,
            sessionStartSource: "",
            notificationType: ""
        )
    }

    private func makeRequest(
        sessionId: String,
        toolName: String = "bash",
        claudeQuestion: ClaudeQuestionRequest? = nil,
        responseHandler: @escaping (String) -> Void = { _ in }
    ) -> PendingRequest {
        PendingRequest(
            hookEventId: nil,
            sessionId: sessionId,
            agentKind: .claudeCode,
            // 승인 유효성: Claude 승인 이벤트는 PermissionRequest, 질문은 PreToolUse여야 함
            eventName: claudeQuestion == nil ? "PermissionRequest" : "PreToolUse",
            toolName: toolName,
            rawToolName: claudeQuestion == nil ? toolName : "AskUserQuestion",
            workspaceRoot: nil,
            isReplay: false,
            message: "Run \(toolName)",
            claudeQuestion: claudeQuestion,
            responseHandler: responseHandler,
            receivedAt: Date()
        )
    }

    private func makeQuestion() -> ClaudeQuestionRequest {
        ClaudeQuestionRequest.parse(toolInput: [
            "id": "q1",
            "question": "Pick one",
            "options": [["label": "Alpha", "value": "Alpha"], ["label": "Beta", "value": "Beta"]]
        ])!
    }

    private func enqueue(_ request: PendingRequest) {
        coordinator.enqueueManualRequest(
            request,
            from: makeHook(
                sessionId: request.sessionId,
                toolName: request.toolName,
                eventName: request.eventName
            ),
            isLifecycleTracked: false
        )
    }

    // MARK: - Queue entry & display selection

    func testEnqueueShowsFirstRequest() {
        let request = makeRequest(sessionId: "session-1")
        enqueue(request)

        waitUntil { self.context.displayState.hasResponseHandler }
        XCTAssertEqual(context.displayState.sessionId, "session-1")
        XCTAssertEqual(context.displayState.toolName, "bash")
        XCTAssertEqual(context.displayState.showingRequestId, request.id)
        XCTAssertEqual(sessionStore.selectedSessionId, "session-1")
        XCTAssertEqual(context.suggestedToolNames, ["bash"])
        XCTAssertTrue(context.isExpandingFromRequest)
    }

    func testEnqueueWhileShowingKeepsFirstAndSyncsDisplay() {
        enqueue(makeRequest(sessionId: "session-1"))
        waitUntil { self.context.displayState.hasResponseHandler }

        let second = makeRequest(sessionId: "session-2")
        enqueue(second)

        XCTAssertEqual(context.displayState.sessionId, "session-1")
        XCTAssertEqual(sessionStore.pendingQueue.count, 2)
        XCTAssertEqual(context.syncDisplayCallCount, 1)
    }

    func testApprovalPreemptsShowingClaudeQuestion() {
        enqueue(makeRequest(sessionId: "question-session", claudeQuestion: makeQuestion()))
        waitUntil { self.claudeQuestionState.currentClaudeQuestion != nil }

        enqueue(makeRequest(sessionId: "approval-session"))
        waitUntil { self.context.displayState.sessionId == "approval-session" }

        XCTAssertNil(claudeQuestionState.currentClaudeQuestion)
        XCTAssertTrue(context.displayState.hasResponseHandler)
        // 질문 요청은 큐에 남아 있어 결정 후 다시 표시된다
        XCTAssertEqual(sessionStore.pendingQueue.count, 2)

        coordinator.sendDecision(approved: true)
        waitUntil { self.context.displayState.sessionId == "question-session" }
        XCTAssertNotNil(claudeQuestionState.currentClaudeQuestion)
    }

    // MARK: - Decision dispatch

    func testSendDecisionDeliversPayloadAndAdvancesQueue() {
        var firstResponse: String?
        enqueue(makeRequest(sessionId: "session-1", responseHandler: { firstResponse = $0 }))
        waitUntil { self.context.displayState.hasResponseHandler }
        enqueue(makeRequest(sessionId: "session-2"))

        coordinator.sendDecision(approved: true)

        waitUntil { self.context.displayState.sessionId == "session-2" }
        XCTAssertEqual(parseResponse(firstResponse ?? "")?["response"] as? String, "approved")
        XCTAssertEqual(sessionStore.pendingQueue.count, 1)
        XCTAssertEqual(context.decidedEvents.count, 1)
        XCTAssertEqual(context.decidedEvents.first?.approved, true)
        XCTAssertEqual(context.decidedEvents.first?.scope, RuleScope.once.rawValue)
    }

    func testSendDecisionPassToTerminalDoesNotEmitDecidedEvent() {
        var response: String?
        enqueue(makeRequest(sessionId: "session-1", responseHandler: { response = $0 }))
        waitUntil { self.context.displayState.hasResponseHandler }

        coordinator.sendDecision(approved: false, reason: "Dismissed", passToTerminal: true)

        waitUntil { self.sessionStore.pendingQueue.isEmpty }
        XCTAssertEqual(parseResponse(response ?? "")?["response"] as? String, "pass")
        XCTAssertFalse(context.displayState.hasResponseHandler)
        XCTAssertTrue(context.decidedEvents.isEmpty)
    }

    // MARK: - Timeout

    func testTimeoutPassesRequestToTerminal() {
        mockDefaults.set(0.3, forKey: SettingsStore.DefaultsKey.permissionTimeoutSeconds)
        context.isNotchExpanded = true

        var response: String?
        enqueue(makeRequest(sessionId: "session-1", responseHandler: { response = $0 }))
        waitUntil { self.context.displayState.hasResponseHandler }

        waitUntil(timeout: 3.0) { response != nil }
        let parsed = parseResponse(response ?? "")
        XCTAssertEqual(parsed?["response"] as? String, "pass")
        XCTAssertEqual(parsed?["reason"] as? String, "Timeout")
        waitUntil { self.sessionStore.pendingQueue.isEmpty }
        XCTAssertFalse(context.displayState.hasResponseHandler)
    }

    func testCancelTimeoutResetsProgress() {
        context.timeoutProgress = 0.4
        coordinator.cancelTimeout()
        XCTAssertEqual(context.timeoutProgress, 1.0)
    }

    // MARK: - Frontmost bypass

    func testFrontmostTerminalBypassesRequest() {
        isTerminalFrontmost = true
        var response: String?
        enqueue(makeRequest(sessionId: "session-1", responseHandler: { response = $0 }))

        waitUntil { response != nil }
        let parsed = parseResponse(response ?? "")
        XCTAssertEqual(parsed?["response"] as? String, "pass")
        XCTAssertEqual(parsed?["reason"] as? String, "TerminalFocused")
        waitUntil { self.sessionStore.pendingQueue.isEmpty }
        XCTAssertFalse(context.displayState.hasResponseHandler)
    }

    // MARK: - Invalid request handling

    func testShowNextRequestDiscardsInvalidRequestWithPass() {
        var response: String?
        // 승인 이벤트가 아니고 toolName/message가 모두 비어 있는 무효 요청
        let invalid = PendingRequest(
            hookEventId: nil,
            sessionId: "session-1",
            agentKind: .claudeCode,
            eventName: "SessionStart",
            toolName: "",
            rawToolName: "",
            workspaceRoot: nil,
            isReplay: false,
            message: "",
            claudeQuestion: nil,
            responseHandler: { response = $0 },
            receivedAt: Date()
        )
        sessionStore.appendPending(request: invalid, item: PendingItem(
            id: invalid.id,
            toolName: "",
            message: "",
            sessionId: invalid.sessionId,
            terminalTitle: "",
            terminalWindowId: "",
            terminalTabIndex: "",
            terminalTmuxPane: "",
            terminalTmuxSocket: "",
            terminalTmuxClient: "",
            receivedAt: invalid.receivedAt
        ))

        coordinator.showNextRequest()

        XCTAssertEqual(parseResponse(response ?? "")?["response"] as? String, "pass")
        XCTAssertTrue(sessionStore.pendingQueue.isEmpty)
        XCTAssertFalse(context.displayState.hasResponseHandler)
    }

    // MARK: - previousSessionId

    func testPreviousSessionIdRequiresLiveSession() {
        coordinator.previousSessionId = "gone-session"
        XCTAssertNil(coordinator.previousSessionId)

        sessionStore.updateActiveSession(
            sessionId: "live-session",
            terminalTitle: "Terminal",
            agentKind: .claudeCode,
            terminal: TerminalContext(),
            toolName: "bash",
            eventName: "PreToolUse",
            message: "msg",
            isPending: false
        )
        coordinator.previousSessionId = "live-session"
        XCTAssertEqual(coordinator.previousSessionId, "live-session")
    }
}
