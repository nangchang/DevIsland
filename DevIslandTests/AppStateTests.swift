import XCTest
@testable import DevIsland

final class AppStateTests: XCTestCase {
    var appState: AppState!
    var mockDefaults: UserDefaults!
    
    override func setUp() {
        super.setUp()
        // Use a clean UserDefaults for each test
        mockDefaults = UserDefaults(suiteName: "AppStateTests")
        mockDefaults.removePersistentDomain(forName: "AppStateTests")
        
        // Mock frontmostCheck to always return false to ensure requests go to the queue
        appState = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _, _, _, _ in false }
        )
    }
    
    override func tearDown() {
        appState = nil
        mockDefaults.removePersistentDomain(forName: "AppStateTests")
        mockDefaults = nil
        super.tearDown()
    }
    
    private func parseResponse(_ response: String) -> [String: Any]? {
        guard let data = response.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    
    func testNormalizedHookEventName() {
        XCTAssertEqual(appState.normalizedHookEventName("BeforeTool"), "beforetool")
        XCTAssertEqual(appState.normalizedHookEventName("on_tool_call"), "ontoolcall")
        XCTAssertEqual(appState.normalizedHookEventName("Pre-Tool-Use"), "pretooluse")
        XCTAssertEqual(appState.normalizedHookEventName("SESSION_START"), "sessionstart")
    }
    
    func testAgentKindDetection() {
        // Test Gemini detection
        let geminiJson: [String: Any] = ["hook_event_name": "BeforeTool"]
        XCTAssertEqual(AppState.agentKind(from: geminiJson, terminalTitle: "Terminal"), .gemini)
        
        // Test Codex detection
        let codexJson: [String: Any] = ["event": "PreToolUse"]
        XCTAssertEqual(AppState.agentKind(from: codexJson, terminalTitle: "Terminal"), .codex)
        
        // Test explicit source
        let explicitJson: [String: Any] = ["cli_source": "claude"]
        XCTAssertEqual(AppState.agentKind(from: explicitJson, terminalTitle: "Terminal"), .claudeCode)
        
        // Test terminal title fallback
        XCTAssertEqual(AppState.agentKind(from: [:], terminalTitle: "Claude"), .claudeCode)
    }
    
    func testHandleMessageNotification() {
        let expectation = XCTestExpectation(description: "Response handler called")
        let message = """
        {
            "hook_event_name": "sessionstart",
            "session_id": "test-session",
            "terminal_title": "Test Terminal"
        }
        """
        
        appState.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }
        
        // Wait for main thread async blocks in handleMessage
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        
        wait(for: [expectation], timeout: 2.0)
        
        // Verify session was added
        XCTAssertTrue(appState.activeSessions.contains(where: { $0.id == "test-session" }))
    }

    func testPendingRequestQueue() {
        let expectation = XCTestExpectation(description: "Response handler called for approval")
        let message = """
        {
            "hook_event_name": "permissionrequest",
            "session_id": "test-session-approval",
            "tool_name": "write_to_file",
            "tool_input": {"file_path": "test.txt", "content": "hello"}
        }
        """
        
        appState.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }
        
        // Wait for main thread async blocks in handleMessage (including frontmost check background block)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        
        // Should be pending
        XCTAssertEqual(appState.pendingCount, 1)
        XCTAssertTrue(appState.hasResponseHandler)
        
        // Approve manually
        appState.approve()
        
        // Wait for main thread async blocks in approve()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        
        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(appState.pendingCount, 0)
    }
    
    func testSafeToolAutoApproval() {
        appState.autoApproveSafeTools = true
        
        let expectation = XCTestExpectation(description: "Safe tool auto-approved")
        let message = """
        {
            "hook_event_name": "permissionrequest",
            "session_id": "test-session-safe",
            "tool_name": "read_file",
            "tool_input": {"path": "README.md"}
        }
        """
        
        appState.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(appState.pendingCount, 0)
    }
    
    func testGeminiAutoEditMode() {
        let sessionId = "gemini-session"
        
        // 1. Initial tool call (Should be pending)
        let msg1 = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "\(sessionId)",
            "tool_name": "write_to_file"
        }
        """
        appState.handleMessage(msg1) { _ in }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertEqual(appState.pendingCount, 1)
        XCTAssertEqual(appState.currentSessionId, sessionId)
        appState.approve()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        // 2. Trigger exit_plan_mode (Simulates moving to execution phase)
        let exitPlan = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "\(sessionId)",
            "tool_name": "exit_plan_mode"
        }
        """
        appState.handleMessage(exitPlan) { _ in }
        
        // Wait longer because exit_plan_mode handling involves a global queue -> main queue jump
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        
        // Verify session is now in auto-edit active mode
        let session = appState.activeSessions.first { $0.id == sessionId }
        XCTAssertNotNil(session, "Session should exist in activeSessions")
        XCTAssertTrue(session?.isAutoEditActive ?? false, "Session should be in Auto-Edit mode after exit_plan_mode")
        
        // 3. Subsequent tool call (Should be auto-approved)
        let expectation = XCTestExpectation(description: "Tool auto-approved in auto-edit mode")
        let msg2 = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "\(sessionId)",
            "tool_name": "replace_file_content"
        }
        """
        appState.handleMessage(msg2) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(appState.pendingCount, 0)
        
        // 4. Trigger enter_plan_mode (Should reset auto-edit mode)
        let enterPlan = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "\(sessionId)",
            "tool_name": "enter_plan_mode"
        }
        """
        appState.handleMessage(enterPlan) { _ in }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        
        let resetSession = appState.activeSessions.first { $0.id == sessionId }
        XCTAssertFalse(resetSession?.isAutoEditActive ?? true, "Session should not be in Auto-Edit mode after enter_plan_mode")
    }
    
    func testGeminiInteractiveToolAutoApproval() {
        let expectation = XCTestExpectation(description: "Interactive question shown as notification")
        let message = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "gemini-interactive",
            "tool_name": "ask_user",
            "tool_input": {"prompt": "how are you?"}
        }
        """
        
        appState.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }
        
        // Wait for main thread async blocks
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(appState.pendingCount, 0)
        XCTAssertFalse(appState.hasResponseHandler)
        XCTAssertTrue(appState.isNotchExpanded)
        XCTAssertTrue(appState.currentMessage.contains("how are you?"))
    }

    func testOnlySourceSpecificEventsBecomeApprovalRequests() {
        let codexPreToolExpectation = XCTestExpectation(description: "Codex PreToolUse is notification")
        let claudeBeforeToolExpectation = XCTestExpectation(description: "Claude BeforeTool is notification")
        let geminiPreToolExpectation = XCTestExpectation(description: "Gemini PreToolUse is notification")

        let codexPreTool = """
        {
            "hook_event_name": "PreToolUse",
            "cli_source": "codex",
            "session_id": "codex-pretool",
            "tool_name": "shell",
            "tool_input": {"command": "echo hello"}
        }
        """
        appState.handleMessage(codexPreTool) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            codexPreToolExpectation.fulfill()
        }

        let claudeBeforeTool = """
        {
            "hook_event_name": "BeforeTool",
            "cli_source": "claude",
            "session_id": "claude-beforetool",
            "tool_name": "Bash",
            "tool_input": {"command": "echo hello"}
        }
        """
        appState.handleMessage(claudeBeforeTool) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            claudeBeforeToolExpectation.fulfill()
        }

        let geminiPreTool = """
        {
            "hook_event_name": "PreToolUse",
            "cli_source": "gemini",
            "session_id": "gemini-pretool",
            "tool_name": "write_file",
            "tool_input": {"file_path": "test.txt", "content": "hello"}
        }
        """
        appState.handleMessage(geminiPreTool) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            geminiPreToolExpectation.fulfill()
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

        wait(for: [codexPreToolExpectation, claudeBeforeToolExpectation, geminiPreToolExpectation], timeout: 1.0)
        XCTAssertEqual(appState.pendingCount, 0)
        XCTAssertFalse(appState.hasResponseHandler)
    }

    func testClaudeToolLifecycleEventsAreStatusNotifications() {
        let preToolExpectation = XCTestExpectation(description: "Claude PreToolUse is notification")
        let postToolExpectation = XCTestExpectation(description: "Claude PostToolUse is notification")

        let preTool = """
        {
            "hook_event_name": "PreToolUse",
            "cli_source": "claude",
            "session_id": "claude-lifecycle",
            "tool_name": "Bash",
            "tool_input": {"command": "swift test"}
        }
        """
        appState.handleMessage(preTool) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            preToolExpectation.fulfill()
        }

        let postTool = """
        {
            "hook_event_name": "PostToolUse",
            "cli_source": "claude",
            "session_id": "claude-lifecycle",
            "tool_name": "Bash",
            "tool_response": {"stdout": "ok"}
        }
        """
        appState.handleMessage(postTool) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            postToolExpectation.fulfill()
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

        wait(for: [preToolExpectation, postToolExpectation], timeout: 1.0)
        XCTAssertEqual(appState.pendingCount, 0)
        XCTAssertFalse(appState.hasResponseHandler)
        XCTAssertTrue(appState.activeSessions.contains(where: { $0.id == "claude-lifecycle" }))
    }
    
    func testMultipleSessions() {
        var callCount1 = 0
        var callCount2 = 0
        
        let msg1 = """
        {
            "hook_event_name": "permissionrequest",
            "session_id": "session-1",
            "tool_name": "tool-1"
        }
        """
        let msg2 = """
        {
            "hook_event_name": "permissionrequest",
            "session_id": "session-2",
            "tool_name": "tool-2"
        }
        """
        
        appState.handleMessage(msg1) { _ in callCount1 += 1 }
        appState.handleMessage(msg2) { _ in callCount2 += 1 }
        
        // Wait for main thread async blocks in handleMessage (including frontmost check background block)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        
        XCTAssertEqual(appState.pendingCount, 2)
        XCTAssertEqual(appState.activeSessions.count, 2)
        XCTAssertEqual(appState.currentSessionId, "session-1")
        XCTAssertEqual(callCount1, 0, "Response handler 1 should not be called yet")
        
        // Approve first
        appState.approve()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        
        XCTAssertEqual(callCount1, 1, "Response handler 1 should be called exactly once")
        XCTAssertEqual(appState.pendingCount, 1)
        XCTAssertEqual(appState.currentSessionId, "session-2")
        XCTAssertEqual(callCount2, 0, "Response handler 2 should not be called yet")

        // Approve second
        appState.approve()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        
        XCTAssertEqual(callCount2, 1, "Response handler 2 should be called exactly once")
        XCTAssertEqual(appState.pendingCount, 0)
    }

    func testStopEventClearsShowingRequestLock() {
        var deniedResponse: String?
        var secondCallCount = 0
        let stopExpectation = XCTestExpectation(description: "Stop event responds")

        let firstApproval = """
        {
            "hook_event_name": "permissionrequest",
            "session_id": "session-stop",
            "tool_name": "tool-stop"
        }
        """
        let secondApproval = """
        {
            "hook_event_name": "permissionrequest",
            "session_id": "session-next",
            "tool_name": "tool-next"
        }
        """
        let stopEvent = """
        {
            "hook_event_name": "sessionend",
            "session_id": "session-stop"
        }
        """

        appState.handleMessage(firstApproval) { response in deniedResponse = response }
        appState.handleMessage(secondApproval) { _ in secondCallCount += 1 }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))

        XCTAssertEqual(appState.currentSessionId, "session-stop")

        appState.handleMessage(stopEvent) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            stopExpectation.fulfill()
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        wait(for: [stopExpectation], timeout: 1.0)
        XCTAssertEqual(self.parseResponse(deniedResponse ?? "")?["response"] as? String, "denied")
        XCTAssertEqual(appState.pendingCount, 1)
        XCTAssertEqual(appState.currentSessionId, "session-next")
        XCTAssertEqual(secondCallCount, 0)

        appState.approve()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        XCTAssertEqual(secondCallCount, 1)
        XCTAssertEqual(appState.pendingCount, 0)
    }

    func testDismissSessionRemovesPendingRequestAndPassesToTerminal() {
        let expectation = XCTestExpectation(description: "Pending request passed when session dismissed")
        var receivedResponse: String?
        let message = """
        {
            "hook_event_name": "PermissionRequest",
            "cli_source": "codex",
            "session_id": "dismiss-session",
            "tool_name": "shell",
            "tool_input": {"command": "rm -rf build"}
        }
        """

        appState.handleMessage(message) { response in
            receivedResponse = response
            expectation.fulfill()
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        XCTAssertEqual(appState.pendingCount, 1)
        XCTAssertTrue(appState.hasResponseHandler)
        XCTAssertTrue(appState.activeSessions.contains(where: { $0.id == "dismiss-session" }))

        appState.dismissSession("dismiss-session")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(self.parseResponse(receivedResponse ?? "")?["response"] as? String, "pass")
        XCTAssertEqual(appState.pendingCount, 0)
        XCTAssertFalse(appState.hasResponseHandler)
        XCTAssertFalse(appState.activeSessions.contains(where: { $0.id == "dismiss-session" }))
    }
}
