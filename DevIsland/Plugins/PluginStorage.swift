import Foundation

actor PluginStorageProvider {
    func snapshot(forPluginID pluginID: String) async -> [String: String] {
        [:]
    }

    func applyStorageEffect(_ effect: PluginEffect, pluginID: String) async {
        // Stub for PR 3. Durable plugin storage is implemented in PR 9.
    }
}

