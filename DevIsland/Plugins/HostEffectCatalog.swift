import Foundation

/// Metadata for one host-executed plugin effect. Mirrors `SessionCommandDescriptor`: the catalog
/// (below) is the single place an effect's required permission — and optional built-in allowlist —
/// is declared, so `PluginEffectExecutor` and `PluginHost` validate effects through one path
/// instead of parallel `switch`es. (architecture doc §8, v1.2 command/effect validation 통합)
struct HostEffectDescriptor {
    /// The capability string a plugin effect/action carries (e.g. `"notification.show"`).
    let capability: String
    /// Permission the plugin's manifest must declare to run the effect.
    let requiredPermission: PluginPermission
    /// When non-nil, only these compiled built-in plugin IDs may run the effect. Used for
    /// host-owned side effects that are not exposed as a permission-gated public capability
    /// (e.g. power assertions), so a third-party plugin holding the permission still cannot run
    /// them. `nil` means the permission alone authorizes any plugin.
    let builtInOnlyPluginIDs: Set<String>?
}

/// Host Effect Catalog for plugin effects routed to `PluginEffectExecutor`.
///
/// Validation lives here so the executor's `execute` only performs the side effect — the
/// built-in allowlist that used to be a `guard pluginID == "caffeine"` inside `execute` is now
/// declared as catalog metadata and enforced before the effect is ever dispatched.
enum HostEffectCatalog {
    static let effects: [String: HostEffectDescriptor] = [
        "storage.keyValue": HostEffectDescriptor(
            capability: "storage.keyValue", requiredPermission: .writePluginStorage, builtInOnlyPluginIDs: nil),
        "storage.increment": HostEffectDescriptor(
            capability: "storage.increment", requiredPermission: .writePluginStorage, builtInOnlyPluginIDs: nil),
        "notification.show": HostEffectDescriptor(
            capability: "notification.show", requiredPermission: .showNotification, builtInOnlyPluginIDs: nil),
        "sound.play": HostEffectDescriptor(
            capability: "sound.play", requiredPermission: .playSound, builtInOnlyPluginIDs: nil),
        "power.preventIdleSleep": HostEffectDescriptor(
            capability: "power.preventIdleSleep", requiredPermission: .controlPowerSleep, builtInOnlyPluginIDs: ["caffeine"]),
        "power.toggle": HostEffectDescriptor(
            capability: "power.toggle", requiredPermission: .controlPowerSleep, builtInOnlyPluginIDs: ["caffeine"])
    ]

    static func descriptor(for capability: String) -> HostEffectDescriptor? {
        effects[capability]
    }

    /// True when the effect is known, the plugin holds the required permission, and — if the effect
    /// is built-in-only — the plugin is on its allowlist. Unknown effects are never supported.
    static func isSupported(
        _ capability: String,
        pluginID: String,
        permissions: Set<PluginPermission>
    ) -> Bool {
        guard let descriptor = effects[capability] else { return false }
        guard permissions.contains(descriptor.requiredPermission) else { return false }
        if let allowlist = descriptor.builtInOnlyPluginIDs {
            return allowlist.contains(pluginID)
        }
        return true
    }
}
