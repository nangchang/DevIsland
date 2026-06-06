import Foundation

actor PluginStorageProvider {
    private var appliedEffects: [(pluginID: String, effect: PluginEffect)] = []

    func snapshot(forPluginID pluginID: String) async -> [String: String] {
        [:]
    }

    func applyStorageEffect(_ effect: PluginEffect, pluginID: String) async {
        appliedEffects.append((pluginID: pluginID, effect: effect))
        // Stub: durable plugin storage is implemented in PR 9.
    }

    func appliedStorageEffects() -> [(pluginID: String, effect: PluginEffect)] {
        appliedEffects
    }
}
