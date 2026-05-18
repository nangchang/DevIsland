import AppKit
import SwiftUI
import Combine

// MARK: - Mascot State

class MascotState: ObservableObject {
    static let shared = MascotState()

    @Published var leftMascot: BuddyKind = .claudeCode
    @Published var rightMascot: BuddyKind = .gemini

    func refresh(settings: AppSettings, forceRandomize: Bool = false) {
        leftMascot = resolvedMascot(
            current: forceRandomize ? nil : leftMascot,
            mode: settings.notchLeftCharacterMode,
            specific: settings.notchLeftCharacterKind,
            randomCandidates: settings.notchLeftRandomCharacterKinds
        )
        rightMascot = resolvedMascot(
            current: forceRandomize ? nil : rightMascot,
            mode: settings.notchRightCharacterMode,
            specific: settings.notchRightCharacterKind,
            randomCandidates: settings.notchRightRandomCharacterKinds
        )
    }

    private func resolvedMascot(
        current: BuddyKind?,
        mode: NotchCharacterMode,
        specific: BuddyKind,
        randomCandidates: Set<BuddyKind>
    ) -> BuddyKind {
        switch mode {
        case .hidden:
            return current ?? specific
        case .specific:
            return specific
        case .random:
            let candidates = randomCandidates.isEmpty ? Set(BuddyKind.defaultRandomCases) : randomCandidates
            if let current, candidates.contains(current) {
                return current
            }
            return candidates.randomElement() ?? .claudeCode
        }
    }
}

// MARK: - Notch View

