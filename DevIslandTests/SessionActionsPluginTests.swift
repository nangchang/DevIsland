import XCTest
@testable import DevIsland

@MainActor
final class SessionActionsPluginTests: XCTestCase {

    // MARK: - Plugin contribution

    func testContributesHostExecutedDismissActionForSession() throws {
        let plugin = SessionActionsPlugin()
        // No tracking: the plugin contributes whenever the host evaluates it against a
        // session (the host decides which sessions are evaluated and evicts on ended).
        let contribution = try XCTUnwrap(try plugin.makeUIContribution(
            for: .sessionContextMenu,
            context: uiContext(session: makeSnapshot(id: "s1"))
        ))
        XCTAssertEqual(contribution.slot, .sessionContextMenu)
        XCTAssertEqual(contribution.targetSessionID, "s1", "context action must be keyed to its session")

        let component = try XCTUnwrap(contribution.components.first)
        XCTAssertEqual(component.type, .button)
        let action = try XCTUnwrap(component.action)
        XCTAssertEqual(action.capability, "session.dismiss")
        XCTAssertEqual(action.routing, .hostExecuted)
        XCTAssertEqual(action.payload["sessionID"], "s1", "host needs the target session id in the payload")
    }

    func testContributesHostExecutedCopyResumeActionForSession() throws {
        let plugin = SessionActionsPlugin()
        let contribution = try XCTUnwrap(try plugin.makeUIContribution(
            for: .sessionContextMenu,
            context: uiContext(session: makeSnapshot(id: "s1"))
        ))
        let copyResume = try XCTUnwrap(contribution.components.first { $0.id == "copy-resume" })
        XCTAssertEqual(copyResume.type, .button)
        let action = try XCTUnwrap(copyResume.action)
        XCTAssertEqual(action.capability, "session.copyResumeCommand")
        XCTAssertEqual(action.routing, .hostExecuted)
        XCTAssertEqual(action.payload["sessionID"], "s1")
    }

    func testContributesHostExecutedFocusTerminalActionForSession() throws {
        let plugin = SessionActionsPlugin()
        let contribution = try XCTUnwrap(try plugin.makeUIContribution(
            for: .sessionContextMenu,
            context: uiContext(session: makeSnapshot(id: "s1"))
        ))
        let focus = try XCTUnwrap(contribution.components.first { $0.id == "focus-terminal" })
        XCTAssertEqual(focus.type, .button)
        let action = try XCTUnwrap(focus.action)
        XCTAssertEqual(action.capability, "session.focusTerminal")
        XCTAssertEqual(action.routing, .hostExecuted)
        XCTAssertEqual(action.payload["sessionID"], "s1")
    }

    func testContributesOpenWorkspaceWhenSessionHasWorkspaceRoot() throws {
        let plugin = SessionActionsPlugin()
        let contribution = try XCTUnwrap(try plugin.makeUIContribution(
            for: .sessionContextMenu,
            context: uiContext(session: makeSnapshot(id: "s1", workspaceRoot: "/tmp/proj"))
        ))
        let open = try XCTUnwrap(contribution.components.first { $0.id == "open-workspace" })
        XCTAssertEqual(open.type, .button)
        let action = try XCTUnwrap(open.action)
        XCTAssertEqual(action.capability, "session.openWorkspace")
        XCTAssertEqual(action.routing, .hostExecuted)
        XCTAssertEqual(action.payload["sessionID"], "s1")
    }

    func testNoOpenWorkspaceWhenSessionHasNoWorkspaceRoot() throws {
        let plugin = SessionActionsPlugin()
        let contribution = try XCTUnwrap(try plugin.makeUIContribution(
            for: .sessionContextMenu,
            context: uiContext(session: makeSnapshot(id: "s1", workspaceRoot: nil))
        ))
        XCTAssertNil(contribution.components.first { $0.id == "open-workspace" },
                     "open-workspace must not be offered for a session with no workspace root")
    }

