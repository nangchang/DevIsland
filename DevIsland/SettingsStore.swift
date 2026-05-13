import Foundation
import Combine

// MARK: - Approval Proxy Settings

enum ClaudeSessionApprovalMode: String, CaseIterable, Identifiable {
    case nativePermissions
    case appSessionCache
    case hybrid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nativePermissions: return "Native Claude permissions"
        case .appSessionCache: return "DevIsland-managed session cache"
        case .hybrid: return "Hybrid"
        }
    }

    var detail: String {
        switch self {
        case .nativePermissions:
            return "Recommended. DevIsland returns updatedPermissions with destination=session."
        case .appSessionCache:
            return "DevIsland stores session-scoped approvals and returns simple allow responses."
        case .hybrid:
            return "Use native Claude permissions first and keep DevIsland cache as fallback."
        }
    }
}

enum ClaudePersistentApprovalDestination: String, CaseIterable, Identifiable {
    case localSettings
    case projectSettings
    case userSettings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .localSettings: return "localSettings (.claude/settings.local.json)"
        case .projectSettings: return "projectSettings (.claude/settings.json)"
        case .userSettings: return "userSettings (~/.claude/settings.json)"
        }
    }
}

enum BridgeTransportKind: String, CaseIterable, Identifiable {
    case tcpLoopback
    case unixDomainSocket

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tcpLoopback: return "TCP loopback"
        case .unixDomainSocket: return "Unix domain socket"
        }
    }
}

enum ApprovalFallbackPolicy: String, CaseIterable, Identifiable {
    case denyUnknown
    case allowReadOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .denyUnknown: return "Deny unknown risk"
        case .allowReadOnly: return "Allow safe/read-only only"
        }
    }
}

struct AppSettings: Equatable {
    var claudeSessionApprovalMode: ClaudeSessionApprovalMode
    var claudePersistentApprovalDestination: ClaudePersistentApprovalDestination
    var bridgeTransportKind: BridgeTransportKind
    var bridgeSocketPath: String
    var bridgeTcpPort: Int
    var bridgeConnectTimeoutSeconds: Double
    var bridgeResponseTimeoutSeconds: Double
    var bridgeFallbackToTcp: Bool
    var approvalFallbackPolicy: ApprovalFallbackPolicy
    var replayRetentionDays: Int
    var ptyEnabled: Bool
    var ptyAutoInjectPatterns: [PTYAutoInjectPattern]
    var ptyTranscriptRetentionDays: Int

    static let defaultBridgeSocketPath: String = {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("DevIsland", isDirectory: true)
            .appendingPathComponent("dev-island.sock")
            .path
    }()

    static let defaultBridgeConfigURL: URL = {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("DevIsland", isDirectory: true)
            .appendingPathComponent("bridge-config.json")
    }()

    static let defaults = AppSettings(
        claudeSessionApprovalMode: .nativePermissions,
        claudePersistentApprovalDestination: .userSettings,
        bridgeTransportKind: .tcpLoopback,
        bridgeSocketPath: defaultBridgeSocketPath,
        bridgeTcpPort: 9090,
        bridgeConnectTimeoutSeconds: 5,
        bridgeResponseTimeoutSeconds: 300,
        bridgeFallbackToTcp: true,
        approvalFallbackPolicy: .denyUnknown,
        replayRetentionDays: 30,
        ptyEnabled: false,
        ptyAutoInjectPatterns: [],
        ptyTranscriptRetentionDays: 7
    )
}

struct BridgeRuntimeConfig: Codable, Equatable {
    let bridgeTransportKind: String
    let bridgeSocketPath: String
    let bridgeTcpPort: Int
    let bridgeConnectTimeoutSeconds: Double
    let bridgeResponseTimeoutSeconds: Double
    let bridgeFallbackToTcp: Bool
    let approvalFallbackPolicy: String

