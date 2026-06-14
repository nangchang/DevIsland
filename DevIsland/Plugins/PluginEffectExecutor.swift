import Foundation

actor PluginEffectExecutor {
    typealias NotificationHandler = @Sendable (_ title: String, _ body: String?) async -> Void
    typealias PowerSleepHandler = @Sendable (_ preventSleep: Bool, _ reason: String) async -> Void
    typealias PowerToggleHandler = @Sendable () async -> Void
    typealias AudioPlayHandler = @Sendable (_ url: URL, _ volume: Float) async -> Void

    private let storageProvider: PluginStorageProvider
    private let scopedFileBroker: PluginScopedFileBroker
    private let notificationHandler: NotificationHandler?
    private let powerSleepHandler: PowerSleepHandler?
    private let powerToggleHandler: PowerToggleHandler?
    private let audioPlayHandler: AudioPlayHandler

    init(
        storageProvider: PluginStorageProvider,
        scopedFileBroker: PluginScopedFileBroker = PluginScopedFileBroker(),
        notificationHandler: NotificationHandler? = nil,
        powerSleepHandler: PowerSleepHandler? = nil,
        powerToggleHandler: PowerToggleHandler? = nil,
        audioPlayHandler: AudioPlayHandler? = nil
    ) {
        self.storageProvider = storageProvider
        self.scopedFileBroker = scopedFileBroker
        self.notificationHandler = notificationHandler
        self.powerSleepHandler = powerSleepHandler
        self.powerToggleHandler = powerToggleHandler
        self.audioPlayHandler = audioPlayHandler ?? { url, volume in
            await PluginScopedAudioPlayer.shared.play(url: url, volume: volume)
        }
    }

    func enqueue(
        _ effects: [PluginEffect],
        pluginID: String,
        kind: PluginKind,
        permissions: Set<PluginPermission>
    ) async {
        for effect in effects where HostEffectCatalog.isSupported(effect.capability, kind: kind, permissions: permissions) {
            await execute(effect, pluginID: pluginID)
        }
    }

    private func execute(_ effect: PluginEffect, pluginID: String) async {
        if effect.capability.hasPrefix("storage.") {
            await storageProvider.applyStorageEffect(effect, pluginID: pluginID)
            return
        }

        if effect.capability == "notification.show" {
            let title = normalizedText(effect.payload["title"])
            let body = normalizedText(effect.payload["body"])
            guard let message = title ?? body else { return }
            await notificationHandler?(message, title == nil ? nil : body)
            return
        }

        if effect.capability == "audio.playFile" {
            guard let scopeID = normalizedText(effect.payload["scope"]),
                  let relativePath = normalizedText(effect.payload["path"]) else {
                return
            }
            do {
                let url = try await scopedFileBroker.resolvePlayableFile(
                    pluginID: pluginID,
                    scopeID: scopeID,
                    relativePath: relativePath
                )
                await audioPlayHandler(url, normalizedVolume(effect.payload["volume"]))
            } catch {
                print("[DevIsland] Plugin audio effect rejected for \(pluginID): \(error)")
            }
            return
        }

        // The built-in allowlist (`caffeine` only) is enforced by `HostEffectCatalog.isSupported`
        // in `enqueue`, so an unauthorized plugin's power effect never reaches here.
        if effect.capability == "power.preventIdleSleep" {
            let prevent = effect.payload["preventSleep"] == "true"
            let reason = effect.payload["reason"] ?? "off"
            await powerSleepHandler?(prevent, reason)
            return
        }

        if effect.capability == "power.toggle" {
            await powerToggleHandler?()
            return
        }
    }

    private func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedVolume(_ value: String?) -> Float {
        guard let value, let parsed = Float(value) else { return 1.0 }
        return min(max(parsed, 0), 1)
    }
}
