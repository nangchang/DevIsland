import Foundation

enum PluginPermission: String, Codable, CaseIterable, Hashable {
    case readSessionEvents
    case readHookSummaries
    case readTerminalMetadata
    case showNotchCard
    case showMenubarMenu
    case showSessionSurface
    case writePluginStorage
    case showNotification
    case playSound
    case controlPowerSleep
}

