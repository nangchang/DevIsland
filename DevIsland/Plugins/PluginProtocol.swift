import Foundation

enum PluginKind: String, Codable {
    case system
    case utility
}

struct PluginManifest: Codable, Equatable {
    let id: String
    let name: String
    let version: String
    let apiVersion: Int
    let kind: PluginKind
    let permissions: Set<PluginPermission>
    let surfaces: Set<PluginUISlot>
    let activationEvents: Set<String>
    var localizedName: PluginLocalizedString? = nil

    func displayName(language: AppLanguage) -> String {
        localizedName?.resolved(for: language) ?? name
    }
}

protocol DevIslandPlugin: AnyObject {
    var manifest: PluginManifest { get }

    /// Declarative settings this plugin exposes. The host renders, validates, and persists
    /// them and injects the resolved values via `PluginContext.settings`. Defaults to none.
    var settingsSchema: [PluginSettingDescriptor] { get }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect]
    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution?
    func needsTick(surfaceState: PluginSurfaceState) -> Bool
}

extension DevIslandPlugin {
    var settingsSchema: [PluginSettingDescriptor] { [] }
}

struct PluginContext {
    let pluginID: String
    let permissions: Set<PluginPermission>
    let storageSnapshot: [String: String]
    let scopedFiles: PluginScopedFileClient?
    /// Current setting values, with every schema key present (stored value validated, or the
    /// descriptor default). Read-only — plugins never mutate host settings.
    let settings: [String: PluginSettingValue]
    /// Current app language snapshot. Plugins own their strings and choose localized text
    /// from this value instead of reaching into host-owned `L10n`.
    let language: AppLanguage

    init(
        pluginID: String,
        permissions: Set<PluginPermission>,
        storageSnapshot: [String: String],
        scopedFiles: PluginScopedFileClient? = nil,
        settings: [String: PluginSettingValue] = [:],
        language: AppLanguage = .english
    ) {
        self.pluginID = pluginID
        self.permissions = permissions
        self.storageSnapshot = storageSnapshot
        self.scopedFiles = scopedFiles
        self.settings = settings
        self.language = language
    }
}

struct PluginEffect: Codable, Equatable {
    let capability: String
    let payload: [String: String]
}
