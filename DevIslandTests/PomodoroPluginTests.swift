import XCTest
@testable import DevIsland

@MainActor
final class PomodoroPluginTests: XCTestCase {

    // MARK: - Plugin logic (direct calls)

    func testStartsAndPausesViaToggleAction() throws {
        let plugin = PomodoroPlugin()
        XCTAssertFalse(plugin.needsTick(surfaceState: noSurfaces), "idle must not request ticks")

        _ = try plugin.onEvent(toggleEvent(), context: context())
        XCTAssertTrue(plugin.needsTick(surfaceState: noSurfaces), "running must request ticks")
        let running = try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext())
        XCTAssertEqual(metric(running, id: "timer")?.label, "Focus")
        XCTAssertEqual(metric(running, id: "timer")?.tone, .success)
        XCTAssertEqual(button(running)?.label, "Pause")

        _ = try plugin.onEvent(toggleEvent(), context: context())
        XCTAssertFalse(plugin.needsTick(surfaceState: noSurfaces), "paused must not request ticks")
        let paused = try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext())
        XCTAssertEqual(metric(paused, id: "timer")?.label, "Paused")
        XCTAssertEqual(button(paused)?.label, "Start")
    }

    func testTickDecrementsOnlyWhileRunning() throws {
        let plugin = PomodoroPlugin(workSeconds: 90)

        // Idle: tick is a no-op.
        _ = try plugin.onEvent(tickEvent(), context: context())
        XCTAssertEqual(metric(try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext()), id: "timer")?.value, "01:30")

        // Running: tick counts down.
        _ = try plugin.onEvent(toggleEvent(), context: context())
        _ = try plugin.onEvent(tickEvent(), context: context())
        XCTAssertEqual(metric(try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext()), id: "timer")?.value, "01:29")
    }

    func testCompletionEmitsNotificationResetsAndCountsUp() throws {
        let plugin = PomodoroPlugin(workSeconds: 2)
        _ = try plugin.onEvent(toggleEvent(), context: context())   // running, 2s

        let beforeLast = try plugin.onEvent(tickEvent(), context: context())   // -> 1s
        XCTAssertTrue(beforeLast.isEmpty, "no effect until the block completes")

        let onComplete = try plugin.onEvent(tickEvent(), context: context())   // -> 0 -> complete
        XCTAssertEqual(onComplete.count, 1)
        XCTAssertEqual(onComplete.first?.capability, "notification.show")
        XCTAssertEqual(onComplete.first?.payload["title"], "Pomodoro")

        // After completion: idle, reset to full duration, count incremented.
        XCTAssertFalse(plugin.needsTick(surfaceState: noSurfaces))
        let menu = try plugin.makeUIContribution(for: .menubarMenu, context: uiContext())
        XCTAssertEqual(metric(menu, id: "timer")?.value, "00:02")
        XCTAssertEqual(metric(menu, id: "count")?.value, "1")
    }

    func testRendersBothSlotsWithToggleAction() throws {
        let plugin = PomodoroPlugin()

        let notch = try XCTUnwrap(try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext()))
        XCTAssertEqual(notch.slot, .notchExpandedActivity)
        XCTAssertNil(notch.targetSessionID)
        XCTAssertEqual(button(notch)?.action?.capability, "timer.startStop")
        XCTAssertEqual(button(notch)?.action?.routing, .pluginEvent)

        let menu = try XCTUnwrap(try plugin.makeUIContribution(for: .menubarMenu, context: uiContext()))
        XCTAssertEqual(menu.slot, .menubarMenu)
        XCTAssertEqual(metric(menu, id: "timer")?.label, "Pomodoro")
        XCTAssertNotNil(metric(menu, id: "count"))
        XCTAssertNotNil(button(menu))
    }

    // MARK: - Host integration

    /// The toggle action is `pluginEvent`-routed; it must come back only to Pomodoro
    /// and never reach another plugin that also listens for action events.
    func testHandleActionTogglesOnlyTargetPlugin() async {
        let pomodoro = PomodoroPlugin()
        let bystander = ActionRecordingPlugin(id: "com.devisland.test.bystander")
        let host = PluginHost()
        host.register([pomodoro, bystander])

        // Register surfaces by sending a lifecycle event first so contributions exist.
        host.enqueue(makeBareEvent(kind: .pluginStarted))
        await host.waitUntilIdle()
        XCTAssertEqual(button(host.contributions[.notchExpandedActivity]?.first)?.label, "Start")

        host.handleAction(
            PluginUIActionDTO(id: "pomodoro.toggle", capability: "timer.startStop", routing: .pluginEvent, payload: [:]),
            from: pomodoro.manifest.id,
            componentID: "toggle"
        )
        await host.waitUntilIdle()

        XCTAssertEqual(button(host.contributions[.notchExpandedActivity]?.first)?.label, "Pause",
                       "Pomodoro must receive its own toggle and start running")
        XCTAssertTrue(bystander.received.isEmpty, "the action must not reach another plugin")
    }

    // MARK: - Helpers

    private let noSurfaces = PluginSurfaceState(visibleSurfaces: [])

    private func context() -> PluginContext {
        PluginContext(pluginID: "com.devisland.pomodoro", permissions: [], storageSnapshot: [:])
    }

    private func uiContext() -> PluginUIContext {
        PluginUIContext(slot: .notchExpandedActivity, timestamp: Date(), session: nil)
    }

    private func tickEvent() -> PluginEvent { makeBareEvent(kind: .pluginTick) }

    private func toggleEvent() -> PluginEvent {
        PluginEvent(
            id: UUID(),
            kind: .pluginActionInvoked,
            timestamp: Date(),
            session: nil,
            hook: nil,
            action: PluginActionEvent(
                pluginID: "com.devisland.pomodoro",
                actionID: "pomodoro.toggle",
                componentID: "toggle",
                capability: "timer.startStop",
                payload: [:],
                value: nil
            ),
            approval: nil
        )
    }

    private func makeBareEvent(kind: PluginEventKind) -> PluginEvent {
        PluginEvent(id: UUID(), kind: kind, timestamp: Date(), session: nil, hook: nil, action: nil, approval: nil)
    }

    private func metric(_ contribution: PluginUIContribution?, id: String) -> PluginUIComponentDTO? {
        contribution?.components.first { $0.id == id && $0.type == .metric }
    }

    private func button(_ contribution: PluginUIContribution?) -> PluginUIComponentDTO? {
        contribution?.components.first { $0.type == .button }
    }
}

private final class ActionRecordingPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let lock = NSLock()
    private var _received: [PluginEventKind] = []
    var received: [PluginEventKind] {
        lock.lock(); defer { lock.unlock() }
        return _received
    }

    init(id: String) {
        manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [],
            surfaces: [],
            activationEvents: [PluginEventKind.pluginActionInvoked.rawValue]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        lock.lock()
        _received.append(event.kind)
        lock.unlock()
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? { nil }
    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }
}
