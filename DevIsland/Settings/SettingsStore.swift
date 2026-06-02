import Foundation
import Combine

// MARK: - Approval Proxy Settings

enum ClaudeSessionApprovalMode: String, CaseIterable, Identifiable {
    case nativePermissions
    case appSessionCache
    case hybrid

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .nativePermissions: return l.modeNative
        case .appSessionCache:   return l.modeCache
        case .hybrid:            return l.modeHybrid
        }
    }

    var detail: String {
        let l = L10n.shared
        switch self {
        case .nativePermissions: return l.detailNative
        case .appSessionCache:   return l.detailCache
        case .hybrid:            return l.detailHybrid
        }
    }
}

enum ClaudePersistentApprovalDestination: String, CaseIterable, Identifiable {
    case localSettings
    case projectSettings
    case userSettings

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .localSettings:   return l.destLocal
        case .projectSettings: return l.destProject
        case .userSettings:    return l.destUser
        }
    }

    var detail: String {
        let l = L10n.shared
        switch self {
        case .localSettings:   return l.detailDestLocal
        case .projectSettings: return l.detailDestProject
        case .userSettings:    return l.detailDestUser
        }
    }
}

enum BridgeTransportKind: String, CaseIterable, Identifiable {
    case tcpLoopback
    case unixDomainSocket

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .tcpLoopback:      return l.transportTCP
        case .unixDomainSocket: return l.transportUnix
        }
    }
}

enum ApprovalFallbackPolicy: String, CaseIterable, Identifiable {
    case pass
    case deny

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .pass:         return l.fallbackPass
        case .deny:         return l.fallbackDeny
        }
    }
}

enum NotchCharacterMode: String, CaseIterable, Identifiable {
    case hidden
    case random
    case specific

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .hidden:   return l.notchCharacterHidden
        case .random:   return l.notchCharacterRandom
        case .specific: return l.notchCharacterSpecific
        }
    }
}

enum NotchUnreadDotPosition: String, CaseIterable, Identifiable {
    case left
    case center
    case right

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .left:   return l.posLeft
        case .center: return l.posCenter
        case .right:  return l.posRight
        }
    }
}

enum NotchShapeStyle: String, CaseIterable, Identifiable {
    case classic
    case dynamicIsland

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .classic:       return l.notchShapeClassic
        case .dynamicIsland: return l.notchShapeDynamicIsland
        }
    }
}

