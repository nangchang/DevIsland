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
}
