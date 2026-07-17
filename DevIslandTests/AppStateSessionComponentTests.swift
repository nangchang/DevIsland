import XCTest
@testable import DevIsland

extension AppStateTests {
    // MARK: - PTYSessionBuffer

    func testPTYSlidingWindowMatchesPatternAcrossChunks() throws {
        let patterns = [PTYAutoInjectPattern(pattern: "password:", response: "secret\n")]
        let data = try JSONEncoder().encode(patterns)
        mockDefaults.set(true, forKey: SettingsStore.DefaultsKey.ptyEnabled)
        mockDefaults.set(data, forKey: SettingsStore.DefaultsKey.ptyAutoInjectPatterns)

        // First chunk: partial pattern — must NOT fire injection
        var firstResponse: String?
        appState.handleMessage(
            """
            {"hook_event_name":"PTYOutput","cli_source":"claude","session_id":"pty-chunks","content":"pass"}
            """
        ) { firstResponse = $0 }
        XCTAssertNil(parseResponse(firstResponse ?? "")?["injection"], "Partial pattern must not fire injection")

        // Second chunk: completes the pattern across chunk boundary
        var secondResponse: String?
        appState.handleMessage(
            """
            {"hook_event_name":"PTYOutput","cli_source":"claude","session_id":"pty-chunks","content":"word:"}
            """
        ) { secondResponse = $0 }
        let json = parseResponse(secondResponse ?? "")
        XCTAssertEqual(json?["injection"] as? String, "secret\n", "Sliding window must match pattern split across two chunks")
    }

    func testPTYMatchClearsBufferSoAccumulatedPatternDoesNotRefire() throws {
        // After a pattern fires, the buffer is reset to "".
        // Without this reset, the matched content would persist in the window and cause re-firing
        // when the next chunk arrives (combined = "password:" + "more text" still contains "password:").
        let patterns = [PTYAutoInjectPattern(pattern: "password:", response: "secret\n")]
        let data = try JSONEncoder().encode(patterns)
        mockDefaults.set(true, forKey: SettingsStore.DefaultsKey.ptyEnabled)
        mockDefaults.set(data, forKey: SettingsStore.DefaultsKey.ptyAutoInjectPatterns)

        // First delivery — fires injection, buffer cleared to ""
        var firstResponse: String?
        appState.handleMessage(
            """
            {"hook_event_name":"PTYOutput","cli_source":"claude","session_id":"pty-refire","content":"password:"}
            """
        ) { firstResponse = $0 }
        XCTAssertEqual(parseResponse(firstResponse ?? "")?["injection"] as? String, "secret\n", "First delivery must fire injection")

        // Next chunk has no pattern by itself; combined = "" + "more output" = "more output"
        // Without the buffer clear it would be "password:more output" which still matches.
        var secondResponse: String?
        appState.handleMessage(
            """
            {"hook_event_name":"PTYOutput","cli_source":"claude","session_id":"pty-refire","content":"more output"}
            """
        ) { secondResponse = $0 }
        XCTAssertNil(parseResponse(secondResponse ?? "")?["injection"], "Subsequent chunk without pattern must not refire after buffer was cleared")
    }

