import SwiftUI

// MARK: - Status Badge

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 7, weight: .black))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Tag View

struct TagView: View {
    let icon: String?
    let text: String
    var color: Color = .white.opacity(0.15)

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
            }
            Text(text)
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundColor(.white.opacity(0.8))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color)
        .clipShape(Capsule())
    }
}

// MARK: - Agent Request Badge

struct AgentRequestBadge: View {
    let kind: BuddyKind
    let tool: ToolInfo
    let isActive: Bool
    var size: CGFloat = 48

    private var mascotSize: CGFloat { size * 0.88 }
    private var requestBadgeSize: CGFloat { size * 0.38 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(kind.accentColor.opacity(0.18))
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(kind.accentColor.opacity(0.28), lineWidth: 1)
                )

            CLIBuddyView(isActive: isActive, kind: kind)
                .frame(width: mascotSize, height: mascotSize)
                .offset(x: -size * 0.04, y: size * 0.03)

            Circle()
                .fill(Color.black.opacity(0.92))
                .frame(width: requestBadgeSize, height: requestBadgeSize)
                .overlay(
                    Circle()
                        .fill(tool.color.opacity(0.22))
                )
                .overlay(
                    Image(systemName: tool.icon)
                        .font(.system(size: size * 0.18, weight: .black))
                        .foregroundColor(tool.color)
                )
                .overlay(
                    Circle()
                        .stroke(Color.black, lineWidth: max(1.5, size * 0.04))
                )
                .offset(x: size * 0.05, y: size * 0.04)
        }
        .frame(width: size + size * 0.08, height: size + size * 0.08)
        .accessibilityLabel("\(kind.accessibilityName) \(tool.label)")
    }
}

// MARK: - Claude Question Form

struct ClaudeQuestionFormView: View {
    let request: ClaudeQuestionRequest
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(request.questions.enumerated()), id: \.element.id) { index, question in
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        if request.questions.count > 1 {
                            Text("Question \(index + 1)")
                                .font(.system(size: 9, weight: .black))
                                .foregroundColor(.white.opacity(0.35))
                        }

                        if let title = question.title, title != question.prompt {
                            Text(title)
                                .font(.system(size: 12, weight: .black))
                                .foregroundColor(.white.opacity(0.75))
                        }

                        Text(question.prompt)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !question.options.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(question.options) { option in
                                ClaudeQuestionOptionRow(
                                    title: option.label,
                                    detail: option.detail,
                                    isSelected: isSelected(option.id, for: question.id),
                                    allowsMultipleSelection: question.allowsMultipleSelection
                                ) {
                                    state.setClaudeQuestionOption(questionId: question.id, optionId: option.id)
                                }
                            }

                            if question.allowsTextInput {
                                ClaudeQuestionOptionRow(
                                    title: "Other",
                                    detail: "Type a custom answer",
                                    isSelected: usesCustomText(for: question.id),
                                    allowsMultipleSelection: question.allowsMultipleSelection
                                ) {
                                    state.setClaudeQuestionCustomAnswerEnabled(
                                        questionId: question.id,
                                        isEnabled: !usesCustomText(for: question.id)
                                    )
                                }
                            }
                        }
                    }

                    if shouldShowTextInput(for: question) {
                        TextField("", text: Binding(
                            get: { state.currentClaudeQuestionAnswers[question.id]?.text ?? "" },
                            set: { state.setClaudeQuestionText(questionId: question.id, text: $0) }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func isSelected(_ optionId: String, for questionId: String) -> Bool {
        state.currentClaudeQuestionAnswers[questionId]?.selectedOptionIds.contains(optionId) == true
    }

    private func usesCustomText(for questionId: String) -> Bool {
        state.currentClaudeQuestionAnswers[questionId]?.usesCustomText == true
    }

    private func shouldShowTextInput(for question: ClaudeQuestionRequest.Question) -> Bool {
        question.options.isEmpty || usesCustomText(for: question.id)
    }
}

private struct ClaudeQuestionOptionRow: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    let allowsMultipleSelection: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selectedIcon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isSelected ? .green : .white.opacity(0.35))
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(2)

                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.48))
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.green.opacity(0.13) : Color.white.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.green.opacity(0.45) : Color.white.opacity(0.07), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var selectedIcon: String {
        if allowsMultipleSelection {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }
}

