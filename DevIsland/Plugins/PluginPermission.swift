import Foundation

enum PluginPermission: String, Codable, CaseIterable, Hashable {
    case readSessionEvents
    case readHookSummaries
    case readTerminalMetadata
    case showNotchCard
    case showMenubarMenu
    case showSessionSurface
    case writePluginStorage
    case readScopedFiles
    case playScopedAudio
    case showNotification
    case controlPowerSleep
}

extension PluginPermission {
    /// Permissions that touch system resources (e.g. power assertions). Only plugins that
    /// declare `kind == .system` may exercise effects requiring these, so the host gates by a
    /// plugin's declared trust tier instead of hard-coding specific plugin IDs.
    static let systemOnly: Set<PluginPermission> = [.controlPowerSleep]

    var isSystemOnly: Bool { Self.systemOnly.contains(self) }
}
