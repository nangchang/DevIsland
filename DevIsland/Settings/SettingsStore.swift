import Foundation
import Combine
import os

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
        static let notchCompactLeadingSelection = "notchCompactLeadingSelection"
        static let notchCompactCenterSelection = "notchCompactCenterSelection"
        static let notchCompactTrailingSelection = "notchCompactTrailingSelection"
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
        static let aoeSessionFocusMode = "aoeSessionFocusMode"
        static let checkForUpdatesOnStartup = "checkForUpdatesOnStartup"
        static let processVSCodeEnabled = "processVSCodeEnabled"
        static let processClaudeDesktopEnabled = "processClaudeDesktopEnabled"
        static let processCodexDesktopEnabled = "processCodexDesktopEnabled"
        static let notchAnimationEnabled = "notchAnimationEnabled"
        static let notchAnimationSpeed = "notchAnimationSpeed"
        static let caffeineEnabled = "caffeineEnabled"
        static let caffeineExcludedSSIDs = "caffeineExcludedSSIDs"
        static let caffeineSessionTimeoutEnabled = "caffeineSessionTimeoutEnabled"
        static let caffeineSessionTimeoutMinutes = "caffeineSessionTimeoutMinutes"
        static let releaseChannel = "releaseChannel"
        static let notificationsEnabled = "notificationsEnabled"
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
        userDefaults.set(settings.notchCompactLeadingSelection.persistedValue, forKey: DefaultsKey.notchCompactLeadingSelection)
        userDefaults.set(settings.notchCompactCenterSelection.persistedValue, forKey: DefaultsKey.notchCompactCenterSelection)
        userDefaults.set(settings.notchCompactTrailingSelection.persistedValue, forKey: DefaultsKey.notchCompactTrailingSelection)
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
        userDefaults.set(settings.aoeSessionFocusMode.rawValue, forKey: DefaultsKey.aoeSessionFocusMode)
        userDefaults.set(settings.checkForUpdatesOnStartup, forKey: DefaultsKey.checkForUpdatesOnStartup)
        userDefaults.set(settings.processVSCodeEnabled, forKey: DefaultsKey.processVSCodeEnabled)
        userDefaults.set(settings.processClaudeDesktopEnabled, forKey: DefaultsKey.processClaudeDesktopEnabled)
        userDefaults.set(settings.processCodexDesktopEnabled, forKey: DefaultsKey.processCodexDesktopEnabled)
        userDefaults.set(settings.notchAnimationEnabled, forKey: DefaultsKey.notchAnimationEnabled)
        userDefaults.set(settings.notchAnimationSpeed, forKey: DefaultsKey.notchAnimationSpeed)
        userDefaults.set(settings.caffeineEnabled, forKey: DefaultsKey.caffeineEnabled)
        userDefaults.set(settings.caffeineExcludedSSIDs, forKey: DefaultsKey.caffeineExcludedSSIDs)
        userDefaults.set(settings.caffeineSessionTimeoutEnabled, forKey: DefaultsKey.caffeineSessionTimeoutEnabled)
        userDefaults.set(settings.caffeineSessionTimeoutMinutes, forKey: DefaultsKey.caffeineSessionTimeoutMinutes)
        userDefaults.set(settings.releaseChannel.rawValue, forKey: DefaultsKey.releaseChannel)
        userDefaults.set(settings.notificationsEnabled, forKey: DefaultsKey.notificationsEnabled)
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
            Log.core.error("SettingsStore: failed to write bridge config – \(error, privacy: .private)")
        }
    }
}
