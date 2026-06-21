import Foundation

enum BuiltInPluginID {
    static let openPeon = "devisland.builtin.openpeon"
    static let caffeine = "devisland.builtin.caffeine"
    static let sessionStats = "devisland.builtin.session-stats"
    static let sessionTimer = "devisland.builtin.session-timer"
    static let sessionActions = "devisland.builtin.session-actions"
    static let pomodoro = "devisland.builtin.pomodoro"
    static let compactAppearance = "devisland.builtin.compact-appearance"

    static let legacyMappings: [String: String] = [
        "openpeon": openPeon,
        "caffeine": caffeine,
        "com.devisland.stats": sessionStats,
        "com.devisland.timer": sessionTimer,
        "com.devisland.session-actions": sessionActions,
        "com.devisland.pomodoro": pomodoro
    ]

    static func currentID(for pluginID: String) -> String {
        legacyMappings[pluginID] ?? pluginID
    }

    static func legacyIDs(for currentID: String) -> [String] {
        legacyMappings.compactMap { legacyID, mappedID in
            mappedID == currentID ? legacyID : nil
        }
    }
}
