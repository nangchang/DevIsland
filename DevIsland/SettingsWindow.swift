import SwiftUI
import AppKit

// MARK: - Window Routing

enum AppWindowRouter {
    private static let settingsController = HostedWindowController(
        title: "DevIsland Settings",
        size: NSSize(width: 760, height: 560),
        rootView: AnyView(SettingsWindowView())
    )

    private static let approvalRulesController = HostedWindowController(
        title: "Approval Rules",
        size: NSSize(width: 720, height: 480),
        rootView: AnyView(PlaceholderToolWindowView(
            title: "Approval Rules",
            systemImage: "checklist.checked",
            message: "Persistent and session approval rule management will be implemented in a later Approval Proxy phase."
        ))
    )

    private static let replayLogController = HostedWindowController(
        title: "Replay Log",
        size: NSSize(width: 720, height: 480),
        rootView: AnyView(PlaceholderToolWindowView(
            title: "Replay Log",
            systemImage: "clock.arrow.circlepath",
            message: "Hook event replay, decision audit, and rule creation from events will be implemented in a later Approval Proxy phase."
        ))
    )

    static func showSettings() { settingsController.show() }
    static func showApprovalRules() { approvalRulesController.show() }
    static func showReplayLog() { replayLogController.show() }
}

final class HostedWindowController: NSWindowController {
    init(title: String, size: NSSize, rootView: AnyView) {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.setContentSize(size)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.centerIfNotVisible()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private extension NSWindow {
    func centerIfNotVisible() {
        guard !isVisible else { return }
        center()
    }
}

// MARK: - Settings

struct SettingsWindowView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        TabView {
            GeneralSettingsPane(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }

            DisplaySettingsPane(appState: appState)
                .tabItem { Label("Display", systemImage: "display") }

            ApprovalSettingsPane(appState: appState, store: store)
                .tabItem { Label("Approval", systemImage: "hand.raised") }

            ProviderSettingsPane(store: store)
                .tabItem { Label("Providers", systemImage: "person.3.sequence") }

            BridgeIPCSettingsPane(store: store)
                .tabItem { Label("Bridge / IPC", systemImage: "cable.connector") }

            ExperimentalPTYSettingsPane()
                .tabItem { Label("Experimental", systemImage: "testtube.2") }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 500)
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Approval Proxy") {
                Text("DevIsland is being expanded from a notch approval UI into the app-hosted Approval Proxy daemon and UI described in docs/approval-proxy.md.")
                    .foregroundStyle(.secondary)
                Button("Reset Approval Proxy Settings") {
                    store.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DisplaySettingsPane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Notch") {
                Picker("Display", selection: $appState.notchDisplayTarget) {
                    ForEach(NotchDisplayTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }

                if appState.notchDisplayTarget == .specific {
                    Picker("Monitor", selection: $appState.selectedDisplayId) {
                        ForEach(NSScreen.screens, id: \.displayId) { screen in
                            Text(displayName(for: screen)).tag(screen.displayId)
                        }
                    }
                }

                Toggle("Show above full-screen apps", isOn: $appState.showInFullScreenApps)
            }

            Section("Requests") {
                Picker("Request display", selection: $appState.requestDisplayTarget) {
                    ForEach(RequestDisplayTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func displayName(for screen: NSScreen) -> String {
        let index = NSScreen.screens.firstIndex(of: screen).map { $0 + 1 } ?? 1
        let role = screen == NSScreen.main ? "Main monitor" : "Monitor \(index)"
        return "\(role) · \(Int(screen.frame.width))×\(Int(screen.frame.height))"
    }
}

private struct ApprovalSettingsPane: View {
    @ObservedObject var appState: AppState
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Automatic approvals") {
                Toggle("Auto-approve safe/read-only tools", isOn: $appState.autoApproveSafeTools)
                Toggle("Gemini interactive emulation", isOn: $appState.emulateGeminiInteractiveMode)
            }

            Section("Transport failure fallback") {
                Picker("Fallback policy", selection: binding(\.approvalFallbackPolicy)) {
                    ForEach(ApprovalFallbackPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0 }
        )
    }
}

private struct ProviderSettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Claude Code") {
                Picker("Session approval mode", selection: binding(\.claudeSessionApprovalMode)) {
                    ForEach(ClaudeSessionApprovalMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Text(store.settings.claudeSessionApprovalMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Persistent approval destination", selection: binding(\.claudePersistentApprovalDestination)) {
                    ForEach(ClaudePersistentApprovalDestination.allCases) { destination in
                        Text(destination.label).tag(destination)
                    }
                }

                if store.settings.claudePersistentApprovalDestination == .projectSettings {
                    Label("Project settings can be committed to the repository. Review changes before committing.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Codex") {
                Text("Codex session approval will use DevIsland-managed cache and persistent SQLite rules in later phases.")
                    .foregroundStyle(.secondary)
            }

            Section("Gemini") {
                Text("Existing Gemini auto-edit, interactive notification, and safe-tool behavior remain compatible with Approval Proxy settings.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0 }
        )
    }
}

private struct BridgeIPCSettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Transport") {
                Picker("Transport", selection: binding(\.bridgeTransportKind)) {
                    ForEach(BridgeTransportKind.allCases) { transport in
                        Text(transport.label).tag(transport)
                    }
                }
                Toggle("Fallback to TCP when Unix socket is unavailable", isOn: binding(\.bridgeFallbackToTcp))
            }

            Section("TCP") {
                Stepper(value: binding(\.bridgeTcpPort), in: 1...65535) {
                    Text("Port: \(store.settings.bridgeTcpPort)")
                }
            }

            Section("Unix domain socket") {
                TextField("Socket path", text: binding(\.bridgeSocketPath))
                    .textFieldStyle(.roundedBorder)
            }

            Section("Timeouts") {
                Stepper(value: binding(\.bridgeConnectTimeoutSeconds), in: 1...60, step: 1) {
                    Text("Connect timeout: \(Int(store.settings.bridgeConnectTimeoutSeconds)) seconds")
                }
                Stepper(value: binding(\.bridgeResponseTimeoutSeconds), in: 1...86400, step: 10) {
                    Text("Response timeout: \(Int(store.settings.bridgeResponseTimeoutSeconds)) seconds")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { store.settings[keyPath: keyPath] = $0 }
        )
    }
}

private struct ExperimentalPTYSettingsPane: View {
    var body: some View {
        Form {
            Section("PTY") {
                Text("PTY-assisted interaction remains optional and is scheduled after replay log and policy engine work.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaceholderToolWindowView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
