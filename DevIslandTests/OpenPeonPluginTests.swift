import XCTest
@testable import DevIsland

@MainActor
final class OpenPeonPluginTests: XCTestCase {
    private var settings: AppSettings!

    override func setUp() async throws {
        try await super.setUp()
        settings = AppSettings.defaults
        settings.openPeonEnabled = true
        settings.openPeonGlobalMuted = false
        settings.openPeonMutedCategories = []
        settings.openPeonDebounceMilliseconds = 0
        settings.openPeonActivePackName = "sample"
    }

    override func tearDown() async throws {
        settings = nil
        try await super.tearDown()
    }

    func testHookEventProducesScopedAudioEffect() async throws {
        let (_, client) = try makeBroker()

        let effects = try await makePlugin().onEvent(hookEvent(), context: context(client))

        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects.first?.capability, "audio.playFile")
        XCTAssertEqual(effects.first?.payload["scope"], OpenPeonPlugin.packScopeID)
        XCTAssertEqual(effects.first?.payload["path"], "sample/sounds/input.wav")
    }

    func testMissingScopedFilesProducesNoEffect() async throws {
        let context = PluginContext(
            pluginID: OpenPeonPlugin.pluginID,
            permissions: [.readHookSummaries, .playScopedAudio],
            storageSnapshot: [:]
        )

        let effects = try await makePlugin().onEvent(hookEvent(), context: context)

        XCTAssertTrue(effects.isEmpty)
    }

    func testGlobalMuteProducesNoEffect() async throws {
        settings.openPeonGlobalMuted = true
        let (_, client) = try makeBroker()

        let effects = try await makePlugin().onEvent(hookEvent(), context: context(client))

        XCTAssertTrue(effects.isEmpty)
    }

    func testMutedCategoryProducesNoEffect() async throws {
        settings.openPeonMutedCategories = ["task.acknowledge"]
        let (_, client) = try makeBroker()

        let effects = try await makePlugin().onEvent(hookEvent(), context: context(client))

        XCTAssertTrue(effects.isEmpty)
    }

    func testInvalidPackProducesNoEffect() async throws {
        let (_, client) = try makeBroker(cespVersion: "2.0")

        let effects = try await makePlugin().onEvent(hookEvent(), context: context(client))

        XCTAssertTrue(effects.isEmpty)
    }

    func testActivePackResolvesWhenNameUnset() async throws {
        settings.openPeonActivePackName = nil
        let (_, client) = try makeBroker()

        let effects = try await makePlugin().onEvent(hookEvent(), context: context(client))

        XCTAssertEqual(effects.first?.payload["path"], "sample/sounds/input.wav")
    }

    func testDebounceSuppressesRepeatWithinInterval() async throws {
        settings.openPeonDebounceMilliseconds = 1000
        let (_, client) = try makeBroker()
        let runtime = OpenPeonRuntime()
        let base = Date()

        let first = await runtime.resolveEffects(
            category: .taskAcknowledge, scoped: client, scopeID: OpenPeonPlugin.packScopeID,
            settings: settings, now: base
        )
        let within = await runtime.resolveEffects(
            category: .taskAcknowledge, scoped: client, scopeID: OpenPeonPlugin.packScopeID,
            settings: settings, now: base.addingTimeInterval(0.1)
        )
        let after = await runtime.resolveEffects(
            category: .taskAcknowledge, scoped: client, scopeID: OpenPeonPlugin.packScopeID,
            settings: settings, now: base.addingTimeInterval(2.0)
        )

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(within.isEmpty)
        XCTAssertEqual(after.count, 1)
    }

    func testEmptyPacksDirectoryDoesNotCreateScope() {
        settings.openPeonPacksDirectory = ""

        let scopes = OpenPeonPlugin.scopedFileScopes(settings: settings)

        XCTAssertTrue(scopes.isEmpty)
    }

    // MARK: - Helpers

    private func makePlugin() -> OpenPeonPlugin {
        let settings = self.settings!
        return OpenPeonPlugin(settingsProvider: { settings })
    }

    private func context(_ client: PluginScopedFileClient) -> PluginContext {
        PluginContext(
            pluginID: OpenPeonPlugin.pluginID,
            permissions: [.readHookSummaries, .playScopedAudio, .readScopedFiles],
            storageSnapshot: [:],
            scopedFiles: client
        )
    }

    private func hookEvent() -> PluginEvent {
        PluginEvent(
            id: UUID(),
            kind: .hookReceived,
            timestamp: Date(),
            hook: PluginHookSummary(
                provider: "codex",
                eventType: "pretooluse",
                commandSummary: nil,
                cwd: nil,
                terminalApp: nil,
                rawEvent: "PreToolUse",
                toolName: "Bash",
                notificationType: nil,
                message: nil,
                payload: nil
            )
        )
    }

    /// Builds a real broker over a temp packs directory containing a single `sample` pack
    /// (category `task.acknowledge` → `sounds/input.wav`) and a `.readScopedFiles` client.
    private func makeBroker(cespVersion: String = "1.0") throws -> (PluginScopedFileBroker, PluginScopedFileClient) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenPeonPluginTests-\(UUID().uuidString)", isDirectory: true)
        let sounds = root.appendingPathComponent("sample/sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        let manifest = """
        {
          "cesp_version": "\(cespVersion)",
          "name": "sample",
          "version": "1.0.0",
          "categories": {
            "task.acknowledge": {
              "sounds": [
                { "file": "sounds/input.wav" }
              ]
            }
          }
        }
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("sample/openpeon.json"))
        try Data("wav".utf8).write(to: sounds.appendingPathComponent("input.wav"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let scope = PluginScopedFileScope(id: OpenPeonPlugin.packScopeID, baseDirectory: root)
        let broker = PluginScopedFileBroker(scopesByPluginID: [OpenPeonPlugin.pluginID: [scope]])
        let client = PluginScopedFileClient(
            pluginID: OpenPeonPlugin.pluginID,
            permissions: [.readScopedFiles],
            broker: broker
        )
        return (broker, client)
    }
}
