import Foundation

/// Metadata for one host-executed plugin effect. Mirrors `SessionCommandDescriptor`: the catalog
/// (below) is the single place an effect's required permission is declared, so
/// `PluginEffectExecutor` and `PluginHost` validate effects through one path instead of parallel
/// `switch`es. (architecture doc §8, v1.2 command/effect validation 통합)
struct HostEffectDescriptor {
    /// The capability string a plugin effect/action carries (e.g. `"notification.show"`).
    let capability: String
    /// Permission the plugin's manifest must declare to run the effect. When the permission is
    /// `isSystemOnly`, the plugin must also declare `kind == .system` (see `isSupported`), so
    /// host-owned side effects like power assertions are gated by the plugin's declared trust
    /// tier rather than a hard-coded plugin-ID allowlist.
    let requiredPermission: PluginPermission
}

/// Host Effect Catalog for plugin effects routed to `PluginEffectExecutor`.
///
/// Validation lives here so the executor's `execute` only performs the side effect — the
/// system-only gate that used to be a `guard pluginID == "caffeine"` inside `execute` is now
/// derived from the required permission + the plugin's `kind` before the effect is dispatched.
enum HostEffectCatalog {
    static let effects: [String: HostEffectDescriptor] = [
        "storage.keyValue": HostEffectDescriptor(
            capability: "storage.keyValue", requiredPermission: .writePluginStorage),
        "storage.increment": HostEffectDescriptor(
            capability: "storage.increment", requiredPermission: .writePluginStorage),
        "notification.show": HostEffectDescriptor(
            capability: "notification.show", requiredPermission: .showNotification),
        "audio.playFile": HostEffectDescriptor(
            capability: "audio.playFile", requiredPermission: .playScopedAudio),
        "power.preventIdleSleep": HostEffectDescriptor(
            capability: "power.preventIdleSleep", requiredPermission: .controlPowerSleep),
        "power.toggle": HostEffectDescriptor(
            capability: "power.toggle", requiredPermission: .controlPowerSleep)
    ]

    static func descriptor(for capability: String) -> HostEffectDescriptor? {
        effects[capability]
    }

    /// True when the effect is known, the plugin holds the required permission, and — when that
    /// permission is system-only — the plugin declares `kind == .system`. Unknown effects are
    /// never supported.
    static func isSupported(
        _ capability: String,
        kind: PluginKind,
        permissions: Set<PluginPermission>
    ) -> Bool {
        guard let descriptor = effects[capability] else { return false }
        guard permissions.contains(descriptor.requiredPermission) else { return false }
        if descriptor.requiredPermission.isSystemOnly {
            return kind == .system
        }
        return true
    }
}
