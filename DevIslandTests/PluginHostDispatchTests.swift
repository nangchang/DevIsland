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
                capability: "timer.startStop",
                payload: [:],
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
            delay: 0.12
        )
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()

        XCTAssertEqual(host.contributions[.notchExpandedActivity]?.count, 1)
        XCTAssertEqual(host.failures.last?.pluginID, "com.devisland.test.slow")
        XCTAssertEqual(host.failures.last?.clearsContribution, false)
    }

    func testNilContributionClearsPreviousContribution() async {
        let plugin = ToggleContributionPlugin(
            id: "com.devisland.test.toggle",
            permissions: [.showNotchCard]
        )
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.notchExpandedActivity]?.count, 1)

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()

        XCTAssertTrue(host.contributions[.notchExpandedActivity]?.isEmpty ?? true)
    }

    func testExpiredContributionIsPrunedFromHostCache() async {
        let plugin = ExpiringContributionPlugin(
            id: "com.devisland.test.expired",
            permissions: [.showNotchCard]
        )
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()

        XCTAssertTrue(host.contributions[.notchExpandedActivity]?.isEmpty ?? true)
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

    func testEffectExecutorRejectsUnsupportedHostEffect() async {
        let storage = PluginStorageProvider()
        let executor = PluginEffectExecutor(storageProvider: storage)
        let effect = PluginEffect(capability: "notification.show", payload: ["title": "Done"])

        await executor.enqueue(
            [effect],
            pluginID: "com.devisland.test.notification",
            permissions: [.showNotification]
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

    func testHostExecutedActionAppliesStorageEffect() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.host-action",
            permissions: [.writePluginStorage],
            activationEvents: [.pluginActionInvoked]
        )
        let host = PluginHost()
        host.register([plugin])

        let action = PluginUIActionDTO(
            id: "store",
            capability: "storage.keyValue",
            routing: .hostExecuted,
            payload: ["key": "count"]
        )
        host.handleAction(action, from: "com.devisland.test.host-action", componentID: "store")

        let deadline = Date().addingTimeInterval(1)
        var applied: [(pluginID: String, effect: PluginEffect)] = []
        repeat {
            applied = await host.appliedStorageEffects()
            if !applied.isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while applied.isEmpty && Date() < deadline

        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.pluginID, "com.devisland.test.host-action")
        XCTAssertEqual(applied.first?.effect.capability, "storage.keyValue")
    }

    func testGlobalContributionsDeduplicateByPluginOnly() async {
        let plugin = RotatingContributionPlugin(
            id: "com.devisland.test.global-dedupe",
            slot: .menubarMenu,
            targetSessionIDs: ["session-a", "session-b"],
            permissions: [.showMenubarMenu]
        )
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()
        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()

        let contributions = host.contributions[.menubarMenu] ?? []
        XCTAssertEqual(contributions.count, 1)
        XCTAssertEqual(contributions.first?.targetSessionID, "session-b")
    }

    func testSessionScopedContributionsCoexistAcrossSessions() async {
        let plugin = SessionScopedContributionPlugin(id: "com.devisland.test.session-scope")
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .sessionUpdated, sessionID: "session-a"))
        await host.waitUntilIdle()
        host.enqueue(makeEvent(kind: .sessionUpdated, sessionID: "session-b"))
        await host.waitUntilIdle()

        let contributions = host.contributions[.sessionDetailSummary] ?? []
        XCTAssertEqual(contributions.count, 2)
        XCTAssertEqual(Set(contributions.compactMap(\.targetSessionID)), ["session-a", "session-b"])
    }

    func testNilSessionScopedContributionClearsOnlyMatchingSession() async {
        let plugin = ToggleSessionScopedContributionPlugin(id: "com.devisland.test.session-toggle")
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .sessionUpdated, sessionID: "session-a"))
        await host.waitUntilIdle()
        host.enqueue(makeEvent(kind: .sessionUpdated, sessionID: "session-b"))
        await host.waitUntilIdle()

        var contributions = host.contributions[.sessionDetailSummary] ?? []
        XCTAssertEqual(contributions.count, 2)

        host.enqueue(makeEvent(kind: .pluginTick, sessionID: "session-a"))
        await host.waitUntilIdle()

        contributions = host.contributions[.sessionDetailSummary] ?? []
        XCTAssertEqual(contributions.count, 1)
        XCTAssertEqual(contributions.first?.targetSessionID, "session-b")
    }

    private func makeEvent(
        kind: PluginEventKind,
        sessionID: String? = nil,
        hook: PluginHookSummary? = nil,
        action: PluginActionEvent? = nil
    ) -> PluginEvent {
        PluginEvent(
            id: UUID(),
            kind: kind,
            timestamp: Date(),
            session: sessionID.map(makeSessionSnapshot),
            hook: hook,
            action: action,
            approval: nil
        )
    }

    private func makeSessionSnapshot(id: String) -> PluginSessionSnapshot {
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

private final class RotatingContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let lock = NSLock()
    private let slot: PluginUISlot
    private let targetSessionIDs: [String?]
    private var index = 0

    init(
        id: String,
        slot: PluginUISlot,
        targetSessionIDs: [String?],
        permissions: Set<PluginPermission>
    ) {
        self.slot = slot
        self.targetSessionIDs = targetSessionIDs
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: permissions,
            surfaces: [slot],
            activationEvents: [
                PluginEventKind.pluginStarted.rawValue,
                PluginEventKind.pluginTick.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        []
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        lock.lock()
        let targetSessionID = targetSessionIDs[min(index, targetSessionIDs.count - 1)]
        index += 1
        lock.unlock()

        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: targetSessionID,
            priority: 10,
            expiresAt: nil,
            components: [
                PluginUIComponentDTO(
                    id: "status",
                    type: .text,
                    label: "Status",
                    value: targetSessionID ?? "global",
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

private final class ToggleContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let lock = NSLock()
    private var shouldRender = true

    init(id: String, permissions: Set<PluginPermission>) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: permissions,
            surfaces: [.notchExpandedActivity],
            activationEvents: [
                PluginEventKind.pluginStarted.rawValue,
                PluginEventKind.pluginTick.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        if event.kind == .pluginTick {
            lock.lock()
            shouldRender = false
            lock.unlock()
        }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        lock.lock()
        let render = shouldRender
        lock.unlock()
        guard render else { return nil }

        return PluginUIContribution(
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
        false
    }
}

private final class ExpiringContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest

    init(id: String, permissions: Set<PluginPermission>) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: permissions,
            surfaces: [.notchExpandedActivity],
            activationEvents: [PluginEventKind.pluginStarted.rawValue]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: nil,
            priority: 10,
            expiresAt: Date(timeIntervalSinceNow: -1),
            components: [
                PluginUIComponentDTO(
                    id: "status",
                    type: .text,
                    label: "Expired",
                    value: nil,
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

private final class SessionScopedContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest

    init(id: String) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [.readSessionEvents, .showSessionSurface],
            surfaces: [.sessionDetailSummary],
            activationEvents: [PluginEventKind.sessionUpdated.rawValue]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        guard let sessionID = context.session?.id else { return nil }
        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: sessionID,
            priority: 10,
            expiresAt: nil,
            components: [
                PluginUIComponentDTO(
                    id: "summary-\(sessionID)",
                    type: .text,
                    label: sessionID,
                    value: "Active",
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

private final class ToggleSessionScopedContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let lock = NSLock()
    private var hiddenSessionIDs: Set<String> = []

    init(id: String) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [.readSessionEvents, .showSessionSurface],
            surfaces: [.sessionDetailSummary],
            activationEvents: [
                PluginEventKind.sessionUpdated.rawValue,
                PluginEventKind.pluginTick.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        if event.kind == .pluginTick, let sessionID = event.session?.id {
            lock.lock()
            hiddenSessionIDs.insert(sessionID)
            lock.unlock()
        }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        guard let sessionID = context.session?.id else { return nil }
        lock.lock()
        let shouldHide = hiddenSessionIDs.contains(sessionID)
        lock.unlock()
        guard !shouldHide else { return nil }

        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: sessionID,
            priority: 10,
            expiresAt: nil,
            components: [
                PluginUIComponentDTO(
                    id: "summary-\(sessionID)",
                    type: .text,
                    label: sessionID,
                    value: "Active",
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}
