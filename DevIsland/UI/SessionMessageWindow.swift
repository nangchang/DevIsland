import AppKit
import SwiftUI
import Combine

// MARK: - Session History ViewModel

@MainActor
final class SessionMessageHistoryViewModel: ObservableObject {
    @Published private(set) var entries: [ReplayLogEntry] = []  // 오래된 것부터 — [0]=oldest, [last]=newest
    @Published var currentIndex: Int = 0

    let sessionId: String

    init(sessionId: String) {
        self.sessionId = sessionId
        load()
    }

    var count: Int { entries.count }
    var currentEntry: ReplayLogEntry? { entries.isEmpty ? nil : entries[currentIndex] }

    /// 최신 항목(라이브 뷰)에 있는 상태
    var isAtLatest: Bool { entries.isEmpty || currentIndex == entries.count - 1 }
    var hasPrevious: Bool { currentIndex > 0 }
    var hasNext: Bool { currentIndex < entries.count - 1 }

    /// 1-based 위치 표시용 (예: "3 / 12")
    var positionLabel: String { entries.isEmpty ? "" : "\(currentIndex + 1) / \(entries.count)" }

    func goToPrevious() { if hasPrevious { currentIndex -= 1 } }
    func goToNext()     { if hasNext     { currentIndex += 1 } }
    func goToLatest()   { currentIndex = max(0, entries.count - 1) }

    func load() {
        // DB I/O를 백그라운드에서 처리하여 메인 스레드 블로킹 방지
        let sid = sessionId
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                (try? AppState.shared.sessionMessageHistory(sessionId: sid, limit: 100)) ?? []
            }.value
            self.entries = loaded.reversed()  // DESC → ASC (오래된 것부터)
            self.currentIndex = max(0, self.entries.count - 1)
        }
    }

    /// 새 이벤트 도착 시 최신 항목 유지하며 갱신
    func refresh() {
        let wasAtLatest = isAtLatest
        let prevId = currentEntry?.id
        let sid = sessionId
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                (try? AppState.shared.sessionMessageHistory(sessionId: sid, limit: 100)) ?? []
            }.value
            self.entries = loaded.reversed()
            if wasAtLatest || prevId == nil {
                self.goToLatest()
            } else if let prevId, let idx = self.entries.firstIndex(where: { $0.id == prevId }) {
                self.currentIndex = idx
            } else {
                self.goToLatest()
            }
        }
    }

    /// payloadJSON에서 표시 메시지 추출
    func displayMessage(for entry: ReplayLogEntry) -> String {
        guard
            let data = entry.payloadJSON.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "" }
        let toolInput = json["tool_input"] as? [String: Any]
        let msg = ToolMessageFormatter.displayMessage(
            for: entry.toolName,
            toolInput: toolInput,
            json: json,
            eventName: entry.eventName
        )
        return msg
    }
}

// MARK: - Manager

@MainActor
final class SessionMessageWindowManager {
    static let shared = SessionMessageWindowManager()

    private var controllers: [String: SessionMessageWindowController] = [:]

    func openWindow(for sessionId: String) {
        if let existing = controllers[sessionId] {
            existing.show()
        } else {
            let controller = SessionMessageWindowController(sessionId: sessionId)
            controllers[sessionId] = controller
            controller.show()
        }
        // 팝아웃 창으로 분리 시 노치 닫기
        AppState.shared.isNotchExpanded = false
    }

    func closeWindow(for sessionId: String) {
        controllers[sessionId]?.close()
        controllers.removeValue(forKey: sessionId)
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame SessionMessageWindow-\(sessionId)")
    }

    func hasWindow(for sessionId: String) -> Bool {
        controllers[sessionId] != nil
    }

    func windowClosed(for sessionId: String) {
        controllers.removeValue(forKey: sessionId)
        // P2: 팝아웃 창이 승인 대기 중 닫히면 노치에서 요청을 다시 표시
        let state = AppState.shared
        if state.currentSessionId == sessionId && state.hasResponseHandler {
            state.isExpandingFromRequest = true
            state.isNotchExpanded = true
        }
    }

    func updateTitle(for sessionId: String, title: String) {
        controllers[sessionId]?.window?.title = title
    }

    func closeAll() {
        controllers.values.forEach { $0.close() }
        controllers.removeAll()
    }
}

// MARK: - Window Controller

@MainActor
final class SessionMessageWindowController: NSWindowController, NSWindowDelegate {
    let sessionId: String