    func testNoContributionForOtherSlots() throws {
        let plugin = SessionActionsPlugin()
        XCTAssertNil(try plugin.makeUIContribution(
            for: .notchSessionRow,
            context: PluginUIContext(slot: .notchSessionRow, timestamp: Date(), session: makeSnapshot(id: "s1"))
        ))
    }

    func testReturnsNoEffectsAndNeverTicks() throws {
        let plugin = SessionActionsPlugin()
        let effects = try plugin.onEvent(sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1")), context: context())
        XCTAssertTrue(effects.isEmpty, "session actions plugin is observation-only")
        XCTAssertFalse(plugin.needsTick(surfaceState: PluginSurfaceState(visibleSurfaces: [.sessionContextMenu])))
    }

    // MARK: - Host eviction lifecycle

    /// The host owns the session lifecycle: it generates the context action on a session
    /// event and evicts it by `targetSessionID` on `session.ended`.
    func testHostShowsAndEvictsContextActionAcrossLifecycle() async {
        let host = PluginHost()
        host.register([SessionActionsPlugin()])

        host.enqueue(sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1")))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.sessionContextMenu]?.count, 1)

        host.enqueue(sessionEvent(kind: .sessionEnded, session: makeSnapshot(id: "s1")))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions, [:])
    }

    // MARK: - Session Command Catalog

    func testCatalogRecognizesSessionDismiss() {
        XCTAssertTrue(SessionCommandCatalog.isSessionCommand("session.dismiss"))
        XCTAssertNotNil(SessionCommandCatalog.descriptor(for: "session.dismiss"))
    }

    func testCatalogRejectsUnknownCapability() {
        XCTAssertFalse(SessionCommandCatalog.isSessionCommand("session.bogus"))
        XCTAssertNil(SessionCommandCatalog.descriptor(for: "session.bogus"))
        XCTAssertFalse(SessionCommandCatalog.isAllowed("session.bogus", permissions: [.showSessionSurface]))
    }

    func testCatalogAllowsDismissOnlyWithShowSessionSurface() {
        XCTAssertTrue(SessionCommandCatalog.isAllowed("session.dismiss", permissions: [.showSessionSurface]))
        XCTAssertFalse(SessionCommandCatalog.isAllowed("session.dismiss", permissions: []))
        XCTAssertFalse(SessionCommandCatalog.isAllowed("session.dismiss", permissions: [.readSessionEvents]))
    }

    func testDismissDescriptorIsDestructive() {
        XCTAssertEqual(SessionCommandCatalog.descriptor(for: "session.dismiss")?.isDestructive, true)
    }

    func testCatalogRecognizesCopyResumeCommand() {
        XCTAssertTrue(SessionCommandCatalog.isSessionCommand("session.copyResumeCommand"))
        XCTAssertTrue(SessionCommandCatalog.isAllowed("session.copyResumeCommand", permissions: [.showSessionSurface]))
        XCTAssertFalse(SessionCommandCatalog.isAllowed("session.copyResumeCommand", permissions: []))
    }

    func testCopyResumeCommandDescriptorIsNonDestructive() {
        XCTAssertEqual(SessionCommandCatalog.descriptor(for: "session.copyResumeCommand")?.isDestructive, false)
    }

    func testCatalogRecognizesFocusTerminal() {
        XCTAssertTrue(SessionCommandCatalog.isSessionCommand("session.focusTerminal"))
        XCTAssertTrue(SessionCommandCatalog.isAllowed("session.focusTerminal", permissions: [.showSessionSurface]))
        XCTAssertFalse(SessionCommandCatalog.isAllowed("session.focusTerminal", permissions: []))
    }

    func testFocusTerminalDescriptorIsNonDestructive() {
        XCTAssertEqual(SessionCommandCatalog.descriptor(for: "session.focusTerminal")?.isDestructive, false)
    }

    func testCatalogRecognizesOpenWorkspace() {
        XCTAssertTrue(SessionCommandCatalog.isSessionCommand("session.openWorkspace"))
        XCTAssertTrue(SessionCommandCatalog.isAllowed("session.openWorkspace", permissions: [.showSessionSurface]))
        XCTAssertFalse(SessionCommandCatalog.isAllowed("session.openWorkspace", permissions: []))
    }

    func testOpenWorkspaceDescriptorIsNonDestructive() {
        XCTAssertEqual(SessionCommandCatalog.descriptor(for: "session.openWorkspace")?.isDestructive, false)
    }

    // MARK: - Host Command Catalog routing

    func testHostRoutesSessionDismissToCommandHandler() {
        let host = PluginHost()
        host.register([SessionActionsPlugin()])
        var received: (capability: String, sessionID: String)?
        host.sessionCommandHandler = { received = ($0, $1) }

        host.handleAction(dismissAction(sessionID: "s1"), from: "com.devisland.session-actions", componentID: "dismiss")

        XCTAssertEqual(received?.capability, "session.dismiss")
        XCTAssertEqual(received?.sessionID, "s1")
    }

    func testHostRoutesCopyResumeCommandToCommandHandler() {
        let host = PluginHost()
        host.register([SessionActionsPlugin()])
        var received: (capability: String, sessionID: String)?
        host.sessionCommandHandler = { received = ($0, $1) }

        host.handleAction(copyResumeAction(sessionID: "s1"), from: "com.devisland.session-actions", componentID: "copy-resume")

        XCTAssertEqual(received?.capability, "session.copyResumeCommand")
        XCTAssertEqual(received?.sessionID, "s1")
    }

    func testHostRejectsCopyResumeCommandWithoutShowSessionSurface() {
        let host = PluginHost()
        host.register([DismissStubPlugin(permissions: [])])
        var called = false
        host.sessionCommandHandler = { _, _ in called = true }

        host.handleAction(copyResumeAction(sessionID: "s1"), from: "com.devisland.test.dismiss-stub", componentID: "copy-resume")

        XCTAssertFalse(called, "session.copyResumeCommand requires showSessionSurface")
    }

    func testHostRoutesFocusTerminalToCommandHandler() {
        let host = PluginHost()
        host.register([SessionActionsPlugin()])
        var received: (capability: String, sessionID: String)?
        host.sessionCommandHandler = { received = ($0, $1) }

        host.handleAction(focusTerminalAction(sessionID: "s1"), from: "com.devisland.session-actions", componentID: "focus-terminal")

        XCTAssertEqual(received?.capability, "session.focusTerminal")
        XCTAssertEqual(received?.sessionID, "s1")
    }

    func testHostRejectsFocusTerminalWithoutShowSessionSurface() {
        let host = PluginHost()
        host.register([DismissStubPlugin(permissions: [])])
        var called = false
        host.sessionCommandHandler = { _, _ in called = true }

        host.handleAction(focusTerminalAction(sessionID: "s1"), from: "com.devisland.test.dismiss-stub", componentID: "focus-terminal")

        XCTAssertFalse(called, "session.focusTerminal requires showSessionSurface")
    }

    func testHostRoutesOpenWorkspaceToCommandHandler() {
        let host = PluginHost()
        host.register([SessionActionsPlugin()])
        var received: (capability: String, sessionID: String)?
        host.sessionCommandHandler = { received = ($0, $1) }

        host.handleAction(openWorkspaceAction(sessionID: "s1"), from: "com.devisland.session-actions", componentID: "open-workspace")

        XCTAssertEqual(received?.capability, "session.openWorkspace")
        XCTAssertEqual(received?.sessionID, "s1")
    }

    func testHostRejectsOpenWorkspaceWithoutShowSessionSurface() {
        let host = PluginHost()
        host.register([DismissStubPlugin(permissions: [])])
        var called = false
        host.sessionCommandHandler = { _, _ in called = true }

        host.handleAction(openWorkspaceAction(sessionID: "s1"), from: "com.devisland.test.dismiss-stub", componentID: "open-workspace")

        XCTAssertFalse(called, "session.openWorkspace requires showSessionSurface")
    }

    func testHostRejectsSessionDismissWithoutShowSessionSurface() {
        let host = PluginHost()
        host.register([DismissStubPlugin(permissions: [])])
        var called = false
        host.sessionCommandHandler = { _, _ in called = true }

        host.handleAction(dismissAction(sessionID: "s1"), from: "com.devisland.test.dismiss-stub", componentID: "dismiss")

        XCTAssertFalse(called, "session.dismiss requires showSessionSurface")
    }

    func testHostRejectsSessionDismissWithoutSessionID() {
        let host = PluginHost()
        host.register([SessionActionsPlugin()])
        var called = false
        host.sessionCommandHandler = { _, _ in called = true }

        let action = PluginUIActionDTO(id: "session.dismiss", capability: "session.dismiss", routing: .hostExecuted, payload: [:])
        host.handleAction(action, from: "com.devisland.session-actions", componentID: "dismiss")

        XCTAssertFalse(called, "a session command with no target id must not run")
    }

    func testDisabledPluginCannotInvokeSessionCommand() {
        let host = PluginHost()
        host.register([SessionActionsPlugin()])
        host.setPluginEnabled(false, pluginID: "com.devisland.session-actions")
        var called = false
        host.sessionCommandHandler = { _, _ in called = true }

        host.handleAction(dismissAction(sessionID: "s1"), from: "com.devisland.session-actions", componentID: "dismiss")

        XCTAssertFalse(called, "a disabled plugin must not reach the host command catalog")
    }

    // MARK: - Host dismissal policy (AppState.isPluginDismissable)

    func testIdleCleanSessionIsDismissable() {
        XCTAssertTrue(AppState.isPluginDismissable(makeActiveSession()))
    }

    func testPendingSessionIsNotDismissable() {
        XCTAssertFalse(AppState.isPluginDismissable(makeActiveSession(isPending: true, status: .pending)))
    }

    func testMissedApprovalSessionIsNotDismissable() {
        XCTAssertFalse(AppState.isPluginDismissable(makeActiveSession(hasMissedApproval: true)))
    }

    func testUnreadSessionIsNotDismissable() {
        XCTAssertFalse(AppState.isPluginDismissable(makeActiveSession(isUnread: true)))
    }

    func testNonIdleStatusSessionIsNotDismissable() {
        XCTAssertFalse(
            AppState.isPluginDismissable(makeActiveSession(status: .autoApproved(Date()))),
            "only fully idle sessions may be dismissed by a plugin"
        )
    }

    // MARK: - Helpers

    private func makeSnapshot(id: String, workspaceRoot: String? = nil) -> PluginSessionSnapshot {
        PluginSessionSnapshot(
            id: id,
            agentKind: "codex",
            startTime: Date(timeIntervalSince1970: 0),
            lastActiveAt: Date(timeIntervalSince1970: 0),
            lastToolName: nil,
            lastEventName: nil,
            workspaceRoot: workspaceRoot
        )
    }

    private func sessionEvent(kind: PluginEventKind, session: PluginSessionSnapshot) -> PluginEvent {
        PluginEvent(id: UUID(), kind: kind, timestamp: Date(), session: session)
    }

    private func context() -> PluginContext {
        PluginContext(
            pluginID: "com.devisland.session-actions",
            permissions: [.readSessionEvents, .showSessionSurface],
            storageSnapshot: [:]
        )
    }

    private func uiContext(session: PluginSessionSnapshot) -> PluginUIContext {
        PluginUIContext(slot: .sessionContextMenu, timestamp: Date(), session: session)
    }

    private func dismissAction(sessionID: String) -> PluginUIActionDTO {
        PluginUIActionDTO(id: "session.dismiss", capability: "session.dismiss", routing: .hostExecuted, payload: ["sessionID": sessionID])
    }

    private func copyResumeAction(sessionID: String) -> PluginUIActionDTO {
        PluginUIActionDTO(id: "session.copyResumeCommand", capability: "session.copyResumeCommand", routing: .hostExecuted, payload: ["sessionID": sessionID])
    }

    private func focusTerminalAction(sessionID: String) -> PluginUIActionDTO {
        PluginUIActionDTO(id: "session.focusTerminal", capability: "session.focusTerminal", routing: .hostExecuted, payload: ["sessionID": sessionID])
    }

    private func openWorkspaceAction(sessionID: String) -> PluginUIActionDTO {
        PluginUIActionDTO(id: "session.openWorkspace", capability: "session.openWorkspace", routing: .hostExecuted, payload: ["sessionID": sessionID])
    }

    private func makeActiveSession(
        id: String = "s1",
        agentKind: BuddyKind = .codex,
        workspaceRoot: String? = nil,
        isPending: Bool = false,
        isUnread: Bool = false,
        hasMissedApproval: Bool = false,
        status: SessionStatus = .idle
    ) -> ActiveSession {
        ActiveSession(
            id: id,
            terminalTitle: "Terminal",
            agentKind: agentKind,
            terminalApp: "",
            terminalTTY: "",
            terminalWindowId: "",
            terminalTabIndex: "",
            terminalTmuxPane: "",
            terminalTmuxSocket: "",
            terminalTmuxClient: "",
            lastToolName: "",
            lastEventName: "",
            lastMessage: "",
            startTime: Date(timeIntervalSince1970: 0),
            lastActiveAt: Date(timeIntervalSince1970: 0),
            isPending: isPending,
            isLifecycleTracked: true,
            isSubAgentSession: false,
            isAutoEditActive: false,
            isUnread: isUnread,
            hasMissedApproval: hasMissedApproval,
            status: status,
            parentSessionId: nil,
            workspaceRoot: workspaceRoot
        )
    }

    // MARK: - ActiveSession.resumeCommand (host-generated, shell-escaped)

    func testResumeCommandClaudeCodeWithWorkspace() {
        let session = makeActiveSession(id: "abc123", agentKind: .claudeCode, workspaceRoot: "/Users/me/proj")
        XCTAssertEqual(session.resumeCommand, "cd '/Users/me/proj' && claude --resume abc123")
    }

    func testResumeCommandCodexWithoutWorkspace() {
        let session = makeActiveSession(id: "abc123", agentKind: .codex, workspaceRoot: nil)
        XCTAssertEqual(session.resumeCommand, "codex --resume abc123")
    }

    func testResumeCommandGeminiIgnoresSessionID() {
        let session = makeActiveSession(id: "abc123", agentKind: .gemini, workspaceRoot: "/tmp/x")
        XCTAssertEqual(session.resumeCommand, "cd '/tmp/x' && gemini")
    }

    func testResumeCommandIslandIsCdOnlyOrEmpty() {
        XCTAssertEqual(makeActiveSession(agentKind: .island, workspaceRoot: "/tmp/x").resumeCommand, "cd '/tmp/x'")
        XCTAssertEqual(makeActiveSession(agentKind: .island, workspaceRoot: nil).resumeCommand, "")
    }

    func testResumeCommandEscapesSingleQuotesInPath() {
        let session = makeActiveSession(agentKind: .codex, workspaceRoot: "/tmp/a'b")
        XCTAssertEqual(session.resumeCommand, "cd '/tmp/a'\\''b' && codex --resume s1")
    }

    /// Command-injection guard: shell metacharacters in the path must survive as literals
    /// inside the single quotes, never as command substitution or variable expansion.
    func testResumeCommandPreservesShellMetacharactersLiterally() {
        let session = makeActiveSession(agentKind: .codex, workspaceRoot: "/tmp/$(whoami)`id`$HOME")
        XCTAssertEqual(session.resumeCommand, "cd '/tmp/$(whoami)`id`$HOME' && codex --resume s1")
    }
}

private final class DismissStubPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest

    init(permissions: Set<PluginPermission>) {
        manifest = PluginManifest(
            id: "com.devisland.test.dismiss-stub",
            name: "dismiss stub",
            version: "1.0.0",
            apiVersion: 1,
            kind: .system,
            permissions: permissions,
            surfaces: [],
            activationEvents: []
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] { [] }
    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? { nil }
    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }
}
