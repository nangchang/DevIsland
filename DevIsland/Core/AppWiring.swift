import Foundation
import Combine

// MARK: - App Wiring

/// Post-construction wiring extracted from `AppState.init` (refactoring plan R2-d):
/// built-in plugin registration, plugin host callbacks, session-change → plugin event
/// forwarding, and Caffeine power/Wi-Fi/settings bindings. The power and Wi-Fi
/// monitors exist only to feed the Caffeine coordinator, so this type owns them.
final class AppWiring {
    private let powerSourceMonitor = PowerSourceMonitor()
    private let wifiMonitor = WifiSSIDMonitor()

    /// Built-in plugins compiled into DevIsland, registered once at wiring.
    private static func builtInPlugins(
        settingsProvider: @escaping @MainActor @Sendable () -> AppSettings
    ) -> [any DevIslandPlugin & Sendable] {
        [
            CompactAppearancePlugin(settingsProvider: settingsProvider),
            SessionTimerPlugin(),
            PomodoroPlugin(),
            OpenPeonPlugin(settingsProvider: settingsProvider),
            CaffeinePlugin(),
            SessionStatsPlugin(),
            SessionActionsPlugin()
        ]
    }

    /// Registers built-in plugins and wires the plugin host callbacks. Plugins are
    /// registered before the session callback so they observe every subsequent
    /// session/hook event. `register` no-ops when plugins are disabled. The persisted
    /// disabled set is applied here so a disabled plugin never runs for one cycle
    /// before `plugin.started` fires.
    @MainActor
    func wirePlugins(appState: AppState) {
        let pluginHost = appState.pluginHost
        pluginHost.register(
            Self.builtInPlugins(settingsProvider: { SettingsStore.shared.settings }),
            disabledPluginIDs: PluginSettingsStore.shared.disabledPluginIDs
        )
        // Host Command Catalog: route validated session commands (e.g. session.dismiss)
        // to AppState, which alone knows the session state needed to authorize them.
        pluginHost.sessionCommandHandler = { [weak appState] capability, sessionID in
            appState?.handlePluginSessionCommand(capability, sessionID: sessionID)
        }
        // Selection signal: the session the user is currently viewing, so global-slot
        // contributions render for it instead of the most-recently-active session.
        pluginHost.selectedSessionProvider = { [weak appState] in
            appState?.displayedSessionID
        }
        pluginHost.compactRegionSelectionProvider = {
            let settings = SettingsStore.shared.settings
            return [
                .notchCompactLeading: settings.notchCompactLeadingSelection.providerID,
                .notchCompactCenter: settings.notchCompactCenterSelection.providerID,
                .notchCompactTrailing: settings.notchCompactTrailingSelection.providerID
            ].compactMapValues { $0 }
        }
        // Active sessions: lets the host fan out settings.changed to session-scoped
        // slots so per-session contributions refresh when a plugin's settings change.
        pluginHost.activeSessionsProvider = { [weak appState] in
            guard let appState else { return [] }
            return appState.sessionStore.activeSessions.map { appState.pluginEventFactory.snapshot(from: $0) }
        }

        appState.sessionStore.onSessionChanged = { [weak appState] change in
            guard let appState else { return }
            MainActor.assumeIsolated {
                let event: PluginEvent
                switch change {
                case .started(let session):
                    event = appState.pluginEventFactory.makeSessionEvent(kind: .sessionStarted, from: session)
                case .updated(let session):
                    event = appState.pluginEventFactory.makeSessionEvent(kind: .sessionUpdated, from: session)
                case .ended(let session):
                    event = appState.pluginEventFactory.makeSessionEvent(kind: .sessionEnded, from: session)
                }
                appState.pluginHost.enqueue(event)
            }
        }
    }

    /// Starts the power/Wi-Fi monitors and binds them, the settings store, and
    /// session activity to the Caffeine coordinator.
    @MainActor
    func wireCaffeine(appState: AppState) {
        let caffeineCoordinator = appState.caffeineCoordinator
        caffeineCoordinator.onStatusChanged = { [weak appState] status in
            guard let appState else { return }
            MainActor.assumeIsolated {
                let event = appState.pluginEventFactory.makePowerStatusEvent(status: status)
                appState.pluginHost.enqueue(event)
            }
        }

        powerSourceMonitor.start()
        wifiMonitor.start()

        // assign(to:&)는 대상 @Published의 라이프사이클에 따라 자동 정리되므로
        // 별도 cancellables 보관이 필요 없고 retain cycle 위험도 없다.
        powerSourceMonitor.$isOnACPower
            .receive(on: DispatchQueue.main)
            .assign(to: &caffeineCoordinator.$isOnACPower)

        powerSourceMonitor.$batteryLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &caffeineCoordinator.$batteryLevel)

        wifiMonitor.$currentSSID
            .receive(on: DispatchQueue.main)
            .assign(to: &caffeineCoordinator.$currentSSID)

        DispatchQueue.main.async { [caffeineCoordinator] in
            let store = SettingsStore.shared
            caffeineCoordinator.caffeineEnabled = store.settings.caffeineEnabled
            caffeineCoordinator.excludedSSIDs = store.settings.caffeineExcludedSSIDs

            store.$settings
                .map(\.caffeineEnabled)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .assign(to: &caffeineCoordinator.$caffeineEnabled)

            store.$settings
                .map(\.caffeineExcludedSSIDs)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .assign(to: &caffeineCoordinator.$excludedSSIDs)

            caffeineCoordinator.sessionTimeoutEnabled = store.settings.caffeineSessionTimeoutEnabled
            caffeineCoordinator.sessionTimeoutMinutes = store.settings.caffeineSessionTimeoutMinutes

            store.$settings
                .map(\.caffeineSessionTimeoutEnabled)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .assign(to: &caffeineCoordinator.$sessionTimeoutEnabled)

            store.$settings
                .map(\.caffeineSessionTimeoutMinutes)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .assign(to: &caffeineCoordinator.$sessionTimeoutMinutes)

            caffeineCoordinator.bind()
        }

        // 세션 활동이 있을 때마다 lastSessionActivityAt을 최신 lastActiveAt으로 갱신.
        // activeSessions가 비어지면 compactMap이 nil을 반환해 값이 유지되므로
        // 타임아웃은 마지막 세션이 활동한 시각부터 카운트된다.
        appState.sessionStore.$activeSessions
            .receive(on: DispatchQueue.main)
            .compactMap { sessions -> Date? in
                sessions.map(\.lastActiveAt).max()
            }
            .assign(to: &caffeineCoordinator.$lastSessionActivityAt)
    }
}
