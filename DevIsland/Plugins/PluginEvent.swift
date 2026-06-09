import Foundation

enum PluginEventKind: String, Codable, CaseIterable {
    case appStarted = "app.started"
    case sessionStarted = "session.started"
    case sessionUpdated = "session.updated"
    case sessionEnded = "session.ended"
    case hookReceived = "hook.received"
    case approvalDecided = "approval.decided"
    case notificationShown = "notification.shown"
    case settingsChanged = "settings.changed"
    case pluginStarted = "plugin.started"
    case pluginTick = "plugin.tick"
    case pluginActionInvoked = "plugin.action.invoked"
    case caffeineStatusChanged = "caffeine.status.changed"
}

struct PluginEvent: Codable, Equatable {
    let id: UUID
    let kind: PluginEventKind
    let timestamp: Date
    let session: PluginSessionSnapshot?
    let hook: PluginHookSummary?
    let action: PluginActionEvent?
    let approval: PluginApprovalSummary?
    let caffeineStatus: PluginCaffeineStatus?

    init(
        id: UUID,
        kind: PluginEventKind,
        timestamp: Date,
        session: PluginSessionSnapshot? = nil,
        hook: PluginHookSummary? = nil,
        action: PluginActionEvent? = nil,
        approval: PluginApprovalSummary? = nil,
        caffeineStatus: PluginCaffeineStatus? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.session = session
        self.hook = hook
        self.action = action
        self.approval = approval
        self.caffeineStatus = caffeineStatus
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

struct PluginCaffeineStatus: Codable, Equatable {
    let caffeineEnabled: Bool
    let excludedSSIDs: [String]
    let isOnACPower: Bool
    let batteryLevel: Double?
    let currentSSID: String?
}
