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
                                    preview: option.preview,
                                    previewFormat: question.previewFormat,
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
                                    preview: nil,
                                    previewFormat: question.previewFormat,
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
    let preview: String?
    let previewFormat: ClaudeQuestionRequest.Question.PreviewFormat
    let isSelected: Bool
    let allowsMultipleSelection: Bool
    let action: () -> Void

    var body: some View {
        let hasPreview = isSelected && preview?.isEmpty == false
        VStack(alignment: .leading, spacing: 0) {
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
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 8,
                        bottomLeadingRadius: hasPreview ? 0 : 8,
                        bottomTrailingRadius: hasPreview ? 0 : 8,
                        topTrailingRadius: 8
                    )
                )
            }
            .buttonStyle(.plain)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.green.opacity(0.45) : Color.white.opacity(0.07), lineWidth: 1)
                    .padding(.bottom, hasPreview ? -8 : 0)
            )
            .zIndex(1)

            if hasPreview, let preview {
                Group {
                    if previewFormat == .html {
                        HTMLPreviewView(html: preview)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ScrollView {
                            MarkdownView(
                                text: preview,
                                foregroundColor: .white.opacity(0.75),
                                font: .system(size: 11, weight: .regular)
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 200)
                .background(Color.green.opacity(0.07))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 8,
                        bottomTrailingRadius: 8,
                        topTrailingRadius: 0
                    )
                )
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 8,
                        bottomTrailingRadius: 8,
                        topTrailingRadius: 0
                    )
                    .stroke(Color.green.opacity(0.45), lineWidth: 1)
                )
            }
        }
    }

    private var selectedIcon: String {
        if allowsMultipleSelection {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }
}

// MARK: - HTML Preview View

import WebKit

private struct HTMLPreviewView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let limitedHTML = HTMLPreviewContentPolicy.limit(html)
        guard context.coordinator.renderedHTML != limitedHTML else { return }
        context.coordinator.prepareToLoad(limitedHTML)
        webView.loadHTMLString(HTMLPreviewContentPolicy.document(containing: limitedHTML), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var renderedHTML: String?
        private var allowsInitialDocumentNavigation = false

        func prepareToLoad(_ html: String) {
            renderedHTML = html
            allowsInitialDocumentNavigation = true
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let isInitialDocument = allowsInitialDocumentNavigation
                && HTMLPreviewContentPolicy.isInitialDocumentNavigation(
                    url: navigationAction.request.url,
                    isMainFrame: navigationAction.targetFrame?.isMainFrame == true
                )
            if isInitialDocument {
                allowsInitialDocumentNavigation = false
            }
            decisionHandler(isInitialDocument ? .allow : .cancel)
        }
    }
}

enum HTMLPreviewContentPolicy {
    static let maximumInputLength = 100_000

    static func limit(_ html: String) -> String {
        String(html.prefix(maximumInputLength))
    }

    static func isInitialDocumentNavigation(url: URL?, isMainFrame: Bool) -> Bool {
        isMainFrame && (url == nil || url?.scheme == "about")
    }

    static func document(containing html: String) -> String {
        """
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; img-src data:; style-src 'unsafe-inline';
                       font-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none';
                       connect-src 'none'; form-action 'none'; base-uri 'none'">
        <style>
        * { box-sizing: border-box; }
        body { background: transparent; color: rgba(255,255,255,0.75);
               font-family: -apple-system, sans-serif; font-size: 11px;
               margin: 0; padding: 0; word-break: break-word; }
        pre { background: rgba(255,255,255,0.08); border-radius: 4px;
              padding: 6px 8px; overflow-x: auto; margin: 4px 0; }
        code { font-family: monospace; font-size: 10px; }
        a { color: rgba(100,200,255,0.8); }
        </style></head><body>\(html)</body></html>
        """
    }
}

// MARK: - Session Row View

