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
}

struct PluginEvent: Codable, Equatable {
    let id: UUID
    let kind: PluginEventKind
    let timestamp: Date
    let session: PluginSessionSnapshot?
    let hook: PluginHookSummary?
    let action: PluginActionEvent?
    let approval: PluginApprovalSummary?
}

struct PluginSessionSnapshot: Codable, Equatable {
    let id: String
    let agentKind: String
    let startTime: Date
    let lastActiveAt: Date
    let lastToolName: String
    let lastEventName: String
    let workspaceRoot: String?
}

struct PluginHookSummary: Codable, Equatable {
    let provider: String
    let eventType: String
    let commandSummary: String?
    let cwd: String?
    let terminalApp: String?
}

struct PluginActionEvent: Codable, Equatable {
    let pluginID: String
    let actionID: String
    let componentID: String
    let value: String?
}

struct PluginApprovalSummary: Codable, Equatable {
    let sessionID: String
    let approved: Bool
    let toolName: String
    let scope: String
}

