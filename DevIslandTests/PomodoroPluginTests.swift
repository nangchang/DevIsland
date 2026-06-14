import XCTest
@testable import DevIsland

@MainActor
final class PomodoroPluginTests: XCTestCase {

    // MARK: - Plugin logic (direct calls)

    func testStartPauseResumePreservesRemainingViaTimestamps() throws {
        let plugin = PomodoroPlugin(workSeconds: 1500)   // 25:00
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(plugin.needsTick(surfaceState: noSurfaces), "idle must not request ticks")

        _ = try plugin.onEvent(toggleEvent(at: t0), context: context())   // start: end = t0+1500
        XCTAssertTrue(plugin.needsTick(surfaceState: noSurfaces), "running must request ticks")
        let running = try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext())
        XCTAssertEqual(metric(running, id: "timer")?.label, "Focus")
        XCTAssertEqual(metric(running, id: "timer")?.tone, .success)
        XCTAssertEqual(button(running)?.label, "Pause")

        // Pause after 60s of wall clock → 24:00 remaining, retained while paused.
        _ = try plugin.onEvent(toggleEvent(at: t0.addingTimeInterval(60)), context: context())
        XCTAssertFalse(plugin.needsTick(surfaceState: noSurfaces), "paused must not request ticks")
        let paused = try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext())
        XCTAssertEqual(metric(paused, id: "timer")?.label, "Paused")
        XCTAssertEqual(button(paused)?.label, "Start")
        XCTAssertEqual(metric(paused, id: "timer")?.value, "24:00")

        // Resume 100s later, then tick 1s in: continues from 24:00, not wall-clock-since-pause.
        _ = try plugin.onEvent(toggleEvent(at: t0.addingTimeInterval(160)), context: context())
        _ = try plugin.onEvent(tickEvent(at: t0.addingTimeInterval(161)), context: context())
        let resumed = try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext())
        XCTAssertEqual(metric(resumed, id: "timer")?.value, "23:59")
    }

    func testTickDerivesRemainingFromWallClockAndCatchesUp() throws {
        let plugin = PomodoroPlugin(workSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_000)

        // Idle: tick is a no-op.
        _ = try plugin.onEvent(tickEvent(at: t0), context: context())
        XCTAssertEqual(try timerValue(plugin), "01:30")

        // Running: remaining tracks the wall-clock delta, not a per-tick decrement.
        _ = try plugin.onEvent(toggleEvent(at: t0), context: context())   // end = t0+90
        _ = try plugin.onEvent(tickEvent(at: t0.addingTimeInterval(1)), context: context())
        XCTAssertEqual(try timerValue(plugin), "01:29")

        // A single tick after a 60s gap (e.g. sleep/throttle) catches up rather than drifting.
        _ = try plugin.onEvent(tickEvent(at: t0.addingTimeInterval(60)), context: context())
        XCTAssertEqual(try timerValue(plugin), "00:30")
    }

    func testCompletesWhenWallClockPassesEndAndCountsUp() throws {
        let plugin = PomodoroPlugin(workSeconds: 2)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = try plugin.onEvent(toggleEvent(at: t0), context: context())   // running, end = t0+2

        let beforeLast = try plugin.onEvent(tickEvent(at: t0.addingTimeInterval(1)), context: context())
        XCTAssertTrue(beforeLast.isEmpty, "no effect until the block completes")

        // Tick past the end (sleep-through) still completes exactly once.
        let onComplete = try plugin.onEvent(tickEvent(at: t0.addingTimeInterval(10)), context: context())
        XCTAssertEqual(onComplete.count, 1)
        XCTAssertEqual(onComplete.first?.capability, "notification.show")
        XCTAssertEqual(onComplete.first?.payload["title"], "Pomodoro")

        // After completion: idle, reset to full duration, count incremented.
        XCTAssertFalse(plugin.needsTick(surfaceState: noSurfaces))
        let menu = try plugin.makeUIContribution(for: .menubarMenu, context: uiContext())
        XCTAssertEqual(metric(menu, id: "timer")?.value, "00:02")
        XCTAssertEqual(metric(menu, id: "count")?.value, "1")
    }

    func testCompletionNotificationUsesPluginLanguage() throws {
        let plugin = PomodoroPlugin(workSeconds: 1)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = try plugin.onEvent(toggleEvent(at: t0), context: context(settings: [:]))

        let effects = try plugin.onEvent(
            tickEvent(at: t0.addingTimeInterval(1)),
            context: context(settings: [:], language: .korean)
        )

        XCTAssertEqual(effects.first?.payload["title"], "포모도로")
        XCTAssertEqual(effects.first?.payload["body"], "집중 세션이 완료되었습니다")
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

    func testRendersKoreanLabelsFromPluginContext() throws {
        let plugin = PomodoroPlugin()
        let notch = try XCTUnwrap(try plugin.makeUIContribution(
            for: .notchExpandedActivity,
            context: uiContext(language: .korean)
        ))
        XCTAssertEqual(metric(notch, id: "timer")?.label, "대기")
        XCTAssertEqual(button(notch)?.label, "시작")
    }

    // MARK: - Host integration

    /// The toggle action is `pluginEvent`-routed; it must come back only to Pomodoro
    /// and never reach another plugin that also listens for action events.
    func testHandleActionTogglesOnlyTargetPlugin() async {
        let original = L10n.shared.language
        L10n.shared.language = .english
        addTeardownBlock { L10n.shared.language = original }

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

    func testHostRebuildsContributionsWhenLanguageChanges() async {
        let original = L10n.shared.language
        L10n.shared.language = .english
        addTeardownBlock { L10n.shared.language = original }

        let pomodoro = PomodoroPlugin()
        let host = PluginHost()
        host.register([pomodoro])

        host.enqueue(makeBareEvent(kind: .pluginStarted))
        await host.waitUntilIdle()
        XCTAssertEqual(button(host.contributions[.notchExpandedActivity]?.first)?.label, "Start")

        L10n.shared.language = .korean
        host.pluginLanguageChanged()
        await host.waitUntilIdle()

        XCTAssertEqual(button(host.contributions[.notchExpandedActivity]?.first)?.label, "시작")
        XCTAssertEqual(host.pluginDisplayNames[pomodoro.manifest.id], "포모도로")
    }

    // MARK: - Settings (v1.3)

    func testWorkMinutesSettingChangesDurationWhenIdle() throws {
        let plugin = PomodoroPlugin()   // default 25:00
        let t0 = Date(timeIntervalSince1970: 1_000)

        _ = try plugin.onEvent(
            makeBareEvent(kind: .settingsChanged, at: t0),
            context: context(settings: ["workMinutes": .int(10)])
        )
        XCTAssertEqual(try timerValue(plugin), "10:00",
                       "a workMinutes change must reset the idle timer to the new duration")
    }

    func testWorkMinutesChangeMidRunDefersToNextBlock() throws {
        let plugin = PomodoroPlugin(workSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = try plugin.onEvent(toggleEvent(at: t0), context: context())              // running, end = t0+90
        _ = try plugin.onEvent(tickEvent(at: t0.addingTimeInterval(1)), context: context())  // 01:29

        // Changing the setting while running must not reset the active countdown to 05:00.
        _ = try plugin.onEvent(
            makeBareEvent(kind: .settingsChanged, at: t0.addingTimeInterval(2)),
            context: context(settings: ["workMinutes": .int(5)])
        )
        XCTAssertEqual(try timerValue(plugin), "01:29", "mid-run setting change must not reset the timer")
    }

    func testAutoRestartBeginsNewBlockOnCompletion() throws {
        let plugin = PomodoroPlugin(workSeconds: 2)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let settings: [String: PluginSettingValue] = ["autoRestart": .bool(true)]

        _ = try plugin.onEvent(toggleEvent(at: t0), context: context(settings: settings))   // running
        let onComplete = try plugin.onEvent(
            tickEvent(at: t0.addingTimeInterval(2)),
            context: context(settings: settings)
        )
        XCTAssertEqual(onComplete.first?.capability, "notification.show")
        XCTAssertTrue(plugin.needsTick(surfaceState: noSurfaces),
                      "auto-restart must immediately resume a running block")
        let running = try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext())
        XCTAssertEqual(metric(running, id: "timer")?.label, "Focus")
    }

    func testExposesSettingsSchema() {
        let schema = PomodoroPlugin().settingsSchema
        XCTAssertEqual(schema.map(\.key), ["workMinutes", "autoRestart"])
    }

    /// End-to-end: a stored setting resolved against the schema must drive the rendered
    /// contribution after a lifecycle event flows through the host.
    func testStoredSettingDrivesContributionThroughHost() async {
        let suiteName = "PomodoroPluginTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = PluginSettingsStore(userDefaults: defaults)
        store.setValue(.int(10), forKey: "workMinutes", pluginID: "com.devisland.pomodoro")

        let plugin = PomodoroPlugin()
        let host = PluginHost()
        host.register([plugin], settingsStore: store)

        host.enqueue(makeBareEvent(kind: .pluginStarted))
        await host.waitUntilIdle()

        let timer = host.contributions[.notchExpandedActivity]?.first?
            .components.first { $0.id == "timer" }
        XCTAssertEqual(timer?.value, "10:00",
                       "the resolved workMinutes setting must drive the contribution value")
    }

    // MARK: - Helpers

    private let noSurfaces = PluginSurfaceState(visibleSurfaces: [])

    private func context(
        settings: [String: PluginSettingValue] = [:],
        language: AppLanguage = .english
    ) -> PluginContext {
        PluginContext(
            pluginID: "com.devisland.pomodoro",
            permissions: [],
            storageSnapshot: [:],
            settings: settings,
            language: language
        )
    }

    private func uiContext(language: AppLanguage = .english) -> PluginUIContext {
        PluginUIContext(slot: .notchExpandedActivity, timestamp: Date(), session: nil, language: language)
    }

    private func tickEvent(at time: Date = Date()) -> PluginEvent { makeBareEvent(kind: .pluginTick, at: time) }

    private func toggleEvent(at time: Date = Date()) -> PluginEvent {
        PluginEvent(
            id: UUID(),
            kind: .pluginActionInvoked,
            timestamp: time,
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

    private func makeBareEvent(kind: PluginEventKind, at time: Date = Date()) -> PluginEvent {
        PluginEvent(id: UUID(), kind: kind, timestamp: time, session: nil, hook: nil, action: nil, approval: nil)
    }

    private func metric(_ contribution: PluginUIContribution?, id: String) -> PluginUIComponentDTO? {
        contribution?.components.first { $0.id == id && $0.type == .metric }
    }

    private func button(_ contribution: PluginUIContribution?) -> PluginUIComponentDTO? {
        contribution?.components.first { $0.type == .button }
    }

    private func timerValue(_ plugin: PomodoroPlugin) throws -> String? {
        let contribution = try plugin.makeUIContribution(for: .notchExpandedActivity, context: uiContext())
        return metric(contribution, id: "timer")?.value
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
