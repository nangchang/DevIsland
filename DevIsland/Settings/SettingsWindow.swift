import SwiftUI
import AppKit

// MARK: - Window Routing

@MainActor
enum AppWindowRouter {
    private static var settingsController: HostedWindowController?
    private static var approvalRulesController: HostedWindowController?
    private static var replayLogController: HostedWindowController?
    private static var ptyTranscriptController: HostedWindowController?
    private static var sessionHistoryController: HostedWindowController?
    private static let sessionCenterPresentationState = SessionCenterPresentationState()

    static func showSettings() {
        AppState.shared.isNotchExpanded = false
        let controller = cachedController(&settingsController) {
            HostedWindowController(
                title: L10n.shared.winSettings,
                size: NSSize(width: 760, height: 560),
                rootView: AnyView(SettingsWindowView())
            )
        }
        controller.show()
    }

    static func showApprovalRules() {
        let controller = cachedController(&approvalRulesController) {
            HostedWindowController(
                title: L10n.shared.winApprovalRules,
                size: NSSize(width: 760, height: 560),
                rootView: AnyView(ApprovalRulesWindowView())
            )
        }
        controller.show()
    }

    static func showReplayLog() {
        let controller = cachedController(&replayLogController) {
            HostedWindowController(
                title: L10n.shared.winReplayLog,
                size: NSSize(width: 900, height: 600),
                rootView: AnyView(ReplayLogWindowView())
            )
        }
        controller.show()
    }

    static func showSessionHistory() {
        sessionCenterPresentationState.present()
        let controller = cachedController(&sessionHistoryController) {
            HostedWindowController(
                localizedTitleKey: "winSessionHistory",
                size: NSSize(width: 960, height: 640),
                rootView: AnyView(SessionHistoryWindowView(
                    presentationState: sessionCenterPresentationState
                )),
                onWindowWillClose: {
                    sessionCenterPresentationState.dismiss()
                }
            )
        }
        controller.show()
    }

    static func showPTYTranscript() {
        let controller = cachedController(&ptyTranscriptController) {
            HostedWindowController(
                title: L10n.shared.winPTYTranscript,
                size: NSSize(width: 860, height: 560),
                rootView: AnyView(PTYTranscriptWindowView())
            )
        }
        controller.show()
    }

    private static func cachedController(
        _ storage: inout HostedWindowController?,
        make: () -> HostedWindowController
    ) -> HostedWindowController {
        if let storage { return storage }
        let controller = make()
        storage = controller
        return controller
    }
}

// MARK: - Settings

struct SettingsWindowView: View {
    @StateObject private var appState = AppState.shared
    @StateObject private var store = SettingsStore.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        TabView {
            GeneralSettingsPane(store: store)
                .tabItem { Label(l10n.tabGeneral, systemImage: "gearshape") }

            IslandSettingsPane(displayPrefs: appState.displayPrefs, store: store)
                .tabItem { Label(l10n.tabIsland, systemImage: "sparkles.rectangle.stack") }

            ApprovalSettingsPane(appState: appState, store: store)
                .tabItem { Label(l10n.tabApproval, systemImage: "hand.raised") }

            IntegrationsSettingsPane(store: store)
                .tabItem { Label(l10n.tabIntegrations, systemImage: "puzzlepiece.extension") }

            PluginSettingsView(pluginHost: appState.pluginHost, settings: PluginSettingsStore.shared)
                .tabItem { Label(l10n.tabPlugins, systemImage: "puzzlepiece") }

            FeaturesSettingsPane(pluginHost: appState.pluginHost, store: store, appState: appState)
                .tabItem { Label(l10n.tabExtras, systemImage: "square.stack.3d.up") }

            AdvancedSettingsPane(geminiState: appState.geminiState, store: store)
                .tabItem { Label(l10n.tabAdvanced, systemImage: "slider.horizontal.3") }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 500)
    }
}

extension SettingsStore {
    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0 }
        )
    }
}
