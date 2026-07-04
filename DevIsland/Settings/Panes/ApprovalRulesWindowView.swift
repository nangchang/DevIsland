import SwiftUI
import AppKit

struct ApprovalRulesWindowView: View {
    @StateObject private var state = AppState.shared
    @ObservedObject private var sessionStore = AppState.shared.sessionStore
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
                        state.insertGlobalPersistentRule(tool.id)
                    }
                }

                if state.globalAutoApproveTypes.isEmpty {
                    Text(l10n.lblNoGlobalTools)
                        .foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive) {
                        state.removeAllGlobalPersistentRules()
                    } label: {
                        Label(l10n.btnRemoveAllGlobal, systemImage: "trash.fill")
                    }

                    ForEach(Array(state.globalAutoApproveTypes.sorted()), id: \.self) { tool in
                        ruleRow(tool: tool) {
                            state.removeGlobalPersistentRule(tool)
                        }
                    }
                }
            }

            Section(l10n.secSessionRules) {
                Text(l10n.descSessionRules)
                    .foregroundStyle(.secondary)

                if sessionStore.activeSessions.isEmpty {
                    Text(l10n.lblNoSessions)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessionStore.activeSessions) { session in
                        let tools = sessionStore.sessionAutoApproveTypes[session.id] ?? []
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
                                    sessionStore.sessionAutoApproveTypes[session.id]?.removeAll()
                                } label: {
                                    Label(l10n.btnRemoveAllSession, systemImage: "trash.fill")
                                }

                                ForEach(Array(tools.sorted()), id: \.self) { tool in
                                    ruleRow(tool: tool) {
                                        sessionStore.sessionAutoApproveTypes[session.id]?.remove(tool)
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
            try state.ruleService.addCodexPersistentRule(toolName: toolName, action: codexRuleAction)
            codexToolName = ""
            codexRuleError = nil
            loadCodexPersistentRules()
        } catch {
            codexRuleError = l10n.errSaveCodexRule(error.localizedDescription)
        }
    }

    private func deleteCodexPersistentRule(_ rule: ApprovalRule) {
        do {
            try state.ruleService.deleteCodexPersistentRule(rule)
            codexRuleError = nil
            loadCodexPersistentRules()
        } catch {
            codexRuleError = l10n.errDeleteCodexRule(error.localizedDescription)
        }
    }

    private func loadCodexPersistentRules() {
        do {
            codexPersistentRules = try state.ruleService.codexPersistentRules()
            codexRuleError = nil
        } catch {
            codexPersistentRules = []
            codexRuleError = l10n.errLoadCodexRules(error.localizedDescription)
        }
    }

    private func syncCodexPersistentRules() {
        do {
            let result = try state.ruleService.syncCodexPersistentRules()
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
        if sessionStore.sessionAutoApproveTypes[sessionId] == nil {
            sessionStore.sessionAutoApproveTypes[sessionId] = []
        }
        sessionStore.sessionAutoApproveTypes[sessionId]?.insert(tool)
    }
}
