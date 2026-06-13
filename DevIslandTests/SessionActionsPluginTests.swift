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

    private func makeSnapshot(id: String) -> PluginSessionSnapshot {
        PluginSessionSnapshot(
            id: id,
            agentKind: "codex",
            startTime: Date(timeIntervalSince1970: 0),
            lastActiveAt: Date(timeIntervalSince1970: 0),
            lastToolName: nil,
            lastEventName: nil,
            workspaceRoot: nil
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

    private func makeActiveSession(
        id: String = "s1",
        isPending: Bool = false,
        isUnread: Bool = false,
        hasMissedApproval: Bool = false,
        status: SessionStatus = .idle
    ) -> ActiveSession {
        ActiveSession(
            id: id,
            terminalTitle: "Terminal",
            agentKind: .codex,
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
            workspaceRoot: nil
        )
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
