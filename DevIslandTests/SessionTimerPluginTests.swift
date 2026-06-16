import XCTest
@testable import DevIsland

@MainActor
final class SessionTimerPluginTests: XCTestCase {

    // MARK: - Plugin logic (direct calls)

    func testSessionStartProducesElapsedMetric() async throws {
        let plugin = SessionTimerPlugin()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(id: "s1", startTime: start, lastActiveAt: start)

        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, session: snapshot), context: context())

        let contribution = try plugin.makeUIContribution(
            for: .notchExpandedActivity,
            context: uiContext(timestamp: start.addingTimeInterval(65))
        )
        let component = try XCTUnwrap(contribution?.components.first)

        XCTAssertEqual(contribution?.slot, .notchExpandedActivity)
        XCTAssertNil(contribution?.targetSessionID, "global slot must not be session-scoped")
        XCTAssertEqual(component.type, .metric)
        XCTAssertEqual(component.label, "Elapsed")
        XCTAssertEqual(component.value, "01:05")
    }

    func testSessionStartProducesKoreanElapsedMetric() async throws {
        let plugin = SessionTimerPlugin()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(id: "s1", startTime: start, lastActiveAt: start)

        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, session: snapshot), context: context())

        let contribution = try plugin.makeUIContribution(
            for: .notchExpandedActivity,
            context: uiContext(timestamp: start.addingTimeInterval(65), language: .korean)
        )

        XCTAssertEqual(contribution?.components.first?.label, "경과")
    }

    func testElapsedFormatsHoursPastSixtyMinutes() async throws {
        let plugin = SessionTimerPlugin()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = try await plugin.onEvent(
            sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1", startTime: start, lastActiveAt: start)),
            context: context()
        )

        let contribution = try plugin.makeUIContribution(
            for: .notchExpandedActivity,
            context: uiContext(timestamp: start.addingTimeInterval(3_665))
        )

        XCTAssertEqual(contribution?.components.first?.value, "1:01:05")
    }

    func testSessionEndClearsContribution() async throws {
        let plugin = SessionTimerPlugin()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(id: "s1", startTime: start, lastActiveAt: start)

        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, session: snapshot), context: context())
        XCTAssertNotNil(
            try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext(timestamp: start))
        )

        _ = try await plugin.onEvent(sessionEvent(kind: .sessionEnded, session: snapshot), context: context())
        XCTAssertNil(
            try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext(timestamp: start)),
            "no active session means no contribution"
        )
    }

    // MARK: - Per-session row badge (notch.session.row)

    func testSessionRowProducesPerSessionElapsedBadge() async throws {
        let plugin = SessionTimerPlugin()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(id: "s1", startTime: start, lastActiveAt: start)

        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, session: snapshot), context: context())

        let contribution = try XCTUnwrap(try plugin.makeUIContribution(
            for: .notchSessionRow,
            context: PluginUIContext(slot: .notchSessionRow, timestamp: start.addingTimeInterval(65), session: snapshot)
        ))
        XCTAssertEqual(contribution.slot, .notchSessionRow)
        XCTAssertEqual(contribution.targetSessionID, "s1", "row badge must be keyed to its session")
        XCTAssertEqual(contribution.components.first?.value, "01:05")
        XCTAssertNil(contribution.components.first?.label, "row badge omits the label to stay compact")
    }

    func testSessionRowBadgeAbsentForUntrackedSession() async throws {
        let plugin = SessionTimerPlugin()
        // No session.started observed, so the session is not tracked.
        XCTAssertNil(try plugin.makeUIContribution(
            for: .notchSessionRow,
            context: PluginUIContext(slot: .notchSessionRow, timestamp: Date(), session: makeSnapshot(id: "s1"))
        ))
    }

    // MARK: - Message-window header badge (session.message)

    func testSessionMessageProducesPerSessionElapsedBadge() async throws {
        let plugin = SessionTimerPlugin()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(id: "s1", startTime: start, lastActiveAt: start)

        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, session: snapshot), context: context())

        let contribution = try XCTUnwrap(try plugin.makeUIContribution(
            for: .sessionMessage,
            context: PluginUIContext(slot: .sessionMessage, timestamp: start.addingTimeInterval(65), session: snapshot)
        ))
        XCTAssertEqual(contribution.slot, .sessionMessage)
        XCTAssertEqual(contribution.targetSessionID, "s1", "header badge must be keyed to its session")
        XCTAssertEqual(contribution.components.first?.value, "01:05")
    }

    /// The message-window surface is session-scoped, so the host evaluates it on session
    /// events and evicts by `targetSessionID` on `session.ended`.
    func testHostShowsAndEvictsSessionMessageBadgeAcrossLifecycle() async {
        let host = PluginHost()
        host.register([SessionTimerPlugin()])

        host.enqueue(sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1")))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.sessionMessage]?.count, 1)

        host.enqueue(sessionEvent(kind: .sessionEnded, session: makeSnapshot(id: "s1")))
        await host.waitUntilIdle()
        XCTAssertNil(host.contributions[.sessionMessage])
    }

    func testCurrentSessionIsMostRecentlyActive() async throws {
        let plugin = SessionTimerPlugin()
        let base = Date(timeIntervalSince1970: 1_000)
        let older = makeSnapshot(id: "old", startTime: base, lastActiveAt: base.addingTimeInterval(10))
        let newer = makeSnapshot(id: "new", startTime: base.addingTimeInterval(30), lastActiveAt: base.addingTimeInterval(40))

        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, session: older), context: context())
        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, session: newer), context: context())

        // Elapsed is measured from the most recently active session (newer, startTime base+30).
        let contribution = try plugin.makeUIContribution(
            for: .notchExpandedActivity,
            context: uiContext(timestamp: base.addingTimeInterval(90))
        )
        XCTAssertEqual(contribution?.components.first?.value, "01:00")
    }

    // MARK: - Selected-session signal (global slot)

    func testGlobalSlotFollowsSelectedSessionOverRecency() async throws {
        let plugin = SessionTimerPlugin()
        let base = Date(timeIntervalSince1970: 1_000)
        let older = makeSnapshot(id: "old", startTime: base, lastActiveAt: base.addingTimeInterval(10))
        let newer = makeSnapshot(id: "new", startTime: base.addingTimeInterval(30), lastActiveAt: base.addingTimeInterval(40))

        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, session: older), context: context())
        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, session: newer), context: context())

        // The user selected the older session; the global elapsed must follow the selection,
        // not the most-recently-active (newer) one. older startTime = base → base+90 = 90s.
        let ctx = PluginUIContext(
            slot: .notchExpandedActivity,
            timestamp: base.addingTimeInterval(90),
            session: nil,
            selectedSessionID: "old"
        )
        let contribution = try plugin.makeUIContribution(for: .notchExpandedActivity, context: ctx)
        XCTAssertEqual(contribution?.components.first?.value, "01:30")
    }

    func testGlobalSlotFallsBackToRecencyWhenSelectionUntracked() async throws {
        let plugin = SessionTimerPlugin()
        let base = Date(timeIntervalSince1970: 1_000)
        let newer = makeSnapshot(id: "new", startTime: base.addingTimeInterval(30), lastActiveAt: base.addingTimeInterval(40))

        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, session: newer), context: context())

        // Selection points at a session this plugin never tracked → recency fallback (newer).
        let ctx = PluginUIContext(
            slot: .notchExpandedActivity,
            timestamp: base.addingTimeInterval(90),
            session: nil,
            selectedSessionID: "ghost"
        )
        let contribution = try plugin.makeUIContribution(for: .notchExpandedActivity, context: ctx)
        XCTAssertEqual(contribution?.components.first?.value, "01:00")
    }

    func testNeedsTickOnlyWhenSessionActiveAndNotchVisible() async throws {
        let plugin = SessionTimerPlugin()
        let visible = PluginSurfaceState(visibleSurfaces: [.notchExpandedActivity])
        let hidden = PluginSurfaceState(visibleSurfaces: [])

        XCTAssertFalse(plugin.needsTick(surfaceState: visible), "no session means no tick")

        _ = try await plugin.onEvent(
            sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1")),
            context: context()
        )
        XCTAssertFalse(plugin.needsTick(surfaceState: hidden), "hidden notch means no tick")
        XCTAssertTrue(plugin.needsTick(surfaceState: visible), "active session + visible notch needs tick")
    }

    // MARK: - Host integration

    /// `.notchExpandedActivity` is a global slot, so the contribution is evicted
    /// via the nil-return path (remove-by-pluginID), not targetSessionID eviction.
    func testHostEvictsGlobalContributionWhenSessionEnds() async {
        let host = PluginHost()
        host.register([SessionTimerPlugin()])

        host.enqueue(sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1")))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.notchExpandedActivity]?.count, 1)

        host.enqueue(sessionEvent(kind: .sessionEnded, session: makeSnapshot(id: "s1")))
        await host.waitUntilIdle()
        XCTAssertTrue(host.contributions[.notchExpandedActivity]?.isEmpty ?? true)
    }

    /// `.notchSessionRow` is session-scoped, so its eviction goes through the
    /// `targetSessionID` path on `session.ended` (not the remove-by-pluginID path).
    func testHostEvictsSessionRowBadgeWhenSessionEnds() async {
        let host = PluginHost()
        host.register([SessionTimerPlugin()])

        host.enqueue(sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1")))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.notchSessionRow]?.count, 1, "an active session contributes a row badge")

        host.enqueue(sessionEvent(kind: .sessionEnded, session: makeSnapshot(id: "s1")))
        await host.waitUntilIdle()
        // The ended session clears both the row badge and the global activity card,
        // so the whole cache is empty.
        XCTAssertEqual(host.contributions, [:])
    }

    /// Disabling a plugin must drop its session-scoped contributions too, not just
    /// global ones — otherwise per-session row badges would linger after disable.
    func testDisablingPluginEvictsSessionRowBadge() async {
        let host = PluginHost()
        host.register([SessionTimerPlugin()])

        host.enqueue(sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1")))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.notchSessionRow]?.count, 1)

        host.setPluginEnabled(false, pluginID: "com.devisland.timer")
        XCTAssertEqual(
            host.contributions,
            [:],
            "disabling a plugin must evict its per-session contributions"
        )
    }

    /// The host pulls the selection from `selectedSessionProvider` at drain time and threads
    /// it into each plugin's `PluginUIContext`.
    func testHostSuppliesSelectedSessionToContext() async {
        let host = PluginHost()
        let echo = SelectionEchoPlugin()
        host.register([echo])
        host.selectedSessionProvider = { "selected-id" }

        host.enqueue(sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1")))
        await host.waitUntilIdle()

        let contribution = host.contributions[.notchExpandedActivity]?.first
        XCTAssertEqual(contribution?.components.first?.value, "selected-id")
    }

    func testHostSuppliesNilSelectionWhenNoProvider() async {
        let host = PluginHost()
        let echo = SelectionEchoPlugin()
        host.register([echo])

        host.enqueue(sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1")))
        await host.waitUntilIdle()

        let contribution = host.contributions[.notchExpandedActivity]?.first
        XCTAssertEqual(contribution?.components.first?.value, "none")
    }

    /// The selected session id is session data, so a plugin without `readSessionEvents`
    /// must not receive it — even on a non-session event it is allowed to handle.
    func testSelectedSessionGatedByReadSessionEventsPermission() async {
        let host = PluginHost()
        let echo = SelectionEchoPlugin(permissions: [.showNotchCard])  // no readSessionEvents
        host.register([echo])
        host.selectedSessionProvider = { "selected-id" }

        host.enqueue(PluginEvent(id: UUID(), kind: .appStarted, timestamp: Date()))
        await host.waitUntilIdle()

        let contribution = host.contributions[.notchExpandedActivity]?.first
        XCTAssertEqual(
            contribution?.components.first?.value, "none",
            "a plugin without readSessionEvents must not learn the selected session id"
        )
    }

    // MARK: - Permission gating relied on by SessionTimer

    func testSessionEventRequiresReadSessionEventsPermission() async {
        let denied = GatingStubPlugin(permissions: [])
        let deniedHost = PluginHost()
        deniedHost.register([denied])
        deniedHost.enqueue(sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1")))
        await deniedHost.waitUntilIdle()
        XCTAssertTrue(denied.received.isEmpty, "session events must not reach a plugin without readSessionEvents")

        let allowed = GatingStubPlugin(permissions: [.readSessionEvents])
        let allowedHost = PluginHost()
        allowedHost.register([allowed])
        allowedHost.enqueue(sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1")))
        await allowedHost.waitUntilIdle()
        XCTAssertEqual(allowed.received, [.sessionStarted])
    }

    // MARK: - Settings (show-seconds) and settings.changed fan-out

    func testShowSecondsSettingControlsBadgeFormat() async throws {
        let plugin = SessionTimerPlugin()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(id: "s1", startTime: start, lastActiveAt: start)
        let ctx = PluginContext(
            pluginID: "com.devisland.timer",
            permissions: [.readSessionEvents, .showNotchCard, .showSessionSurface],
            storageSnapshot: [:],
            settings: ["showSeconds": .bool(false)]
        )
        _ = try await plugin.onEvent(sessionEvent(kind: .sessionStarted, session: snapshot), context: ctx)

        let contribution = try XCTUnwrap(try plugin.makeUIContribution(
            for: .notchSessionRow,
            context: PluginUIContext(slot: .notchSessionRow, timestamp: start.addingTimeInterval(65), session: snapshot)
        ))
        XCTAssertEqual(contribution.components.first?.value, "1m",
                       "with seconds hidden the badge shows whole minutes")
    }

    /// The core of the codex P2 fix: changing a setting must refresh a *session-scoped*
    /// contribution, which only happens if the host fans out settings.changed per active
    /// session. Without the fan-out the row badge keeps its old (seconds) format.
    func testSettingChangeRefreshesSessionScopedBadgeViaHost() async {
        let suiteName = "SessionTimerPluginTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = PluginSettingsStore(userDefaults: defaults)

        let host = PluginHost()
        host.register([SessionTimerPlugin()], settingsStore: store)
        // Recent startTime so elapsed stays under an hour (format differs only by the colon).
        let snapshot = makeSnapshot(id: "s1", startTime: Date(), lastActiveAt: Date())
        host.activeSessionsProvider = { [snapshot] }

        host.enqueue(sessionEvent(kind: .sessionStarted, session: snapshot))
        await host.waitUntilIdle()
        let before = host.contributions[.notchSessionRow]?.first?.components.first?.value
        XCTAssertEqual(before?.contains(":"), true, "default (showSeconds=true) badge uses MM:SS")

        store.setValue(.bool(false), forKey: "showSeconds", pluginID: "com.devisland.timer")
        host.pluginSettingChanged(pluginID: "com.devisland.timer")
        await host.waitUntilIdle()

        let after = host.contributions[.notchSessionRow]?.first?.components.first?.value
        XCTAssertNotNil(after)
        XCTAssertEqual(after?.contains(":"), false,
                       "settings.changed must refresh the session-scoped badge to seconds-hidden format")
    }

    // MARK: - Helpers

    private func makeSnapshot(
        id: String,
        startTime: Date = Date(timeIntervalSince1970: 0),
        lastActiveAt: Date = Date(timeIntervalSince1970: 0)
    ) -> PluginSessionSnapshot {
        PluginSessionSnapshot(
            id: id,
            agentKind: "codex",
            startTime: startTime,
            lastActiveAt: lastActiveAt,
            lastToolName: nil,
            lastEventName: nil,
            workspaceRoot: nil
        )
    }

    private func sessionEvent(kind: PluginEventKind, session: PluginSessionSnapshot) -> PluginEvent {
        PluginEvent(
            id: UUID(),
            kind: kind,
            timestamp: Date(),
            session: session,
            hook: nil,
            action: nil,
            approval: nil
        )
    }

    private func context() -> PluginContext {
        PluginContext(
            pluginID: "com.devisland.timer",
            permissions: [.readSessionEvents, .showNotchCard],
            storageSnapshot: [:]
        )
    }

    private func uiContext(timestamp: Date, language: AppLanguage = .english) -> PluginUIContext {
        PluginUIContext(slot: .notchExpandedActivity, timestamp: timestamp, session: nil, language: language)
    }
}

private final class GatingStubPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let receivedStorage = LockIsolated<[PluginEventKind]>([])
    var received: [PluginEventKind] {
        receivedStorage.value
    }

    init(permissions: Set<PluginPermission>) {
        manifest = PluginManifest(
            id: "com.devisland.test.session-gating",
            name: "gating",
            version: "1.0.0",
            apiVersion: 1,
            kind: .system,
            permissions: permissions,
            surfaces: [],
            activationEvents: [PluginEventKind.sessionStarted.rawValue]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        receivedStorage.withValue { $0.append(event.kind) }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        nil
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }
}

/// Echoes the `selectedSessionID` it receives in `PluginUIContext` into a global-slot
/// contribution, so a host test can assert the selection signal reached the runner.
private final class SelectionEchoPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest

    init(permissions: Set<PluginPermission> = [.readSessionEvents, .showNotchCard]) {
        manifest = PluginManifest(
            id: "com.devisland.test.selection-echo",
            name: "selection echo",
            version: "1.0.0",
            apiVersion: 1,
            kind: .system,
            permissions: permissions,
            surfaces: [.notchExpandedActivity],
            // app.started is a non-session event a plugin receives without readSessionEvents,
            // so it exercises the selected-session permission gate.
            activationEvents: [
                PluginEventKind.sessionStarted.rawValue,
                PluginEventKind.appStarted.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] { [] }
    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        guard slot == .notchExpandedActivity else { return nil }
        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: nil,
            priority: 1,
            expiresAt: nil,
            components: [
                PluginUIComponentDTO(
                    id: "sel",
                    type: .text,
                    label: context.selectedSessionID ?? "none",
                    value: context.selectedSessionID ?? "none",
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }
}
