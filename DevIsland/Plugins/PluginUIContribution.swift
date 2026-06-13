import Foundation

enum PluginUISlot: String, Codable, CaseIterable, Hashable {
    case notchExpandedActivity = "notch.expanded.activity"
    case notchExpandedDetails = "notch.expanded.details"
    case notchSessionRow = "notch.session.row"
    case menubarMenu = "menubar.menu"
    case sessionDetailTimeline = "session.detail.timeline"
    case sessionDetailSummary = "session.detail.summary"
    case sessionContextMenu = "session.context-menu"
    case sessionMessage = "session.message"
}

struct PluginUIContext: Equatable {
    let slot: PluginUISlot
    let timestamp: Date
    let session: PluginSessionSnapshot?
    /// The session the user is currently viewing (selected/current), if any. Lets global
    /// slots render for the user's selection instead of a recency proxy. `nil` when no
    /// session is selected or the host provides no selection signal (e.g. in tests).
    var selectedSessionID: String? = nil
}

struct PluginSurfaceState: Codable, Equatable {
    let visibleSurfaces: Set<PluginUISlot>
}

struct PluginUIContribution: Codable, Equatable {
    let pluginID: String
    let slot: PluginUISlot
    let targetSessionID: String?
    let priority: Int
    let expiresAt: Date?
    let components: [PluginUIComponentDTO]
}

func isActivePluginContribution(
    _ contribution: PluginUIContribution,
    now: Date = Date()
) -> Bool {
    !contribution.components.isEmpty &&
    (contribution.expiresAt == nil || contribution.expiresAt! > now)
}

func activePluginContributions(
    _ contributions: [PluginUIContribution],
    now: Date = Date()
) -> [PluginUIContribution] {
    contributions.filter { isActivePluginContribution($0, now: now) }
}

struct PluginUIComponentDTO: Codable, Equatable {
    let id: String
    let type: PluginUIComponentType
    let label: String?
    let value: String?
    let tone: PluginUITone?
    let iconName: String?
    let action: PluginUIActionDTO?
}

struct PluginUIActionDTO: Codable, Equatable {
    let id: String
    let capability: String
    let routing: PluginActionRouting
    let payload: [String: String]
}

enum PluginActionRouting: String, Codable {
    case hostExecuted
    case pluginEvent
}

enum PluginUIComponentType: String, Codable {
    case metric
    case badge
    case button
    case text
}

enum PluginUITone: String, Codable {
    case `default`
    case success
    case warning
    case error
}

// Runner-to-host result bundle kept in memory only; not part of plugin IPC or durable storage.
struct PluginContributionSnapshot: Equatable {
    let pluginID: String
    let sessionID: String?
    let evaluatedSlots: Set<PluginUISlot>
    let contributions: [PluginUISlot: PluginUIContribution]
    let effects: [PluginEffect]
    let failure: PluginFailure?
    let timestamp: Date
}

// Runtime failure metadata kept in memory only; safemode persistence will use a separate store.
struct PluginFailure: Equatable {
    let pluginID: String
    let message: String
    let occurredAt: Date
    let clearsContribution: Bool
}