    func testStopEventClearsPTYOutputBuffer() throws {
        let patterns = [PTYAutoInjectPattern(pattern: "password:", response: "secret\n")]
        let data = try JSONEncoder().encode(patterns)
        mockDefaults.set(true, forKey: SettingsStore.DefaultsKey.ptyEnabled)
        mockDefaults.set(data, forKey: SettingsStore.DefaultsKey.ptyAutoInjectPatterns)

        // Accumulate partial pattern in buffer
        appState.handleMessage(
            """
            {"hook_event_name":"PTYOutput","cli_source":"claude","session_id":"pty-stop","content":"pass"}
            """
        ) { _ in }

        // Stop event should clear PTY buffer for that session
        let stopExpectation = XCTestExpectation(description: "Stop event responded")
        appState.handleMessage(
            """
            {"hook_event_name":"sessionend","session_id":"pty-stop"}
            """
        ) { response in
            let json = self.parseResponse(response)
            XCTAssertEqual(json?["response"] as? String, "approved")
            stopExpectation.fulfill()
        }
        wait(for: [stopExpectation], timeout: 1.0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        // Completing the pattern on a new session (same id, fresh start) must NOT fire injection
        var response: String?
        appState.handleMessage(
            """
            {"hook_event_name":"PTYOutput","cli_source":"claude","session_id":"pty-stop","content":"word:"}
            """
        ) { response = $0 }
        XCTAssertNil(parseResponse(response ?? "")?["injection"], "Stop event must clear PTY buffer; stale buffer must not trigger injection")
    }

    // MARK: - SessionStore

    func testShowSessionDetailSynchronizesSelectionAndExpandsWithoutFocusing() {
        let frontmostChecks = LockIsolated(0)
        appState = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in
                frontmostChecks.withValue { $0 += 1 }
                return false
            }
        )
        appState.sessionStore.updateActiveSession(
            sessionId: "fleet-detail",
            terminalTitle: "Fleet Terminal",
            agentKind: .codex,
            terminal: TerminalContext(),
            toolName: "Read",
            eventName: "PostToolUse",
            message: "Detail message",
            isPending: false,
            workspaceRoot: "/tmp/fleet-detail"
        )
        appState.isNotchExpanded = false
        appState.isExpandingFromRequest = false

