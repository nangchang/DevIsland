import XCTest
@testable import DevIsland

@MainActor
final class PluginHostDispatchTests: XCTestCase {
    func testZeroPluginsIsNoOp() async {
        let host = PluginHost()

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()

        XCTAssertTrue(host.contributions.isEmpty)
        XCTAssertTrue(host.failures.isEmpty)
    }

    func testEnqueuePreservesEventOrderForRunner() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.order",
            activationEvents: [.pluginStarted, .pluginTick]
        )
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()

        XCTAssertEqual(plugin.receivedKinds, [.pluginStarted, .pluginTick])
    }

    func testRunnerSpecificRedactionUsesRunnerPermissions() async {
        let limited = RecordingPlugin(
            id: "com.devisland.test.limited",
            permissions: [.readHookSummaries],
            activationEvents: [.hookReceived]
        )
        let full = RecordingPlugin(
            id: "com.devisland.test.full",
            permissions: [.readHookSummaries, .readTerminalMetadata],
            activationEvents: [.hookReceived]
        )
        let host = PluginHost()
        host.register([limited, full])

        host.enqueue(makeEvent(
            kind: .hookReceived,
            hook: PluginHookSummary(
                provider: "codex",
                eventType: "pretooluse",
                commandSummary: "Edit",
                cwd: "/Users/alice/project",
                terminalApp: "iTerm"
            )
        ))
        await host.waitUntilIdle()

        XCTAssertNil(limited.receivedEvents.first?.hook?.cwd)
        XCTAssertEqual(full.receivedEvents.first?.hook?.cwd, "/Users/alice/project")
    }

    func testActionEventDispatchesOnlyToTargetPlugin() async {
        let target = RecordingPlugin(
            id: "com.devisland.test.target",
            activationEvents: [.pluginActionInvoked]
        )
        let other = RecordingPlugin(
            id: "com.devisland.test.other",
            activationEvents: [.pluginActionInvoked]
        )
        let host = PluginHost()
        host.register([target, other])

        host.enqueue(makeEvent(
            kind: .pluginActionInvoked,
            action: PluginActionEvent(
                pluginID: "com.devisland.test.target",
                actionID: "toggle",
                componentID: "button",
                value: nil
            )
        ))
        await host.waitUntilIdle()

        XCTAssertEqual(target.receivedKinds, [.pluginActionInvoked])
        XCTAssertTrue(other.receivedEvents.isEmpty)
    }

    func testFailureClearsExistingContributions() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.failure",
            permissions: [.showNotchCard],
            activationEvents: [.pluginStarted, .pluginTick],
            contribution: makeContribution(pluginID: "com.devisland.test.failure"),
            throwOnKinds: [.pluginTick]
        )
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.notchExpandedActivity]?.count, 1)

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()

        XCTAssertTrue(host.contributions[.notchExpandedActivity]?.isEmpty ?? true)
        XCTAssertEqual(host.failures.last?.pluginID, "com.devisland.test.failure")
        XCTAssertEqual(host.failures.last?.clearsContribution, true)
    }

    func testSlowPluginRecordsTimeoutFailureWithoutClearingContribution() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.slow",
            permissions: [.showNotchCard],
            activationEvents: [.pluginStarted],
            contribution: makeContribution(pluginID: "com.devisland.test.slow"),
            delay: 0.06
        )
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()

        XCTAssertEqual(host.contributions[.notchExpandedActivity]?.count, 1)
        XCTAssertEqual(host.failures.last?.pluginID, "com.devisland.test.slow")
        XCTAssertEqual(host.failures.last?.clearsContribution, false)
    }

    func testRunnerDropsContributionForUnauthorizedSurface() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.surface",
            activationEvents: [.pluginStarted],
            contribution: makeContribution(
                pluginID: "com.devisland.test.surface",
                slot: .menubarMenu
            ),
            surfaces: [.menubarMenu]
        )
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()

        XCTAssertTrue(host.contributions.isEmpty)
    }

    func testEffectExecutorRejectsStorageEffectWithoutPermission() async {
        let storage = PluginStorageProvider()
        let executor = PluginEffectExecutor(storageProvider: storage)
        let effect = PluginEffect(capability: "storage.keyValue", payload: ["key": "count"])

        await executor.enqueue(
            [effect],
            pluginID: "com.devisland.test.storage",
            permissions: []
        )

        let applied = await storage.appliedStorageEffects()
        XCTAssertTrue(applied.isEmpty)
    }

    func testEffectExecutorAllowsStorageEffectWithPermission() async {
        let storage = PluginStorageProvider()
        let executor = PluginEffectExecutor(storageProvider: storage)
        let effect = PluginEffect(capability: "storage.keyValue", payload: ["key": "count"])

        await executor.enqueue(
            [effect],
            pluginID: "com.devisland.test.storage",
            permissions: [.writePluginStorage]
        )

        let applied = await storage.appliedStorageEffects()
        XCTAssertEqual(applied.count, 1)
    }

    private func makeEvent(
        kind: PluginEventKind,
        hook: PluginHookSummary? = nil,
        action: PluginActionEvent? = nil
    ) -> PluginEvent {
        PluginEvent(
            id: UUID(),
            kind: kind,
            timestamp: Date(),
            session: nil,
            hook: hook,
            action: action,
            approval: nil
        )
    }

    private func makeContribution(
        pluginID: String,
        slot: PluginUISlot = .notchExpandedActivity,
        targetSessionID: String? = nil
    ) -> PluginUIContribution {
        PluginUIContribution(
            pluginID: pluginID,
            slot: slot,
            targetSessionID: targetSessionID,
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
}

private final class RecordingPlugin: DevIslandPlugin, @unchecked Sendable {
    struct TestError: Error {}

    let manifest: PluginManifest
    let contribution: PluginUIContribution?
    let throwOnKinds: Set<PluginEventKind>
    let delay: TimeInterval
    private let lock = NSLock()
    private var _receivedEvents: [PluginEvent] = []
    var receivedEvents: [PluginEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedEvents
    }
    var receivedKinds: [PluginEventKind] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedEvents.map(\.kind)
    }

    init(
        id: String,
        permissions: Set<PluginPermission> = [],
        activationEvents: Set<PluginEventKind>,
        contribution: PluginUIContribution? = nil,
        surfaces: Set<PluginUISlot> = [.notchExpandedActivity],
        throwOnKinds: Set<PluginEventKind> = [],
        delay: TimeInterval = 0
    ) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: permissions,
            surfaces: surfaces,
            activationEvents: Set(activationEvents.map(\.rawValue))
        )
        self.contribution = contribution
        self.throwOnKinds = throwOnKinds
        self.delay = delay
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        if throwOnKinds.contains(event.kind) {
            throw TestError()
        }
        lock.lock()
        _receivedEvents.append(event)
        lock.unlock()
        return []
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        contribution
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}
