import Foundation

actor PluginEffectExecutor {
    typealias NotificationHandler = @Sendable (_ title: String, _ body: String?) async -> Void

    private let storageProvider: PluginStorageProvider
    private let notificationHandler: NotificationHandler?

    init(
        storageProvider: PluginStorageProvider,
        notificationHandler: NotificationHandler? = nil
    ) {
        self.storageProvider = storageProvider
        self.notificationHandler = notificationHandler
    }

    func enqueue(
        _ effects: [PluginEffect],
        pluginID: String,
        permissions: Set<PluginPermission>
    ) async {
        for effect in effects where Self.isHostEffectSupported(effect.capability, permissions: permissions) {
            await execute(effect, pluginID: pluginID)
        }
    }

    nonisolated static func isHostEffectSupported(
        _ capability: String,
        permissions: Set<PluginPermission>
    ) -> Bool {
        switch capability {
        case "storage.keyValue", "storage.increment":
            return permissions.contains(.writePluginStorage)
        case "notification.show":
            return permissions.contains(.showNotification)
        case "sound.play":
            return permissions.contains(.playSound)
        default:
            return false
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
        }
    }

    private func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
