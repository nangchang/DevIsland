import XCTest
@testable import DevIsland

extension AppStateTests {
    // MARK: - Notification expand per-case settings

    @MainActor
    func testTaskCompletionExpandsWhenEnabled() {
        SettingsStore.shared.settings.notchAutoExpandEnabled = true
        SettingsStore.shared.settings.expandOnTaskCompletion = true
        defer { SettingsStore.shared.settings.expandOnTaskCompletion = true }

        let expectation = XCTestExpectation(description: "stop event processed")
        let message = """
        {
            "hook_event_name": "Stop",
            "session_id": "stop-expand-session",
            "tool_name": ""
        }
        """
        appState.handleMessage(message) { _ in expectation.fulfill() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(appState.isNotchExpanded, "notch should expand on task completion when expandOnTaskCompletion is enabled")
    }

    @MainActor
    func testTaskCompletionDoesNotExpandWhenDisabled() {
        SettingsStore.shared.settings.notchAutoExpandEnabled = true
        SettingsStore.shared.settings.expandOnTaskCompletion = false
        defer { SettingsStore.shared.settings.expandOnTaskCompletion = true }

        let expectation = XCTestExpectation(description: "stop event processed")
        let message = """
        {
            "hook_event_name": "Stop",
            "session_id": "stop-no-expand-session",
            "tool_name": ""
        }
        """
        appState.handleMessage(message) { _ in expectation.fulfill() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(appState.isNotchExpanded, "notch should NOT expand on task completion when expandOnTaskCompletion is disabled")
    }

    @MainActor
    func testIdlePromptExpandsWhenEnabled() {
        SettingsStore.shared.settings.notchAutoExpandEnabled = true
        SettingsStore.shared.settings.expandOnIdlePrompt = true
        defer { SettingsStore.shared.settings.expandOnIdlePrompt = true }

        let expectation = XCTestExpectation(description: "idle_prompt notification processed")
        let message = """
        {
            "hook_event_name": "Notification",
            "session_id": "idle-expand-session",
            "notification_type": "idle_prompt",
            "tool_name": ""
        }
        """
        appState.handleMessage(message) { _ in expectation.fulfill() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(appState.isNotchExpanded, "notch should expand on idle prompt when expandOnIdlePrompt is enabled")
    }

    @MainActor
    func testIdlePromptDoesNotExpandWhenDisabled() {
        SettingsStore.shared.settings.notchAutoExpandEnabled = true
        SettingsStore.shared.settings.expandOnIdlePrompt = false
        defer { SettingsStore.shared.settings.expandOnIdlePrompt = true }

        let expectation = XCTestExpectation(description: "idle_prompt notification processed")
        let message = """
        {
            "hook_event_name": "Notification",
            "session_id": "idle-no-expand-session",
            "notification_type": "idle_prompt",
            "tool_name": ""
        }
        """
        appState.handleMessage(message) { _ in expectation.fulfill() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(appState.isNotchExpanded, "notch should NOT expand on idle prompt when expandOnIdlePrompt is disabled")
    }

    @MainActor
    func testTaskCompletionSetsUnreadRegardlessOfExpandSetting() {
        SettingsStore.shared.settings.notchAutoExpandEnabled = true
        SettingsStore.shared.settings.expandOnTaskCompletion = false
        defer { SettingsStore.shared.settings.expandOnTaskCompletion = true }

        let sessionId = "stop-unread-session"
        // 세션을 먼저 시작해야 unread 상태가 기록됨
        let startExpectation = XCTestExpectation(description: "session started")
        appState.handleMessage("""
        {
            "hook_event_name": "SessionStart",
            "session_id": "\(sessionId)"
        }
        """) { _ in startExpectation.fulfill() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        wait(for: [startExpectation], timeout: 1.0)

        let stopExpectation = XCTestExpectation(description: "stop event processed")
        appState.handleMessage("""
        {
            "hook_event_name": "Stop",
            "session_id": "\(sessionId)",
            "tool_name": ""
        }
        """) { _ in stopExpectation.fulfill() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        wait(for: [stopExpectation], timeout: 1.0)

        XCTAssertFalse(appState.isNotchExpanded, "notch must not expand when expandOnTaskCompletion is disabled")
        let session = appState.sessionStore.activeSessions.first { $0.id == sessionId }
        XCTAssertTrue(session?.isUnread == true, "unread dot must be set regardless of expand setting")
    }

    /// Locks the lifecycle emission order: a plugin must observe `plugin.started`
    /// before `app.started` so it can restore state before app-level side effects.
    @MainActor
    func testStartPluginPlatformEmitsPluginStartedBeforeAppStarted() async {
        let plugin = LifecycleRecordingPlugin(id: "com.devisland.test.lifecycle-order")
        appState.pluginHost.register([plugin])

        appState.startPluginPlatform()
        await appState.pluginHost.waitUntilIdle()
        appState.stopPluginPlatform()

        XCTAssertEqual(plugin.receivedKinds, [.pluginStarted, .appStarted])
    }

    /// Mirrors AppDelegate launch ordering: compact visibility must be observed only after
    /// plugins have restored state in `plugin.started` and handled `app.started`.
    @MainActor
    func testCompactVisibilityRefreshFollowsPluginLifecycle() async {
        let plugin = LifecycleRecordingPlugin(id: "com.devisland.test.compact-launch-order")
        appState.pluginHost.register([plugin])
        appState.pluginHost.compactRegionSelectionProvider = {
            [.notchCompactCenter: plugin.manifest.id]
        }

        appState.startPluginPlatform()
        appState.pluginHost.compactRegionsBecameVisible()
        await appState.pluginHost.waitUntilIdle()
        appState.stopPluginPlatform()

        XCTAssertEqual(plugin.receivedKinds, [
            .pluginStarted,
            .appStarted,
            .compactRegionShown
        ])
    }
}

private final class LifecycleRecordingPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let receivedKindsStorage = LockIsolated<[PluginEventKind]>([])
    var receivedKinds: [PluginEventKind] {
        receivedKindsStorage.value
    }

    init(id: String) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [.showCompactRegion],
            surfaces: [],
            regions: [.notchCompactCenter],
            activationEvents: [
                PluginEventKind.pluginStarted.rawValue,
                PluginEventKind.appStarted.rawValue,
                PluginEventKind.compactRegionShown.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        receivedKindsStorage.withValue { $0.append(event.kind) }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        nil
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}