struct SessionRowView: View {
    let session: ActiveSession
    let isCurrent: Bool
    var isSubAgent: Bool = false
    var compact: Bool = false

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var appState = AppState.shared
    @State private var isRenaming: Bool = false
    @State private var renameText: String = ""
    @FocusState private var renameFocused: Bool
    private var tool: ToolInfo { toolInfo(for: session.lastToolName) }
    private var displayTitle: String {
        appState.sessionLabels[session.id] ?? session.terminalTitle
    }
    private var hasCustomLabel: Bool {
        appState.sessionLabels[session.id] != nil
    }
    private var sessionDescription: String? {
        let description = appState.sessionDescriptions[session.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return description?.isEmpty == false ? description : nil
    }

    /// Plugin-contributed context-menu actions for this session (e.g. host-validated
    /// session.dismiss). Read without observing `pluginHost`: the row must NOT re-render on
    /// every contributions change, or the per-second `notch.session.row` tick refresh would
    /// rebuild an open context menu and make its submenus flicker. The menu closure is
    /// evaluated when the menu opens, so it still reads the current cache then. Row badges
    /// observe `pluginHost` in their own child view (`SessionRowPluginBadges`) instead.
    private var contextMenuContributions: [PluginUIContribution] {
        AppState.shared.pluginHost.contributions[.sessionContextMenu]?
            .filter { $0.targetSessionID == session.id } ?? []
    }

    private struct AppBadge { let label: String; let color: Color }
    private func terminalAppBadge(_ app: String) -> AppBadge? {
        switch app {
        case "VSCode":        return AppBadge(label: "VS Code", color: Color(red: 0.0, green: 0.6, blue: 1.0))
        case "ClaudeDesktop": return AppBadge(label: "Claude",  color: Color(red: 0.8, green: 0.5, blue: 1.0))
        case "CodexDesktop":  return AppBadge(label: "Codex",   color: Color(red: 0.2, green: 0.6, blue: 0.9))
        default:              return nil
        }
    }

    private var resumeCommand: String { session.resumeCommand }

    private var autoTerminalName: String {
        TerminalFocuser.resolvedTerminalName(
            preferred: SettingsStore.shared.settings.preferredTerminal,
            sessionTerminal: session.workspaceRoot != nil ? session.terminal.app : nil
        ) ?? "?"
    }

    private func openInTerminal(appName: String? = nil) {
        let name = appName ?? autoTerminalName
        TerminalFocuser.openNewWindow(appName: name, command: resumeCommand)
    }

    private func openNewSession(provider: BuddyKind, appName: String? = nil) {
        let name = appName ?? autoTerminalName
        TerminalFocuser.openNewWindow(appName: name, command: session.newSessionCommand(for: provider))
    }
    private var statusLabel: String? {
        switch session.status {
        case .pending:       return l10n.statusPending
        case .timeoutBypassed: return l10n.statusBypassed
        case .autoApproved:  return l10n.statusAutoApproved
        case .policyApproved: return l10n.statusPolicyApproved
        case .policyDenied:  return l10n.statusPolicyDenied
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
        case .policyDenied:
            return Color(red: 1.0, green: 0.35, blue: 0.35)
        case .idle:
            return .white.opacity(0.3)
        }
    }

    private var badgeSize: CGFloat    { isSubAgent ? 24 : 32 }
    private var badgeFrame: CGFloat   { isSubAgent ? 28 : 36 }
    private var titleFont: CGFloat    { isSubAgent ? 10 : 12 }
    private var metaFont: CGFloat     { isSubAgent ? 8 : 9 }
    private var messageFont: CGFloat  { isSubAgent ? 9 : 10 }
    private var buttonSize: CGFloat   { isSubAgent ? 22 : 28 }
    private var vertPadding: CGFloat  { isSubAgent ? 6 : 10 }

    var body: some View {
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))