// MARK: - Session Row View

struct SessionRowView: View {
    let session: ActiveSession
    let isCurrent: Bool
    var isSubAgent: Bool = false

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var appState = AppState.shared
    @State private var timeAgo: String = ""
    private var tool: ToolInfo { toolInfo(for: session.lastToolName) }
    private var displayTitle: String {
        appState.sessionLabels[session.id] ?? session.terminalTitle
    }
    private var hasCustomLabel: Bool {
        appState.sessionLabels[session.id] != nil
    }

    private var resumeCommand: String {
        let cd = session.workspaceRoot.map { "cd \($0.contains(" ") ? "\"\($0)\"" : $0) && " } ?? ""
        switch session.agentKind {
        case .claudeCode: return "\(cd)claude --resume \(session.id)"
        case .codex:      return "\(cd)codex --resume \(session.id)"
        case .gemini:     return "\(cd)gemini"
        case .island:     return cd.isEmpty ? "" : String(cd.dropLast(4)) // cd only
        }
    }

    private var autoTerminalName: String {
        TerminalFocuser.resolvedTerminalName(
            preferred: SettingsStore.shared.settings.preferredTerminal,
            sessionTerminal: session.workspaceRoot != nil ? session.terminalApp : nil
        ) ?? "?"
    }

    private func openInTerminal(appName: String? = nil) {
        let name = appName ?? autoTerminalName
        TerminalFocuser.openNewWindow(appName: name, command: resumeCommand)
    }
    private var statusLabel: String? {
        switch session.status {
        case .pending:       return l10n.statusPending
        case .timeoutBypassed: return l10n.statusBypassed
        case .autoApproved:  return l10n.statusAutoApproved
        case .policyApproved: return l10n.statusPolicyApproved
        case .idle:          return nil
        }
    }
    private var statusColor: Color {
        switch session.status {
        case .pending:
            return .orange
        case .timeoutBypassed:
            return Color(red: 0.2, green: 0.8, blue: 0.9)
        case .autoApproved:
            return Color(red: 0.2, green: 0.9, blue: 0.5)
        case .policyApproved:
            return Color(red: 0.45, green: 0.75, blue: 1.0)
        case .idle:
            return .white.opacity(0.3)
        }
    }

    private static let sharedTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var badgeSize: CGFloat    { isSubAgent ? 24 : 32 }
    private var badgeFrame: CGFloat   { isSubAgent ? 28 : 36 }
    private var titleFont: CGFloat    { isSubAgent ? 10 : 12 }
    private var metaFont: CGFloat     { isSubAgent ? 8 : 9 }
    private var messageFont: CGFloat  { isSubAgent ? 9 : 10 }
    private var buttonSize: CGFloat   { isSubAgent ? 22 : 28 }
    private var vertPadding: CGFloat  { isSubAgent ? 6 : 10 }