struct NotchView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject private var sessionStore = AppState.shared.sessionStore
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var mascotState = MascotState.shared
    @State private var buddyPulse = false
    @State private var localIsExpanded = false

    var forceCollapsed: Bool = false
    private var isExpanded: Bool {
        forceCollapsed ? false : localIsExpanded
    }

    private var tool: ToolInfo { toolInfo(for: state.currentToolName) }
    private var isActionAreaShowing: Bool {
        sessionStore.pendingCount > 0 || (isExpanded && state.isExpandingFromRequest && !state.currentMessage.isEmpty)
    }
    private var headerTitle: String { isActionAreaShowing && !state.currentToolName.isEmpty ? tool.label : L10n.shared.notchSessions }
    private var displayedSessionId: String {
        state.currentSessionId.isEmpty ? (sessionStore.selectedSessionId ?? "") : state.currentSessionId
    }
    private var notchSize: NSSize {
        NotchLayout.size(expanded: isExpanded, settings: settingsStore.settings)
    }
    private var approvalLeftColumnHeight: CGFloat {
        notchSize.height - 80  // header paddingTop(20) + badge(48) + approvalContent paddingTop(12)
    }
    private var approvalPrimaryColumnWidth: CGFloat {
        if sessionStore.activeSessions.isEmpty {
            return max(0, notchSize.width - 12)
        }
        return max(420, min(notchSize.width * 0.68, notchSize.width - 220))
    }

    private var currentBuddyKind: BuddyKind {
        let session = sessionStore.activeSessions.first { $0.id == state.currentSessionId }
            ?? sessionStore.activeSessions.first { $0.id == sessionStore.selectedSessionId }
            ?? sessionStore.activeSessions.first
        return session?.agentKind ?? BuddyKind(from: "")
    }

    private var notchExpansionAnimation: Animation {
        let settings = settingsStore.settings
        return isExpanded
            ? Animation.spring(response: NotchLayout.expansionDuration(settings: settings), dampingFraction: 0.75)
            : Animation.easeOut(duration: NotchLayout.collapseDuration(settings: settings))
    }

    var body: some View {
        HStack {
            Spacer()

            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    notchBackground

                    VStack(alignment: .leading, spacing: 0) {
                        if isExpanded {
                            expandedContent
                                .transition(.opacity)
                        } else {
                            collapsedContent
                                .transition(.opacity)
                        }

                        if !isExpanded {
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(
                        width: notchSize.width,
                        height: notchSize.height,
                        alignment: .top
                    )
                }
            }
            .frame(
                width: notchSize.width,
                height: NotchLayout.windowSize(expanded: isExpanded, settings: settingsStore.settings).height,
                alignment: .top
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if !isExpanded {
                    (NSApp.windows.first { $0.windowController is NotchWindowController }?.windowController as? NotchWindowController)?.expandFromCollapsedWindow()
                }
            }
            .animation(notchExpansionAnimation, value: isExpanded)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                buddyPulse = true
            }
            if forceCollapsed {
                mascotState.refresh(settings: settingsStore.settings, forceRandomize: true)
            } else {
                localIsExpanded = false
                if state.isNotchExpanded {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        localIsExpanded = true
                    }
                }
            }

            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
        .onChange(of: state.isNotchExpanded) { _, newValue in
            if !forceCollapsed {
                if newValue {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        localIsExpanded = true
                    }
                } else {
                    localIsExpanded = false
                }
            }
        }
        .onReceive(settingsStore.$settings) { settings in
            if forceCollapsed {
                mascotState.refresh(settings: settings)
            }
        }
    }

    private var notchBackground: some View {
        let shape = NotchShape(
            cornerRadius: isExpanded ? 24 : 14,
            topFilletRadius: 6
        )

        return ZStack(alignment: .top) {
            if settingsStore.settings.notchBackdropShadowEnabled {
                shape
                    .fill(Color.black.opacity(isExpanded ? 0.32 : 0.28))
                    .offset(y: isExpanded ? 3 : 2)
                    .blur(radius: isExpanded ? 3 : 2)
                    .allowsHitTesting(false)

                shape
                    .fill(Color.black.opacity(isExpanded ? 0.16 : 0.14))
                    .offset(y: 1)
                    .blur(radius: 1)
                    .allowsHitTesting(false)
            }

            shape
                .fill(Color.black.opacity(settingsStore.settings.notchPanelOpacity))
        }
        .frame(
            width: notchSize.width,
            height: notchSize.height,
            alignment: .top
        )
    }

    // MARK: Collapsed

    var collapsedContent: some View {
        ZStack {
            Text("DevIsland")
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 11, weight: .semibold))

            if settingsStore.settings.notchLeftCharacterMode != .hidden {
                CLIBuddyView(
                    isActive: buddyPulse,
                    kind: mascotState.leftMascot
                )
                .frame(width: 24, height: 24)
                .position(x: characterHorizontalInset, y: characterCenterY)
            }

            if settingsStore.settings.notchRightCharacterMode != .hidden {
                CLIBuddyView(
                    isActive: buddyPulse,
                    kind: mascotState.rightMascot
                )
                .frame(width: 24, height: 24)
                .position(x: notchSize.width - characterHorizontalInset, y: characterCenterY)
            }
        }
        .frame(width: notchSize.width, height: notchSize.height)
    }

    private var characterHorizontalInset: CGFloat {
        max(12, min(notchSize.width / 2 - 12, settingsStore.settings.notchCharacterHorizontalInset))
    }

    private var characterCenterY: CGFloat {
        max(12, min(notchSize.height - 12, notchSize.height / 2 + settingsStore.settings.notchCharacterVerticalOffset))
    }

    // MARK: Expanded

    var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────
            HStack(spacing: 16) {
                AgentRequestBadge(
                    kind: currentBuddyKind,
                    tool: tool,
                    isActive: buddyPulse,
                    size: 48
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(headerTitle)
                            .font(.system(size: 18, weight: .black))
                            .foregroundColor(.white)

                        StatusBadge(
                            text: sessionStore.pendingCount > 0 ? l10n.notchApprovalRequired : (isActionAreaShowing ? l10n.notchNotification : l10n.notchMonitoring),
                            color: sessionStore.pendingCount > 0 ? .orange : (isActionAreaShowing ? .blue.opacity(0.7) : .green.opacity(0.6))
                        )
                    }

                    if !displayedSessionId.isEmpty {
                        HStack(spacing: 6) {
                            TagView(icon: "terminal.fill", text: String(displayedSessionId.prefix(8)))
                            TagView(icon: "macwindow", text: sessionStore.activeSessions.first(where: { $0.id == displayedSessionId })?.terminalTitle ?? l10n.notchUnknown)
                            if sessionStore.pendingCount > 1 {
                                TagView(icon: "list.bullet", text: l10n.tasksQueued(sessionStore.pendingCount), color: .orange.opacity(0.2))
                            }
                        }
                    } else if sessionStore.pendingCount > 1 {
                        HStack(spacing: 6) {
                            TagView(icon: "list.bullet", text: l10n.tasksQueued(sessionStore.pendingCount), color: .orange.opacity(0.2))
                        }
                    }
                }

                Spacer()

                Button {
                    AppWindowRouter.showSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(l10n.helpOpenSettings)

                if !displayedSessionId.isEmpty {
                    Button {
                        state.focusTerminal(for: displayedSessionId)
                    } label: {
                        Image(systemName: "arrow.up.forward.app.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(l10n.helpFocusTerminal)
                }

                // Close Button
                Button {
                    state.dismissCurrentRequest()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(l10n.notchDismiss)
            }
            .padding(.horizontal, 30)
            .padding(.top, 20)

            // ── Main Dashboard ──────────────────────────
            if isActionAreaShowing {
                approvalContent
            } else {
                sessionsContent
            }
        }
    }

    // MARK: Approval Content

    private var approvalContent: some View {
        HStack(alignment: .top, spacing: 0) {
            // LEFT: Focus Area
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(state.hasResponseHandler ? l10n.notchActiveAction : l10n.notchNotification.uppercased())
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(.white.opacity(0.3))

                        if !state.currentToolName.isEmpty {
                            let risk = ToolKnowledge.risk(for: state.currentToolName)
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
                        Text(state.currentEventName)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(tool.color)
                    }
                    .padding(.horizontal, 20)

                    ScrollView {
                        Text(state.currentMessage)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 12) {
                    if state.hasResponseHandler {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.07))
                                Capsule()
                                    .fill(
                                        LinearGradient(colors: [progressColor.opacity(0.8), progressColor], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .frame(width: geo.size.width * state.timeoutProgress)
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 20)
                    }

                    HStack(spacing: 12) {
                        if state.hasResponseHandler {
                            Button(action: { state.focusTerminal() }) {
                                HStack {
                                    Image(systemName: "arrow.up.forward.app.fill")
                                    Text(l10n.notchFocus)
                                }
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 92, height: 38)
                                .background(Color.white.opacity(0.08))
                                .foregroundColor(.white.opacity(0.82))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .help(l10n.helpFocusTerminal)

                            Button(action: { state.deny() }) {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                    Text(l10n.notchDenyRequest)
                                }
                                .font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)

                            HStack(spacing: 1) {
                                Button(action: { state.approve() }) {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text(l10n.notchApprove)
                                    }
                                    .font(.system(size: 13, weight: .bold))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(tool.color.opacity(0.15))
                                    .foregroundColor(tool.color)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                // [UI/UX] macOS 기본 Menu 스타일 버그 우회용 ZStack 트릭
                                // macOS의 borderlessButton Menu는 커스텀 배경색(.background)을 무시하거나 클리핑하는 버그가 있습니다.
                                // 이를 해결하기 위해 배경색과 아이콘을 먼저 렌더링하고, 실제 기능하는 Menu를 그 위에 겹쳐(오버레이) 구현합니다.
                                ZStack {
                                    tool.color.opacity(0.2)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(tool.color)

                                    Menu {
                                        Button(l10n.notchAutoApproveSession) { state.approve(globalAlways: false, sessionAlways: true) }
                                        Button(l10n.notchAlwaysAutoApprove) { state.approve(globalAlways: true, sessionAlways: false) }
                                    } label: {
                                        // Text("")를 사용하면 크기가 0x0이 되어 클릭 히트 박스가 생성되지 않습니다.
                                        // 눈에 보이지 않지만 프레임을 꽉 채우는 투명한 도형으로 빈 껍데기를 만들어 클릭 이벤트를 낚아챕니다.
                                        Color.black.opacity(0.001)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .contentShape(Rectangle())
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .frame(width: 32, height: 38)
                            }
                            .frame(height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            Button(action: { state.focusTerminal() }) {
                                HStack {
                                    Image(systemName: "arrow.up.forward.app.fill")
                                    Text(l10n.notchFocusTerminal)
                                }
                                .font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(Color.white.opacity(0.08))
                                .foregroundColor(.white.opacity(0.82))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .help(l10n.helpFocusTerminal)

                            Button(action: { state.isNotchExpanded = false }) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text(l10n.notchDismiss)
                                }
                                .font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 20)
            }
            .frame(width: approvalPrimaryColumnWidth, height: approvalLeftColumnHeight)

            if !sessionStore.activeSessions.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
                    .padding(.vertical, 20)

                sessionList
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 12)
    }

    // MARK: Sessions Content

    private var sessionsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.notchAgentSessions)
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.white.opacity(0.3))
                .padding(.horizontal, 20)

            if sessionStore.activeSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.1))
                    Text(l10n.notchListening)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.2))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sessionList
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    // MARK: Session List

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(sessionStore.activeSessions) { session in
                    SessionRowView(
                        session: session,
                        isCurrent: session.id == displayedSessionId
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
    }

    private var progressColor: Color {
        if state.timeoutProgress > 0.5  { return .green }
        if state.timeoutProgress > 0.25 { return .orange }
        return .red
    }
}
