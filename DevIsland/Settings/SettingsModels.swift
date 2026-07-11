import Foundation

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

enum AoESessionFocusMode: String, CaseIterable, Identifiable {
    case tmuxClient
    case managerSearch

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .tmuxClient:    return l.aoeFocusTmuxClient
        case .managerSearch: return l.aoeFocusManagerSearch
        }
    }

    var detail: String {
        let l = L10n.shared
        switch self {
        case .tmuxClient:    return l.detailAoEFocusTmuxClient
        case .managerSearch: return l.detailAoEFocusManagerSearch
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

struct NotchCompactRegionSelection: Equatable, Hashable {
    static let hiddenValue = "hidden"

    let providerID: String?

    static let hidden = NotchCompactRegionSelection(providerID: nil)

    static func provider(_ pluginID: String) -> NotchCompactRegionSelection {
        NotchCompactRegionSelection(providerID: pluginID)
    }

    init(providerID: String?) {
        let normalized = providerID.map(BuiltInPluginID.currentID(for:))
        self.providerID = normalized?.isEmpty == false ? normalized : nil
    }

    init(persistedValue: String, default defaultValue: NotchCompactRegionSelection) {
        if persistedValue == Self.hiddenValue {
            self = .hidden
        } else if persistedValue.isEmpty {
            self = defaultValue
        } else {
            self = .provider(persistedValue)
        }
    }

    var persistedValue: String { providerID ?? Self.hiddenValue }
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

enum ReleaseChannel: String, CaseIterable, Identifiable {
    case stable
    case nightly

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .stable:  return l.releaseChannelStable
        case .nightly: return l.releaseChannelNightly
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
    var notchCompactLeadingSelection: NotchCompactRegionSelection
    var notchCompactCenterSelection: NotchCompactRegionSelection
    var notchCompactTrailingSelection: NotchCompactRegionSelection
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
    var aoeSessionFocusMode: AoESessionFocusMode
    var checkForUpdatesOnStartup: Bool
    var processVSCodeEnabled: Bool
    var processClaudeDesktopEnabled: Bool
    var processCodexDesktopEnabled: Bool
    var notchAnimationEnabled: Bool
    var notchAnimationSpeed: Double
    var caffeineEnabled: Bool
    var caffeineExcludedSSIDs: [String]
    var caffeineSessionTimeoutEnabled: Bool
    var caffeineSessionTimeoutMinutes: Int
    var releaseChannel: ReleaseChannel
    var notificationsEnabled: Bool

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
        notchCompactLeadingSelection: .provider(BuiltInPluginID.compactAppearance),
        notchCompactCenterSelection: .provider(BuiltInPluginID.compactAppearance),
        notchCompactTrailingSelection: .provider(BuiltInPluginID.compactAppearance),
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
        aoeSessionFocusMode: .managerSearch,
        checkForUpdatesOnStartup: true,
        processVSCodeEnabled: false,
        processClaudeDesktopEnabled: false,
        processCodexDesktopEnabled: false,
        notchAnimationEnabled: true,
        notchAnimationSpeed: 1.0,
        caffeineEnabled: false,
        caffeineExcludedSSIDs: [],
        caffeineSessionTimeoutEnabled: false,
        caffeineSessionTimeoutMinutes: 5,
        releaseChannel: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").contains("nightly") ? .nightly : .stable,
        notificationsEnabled: false
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
