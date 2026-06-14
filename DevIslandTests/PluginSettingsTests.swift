import XCTest
@testable import DevIsland

@MainActor
final class PluginSettingsTests: XCTestCase {

    // MARK: - PluginSettingsStore persistence

    func testSetEnabledPersistsAcrossStores() {
        let suiteName = "PluginSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginSettingsStore(userDefaults: defaults)
        XCTAssertTrue(store.isEnabled("com.devisland.test.a"))

        store.setEnabled(false, pluginID: "com.devisland.test.a")
        XCTAssertFalse(store.isEnabled("com.devisland.test.a"))

        let reopened = PluginSettingsStore(userDefaults: defaults)
        XCTAssertFalse(reopened.isEnabled("com.devisland.test.a"),
                       "disabled state must survive a fresh store reading the same defaults")
    }

    // MARK: - Disable removes contributions / excludes dispatch

    func testDisableRemovesContributions() async {
        let plugin = SettingsTestPlugin(id: "com.devisland.test.disable")
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.notchExpandedActivity]?.count, 1)

        host.setPluginEnabled(false, pluginID: plugin.manifest.id)

        XCTAssertTrue(host.contributions[.notchExpandedActivity]?.isEmpty ?? true)
        XCTAssertFalse(host.isPluginEnabled(plugin.manifest.id))
    }

    func testDisabledPluginExcludedFromTick() async {
        let plugin = SettingsTestPlugin(id: "com.devisland.test.tick", needsTick: true)
        let host = PluginHost()
        host.register([plugin])
        host.setVisibleSurfaces([.notchExpandedActivity])

        host.setPluginEnabled(false, pluginID: plugin.manifest.id)
        await host.tickIfNeeded()
        await host.waitUntilIdle()

        XCTAssertFalse(plugin.receivedKinds.contains(.pluginTick))
    }

    func testDisabledAtRegistrationSkipsLifecycle() async {
        let plugin = SettingsTestPlugin(id: "com.devisland.test.preDisabled")
        let host = PluginHost()
        host.register([plugin], disabledPluginIDs: [plugin.manifest.id])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()

        XCTAssertTrue(plugin.receivedKinds.isEmpty,
                      "a plugin disabled at registration must not run on the first lifecycle event")
        XCTAssertTrue(host.contributions.isEmpty)
    }

    // MARK: - Enable re-emits a targeted plugin.started

    func testEnableEmitsPluginStartedToThatPluginOnly() async {
        let target = SettingsTestPlugin(id: "com.devisland.test.target")
        let other = SettingsTestPlugin(id: "com.devisland.test.other")
        let host = PluginHost()
        host.register([target, other])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()
        XCTAssertEqual(target.receivedKinds, [.pluginStarted])
        XCTAssertEqual(other.receivedKinds, [.pluginStarted])

        host.setPluginEnabled(false, pluginID: target.manifest.id)
        host.setPluginEnabled(true, pluginID: target.manifest.id)
        await host.waitUntilIdle()

        XCTAssertEqual(target.receivedKinds, [.pluginStarted, .pluginStarted],
                       "re-enabling must replay plugin.started to the re-enabled plugin")
        XCTAssertEqual(other.receivedKinds, [.pluginStarted],
                       "re-enabling one plugin must not re-fire plugin.started to others")
    }

    // MARK: - Safemode entry + reset

    func testSafemodeEntryClearsContributionsAndExcludesDispatch() async {
        let plugin = SettingsTestPlugin(
            id: "com.devisland.test.safemode",
            activationEvents: [.pluginStarted, .pluginTick]
        )
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.notchExpandedActivity]?.count, 1)

        host.enterSafemode(pluginID: plugin.manifest.id)
        XCTAssertTrue(host.isInSafemode(plugin.manifest.id))
        XCTAssertTrue(host.contributions[.notchExpandedActivity]?.isEmpty ?? true)

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()
        XCTAssertFalse(plugin.receivedKinds.contains(.pluginTick),
                       "a safemode plugin must not receive further events")
    }

    func testResetPluginClearsSafemodeAndFailures() async {
        let plugin = SettingsTestPlugin(id: "com.devisland.test.reset", throwOnStart: true)
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()
        XCTAssertEqual(host.failures.filter { $0.pluginID == plugin.manifest.id }.count, 1)

        host.enterSafemode(pluginID: plugin.manifest.id)
        host.resetPlugin(pluginID: plugin.manifest.id)

        XCTAssertFalse(host.isInSafemode(plugin.manifest.id))
        XCTAssertTrue(host.failures.filter { $0.pluginID == plugin.manifest.id }.isEmpty,
                      "reset must clear the plugin's recorded failures so the UI count resets")
    }

    // MARK: - Storage reset via host

    func testResetStorageClearsPluginData() async {
        let plugin = SettingsTestPlugin(
            id: "com.devisland.test.storage",
            permissions: [.showNotchCard, .writePluginStorage],
            activationEvents: [.pluginActionInvoked]
        )
        let host = PluginHost(pluginDataDirectory: makeTempStorageDirectory())
        host.register([plugin])

        let write = PluginUIActionDTO(
            id: "store",
            capability: "storage.keyValue",
            routing: .hostExecuted,
            payload: ["key": "count", "value": "5"]
        )
        host.handleAction(write, from: plugin.manifest.id, componentID: "store")
        try? await waitFor { await host.pluginStorageSnapshot(forPluginID: plugin.manifest.id)["count"] == "5" }

        host.resetStorage(forPluginID: plugin.manifest.id)
        try? await waitFor { await host.pluginStorageSnapshot(forPluginID: plugin.manifest.id).isEmpty }

        let snapshot = await host.pluginStorageSnapshot(forPluginID: plugin.manifest.id)
        XCTAssertTrue(snapshot.isEmpty, "reset must wipe the plugin's durable storage")
    }

    // MARK: - Settings schema (v1.3)

    func testPluginSettingValueCodableRoundTrip() throws {
        let values: [PluginSettingValue] = [.bool(true), .int(42), .double(3.5), .string("hi")]
        for value in values {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(PluginSettingValue.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    func testDescriptorValidatedFallbackClampAndTruncate() {
        let toggle = PluginSettingDescriptor(key: "t", label: "T", kind: .toggle, defaultValue: .bool(false))
        XCTAssertEqual(toggle.validated(.bool(true)), .bool(true))
        XCTAssertEqual(toggle.validated(.int(1)), .bool(false), "wrong kind falls back to default")
        XCTAssertEqual(toggle.validated(nil), .bool(false), "missing value falls back to default")

        let stepper = PluginSettingDescriptor(key: "s", label: "S",
            kind: .stepper(range: 1...10, step: 1), defaultValue: .int(5))
        XCTAssertEqual(stepper.validated(.int(20)), .int(10), "clamp to upper bound")
        XCTAssertEqual(stepper.validated(.int(0)), .int(1), "clamp to lower bound")
        XCTAssertEqual(stepper.validated(.string("x")), .int(5), "wrong kind falls back to default")

        let slider = PluginSettingDescriptor(key: "d", label: "D",
            kind: .slider(range: 0...1, step: 0.1), defaultValue: .double(0.5))
        XCTAssertEqual(slider.validated(.double(2)), .double(1))
        XCTAssertEqual(slider.validated(.double(-1)), .double(0))

        let picker = PluginSettingDescriptor(key: "p", label: "P",
            kind: .picker(options: [.init(value: "a", label: "A"), .init(value: "b", label: "B")]),
            defaultValue: .string("a"))
        XCTAssertEqual(picker.validated(.string("b")), .string("b"))
        XCTAssertEqual(picker.validated(.string("z")), .string("a"), "value outside options falls back")

        let text = PluginSettingDescriptor(key: "x", label: "X",
            kind: .text(maxLength: 3), defaultValue: .string(""))
        XCTAssertEqual(text.validated(.string("abcdef")), .string("abc"), "truncate to maxLength")
    }

    func testSettingsStorePersistsAndIsolatesPerPlugin() {
        let suiteName = "PluginSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginSettingsStore(userDefaults: defaults)
        store.setValue(.int(10), forKey: "workMinutes", pluginID: "a")
        store.setValue(.bool(true), forKey: "flag", pluginID: "b")

        XCTAssertEqual(store.value(forKey: "workMinutes", pluginID: "a"), .int(10))
        XCTAssertNil(store.value(forKey: "workMinutes", pluginID: "b"),
                     "settings must not leak across plugins")

        let reopened = PluginSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reopened.value(forKey: "workMinutes", pluginID: "a"), .int(10),
                       "settings must survive a fresh store reading the same defaults")
        XCTAssertEqual(reopened.value(forKey: "flag", pluginID: "b"), .bool(true))
    }

    func testResetSettingsClearsPluginValues() {
        let suiteName = "PluginSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginSettingsStore(userDefaults: defaults)
        store.setValue(.int(10), forKey: "workMinutes", pluginID: "a")
        store.resetSettings(forPluginID: "a")
        XCTAssertNil(store.value(forKey: "workMinutes", pluginID: "a"))
    }

    func testSettingChangedRestrictedToTargetPlugin() async {
        let target = SettingsTestPlugin(id: "com.devisland.test.scTarget",
            activationEvents: [.pluginStarted, .settingsChanged])
        let other = SettingsTestPlugin(id: "com.devisland.test.scOther",
            activationEvents: [.pluginStarted, .settingsChanged])
        let host = PluginHost()
        host.register([target, other])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()

        host.pluginSettingChanged(pluginID: target.manifest.id)
        await host.waitUntilIdle()

        XCTAssertTrue(target.receivedKinds.contains(.settingsChanged))
        XCTAssertFalse(other.receivedKinds.contains(.settingsChanged),
                       "settings.changed must reach only the plugin whose settings changed")
    }

    // MARK: - Helpers

    private func waitFor(
        timeout: TimeInterval = 1,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    private func makeTempStorageDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginSettingsTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeEvent(kind: PluginEventKind) -> PluginEvent {
        PluginEvent(
            id: UUID(),
            kind: kind,
            timestamp: Date(),
            session: nil,
            hook: nil,
            action: nil,
            approval: nil
        )
    }
}

private final class SettingsTestPlugin: DevIslandPlugin, @unchecked Sendable {
    struct StartError: Error {}

    let manifest: PluginManifest
    private let needsTickValue: Bool
    private let throwOnStart: Bool
    private let lock = NSLock()
    private var _receivedKinds: [PluginEventKind] = []

    var receivedKinds: [PluginEventKind] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedKinds
    }

    init(
        id: String,
        permissions: Set<PluginPermission> = [.showNotchCard],
        activationEvents: Set<PluginEventKind> = [.pluginStarted, .pluginTick],
        needsTick: Bool = false,
        throwOnStart: Bool = false
    ) {
        self.needsTickValue = needsTick
        self.throwOnStart = throwOnStart
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: permissions,
            surfaces: [.notchExpandedActivity],
            activationEvents: Set(activationEvents.map(\.rawValue))
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        if throwOnStart, event.kind == .pluginStarted {
            throw StartError()
        }
        lock.lock()
        _receivedKinds.append(event.kind)
        lock.unlock()
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: nil,
            priority: 10,
            expiresAt: nil,
            components: [
                PluginUIComponentDTO(
                    id: "status",
                    type: .text,
                    label: "Status",
                    value: "Ready",
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        needsTickValue && surfaceState.visibleSurfaces.contains(.notchExpandedActivity)
    }
}
