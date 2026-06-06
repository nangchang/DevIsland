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
        storageSnapshot: [String: String]
    ) async -> PluginContributionSnapshot {
        let startedAt = ContinuousClock.now

        do {
            let context = PluginContext(
                pluginID: manifest.id,
                permissions: manifest.permissions,
                storageSnapshot: storageSnapshot
            )
            let effects = try plugin.onEvent(event, context: context)
            var contributions: [PluginUISlot: PluginUIContribution] = [:]

            for slot in manifest.surfaces {
                let context = PluginUIContext(
                    slot: slot,
                    timestamp: event.timestamp,
                    session: event.session
                )
                if let contribution = try plugin.makeUIContribution(for: slot, context: context) {
                    contributions[slot] = contribution
                }
            }

            let elapsed = startedAt.duration(to: ContinuousClock.now)
            return PluginContributionSnapshot(
                pluginID: manifest.id,
                contributions: contributions,
                effects: effects,
                failure: elapsed > .milliseconds(50)
                    ? PluginFailure(
                        pluginID: manifest.id,
                        message: "Plugin exceeded 50ms budget",
                        occurredAt: event.timestamp,
                        clearsContribution: false
                    )
                    : nil,
                timestamp: event.timestamp
            )
        } catch {
            return PluginContributionSnapshot(
                pluginID: manifest.id,
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
}
