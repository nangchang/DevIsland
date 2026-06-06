import Foundation

actor PluginEffectExecutor {
    private let storageProvider: PluginStorageProvider

    init(storageProvider: PluginStorageProvider) {
        self.storageProvider = storageProvider
    }

    func enqueue(_ effects: [PluginEffect], pluginID: String) async {
        for effect in effects {
            await execute(effect, pluginID: pluginID)
        }
    }

    private func execute(_ effect: PluginEffect, pluginID: String) async {
        if effect.capability.hasPrefix("storage.") {
            await storageProvider.applyStorageEffect(effect, pluginID: pluginID)
        }
    }
}

