import XCTest
@testable import DevIsland

@MainActor
final class SessionTimerPluginTests: XCTestCase {

    // MARK: - Plugin logic (direct calls)

    func testSessionStartProducesElapsedMetric() throws {
        let plugin = SessionTimerPlugin()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(id: "s1", startTime: start, lastActiveAt: start)

        _ = try plugin.onEvent(sessionEvent(kind: .sessionStarted, session: snapshot), context: context())

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

    func testElapsedFormatsHoursPastSixtyMinutes() throws {
        let plugin = SessionTimerPlugin()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = try plugin.onEvent(
            sessionEvent(kind: .sessionStarted, session: makeSnapshot(id: "s1", startTime: start, lastActiveAt: start)),
            context: context()
        )

        let contribution = try plugin.makeUIContribution(
            for: .notchExpandedActivity,
            context: uiContext(timestamp: start.addingTimeInterval(3_665))
        )

        XCTAssertEqual(contribution?.components.first?.value, "1:01:05")
    }

    func testSessionEndClearsContribution() throws {
        let plugin = SessionTimerPlugin()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(id: "s1", startTime: start, lastActiveAt: start)

        _ = try plugin.onEvent(sessionEvent(kind: .sessionStarted, session: snapshot), context: context())
        XCTAssertNotNil(
            try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext(timestamp: start))
        )

        _ = try plugin.onEvent(sessionEvent(kind: .sessionEnded, session: snapshot), context: context())
        XCTAssertNil(
            try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext(timestamp: start)),
            "no active session means no contribution"
        )
    }

    func testCurrentSessionIsMostRecentlyActive() throws {
        let plugin = SessionTimerPlugin()
        let base = Date(timeIntervalSince1970: 1_000)
        let older = makeSnapshot(id: "old", startTime: base, lastActiveAt: base.addingTimeInterval(10))
        let newer = makeSnapshot(id: "new", startTime: base.addingTimeInterval(30), lastActiveAt: base.addingTimeInterval(40))

        _ = try plugin.onEvent(sessionEvent(kind: .sessionStarted, session: older), context: context())
        _ = try plugin.onEvent(sessionEvent(kind: .sessionStarted, session: newer), context: context())

        // Elapsed is measured from the most recently active session (newer, startTime base+30).
        let contribution = try plugin.makeUIContribution(
            for: .notchExpandedActivity,
            context: uiContext(timestamp: base.addingTimeInterval(90))
        )
        XCTAssertEqual(contribution?.components.first?.value, "01:00")
    }

    func testNeedsTickOnlyWhenSessionActiveAndNotchVisible() throws {
        let plugin = SessionTimerPlugin()
        let visible = PluginSurfaceState(visibleSurfaces: [.notchExpandedActivity])
        let hidden = PluginSurfaceState(visibleSurfaces: [])

        XCTAssertFalse(plugin.needsTick(surfaceState: visible), "no session means no tick")

        _ = try plugin.onEvent(
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

    private func uiContext(timestamp: Date) -> PluginUIContext {
        PluginUIContext(slot: .notchExpandedActivity, timestamp: timestamp, session: nil)
    }
}

private final class GatingStubPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let lock = NSLock()
    private var _received: [PluginEventKind] = []
    var received: [PluginEventKind] {
        lock.lock(); defer { lock.unlock() }
        return _received
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

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        lock.lock()
        _received.append(event.kind)
        lock.unlock()
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        nil
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }
}
