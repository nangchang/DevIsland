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
            frontmostCheck: { _, _, _, _, _, _, _ in false }
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

    private func waitUntil(
        timeout: TimeInterval,
        expectation: XCTestExpectation,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() {
                expectation.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    poll()
                }
            }
        }
        poll()
    }
    
    func testNormalizedHookEventName() {
        XCTAssertEqual(HookEventNormalizer.normalizedName("BeforeTool"), "beforetool")
        XCTAssertEqual(HookEventNormalizer.normalizedName("on_tool_call"), "ontoolcall")
        XCTAssertEqual(HookEventNormalizer.normalizedName("Pre-Tool-Use"), "pretooluse")
        XCTAssertEqual(HookEventNormalizer.normalizedName("SESSION_START"), "sessionstart")
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

    func testClaudeUserPromptSubmitPolicyBlocksSecretPrompt() {
        let expectation = XCTestExpectation(description: "Prompt policy response")
        let message = """
        {
            "hook_event_name": "UserPromptSubmit",
            "session_id": "test-session-prompt",
            "cli_source": "claude",
            "prompt": "api_key=sk-test"
        }
        """

        appState.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "denied")
            XCTAssertNotNil(json?["reason"] as? String)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
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

    func testCodexSessionCacheAutoApprovesPermissionRequest() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateCodexPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let controller = try ApprovalProxyController(databaseURL: tempDir.appendingPathComponent("approval-proxy.sqlite3"))
        try controller.store.upsertSessionApproval(
            provider: .codex,
            sessionId: "codex-session",
            toolName: "shell",
            action: .allow,
            expiresAt: nil
        )
        let state = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _, _, _, _, _, _, _ in false },
            approvalProxy: controller
        )
        let expectation = XCTestExpectation(description: "Codex policy auto-approval")
        let message = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "codex-session",
            "cli_source": "codex",
            "tool_name": "shell",
            "tool_input": {"command": "npm test"}
        }
        """

        state.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(state.pendingCount, 0)
    }

    func testCodexSessionApprovalPersistsToSQLiteCache() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateCodexPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let controller = try ApprovalProxyController(databaseURL: tempDir.appendingPathComponent("approval-proxy.sqlite3"))
        let state = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _, _, _, _, _, _, _ in false },
            approvalProxy: controller
        )
        let expectation = XCTestExpectation(description: "Codex manual session approval")
        let message = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "codex-session",
            "cli_source": "codex",
            "tool_name": "shell",
            "tool_input": {"command": "npm test"}
        }
        """

        state.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        XCTAssertEqual(state.pendingCount, 1)
        state.approve(sessionAlways: true)

        wait(for: [expectation], timeout: 2.0)
        state.flushApprovalPersistenceForTesting()
        let decision = try controller.store.sessionDecision(for: ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "codex-session",
            toolName: "shell"
        ))
        XCTAssertEqual(decision?.action, .allow)
        XCTAssertEqual(decision?.source, .sessionCache)
    }

    func testReplayHookEventRequeuesStoredApprovalPayload() throws {
        appState = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _, _, _, _, _, _, _ in true }
        )
        let entry = ReplayLogEntry(
            id: 42,
            requestId: "request-42",
            provider: .codex,
            sessionId: "replay-session",
            eventName: "PermissionRequest",
            toolName: "shell",
            payloadJSON: """
            {
              "hook_event_name": "PermissionRequest",
              "session_id": "replay-session",
              "cli_source": "codex",
              "tool_name": "shell",
              "tool_input": {"command": "npm test"}
            }
            """,
            receivedAt: Date(timeIntervalSince1970: 1_000),
            decisionAction: nil,
            decisionSource: nil,
            decisionReason: nil,
            decidedAt: nil
        )
        try appState.replayHookEvent(entry)
        let expectation = expectation(description: "replay enqueued")
        waitUntil(timeout: 2.0, expectation: expectation) {
            self.appState.pendingCount == 1
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(appState.pendingCount, 1)
        XCTAssertEqual(appState.pendingItems.first?.sessionId, "replay-session")
        XCTAssertEqual(appState.pendingItems.first?.toolName, "shell")
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
    
    // MARK: - Gemini Normal Mode (emulateGeminiInteractiveMode = false)

    func testGeminiNormalModePassesAllToolsThrough() {
        // Normal mode: Gemini runs with --auto-approve/--yolo, DevIsland passes all BeforeTool through.
        let expectation = XCTestExpectation(description: "Risky tool approved immediately in normal mode")
        let message = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "gemini-normal",
            "tool_name": "write_to_file"
        }
        """
        appState.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(appState.pendingCount, 0)
        XCTAssertFalse(appState.hasResponseHandler)
    }

    func testGeminiNormalModeSafeToolPassesThrough() {
        let expectation = XCTestExpectation(description: "Safe tool approved in normal mode")
        let message = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "gemini-normal-safe",
            "tool_name": "view_file"
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

    func testGeminiNormalModeExitPlanModeDoesNotActivateAutoEdit() {
        // In normal mode, exit_plan_mode passes through but must NOT activate auto-edit
        // because no approval UI was shown to the user.
        let expectation = XCTestExpectation(description: "exit_plan_mode approved in normal mode")
        let sessionId = "gemini-normal-plan"
        let message = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "\(sessionId)",
            "tool_name": "exit_plan_mode"
        }
        """
        appState.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        // Session may or may not appear in activeSessions, but must not be in auto-edit.
        let session = appState.activeSessions.first { $0.id == sessionId }
        XCTAssertFalse(session?.isAutoEditActive ?? false, "Auto-Edit must not activate via pass-through in normal mode")
    }

    // MARK: - Gemini Emulation Mode (emulateGeminiInteractiveMode = true)

    func testGeminiEmulationModeRiskyToolRequiresApproval() {
        appState.emulateGeminiInteractiveMode = true
        let sessionId = "gemini-emulate-risky"
        let message = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "\(sessionId)",
            "tool_name": "write_to_file"
        }
        """
        appState.handleMessage(message) { _ in }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertEqual(appState.pendingCount, 1, "Risky tool should enter approval queue in emulation mode")
        XCTAssertEqual(appState.currentSessionId, sessionId)
        XCTAssertTrue(appState.hasResponseHandler)
    }

    func testGeminiEmulationModeSafeToolRequiresApprovalByDefault() {
        // Safe tools in emulation mode still go to pending unless autoApproveSafeTools is enabled.
        // The emulation block only skips the isAutoApprovedGlobal reset for safe tools;
        // it does not set autoApproval itself — that requires the separate autoApproveSafeTools setting.
        appState.emulateGeminiInteractiveMode = true
        let message = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "gemini-emulate-safe-default",
            "tool_name": "view_file"
        }
        """
        appState.handleMessage(message) { _ in }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(appState.pendingCount, 1, "Safe tool should still require approval without autoApproveSafeTools")
        XCTAssertTrue(appState.hasResponseHandler)
    }

    func testGeminiEmulationModeSafeToolAutoApprovedWhenSettingEnabled() {
        appState.emulateGeminiInteractiveMode = true
        appState.autoApproveSafeTools = true
        let expectation = XCTestExpectation(description: "Safe tool auto-approved with autoApproveSafeTools enabled")
        let message = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "gemini-emulate-safe-setting",
            "tool_name": "view_file"
        }
        """
        appState.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(appState.pendingCount, 0)
        XCTAssertFalse(appState.hasResponseHandler)
    }

    func testGeminiEmulationModeExplicitGlobalApproveBypassesBlock() {
        appState.emulateGeminiInteractiveMode = true
        appState.globalAutoApproveTypes.insert("write_to_file")

        let expectation = XCTestExpectation(description: "Explicitly approved tool passes through even in emulation mode")
        let message = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "gemini-emulate-global",
            "tool_name": "write_to_file"
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

    func testGeminiEmulationModeExplicitSessionApproveBypassesBlock() {
        appState.emulateGeminiInteractiveMode = true
        let sessionId = "gemini-emulate-session"
        appState.sessionAutoApproveTypes[sessionId] = ["replace_file_content"]

        let expectation = XCTestExpectation(description: "Session-approved tool passes through in emulation mode")
        let message = """
        {
            "hook_event_name": "BeforeTool",
            "session_id": "\(sessionId)",
            "tool_name": "replace_file_content"
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

    func testGeminiEmulationModeAutoEditCycle() {
        // In emulation mode the emulation block forcibly resets isAutoApprovedGlobal AND
        // isAutoEditActive for any risky/medium tool that is not explicitly approved.
        // Risk levels: write_to_file=high, replace_file_content=high (contains "replace"),
        //              exit_plan_mode=medium, enter_plan_mode=medium (no matching heuristic keyword).
        // Consequence: auto-edit state is set but has no effect on risky tools in emulation mode —
        // every risky tool always requires manual approval.
        appState.emulateGeminiInteractiveMode = true
        let sessionId = "gemini-emulate-autoedit"

        // Step 1: risky tool → pending queue
        appState.handleMessage("""
        {"hook_event_name":"BeforeTool","session_id":"\(sessionId)","tool_name":"write_to_file"}
        """) { _ in }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(appState.pendingCount, 1, "Risky tool must be pending in emulation mode")
        appState.approve()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        // Step 2: exit_plan_mode → also pending (risk=medium, emulation blocks isAutoApprovedGlobal)
        appState.handleMessage("""
        {"hook_event_name":"BeforeTool","session_id":"\(sessionId)","tool_name":"exit_plan_mode"}
        """) { _ in }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(appState.pendingCount, 1, "exit_plan_mode must be pending in emulation mode (risk=medium)")

        // User manually approves exit_plan_mode → isAutoEditActive becomes true
        appState.approve()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        let session = appState.activeSessions.first { $0.id == sessionId }
        XCTAssertNotNil(session, "Session should exist after exit_plan_mode approval")
        XCTAssertTrue(session?.isAutoEditActive ?? false, "isAutoEditActive set after manual approval of exit_plan_mode")

        // Step 3: subsequent risky tool → still pending despite auto-edit being active,
        // because emulation resets isAutoEditActive=false for risky tools.
        appState.handleMessage("""
        {"hook_event_name":"BeforeTool","session_id":"\(sessionId)","tool_name":"replace_file_content"}
        """) { _ in }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(appState.pendingCount, 1, "Risky tool must still be pending in emulation mode even with auto-edit active")
        appState.approve()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        // Step 4: enter_plan_mode → pending (risk=medium), manual approval resets isAutoEditActive
        appState.handleMessage("""
        {"hook_event_name":"BeforeTool","session_id":"\(sessionId)","tool_name":"enter_plan_mode"}
        """) { _ in }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(appState.pendingCount, 1, "enter_plan_mode must be pending in emulation mode")
        appState.approve()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

        let resetSession = appState.activeSessions.first { $0.id == sessionId }
        XCTAssertFalse(resetSession?.isAutoEditActive ?? true, "Auto-Edit should be reset after enter_plan_mode approval")
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
