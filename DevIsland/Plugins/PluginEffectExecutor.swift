import Foundation

actor PluginEffectExecutor {
    typealias NotificationHandler = @Sendable (_ title: String, _ body: String?) async -> Void
    typealias PowerSleepHandler = @Sendable (_ preventSleep: Bool, _ reason: String) async -> Void
    typealias PowerToggleHandler = @Sendable () async -> Void

    private let storageProvider: PluginStorageProvider
    private let notificationHandler: NotificationHandler?
    private let powerSleepHandler: PowerSleepHandler?
    private let powerToggleHandler: PowerToggleHandler?

    init(
        storageProvider: PluginStorageProvider,
        notificationHandler: NotificationHandler? = nil,
        powerSleepHandler: PowerSleepHandler? = nil,
        powerToggleHandler: PowerToggleHandler? = nil
    ) {
        self.storageProvider = storageProvider
        self.notificationHandler = notificationHandler
        self.powerSleepHandler = powerSleepHandler
        self.powerToggleHandler = powerToggleHandler
    }

    func enqueue(
        _ effects: [PluginEffect],
        pluginID: String,
        permissions: Set<PluginPermission>
    ) async {
        for effect in effects where HostEffectCatalog.isSupported(effect.capability, pluginID: pluginID, permissions: permissions) {
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

        if effect.capability == "sound.play" {
            if let categoryString = effect.payload["category"],
               let category = CESPCategory(rawValue: categoryString) {
                Task { @MainActor in
                    CESPAudioPlayer.shared.play(category: category)
                }
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
}
