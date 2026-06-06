import XCTest
@testable import DevIsland

final class PluginEventFactoryTests: XCTestCase {
    private let factory = PluginEventFactory()

    func testSessionSnapshotUsesSanitizedSubsetAndOptionalLastFields() {
        let session = makeSession(
            agentKind: .claudeCode,
            terminalTTY: "/dev/ttys001",
            lastToolName: "",
            lastEventName: "",
            workspaceRoot: "/Users/alice/project"
        )

        let snapshot = factory.snapshot(from: session)

        XCTAssertEqual(snapshot.id, "session-1")
        XCTAssertEqual(snapshot.agentKind, "claude")
        XCTAssertNil(snapshot.lastToolName)
        XCTAssertNil(snapshot.lastEventName)
        XCTAssertEqual(snapshot.workspaceRoot, "/Users/alice/project")
    }

    func testMakeSessionEventUsesRequestedKindAndOnlySessionPayload() {
        let session = makeSession(lastToolName: "Edit", lastEventName: "PreToolUse")

        let event = factory.makeSessionEvent(kind: .sessionStarted, from: session)

        XCTAssertEqual(event.kind, .sessionStarted)
        XCTAssertEqual(event.session?.id, "session-1")
        XCTAssertNil(event.hook)
        XCTAssertNil(event.action)
        XCTAssertNil(event.approval)
    }

