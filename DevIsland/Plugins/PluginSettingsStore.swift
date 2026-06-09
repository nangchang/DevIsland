import Combine
import Foundation

/// Persists per-plugin enable/disable state. Kept separate from `SettingsStore` so the
/// plugin platform stays decoupled from core app settings (design §11): a disabled
/// plugin is opt-out, so absence of an entry means enabled.
@MainActor
final class PluginSettingsStore: ObservableObject {
    static let shared = PluginSettingsStore()

    private enum DefaultsKey {
        static let disabledPlugins = "pluginDisabledIDs"
    }

    private let userDefaults: UserDefaults

    @Published private(set) var disabledPluginIDs: Set<String>

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let stored = userDefaults.stringArray(forKey: DefaultsKey.disabledPlugins) ?? []
        self.disabledPluginIDs = Set(stored)
    }

    func isEnabled(_ pluginID: String) -> Bool {
        !disabledPluginIDs.contains(pluginID)
    }

    func setEnabled(_ enabled: Bool, pluginID: String) {
        if enabled {
            disabledPluginIDs.remove(pluginID)
        } else {
            disabledPluginIDs.insert(pluginID)
        }
        userDefaults.set(disabledPluginIDs.sorted(), forKey: DefaultsKey.disabledPlugins)
    }
}
