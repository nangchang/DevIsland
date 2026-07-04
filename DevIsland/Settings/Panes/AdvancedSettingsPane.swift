import SwiftUI
import AppKit

struct AdvancedSettingsPane: View {
    @ObservedObject var geminiState: GeminiSessionState
    @ObservedObject var store: SettingsStore
    @ObservedObject private var l10n = L10n.shared
    @State private var selection: AdvancedSettingsSection = .providers

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $selection) {
                ForEach(AdvancedSettingsSection.allCases) { section in
                    Label(section.label, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch selection {
                case .providers:
                    ProviderSettingsPane(geminiState: geminiState, store: store)
                case .bridge:
                    BridgeIPCSettingsPane(store: store)
                case .diagnostics:
                    BridgeDiagnosticsPane()
                case .experimental:
                    ExperimentalPTYSettingsPane()
                        .environmentObject(store)
                }
            }
        }
        .padding()
    }

    private enum AdvancedSettingsSection: String, CaseIterable, Identifiable {
        case providers
        case bridge
        case diagnostics
        case experimental

        var id: String { rawValue }

        var label: String {
            let l = L10n.shared
            switch self {
            case .providers:    return l.tabProviders
            case .bridge:       return l.tabBridge
            case .diagnostics:  return l.tabDiagnostics
            case .experimental: return l.tabExperimental
            }
        }

        var systemImage: String {
            switch self {
            case .providers:    return "person.3.sequence"
            case .bridge:       return "cable.connector"
            case .diagnostics:  return "stethoscope"
            case .experimental: return "testtube.2"
            }
        }
    }
}

private struct ProviderSettingsPane: View {
    @ObservedObject var geminiState: GeminiSessionState
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

                Text(store.settings.claudePersistentApprovalDestination.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if store.settings.claudePersistentApprovalDestination == .projectSettings {
                    Label(l10n.warnProjectSettings, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Codex") {
                Text(l10n.descCodex)
                    .foregroundStyle(.secondary)
            }

            Section("Gemini / Antigravity") {
                Toggle(isOn: $geminiState.emulateInteractiveMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.lblGeminiEmulate)
                        Text(l10n.descGemini)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct BridgeIPCSettingsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var l10n = L10n.shared

    private var isGraceMode: Bool { BridgeTokenManager.shared.isGraceMode }

    var body: some View {
        Form {
            if isGraceMode {
                Section(l10n.secTokenSecurity) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l10n.warnGraceMode)
                                .foregroundStyle(.primary)
                            Text(l10n.hintGraceModeResolve)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

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

// MARK: - Bridge Diagnostics

private struct BridgeDiagnosticsPane: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var hookStatuses: [BridgeHookStatus] = []
    @State private var lastEventAt: Date?
    @State private var logLines: [String] = []
    @State private var bridgeScriptInstalled = false

    var body: some View {
        Form {
            Section(l10n.secBridgeScript) {
                LabeledContent(l10n.lblBridgeInstallPath) {
                    Text(BridgeHealthDetector.bridgeScriptURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Image(systemName: bridgeScriptInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(bridgeScriptInstalled ? .green : .red)
                    Text(bridgeScriptInstalled ? l10n.lblBridgeFileFound : l10n.lblBridgeFileNotFound)
                }
            }

            Section(l10n.secHookStatus) {
                ForEach(hookStatuses, id: \.provider.displayName) { status in
                    HStack(spacing: 6) {
                        Image(systemName: hookStatusIcon(status))
                            .foregroundStyle(hookStatusColor(status))
                        Text(status.provider.displayName)
                        Spacer()
                        Text(hookStatusLabel(status))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            Section(l10n.secLastEvent) {
                if let lastEventAt {
                    Text(lastEventAt, style: .relative)
                } else {
                    Text(l10n.lblNoEventYet)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(l10n.btnDiagRefresh) { refresh() }
            }

            if !logLines.isEmpty {
                Section(l10n.secBridgeLog) {
                    ScrollView {
                        Text(logLines.joined(separator: "\n"))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                }
            } else {
                Section(l10n.secBridgeLog) {
                    Text(l10n.secBridgeLogEmpty)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func refresh() {
        let appState = AppState.shared
        Task.detached(priority: .utility) {
            let statuses = BridgeHealthDetector.allHookStatuses()
            let logTail = BridgeHealthDetector.logTail(maxLines: 20)
            let scriptInstalled = BridgeHealthDetector.isBridgeScriptInstalled
            let lastEvent = try? appState.replayLogEntries(limit: 1).first
            await MainActor.run {
                self.hookStatuses = statuses
                self.logLines = logTail
                self.bridgeScriptInstalled = scriptInstalled
                self.lastEventAt = lastEvent?.receivedAt
            }
        }
    }

    private func hookStatusIcon(_ status: BridgeHookStatus) -> String {
        if status.isInstalled { return "checkmark.circle.fill" }
        if status.settingsFileExists { return "exclamationmark.circle.fill" }
        return "minus.circle"
    }

    private func hookStatusColor(_ status: BridgeHookStatus) -> Color {
        if status.isInstalled { return .green }
        if status.settingsFileExists { return .orange }
        return .secondary
    }

    private func hookStatusLabel(_ status: BridgeHookStatus) -> String {
        if status.isInstalled { return l10n.lblHookInstalled }
        if status.settingsFileExists { return l10n.lblHookNotInstalled }
        return l10n.lblHookFileMissing
    }
}
