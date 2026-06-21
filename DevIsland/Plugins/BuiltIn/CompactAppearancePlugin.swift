import Foundation

/// Owns the default content of all three compact-notch regions. The host keeps the notch
/// chrome and unread indicator; this plugin contributes only declarative region content.
final class CompactAppearancePlugin: DevIslandPlugin, @unchecked Sendable {
    static let pluginID = BuiltInPluginID.compactAppearance

    let manifest = PluginManifest(
        id: CompactAppearancePlugin.pluginID,
        name: "Compact Appearance",
        version: "1.0.0",
        apiVersion: 1,
        kind: .system,
        permissions: [.showCompactRegion],
        surfaces: [],
        regions: Set(PluginRegionID.allCases),
        activationEvents: [
            PluginEventKind.pluginStarted.rawValue,
            PluginEventKind.appStarted.rawValue,
            PluginEventKind.settingsChanged.rawValue,
            PluginEventKind.languageChanged.rawValue
        ],
        localizedName: PluginLocalizedString(english: "Compact Appearance", korean: "컴팩트 모양"),
        localizedDescription: PluginLocalizedString(
            english: "Shows the configured buddies and center text in the compact Island.",
            korean: "컴팩트 아일랜드에 설정된 버디와 중앙 텍스트를 표시합니다."
        )
    )

    private let settingsProvider: @MainActor @Sendable () -> AppSettings
    private var settings = AppSettings.defaults
    private var leftBuddy: BuddyKind?
    private var rightBuddy: BuddyKind?

    init(settingsProvider: @escaping @MainActor @Sendable () -> AppSettings) {
        self.settingsProvider = settingsProvider
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        let nextSettings = await settingsProvider()
        leftBuddy = resolvedBuddy(
            current: leftBuddy,
            mode: nextSettings.notchLeftCharacterMode,
            specific: nextSettings.notchLeftCharacterKind,
            randomCandidates: nextSettings.notchLeftRandomCharacterKinds
        )
        rightBuddy = resolvedBuddy(
            current: rightBuddy,
            mode: nextSettings.notchRightCharacterMode,
            specific: nextSettings.notchRightCharacterKind,
            randomCandidates: nextSettings.notchRightRandomCharacterKinds
        )
        settings = nextSettings
        return []
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        nil
    }

    func makeCompactRegionContribution(
        for region: PluginRegionID,
        context: PluginCompactRegionContext
    ) throws -> PluginCompactRegionContribution? {
        let content: PluginCompactRegionContent
        switch region {
        case .notchCompactLeading:
            guard settings.notchLeftCharacterMode != .hidden, let leftBuddy else { return nil }
            content = .buddy(kind: leftBuddy.rawValue)
        case .notchCompactCenter:
            guard !settings.notchCenterText.isEmpty else { return nil }
            content = .text(settings.notchCenterText)
        case .notchCompactTrailing:
            guard settings.notchRightCharacterMode != .hidden, let rightBuddy else { return nil }
            content = .buddy(kind: rightBuddy.rawValue)
        }
        return PluginCompactRegionContribution(
            pluginID: manifest.id,
            region: region,
            expiresAt: nil,
            content: content
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }

    private func resolvedBuddy(
        current: BuddyKind?,
        mode: NotchCharacterMode,
        specific: BuddyKind,
        randomCandidates: Set<BuddyKind>
    ) -> BuddyKind? {
        switch mode {
        case .hidden:
            return nil
        case .specific:
            return specific
        case .random:
            let candidates = randomCandidates.isEmpty
                ? Set(BuddyKind.defaultRandomCases)
                : randomCandidates
            if let current, candidates.contains(current) {
                return current
            }
            return candidates.randomElement() ?? .claudeCode
        }
    }
}
