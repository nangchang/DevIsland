import XCTest
@testable import DevIsland

@MainActor
final class SessionStatsPluginTests: XCTestCase {

    // MARK: - Session counting

    func testActiveSessionCountShownInNotch() async throws {
        let plugin = SessionStatsPlugin()

        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, id: "s1"), context: context())
        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, id: "s2"), context: context())

        let contribution = try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext())
        let component = try XCTUnwrap(contribution?.components.first)
        XCTAssertNil(contribution?.targetSessionID, "global slot must not be session-scoped")
        XCTAssertEqual(component.type, .metric)
        XCTAssertEqual(component.label, "Sessions")
        XCTAssertEqual(component.value, "2")
    }

    func testNoNotchContributionWhenNoActiveSessions() async throws {
        let plugin = SessionStatsPlugin()
        XCTAssertNil(
            try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext()),
            "no active session means no notch contribution"
        )
    }

    func testSessionEndDecrementsCount() async throws {
        let plugin = SessionStatsPlugin()
        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, id: "s1"), context: context())
        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, id: "s2"), context: context())
        _ = try await plugin.onEvent(sessionEvent(kind: .sessionEnded, id: "s1"), context: context())

        let contribution = try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext())
        XCTAssertEqual(contribution?.components.first?.value, "1")
    }

    func testRepeatedUpdatesDoNotDoubleCount() async throws {
        let plugin = SessionStatsPlugin()
        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, id: "s1"), context: context())
        _ = try await plugin.onEvent(sessionEvent(kind: .sessionUpdated, id: "s1"), context: context())

        let contribution = try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext())
        XCTAssertEqual(contribution?.components.first?.value, "1", "same session id must be counted once")
    }

    // MARK: - Hook tallies

    func testHookEventsTalliedPerProviderInMenubar() async throws {
        let plugin = SessionStatsPlugin()
        _ = try await plugin.onEvent(hookEvent(provider: "claude"), context: context())
        _ = try await plugin.onEvent(hookEvent(provider: "claude"), context: context())
        _ = try await plugin.onEvent(hookEvent(provider: "codex"), context: context())

        let contribution = try XCTUnwrap(
            try plugin.makeUIContribution(for: .menubarMenu, context: uiContext(slot: .menubarMenu))
        )
        let byID = Dictionary(uniqueKeysWithValues: contribution.components.map { ($0.id, $0) })

        XCTAssertEqual(byID["sessions"]?.value, "0")
        XCTAssertEqual(byID["hooks"]?.value, "3")
        XCTAssertEqual(byID["provider.claude"]?.value, "2")
        XCTAssertEqual(byID["provider.claude"]?.label, "Claude")
        XCTAssertEqual(byID["provider.codex"]?.value, "1")
    }

    func testProviderRowsSortedDeterministically() async throws {
        let plugin = SessionStatsPlugin()
        _ = try await plugin.onEvent(hookEvent(provider: "gemini"), context: context())
        _ = try await plugin.onEvent(hookEvent(provider: "claude"), context: context())
        _ = try await plugin.onEvent(hookEvent(provider: "codex"), context: context())

        let contribution = try XCTUnwrap(
            try plugin.makeUIContribution(for: .menubarMenu, context: uiContext(slot: .menubarMenu))
        )
        let providerLabels = contribution.components
            .filter { $0.id.hasPrefix("provider.") }
            .map { $0.label }
        XCTAssertEqual(providerLabels, ["Claude", "Codex", "Gemini"])
    }

    func testNoMenubarContributionWhenNothingObserved() async throws {
        let plugin = SessionStatsPlugin()
        XCTAssertNil(
            try plugin.makeUIContribution(for: .menubarMenu, context: uiContext(slot: .menubarMenu)),
            "no sessions and no hooks means no menu rows"
        )
    }

    func testNoHookRowsWhenOnlySessionsObserved() async throws {
        let plugin = SessionStatsPlugin()
        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, id: "s1"), context: context())

        let contribution = try XCTUnwrap(
            try plugin.makeUIContribution(for: .menubarMenu, context: uiContext(slot: .menubarMenu))
        )
        XCTAssertEqual(contribution.components.map { $0.id }, ["sessions"], "no hooks means only the sessions row")
    }

    // MARK: - Approval tallies

    func testApprovalDecisionsTalliedInMenubar() async throws {
        let plugin = SessionStatsPlugin()
        _ = try await plugin.onEvent(approvalEvent(approved: true), context: context())
        _ = try await plugin.onEvent(approvalEvent(approved: true), context: context())
        _ = try await plugin.onEvent(approvalEvent(approved: false), context: context())

        let contribution = try XCTUnwrap(
            try plugin.makeUIContribution(for: .menubarMenu, context: uiContext(slot: .menubarMenu))
        )
        let byID = Dictionary(uniqueKeysWithValues: contribution.components.map { ($0.id, $0) })
        XCTAssertEqual(byID["approved"]?.value, "2")
        XCTAssertEqual(byID["denied"]?.value, "1")
    }

    func testApprovalRowsShownWhenOnlyApprovalsObserved() async throws {
        let plugin = SessionStatsPlugin()
        _ = try await plugin.onEvent(approvalEvent(approved: true), context: context())

        let contribution = try XCTUnwrap(
            try plugin.makeUIContribution(for: .menubarMenu, context: uiContext(slot: .menubarMenu)),
            "an approval decision alone warrants a menu contribution"
        )
        XCTAssertEqual(contribution.components.map { $0.id }, ["sessions", "approved", "denied"])
    }

    func testNoApprovalRowsBeforeAnyDecision() async throws {
        let plugin = SessionStatsPlugin()
        _ = try await plugin.onEvent(hookEvent(provider: "claude"), context: context())

        let contribution = try XCTUnwrap(
            try plugin.makeUIContribution(for: .menubarMenu, context: uiContext(slot: .menubarMenu))
        )
        XCTAssertFalse(
            contribution.components.contains { $0.id == "approved" || $0.id == "denied" },
            "no approval rows until an approval.decided event is observed"
        )
    }

    // MARK: - Tick

    func testNeverNeedsTick() async throws {
        let plugin = SessionStatsPlugin()
        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, id: "s1"), context: context())
        XCTAssertFalse(
            plugin.needsTick(surfaceState: PluginSurfaceState(visibleSurfaces: [.notchExpandedActivity, .menubarMenu])),
            "stats are event-driven and never request the central tick"
        )
    }

    // MARK: - Host integration

    func testHostEvictsNotchContributionWhenAllSessionsEnd() async {
        let host = PluginHost()
        host.register([SessionStatsPlugin()])

        host.enqueue(sessionEvent(kind: .sessionStarted, id: "s1"))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.notchExpandedActivity]?.count, 1)

        host.enqueue(sessionEvent(kind: .sessionEnded, id: "s1"))
        await host.waitUntilIdle()
        XCTAssertTrue(host.contributions[.notchExpandedActivity]?.isEmpty ?? true)
    }

    func testHookEventsRequireReadHookSummariesPermission() async {
        // SessionStatsPlugin declares readHookSummaries; verify the host gate enforces it
        // for hook.received by registering the real plugin (allowed) — the deny path is
        // covered by PluginEventFactory/Host tests. Here we confirm the plugin tallies hooks.
        let host = PluginHost()
        host.register([SessionStatsPlugin()])
        host.enqueue(hookEvent(provider: "claude"))
        await host.waitUntilIdle()
        let menubar = host.contributions[.menubarMenu]?.first
        XCTAssertEqual(menubar?.components.first { $0.id == "hooks" }?.value, "1")
    }

    // MARK: - Helpers

    private func sessionEvent(kind: PluginEventKind, id: String) -> PluginEvent {
        PluginEvent(
            id: UUID(),
            kind: kind,
            timestamp: Date(),
            session: PluginSessionSnapshot(
                id: id,
                agentKind: "codex",
                startTime: Date(timeIntervalSince1970: 0),
                lastActiveAt: Date(timeIntervalSince1970: 0),
                lastToolName: nil,
                lastEventName: nil,
                workspaceRoot: nil
            )
        )
    }

    private func hookEvent(provider: String) -> PluginEvent {
        PluginEvent(
            id: UUID(),
            kind: .hookReceived,
            timestamp: Date(),
            hook: PluginHookSummary(
                provider: provider,
                eventType: "pretooluse",
                commandSummary: nil,
                cwd: nil,
                terminalApp: nil,
                rawEvent: nil,
                toolName: nil,
                notificationType: nil,
                message: nil,
                payload: nil
            )
        )
    }

    private func approvalEvent(approved: Bool) -> PluginEvent {
        PluginEvent(
            id: UUID(),
            kind: .approvalDecided,
            timestamp: Date(),
            approval: PluginApprovalSummary(
                sessionID: "s1",
                approved: approved,
                toolName: "Bash",
                scope: "once"
            )
        )
    }

    private func context() -> PluginContext {
        PluginContext(
            pluginID: BuiltInPluginID.sessionStats,
            permissions: [.readSessionEvents, .readHookSummaries, .showNotchCard, .showMenubarMenu],
            storageSnapshot: [:]
        )
    }

    private func uiContext(slot: PluginUISlot = .notchExpandedActivity) -> PluginUIContext {
        PluginUIContext(slot: slot, timestamp: Date(), session: nil)
    }
}
