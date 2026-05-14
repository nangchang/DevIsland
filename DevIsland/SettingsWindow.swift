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
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        TabView {
            GeneralSettingsPane(store: store)
                .tabItem { Label(l10n.tabGeneral, systemImage: "gearshape") }

            DisplaySettingsPane(appState: appState)
                .tabItem { Label(l10n.tabDisplay, systemImage: "display") }

            ApprovalSettingsPane(appState: appState, store: store)
                .tabItem { Label(l10n.tabApproval, systemImage: "hand.raised") }

            ProviderSettingsPane(store: store)
                .tabItem { Label(l10n.tabProviders, systemImage: "person.3.sequence") }

            BridgeIPCSettingsPane(store: store)
                .tabItem { Label(l10n.tabBridge, systemImage: "cable.connector") }

            ExperimentalPTYSettingsPane()
                .environmentObject(store)
                .tabItem { Label(l10n.tabExperimental, systemImage: "testtube.2") }
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
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section(l10n.secLanguage) {
                Picker(l10n.lblLanguage, selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section(l10n.secApprovalProxy) {
                Text(l10n.descApprovalProxy)
                    .foregroundStyle(.secondary)
                Button(l10n.btnResetProxy) {
                    store.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DisplaySettingsPane: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section(l10n.secNotch) {
                Picker(l10n.lblDisplay, selection: $appState.notchDisplayTarget) {
                    ForEach(NotchDisplayTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }

                if appState.notchDisplayTarget == .specific {
                    Picker(l10n.lblMonitor, selection: $appState.selectedDisplayId) {
                        ForEach(NSScreen.screens, id: \.displayId) { screen in
                            Text(displayName(for: screen)).tag(screen.displayId)
                        }
                    }
                }

                Toggle(l10n.lblShowFullScreen, isOn: $appState.showInFullScreenApps)
            }

            Section(l10n.secRequests) {
                Picker(l10n.lblRequestDisplay, selection: $appState.requestDisplayTarget) {
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
        let role = screen == NSScreen.main ? l10n.monitorMain() : l10n.monitorN(index)
        return "\(role) · \(Int(screen.frame.width))×\(Int(screen.frame.height))"
    }
}

private struct ApprovalSettingsPane: View {
    @ObservedObject var appState: AppState
    @ObservedObject var store: SettingsStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section(l10n.secAutoApprovals) {
                Toggle(l10n.lblAutoSafe, isOn: $appState.autoApproveSafeTools)
                Toggle(l10n.lblGeminiEmulate, isOn: $appState.emulateGeminiInteractiveMode)
            }

            Section(l10n.secFallback) {
                Picker(l10n.lblFallbackPolicy, selection: store.binding(\.approvalFallbackPolicy)) {
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
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section("Claude Code") {
                Picker(l10n.lblSessionApproval, selection: store.binding(\.claudeSessionApprovalMode)) {
                    ForEach(ClaudeSessionApprovalMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Text(store.settings.claudeSessionApprovalMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(l10n.lblPersistentDest, selection: store.binding(\.claudePersistentApprovalDestination)) {
                    ForEach(ClaudePersistentApprovalDestination.allCases) { destination in
                        Text(destination.label).tag(destination)
                    }
                }

                if store.settings.claudePersistentApprovalDestination == .projectSettings {
                    Label(l10n.warnProjectSettings, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Codex") {
                Text(l10n.descCodex)
                    .foregroundStyle(.secondary)
            }

            Section("Gemini") {
                Text(l10n.descGemini)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BridgeIPCSettingsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section(l10n.secTransport) {
                Picker(l10n.lblTransport, selection: store.binding(\.bridgeTransportKind)) {
                    ForEach(BridgeTransportKind.allCases) { transport in
                        Text(transport.label).tag(transport)
                    }
                }
                Text(l10n.descTransport)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(l10n.secTCP) {
                LabeledContent(l10n.lblPort, value: "\(AppSettings.defaults.bridgeTcpPort)")
            }

            Section(l10n.secUnixSocket) {
                TextField(l10n.lblSocketPath, text: store.binding(\.bridgeSocketPath))
                    .textFieldStyle(.roundedBorder)
                    .disabled(store.settings.bridgeTransportKind == .tcpLoopback)
                Toggle(l10n.lblFallbackTCP, isOn: store.binding(\.bridgeFallbackToTcp))
            }

            Section(l10n.secTimeouts) {
                LabeledContent(l10n.lblConnectTimeout,
                               value: l10n.labelSeconds(Int(AppSettings.defaults.bridgeConnectTimeoutSeconds)))
                LabeledContent(l10n.lblResponseTimeout,
                               value: l10n.labelSeconds(Int(AppSettings.defaults.bridgeResponseTimeoutSeconds)))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExperimentalPTYSettingsPane: View {
    @EnvironmentObject private var store: SettingsStore
    @ObservedObject private var l10n = L10n.shared
    @State private var newPattern = ""
    @State private var newResponse = ""

    var body: some View {
        Form {
            Section(l10n.secPTYWrapper) {
                Toggle(l10n.lblPTYEnable, isOn: $store.settings.ptyEnabled)
                Stepper(l10n.lblRetention(store.settings.ptyTranscriptRetentionDays),
                        value: $store.settings.ptyTranscriptRetentionDays, in: 1...365)
                Button(l10n.btnViewPTY) {
                    AppWindowRouter.showPTYTranscript()
                }
            }

            Section(l10n.secAutoInject) {
                if store.settings.ptyAutoInjectPatterns.isEmpty {
                    Text(l10n.lblNoPatterns)
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
                    TextField(l10n.phPattern, text: $newPattern)
                    TextField(l10n.phResponse, text: $newResponse)
                    Button(l10n.btnAdd) {
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

            Section(l10n.secUsage) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.descPTYUsage)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("python3 devisland_pty.py --source claude -- claude")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(l10n.descPTYHooks)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ApprovalRulesWindowView: View {
    @StateObject private var state = AppState.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var codexPersistentRules: [ApprovalRule] = []
    @State private var codexToolName = ""
    @State private var codexRuleAction: RuleAction = .allow
    @State private var codexRuleError: String?
    @State private var codexRuleSyncMessage: String?
    private let riskGroups = ToolRiskLevel.allCases

    var body: some View {
        Form {
            Section(l10n.secCodexRules) {
                HStack {
                    TextField(l10n.phToolName, text: $codexToolName)
                        .textFieldStyle(.roundedBorder)
                    Picker(l10n.lblAction, selection: $codexRuleAction) {
                        Text(l10n.lblAllow).tag(RuleAction.allow)
                        Text(l10n.lblDeny).tag(RuleAction.deny)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    Button {
                        addCodexPersistentRule()
                    } label: {
                        Label(l10n.btnAdd, systemImage: "plus")
                    }
                    .disabled(codexToolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        syncCodexPersistentRules()
                    } label: {
                        Label(l10n.btnExportSnapshot, systemImage: "square.and.arrow.up")
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
                    Text(l10n.lblNoCodexRules)
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

            Section(l10n.secGlobalRules) {
                Text(l10n.descGlobalRules)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(l10n.btnAddManually) {
                        state.promptToAddGlobalAutoApprove()
                    }
                    predefinedToolMenu { tool in
                        state.globalAutoApproveTypes.insert(tool.id)
                    }
                }

                if state.globalAutoApproveTypes.isEmpty {
                    Text(l10n.lblNoGlobalTools)
                        .foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive) {
                        state.globalAutoApproveTypes.removeAll()
                    } label: {
                        Label(l10n.btnRemoveAllGlobal, systemImage: "trash.fill")
                    }

                    ForEach(Array(state.globalAutoApproveTypes.sorted()), id: \.self) { tool in
                        ruleRow(tool: tool) {
                            state.globalAutoApproveTypes.remove(tool)
                        }
                    }
                }
            }

            Section(l10n.secSessionRules) {
                Text(l10n.descSessionRules)
                    .foregroundStyle(.secondary)

                if state.activeSessions.isEmpty {
                    Text(l10n.lblNoSessions)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.activeSessions) { session in
                        let tools = state.sessionAutoApproveTypes[session.id] ?? []
                        DisclosureGroup(l10n.lblSession(String(session.id.prefix(8)), tools.count)) {
                            HStack {
                                Button(l10n.btnAddManually) {
                                    state.promptToAddSessionAutoApprove(for: session.id)
                                }
                                predefinedToolMenu { tool in
                                    addSessionTool(tool.id, to: session.id)
                                }
                            }

                            if tools.isEmpty {
                                Text(l10n.lblNoSessionTools)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button(role: .destructive) {
                                    state.sessionAutoApproveTypes[session.id]?.removeAll()
                                } label: {
                                    Label(l10n.btnRemoveAllSession, systemImage: "trash.fill")
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
            codexRuleError = l10n.errSaveCodexRule(error.localizedDescription)
        }
    }

    private func deleteCodexPersistentRule(_ rule: ApprovalRule) {
        do {
            try state.deleteCodexPersistentRule(rule)
            codexRuleError = nil
            loadCodexPersistentRules()
        } catch {
            codexRuleError = l10n.errDeleteCodexRule(error.localizedDescription)
        }
    }

    private func loadCodexPersistentRules() {
        do {
            codexPersistentRules = try state.codexPersistentRules()
            codexRuleError = nil
        } catch {
            codexPersistentRules = []
            codexRuleError = l10n.errLoadCodexRules(error.localizedDescription)
        }
    }

    private func syncCodexPersistentRules() {
        do {
            let result = try state.syncCodexPersistentRules()
            codexRuleSyncMessage = l10n.exportedCodexRules(result.ruleCount, result.url.path)
            codexRuleError = nil
        } catch {
            codexRuleSyncMessage = nil
            codexRuleError = l10n.errExportCodexRules(error.localizedDescription)
        }
    }

    private func predefinedToolMenu(onSelect: @escaping (KnownTool) -> Void) -> some View {
        Menu(l10n.btnAddFromList) {
            ForEach(riskGroups, id: \.self) { risk in
                let tools = ToolKnowledge.predefined.filter { $0.risk == risk }
                if !tools.isEmpty {
                    Menu("\(risk.emoji) \(risk.rawValue)") {
                        Button(l10n.addAllRisk(risk.rawValue)) {
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
