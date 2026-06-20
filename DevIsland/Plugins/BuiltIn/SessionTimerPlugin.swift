import Foundation

/// First core-aware built-in plugin: shows the elapsed time of the currently
/// active session in the expanded notch activity slot, plus a per-session elapsed
/// badge on each session row (`notch.session.row`, opened in v1.1).
///
/// Observation-only — it never mutates core state and returns no effects. It
/// tracks active sessions from `session.*` events and refreshes the global elapsed
/// display on `plugin.tick`. The "current" session for the global card is the most
/// recently active one, since plugin events carry no explicit selection signal.
///
/// `@unchecked Sendable`: mutable state (`sessions`) is only ever touched inside
/// the `PluginRunner` actor, which serializes every call (architecture doc §6.4).
final class SessionTimerPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest = PluginManifest(
        id: BuiltInPluginID.sessionTimer,
        name: "Session Timer",
        version: "1.0.0",
        apiVersion: 1,
        kind: .system,
        permissions: [.readSessionEvents, .showNotchCard, .showSessionSurface],
        surfaces: [.notchExpandedActivity, .notchSessionRow, .sessionMessage],
        activationEvents: [
            PluginEventKind.sessionStarted.rawValue,
            PluginEventKind.sessionUpdated.rawValue,
            PluginEventKind.sessionEnded.rawValue,
            PluginEventKind.pluginTick.rawValue,
            PluginEventKind.settingsChanged.rawValue,
            PluginEventKind.languageChanged.rawValue
        ],
        localizedName: PluginLocalizedString(english: "Session Timer", korean: "세션 타이머"),
        localizedDescription: PluginLocalizedString(
            english: "Shows elapsed time for the active session in the notch and on each session row.",
            korean: "노치와 세션 행에 현재 세션의 경과 시간을 표시합니다."
        )
    )

    /// Whether the elapsed badges include seconds. Toggling it must refresh the per-session
    /// badges (`notch.session.row`, `session.message`) too, which is what exercises the
    /// settings.changed → session-scoped fan-out in `PluginHost.pluginSettingChanged`.
    var settingsSchema: [PluginSettingDescriptor] {
        [
            PluginSettingDescriptor(
                key: "showSeconds",
                label: "Show seconds",
                localizedLabel: PluginLocalizedString(english: "Show seconds", korean: "초 표시"),
                kind: .toggle,
                defaultValue: .bool(true)
            )
        ]
    }

    private var sessions: [String: PluginSessionSnapshot] = [:]
    private var showSeconds = true
    private static let liveSurfaces: Set<PluginUISlot> = [
        .notchExpandedActivity,
        .sessionMessage
    ]

    private var currentSession: PluginSessionSnapshot? {
        sessions.values.max { $0.lastActiveAt < $1.lastActiveAt }
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        // Refresh from settings on every event so makeUIContribution (which has no settings in
        // its context) reflects the current value. Mirrors PomodoroPlugin's pattern.
        showSeconds = context.settings["showSeconds"]?.boolValue ?? true
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
    /// a session is active and a surface with a live elapsed value is visible.
    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        !sessions.isEmpty && !surfaceState.visibleSurfaces.isDisjoint(with: Self.liveSurfaces)
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        switch slot {
        case .notchExpandedActivity:
            // Prefer the session the user is viewing; fall back to the most recently active
            // one only when there is no selection signal (host provides none, or it points
            // at an untracked session). This keeps the global elapsed from drifting away
            // from the user's selection across multiple sessions.
            let selected = context.selectedSessionID.flatMap { sessions[$0] }
            guard let target = selected ?? currentSession else { return nil }
            return elapsedContribution(
                slot: slot,
                session: target,
                targetSessionID: nil,
                timestamp: context.timestamp,
                label: context.language.s("Elapsed", "경과")
            )
        case .notchSessionRow, .sessionMessage:
            // Per-session elapsed badge keyed to the triggering session, on the row and in
            // the message-window header. PluginHost fans out session-bearing ticks while a
            // live timer surface is visible, so these cached values advance each second.
            // Only still-tracked sessions contribute, so an ended session yields nil.
            guard let target = context.session, let tracked = sessions[target.id] else { return nil }
            return elapsedContribution(
                slot: slot,
                session: tracked,
                targetSessionID: tracked.id,
                timestamp: context.timestamp,
                label: nil
            )
        default:
            return nil
        }
    }

    private func elapsedContribution(
        slot: PluginUISlot,
        session: PluginSessionSnapshot,
        targetSessionID: String?,
        timestamp: Date,
        label: String?
    ) -> PluginUIContribution {
        let elapsed = Int(timestamp.timeIntervalSince(session.startTime))
        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: targetSessionID,
            priority: 10,
            expiresAt: nil,
            components: [
                PluginUIComponentDTO(
                    id: "elapsed",
                    type: .metric,
                    label: label,
                    value: Self.formattedElapsed(elapsed, showSeconds: showSeconds),
                    tone: nil,
                    iconName: "clock",
                    action: nil
                )
            ]
        )
    }

    private static func formattedElapsed(_ seconds: Int, showSeconds: Bool) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if showSeconds {
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, secs)
            }
            return String(format: "%02d:%02d", minutes, secs)
        }
        // Seconds hidden: hours:minutes, or whole minutes when under an hour.
        if hours > 0 {
            return String(format: "%d:%02d", hours, minutes)
        }
        return String(format: "%dm", minutes)
    }
}