        appState.showSessionDetail("fleet-detail")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(appState.sessionStore.selectedSessionId, "fleet-detail")
        XCTAssertEqual(appState.currentSessionId, "fleet-detail")
        XCTAssertEqual(appState.currentToolName, "Read")
        XCTAssertEqual(appState.currentEventName, "PostToolUse")
        XCTAssertEqual(appState.currentMessage, "Detail message")
        XCTAssertTrue(appState.isExpandingFromRequest)
        XCTAssertTrue(appState.isNotchExpanded)
        XCTAssertFalse(appState.hasResponseHandler)
        XCTAssertEqual(frontmostChecks.value, 0)
    }

    func testShowSessionDetailDoesNotReplaceOrRespondToPendingApproval() {
        var responseCount = 0
        appState.sessionStore.selectedSessionId = "approval-session"
        appState.displayState.sessionId = "approval-session"
        appState.displayState.responseHandler = { _ in responseCount += 1 }
        appState.isNotchExpanded = true

        appState.showSessionDetail("fleet-detail")

        XCTAssertEqual(appState.sessionStore.selectedSessionId, "approval-session")
        XCTAssertEqual(appState.currentSessionId, "approval-session")
        XCTAssertTrue(appState.hasResponseHandler)
        XCTAssertTrue(appState.isNotchExpanded)
        XCTAssertEqual(responseCount, 0)
    }

    func testSessionMetadataUpdatedNotDuplicated() {
        let msg1 = """
        {"hook_event_name":"sessionstart","cli_source":"claude","session_id":"meta-session","terminal_title":"Terminal 1"}
        """
        let msg2 = """
        {"hook_event_name":"PreToolUse","cli_source":"claude","session_id":"meta-session","tool_name":"Bash","tool_input":{"command":"ls"}}
        """

        let exp1 = XCTestExpectation(description: "First event responded")
        appState.handleMessage(msg1) { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)

        let exp2 = XCTestExpectation(description: "Second event responded")
        appState.handleMessage(msg2) { _ in exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        let sessions = appState.sessionStore.activeSessions.filter { $0.id == "meta-session" }
        XCTAssertEqual(sessions.count, 1, "Same session_id must not create duplicate session rows")
        XCTAssertEqual(sessions.first?.lastToolName, "Bash", "Second event must update lastToolName")
    }

    func testSelectedSessionIdAutoSwitchesWhenActiveSessionRemoved() {
        // Put two sessions in the active list via notifications
        let exp1 = XCTestExpectation(description: "session-a started")
        appState.handleMessage(
            """
            {"hook_event_name":"sessionstart","cli_source":"claude","session_id":"session-a"}
            """
        ) { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)

        let exp2 = XCTestExpectation(description: "session-b started")
        appState.handleMessage(
            """
            {"hook_event_name":"sessionstart","cli_source":"claude","session_id":"session-b"}
            """
        ) { _ in exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(appState.sessionStore.activeSessions.count, 2)
        appState.sessionStore.selectedSessionId = "session-a"

        // Stop session-a
        let stopExp = XCTestExpectation(description: "session-a stopped")
        appState.handleMessage(
            """
            {"hook_event_name":"sessionend","session_id":"session-a"}
            """
        ) { _ in stopExp.fulfill() }
        wait(for: [stopExp], timeout: 1.0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertFalse(appState.sessionStore.activeSessions.contains(where: { $0.id == "session-a" }), "Stopped session must be removed")
        XCTAssertNotEqual(appState.sessionStore.selectedSessionId, "session-a", "selectedSessionId must switch away from stopped session")
        XCTAssertEqual(appState.sessionStore.selectedSessionId, "session-b", "selectedSessionId must fall back to remaining session")
    }

    func testCodexSessionStartSupersedesPreviousCodexSessionInSameTTY() {
        let exp1 = XCTestExpectation(description: "old codex session started")
        appState.handleMessage(
            """
            {"hook_event_name":"SessionStart","source":"startup","cli_source":"codex","session_id":"codex-old","terminal_tty":"/dev/ttys001"}
            """
        ) { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)

        let exp2 = XCTestExpectation(description: "new codex session started")
        appState.handleMessage(
            """
            {"hook_event_name":"SessionStart","source":"clear","cli_source":"codex","session_id":"codex-new","terminal_tty":"/dev/ttys001"}
            """
        ) { _ in exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertFalse(appState.sessionStore.activeSessions.contains(where: { $0.id == "codex-old" }))
        XCTAssertTrue(appState.sessionStore.activeSessions.contains(where: { $0.id == "codex-new" }))
    }

    func testCodexSessionStartDoesNotSupersedeOtherProvidersOrDifferentTTY() {
        let claudeExp = XCTestExpectation(description: "claude session started")
        appState.handleMessage(
            """
            {"hook_event_name":"SessionStart","source":"startup","cli_source":"claude","session_id":"claude-parent","terminal_tty":"/dev/ttys001"}
            """
        ) { _ in claudeExp.fulfill() }
        wait(for: [claudeExp], timeout: 1.0)

        let codexExp = XCTestExpectation(description: "codex session on another tty started")
        appState.handleMessage(
            """
            {"hook_event_name":"SessionStart","source":"startup","cli_source":"codex","session_id":"codex-other","terminal_tty":"/dev/ttys002"}
            """
        ) { _ in codexExp.fulfill() }
        wait(for: [codexExp], timeout: 1.0)

        let newExp = XCTestExpectation(description: "nested codex session started")
        appState.handleMessage(
            """
            {"hook_event_name":"SessionStart","source":"startup","cli_source":"codex","session_id":"codex-nested","terminal_tty":"/dev/ttys001"}
            """
        ) { _ in newExp.fulfill() }
        wait(for: [newExp], timeout: 1.0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertTrue(appState.sessionStore.activeSessions.contains(where: { $0.id == "claude-parent" }))
        XCTAssertTrue(appState.sessionStore.activeSessions.contains(where: { $0.id == "codex-other" }))
        XCTAssertTrue(appState.sessionStore.activeSessions.contains(where: { $0.id == "codex-nested" }))
    }

    func testCodexSessionStartDoesNotSupersedeSubAgentSession() {
        appState.sessionStore.updateActiveSession(
            sessionId: "codex-subagent",
            terminalTitle: "Terminal",
            agentKind: .codex,
            terminal: TerminalContext(tty: "/dev/ttys001"),
            toolName: "",
            eventName: "SessionStart",
            message: "Session Started",
            isPending: false,
            isLifecycleTracked: true,
            isSubAgentSession: true
        )

        let exp = XCTestExpectation(description: "main codex session started")
        appState.handleMessage(
            """
            {"hook_event_name":"SessionStart","source":"clear","cli_source":"codex","session_id":"codex-main","terminal_tty":"/dev/ttys001"}
            """
        ) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertTrue(appState.sessionStore.activeSessions.contains(where: { $0.id == "codex-subagent" }))
        XCTAssertTrue(appState.sessionStore.activeSessions.contains(where: { $0.id == "codex-main" }))
    }

    func testCodexSessionStartDoesNotSupersedeDifferentTmuxPaneWithSameTTY() {
        let exp1 = XCTestExpectation(description: "codex tmux pane one started")
        appState.handleMessage(
            """
            {
                "hook_event_name": "SessionStart",
                "source": "startup",
                "cli_source": "codex",
                "session_id": "codex-pane-one",
                "terminal_tty": "/dev/ttys001",
                "terminal_tmux_socket": "/tmp/tmux-501/default",
                "terminal_tmux_client": "/dev/ttys001",
                "terminal_tmux_pane": "%1"
            }
            """
        ) { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)

        let exp2 = XCTestExpectation(description: "codex tmux pane two started")
        appState.handleMessage(
            """
            {
                "hook_event_name": "SessionStart",
                "source": "startup",
                "cli_source": "codex",
                "session_id": "codex-pane-two",
                "terminal_tty": "/dev/ttys001",
                "terminal_tmux_socket": "/tmp/tmux-501/default",
                "terminal_tmux_client": "/dev/ttys001",
                "terminal_tmux_pane": "%2"
            }
            """
        ) { _ in exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertTrue(appState.sessionStore.activeSessions.contains(where: { $0.id == "codex-pane-one" }))
        XCTAssertTrue(appState.sessionStore.activeSessions.contains(where: { $0.id == "codex-pane-two" }))
    }

    // MARK: - ReplayRecorder

    func testApprovalEventIsRecordedInReplayLog() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let controller = try ApprovalProxyController(databaseURL: tempDir.appendingPathComponent("approval-proxy.sqlite3"))
        let state = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in false },
            approvalProxy: controller
        )

        let expectation = XCTestExpectation(description: "Approval event processed")
        let message = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "replay-record-session",
            "cli_source": "codex",
            "tool_name": "shell",
            "tool_input": {"command": "npm test"}
        }
        """
        state.handleMessage(message) { _ in expectation.fulfill() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        state.approve()
        wait(for: [expectation], timeout: 2.0)
        state.flushApprovalPersistenceForTesting()

        let log = try controller.replayLog(limit: 10)
        let entry = log.first { $0.sessionId == "replay-record-session" }
        XCTAssertNotNil(entry, "Approval event must be recorded in the replay log")
        XCTAssertEqual(entry?.toolName, "shell")
        XCTAssertEqual(entry?.eventName, "PermissionRequest")
        XCTAssertEqual(entry?.provider, .codex)
    }

    func testApprovalDecisionLinkedToHookEventInReplayLog() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayDecisionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let controller = try ApprovalProxyController(databaseURL: tempDir.appendingPathComponent("approval-proxy.sqlite3"))
        let state = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in false },
            approvalProxy: controller
        )

        let expectation = XCTestExpectation(description: "Approval processed")
        let message = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "replay-decision-session",
            "cli_source": "claude",
            "tool_name": "Bash",
            "tool_input": {"command": "git status"}
        }
        """
        state.handleMessage(message) { _ in expectation.fulfill() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        state.approve()
        wait(for: [expectation], timeout: 2.0)
        state.flushApprovalPersistenceForTesting()

        let log = try controller.replayLog(limit: 10)
        let entry = log.first { $0.sessionId == "replay-decision-session" }
        XCTAssertNotNil(entry, "Hook event must be in replay log")
        XCTAssertEqual(entry?.decisionAction, .allow, "Approved decision must be linked to hook event as 'allow'")
        XCTAssertNotNil(entry?.decidedAt, "Decision timestamp must be recorded")
    }

}
