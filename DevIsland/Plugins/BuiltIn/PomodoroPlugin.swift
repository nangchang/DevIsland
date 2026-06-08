import Foundation

/// First utility built-in plugin: a self-contained Pomodoro timer that has no
/// dependency on DevIsland sessions or hooks. It drives itself off the central
/// `plugin.tick` loop while running and toggles via a `pluginEvent`-routed action.
///
/// It contributes to both `notch.expanded.activity` and `menubar.menu`, and asks
/// the host to post a notification (via the `notification.show` effect) when a
/// focus block completes.
///
/// `@unchecked Sendable`: mutable state is only ever touched inside the
/// `PluginRunner` actor, which serializes every call (architecture doc §6.4).
final class PomodoroPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest = PluginManifest(
        id: "com.devisland.pomodoro",
        name: "Pomodoro",
        version: "1.0.0",
        apiVersion: 1,
        kind: .utility,
        permissions: [.showNotchCard, .showMenubarMenu, .showNotification],
        surfaces: [.notchExpandedActivity, .menubarMenu],
        activationEvents: [
            PluginEventKind.pluginStarted.rawValue,
            PluginEventKind.pluginTick.rawValue,
            PluginEventKind.pluginActionInvoked.rawValue
        ]
    )

    private enum Mode { case idle, running, paused }

    private let toggleActionID = "pomodoro.toggle"
    private let workSeconds: Int

    private var mode: Mode = .idle
    private var remainingSeconds: Int
    private var completedCount = 0
    /// Wall-clock target end while running; nil when idle/paused. The countdown is
    /// derived from this against each event's timestamp so the timer stays accurate
    /// across missed ticks, App Nap throttling, and system sleep — instead of losing
    /// time whenever a 1Hz tick is delayed or skipped.
    private var expectedEndTime: Date?

    /// `workSeconds` is injectable so tests can reach completion without 25 minutes
    /// of ticks; production always uses the 25-minute default.
    init(workSeconds: Int = 25 * 60) {
        self.workSeconds = workSeconds
        self.remainingSeconds = workSeconds
    }

    /// Only running needs the tick: it is the only state where the value changes.
    /// Toggling re-renders synchronously via the action path, and the cached
    /// contribution (no `expiresAt`) keeps showing while idle/paused.
    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        mode == .running
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        switch event.kind {
        case .pluginTick:
            guard mode == .running, let end = expectedEndTime else { return [] }
            remainingSeconds = Self.secondsRemaining(until: end, now: event.timestamp)
            if remainingSeconds == 0 {
                return complete()
            }
        case .pluginActionInvoked:
            guard event.action?.actionID == toggleActionID else { break }
            switch mode {
            case .idle, .paused:
                mode = .running
                expectedEndTime = event.timestamp.addingTimeInterval(Double(remainingSeconds))
            case .running:
                if let end = expectedEndTime {
                    remainingSeconds = Self.secondsRemaining(until: end, now: event.timestamp)
                }
                mode = .paused
                expectedEndTime = nil
            }
        default:
            break
        }
        return []
    }

    private func complete() -> [PluginEffect] {
        completedCount += 1
        mode = .idle
        remainingSeconds = workSeconds
        expectedEndTime = nil
        return [PluginEffect(
            capability: "notification.show",
            payload: ["title": "Pomodoro", "body": "Focus session complete"]
        )]
    }

    private static func secondsRemaining(until end: Date, now: Date) -> Int {
        max(0, Int(end.timeIntervalSince(now).rounded()))
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        let time = Self.formatted(remainingSeconds)
        let components: [PluginUIComponentDTO]
        switch slot {
        case .notchExpandedActivity:
            components = [
                PluginUIComponentDTO(
                    id: "timer",
                    type: .metric,
                    label: statusLabel,
                    value: time,
                    tone: mode == .running ? .success : nil,
                    iconName: "timer",
                    action: nil
                ),
                toggleButton
            ]
        case .menubarMenu:
            components = [
                PluginUIComponentDTO(
                    id: "timer",
                    type: .metric,
                    label: "Pomodoro",
                    value: time,
                    tone: mode == .running ? .success : nil,
                    iconName: "timer",
                    action: nil
                ),
                PluginUIComponentDTO(
                    id: "count",
                    type: .metric,
                    label: "Completed",
                    value: "\(completedCount)",
                    tone: nil,
                    iconName: nil,
                    action: nil
                ),
                toggleButton
            ]
        default:
            return nil
        }

        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: nil,
            priority: 20,
            expiresAt: nil,
            components: components
        )
    }

    private var statusLabel: String {
        switch mode {
        case .idle: return "Idle"
        case .running: return "Focus"
        case .paused: return "Paused"
        }
    }

    private var toggleButton: PluginUIComponentDTO {
        PluginUIComponentDTO(
            id: "toggle",
            type: .button,
            label: mode == .running ? "Pause" : "Start",
            value: nil,
            tone: nil,
            iconName: nil,
            action: PluginUIActionDTO(
                id: toggleActionID,
                capability: "timer.startStop",
                routing: .pluginEvent,
                payload: [:]
            )
        )
    }

    private static func formatted(_ seconds: Int) -> String {
        let total = max(0, seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
