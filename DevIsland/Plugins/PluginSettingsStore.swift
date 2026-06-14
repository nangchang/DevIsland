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
        static let safemodePlugins = "pluginSafemodeIDs"
        /// Per-plugin setting values live under one key each, namespaced away from core app,
        /// bridge, and approval defaults so a plugin can never touch them.
        static func settings(_ pluginID: String) -> String { "pluginSettings.\(pluginID)" }
    }

    private let userDefaults: UserDefaults

    @Published private(set) var disabledPluginIDs: Set<String>
    @Published private(set) var safemodePluginIDs: Set<String>
    /// pluginID → (key → value). Mirrors the per-plugin defaults entries; republished on
    /// change so the settings UI updates. Loaded lazily per plugin in `settings(forPluginID:)`.
    @Published private(set) var settingsValues: [String: [String: PluginSettingValue]] = [:]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedDisabled = userDefaults.stringArray(forKey: DefaultsKey.disabledPlugins) ?? []
        self.disabledPluginIDs = Set(storedDisabled)
        let storedSafemode = userDefaults.stringArray(forKey: DefaultsKey.safemodePlugins) ?? []
        self.safemodePluginIDs = Set(storedSafemode)
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

    func setSafemode(_ inSafemode: Bool, pluginID: String) {
        if inSafemode {
            safemodePluginIDs.insert(pluginID)
        } else {
            safemodePluginIDs.remove(pluginID)
        }
        userDefaults.set(safemodePluginIDs.sorted(), forKey: DefaultsKey.safemodePlugins)
    }

    // MARK: - Per-plugin settings

    /// Raw stored settings for a plugin (no schema validation — callers resolve against the
    /// schema). Pure read: never mutates `settingsValues`, so it is safe to call from a
    /// SwiftUI view body (mutating `@Published` during view update triggers a runtime
    /// warning). The cache is populated only by `setValue`; until then reads hit defaults.
    func settings(forPluginID pluginID: String) -> [String: PluginSettingValue] {
        settingsValues[pluginID] ?? loadSettings(pluginID: pluginID)
    }

    func value(forKey key: String, pluginID: String) -> PluginSettingValue? {
        settings(forPluginID: pluginID)[key]
    }

    func setValue(_ value: PluginSettingValue, forKey key: String, pluginID: String) {
        var current = settings(forPluginID: pluginID)
        current[key] = value
        settingsValues[pluginID] = current
        persistSettings(current, pluginID: pluginID)
    }

    func resetSettings(forPluginID pluginID: String) {
        settingsValues[pluginID] = [:]
        userDefaults.removeObject(forKey: DefaultsKey.settings(pluginID))
    }

    private func loadSettings(pluginID: String) -> [String: PluginSettingValue] {
        guard let data = userDefaults.data(forKey: DefaultsKey.settings(pluginID)),
              let decoded = try? JSONDecoder().decode([String: PluginSettingValue].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistSettings(_ values: [String: PluginSettingValue], pluginID: String) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        userDefaults.set(data, forKey: DefaultsKey.settings(pluginID))
    }
}
