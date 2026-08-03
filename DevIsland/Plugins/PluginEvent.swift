import Foundation

enum PluginEventKind: String, Codable, CaseIterable {
    case appStarted = "app.started"
    case sessionStarted = "session.started"
    case sessionUpdated = "session.updated"
    case sessionEnded = "session.ended"
    case hookReceived = "hook.received"
    case approvalDecided = "approval.decided"
    case notificationShown = "notification.shown"
    case compactRegionShown = "compact.region.shown"
    case settingsChanged = "settings.changed"
    case languageChanged = "language.changed"
    case pluginStarted = "plugin.started"
    case pluginTick = "plugin.tick"
    case pluginActionInvoked = "plugin.action.invoked"
    case powerStatusChanged = "power.status.changed"
}

struct PluginEvent: Codable, Equatable {
    let id: UUID
    let kind: PluginEventKind
    let timestamp: Date
    let session: PluginSessionSnapshot?
    let hook: PluginHookSummary?
    let action: PluginActionEvent?
    let approval: PluginApprovalSummary?
    let powerStatus: PluginPowerStatus?

    init(
        id: UUID,
        kind: PluginEventKind,
        timestamp: Date,
        session: PluginSessionSnapshot? = nil,
        hook: PluginHookSummary? = nil,
        action: PluginActionEvent? = nil,
        approval: PluginApprovalSummary? = nil,
        powerStatus: PluginPowerStatus? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.session = session
        self.hook = hook
        self.action = action
        self.approval = approval
        self.powerStatus = powerStatus
    }
}

struct PluginSessionSnapshot: Codable, Equatable {
    let id: String
    let agentKind: String
    let startTime: Date
    let lastActiveAt: Date
    let lastToolName: String?
    let lastEventName: String?
    let workspaceRoot: String?
}

struct PluginHookSummary: Codable, Equatable {
    let provider: String
    let eventType: String
    let commandSummary: String?
    let cwd: String?
    let terminalApp: String?
    let rawEvent: String?
    let toolName: String?
    let notificationType: String?
    let message: String?
    let payload: [String: AnyJSON]?
}

struct PluginActionEvent: Codable, Equatable {
    let pluginID: String
    let actionID: String
    let componentID: String
    let capability: String
    let payload: [String: String]
    let value: String?
}

struct PluginApprovalSummary: Codable, Equatable {
    let sessionID: String
    let approved: Bool
    let toolName: String
    let scope: String
}

/// Generic, sanitized power signal delivered to power-control plugins. Field names stay
/// host-implementation-agnostic (no "caffeine"/"assertion" leakage): the plugin owns the
/// prevention policy and only sees system signals plus the result of its last effect.
struct PluginPowerStatus: Codable, Equatable {
    /// Whether the user-facing power-control feature is enabled.
    let featureEnabled: Bool
    let excludedSSIDs: [String]
    let isOnACPower: Bool
    let batteryLevel: Double?
    let currentSSID: String?
    /// Whether any VPN (e.g. FortiClient) is currently connected.
    let isVPNConnected: Bool
    /// Whether the "activate on VPN" behavior is enabled by the user. Defaults to a
    /// conservative `false` on this signal DTO (do not hold on VPN unless explicitly
    /// told); the runtime value is mirrored from `SettingsStore.caffeineActivateOnVPN`
    /// (which defaults to `true`) by `CaffeineCoordinator`.
    let activateOnVPN: Bool
    /// Result feedback (host → plugin) after a `power.preventIdleSleep` effect was applied.
    let isPreventingSleep: Bool?
    let effectReason: String?
    let effectFailureCode: Int32?
    /// True when this event reports an effect result rather than a fresh input signal.
    let isEffectResult: Bool
    /// True when all sessions have been idle or terminated for the configured timeout duration.
    let sessionIdleTimedOut: Bool

    init(
        featureEnabled: Bool,
        excludedSSIDs: [String],
        isOnACPower: Bool,
        batteryLevel: Double?,
        currentSSID: String?,
        isVPNConnected: Bool = false,
        activateOnVPN: Bool = false,
        isPreventingSleep: Bool? = nil,
        effectReason: String? = nil,
        effectFailureCode: Int32? = nil,
        isEffectResult: Bool = false,
        sessionIdleTimedOut: Bool = false
    ) {
        self.featureEnabled = featureEnabled
        self.excludedSSIDs = excludedSSIDs
        self.isOnACPower = isOnACPower
        self.batteryLevel = batteryLevel
        self.currentSSID = currentSSID
        self.isVPNConnected = isVPNConnected
        self.activateOnVPN = activateOnVPN
        self.isPreventingSleep = isPreventingSleep
        self.effectReason = effectReason
        self.effectFailureCode = effectFailureCode
        self.isEffectResult = isEffectResult
        self.sessionIdleTimedOut = sessionIdleTimedOut
    }
}
