import XCTest
@testable import DevIsland

extension AppStateTests {
    // MARK: - Plugin focus guard (session.focusTerminal)

    func testCanPluginFocusTerminalWhenNoRequestShown() {
        appState.isNotchExpanded = false
        appState.isExpandingFromRequest = false
        XCTAssertTrue(appState.canPluginFocusTerminal)
    }

    func testCannotPluginFocusTerminalWhileShowingRequest() {
        // While a request/notification is on screen, focusing the terminal would let
        // NotchWindowController's observers auto-pass the approval — so it must be refused.
        appState.isNotchExpanded = true
        appState.isExpandingFromRequest = true
        XCTAssertFalse(appState.canPluginFocusTerminal)
    }

    func testCanPluginFocusTerminalWhenExpandedButNotFromRequest() {
        appState.isNotchExpanded = true
        appState.isExpandingFromRequest = false
        XCTAssertTrue(appState.canPluginFocusTerminal)
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

    func testOnlyTimeoutBypassedStatusCountsAsTimeoutBypassed() {
        XCTAssertTrue(SessionStatus.timeoutBypassed(Date()).isTimeoutBypassed)
        XCTAssertFalse(SessionStatus.autoApproved(Date()).isTimeoutBypassed)
        XCTAssertFalse(SessionStatus.policyApproved(Date()).isTimeoutBypassed)
        XCTAssertFalse(SessionStatus.pending.isTimeoutBypassed)
        XCTAssertFalse(SessionStatus.idle.isTimeoutBypassed)
    }

    func testSessionHistoryMetadataPersists() {
        appState.toggleSessionFavorite("session-a")
        appState.setSessionDescription("session-a", description: "Needs follow-up")
        appState.setSessionDescription("session-b", description: "  ")

        let restored = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in false }
        )

        XCTAssertTrue(restored.isSessionFavorite("session-a"))
        XCTAssertFalse(restored.isSessionFavorite("session-b"))
        XCTAssertEqual(restored.sessionDescriptions["session-a"], "Needs follow-up")
        XCTAssertNil(restored.sessionDescriptions["session-b"])
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
        XCTAssertTrue(appState.sessionStore.activeSessions.contains(where: { $0.id == "test-session" }))
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

    func testClaudeAskUserQuestionQueuesStructuredReply() {
        let expectation = XCTestExpectation(description: "Question response")
        let message = """
        {
            "hook_event_name": "PreToolUse",
            "session_id": "claude-question-session",
            "cli_source": "claude",
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [
                    {
                        "question": "Which framework?",
                        "options": [
                            { "label": "SwiftUI" },
                            { "label": "AppKit" }
                        ]
                    }
                ]
            }
        }
        """

        appState.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            let toolInput = json?["tool_input"] as? [String: Any]
            let answers = toolInput?["answers"] as? [String: Any]
            XCTAssertEqual(answers?["Which framework?"] as? String, "AppKit")
            expectation.fulfill()
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(appState.sessionStore.pendingCount, 1)
        XCTAssertNotNil(appState.currentClaudeQuestion)

        guard let question = appState.currentClaudeQuestion?.questions.first,
              let appKit = question.options.last else {
            XCTFail("Expected parsed question options")
            return
        }
        appState.setClaudeQuestionOption(questionId: question.id, optionId: appKit.id)
        appState.submitClaudeQuestion()

        wait(for: [expectation], timeout: 2.0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(appState.sessionStore.pendingCount, 0)
        XCTAssertNil(appState.currentClaudeQuestion)
    }

    func testClaudeAskUserQuestionPassesWhenTerminalFocused() {
        appState = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in true }
        )

        let expectation = XCTestExpectation(description: "Focused terminal receives native Claude question")
        let message = """
        {
            "hook_event_name": "PreToolUse",
            "session_id": "claude-question-focused",
            "cli_source": "claude",
            "terminal_app": "iTerm2",
            "terminal_tty": "/dev/ttys001",
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [
                    { "id": "q1", "prompt": "Proceed?" }
                ]
            }
        }
        """

