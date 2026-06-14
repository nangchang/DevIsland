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

    func testPluginDisplayNamesAreCachedOnRegister() {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.display",
            name: "Display Plugin",
            activationEvents: [.pluginStarted]
        )
        let host = PluginHost()

        XCTAssertTrue(host.pluginDisplayNames.isEmpty)
        host.register([plugin])

        XCTAssertEqual(host.pluginDisplayNames, ["com.devisland.test.display": "Display Plugin"])
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
                terminalApp: "iTerm",
                rawEvent: nil,
                toolName: nil,
                notificationType: nil,
                message: nil,
                payload: nil
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
        let storage = PluginStorageProvider(baseDirectory: makeTempStorageDirectory())
        let executor = PluginEffectExecutor(storageProvider: storage)
        let effect = PluginEffect(capability: "storage.keyValue", payload: ["key": "count", "value": "5"])

        await executor.enqueue(
            [effect],
            pluginID: "com.devisland.test.storage",
            permissions: []
        )

        let snapshot = await storage.snapshot(forPluginID: "com.devisland.test.storage")
        XCTAssertTrue(snapshot.isEmpty, "storage write must be rejected without writePluginStorage")
    }

    func testEffectExecutorRejectsUnsupportedHostEffect() async {
        let storage = PluginStorageProvider(baseDirectory: makeTempStorageDirectory())
        let executor = PluginEffectExecutor(storageProvider: storage)
        let effect = PluginEffect(capability: "power.preventIdleSleep", payload: [:])

        await executor.enqueue(
            [effect],
            pluginID: "com.devisland.test.power",
            permissions: [.showNotification]
        )

        let snapshot = await storage.snapshot(forPluginID: "com.devisland.test.power")
        XCTAssertTrue(snapshot.isEmpty, "an unsupported capability must not write storage")
    }

    func testEffectExecutorDeliversNotificationEffect() async {
        let storage = PluginStorageProvider()
        let delivered = LockIsolated<[String]>([])
        let executor = PluginEffectExecutor(
            storageProvider: storage,
            notificationHandler: { title, body in
                delivered.withValue { $0.append([title, body].compactMap { $0 }.joined(separator: " :: ")) }
            }
        )
        let effect = PluginEffect(
            capability: "notification.show",
            payload: ["title": "Done", "body": "Focus session complete"]
        )

        await executor.enqueue(
            [effect],
            pluginID: "com.devisland.test.notification",
            permissions: [.showNotification]
        )

        XCTAssertEqual(delivered.value, ["Done :: Focus session complete"])
    }

    func testEffectExecutorPromotesBodyOnlyNotificationToTitle() async {
        let storage = PluginStorageProvider()
        let delivered = LockIsolated<[String]>([])
        let executor = PluginEffectExecutor(
            storageProvider: storage,
            notificationHandler: { title, body in
                delivered.withValue { $0.append([title, body].compactMap { $0 }.joined(separator: " :: ")) }
            }
        )
        let effect = PluginEffect(
            capability: "notification.show",
            payload: ["body": "Focus session complete"]
        )

        await executor.enqueue(
            [effect],
            pluginID: "com.devisland.test.notification",
            permissions: [.showNotification]
        )

        XCTAssertEqual(delivered.value, ["Focus session complete"])
    }

    func testEffectExecutorPlaysScopedAudioFileWithPermission() async throws {
        let root = makeTempStorageDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("sound".utf8).write(to: root.appendingPathComponent("done.wav"))
        let broker = PluginScopedFileBroker(scopesByPluginID: [
            "openpeon": [
                PluginScopedFileScope(id: "packs", baseDirectory: root)
            ]
        ])
        let delivered = LockIsolated<[(String, Float)]>([])
        let executor = PluginEffectExecutor(
            storageProvider: PluginStorageProvider(),
            scopedFileBroker: broker,
            audioPlayHandler: { url, volume in
                delivered.withValue { $0.append((url.lastPathComponent, volume)) }
            }
        )
        let effect = PluginEffect(
            capability: "audio.playFile",
            payload: ["scope": "packs", "path": "done.wav", "volume": "0.5"]
        )

        await executor.enqueue(
            [effect],
            pluginID: "openpeon",
            permissions: Set<PluginPermission>([.playScopedAudio])
        )

        XCTAssertEqual(delivered.value.map(\.0), ["done.wav"])
        XCTAssertEqual(delivered.value.first?.1, 0.5)
    }

    func testEffectExecutorRejectsScopedAudioWithoutPermission() async throws {
        let root = makeTempStorageDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("sound".utf8).write(to: root.appendingPathComponent("done.wav"))
        let broker = PluginScopedFileBroker(scopesByPluginID: [
            "openpeon": [
                PluginScopedFileScope(id: "packs", baseDirectory: root)
            ]
        ])
        let delivered = LockIsolated<[String]>([])
        let executor = PluginEffectExecutor(
            storageProvider: PluginStorageProvider(),
            scopedFileBroker: broker,
            audioPlayHandler: { url, _ in
                delivered.withValue { $0.append(url.lastPathComponent) }
            }
        )

        await executor.enqueue(
            [PluginEffect(capability: "audio.playFile", payload: ["scope": "packs", "path": "done.wav"])],
            pluginID: "openpeon",
            permissions: Set<PluginPermission>([.playSound])
        )

        XCTAssertTrue(delivered.value.isEmpty)
    }

    func testPluginContextProvidesScopedFileClientWhenPermitted() async throws {
        let root = makeTempStorageDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("manifest.txt"))
        let broker = PluginScopedFileBroker(scopesByPluginID: [
            "com.devisland.test.scoped-reader": [
                PluginScopedFileScope(id: "packs", baseDirectory: root)
            ]
        ])
        let plugin = ScopedReaderPlugin(
            id: "com.devisland.test.scoped-reader",
            permissions: [.readScopedFiles]
        )
        let host = PluginHost(scopedFileBroker: broker)
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()

        XCTAssertEqual(plugin.readText, "hello")
    }

    func testPluginContextOmitsScopedFileClientWithoutPermission() async {
        let plugin = ScopedReaderPlugin(id: "com.devisland.test.no-scope", permissions: [])
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()

        XCTAssertNil(plugin.readText)
        XCTAssertTrue(plugin.sawMissingClient)
    }

    func testEffectExecutorAllowsStorageEffectWithPermission() async {
        let storage = PluginStorageProvider(baseDirectory: makeTempStorageDirectory())
        let executor = PluginEffectExecutor(storageProvider: storage)
        let effect = PluginEffect(capability: "storage.keyValue", payload: ["key": "count", "value": "5"])

        await executor.enqueue(
            [effect],
            pluginID: "com.devisland.test.storage",
            permissions: [.writePluginStorage]
        )

        let snapshot = await storage.snapshot(forPluginID: "com.devisland.test.storage")
        XCTAssertEqual(snapshot["count"], "5")
    }

    func testHostExecutedActionAppliesStorageEffect() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.host-action",
            permissions: [.writePluginStorage],
            activationEvents: [.pluginActionInvoked]
        )
        let host = PluginHost(pluginDataDirectory: makeTempStorageDirectory())
        host.register([plugin])

        let action = PluginUIActionDTO(
            id: "store",
            capability: "storage.keyValue",
            routing: .hostExecuted,
            payload: ["key": "count", "value": "5"]
        )
        host.handleAction(action, from: "com.devisland.test.host-action", componentID: "store")

        let deadline = Date().addingTimeInterval(1)
        var stored: String?
        repeat {
            stored = await host.pluginStorageSnapshot(forPluginID: "com.devisland.test.host-action")["count"]
            if stored != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while stored == nil && Date() < deadline

        XCTAssertEqual(stored, "5", "host-executed storage effect must persist the value")
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

    func testGlobalEventPreservesSessionScopedContributionCache() async {
        let plugin = GlobalToggleSessionScopedContributionPlugin(id: "com.devisland.test.session-global-toggle")
        let host = PluginHost()
        host.register([plugin])

        host.enqueue(makeEvent(kind: .sessionUpdated, sessionID: "session-a"))
        await host.waitUntilIdle()
        host.enqueue(makeEvent(kind: .sessionUpdated, sessionID: "session-b"))
        await host.waitUntilIdle()

        var contributions = host.contributions[.sessionDetailSummary] ?? []
        XCTAssertEqual(contributions.count, 2)

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()

        contributions = host.contributions[.sessionDetailSummary] ?? []
        XCTAssertEqual(contributions.count, 2)
        XCTAssertEqual(Set(contributions.compactMap(\.targetSessionID)), ["session-a", "session-b"])
    }

    func testTickSkippedWhenNoVisibleSurface() async {
        let plugin = VisibilityTickingPlugin(id: "com.devisland.test.tick-hidden")
        let host = PluginHost()
        host.register([plugin])

        host.setVisibleSurfaces([])
        await host.tickIfNeeded()
        await host.waitUntilIdle()

        XCTAssertFalse(plugin.receivedKinds.contains(.pluginTick))
    }

    func testTickEmittedWhenSurfaceBecomesVisible() async {
        let plugin = VisibilityTickingPlugin(id: "com.devisland.test.tick-visible")
        let host = PluginHost()
        host.register([plugin])

        host.setVisibleSurfaces([])
        await host.tickIfNeeded()
        await host.waitUntilIdle()
        XCTAssertFalse(plugin.receivedKinds.contains(.pluginTick))

        host.setVisibleSurfaces([.notchExpandedActivity])
        await host.tickIfNeeded()
        await host.waitUntilIdle()
        XCTAssertEqual(plugin.receivedKinds, [.pluginTick])
    }

    func testStartTickingStartsOnlyOnce() {
        let host = PluginHost()

        host.startTicking()
        host.startTicking()

        XCTAssertEqual(host.tickStartCount, 1)
        host.stopTicking()
    }

    func testDisabledHostDoesNotTick() async {
        let plugin = VisibilityTickingPlugin(id: "com.devisland.test.tick-disabled")
        let host = PluginHost(enablePlugins: false)
        host.register([plugin])

        host.startTicking()
        XCTAssertEqual(host.tickStartCount, 0)

        host.setVisibleSurfaces([.notchExpandedActivity])
        await host.tickIfNeeded()
        await host.waitUntilIdle()
        XCTAssertFalse(plugin.receivedKinds.contains(.pluginTick))
    }

    func testTickFansOutToSessionScopedSlotsForActiveSessions() async {
        let plugin = SessionRowTickPlugin(id: "com.devisland.test.rowtick")
        let host = PluginHost()
        host.register([plugin])
        host.setVisibleSurfaces([.notchSessionRow])
        let snapshot = PluginSessionSnapshot(
            id: "s1", agentKind: "codex", startTime: Date(), lastActiveAt: Date(),
            lastToolName: nil, lastEventName: nil, workspaceRoot: nil)
        host.activeSessionsProvider = { [snapshot] }

        host.enqueue(PluginEvent(id: UUID(), kind: .sessionStarted, timestamp: Date(), session: snapshot))
        await host.waitUntilIdle()
        let before = host.contributions[.notchSessionRow]?.first?.components.first?.value
        XCTAssertNotNil(before, "an active session contributes a row badge")

        await host.tickIfNeeded()
        await host.waitUntilIdle()
        let after = host.contributions[.notchSessionRow]?.first?.components.first?.value

        XCTAssertNotEqual(before, after,
                          "a session-bearing tick must re-evaluate the session-scoped row slot")
    }

    func testTickDoesNotFanOutToGlobalOnlyPlugin() async {
        let plugin = VisibilityTickingPlugin(id: "com.devisland.test.tick-global")
        let host = PluginHost()
        host.register([plugin])
        host.setVisibleSurfaces([.notchExpandedActivity])
        host.activeSessionsProvider = {
            [PluginSessionSnapshot(id: "s1", agentKind: "codex", startTime: Date(), lastActiveAt: Date(),
                lastToolName: nil, lastEventName: nil, workspaceRoot: nil)]
        }

        await host.tickIfNeeded()
        await host.waitUntilIdle()
        XCTAssertEqual(plugin.receivedKinds.filter { $0 == .pluginTick }.count, 1,
                       "a plugin with no session-scoped surface gets only the session-less tick")
    }

    func testLanguageChangedSessionFanoutIsLimitedToSessionScopedPlugins() async {
        let global = RecordingPlugin(
            id: "com.devisland.test.language-global",
            activationEvents: [.languageChanged],
            surfaces: [.menubarMenu]
        )
        let sessionScoped = RecordingPlugin(
            id: "com.devisland.test.language-session",
            permissions: [.readSessionEvents, .showSessionSurface],
            activationEvents: [.languageChanged],
            surfaces: [.sessionMessage]
        )
        let host = PluginHost()
        host.register([global, sessionScoped])
        host.activeSessionsProvider = {
            [self.makeSessionSnapshot(id: "s1"), self.makeSessionSnapshot(id: "s2")]
        }

        host.pluginLanguageChanged()
        await host.waitUntilIdle()

        XCTAssertEqual(global.receivedKinds.filter { $0 == .languageChanged }.count, 1,
                       "global-only plugins must not infer active-session count from fan-out")
        XCTAssertEqual(sessionScoped.receivedKinds.filter { $0 == .languageChanged }.count, 3,
                       "session-scoped plugins get the global rebuild plus one session-bearing rebuild per active session")
    }

    func testSafemodeTriggeredAfterThreeErrorsWithinSixtySeconds() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.safemode.errors",
            permissions: [.showNotchCard],
            activationEvents: [.pluginStarted, .pluginTick],
            contribution: makeContribution(pluginID: "com.devisland.test.safemode.errors"),
            throwOnKinds: [.pluginTick]
        )
        let defaults = UserDefaults(suiteName: "PluginHostDispatchTests.safemode.errors")!
        defaults.removePersistentDomain(forName: "PluginHostDispatchTests.safemode.errors")
        let settings = PluginSettingsStore(userDefaults: defaults)
        
        let host = PluginHost()
        host.register([plugin], settingsStore: settings)

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.notchExpandedActivity]?.count, 1)
        XCTAssertFalse(host.isInSafemode("com.devisland.test.safemode.errors"))

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()
        XCTAssertTrue(host.contributions[.notchExpandedActivity]?.isEmpty ?? true)
        XCTAssertFalse(host.isInSafemode("com.devisland.test.safemode.errors"))

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()
        XCTAssertFalse(host.isInSafemode("com.devisland.test.safemode.errors"))

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()
        XCTAssertTrue(host.isInSafemode("com.devisland.test.safemode.errors"))
        XCTAssertTrue(settings.safemodePluginIDs.contains("com.devisland.test.safemode.errors"))
    }

    func testSafemodeTriggeredAfterThreeTimeoutsWithinSixtySeconds() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.safemode.timeouts",
            permissions: [.showNotchCard],
            activationEvents: [.pluginStarted, .pluginTick],
            contribution: makeContribution(pluginID: "com.devisland.test.safemode.timeouts"),
            delay: 0.06
        )
        let defaults = UserDefaults(suiteName: "PluginHostDispatchTests.safemode.timeouts")!
        defaults.removePersistentDomain(forName: "PluginHostDispatchTests.safemode.timeouts")
        let settings = PluginSettingsStore(userDefaults: defaults)

        let host = PluginHost()
        host.register([plugin], settingsStore: settings)

        host.enqueue(makeEvent(kind: .pluginStarted))
        await host.waitUntilIdle()
        XCTAssertEqual(host.contributions[.notchExpandedActivity]?.count, 1)
        XCTAssertFalse(host.isInSafemode("com.devisland.test.safemode.timeouts"))

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()
        XCTAssertFalse(host.isInSafemode("com.devisland.test.safemode.timeouts"))

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()
        XCTAssertTrue(host.isInSafemode("com.devisland.test.safemode.timeouts"))
        XCTAssertTrue(host.contributions[.notchExpandedActivity]?.isEmpty ?? true)
        XCTAssertTrue(settings.safemodePluginIDs.contains("com.devisland.test.safemode.timeouts"))
    }

    func testProbationEntersSafemodeOnFirstFailureAfterReset() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.safemode.probation",
            permissions: [.showNotchCard],
            activationEvents: [.pluginStarted, .pluginTick],
            contribution: makeContribution(pluginID: "com.devisland.test.safemode.probation"),
            throwOnKinds: [.pluginTick]
        )
        let defaults = UserDefaults(suiteName: "PluginHostDispatchTests.safemode.probation")!
        defaults.removePersistentDomain(forName: "PluginHostDispatchTests.safemode.probation")
        let settings = PluginSettingsStore(userDefaults: defaults)

        let host = PluginHost()
        host.register([plugin], settingsStore: settings)

        host.enterSafemode(pluginID: "com.devisland.test.safemode.probation")
        XCTAssertTrue(host.isInSafemode("com.devisland.test.safemode.probation"))
        XCTAssertTrue(settings.safemodePluginIDs.contains("com.devisland.test.safemode.probation"))

        host.resetPlugin(pluginID: "com.devisland.test.safemode.probation")
        await host.waitUntilIdle()
        XCTAssertFalse(host.isInSafemode("com.devisland.test.safemode.probation"))
        XCTAssertFalse(settings.safemodePluginIDs.contains("com.devisland.test.safemode.probation"))

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()
        
        XCTAssertTrue(host.isInSafemode("com.devisland.test.safemode.probation"))
        XCTAssertTrue(settings.safemodePluginIDs.contains("com.devisland.test.safemode.probation"))
    }

    func testSuccessfulExecutionClearsProbation() async {
        let plugin = ProbationTestPlugin(id: "com.devisland.test.safemode.probation.success")
        let defaults = UserDefaults(suiteName: "PluginHostDispatchTests.safemode.probation.success")!
        defaults.removePersistentDomain(forName: "PluginHostDispatchTests.safemode.probation.success")
        let settings = PluginSettingsStore(userDefaults: defaults)

        let host = PluginHost()
        host.register([plugin], settingsStore: settings)

        host.resetPlugin(pluginID: "com.devisland.test.safemode.probation.success")
        await host.waitUntilIdle()

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()
        XCTAssertFalse(host.isInSafemode("com.devisland.test.safemode.probation.success"))

        plugin.shouldThrow = true
        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()
        XCTAssertFalse(host.isInSafemode("com.devisland.test.safemode.probation.success"))
    }

    func testAppRestartRestoresSafemodeAndStartsProbation() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.safemode.restart",
            permissions: [.showNotchCard],
            activationEvents: [.pluginStarted, .pluginTick],
            contribution: makeContribution(pluginID: "com.devisland.test.safemode.restart"),
            throwOnKinds: [.pluginTick]
        )
        let defaults = UserDefaults(suiteName: "PluginHostDispatchTests.safemode.restart")!
        defaults.removePersistentDomain(forName: "PluginHostDispatchTests.safemode.restart")
        let settings = PluginSettingsStore(userDefaults: defaults)

        settings.setSafemode(true, pluginID: "com.devisland.test.safemode.restart")

        let host = PluginHost()
        host.register([plugin], settingsStore: settings)

        XCTAssertFalse(host.isInSafemode("com.devisland.test.safemode.restart"))
        XCTAssertFalse(settings.safemodePluginIDs.contains("com.devisland.test.safemode.restart"))

        host.enqueue(makeEvent(kind: .pluginTick))
        await host.waitUntilIdle()

        XCTAssertTrue(host.isInSafemode("com.devisland.test.safemode.restart"))
        XCTAssertTrue(settings.safemodePluginIDs.contains("com.devisland.test.safemode.restart"))
    }

    func testSafemodeOrDisabledPluginActionIsBlocked() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.action.blocked",
            permissions: [.writePluginStorage],
            activationEvents: [.pluginActionInvoked]
        )
        let defaults = UserDefaults(suiteName: "PluginHostDispatchTests.action.blocked")!
        defaults.removePersistentDomain(forName: "PluginHostDispatchTests.action.blocked")
        let settings = PluginSettingsStore(userDefaults: defaults)
        
        let host = PluginHost(pluginDataDirectory: makeTempStorageDirectory())
        host.register([plugin], settingsStore: settings)
        
        let action = PluginUIActionDTO(
            id: "store",
            capability: "storage.keyValue",
            routing: .hostExecuted,
            payload: ["key": "count", "value": "5"]
        )
        
        host.enterSafemode(pluginID: "com.devisland.test.action.blocked")
        
        host.handleAction(action, from: "com.devisland.test.action.blocked", componentID: "store")
        
        try? await Task.sleep(nanoseconds: 100_000_000)
        let snapshot = await host.pluginStorageSnapshot(forPluginID: "com.devisland.test.action.blocked")
        XCTAssertNil(snapshot["count"], "Action must be blocked when plugin is in safemode")
    }

    func testStaleSnapshotDiscardedAfterReset() async {
        let plugin = RecordingPlugin(
            id: "com.devisland.test.safemode.stale",
            permissions: [.showNotchCard],
            activationEvents: [.pluginStarted, .pluginTick],
            contribution: makeContribution(pluginID: "com.devisland.test.safemode.stale"),
            throwOnKinds: [.pluginTick],
            delay: 0.5,
            delayOnKinds: [.pluginTick]
        )
        let defaults = UserDefaults(suiteName: "PluginHostDispatchTests.safemode.stale")!
        defaults.removePersistentDomain(forName: "PluginHostDispatchTests.safemode.stale")
        let settings = PluginSettingsStore(userDefaults: defaults)

        let host = PluginHost()
        host.register([plugin], settingsStore: settings)

        host.enqueue(makeEvent(kind: .pluginTick))
        
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        host.resetPlugin(pluginID: "com.devisland.test.safemode.stale")
        
        await host.waitUntilIdle()
        
        XCTAssertFalse(host.isInSafemode("com.devisland.test.safemode.stale"), "Stale failure must be discarded and not cause safemode")
    }

    func testDisableDuringDrainDiscardsInFlightContribution() async {
        let id = "com.devisland.test.disable.during.drain"
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let plugin = GatedPlugin(
            id: id,
            contribution: makeContribution(pluginID: id),
            gateOn: [.pluginStarted],
            entered: entered,
            resume: resume
        )
        let defaults = UserDefaults(suiteName: "PluginHostDispatchTests.disable.during.drain")!
        defaults.removePersistentDomain(forName: "PluginHostDispatchTests.disable.during.drain")
        let host = PluginHost()
        host.register([plugin], settingsStore: PluginSettingsStore(userDefaults: defaults))

        // The plugin parks inside onEvent, so the host is deterministically stuck on
        // `await eventProcessor.process` when we disable it — the exact window where the
        // in-flight snapshot must be discarded rather than re-added after the user turned
        // it off.
        host.enqueue(makeEvent(kind: .pluginStarted))
        await awaitSignal(entered)
        host.setPluginEnabled(false, pluginID: id)
        resume.signal()

        await host.waitUntilIdle()

        XCTAssertTrue(host.contributions[.notchExpandedActivity]?.isEmpty ?? true,
                      "a plugin disabled mid-drain must not have its in-flight contribution re-added")
    }

    func testSafemodeExcludesEventAlreadyQueued() async {
        let id = "com.devisland.test.safemode.queued"
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        // The first event parks the drain, leaving the second event pending in the queue.
        // That pending event's eligible-runner list was captured at enqueue time, before
        // safemode — the gap the drain-time `isActive` re-filter closes.
        let plugin = GatedPlugin(
            id: id,
            contribution: makeContribution(pluginID: id),
            gateOn: [.pluginStarted],
            entered: entered,
            resume: resume,
            activationEvents: [.pluginStarted, .pluginTick]
        )
        let defaults = UserDefaults(suiteName: "PluginHostDispatchTests.safemode.queued")!
        defaults.removePersistentDomain(forName: "PluginHostDispatchTests.safemode.queued")
        let host = PluginHost()
        host.register([plugin], settingsStore: PluginSettingsStore(userDefaults: defaults))

        host.enqueue(makeEvent(kind: .pluginStarted)) // parks the drain inside onEvent
        host.enqueue(makeEvent(kind: .pluginTick))     // queued behind it, not yet processed
        await awaitSignal(entered)
        host.enterSafemode(pluginID: id)
        resume.signal()

        await host.waitUntilIdle()

        XCTAssertFalse(plugin.receivedKinds.contains(.pluginTick),
                       "an event still queued when the plugin entered safemode must not run")
        XCTAssertTrue(host.isInSafemode(id))
    }

    /// Awaits a `DispatchSemaphore` without blocking the Swift cooperative pool: the plugin
    /// signals it from a synchronous `onEvent`, so the test bridges through a Dispatch global
    /// queue and a continuation. Waiting on the MainActor thread directly would deadlock the
    /// @MainActor-isolated drain loop; blocking a cooperative thread is unavailable in async
    /// code (an error under Swift 6).
    private func awaitSignal(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }

    private func makeTempStorageDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginStorageDispatchTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
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
    let delayOnKinds: Set<PluginEventKind>?
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
        name: String? = nil,
        permissions: Set<PluginPermission> = [],
        activationEvents: Set<PluginEventKind>,
        contribution: PluginUIContribution? = nil,
        surfaces: Set<PluginUISlot> = [.notchExpandedActivity],
        throwOnKinds: Set<PluginEventKind> = [],
        delay: TimeInterval = 0,
        delayOnKinds: Set<PluginEventKind>? = nil
    ) {
        self.manifest = PluginManifest(
            id: id,
            name: name ?? id,
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
        self.delayOnKinds = delayOnKinds
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        let shouldDelay = delayOnKinds?.contains(event.kind) ?? true
        if shouldDelay && delay > 0 {
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

/// Deterministically parks inside `onEvent` for the gated event kinds: it signals
/// `entered` once the host is stuck on `await eventProcessor.process`, then blocks on
/// `resume` until the test releases it. This removes the timing dependence of a sleep —
/// the test controls exactly when state changes relative to the in-flight runner.
private final class GatedPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let contribution: PluginUIContribution
    private let gateOn: Set<PluginEventKind>
    private let entered: DispatchSemaphore
    private let resume: DispatchSemaphore
    private let lock = NSLock()
    private var _receivedKinds: [PluginEventKind] = []
    var receivedKinds: [PluginEventKind] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedKinds
    }

    init(
        id: String,
        contribution: PluginUIContribution,
        gateOn: Set<PluginEventKind>,
        entered: DispatchSemaphore,
        resume: DispatchSemaphore,
        activationEvents: Set<PluginEventKind> = [.pluginStarted]
    ) {
        self.contribution = contribution
        self.gateOn = gateOn
        self.entered = entered
        self.resume = resume
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [.showNotchCard],
            surfaces: [.notchExpandedActivity],
            activationEvents: Set(activationEvents.map(\.rawValue))
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        lock.lock()
        _receivedKinds.append(event.kind)
        lock.unlock()
        if gateOn.contains(event.kind) {
            entered.signal()
            resume.wait()
        }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        contribution
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

private final class ScopedReaderPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let lock = NSLock()
    private var _readText: String?
    private var _sawMissingClient = false

    var readText: String? {
        lock.lock()
        defer { lock.unlock() }
        return _readText
    }

    var sawMissingClient: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _sawMissingClient
    }

    init(id: String, permissions: Set<PluginPermission>) {
        manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: permissions,
            surfaces: [],
            activationEvents: [PluginEventKind.pluginStarted.rawValue]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        guard let scopedFiles = context.scopedFiles else {
            lock.lock()
            _sawMissingClient = true
            lock.unlock()
            return []
        }
        let text = try await scopedFiles.readText(scopeID: "packs", relativePath: "manifest.txt")
        lock.lock()
        _readText = text
        lock.unlock()
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        nil
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

private final class VisibilityTickingPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let tickSurface: PluginUISlot
    private let lock = NSLock()
    private var _receivedKinds: [PluginEventKind] = []
    var receivedKinds: [PluginEventKind] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedKinds
    }

    init(id: String, tickSurface: PluginUISlot = .notchExpandedActivity) {
        self.tickSurface = tickSurface
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [],
            surfaces: [],
            activationEvents: [PluginEventKind.pluginTick.rawValue]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        lock.lock()
        _receivedKinds.append(event.kind)
        lock.unlock()
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        nil
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        surfaceState.visibleSurfaces.contains(tickSurface)
    }
}

/// Contributes a session-scoped row badge whose value changes on every evaluation, so a test
/// can detect whether a session-bearing tick re-evaluated the slot. Tracks sessions from
/// `session.started` and ticks while the row surface is visible.
private final class SessionRowTickPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let lock = NSLock()
    private var trackedSessionIDs: Set<String> = []
    private var rowEvalCount = 0

    init(id: String) {
        manifest = PluginManifest(
            id: id, name: id, version: "1.0.0", apiVersion: 1, kind: .system,
            permissions: [.readSessionEvents, .showSessionSurface],
            surfaces: [.notchSessionRow],
            activationEvents: [
                PluginEventKind.sessionStarted.rawValue,
                PluginEventKind.pluginTick.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        if event.kind == .sessionStarted, let session = event.session {
            lock.lock(); trackedSessionIDs.insert(session.id); lock.unlock()
        }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        guard slot == .notchSessionRow, let session = context.session else { return nil }
        lock.lock()
        guard trackedSessionIDs.contains(session.id) else { lock.unlock(); return nil }
        rowEvalCount += 1
        let count = rowEvalCount
        lock.unlock()
        return PluginUIContribution(
            pluginID: manifest.id, slot: slot, targetSessionID: session.id,
            priority: 10, expiresAt: nil,
            components: [PluginUIComponentDTO(id: "c", type: .text, label: nil,
                value: "\(count)", tone: nil, iconName: nil, action: nil)]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        surfaceState.visibleSurfaces.contains(.notchSessionRow)
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

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
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

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
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

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
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

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
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

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
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

private final class GlobalToggleSessionScopedContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let lock = NSLock()
    private var hideAll = false

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

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        if event.kind == .pluginTick {
            lock.lock()
            hideAll = true
            lock.unlock()
        }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        lock.lock()
        let shouldHide = hideAll
        lock.unlock()
        guard !shouldHide, let sessionID = context.session?.id else { return nil }

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

private final class ProbationTestPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let lock = NSLock()
    private var _shouldThrow = false
    var shouldThrow: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _shouldThrow
        }
        set {
            lock.lock()
            _shouldThrow = newValue
            lock.unlock()
        }
    }

    init(id: String) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [.showNotchCard],
            surfaces: [.notchExpandedActivity],
            activationEvents: ["plugin.started", "plugin.tick"]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        if shouldThrow {
            throw RecordingPlugin.TestError()
        }
        return []
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        nil
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

private final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
