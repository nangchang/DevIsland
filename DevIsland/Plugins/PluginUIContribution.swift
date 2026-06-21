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

enum PluginRegionID: String, Codable, CaseIterable, Hashable {
    case notchCompactLeading = "notch.compact.leading"
    case notchCompactCenter = "notch.compact.center"
    case notchCompactTrailing = "notch.compact.trailing"
}

struct PluginCompactRegionContext: Equatable {
    let region: PluginRegionID
    let timestamp: Date
    let language: AppLanguage
}

struct PluginCompactRegionContribution: Codable, Equatable {
    let pluginID: String
    let region: PluginRegionID
    let expiresAt: Date?
    let content: PluginCompactRegionContent
}

enum PluginCompactRegionContent: Codable, Equatable {
    case text(String)
    case metric(label: String?, value: String)
    case badge(String, tone: PluginUITone)
    case symbol(name: String, tone: PluginUITone)
    /// Host-known buddy identifier. The host owns sprite rendering and animation.
    case buddy(kind: String)
}

func isActiveCompactRegionContribution(
    _ contribution: PluginCompactRegionContribution,
    now: Date = Date()
) -> Bool {
    contribution.expiresAt == nil || contribution.expiresAt! > now
}

struct PluginUIContext: Equatable {
    let slot: PluginUISlot
    let timestamp: Date
    let session: PluginSessionSnapshot?
    /// The session the user is currently viewing (selected/current), if any. Lets global
    /// slots render for the user's selection instead of a recency proxy. `nil` when no
    /// session is selected, the host provides no selection signal (e.g. in tests), or the
    /// plugin lacks `readSessionEvents` (gated in `PluginEventProcessor`).
    let selectedSessionID: String?
    /// Current app language snapshot for plugin-owned contribution strings.
    let language: AppLanguage

    /// Explicit init keeps `selectedSessionID` immutable (`let`) while defaulting it, so a
    /// `let` with an inline default doesn't drop it from the memberwise initializer.
    init(
        slot: PluginUISlot,
        timestamp: Date,
        session: PluginSessionSnapshot?,
        selectedSessionID: String? = nil,
        language: AppLanguage = .english
    ) {
        self.slot = slot
        self.timestamp = timestamp
        self.session = session
        self.selectedSessionID = selectedSessionID
        self.language = language
    }
}

struct PluginSurfaceState: Codable, Equatable {
    let visibleSurfaces: Set<PluginUISlot>
    let visibleRegions: Set<PluginRegionID>

    init(
        visibleSurfaces: Set<PluginUISlot>,
        visibleRegions: Set<PluginRegionID> = []
    ) {
        self.visibleSurfaces = visibleSurfaces
        self.visibleRegions = visibleRegions
    }
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
    let evaluatedRegions: Set<PluginRegionID>
    let regionContributions: [PluginRegionID: PluginCompactRegionContribution]
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
