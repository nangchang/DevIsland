import Foundation

actor PluginRunner {
    nonisolated let manifest: PluginManifest
    /// Cached at init like `manifest`: the schema is static, so the host (MainActor) can read
    /// it without hopping into the actor to resolve persisted setting values at drain time.
    nonisolated let settingsSchema: [PluginSettingDescriptor]
    /// Cached at init: static metadata the host reads from the MainActor to build the
    /// Features settings pane without hopping into the actor.
    nonisolated let settingsPaneDescriptor: PluginSettingsPaneDescriptor?
    private let plugin: any DevIslandPlugin & Sendable

    init(plugin: any DevIslandPlugin & Sendable) {
        self.plugin = plugin
        self.manifest = plugin.manifest
        self.settingsSchema = plugin.settingsSchema
        self.settingsPaneDescriptor = plugin.settingsPaneDescriptor
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        plugin.needsTick(surfaceState: surfaceState)
    }

    func handle(
        _ event: PluginEvent,
        storageSnapshot: [String: String],
        scopedFileBroker: PluginScopedFileBroker,
        settings: [String: PluginSettingValue] = [:],
        selectedSessionID: String? = nil,
        selectedCompactRegionProviders: [PluginRegionID: String]? = nil,
        language: AppLanguage = .english
    ) async -> PluginContributionSnapshot {
        let startedAt = ContinuousClock.now
        let evaluatedSlots = manifest.surfaces.filter {
            Self.isSurfaceAllowed($0, permissions: manifest.permissions)
                && Self.shouldEvaluate($0, for: event)
        }
        let evaluatedRegions = manifest.regions.filter { region in
            guard manifest.permissions.contains(.showCompactRegion) else { return false }
            guard let selectedCompactRegionProviders else { return true }
            return selectedCompactRegionProviders[region] == manifest.id
        }

        do {
            let context = PluginContext(
                pluginID: manifest.id,
                permissions: manifest.permissions,
                storageSnapshot: storageSnapshot,
                scopedFiles: manifest.permissions.contains(.readScopedFiles)
                    ? PluginScopedFileClient(
                        pluginID: manifest.id,
                        permissions: manifest.permissions,
                        broker: scopedFileBroker
                    )
                    : nil,
                settings: settings,
                language: language
            )
            let effects = try await plugin.onEvent(event, context: context)
            var contributions: [PluginUISlot: PluginUIContribution] = [:]
            var regionContributions: [PluginRegionID: PluginCompactRegionContribution] = [:]

            for slot in evaluatedSlots {
                let context = PluginUIContext(
                    slot: slot,
                    timestamp: event.timestamp,
                    session: event.session,
                    selectedSessionID: selectedSessionID,
                    language: language
                )
                if let contribution = try plugin.makeUIContribution(for: slot, context: context) {
                    contributions[slot] = contribution
                }
            }

            for region in evaluatedRegions {
                let context = PluginCompactRegionContext(
                    region: region,
                    timestamp: event.timestamp,
                    language: language
                )
                if let contribution = try plugin.makeCompactRegionContribution(
                    for: region,
                    context: context
                ), contribution.pluginID == manifest.id, contribution.region == region {
                    regionContributions[region] = contribution
                }
            }

            // Built-in plugin execution is measured after completion in PR 3.
            // It is not interrupted; worker/process isolation is a later runtime concern.
            let elapsed = startedAt.duration(to: ContinuousClock.now)
            return PluginContributionSnapshot(
                pluginID: manifest.id,
                sessionID: event.session?.id,
                evaluatedSlots: Set(evaluatedSlots),
                contributions: contributions,
                evaluatedRegions: Set(evaluatedRegions),
                regionContributions: regionContributions,
                effects: effects,
                failure: elapsed > .milliseconds(50)
                    ? PluginFailure(
                        pluginID: manifest.id,
                        message: "Plugin exceeded 50ms measurement budget",
                        occurredAt: event.timestamp,
                        clearsContribution: false
                    )
                    : nil,
                timestamp: event.timestamp
            )
        } catch {
            return PluginContributionSnapshot(
                pluginID: manifest.id,
                sessionID: event.session?.id,
                evaluatedSlots: Set(evaluatedSlots),
                contributions: [:],
                evaluatedRegions: Set(evaluatedRegions),
                regionContributions: [:],
                effects: [],
                failure: PluginFailure(
                    pluginID: manifest.id,
                    message: String(describing: error),
                    occurredAt: event.timestamp,
                    clearsContribution: true
                ),
                timestamp: event.timestamp
            )
        }
    }

    private nonisolated static func isSurfaceAllowed(
        _ slot: PluginUISlot,
        permissions: Set<PluginPermission>
    ) -> Bool {
        switch slot {
        case .notchExpandedActivity, .notchExpandedDetails:
            return permissions.contains(.showNotchCard)
        case .menubarMenu:
            return permissions.contains(.showMenubarMenu)
        case .notchSessionRow,
             .sessionDetailTimeline,
             .sessionDetailSummary,
             .sessionContextMenu,
             .sessionMessage:
            return permissions.contains(.showSessionSurface)
        }
    }

    private nonisolated static func shouldEvaluate(
        _ slot: PluginUISlot,
        for event: PluginEvent
    ) -> Bool {
        guard isSessionScoped(slot) else { return true }
        return event.session != nil
    }

    private nonisolated static func isSessionScoped(_ slot: PluginUISlot) -> Bool {
        switch slot {
        case .notchSessionRow,
             .sessionDetailTimeline,
             .sessionDetailSummary,
             .sessionContextMenu,
             .sessionMessage:
            return true
        case .notchExpandedActivity,
             .notchExpandedDetails,
             .menubarMenu:
            return false
        }
    }
}