    func testHookEventContainsSummaryWithoutRawPayloadFields() throws {
        let hook = makeHook(
            parsedJSON: [
                "raw_secret": "RAW_SECRET_SHOULD_NOT_LEAK",
                "terminal_tty": "/dev/ttys999",
                "tool_input": ["command": "cat /tmp/raw"]
            ],
            displayToolName: "Bash",
            displayMsg: "Run token=ghp_abcdefghijklmnopqrstuvwxyz123456 /Users/alice/project"
        )

        let event = factory.makeHookReceivedEvent(from: hook)
        let encoded = try String(decoding: JSONEncoder().encode(event), as: UTF8.self)

        XCTAssertEqual(event.hook?.provider, "codex")
        XCTAssertEqual(event.hook?.eventType, "pretooluse")
        XCTAssertFalse(encoded.contains("RAW_SECRET_SHOULD_NOT_LEAK"))
        XCTAssertFalse(encoded.contains("/dev/ttys999"))
        XCTAssertFalse(encoded.contains("abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertFalse(encoded.contains("/Users/alice"))
        XCTAssertTrue(event.hook?.commandSummary?.contains("token=[redacted]") == true)
        XCTAssertTrue(event.hook?.commandSummary?.contains("~/project") == true)
    }

    func testCommandSummaryRedactsHeredocBody() {
        let hook = makeHook(
            displayToolName: "Bash",
            displayMsg: """
            cat <<EOF
            secret body
            EOF
            """
        )

        let event = factory.makeHookReceivedEvent(from: hook)

        XCTAssertFalse(event.hook?.commandSummary?.contains("secret body") == true)
        XCTAssertTrue(event.hook?.commandSummary?.contains("[redacted heredoc]") == true)
    }

    func testCommandSummaryRedactsDashHeredocWithTrailingShellOperators() {
        let hook = makeHook(
            displayToolName: "Bash",
            displayMsg: """
            cat <<-EOF > file.txt && echo done
            secret body
            EOF
            """
        )

        let event = factory.makeHookReceivedEvent(from: hook)

        XCTAssertFalse(event.hook?.commandSummary?.contains("secret body") == true)
        XCTAssertTrue(event.hook?.commandSummary?.contains("[redacted heredoc]") == true)
        XCTAssertTrue(event.hook?.commandSummary?.contains("EOF") == true)
    }

    func testCommandSummaryKeepsEmptyHeredocClosingMarker() {
        let hook = makeHook(
            displayToolName: "Bash",
            displayMsg: """
            cat <<EOF
            EOF
            """
        )

        let event = factory.makeHookReceivedEvent(from: hook)

        XCTAssertTrue(event.hook?.commandSummary?.contains("EOF") == true)
    }

    func testCommandSummaryDoesNotRedactOrdinaryLongHexValues() {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let hook = makeHook(
            displayToolName: "Git",
            displayMsg: "show \(sha)"
        )

        let event = factory.makeHookReceivedEvent(from: hook)

        XCTAssertTrue(event.hook?.commandSummary?.contains(sha) == true)
    }

    func testRedactedEventRemovesTerminalMetadataWithoutPermission() {
        let hook = makeHook(
            terminalApp: "iTerm",
            workspaceRoot: "/Users/alice/project"
        )
        let event = factory.makeHookReceivedEvent(from: hook)

        let redacted = factory.redactedEvent(from: event, permissions: [.readHookSummaries])

        XCTAssertEqual(redacted.hook?.provider, "codex")
        XCTAssertNil(redacted.hook?.cwd)
        XCTAssertNil(redacted.hook?.terminalApp)
    }

    func testRedactedEventPreservesTerminalMetadataWithPermission() {
        let hook = makeHook(
            terminalApp: "iTerm",
            workspaceRoot: "/Users/alice/project"
        )
        let event = factory.makeHookReceivedEvent(from: hook)

        let redacted = factory.redactedEvent(
            from: event,
            permissions: [.readHookSummaries, .readTerminalMetadata]
        )

        XCTAssertEqual(redacted.hook?.cwd, "/Users/alice/project")
        XCTAssertEqual(redacted.hook?.terminalApp, "iTerm")
    }

    func testRedactedHookEventRemovesSessionSnapshotWithoutPermission() {
        let session = makeSession(lastToolName: "Edit", lastEventName: "PreToolUse")
        let event = factory.makeHookReceivedEvent(from: makeHook(), session: session)

        let redacted = factory.redactedEvent(from: event, permissions: [.readHookSummaries])

        XCTAssertNotNil(event.session)
        XCTAssertNil(redacted.session)
    }

    func testRedactedHookEventRemovesHookSummaryWithoutPermission() {
        let event = factory.makeHookReceivedEvent(from: makeHook())

        let redacted = factory.redactedEvent(from: event, permissions: [])

        XCTAssertNotNil(event.hook)
        XCTAssertNil(redacted.hook)
    }

    private func makeHook(
        parsedJSON: [String: Any] = [:],
        displayToolName: String = "Edit",
        displayMsg: String = "Edit file",
        terminalApp: String = "",
        workspaceRoot: String? = nil
    ) -> ParsedHookEvent {
        ParsedHookEvent(
            requestId: nil,
            parsedJSON: parsedJSON,
            sessionId: "session-1",
            event: "PreToolUse",
            toolName: "edit",
            displayToolName: displayToolName,
            displayMsg: displayMsg,
            agentKind: .codex,
            terminalTitle: "Terminal",
            terminalApp: terminalApp,
            terminalTTY: "",
            terminalWindowId: "",
            terminalTabIndex: "",
            terminalTmuxPane: "",
            terminalTmuxSocket: "",
            terminalTmuxClient: "",
            workspaceRoot: workspaceRoot,
            toolInput: nil,
            isSubAgentSession: false,
            parentSessionId: nil,
            isReplayPayload: false,
            isPlanAction: false,
            sessionStartSource: "",
            notificationType: ""
        )
    }

    private func makeSession(
        agentKind: BuddyKind = .codex,
        terminalTTY: String = "",
        lastToolName: String = "Edit",
        lastEventName: String = "PreToolUse",
        workspaceRoot: String? = nil
    ) -> ActiveSession {
        ActiveSession(
            id: "session-1",
            terminalTitle: "Terminal",
            agentKind: agentKind,
            terminalApp: "iTerm",
            terminalTTY: terminalTTY,
            terminalWindowId: "1",
            terminalTabIndex: "2",
            terminalTmuxPane: "%1",
            terminalTmuxSocket: "/tmp/tmux.sock",
            terminalTmuxClient: "client",
            lastToolName: lastToolName,
            lastEventName: lastEventName,
            lastMessage: "message",
            startTime: Date(timeIntervalSince1970: 10),
            lastActiveAt: Date(timeIntervalSince1970: 20),
            isPending: false,
            isLifecycleTracked: false,
            isSubAgentSession: false,
            isAutoEditActive: false,
            isUnread: false,
            hasMissedApproval: false,
            status: .idle,
            parentSessionId: nil,
            workspaceRoot: workspaceRoot
        )
    }
}
