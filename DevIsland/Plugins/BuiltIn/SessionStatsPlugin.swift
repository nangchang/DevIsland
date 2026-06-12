import Foundation

/// `system` built-in plugin that surfaces lightweight, observation-only stats
/// derived from the sanitized session and hook streams (Migration PR M3).
///
/// It counts the currently active sessions (from `session.*` events) and tallies
/// hook events per provider (from `hook.received`). Both are read-only summaries —
/// it never mutates core state and returns no effects. Approval stats are out of
/// scope until `approval.decided` lands in v1.1, and it never touches the replay DB.
///
/// Counts are in-memory for the app run; there is no durable storage in v1.
///
/// `@unchecked Sendable`: mutable state is only ever touched inside the
/// `PluginRunner` actor, which serializes every call (architecture doc §6.4).
final class SessionStatsPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest = PluginManifest(
        id: "com.devisland.stats",
        name: "Session Stats",
        version: "1.0.0",
        apiVersion: 1,
        kind: .system,
        permissions: [.readSessionEvents, .readHookSummaries, .showNotchCard, .showMenubarMenu],
        surfaces: [.notchExpandedActivity, .menubarMenu],
        activationEvents: [
            PluginEventKind.sessionStarted.rawValue,
            PluginEventKind.sessionUpdated.rawValue,
            PluginEventKind.sessionEnded.rawValue,
            PluginEventKind.hookReceived.rawValue
        ]
    )

    private var activeSessionIDs: Set<String> = []
    private var hookCountsByProvider: [String: Int] = [:]

    private var totalHooks: Int {
        hookCountsByProvider.values.reduce(0, +)
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        switch event.kind {
        case .sessionStarted, .sessionUpdated:
            if let id = event.session?.id {
                activeSessionIDs.insert(id)
            }
        case .sessionEnded:
            if let id = event.session?.id {
                activeSessionIDs.remove(id)
            }
        case .hookReceived:
            if let provider = event.hook?.provider {
                hookCountsByProvider[provider, default: 0] += 1
            }
        default:
            break
        }
        return []
    }

    /// Stats change on events, not on a clock, so no central tick is needed.
    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        switch slot {
        case .notchExpandedActivity:
            // Don't crowd the expanded notch with a zero before any session exists.
            guard !activeSessionIDs.isEmpty else { return nil }
            return contribution(slot: slot, timestamp: context.timestamp, components: [
                PluginUIComponentDTO(
                    id: "sessions",
                    type: .metric,
                    label: "Sessions",
                    value: "\(activeSessionIDs.count)",
                    tone: nil,
                    iconName: "rectangle.stack",
                    action: nil
                )
            ])
        case .menubarMenu:
            // Nothing observed yet means nothing worth a menu row.
            guard !activeSessionIDs.isEmpty || totalHooks > 0 else { return nil }
            var components: [PluginUIComponentDTO] = [
                PluginUIComponentDTO(
                    id: "sessions",
                    type: .metric,
                    label: "Active Sessions",
                    value: "\(activeSessionIDs.count)",
                    tone: nil,
                    iconName: "rectangle.stack",
                    action: nil
                )
            ]
            if totalHooks > 0 {
                components.append(
                    PluginUIComponentDTO(
                        id: "hooks",
                        type: .metric,
                        label: "Hook Events",
                        value: "\(totalHooks)",
                        tone: nil,
                        iconName: nil,
                        action: nil
                    )
                )
                // Sorted by provider name for deterministic, stable ordering.
                for provider in hookCountsByProvider.keys.sorted() {
                    components.append(
                        PluginUIComponentDTO(
                            id: "provider.\(provider)",
                            type: .metric,
                            label: provider.prefix(1).uppercased() + provider.dropFirst(),
                            value: "\(hookCountsByProvider[provider] ?? 0)",
                            tone: nil,
                            iconName: nil,
                            action: nil
                        )
                    )
                }
            }
            return contribution(slot: slot, timestamp: context.timestamp, components: components)
        default:
            return nil
        }
    }

    private func contribution(
        slot: PluginUISlot,
        timestamp: Date,
        components: [PluginUIComponentDTO]
    ) -> PluginUIContribution {
        PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: nil,
            priority: 30,
            expiresAt: nil,
            components: components
        )
    }
}
