import SwiftUI
import AppKit

// MARK: - Window Routing

@MainActor
enum AppWindowRouter {
    private static var settingsController: HostedWindowController?
    private static var approvalRulesController: HostedWindowController?
    private static var replayLogController: HostedWindowController?
    private static var ptyTranscriptController: HostedWindowController?

    static func showSettings() {
        let controller = cachedController(&settingsController) {
            HostedWindowController(
                title: "DevIsland Settings",
                size: NSSize(width: 760, height: 560),
                rootView: AnyView(SettingsWindowView())
            )
        }
        controller.show()
    }

    static func showApprovalRules() {
        let controller = cachedController(&approvalRulesController) {
            HostedWindowController(
                title: "Approval Rules",
                size: NSSize(width: 760, height: 560),
                rootView: AnyView(ApprovalRulesWindowView())
            )
        }
        controller.show()
    }

    static func showReplayLog() {
        let controller = cachedController(&replayLogController) {
            HostedWindowController(
                title: "Replay Log",
                size: NSSize(width: 900, height: 600),
                rootView: AnyView(ReplayLogWindowView())
            )
        }
        controller.show()
    }

    static func showPTYTranscript() {
        let controller = cachedController(&ptyTranscriptController) {
            HostedWindowController(
                title: "PTY Transcript",
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

@MainActor
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
    @StateObject private var appState = AppState.shared
    @StateObject private var store = SettingsStore.shared

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
                .environmentObject(store)
                .tabItem { Label("Experimental", systemImage: "testtube.2") }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 500)
    }
}

private extension SettingsStore {
    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0 }
        )
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Approval Proxy") {
                Text("DevIsland acts as a policy-based Approval Proxy daemon. The macOS app handles all policy decisions; the bridge scripts stay thin. See AGENTS.md for architecture details.")
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
                Picker("Fallback policy", selection: store.binding(\.approvalFallbackPolicy)) {
                    ForEach(ApprovalFallbackPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Claude Code") {
                Picker("Session approval mode", selection: store.binding(\.claudeSessionApprovalMode)) {
                    ForEach(ClaudeSessionApprovalMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Text(store.settings.claudeSessionApprovalMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Persistent approval destination", selection: store.binding(\.claudePersistentApprovalDestination)) {
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
}

private struct BridgeIPCSettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Transport") {
                Picker("Transport", selection: store.binding(\.bridgeTransportKind)) {
                    ForEach(BridgeTransportKind.allCases) { transport in
                        Text(transport.label).tag(transport)
                    }
                }
                Text("Transport changes are written to the bridge runtime config. Restart DevIsland after switching listener transports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("TCP") {
                LabeledContent("Port", value: "\(AppSettings.defaults.bridgeTcpPort)")
            }

            Section("Unix domain socket") {
                TextField("Socket path", text: store.binding(\.bridgeSocketPath))
                    .textFieldStyle(.roundedBorder)
                    .disabled(store.settings.bridgeTransportKind == .tcpLoopback)
                Toggle("Fallback to TCP loopback", isOn: store.binding(\.bridgeFallbackToTcp))
            }

            Section("Timeouts") {
                LabeledContent("Connect timeout", value: "\(Int(AppSettings.defaults.bridgeConnectTimeoutSeconds)) seconds")
                LabeledContent("Response timeout", value: "\(Int(AppSettings.defaults.bridgeResponseTimeoutSeconds)) seconds")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExperimentalPTYSettingsPane: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var newPattern = ""
    @State private var newResponse = ""

    var body: some View {
        Form {
            Section("PTY Wrapper") {
                Toggle("Enable PTY logging and auto-inject", isOn: $store.settings.ptyEnabled)
                Stepper("Transcript retention: \(store.settings.ptyTranscriptRetentionDays) days",
                        value: $store.settings.ptyTranscriptRetentionDays, in: 1...365)
                Button("View PTY Transcript…") {
                    AppWindowRouter.showPTYTranscript()
                }
            }

            Section("Auto-inject patterns") {
                if store.settings.ptyAutoInjectPatterns.isEmpty {
                    Text("No patterns. Add one below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.settings.ptyAutoInjectPatterns) { pattern in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pattern.pattern).font(.system(.body, design: .monospaced))
                                Text("→ \(pattern.response)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                store.settings.ptyAutoInjectPatterns.removeAll { $0.id == pattern.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("Pattern (substring)", text: $newPattern)
                    TextField("Response text", text: $newResponse)
                    Button("Add") {
                        let p = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                        let r = newResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !p.isEmpty, !r.isEmpty else { return }
                        store.settings.ptyAutoInjectPatterns.append(PTYAutoInjectPattern(pattern: p, response: r))
                        newPattern = ""
                        newResponse = ""
                    }
                    .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              newResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Usage") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run a CLI agent through the PTY wrapper:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("python3 devisland_pty.py --source claude -- claude")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("The script forwards PTYOutput hook events to the app.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ApprovalRulesWindowView: View {
    @StateObject private var state = AppState.shared
    @State private var codexPersistentRules: [ApprovalRule] = []
    @State private var codexToolName = ""
    @State private var codexRuleAction: RuleAction = .allow
    @State private var codexRuleError: String?
    @State private var codexRuleSyncMessage: String?
    private let riskGroups = ToolRiskLevel.allCases

    var body: some View {
        Form {
            Section("Codex persistent SQLite rules") {
                HStack {
                    TextField("Tool name", text: $codexToolName)
                        .textFieldStyle(.roundedBorder)
                    Picker("Action", selection: $codexRuleAction) {
                        Text("Allow").tag(RuleAction.allow)
                        Text("Deny").tag(RuleAction.deny)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    Button {
                        addCodexPersistentRule()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(codexToolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        syncCodexPersistentRules()
                    } label: {
                        Label("Export Snapshot", systemImage: "square.and.arrow.up")
                    }
                }

                if let codexRuleError {
                    Label(codexRuleError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let codexRuleSyncMessage {
                    Label(codexRuleSyncMessage, systemImage: "doc.text")
                        .foregroundStyle(.secondary)
                }

                if codexPersistentRules.isEmpty {
                    Text("No Codex persistent SQLite rules are configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(codexPersistentRules) { rule in
                        HStack {
                            let risk = ToolKnowledge.risk(for: rule.toolName)
                            Label("\(rule.toolName) \(risk.emoji)", systemImage: rule.action == .allow ? "checkmark.circle" : "xmark.octagon")
                            Text(rule.action.rawValue)
                                .foregroundStyle(rule.action == .allow ? .green : .red)
                            Spacer()
                            Button(role: .destructive) {
                                deleteCodexPersistentRule(rule)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("Global auto-approval tools") {
                Text("These existing DevIsland rules are checked for every session before showing an approval prompt.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Add manually…") {
                        state.promptToAddGlobalAutoApprove()
                    }
                    predefinedToolMenu { tool in
                        state.globalAutoApproveTypes.insert(tool.id)
                    }
                }

                if state.globalAutoApproveTypes.isEmpty {
                    Text("No global auto-approval tools are configured.")
                        .foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive) {
                        state.globalAutoApproveTypes.removeAll()
                    } label: {
                        Label("Remove all global tools", systemImage: "trash.fill")
                    }

                    ForEach(Array(state.globalAutoApproveTypes.sorted()), id: \.self) { tool in
                        ruleRow(tool: tool) {
                            state.globalAutoApproveTypes.remove(tool)
                        }
                    }
                }
            }

            Section("Session auto-approval tools") {
                Text("Session rules remain available until the corresponding active session is removed.")
                    .foregroundStyle(.secondary)

                if state.activeSessions.isEmpty {
                    Text("No active sessions.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.activeSessions) { session in
                        let tools = state.sessionAutoApproveTypes[session.id] ?? []
                        DisclosureGroup("Session \(session.id.prefix(8)) (\(tools.count) tools)") {
                            HStack {
                                Button("Add manually…") {
                                    state.promptToAddSessionAutoApprove(for: session.id)
                                }
                                predefinedToolMenu { tool in
                                    addSessionTool(tool.id, to: session.id)
                                }
                            }

                            if tools.isEmpty {
                                Text("No session auto-approval tools are configured.")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button(role: .destructive) {
                                    state.sessionAutoApproveTypes[session.id]?.removeAll()
                                } label: {
                                    Label("Remove all session tools", systemImage: "trash.fill")
                                }

                                ForEach(Array(tools.sorted()), id: \.self) { tool in
                                    ruleRow(tool: tool) {
                                        state.sessionAutoApproveTypes[session.id]?.remove(tool)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 700, minHeight: 500)
        .onAppear(perform: loadCodexPersistentRules)
    }

    private func addCodexPersistentRule() {
        let toolName = codexToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else { return }
        do {
            try state.addCodexPersistentRule(toolName: toolName, action: codexRuleAction)
            codexToolName = ""
            codexRuleError = nil
            loadCodexPersistentRules()
        } catch {
            codexRuleError = "Failed to save Codex rule: \(error.localizedDescription)"
        }
    }

    private func deleteCodexPersistentRule(_ rule: ApprovalRule) {
        do {
            try state.deleteCodexPersistentRule(rule)
            codexRuleError = nil
            loadCodexPersistentRules()
        } catch {
            codexRuleError = "Failed to delete Codex rule: \(error.localizedDescription)"
        }
    }

    private func loadCodexPersistentRules() {
        do {
            codexPersistentRules = try state.codexPersistentRules()
            codexRuleError = nil
        } catch {
            codexPersistentRules = []
            codexRuleError = "Failed to load Codex rules: \(error.localizedDescription)"
        }
    }

    private func syncCodexPersistentRules() {
        do {
            let result = try state.syncCodexPersistentRules()
            codexRuleSyncMessage = "Exported \(result.ruleCount) Codex rules to \(result.url.path)"
            codexRuleError = nil
        } catch {
            codexRuleSyncMessage = nil
            codexRuleError = "Failed to export Codex rules: \(error.localizedDescription)"
        }
    }

    private func predefinedToolMenu(onSelect: @escaping (KnownTool) -> Void) -> some View {
        Menu("Add from list") {
            ForEach(riskGroups, id: \.self) { risk in
                let tools = ToolKnowledge.predefined.filter { $0.risk == risk }
                if !tools.isEmpty {
                    Menu("\(risk.emoji) \(risk.rawValue)") {
                        Button("Add all \(risk.rawValue) tools") {
                            tools.forEach(onSelect)
                        }
                        Divider()
                        ForEach(tools) { tool in
                            Button("\(tool.name) (\(tool.id)) \(risk.emoji)") {
                                onSelect(tool)
                            }
                        }
                    }
                }
            }
        }
    }

    private func ruleRow(tool: String, onRemove: @escaping () -> Void) -> some View {
        HStack {
            let risk = ToolKnowledge.risk(for: tool)
            Label("\(tool) \(risk.emoji)", systemImage: "checkmark.circle")
            Spacer()
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func addSessionTool(_ tool: String, to sessionId: String) {
        if state.sessionAutoApproveTypes[sessionId] == nil {
            state.sessionAutoApproveTypes[sessionId] = []
        }
        state.sessionAutoApproveTypes[sessionId]?.insert(tool)
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