    init(settings: AppSettings) {
        self.bridgeTransportKind = settings.bridgeTransportKind.rawValue
        self.bridgeSocketPath = settings.bridgeSocketPath
        self.bridgeTcpPort = settings.bridgeTcpPort
        self.bridgeConnectTimeoutSeconds = settings.bridgeConnectTimeoutSeconds
        self.bridgeResponseTimeoutSeconds = settings.bridgeResponseTimeoutSeconds
        self.bridgeFallbackToTcp = settings.bridgeFallbackToTcp
        self.approvalFallbackPolicy = settings.approvalFallbackPolicy.rawValue
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    enum DefaultsKey {
        static let claudeSessionApprovalMode = "claudeSessionApprovalMode"
        static let claudePersistentApprovalDestination = "claudePersistentApprovalDestination"
        static let bridgeTransportKind = "bridgeTransportKind"
        static let bridgeSocketPath = "bridgeSocketPath"
        static let bridgeTcpPort = "bridgeTcpPort"
        static let bridgeConnectTimeoutSeconds = "bridgeConnectTimeoutSeconds"
        static let bridgeResponseTimeoutSeconds = "bridgeResponseTimeoutSeconds"
        static let bridgeFallbackToTcp = "bridgeFallbackToTcp"
        static let approvalFallbackPolicy = "approvalFallbackPolicy"
        static let replayRetentionDays = "replayRetentionDays"
        static let ptyEnabled = "ptyEnabled"
        static let ptyAutoInjectPatterns = "ptyAutoInjectPatterns"
        static let ptyTranscriptRetentionDays = "ptyTranscriptRetentionDays"
    }

    private let userDefaults: UserDefaults
    private let bridgeConfigURL: URL

    @Published var settings: AppSettings {
        didSet { save(settings) }
    }

    init(
        userDefaults: UserDefaults = .standard,
        bridgeConfigURL: URL = AppSettings.defaultBridgeConfigURL
    ) {
        self.userDefaults = userDefaults
        self.bridgeConfigURL = bridgeConfigURL
        self.settings = Self.load(from: userDefaults)
        writeBridgeConfig(settings)
    }

    func resetToDefaults() {
        settings = .defaults
    }

    private func save(_ settings: AppSettings) {
        userDefaults.set(settings.claudeSessionApprovalMode.rawValue, forKey: DefaultsKey.claudeSessionApprovalMode)
        userDefaults.set(settings.claudePersistentApprovalDestination.rawValue, forKey: DefaultsKey.claudePersistentApprovalDestination)
        userDefaults.set(settings.bridgeTransportKind.rawValue, forKey: DefaultsKey.bridgeTransportKind)
        userDefaults.set(settings.bridgeSocketPath, forKey: DefaultsKey.bridgeSocketPath)
        userDefaults.set(settings.bridgeTcpPort, forKey: DefaultsKey.bridgeTcpPort)
        userDefaults.set(settings.bridgeConnectTimeoutSeconds, forKey: DefaultsKey.bridgeConnectTimeoutSeconds)
        userDefaults.set(settings.bridgeResponseTimeoutSeconds, forKey: DefaultsKey.bridgeResponseTimeoutSeconds)
        userDefaults.set(settings.bridgeFallbackToTcp, forKey: DefaultsKey.bridgeFallbackToTcp)
        userDefaults.set(settings.approvalFallbackPolicy.rawValue, forKey: DefaultsKey.approvalFallbackPolicy)
        userDefaults.set(settings.replayRetentionDays, forKey: DefaultsKey.replayRetentionDays)
        userDefaults.set(settings.ptyEnabled, forKey: DefaultsKey.ptyEnabled)
        if let data = try? JSONEncoder().encode(settings.ptyAutoInjectPatterns) {
            userDefaults.set(data, forKey: DefaultsKey.ptyAutoInjectPatterns)
        }
        userDefaults.set(settings.ptyTranscriptRetentionDays, forKey: DefaultsKey.ptyTranscriptRetentionDays)
        writeBridgeConfig(settings)
    }

    private func writeBridgeConfig(_ settings: AppSettings) {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: bridgeConfigURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(BridgeRuntimeConfig(settings: settings))
            let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            if fileManager.fileExists(atPath: bridgeConfigURL.path) {
                let tempURL = bridgeConfigURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(bridgeConfigURL.lastPathComponent).\(UUID().uuidString).tmp")
                guard fileManager.createFile(atPath: tempURL.path, contents: data, attributes: attributes) else {
                    throw NSError(
                        domain: "SettingsStore",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unable to create temporary bridge config"]
                    )
                }
                _ = try fileManager.replaceItemAt(bridgeConfigURL, withItemAt: tempURL)
                try fileManager.setAttributes(attributes, ofItemAtPath: bridgeConfigURL.path)
            } else if !fileManager.createFile(atPath: bridgeConfigURL.path, contents: data, attributes: attributes) {
                throw NSError(
                    domain: "SettingsStore",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to create bridge config"]
                )
            }
        } catch {
            print("SettingsStore: failed to write bridge config – \(error)")
        }
    }