    init(sessionId: String) {
        self.sessionId = sessionId

        let session = AppState.shared.sessionStore.activeSessions.first { $0.id == sessionId }
        let title = AppState.shared.sessionLabels[sessionId]
            ?? session?.terminalTitle
            ?? String(sessionId.prefix(8))

        // HostedWindowController 패턴과 동일: NSHostingController → NSWindow(contentViewController:)
        let hostingController = NSHostingController(rootView: SessionMessageView(sessionId: sessionId))
        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.setContentSize(NSSize(width: 460, height: 380))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 260)

        super.init(window: window)
        window.delegate = self

        // 세션별 고유 autosaveName — 여러 창 동시 오픈 시 각각 독립적으로 저장·복원
        let autosaveName = "SessionMessageWindow-\(sessionId)"
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") == nil {
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // DispatchQueue.main.async: 현재 AppKit 런루프 사이클 완료 후 컨트롤러 참조 제거
        // → windowWillClose 콜백 실행 도중 self 해제로 인한 크래시 방지
        let sid = sessionId
        DispatchQueue.main.async {
            SessionMessageWindowManager.shared.windowClosed(for: sid)
        }
    }
}

// MARK: - View

struct SessionMessageView: View {
    let sessionId: String

    @ObservedObject private var sessionStore = AppState.shared.sessionStore
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var l10n = L10n.shared
    @StateObject private var history: SessionMessageHistoryViewModel

    init(sessionId: String) {
        self.sessionId = sessionId
        _history = StateObject(wrappedValue: SessionMessageHistoryViewModel(sessionId: sessionId))
    }

    private var session: ActiveSession? {
        sessionStore.activeSessions.first { $0.id == sessionId }
    }

    private var isCurrentSession: Bool {
        appState.currentSessionId == sessionId
    }

    /// 히스토리 뷰일 때는 해당 항목의 툴/이벤트, 라이브 뷰일 때는 현재 상태
    private var activeToolName: String {
        if !history.isAtLatest, let entry = history.currentEntry { return entry.toolName }
        if let last = session?.lastToolName, !last.isEmpty { return last }
        return isCurrentSession ? appState.currentToolName : ""
    }

    private var activeEventName: String {
        if !history.isAtLatest, let entry = history.currentEntry { return entry.eventName }
        if let last = session?.lastEventName, !last.isEmpty { return last }
        return isCurrentSession ? appState.currentEventName : ""
    }

    private var displayMessage: String {
        if !history.isAtLatest, let entry = history.currentEntry {
            return history.displayMessage(for: entry)
        }
        if let last = session?.lastMessage, !last.isEmpty { return last }
        return isCurrentSession ? appState.currentMessage : ""
    }

    private var tool: ToolInfo { toolInfo(for: activeToolName) }

