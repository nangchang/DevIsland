import XCTest
@testable import DevIsland

@MainActor
final class OpenPeonPluginTests: XCTestCase {
    func testHookEventProducesScopedAudioEffect() async throws {
        let tempRoot = try makePackRoot()
        let previousSettings = SettingsStore.shared.settings
        addTeardownBlock {
            await MainActor.run {
                SettingsStore.shared.settings = previousSettings
                CESPPackStore.shared.replacePacksForTesting([])
            }
        }
        SettingsStore.shared.settings.openPeonEnabled = true
        SettingsStore.shared.settings.openPeonPacksDirectory = tempRoot.path
        SettingsStore.shared.settings.openPeonActivePackName = "sample"
        SettingsStore.shared.settings.openPeonMutedCategories = []
        SettingsStore.shared.settings.openPeonDebounceMilliseconds = 0
        let packURL = tempRoot.appendingPathComponent("sample", isDirectory: true)
        let pack = try XCTUnwrap(CESPPackValidator.loadPack(at: packURL))
        CESPPackStore.shared.replacePacksForTesting([pack])

        let plugin = OpenPeonPlugin()
        let effects = try await plugin.onEvent(
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
            ),
            context: PluginContext(
                pluginID: OpenPeonPlugin.pluginID,
                permissions: [.readHookSummaries, .playScopedAudio],
                storageSnapshot: [:]
            )
        )

        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects.first?.capability, "audio.playFile")
        XCTAssertEqual(effects.first?.payload["scope"], OpenPeonPlugin.packScopeID)
        XCTAssertEqual(effects.first?.payload["path"], "sample/sounds/input.wav")
    }

    private func makePackRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenPeonPluginTests-\(UUID().uuidString)", isDirectory: true)
        let pack = root.appendingPathComponent("sample", isDirectory: true)
        let sounds = pack.appendingPathComponent("sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        let manifest = """
        {
          "cesp_version": "1.0",
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
        try Data(manifest.utf8).write(to: pack.appendingPathComponent("openpeon.json"))
        try Data("wav".utf8).write(to: sounds.appendingPathComponent("input.wav"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