    private static func load(from userDefaults: UserDefaults) -> AppSettings {
        let defaults = AppSettings.defaults
        return AppSettings(
            claudeSessionApprovalMode: enumValue(
                ClaudeSessionApprovalMode.self,
                key: DefaultsKey.claudeSessionApprovalMode,
                from: userDefaults,
                default: defaults.claudeSessionApprovalMode
            ),
            claudePersistentApprovalDestination: enumValue(
                ClaudePersistentApprovalDestination.self,
                key: DefaultsKey.claudePersistentApprovalDestination,
                from: userDefaults,
                default: defaults.claudePersistentApprovalDestination
            ),
            bridgeTransportKind: enumValue(
                BridgeTransportKind.self,
                key: DefaultsKey.bridgeTransportKind,
                from: userDefaults,
                default: defaults.bridgeTransportKind
            ),
            bridgeSocketPath: nonEmptyString(
                key: DefaultsKey.bridgeSocketPath,
                from: userDefaults,
                default: defaults.bridgeSocketPath
            ),
            bridgeTcpPort: positiveInt(
                key: DefaultsKey.bridgeTcpPort,
                from: userDefaults,
                default: defaults.bridgeTcpPort
            ),
            bridgeConnectTimeoutSeconds: positiveDouble(
                key: DefaultsKey.bridgeConnectTimeoutSeconds,
                from: userDefaults,
                default: defaults.bridgeConnectTimeoutSeconds
            ),
            bridgeResponseTimeoutSeconds: positiveDouble(
                key: DefaultsKey.bridgeResponseTimeoutSeconds,
                from: userDefaults,
                default: defaults.bridgeResponseTimeoutSeconds
            ),
            bridgeFallbackToTcp: bool(
                key: DefaultsKey.bridgeFallbackToTcp,
                from: userDefaults,
                default: defaults.bridgeFallbackToTcp
            ),
            approvalFallbackPolicy: enumValue(
                ApprovalFallbackPolicy.self,
                key: DefaultsKey.approvalFallbackPolicy,
                from: userDefaults,
                default: defaults.approvalFallbackPolicy
            ),
            replayRetentionDays: positiveInt(
                key: DefaultsKey.replayRetentionDays,
                from: userDefaults,
                default: defaults.replayRetentionDays
            ),
            ptyEnabled: bool(
                key: DefaultsKey.ptyEnabled,
                from: userDefaults,
                default: defaults.ptyEnabled
            ),
            ptyAutoInjectPatterns: {
                guard let data = userDefaults.data(forKey: DefaultsKey.ptyAutoInjectPatterns),
                      let patterns = try? JSONDecoder().decode([PTYAutoInjectPattern].self, from: data) else {
                    return defaults.ptyAutoInjectPatterns
                }
                return patterns
            }(),
            ptyTranscriptRetentionDays: positiveInt(
                key: DefaultsKey.ptyTranscriptRetentionDays,
                from: userDefaults,
                default: defaults.ptyTranscriptRetentionDays
            )
        )
    }

    private static func enumValue<T: RawRepresentable>(
        _ type: T.Type,
        key: String,
        from userDefaults: UserDefaults,
        default defaultValue: T
    ) -> T where T.RawValue == String {
        guard let rawValue = userDefaults.string(forKey: key),
              let value = T(rawValue: rawValue) else {
            return defaultValue
        }
        return value
    }

    private static func nonEmptyString(key: String, from userDefaults: UserDefaults, default defaultValue: String) -> String {
        guard let value = userDefaults.string(forKey: key), !value.isEmpty else { return defaultValue }
        return value
    }

    private static func positiveInt(key: String, from userDefaults: UserDefaults, default defaultValue: Int) -> Int {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        let value = userDefaults.integer(forKey: key)
        return value > 0 ? value : defaultValue
    }

    private static func positiveDouble(key: String, from userDefaults: UserDefaults, default defaultValue: Double) -> Double {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        let value = userDefaults.double(forKey: key)
        return value > 0 ? value : defaultValue
    }

    private static func bool(key: String, from userDefaults: UserDefaults, default defaultValue: Bool) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        return userDefaults.bool(forKey: key)
    }
}
