import Foundation

final class OpenPeonPlugin: DevIslandPlugin, @unchecked Sendable {
    static let pluginID = BuiltInPluginID.openPeon
    static let packScopeID = "packs"

    let manifest = PluginManifest(
        id: OpenPeonPlugin.pluginID,
        name: "OpenPeon",
        version: "1.0.0",
        apiVersion: 1,
        kind: .system,
        permissions: [.playScopedAudio, .readHookSummaries, .readScopedFiles],
        surfaces: [],
        activationEvents: ["hook.received"],
        localizedName: PluginLocalizedString(english: "OpenPeon", korean: "OpenPeon"),
        localizedDescription: PluginLocalizedString(
            english: "Plays audio cues for hook events using customizable sound packs.",
            korean: "사용자 지정 사운드 팩을 사용해 훅 이벤트에 대한 오디오 신호를 재생합니다."
        )
    )

    private let runtime = OpenPeonRuntime()
    private let settingsProvider: @MainActor @Sendable () -> AppSettings

    init(settingsProvider: @escaping @MainActor @Sendable () -> AppSettings) {
        self.settingsProvider = settingsProvider
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        guard event.kind == .hookReceived,
              let hook = event.hook,
              let scoped = context.scopedFiles else {
            return []
        }

        let agentKind = BuddyKind(from: hook.provider)
        let payloadDict = hook.payload?.mapValues { $0.rawValue }

        guard let category = CESPEventMapper.category(
            event: hook.rawEvent ?? "",
            normalizedEvent: hook.eventType,
            agentKind: agentKind,
            toolName: hook.toolName ?? "",
            notificationType: hook.notificationType ?? "",
            message: hook.message ?? "",
            payload: payloadDict
        ) else {
            return []
        }

        let settings = await settingsProvider()
        return await runtime.resolveEffects(
            category: category,
            scoped: scoped,
            scopeID: Self.packScopeID,
            settings: settings
        )
    }

    var settingsPaneDescriptor: PluginSettingsPaneDescriptor? {
        PluginSettingsPaneDescriptor(
            pluginID: manifest.id,
            label: PluginLocalizedString(english: "Sound", korean: "사운드"),
            systemImage: "speaker.wave.2"
        )
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
              !raw.isEmpty else {
            return packScopes(packsDirectory: defaults.openPeonPacksDirectory)
        }
        return packScopes(packsDirectory: raw)
    }

    static func scopedFileScopes(settings: AppSettings) -> [PluginScopedFileScope] {
        packScopes(packsDirectory: settings.openPeonPacksDirectory)
    }

    private static func packScopes(packsDirectory: String) -> [PluginScopedFileScope] {
        guard !packsDirectory.isEmpty else { return [] }
        return [
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