enum NotchAutoCollapseDelay: String, CaseIterable, Identifiable {
    case off
    case seconds3
    case seconds5
    case seconds10
    case seconds30

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .off:       return nil
        case .seconds3:  return 3
        case .seconds5:  return 5
        case .seconds10: return 10
        case .seconds30: return 30
        }
    }

    var label: String {
        let l = L10n.shared
        switch self {
        case .off:       return l.notchAutoCollapseOff
        case .seconds3:  return l.labelSeconds(3)
        case .seconds5:  return l.labelSeconds(5)
        case .seconds10: return l.labelSeconds(10)
        case .seconds30: return l.labelSeconds(30)
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
    var permissionTimeoutSeconds: Double
    var replayRetentionDays: Int
    var ptyEnabled: Bool
    var ptyAutoInjectPatterns: [PTYAutoInjectPattern]
    var ptyTranscriptRetentionDays: Int
    var openPeonEnabled: Bool
    var openPeonPacksDirectory: String
    var openPeonActivePackName: String?
    var openPeonMasterVolume: Double
    var openPeonGlobalMuted: Bool
    var openPeonMutedCategories: Set<String>
    var openPeonDebounceMilliseconds: Int
    var notchPanelOpacity: Double
    var notchBackdropShadowEnabled: Bool
    var notchShapeStyle: NotchShapeStyle
    var collapsedNotchWidth: Double
    var collapsedNotchHeight: Double
    var expandedNotchWidth: Double
    var expandedNotchHeight: Double
    var notchAutoExpandEnabled: Bool
    var notchUnreadDotPosition: NotchUnreadDotPosition
    var notchAutoCollapseDelay: NotchAutoCollapseDelay
    var notchCharacterHorizontalInset: Double
    var notchCharacterVerticalOffset: Double
    var notchLeftCharacterMode: NotchCharacterMode
    var notchLeftCharacterKind: BuddyKind
    var notchLeftRandomCharacterKinds: Set<BuddyKind>
    var notchRightCharacterMode: NotchCharacterMode
    var notchRightCharacterKind: BuddyKind
    var notchRightRandomCharacterKinds: Set<BuddyKind>
    var notchCenterText: String
    var expandOnNotification: Bool
    var expandOnTaskCompletion: Bool
    var expandOnIdlePrompt: Bool
    var expandOnNotificationMessage: Bool
    var expandOnInteractiveTool: Bool
    var expandOnApprovalRequest: Bool
    var expandOnQuestionResponse: Bool
    var preferredTerminal: String?
    var checkForUpdatesOnStartup: Bool
    var processVSCodeEnabled: Bool
    var processClaudeDesktopEnabled: Bool
    var notchAnimationEnabled: Bool
    var caffeineEnabled: Bool
    var caffeineExcludedSSIDs: [String]

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

    static let defaultOpenPeonPacksDirectory: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openpeon", isDirectory: true)
            .appendingPathComponent("packs", isDirectory: true)
            .path
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
        approvalFallbackPolicy: .pass,
        permissionTimeoutSeconds: 120,
        replayRetentionDays: 30,
        ptyEnabled: false,
        ptyAutoInjectPatterns: [],
        ptyTranscriptRetentionDays: 7,
        openPeonEnabled: false,
        openPeonPacksDirectory: defaultOpenPeonPacksDirectory,
        openPeonActivePackName: nil,
        openPeonMasterVolume: 0.7,
        openPeonGlobalMuted: false,
        openPeonMutedCategories: [
            CESPCategory.taskAcknowledge.rawValue,
            CESPCategory.taskProgress.rawValue,
            CESPCategory.sessionEnd.rawValue,
            CESPCategory.userSpam.rawValue
        ],
        openPeonDebounceMilliseconds: 1500,
        notchPanelOpacity: 1.0,
        notchBackdropShadowEnabled: true,
        notchShapeStyle: .classic,
        collapsedNotchWidth: 260,
        collapsedNotchHeight: 32,
        expandedNotchWidth: 692,
        expandedNotchHeight: 300,
        notchAutoExpandEnabled: true,
        notchUnreadDotPosition: .right,
        notchAutoCollapseDelay: .seconds5,
        notchCharacterHorizontalInset: 24,
        notchCharacterVerticalOffset: 4,
        notchLeftCharacterMode: .random,
        notchLeftCharacterKind: .claudeCode,
        notchLeftRandomCharacterKinds: Set(BuddyKind.defaultRandomCases),
        notchRightCharacterMode: .random,
        notchRightCharacterKind: .gemini,
        notchRightRandomCharacterKinds: Set(BuddyKind.defaultRandomCases),
        notchCenterText: "DevIsland",
        expandOnNotification: true,
        expandOnTaskCompletion: true,
        expandOnIdlePrompt: true,
        expandOnNotificationMessage: true,
        expandOnInteractiveTool: true,
        expandOnApprovalRequest: true,
        expandOnQuestionResponse: true,
        preferredTerminal: nil,
        checkForUpdatesOnStartup: true,
        processVSCodeEnabled: false,
        processClaudeDesktopEnabled: false,
        notchAnimationEnabled: true,
        caffeineEnabled: true,
        caffeineExcludedSSIDs: []
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
        static let permissionTimeoutSeconds = "permissionTimeoutSeconds"
        static let replayRetentionDays = "replayRetentionDays"
        static let ptyEnabled = "ptyEnabled"
        static let ptyAutoInjectPatterns = "ptyAutoInjectPatterns"
        static let ptyTranscriptRetentionDays = "ptyTranscriptRetentionDays"
        static let openPeonEnabled = "openPeonEnabled"
        static let openPeonPacksDirectory = "openPeonPacksDirectory"
        static let openPeonActivePackName = "openPeonActivePackName"
        static let openPeonMasterVolume = "openPeonMasterVolume"
        static let openPeonGlobalMuted = "openPeonGlobalMuted"
        static let openPeonMutedCategories = "openPeonMutedCategories"
        static let openPeonDebounceMilliseconds = "openPeonDebounceMilliseconds"
        static let notchBackgroundOpacity = "notchBackgroundOpacity"
        static let notchPanelOpacity = "notchPanelOpacity"
        static let notchBackdropShadowEnabled = "notchBackdropShadowEnabled"
        static let notchShapeStyle = "notchShapeStyle"
        static let collapsedNotchWidth = "collapsedNotchWidth"
        static let collapsedNotchHeight = "collapsedNotchHeight"
        static let expandedNotchWidth = "expandedNotchWidth"
        static let expandedNotchHeight = "expandedNotchHeight"
        static let notchAutoExpandEnabled = "notchAutoExpandEnabled"
        static let notchUnreadDotPosition = "notchUnreadDotPosition"
        static let notchAutoCollapseDelay = "notchAutoCollapseDelay"
        static let notchCharacterHorizontalInset = "notchCharacterHorizontalInset"
        static let notchCharacterVerticalOffset = "notchCharacterVerticalOffset"
        static let notchLeftCharacterMode = "notchLeftCharacterMode"
        static let notchLeftCharacterKind = "notchLeftCharacterKind"
        static let notchLeftRandomCharacterKinds = "notchLeftRandomCharacterKinds"
        static let notchRightCharacterMode = "notchRightCharacterMode"
        static let notchRightCharacterKind = "notchRightCharacterKind"
        static let notchRightRandomCharacterKinds = "notchRightRandomCharacterKinds"
        static let notchCenterText = "notchCenterText"
        static let expandOnNotification = "expandOnNotification"
        static let expandOnTaskCompletion = "expandOnTaskCompletion"
        static let expandOnIdlePrompt = "expandOnIdlePrompt"
        static let expandOnNotificationMessage = "expandOnNotificationMessage"
        static let expandOnInteractiveTool = "expandOnInteractiveTool"
        static let expandOnApprovalRequest = "expandOnApprovalRequest"
        static let expandOnQuestionResponse = "expandOnQuestionResponse"
        static let preferredTerminal = "preferredTerminal"
        static let checkForUpdatesOnStartup = "checkForUpdatesOnStartup"
        static let processVSCodeEnabled = "processVSCodeEnabled"
        static let processClaudeDesktopEnabled = "processClaudeDesktopEnabled"
        static let notchAnimationEnabled = "notchAnimationEnabled"
        static let caffeineEnabled = "caffeineEnabled"
        static let caffeineExcludedSSIDs = "caffeineExcludedSSIDs"
    }

    private let userDefaults: UserDefaults
    private let bridgeConfigURL: URL

    @Published var settings: AppSettings {
        didSet { save(settings, previous: oldValue) }
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

    private func save(_ settings: AppSettings, previous: AppSettings? = nil) {
        userDefaults.set(settings.claudeSessionApprovalMode.rawValue, forKey: DefaultsKey.claudeSessionApprovalMode)
        userDefaults.set(settings.claudePersistentApprovalDestination.rawValue, forKey: DefaultsKey.claudePersistentApprovalDestination)
        userDefaults.set(settings.bridgeTransportKind.rawValue, forKey: DefaultsKey.bridgeTransportKind)
        userDefaults.set(settings.bridgeSocketPath, forKey: DefaultsKey.bridgeSocketPath)
        userDefaults.set(settings.bridgeTcpPort, forKey: DefaultsKey.bridgeTcpPort)
        userDefaults.set(settings.bridgeConnectTimeoutSeconds, forKey: DefaultsKey.bridgeConnectTimeoutSeconds)
        userDefaults.set(settings.bridgeResponseTimeoutSeconds, forKey: DefaultsKey.bridgeResponseTimeoutSeconds)
        userDefaults.set(settings.bridgeFallbackToTcp, forKey: DefaultsKey.bridgeFallbackToTcp)
        userDefaults.set(settings.approvalFallbackPolicy.rawValue, forKey: DefaultsKey.approvalFallbackPolicy)
        userDefaults.set(settings.permissionTimeoutSeconds, forKey: DefaultsKey.permissionTimeoutSeconds)
        userDefaults.set(settings.replayRetentionDays, forKey: DefaultsKey.replayRetentionDays)
        userDefaults.set(settings.ptyEnabled, forKey: DefaultsKey.ptyEnabled)
        if let data = try? JSONEncoder().encode(settings.ptyAutoInjectPatterns) {
            userDefaults.set(data, forKey: DefaultsKey.ptyAutoInjectPatterns)
        }
        userDefaults.set(settings.ptyTranscriptRetentionDays, forKey: DefaultsKey.ptyTranscriptRetentionDays)
        userDefaults.set(settings.openPeonEnabled, forKey: DefaultsKey.openPeonEnabled)
        userDefaults.set(settings.openPeonPacksDirectory, forKey: DefaultsKey.openPeonPacksDirectory)
        userDefaults.set(settings.openPeonActivePackName, forKey: DefaultsKey.openPeonActivePackName)
        userDefaults.set(settings.openPeonMasterVolume, forKey: DefaultsKey.openPeonMasterVolume)
        userDefaults.set(settings.openPeonGlobalMuted, forKey: DefaultsKey.openPeonGlobalMuted)
        userDefaults.set(Array(settings.openPeonMutedCategories).sorted(), forKey: DefaultsKey.openPeonMutedCategories)
        userDefaults.set(settings.openPeonDebounceMilliseconds, forKey: DefaultsKey.openPeonDebounceMilliseconds)
        userDefaults.set(settings.notchPanelOpacity, forKey: DefaultsKey.notchPanelOpacity)
        userDefaults.set(settings.notchBackdropShadowEnabled, forKey: DefaultsKey.notchBackdropShadowEnabled)
        userDefaults.set(settings.notchShapeStyle.rawValue, forKey: DefaultsKey.notchShapeStyle)
        userDefaults.set(settings.collapsedNotchWidth, forKey: DefaultsKey.collapsedNotchWidth)
        userDefaults.set(settings.collapsedNotchHeight, forKey: DefaultsKey.collapsedNotchHeight)
        userDefaults.set(settings.expandedNotchWidth, forKey: DefaultsKey.expandedNotchWidth)
        userDefaults.set(settings.expandedNotchHeight, forKey: DefaultsKey.expandedNotchHeight)
        userDefaults.set(settings.notchAutoExpandEnabled, forKey: DefaultsKey.notchAutoExpandEnabled)
        userDefaults.set(settings.notchUnreadDotPosition.rawValue, forKey: DefaultsKey.notchUnreadDotPosition)
        userDefaults.set(settings.notchAutoCollapseDelay.rawValue, forKey: DefaultsKey.notchAutoCollapseDelay)
        userDefaults.set(settings.notchCharacterHorizontalInset, forKey: DefaultsKey.notchCharacterHorizontalInset)
        userDefaults.set(settings.notchCharacterVerticalOffset, forKey: DefaultsKey.notchCharacterVerticalOffset)
        userDefaults.set(settings.notchLeftCharacterMode.rawValue, forKey: DefaultsKey.notchLeftCharacterMode)
        userDefaults.set(settings.notchLeftCharacterKind.rawValue, forKey: DefaultsKey.notchLeftCharacterKind)
        userDefaults.set(settings.notchLeftRandomCharacterKinds.map(\.rawValue).sorted(), forKey: DefaultsKey.notchLeftRandomCharacterKinds)
        userDefaults.set(settings.notchRightCharacterMode.rawValue, forKey: DefaultsKey.notchRightCharacterMode)
        userDefaults.set(settings.notchRightCharacterKind.rawValue, forKey: DefaultsKey.notchRightCharacterKind)
        userDefaults.set(settings.notchRightRandomCharacterKinds.map(\.rawValue).sorted(), forKey: DefaultsKey.notchRightRandomCharacterKinds)
        userDefaults.set(settings.notchCenterText, forKey: DefaultsKey.notchCenterText)
        userDefaults.set(settings.expandOnNotification, forKey: DefaultsKey.expandOnNotification)
        userDefaults.set(settings.expandOnTaskCompletion, forKey: DefaultsKey.expandOnTaskCompletion)
        userDefaults.set(settings.expandOnIdlePrompt, forKey: DefaultsKey.expandOnIdlePrompt)
        userDefaults.set(settings.expandOnNotificationMessage, forKey: DefaultsKey.expandOnNotificationMessage)
        userDefaults.set(settings.expandOnInteractiveTool, forKey: DefaultsKey.expandOnInteractiveTool)
        userDefaults.set(settings.expandOnApprovalRequest, forKey: DefaultsKey.expandOnApprovalRequest)
        userDefaults.set(settings.expandOnQuestionResponse, forKey: DefaultsKey.expandOnQuestionResponse)
        userDefaults.set(settings.preferredTerminal, forKey: DefaultsKey.preferredTerminal)
        userDefaults.set(settings.checkForUpdatesOnStartup, forKey: DefaultsKey.checkForUpdatesOnStartup)
        userDefaults.set(settings.processVSCodeEnabled, forKey: DefaultsKey.processVSCodeEnabled)
        userDefaults.set(settings.processClaudeDesktopEnabled, forKey: DefaultsKey.processClaudeDesktopEnabled)
        userDefaults.set(settings.notchAnimationEnabled, forKey: DefaultsKey.notchAnimationEnabled)
        userDefaults.set(settings.caffeineEnabled, forKey: DefaultsKey.caffeineEnabled)
        userDefaults.set(settings.caffeineExcludedSSIDs, forKey: DefaultsKey.caffeineExcludedSSIDs)
        // 브리지 관련 필드가 변경된 경우에만 파일 쓰기 (드래그 리사이즈 등 빈번한 UI 변경 시 파일 I/O 방지)
        let bridgeChanged = previous.map { BridgeRuntimeConfig(settings: settings) != BridgeRuntimeConfig(settings: $0) } ?? true
        if bridgeChanged {
            writeBridgeConfig(settings)
        }
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
            permissionTimeoutSeconds: positiveDouble(
                key: DefaultsKey.permissionTimeoutSeconds,
                from: userDefaults,
                default: defaults.permissionTimeoutSeconds
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
            ),
            openPeonEnabled: bool(
                key: DefaultsKey.openPeonEnabled,
                from: userDefaults,
                default: defaults.openPeonEnabled
            ),
            openPeonPacksDirectory: nonEmptyString(
                key: DefaultsKey.openPeonPacksDirectory,
                from: userDefaults,
                default: defaults.openPeonPacksDirectory
            ),
            openPeonActivePackName: userDefaults.string(forKey: DefaultsKey.openPeonActivePackName),
            openPeonMasterVolume: boundedDouble(
                key: DefaultsKey.openPeonMasterVolume,
                from: userDefaults,
                default: defaults.openPeonMasterVolume,
                range: 0...1
            ),
            openPeonGlobalMuted: bool(
                key: DefaultsKey.openPeonGlobalMuted,
                from: userDefaults,
                default: defaults.openPeonGlobalMuted
            ),
            openPeonMutedCategories: {
                guard let values = userDefaults.stringArray(forKey: DefaultsKey.openPeonMutedCategories) else {
                    return defaults.openPeonMutedCategories
                }
                return Set(values)
            }(),
            openPeonDebounceMilliseconds: positiveInt(
                key: DefaultsKey.openPeonDebounceMilliseconds,
                from: userDefaults,
                default: defaults.openPeonDebounceMilliseconds
            ),
            notchPanelOpacity: boundedDouble(
                key: DefaultsKey.notchPanelOpacity,
                fallbackKey: DefaultsKey.notchBackgroundOpacity,
                from: userDefaults,
                default: defaults.notchPanelOpacity,
                range: 0.4...1.0
            ),
            notchBackdropShadowEnabled: bool(
                key: DefaultsKey.notchBackdropShadowEnabled,
                from: userDefaults,
                default: defaults.notchBackdropShadowEnabled
            ),
            notchShapeStyle: enumValue(
                NotchShapeStyle.self,
                key: DefaultsKey.notchShapeStyle,
                from: userDefaults,
                default: defaults.notchShapeStyle
            ),
            collapsedNotchWidth: boundedDouble(
                key: DefaultsKey.collapsedNotchWidth,
                from: userDefaults,
                default: defaults.collapsedNotchWidth,
                range: 180...420
            ),
            collapsedNotchHeight: boundedDouble(
                key: DefaultsKey.collapsedNotchHeight,
                from: userDefaults,
                default: defaults.collapsedNotchHeight,
                range: 24...56
            ),
            expandedNotchWidth: boundedDouble(
                key: DefaultsKey.expandedNotchWidth,
                from: userDefaults,
                default: defaults.expandedNotchWidth,
                range: 610...1200
            ),
            expandedNotchHeight: boundedDouble(
                key: DefaultsKey.expandedNotchHeight,
                from: userDefaults,
                default: defaults.expandedNotchHeight,
                range: 240...720
            ),
            notchAutoExpandEnabled: bool(
                key: DefaultsKey.notchAutoExpandEnabled,
                from: userDefaults,
                default: defaults.notchAutoExpandEnabled
            ),
            notchUnreadDotPosition: enumValue(
                NotchUnreadDotPosition.self,
                key: DefaultsKey.notchUnreadDotPosition,
                from: userDefaults,
                default: defaults.notchUnreadDotPosition
            ),
            notchAutoCollapseDelay: enumValue(
                NotchAutoCollapseDelay.self,
                key: DefaultsKey.notchAutoCollapseDelay,
                from: userDefaults,
                default: defaults.notchAutoCollapseDelay
            ),
            notchCharacterHorizontalInset: boundedDouble(
                key: DefaultsKey.notchCharacterHorizontalInset,
                from: userDefaults,
                default: defaults.notchCharacterHorizontalInset,
                range: 12...64
            ),
            notchCharacterVerticalOffset: boundedDouble(
                key: DefaultsKey.notchCharacterVerticalOffset,
                from: userDefaults,
                default: defaults.notchCharacterVerticalOffset,
                range: -8...12
            ),
            notchLeftCharacterMode: enumValue(
                NotchCharacterMode.self,
                key: DefaultsKey.notchLeftCharacterMode,
                from: userDefaults,
                default: defaults.notchLeftCharacterMode
            ),
            notchLeftCharacterKind: enumValue(
                BuddyKind.self,
                key: DefaultsKey.notchLeftCharacterKind,
                from: userDefaults,
                default: defaults.notchLeftCharacterKind
            ),
            notchLeftRandomCharacterKinds: buddyKindSet(
                key: DefaultsKey.notchLeftRandomCharacterKinds,
                from: userDefaults,
                default: defaults.notchLeftRandomCharacterKinds
            ),
            notchRightCharacterMode: enumValue(
                NotchCharacterMode.self,
                key: DefaultsKey.notchRightCharacterMode,
                from: userDefaults,
                default: defaults.notchRightCharacterMode
            ),
            notchRightCharacterKind: enumValue(
                BuddyKind.self,
                key: DefaultsKey.notchRightCharacterKind,
                from: userDefaults,
                default: defaults.notchRightCharacterKind
            ),
            notchRightRandomCharacterKinds: buddyKindSet(
                key: DefaultsKey.notchRightRandomCharacterKinds,
                from: userDefaults,
                default: defaults.notchRightRandomCharacterKinds
            ),
            notchCenterText: userDefaults.string(forKey: DefaultsKey.notchCenterText) ?? defaults.notchCenterText,
            expandOnNotification: bool(
                key: DefaultsKey.expandOnNotification,
                from: userDefaults,
                default: defaults.expandOnNotification
            ),
            // 마이그레이션: 세 하위 키가 아직 없으면 기존 expandOnNotification 값을 초기값으로 사용한다.
            // 이렇게 해야 업그레이드 후 부모 토글을 다시 켰을 때 하위 설정도 원래 의도를 유지한다.
            expandOnTaskCompletion: bool(
                key: DefaultsKey.expandOnTaskCompletion,
                from: userDefaults,
                default: (userDefaults.object(forKey: DefaultsKey.expandOnNotification) as? Bool) ?? defaults.expandOnTaskCompletion
            ),
            expandOnIdlePrompt: bool(
                key: DefaultsKey.expandOnIdlePrompt,
                from: userDefaults,
                default: (userDefaults.object(forKey: DefaultsKey.expandOnNotification) as? Bool) ?? defaults.expandOnIdlePrompt
            ),
            expandOnNotificationMessage: bool(
                key: DefaultsKey.expandOnNotificationMessage,
                from: userDefaults,
                default: (userDefaults.object(forKey: DefaultsKey.expandOnNotification) as? Bool) ?? defaults.expandOnNotificationMessage
            ),
            expandOnInteractiveTool: bool(
                key: DefaultsKey.expandOnInteractiveTool,
                from: userDefaults,
                default: defaults.expandOnInteractiveTool
            ),
            expandOnApprovalRequest: bool(
                key: DefaultsKey.expandOnApprovalRequest,
                from: userDefaults,
                default: defaults.expandOnApprovalRequest
            ),
            expandOnQuestionResponse: bool(
                key: DefaultsKey.expandOnQuestionResponse,
                from: userDefaults,
                default: defaults.expandOnQuestionResponse
            ),
            preferredTerminal: userDefaults.string(forKey: DefaultsKey.preferredTerminal),
            checkForUpdatesOnStartup: bool(
                key: DefaultsKey.checkForUpdatesOnStartup,
                from: userDefaults,
                default: defaults.checkForUpdatesOnStartup
            ),
            processVSCodeEnabled: bool(
                key: DefaultsKey.processVSCodeEnabled,
                from: userDefaults,
                default: defaults.processVSCodeEnabled
            ),
            processClaudeDesktopEnabled: bool(
                key: DefaultsKey.processClaudeDesktopEnabled,
                from: userDefaults,
                default: defaults.processClaudeDesktopEnabled
            ),
            notchAnimationEnabled: bool(
                key: DefaultsKey.notchAnimationEnabled,
                from: userDefaults,
                default: defaults.notchAnimationEnabled
            ),
            caffeineEnabled: bool(
                key: DefaultsKey.caffeineEnabled,
                from: userDefaults,
                default: defaults.caffeineEnabled
            ),
            caffeineExcludedSSIDs: (userDefaults.stringArray(forKey: DefaultsKey.caffeineExcludedSSIDs) ?? defaults.caffeineExcludedSSIDs)
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

    private static func boundedDouble(
        key: String,
        fallbackKey: String? = nil,
        from userDefaults: UserDefaults,
        default defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        let resolvedKey: String
        if userDefaults.object(forKey: key) != nil {
            resolvedKey = key
        } else if let fallbackKey, userDefaults.object(forKey: fallbackKey) != nil {
            resolvedKey = fallbackKey
        } else {
            return defaultValue
        }

        let value = userDefaults.double(forKey: resolvedKey)
        return range.contains(value) ? value : defaultValue
    }

    private static func bool(key: String, from userDefaults: UserDefaults, default defaultValue: Bool) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        return userDefaults.bool(forKey: key)
    }

    private static func buddyKindSet(
        key: String,
        from userDefaults: UserDefaults,
        default defaultValue: Set<BuddyKind>
    ) -> Set<BuddyKind> {
        guard let values = userDefaults.stringArray(forKey: key) else { return defaultValue }
        let kinds = Set(values.compactMap(BuddyKind.init(rawValue:)))
        return kinds.isEmpty ? defaultValue : kinds
    }
}