        return layout {
            if isSubAgent && !compact {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 2)
                    .padding(.leading, 8)
            }
            Button(action: { AppState.shared.showSessionDetail(session.id) }) {
                HStack(alignment: .top, spacing: isSubAgent ? 8 : 12) {
                    VStack(spacing: 3) {
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

                        if let appBadge = terminalAppBadge(session.terminal.app) {
                            Text(appBadge.label)
                                .font(.system(size: metaFont - 1, weight: .semibold))
                                .foregroundColor(appBadge.color)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(appBadge.color.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }

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

                            if isRenaming {
                                TextField("", text: $renameText)
                                    .font(.system(size: titleFont, weight: .bold))
                                    .foregroundColor(.white)
                                    .textFieldStyle(.plain)
                                    .focused($renameFocused)
                                    .padding(.horizontal, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.white.opacity(0.12))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                                            )
                                    )
                                    .onSubmit { commitRename() }
                                    .onExitCommand { isRenaming = false }
                                    .onAppear {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                            renameFocused = true
                                        }
                                    }
                            } else {
                                Text(displayTitle)
                                    .font(.system(size: titleFont, weight: (session.hasMissedApproval || session.isUnread) ? .heavy : .bold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                if hasCustomLabel {
                                    Image(systemName: "tag.fill")
                                        .font(.system(size: titleFont - 2))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                            }

                            Spacer()

                            if !isRenaming {
                                SessionRowTimeAgo(lastActiveAt: session.lastActiveAt, fontSize: metaFont - 1)
                            }
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

                        if !compact, !session.lastMessage.isEmpty {
                            Text(session.lastMessage)
                                .font(.system(size: messageFont, weight: .regular, design: .monospaced))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        if !compact, !isSubAgent, let root = session.workspaceRoot {
                            Text((root as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: metaFont, weight: .regular, design: .monospaced))
                                .foregroundColor(.white.opacity(0.25))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                SessionRowPluginBadges(sessionID: session.id)

                Button(action: { AppState.shared.focusTerminal(for: session.id) }) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: isSubAgent ? 10 : 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: buttonSize, height: buttonSize)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: isSubAgent ? 6 : 8))
                }
                .buttonStyle(.plain)
                .help(l10n.helpFocusTerminal)

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
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, vertPadding)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrent ? Color.white.opacity(0.1) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCurrent ? tool.color.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if isSubAgent && compact {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 2)
                    .padding(.leading, 8)
                    .padding(.vertical, 6)
            }
        }
        .help(sessionDescription ?? "")
        .contextMenu { sessionContextMenu }
    }

    @ViewBuilder
    private var sessionContextMenu: some View {
        Button {
            SessionMessageWindowManager.shared.openWindow(for: session.id)
        } label: {
            Label(l10n.popOutWindow, systemImage: "macwindow.on.rectangle")
        }

        Divider()

        Button {
            renameText = appState.sessionLabels[session.id] ?? ""
            isRenaming = true
        } label: {
            Label(l10n.menuRenameSession, systemImage: "pencil")
        }

        Button {
            AppState.shared.promptEditSessionDescription(
                session.id,
                currentDescription: appState.sessionDescriptions[session.id]
            )
        } label: {
            Label(l10n.menuEditSessionDescription, systemImage: "text.bubble")
        }

        Divider()

        if let path = session.workspaceRoot, !path.isEmpty {
            // "Open in Finder" is contributed by SessionActionsPlugin via the
            // session.openWorkspace host command (rendered below), so the core item was
            // removed to avoid a duplicate entry. Disabling the plugin removes this action.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: {
                Label(l10n.menuCopyPath, systemImage: "doc.on.clipboard")
            }

            Divider()
        }

        openInTerminalMenu

        if let root = session.workspaceRoot, !root.isEmpty {
            newSessionMenu
        }

        // "Copy Resume Command" is contributed by SessionActionsPlugin via the
        // session.copyResumeCommand host command (rendered below), so the core item was
        // removed to avoid a duplicate entry. Disabling the plugin removes this action.
        PluginSessionMenuItemsView(contributions: contextMenuContributions)
    }

    @ViewBuilder
    private var newSessionMenu: some View {
        let installed = TerminalFocuser.installedTerminals
        let auto = autoTerminalName
        Menu {
            ForEach(BuddyKind.defaultRandomCases) { provider in
                Menu {
                    Button { openNewSession(provider: provider) } label: {
                        Label(l10n.menuTerminalAuto(auto), systemImage: "terminal")
                    }
                    if !installed.isEmpty {
                        Divider()
                        ForEach(installed, id: \.name) { terminal in
                            Button { openNewSession(provider: provider, appName: terminal.name) } label: {
                                Label(terminal.name, systemImage: terminal.name == auto ? "checkmark" : "terminal")
                            }
                        }
                    }
                } label: {
                    Label(provider.label, systemImage: "terminal")
                }
            }
        } label: {
            Label(l10n.menuStartNewSession, systemImage: "plus.square.on.square")
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

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            appState.sessionLabels.removeValue(forKey: session.id)
        } else {
            appState.sessionLabels[session.id] = trimmed
        }
        isRenaming = false
    }

}

/// "N seconds/minutes ago" label in its own view so its per-second self-refresh re-renders
/// only this label — not the parent SessionRowView, whose `contextMenu` would otherwise
/// rebuild and make open submenus flicker. Same isolation rationale as SessionRowPluginBadges.
private struct SessionRowTimeAgo: View {
    let lastActiveAt: Date
    let fontSize: CGFloat
    @State private var timeAgo: String = ""
    private static let sharedTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(timeAgo)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(.white.opacity(0.3))
            .onAppear { update() }
            .onReceive(Self.sharedTimer) { _ in update() }
    }

    private func update() {
        let diff = Int(Date().timeIntervalSince(lastActiveAt))
        let l = L10n.shared
        if diff < 5 { timeAgo = l.timeJustNow() }
        else if diff < 60 { timeAgo = l.timeSecsAgo(diff) }
        else { timeAgo = l.timeMinsAgo(diff / 60) }
    }
}