    var body: some View {
        HStack(spacing: 8) {
            if isSubAgent {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 2)
                    .padding(.leading, 8)
            }
            Button(action: { AppState.shared.showSessionDetail(session.id) }) {
                HStack(spacing: isSubAgent ? 8 : 12) {
                    ZStack(alignment: .topTrailing) {
                        AgentRequestBadge(
                            kind: session.agentKind,
                            tool: tool,
                            isActive: session.isPending,
                            size: badgeSize
                        )

                        if session.isPending {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: isSubAgent ? 8 : 10, height: isSubAgent ? 8 : 10)
                                .overlay(Circle().stroke(Color.black, lineWidth: 2))
                                .offset(x: 4, y: -4)
                        }
                    }
                    .frame(width: badgeFrame, height: badgeFrame)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if session.hasMissedApproval {
                                Circle()
                                    .fill(Color.red.opacity(0.9))
                                    .frame(width: isSubAgent ? 6 : 7, height: isSubAgent ? 6 : 7)
                            } else if session.isUnread {
                                Circle()
                                    .fill(Color.blue.opacity(0.85))
                                    .frame(width: isSubAgent ? 5 : 6, height: isSubAgent ? 5 : 6)
                            }

                            Text(displayTitle)
                                .font(.system(size: titleFont, weight: (session.hasMissedApproval || session.isUnread) ? .heavy : .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            if hasCustomLabel {
                                Image(systemName: "tag.fill")
                                    .font(.system(size: titleFont - 2))
                                    .foregroundColor(.white.opacity(0.4))
                            }

                            Spacer()

                            Text(timeAgo)
                                .font(.system(size: metaFont - 1, weight: .medium))
                                .foregroundColor(.white.opacity(0.3))
                        }

                        HStack(spacing: 6) {
                            Text(String(session.id.prefix(8)))
                                .font(.system(size: metaFont, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))

                            Text("•")
                                .font(.system(size: metaFont - 1))
                                .foregroundColor(.white.opacity(0.2))

                            Text(session.lastEventName)
                                .font(.system(size: metaFont, weight: .bold))
                                .foregroundColor(tool.color.opacity(0.8))
                                .lineLimit(1)

                            if let statusLabel = statusLabel {
                                Text(statusLabel)
                                    .font(.system(size: metaFont - 1, weight: .black))
                                    .foregroundColor(statusColor)
                                    .lineLimit(1)
                            }

                            if session.isAutoEditActive {
                                Text(l10n.statusAutoEdit)
                                    .font(.system(size: metaFont - 1, weight: .black))
                                    .foregroundColor(Color(red: 1.0, green: 0.7, blue: 0.2))
                                    .lineLimit(1)
                            }

                            if !session.lastToolName.isEmpty {
                                Text(session.lastToolName)
                                    .font(.system(size: metaFont, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }

                        if !session.lastMessage.isEmpty {
                            Text(session.lastMessage)
                                .font(.system(size: messageFont, weight: .regular, design: .monospaced))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { AppState.shared.focusTerminal(for: session.id) }) {
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: isSubAgent ? 10 : 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: isSubAgent ? 6 : 8))
            }
            .buttonStyle(.plain)
            .help("Focus terminal")

            Button(action: { AppState.shared.dismissSession(session.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: isSubAgent ? 10 : 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.65))
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: isSubAgent ? 6 : 8))
            }
            .buttonStyle(.plain)
            .help(session.isPending ? l10n.helpDismissPending : l10n.helpDismissSession)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, vertPadding)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrent ? Color.white.opacity(0.1) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCurrent ? tool.color.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .onAppear { updateTimeAgo() }
        .onReceive(Self.sharedTimer) { _ in updateTimeAgo() }
        .contextMenu {
            Button {
                AppState.shared.promptRenameSession(
                    session.id,
                    currentLabel: appState.sessionLabels[session.id]
                )
            } label: {
                Label(l10n.menuRenameSession, systemImage: "pencil")
            }

            Divider()

            if let path = session.workspaceRoot {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Label(l10n.menuOpenInFinder, systemImage: "folder")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Label(l10n.menuCopyPath, systemImage: "doc.on.clipboard")
                }

                Divider()
            }

            openInTerminalMenu

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(resumeCommand, forType: .string)
            } label: {
                Label(l10n.menuCopyResumeCommand, systemImage: "arrow.counterclockwise")
            }
        }
    }

    @ViewBuilder
    private var openInTerminalMenu: some View {
        let installed = TerminalFocuser.installedTerminals
        let auto = autoTerminalName
        Menu {
            Button { openInTerminal() } label: {
                Label(l10n.menuTerminalAuto(auto), systemImage: "terminal")
            }
            if !installed.isEmpty {
                Divider()
                ForEach(installed, id: \.name) { terminal in
                    Button { openInTerminal(appName: terminal.name) } label: {
                        Label(terminal.name, systemImage: terminal.name == auto ? "checkmark" : "terminal")
                    }
                }
            }
        } label: {
            Label(l10n.menuOpenInTerminal, systemImage: "terminal")
        }
    }

    private func updateTimeAgo() {
        let diff = Int(Date().timeIntervalSince(session.lastActiveAt))
        let l = L10n.shared
        if diff < 5 { timeAgo = l.timeJustNow() }
        else if diff < 60 { timeAgo = l.timeSecsAgo(diff) }
        else { timeAgo = l.timeMinsAgo(diff / 60) }
    }
}
