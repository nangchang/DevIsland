import Foundation

extension SettingsStore {
    static func load(from userDefaults: UserDefaults) -> AppSettings {
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
            notchCompactLeadingSelection: compactRegionSelection(
                key: DefaultsKey.notchCompactLeadingSelection,
                from: userDefaults,
                default: defaults.notchCompactLeadingSelection
            ),
            notchCompactCenterSelection: compactRegionSelection(
                key: DefaultsKey.notchCompactCenterSelection,
                from: userDefaults,
                default: defaults.notchCompactCenterSelection
            ),
            notchCompactTrailingSelection: compactRegionSelection(
                key: DefaultsKey.notchCompactTrailingSelection,
                from: userDefaults,
                default: defaults.notchCompactTrailingSelection
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
            aoeSessionFocusMode: enumValue(
                AoESessionFocusMode.self,
                key: DefaultsKey.aoeSessionFocusMode,
                from: userDefaults,
                default: defaults.aoeSessionFocusMode
            ),
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
            processCodexDesktopEnabled: bool(
                key: DefaultsKey.processCodexDesktopEnabled,
                from: userDefaults,
                default: defaults.processCodexDesktopEnabled
            ),
            notchAnimationEnabled: bool(
                key: DefaultsKey.notchAnimationEnabled,
                from: userDefaults,
                default: defaults.notchAnimationEnabled
            ),
            notchAnimationSpeed: boundedDouble(
                key: DefaultsKey.notchAnimationSpeed,
                from: userDefaults,
                default: defaults.notchAnimationSpeed,
                range: 0.5...2.0
            ),
            caffeineEnabled: bool(
                key: DefaultsKey.caffeineEnabled,
                from: userDefaults,
                default: defaults.caffeineEnabled
            ),
            caffeineExcludedSSIDs: (userDefaults.stringArray(forKey: DefaultsKey.caffeineExcludedSSIDs) ?? defaults.caffeineExcludedSSIDs),
            caffeineSessionTimeoutEnabled: bool(
                key: DefaultsKey.caffeineSessionTimeoutEnabled,
                from: userDefaults,
                default: defaults.caffeineSessionTimeoutEnabled
            ),
            caffeineSessionTimeoutMinutes: positiveInt(
                key: DefaultsKey.caffeineSessionTimeoutMinutes,
                from: userDefaults,
                default: defaults.caffeineSessionTimeoutMinutes
            ),
            releaseChannel: enumValue(
                ReleaseChannel.self,
                key: DefaultsKey.releaseChannel,
                from: userDefaults,
                default: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").contains("nightly") ? .nightly : defaults.releaseChannel
            ),
            notificationsEnabled: bool(
                key: DefaultsKey.notificationsEnabled,
                from: userDefaults,
                default: defaults.notificationsEnabled
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

    private static func compactRegionSelection(
        key: String,
        from userDefaults: UserDefaults,
        default defaultValue: NotchCompactRegionSelection
    ) -> NotchCompactRegionSelection {
        guard let value = userDefaults.string(forKey: key) else { return defaultValue }
        return NotchCompactRegionSelection(persistedValue: value, default: defaultValue)
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
