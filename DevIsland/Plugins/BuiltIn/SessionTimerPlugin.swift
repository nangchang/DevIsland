import Foundation

/// First core-aware built-in plugin: shows the elapsed time of the currently
/// active session in the expanded notch activity slot.
///
/// Observation-only — it never mutates core state and returns no effects. It
/// tracks active sessions from `session.*` events and refreshes the elapsed
/// display on `plugin.tick`. The "current" session is the most recently active
/// one, since plugin events carry no explicit selection signal.
///
/// `@unchecked Sendable`: mutable state (`sessions`) is only ever touched inside
/// the `PluginRunner` actor, which serializes every call (architecture doc §6.4).
final class SessionTimerPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest = PluginManifest(
        id: "com.devisland.timer",
        name: "Session Timer",
        version: "1.0.0",
        apiVersion: 1,
        kind: .system,
        permissions: [.readSessionEvents, .showNotchCard],
        surfaces: [.notchExpandedActivity],
        activationEvents: [
            PluginEventKind.sessionStarted.rawValue,
            PluginEventKind.sessionUpdated.rawValue,
            PluginEventKind.sessionEnded.rawValue,
            PluginEventKind.pluginTick.rawValue
        ]
    )

    private var sessions: [String: PluginSessionSnapshot] = [:]

    private var currentSession: PluginSessionSnapshot? {
        sessions.values.max { $0.lastActiveAt < $1.lastActiveAt }
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        switch event.kind {
        case .sessionStarted, .sessionUpdated:
            if let session = event.session {
                sessions[session.id] = session
            }
        case .sessionEnded:
            if let session = event.session {
                sessions.removeValue(forKey: session.id)
            }
        default:
            break
        }
        return []
    }

    /// Ticking only matters to refresh the elapsed value, so request it only when
    /// a session is active and the notch activity surface is actually visible.
    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        !sessions.isEmpty && surfaceState.visibleSurfaces.contains(.notchExpandedActivity)
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        guard slot == .notchExpandedActivity, let current = currentSession else { return nil }

        let elapsed = Int(context.timestamp.timeIntervalSince(current.startTime))
        let component = PluginUIComponentDTO(
            id: "elapsed",
            type: .metric,
            label: "Elapsed",
            value: Self.formattedElapsed(elapsed),
            tone: nil,
            iconName: "clock",
            action: nil
        )

        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: nil,
            priority: 10,
            expiresAt: nil,
            components: [component]
        )
    }

    private static func formattedElapsed(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