        appState.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "pass")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(appState.sessionStore.pendingCount, 0)
        XCTAssertFalse(appState.hasResponseHandler)
        XCTAssertNil(appState.currentClaudeQuestion)
        XCTAssertFalse(appState.isNotchExpanded)
    }

    func testQueuedClaudeAskUserQuestionPassesWithoutMissedBadgeWhenTerminalBecomesFocused() {
        let frontmostCheckCount = LockIsolated(0)
        appState = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in
                frontmostCheckCount.withValue { count in
                    count += 1
                    return count >= 2
                }
            }
        )

        let expectation = XCTestExpectation(description: "Queued Claude question passes after terminal focus")
        let message = """
        {
            "hook_event_name": "PreToolUse",
            "session_id": "claude-question-focus-later",
            "cli_source": "claude",
            "terminal_app": "iTerm2",
            "terminal_tty": "/dev/ttys001",
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [
                    { "id": "q1", "prompt": "Proceed?" }
                ]
            }
        }
        """

        appState.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "pass")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(appState.sessionStore.pendingCount, 0)
        XCTAssertFalse(appState.hasResponseHandler)
        XCTAssertNil(appState.currentClaudeQuestion)
        XCTAssertFalse(appState.isNotchExpanded)
        XCTAssertFalse(appState.sessionStore.activeSessions.first { $0.id == "claude-question-focus-later" }?.hasMissedApproval ?? true)
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
        XCTAssertEqual(appState.sessionStore.pendingCount, 1)
        XCTAssertTrue(appState.hasResponseHandler)
        
        // Approve manually
        appState.approve()
        
        // Wait for main thread async blocks in approve()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        
        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(appState.sessionStore.pendingCount, 0)
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
            frontmostCheck: { _ in false },
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
        XCTAssertEqual(state.sessionStore.pendingCount, 0)
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
            frontmostCheck: { _ in false },
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

        XCTAssertEqual(state.sessionStore.pendingCount, 1)
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

    func testClaudeSessionApprovalPersistsToSQLiteCache() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateClaudePolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let controller = try ApprovalProxyController(databaseURL: tempDir.appendingPathComponent("approval-proxy.sqlite3"))
        let state = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in false },
            approvalProxy: controller
        )
        let expectation = XCTestExpectation(description: "Claude manual session approval")
        let message = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-session",
            "cli_source": "claude",
            "tool_name": "Bash",
            "tool_input": {"command": "npm test"}
        }
        """

        state.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        XCTAssertEqual(state.sessionStore.pendingCount, 1)
        state.approve(sessionAlways: true)

        wait(for: [expectation], timeout: 2.0)
        state.flushApprovalPersistenceForTesting()
        let decision = try controller.store.sessionDecision(for: ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "claude-session",
            toolName: "Bash"
        ))
        XCTAssertEqual(decision?.action, .allow)
        XCTAssertEqual(decision?.source, .sessionCache)
    }

    func testClaudePersistentApprovalPersistsToSQLiteRules() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateClaudePolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let controller = try ApprovalProxyController(databaseURL: tempDir.appendingPathComponent("approval-proxy.sqlite3"))
        let state = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in false },
            approvalProxy: controller
        )
        let expectation = XCTestExpectation(description: "Claude manual persistent approval")
        let message = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-session",
            "cli_source": "claude",
            "tool_name": "Bash",
            "cwd": "/tmp/project",
            "tool_input": {"command": "npm test"}
        }
        """

        state.handleMessage(message) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            expectation.fulfill()
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        XCTAssertEqual(state.sessionStore.pendingCount, 1)
        state.approve(globalAlways: true)

        wait(for: [expectation], timeout: 2.0)
        state.flushApprovalPersistenceForTesting()
        let decision = try controller.store.persistentDecision(for: ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "claude-session",
            toolName: "Bash",
            workspaceRoot: "/tmp/project"
        ))
        XCTAssertEqual(decision?.action, .allow)
        XCTAssertEqual(decision?.source, .persistentRule)
    }

    func testReplayHookEventRequeuesStoredApprovalPayload() throws {
        appState = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in true }
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
            self.appState.sessionStore.pendingCount == 1
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(appState.sessionStore.pendingCount, 1)
        XCTAssertEqual(appState.sessionStore.pendingItems.first?.sessionId, "replay-session")
        XCTAssertEqual(appState.sessionStore.pendingItems.first?.toolName, "shell")
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
        XCTAssertEqual(appState.sessionStore.pendingCount, 0)
    }
    
}
