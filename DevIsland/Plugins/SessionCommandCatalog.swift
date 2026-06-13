import Foundation

/// Metadata for one host-executed `session.*` command. The catalog (below) is the single
/// place a session command is declared, so adding a command no longer means editing the
/// routing `switch` in `PluginHost` and the permission `switch` separately.
struct SessionCommandDescriptor {
    /// The capability string a plugin action carries (e.g. `"session.dismiss"`).
    let capability: String
    /// Permission the plugin's manifest must declare for the host to route the command.
    let requiredPermission: PluginPermission
    /// Whether the command mutates session lifecycle / approval state. Audit metadata only —
    /// the actual state re-validation lives in `AppState` (the session-state owner).
    let isDestructive: Bool
}

/// Host Command Catalog for validated `session.*` commands.
///
/// `PluginHost` gates the *permission* here; the injected `sessionCommandHandler` (AppState)
/// re-validates the *session state* it alone owns before acting. (architecture doc §7/§8)
enum SessionCommandCatalog {
    static let commands: [String: SessionCommandDescriptor] = [
        "session.dismiss": SessionCommandDescriptor(
            capability: "session.dismiss",
            requiredPermission: .showSessionSurface,
            isDestructive: true
        )
    ]

    static func descriptor(for capability: String) -> SessionCommandDescriptor? {
        commands[capability]
    }

    static func isSessionCommand(_ capability: String) -> Bool {
        commands[capability] != nil
    }

    /// True when the capability is a known session command *and* the plugin holds the
    /// permission it requires. Unknown capabilities are never allowed.
    static func isAllowed(_ capability: String, permissions: Set<PluginPermission>) -> Bool {
        guard let descriptor = commands[capability] else { return false }
        return permissions.contains(descriptor.requiredPermission)
    }
}
