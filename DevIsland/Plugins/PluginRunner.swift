import Foundation

actor PluginRunner {
    nonisolated let manifest: PluginManifest
    private let plugin: any DevIslandPlugin & Sendable

    init(plugin: any DevIslandPlugin & Sendable) {
        self.plugin = plugin
        self.manifest = plugin.manifest
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        plugin.needsTick(surfaceState: surfaceState)
    }

    func handle(
        _ event: PluginEvent,
        storageSnapshot: [String: String],
        selectedSessionID: String? = nil
    ) async -> PluginContributionSnapshot {
        let startedAt = ContinuousClock.now
        let evaluatedSlots = manifest.surfaces.filter {
            Self.isSurfaceAllowed($0, permissions: manifest.permissions)
                && Self.shouldEvaluate($0, for: event)
        }

        do {
            let context = PluginContext(
                pluginID: manifest.id,
                permissions: manifest.permissions,
                storageSnapshot: storageSnapshot
            )
            let effects = try plugin.onEvent(event, context: context)
            var contributions: [PluginUISlot: PluginUIContribution] = [:]

            for slot in evaluatedSlots {
                let context = PluginUIContext(
                    slot: slot,
                    timestamp: event.timestamp,
                    session: event.session,
                    selectedSessionID: selectedSessionID
                )
                if let contribution = try plugin.makeUIContribution(for: slot, context: context) {
                    contributions[slot] = contribution
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
