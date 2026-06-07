import Foundation

actor PluginEffectExecutor {
    private let storageProvider: PluginStorageProvider

    init(storageProvider: PluginStorageProvider) {
        self.storageProvider = storageProvider
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
        default:
            return false
        }
    }

    private func execute(_ effect: PluginEffect, pluginID: String) async {
        if effect.capability.hasPrefix("storage.") {
            await storageProvider.applyStorageEffect(effect, pluginID: pluginID)
        }
    }
}
