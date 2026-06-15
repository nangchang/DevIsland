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
            PluginEventKind.pluginActionInvoked.rawValue,
            PluginEventKind.settingsChanged.rawValue,
            PluginEventKind.languageChanged.rawValue
        ],
        localizedName: PluginLocalizedString(english: "Pomodoro", korean: "포모도로")
    )

    /// User-configurable settings (v1.3 demo): work length and whether to auto-restart a
    /// new focus block on completion. The host renders, validates, and persists these.
    var settingsSchema: [PluginSettingDescriptor] {
        [
            PluginSettingDescriptor(
                key: "workMinutes",
                label: "Work Minutes",
                localizedLabel: PluginLocalizedString(english: "Work Minutes", korean: "작업 시간(분)"),
                kind: .stepper(range: 1...60, step: 5),
                defaultValue: .int(25)
            ),
            PluginSettingDescriptor(
                key: "autoRestart",
                label: "Auto-restart",
                localizedLabel: PluginLocalizedString(english: "Auto-restart", korean: "자동 재시작"),
                kind: .toggle,
                defaultValue: .bool(false)
            )
        ]
    }

    private enum Mode { case idle, running, paused }

    private let toggleActionID = "pomodoro.toggle"
    /// Fallback when no `workMinutes` setting is resolved (e.g. unit tests inject this directly).
    private let defaultWorkSeconds: Int
    /// Effective work length, refreshed from settings at the top of every `onEvent`.
    private var workSeconds: Int

    private var mode: Mode = .idle
    private var remainingSeconds: Int
    private var completedCount = 0
    /// Wall-clock target end while running; nil when idle/paused. The countdown is
    /// derived from this against each event's timestamp so the timer stays accurate
    /// across missed ticks, App Nap throttling, and system sleep — instead of losing
    /// time whenever a 1Hz tick is delayed or skipped.
    private var expectedEndTime: Date?

    /// `workSeconds` is injectable so tests can reach completion without 25 minutes
    /// of ticks; production resolves the length from the `workMinutes` setting and only
    /// falls back to this when no setting is present.
    init(workSeconds: Int = 25 * 60) {
        self.defaultWorkSeconds = workSeconds
        self.workSeconds = workSeconds
        self.remainingSeconds = workSeconds
    }

    /// Only running needs the tick: it is the only state where the value changes.
    /// Toggling re-renders synchronously via the action path, and the cached
    /// contribution (no `expiresAt`) keeps showing while idle/paused.
    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        mode == .running
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        // Refresh the effective work length from settings every event. Changing it mid-run
        // never disturbs the active countdown (driven by `expectedEndTime`); it takes effect
        // on the next idle reset or completion.
        workSeconds = context.settings["workMinutes"]?.intValue.map { $0 * 60 } ?? defaultWorkSeconds
        let autoRestart = context.settings["autoRestart"]?.boolValue ?? false

        switch event.kind {
        case .pluginStarted, .settingsChanged:
            // Reflect a new work length when not actively counting down.
            if mode != .running {
                remainingSeconds = workSeconds
            }
        case .pluginTick:
            guard mode == .running, let end = expectedEndTime else { return [] }
            remainingSeconds = Self.secondsRemaining(until: end, now: event.timestamp)
            if remainingSeconds == 0 {
                return complete(now: event.timestamp, autoRestart: autoRestart, language: context.language)
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

    private func complete(now: Date, autoRestart: Bool, language: AppLanguage) -> [PluginEffect] {
        completedCount += 1
        remainingSeconds = workSeconds
        if autoRestart {
            mode = .running
            expectedEndTime = now.addingTimeInterval(Double(workSeconds))
        } else {
            mode = .idle
            expectedEndTime = nil
        }
        return [PluginEffect(
            capability: "notification.show",
            payload: [
                "title": language.s("Pomodoro", "포모도로"),
                "body": language.s("Focus session complete", "집중 세션이 완료되었습니다")
            ]
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
                    label: statusLabel(language: context.language),
                    value: time,
                    tone: mode == .running ? .success : nil,
                    iconName: "timer",
                    action: nil
                ),
                toggleButton(language: context.language)
            ]
        case .menubarMenu:
            components = [
                PluginUIComponentDTO(
                    id: "timer",
                    type: .metric,
                    label: context.language.s("Pomodoro", "포모도로"),
                    value: time,
                    tone: mode == .running ? .success : nil,
                    iconName: "timer",
                    action: nil
                ),
                PluginUIComponentDTO(
                    id: "count",
                    type: .metric,
                    label: context.language.s("Completed", "완료"),
                    value: "\(completedCount)",
                    tone: nil,
                    iconName: nil,
                    action: nil
                ),
                toggleButton(language: context.language)
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

    private func statusLabel(language: AppLanguage) -> String {
        switch mode {
        case .idle: return language.s("Idle", "대기")
        case .running: return language.s("Focus", "집중")
        case .paused: return language.s("Paused", "일시정지")
        }
    }

    private func toggleButton(language: AppLanguage) -> PluginUIComponentDTO {
        PluginUIComponentDTO(
            id: "toggle",
            type: .button,
            label: mode == .running ? language.s("Pause", "일시정지") : language.s("Start", "시작"),
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