    /// 커스텀 라벨 → 터미널 타이틀 → 세션 ID 접두사 순으로 결정되는 표시 이름
    private var displayTitle: String {
        appState.sessionLabels[sessionId]
            ?? session?.terminalTitle
            ?? String(sessionId.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().background(Color.white.opacity(0.1))

            if let session {
                contentArea(session: session)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.2))
                    Text(l10n.sessionEnded)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: NSColor(white: 0.07, alpha: 1.0)))
        // displayTitle을 관찰하여 커스텀 라벨과 터미널 타이틀 변경 모두에 반응
        .onChange(of: displayTitle) { _, newTitle in
            SessionMessageWindowManager.shared.updateTitle(for: sessionId, title: newTitle)
        }
        // 새 이벤트 도착 시 히스토리 갱신 (최신 뷰에 있을 때만)
        .onChange(of: session?.lastActiveAt) { _, _ in
            history.refresh()
        }
        .onAppear {
            history.load()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            if let session {
                AgentRequestBadge(
                    kind: session.agentKind,
                    tool: tool,
                    isActive: session.isPending,
                    size: 30
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let session, session.isPending {
                        StatusBadge(text: "PENDING", color: .orange)
                    }
                }
                Text(String(sessionId.prefix(8)))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer()

            Button {
                appState.focusTerminal(for: sessionId)
            } label: {
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(l10n.helpFocusTerminal)
        }
        .padding(.horizontal, 16)
        .padding(.top, 36)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private func contentArea(session: ActiveSession) -> some View {
        VStack(spacing: 0) {
            if !activeEventName.isEmpty || !activeToolName.isEmpty {
                HStack(spacing: 8) {
                    Text((isCurrentSession && appState.hasResponseHandler) ? "ACTIVE ACTION" : "NOTIFICATION")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(.white.opacity(0.3))

                    if !activeToolName.isEmpty {
                        let risk = ToolKnowledge.risk(for: activeToolName)
                        HStack(spacing: 4) {
                            Image(systemName: risk.icon)
                            Text(risk.rawValue.uppercased())
                        }
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(risk.color.opacity(0.2))
                        .foregroundColor(risk.color)
                        .clipShape(Capsule())
                    }

                    Spacer()

                    Text(activeEventName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(tool.color)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            ScrollView {
                if isCurrentSession, let question = appState.currentClaudeQuestion {
                    ClaudeQuestionFormView(request: question, state: appState)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else if !displayMessage.isEmpty {
                    DiffAwareMarkdownView(text: displayMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    Text(l10n.msgWaiting)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxHeight: .infinity)
            .overlay {
                if isCurrentSession {
                    MessageMouseDownMonitor {
                        appState.pauseAutoTimersForUserViewing()
                    }
                    .allowsHitTesting(false)
                }
            }

            // 히스토리 내비게이션 바
            if history.count > 1 {
                historyNavigationBar
            }

            if history.isAtLatest &&
               isCurrentSession && (appState.hasResponseHandler || appState.isNotificationAutoCollapseActive) {
                actionArea
            } else if history.isAtLatest && session.isPending && !isCurrentSession {
                HStack {
                    Image(systemName: "hourglass")
                        .font(.system(size: 11))
                        .foregroundColor(.orange.opacity(0.7))
                    Text(l10n.approvingOtherSession)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - History Navigation Bar

    private var historyNavigationBar: some View {
        HStack(spacing: 12) {
            Button {
                history.goToPrevious()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 24)
                    .background(Color.white.opacity(history.hasPrevious ? 0.08 : 0.03))
                    .foregroundColor(.white.opacity(history.hasPrevious ? 0.8 : 0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!history.hasPrevious)

            Spacer()

            if let entry = history.currentEntry {
                VStack(spacing: 1) {
                    Text(history.positionLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                    Text(entry.receivedAt, style: .relative)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            Spacer()

            Button {
                if history.hasNext {
                    history.goToNext()
                }
            } label: {
                Image(systemName: history.isAtLatest ? "arrow.clockwise" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 24)
                    .background(Color.white.opacity(history.hasNext ? 0.08 : 0.03))
                    .foregroundColor(.white.opacity(history.hasNext ? 0.8 : 0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!history.hasNext)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Action Area

    @ViewBuilder
    private var actionArea: some View {
        VStack(spacing: 8) {
            if appState.hasResponseHandler || appState.isNotificationAutoCollapseActive {
                GeometryReader { geo in
                    let progress = appState.hasResponseHandler
                        ? appState.timeoutProgress
                        : appState.notificationAutoCollapseProgress
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [progressColor(for: progress).opacity(0.8), progressColor(for: progress)],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 16)
            }

            HStack(spacing: 10) {
                if appState.hasResponseHandler {
                    Button(action: { appState.focusTerminal() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.app.fill")
                            Text(l10n.notchFocus)
                        }
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 80, height: 34)
                        .background(Color.white.opacity(0.08))
                        .foregroundColor(.white.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(l10n.helpFocusTerminal)

                    Button(action: { appState.deny() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                            Text(l10n.notchDenyRequest)
                        }
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    // [UI/UX] 노치뷰와 동일한 ZStack 트릭으로 macOS Menu 배경색 버그 우회
                    HStack(spacing: 1) {
                        Button(action: {
                            if appState.currentClaudeQuestion != nil {
                                appState.submitClaudeQuestion()
                            } else {
                                appState.approve()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                Text(appState.currentClaudeQuestion == nil ? l10n.notchApprove : "Submit")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(tool.color.opacity(0.15))
                            .foregroundColor(
                                appState.currentClaudeQuestion == nil || appState.canSubmitClaudeQuestion()
                                    ? tool.color : .white.opacity(0.35)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.currentClaudeQuestion != nil && !appState.canSubmitClaudeQuestion())

                        if appState.currentClaudeQuestion == nil {
                            ZStack {
                                tool.color.opacity(0.2)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(tool.color)

                                Menu {
                                    Button(l10n.notchAutoApproveSession) {
                                        appState.approve(globalAlways: false, sessionAlways: true)
                                    }
                                    Button(l10n.notchAlwaysAutoApprove) {
                                        appState.approve(globalAlways: true, sessionAlways: false)
                                    }
                                } label: {
                                    Color.black.opacity(0.001)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .contentShape(Rectangle())
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .frame(width: 28, height: 34)
                        }
                    }
                    .frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Button(action: { appState.dismissCurrentRequest() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(l10n.notchDismiss)
                        }
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.02))
    }

    private func progressColor(for progress: Double) -> Color {
        if progress > 0.5  { return .green }
        if progress > 0.25 { return .orange }
        return .red
    }
}
