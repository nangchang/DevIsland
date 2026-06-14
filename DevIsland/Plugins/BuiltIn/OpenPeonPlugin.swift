import Foundation

final class OpenPeonPlugin: DevIslandPlugin, @unchecked Sendable {
    static let pluginID = "openpeon"
    static let packScopeID = "packs"

    let manifest = PluginManifest(
        id: OpenPeonPlugin.pluginID,
        name: "OpenPeon",
        version: "1.0.0",
        apiVersion: 1,
        kind: .system,
        permissions: [.playScopedAudio, .readHookSummaries],
        surfaces: [],
        activationEvents: ["hook.received"],
        localizedName: PluginLocalizedString(english: "OpenPeon", korean: "OpenPeon")
    )

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        guard event.kind == .hookReceived, let hook = event.hook else {
            return []
        }

        let agentKind = BuddyKind(from: hook.provider)

        let payloadDict = hook.payload?.mapValues { $0.rawValue }

        if let category = CESPEventMapper.category(
            event: hook.rawEvent ?? "",
            normalizedEvent: hook.eventType,
            agentKind: agentKind,
            toolName: hook.toolName ?? "",
            notificationType: hook.notificationType ?? "",
            message: hook.message ?? "",
            payload: payloadDict
        ) {
            let settings = await MainActor.run { SettingsStore.shared.settings }
            guard let request = await CESPAudioPlayer.shared.scopedAudioRequest(
                category: category,
                settings: settings,
                scopeRootPath: settings.openPeonPacksDirectory
            ) else {
                return []
            }
            return [
                PluginEffect(
                    capability: "audio.playFile",
                    payload: [
                        "scope": Self.packScopeID,
                        "path": request.relativePath,
                        "volume": request.volume
                    ]
                )
            ]
        }

        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        return nil
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        return false
    }
}

extension OpenPeonPlugin: PluginScopedFileScopeProvider {
    static var scopedFilePluginID: String { pluginID }

    static func scopedFileScopes(userDefaults: UserDefaults) -> [PluginScopedFileScope] {
        let defaults = AppSettings.defaults
        guard let raw = userDefaults.string(forKey: SettingsStore.DefaultsKey.openPeonPacksDirectory),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return packScopes(packsDirectory: defaults.openPeonPacksDirectory)
        }
        return packScopes(packsDirectory: raw)
    }

    static func scopedFileScopes(settings: AppSettings) -> [PluginScopedFileScope] {
        packScopes(packsDirectory: settings.openPeonPacksDirectory)
    }

    private static func packScopes(packsDirectory: String) -> [PluginScopedFileScope] {
        [
            PluginScopedFileScope(
                id: packScopeID,
                baseDirectory: URL(
                    fileURLWithPath: NSString(string: packsDirectory).expandingTildeInPath,
                    isDirectory: true
                )
            )
        ]
    }
}
