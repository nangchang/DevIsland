import AppKit
import SwiftUI
import Combine

// MARK: - Collapsed View (dedicated collapsed window)

struct NotchCollapsedView: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var sessionStore = AppState.shared.sessionStore
    @State private var buddyPulse = false
    @State private var notifPulse = false

    private var notchSize: NSSize {
        NotchLayout.collapsedSize(settings: settingsStore.settings)
    }

    private var hasDotIndicator: Bool {
        sessionStore.pendingCount > 0 || sessionStore.activeSessions.contains { $0.isUnread }
    }

    private var unreadDotX: CGFloat {
        switch settingsStore.settings.notchUnreadDotPosition {
        case .left:   return 18
        case .center: return notchSize.width / 2
        case .right:  return notchSize.width - 18
        }
    }

    private var sideRegionWidth: CGFloat {
        min(64, characterHorizontalInset * 2)
    }

    private var centerRegionWidth: CGFloat {
        max(0, notchSize.width - sideRegionWidth * 2)
    }

    var body: some View {
        HStack {
            Spacer()

            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    collapsedBackground

                    ZStack {
                        CompactNotchRegionView(
                            region: .notchCompactCenter,
                            buddyPulse: buddyPulse
                        )
                        .frame(width: centerRegionWidth)
                        .position(x: notchSize.width / 2, y: notchSize.height / 2)

                        CompactNotchRegionView(
                            region: .notchCompactLeading,
                            buddyPulse: buddyPulse
                        )
                            .frame(width: sideRegionWidth, height: 24)
                            .position(x: characterHorizontalInset, y: characterCenterY)

                        CompactNotchRegionView(
                            region: .notchCompactTrailing,
                            buddyPulse: buddyPulse
                        )
                            .frame(width: sideRegionWidth, height: 24)
                            .position(x: notchSize.width - characterHorizontalInset, y: characterCenterY)

                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(notifPulse ? 0.0 : 0.65))
                                .frame(width: notifPulse ? 22 : 7, height: notifPulse ? 22 : 7)
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 7, height: 7)
                                .shadow(color: .orange, radius: 3)
                        }
                        .position(x: unreadDotX, y: notchSize.height - 6)
                        .opacity(hasDotIndicator ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: hasDotIndicator)
                    }
                    .frame(width: notchSize.width, height: notchSize.height)
                }
                .offset(y: settingsStore.settings.notchShapeStyle == .dynamicIsland ? 3 : 0)
            }
            .frame(
                width: notchSize.width,
                height: NotchLayout.windowSize(expanded: false, settings: settingsStore.settings).height,
                alignment: .top
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                buddyPulse = true
            }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                notifPulse = true
            }
            AppState.shared.pluginHost.setVisibleCompactRegions(
                Set(PluginRegionID.allCases),
                source: "notch.compact"
            )
            AppState.shared.pluginHost.compactRegionSelectionChanged()
            AppState.shared.pluginHost.compactRegionsBecameVisible()
        }
        .onDisappear {
            AppState.shared.pluginHost.setVisibleCompactRegions([], source: "notch.compact")
        }
        .onReceive(settingsStore.$settings) { _ in
            AppState.shared.pluginHost.compactRegionSelectionChanged()
        }
    }

    private var collapsedBackground: some View {
        let style = settingsStore.settings.notchShapeStyle
        let (cr, tr): (CGFloat, CGFloat) = style == .dynamicIsland
            ? (notchSize.height / 2, 0)
            : (14, 6)
        let shape = NotchShape(cornerRadius: cr, topFilletRadius: tr, shapeStyle: style)

        return ZStack(alignment: .top) {
            if settingsStore.settings.notchBackdropShadowEnabled {
                shape
                    .fill(Color.black.opacity(0.28))
                    .offset(y: 2)
                    .blur(radius: 2)
                    .allowsHitTesting(false)

                shape
                    .fill(Color.black.opacity(0.14))
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

    private var characterHorizontalInset: CGFloat {
        max(12, min(notchSize.width / 2 - 12, settingsStore.settings.notchCharacterHorizontalInset))
    }

    private var characterCenterY: CGFloat {
        max(12, min(notchSize.height - 12, notchSize.height / 2 + settingsStore.settings.notchCharacterVerticalOffset))
    }
}

// MARK: - Notch View (expanded window only)

struct NotchView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject private var sessionStore = AppState.shared.sessionStore
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var buddyPulse = false
    @State private var isExpanded = false
    @State private var liveHeight: Double? = nil
    @State private var liveWidth: Double? = nil

    private var tool: ToolInfo { toolInfo(for: state.currentToolName) }
    private var isActionAreaShowing: Bool {
        sessionStore.pendingCount > 0 || (isExpanded && state.isExpandingFromRequest && !state.currentMessage.isEmpty)
    }
    private var headerTitle: String { isActionAreaShowing && !state.currentToolName.isEmpty ? tool.label : L10n.shared.notchSessions }
    private var displayedSessionId: String {
        state.currentSessionId.isEmpty ? (sessionStore.selectedSessionId ?? "") : state.currentSessionId
    }
    private var notchSize: NSSize {
        guard isExpanded else {
            return NotchLayout.collapsedSize(settings: settingsStore.settings)
        }
        return NSSize(
            width: liveWidth ?? settingsStore.settings.expandedNotchWidth,
            height: liveHeight ?? settingsStore.settings.expandedNotchHeight
        )
    }
    private var approvalLeftColumnHeight: CGFloat {
        notchSize.height - 80
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

    private var notchExpansionAnimation: Animation? {
        let settings = settingsStore.settings
        guard settings.notchAnimationEnabled else { return nil }
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

                    ZStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            if isExpanded {
                                expandedContent
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

                        if isExpanded {
                            ResizeHandle(liveHeight: $liveHeight)
                                .frame(width: notchSize.width, height: 12)
                                .padding(.trailing, 20)
                                .transition(.opacity)
                        }
                    }
                    .frame(
                        width: notchSize.width,
                        height: notchSize.height,
                        alignment: .top
                    )
                    .overlay(alignment: .trailing) {
                        if isExpanded {
                            RightResizeHandle(liveWidth: $liveWidth)
                                .frame(width: 12, height: notchSize.height)
                                .padding(.bottom, 20)
                                .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isExpanded {
                            CornerResizeHandle(liveHeight: $liveHeight, liveWidth: $liveWidth)
                                .frame(width: 20, height: 20)
                                // 패널 r=24 모서리에 맞춰 클리핑: 원 중심 (-4,-4), r=24
                                .clipShape(Path { p in
                                    p.move(to: CGPoint(x: 20, y: 0))
                                    p.addArc(center: CGPoint(x: -4, y: -4), radius: 24,
                                             startAngle: .degrees(0), endAngle: .degrees(90),
                                             clockwise: true)
                                    p.addLine(to: CGPoint(x: 0, y: 0))
                                    p.closeSubpath()
                                })
                                .transition(.opacity)
                        }
                    }
                }
                .offset(y: settingsStore.settings.notchShapeStyle == .dynamicIsland ? 3 : 0)
            }
            .frame(
                width: notchSize.width,
                height: notchSize.height + NotchLayout.shadowOutset(expanded: isExpanded, settings: settingsStore.settings),
                alignment: .top
            )
            .animation(notchExpansionAnimation, value: isExpanded)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                buddyPulse = true
            }
            isExpanded = false
            if state.isNotchExpanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isExpanded = true
                }
            }
        }
        .onChange(of: state.isNotchExpanded) { _, newValue in
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isExpanded = true
                }
            } else {
                isExpanded = false
            }
        }
    }

    private var notchBackground: some View {
        let style = settingsStore.settings.notchShapeStyle
        let (collapsedCR, tr): (CGFloat, CGFloat) = style == .dynamicIsland
            ? (CGFloat(settingsStore.settings.collapsedNotchHeight) / 2, 0)
            : (14, 6)
        let shape = NotchShape(
            cornerRadius: isExpanded ? 24 : collapsedCR,
            topFilletRadius: tr,
            shapeStyle: style
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
                        SessionMessageWindowManager.shared.openWindow(for: displayedSessionId)
                    } label: {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(l10n.popOutWindow)

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
                        if let question = state.currentClaudeQuestion {
                            ClaudeQuestionFormView(request: question, state: state)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                        } else {
                            DiffAwareMarkdownView(text: state.currentMessage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                        }
                    }
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)
                    .overlay {
                        MessageMouseDownMonitor {
                            state.pauseAutoTimersForUserViewing()
                        }
                        .allowsHitTesting(false)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 12) {
                    if state.hasResponseHandler || state.isNotificationAutoCollapseActive {
                        GeometryReader { geo in
                            let progress = state.hasResponseHandler ? state.timeoutProgress : state.notificationAutoCollapseProgress
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.07))
                                Capsule()
                                    .fill(
                                        LinearGradient(colors: [progressColor(for: progress).opacity(0.8), progressColor(for: progress)], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 20)
                    }

                    if let suggestedTool = state.alwaysAllowSuggestion, state.hasResponseHandler, state.currentClaudeQuestion == nil {
                        Button(action: { state.approve(globalAlways: true) }) {
                            HStack(spacing: 6) {
                                Image(systemName: "wand.and.stars")
                                Text(l10n.notchAlwaysAllowSuggestion)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(Color.yellow.opacity(0.12))
                            .foregroundColor(.yellow)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .help(l10n.notchAlwaysAllowSuggestionHelp(suggestedTool))
                        .padding(.horizontal, 12)
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
                                Button(action: {
                                    if state.currentClaudeQuestion != nil {
                                        state.submitClaudeQuestion()
                                    } else {
                                        state.approve()
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text(state.currentClaudeQuestion == nil ? l10n.notchApprove : "Submit")
                                    }
                                    .font(.system(size: 13, weight: .bold))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(tool.color.opacity(0.15))
                                    .foregroundColor(state.currentClaudeQuestion == nil || state.canSubmitClaudeQuestion() ? tool.color : .white.opacity(0.35))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(state.currentClaudeQuestion != nil && !state.canSubmitClaudeQuestion())

                                // [UI/UX] macOS 기본 Menu 스타일 버그 우회용 ZStack 트릭
                                // macOS의 borderlessButton Menu는 커스텀 배경색(.background)을 무시하거나 클리핑하는 버그가 있습니다.
                                // 이를 해결하기 위해 배경색과 아이콘을 먼저 렌더링하고, 실제 기능하는 Menu를 그 위에 겹쳐(오버레이) 구현합니다.
                                if state.currentClaudeQuestion == nil {
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

                            Button(action: { state.dismissCurrentRequest() }) {
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
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .frame(width: approvalPrimaryColumnWidth, height: approvalLeftColumnHeight)

            if !sessionStore.activeSessions.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
                    .padding(.vertical, 20)

                sessionList(compact: true)
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

            NotchActivityContributionsView()

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
                sessionList(compact: false)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    // MARK: Session List

    private var groupedSessions: [(session: ActiveSession, isSubAgent: Bool)] {
        let all = sessionStore.activeSessions
        guard !all.isEmpty else { return [] }

        var childrenByParent: [String: [ActiveSession]] = [:]
        var parents: [ActiveSession] = []
        for session in all {
            if let pid = session.parentSessionId {
                childrenByParent[pid, default: []].append(session)
            } else {
                parents.append(session)
            }
        }

        var result: [(ActiveSession, Bool)] = []
        var accountedIds = Set<String>()
        for parent in parents {
            result.append((parent, false))
            accountedIds.insert(parent.id)
            for child in childrenByParent[parent.id] ?? [] {
                result.append((child, true))
                accountedIds.insert(child.id)
            }
        }
        // Orphaned sub-agents (parent already removed from list)
        for session in all where !accountedIds.contains(session.id) {
            result.append((session, session.parentSessionId != nil))
        }
        return result
    }

    private func sessionList(compact: Bool) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(groupedSessions, id: \.session.id) { item in
                    SessionRowView(
                        session: item.session,
                        isCurrent: item.session.id == displayedSessionId,
                        isSubAgent: item.isSubAgent,
                        compact: compact
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
    }

    private func progressColor(for progress: Double) -> Color {
        if progress > 0.5  { return .green }
        if progress > 0.25 { return .orange }
        return .red
    }
}

struct MessageMouseDownMonitor: NSViewRepresentable {
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> MouseDownMonitorView {
        let view = MouseDownMonitorView()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ nsView: MouseDownMonitorView, context: Context) {
        nsView.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ nsView: MouseDownMonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }
}

final class MouseDownMonitorView: NSView {
    var onMouseDown: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitorIfNeeded()
        }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) {
                self.onMouseDown?()
            }
            return event
        }
    }

    deinit {
        removeMonitor()
    }
}

// MARK: - Resize Handle (NSView-backed, 스크린 절대좌표 사용으로 창 이동에 의한 lag 제거)

private struct ResizeHandle: NSViewRepresentable {
    @Binding var liveHeight: Double?

    func makeNSView(context: Context) -> ResizeHandleNSView {
        ResizeHandleNSView(axis: .vertical, liveValue: $liveHeight)
    }
    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        nsView.liveValue = $liveHeight
    }
}

private struct RightResizeHandle: NSViewRepresentable {
    @Binding var liveWidth: Double?

    func makeNSView(context: Context) -> ResizeHandleNSView {
        ResizeHandleNSView(axis: .horizontal, liveValue: $liveWidth)
    }
    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        nsView.liveValue = $liveWidth
    }
}

// MARK: - ResizeHandleNSView

final class ResizeHandleNSView: NSView {
    enum Axis { case vertical, horizontal }

    var liveValue: Binding<Double?>

    private let axis: Axis
    private var isTracking = false
    private var dragStartValue: Double = 0
    private var startScreenPos: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    private var minValue: Double { axis == .vertical ? 240 : 610 }
    private var maxValue: Double { axis == .vertical ? 720 : 1200 }

    init(axis: Axis, liveValue: Binding<Double?>) {
        self.axis = axis
        self.liveValue = liveValue
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        axis == .vertical
            ? NSSize(width: NSView.noIntrinsicMetric, height: 12)
            : NSSize(width: 12, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.2).setFill()
        let (w, h): (CGFloat, CGFloat) = axis == .vertical ? (36, 4) : (4, 36)
        let rect = NSRect(
            x: (bounds.width - w) / 2,
            y: (bounds.height - h) / 2,
            width: w, height: h
        )
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea.map { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        (axis == .vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
    }
    override func mouseExited(with event: NSEvent) {
        if !isTracking { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        let settings = SettingsStore.shared.settings
        dragStartValue = axis == .vertical ? settings.expandedNotchHeight : settings.expandedNotchWidth
        startScreenPos = axis == .vertical ? NSEvent.mouseLocation.y : NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        let currentPos = axis == .vertical ? NSEvent.mouseLocation.y : NSEvent.mouseLocation.x
        let delta = currentPos - startScreenPos
        let settings = SettingsStore.shared.settings

        let clamped: Double
        let size: NSSize
        if axis == .vertical {
            // 아래로 드래그 = y 감소 = delta 음수 → 높이 증가
            clamped = min(max(dragStartValue - delta, minValue), maxValue)
            size = NSSize(width: settings.expandedNotchWidth, height: clamped)
        } else {
            // 오른쪽으로 드래그 = x 증가 = delta 양수 → 패널 중앙 고정이므로 ×2
            clamped = min(max(dragStartValue + delta * 2, minValue), maxValue)
            size = NSSize(width: clamped, height: settings.expandedNotchHeight)
        }
        liveValue.wrappedValue = clamped
        NotchWindowController.current?.updateLiveExpandedFrame(size: size)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        if let final = liveValue.wrappedValue {
            if axis == .vertical {
                SettingsStore.shared.settings.expandedNotchHeight = final
            } else {
                SettingsStore.shared.settings.expandedNotchWidth = final
            }
        }
        liveValue.wrappedValue = nil
        NSCursor.arrow.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - NSCursor helpers

private extension NSCursor {
    /// macOS 창 우하단 모서리 리사이즈 커서 (↖↘). 공개 API 부재로 private selector 사용, 실패 시 crosshair 폴백.
    static var resizeNorthWestSouthEast: NSCursor {
        let sel = NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
        return (NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor) ?? .crosshair
    }
}

// MARK: - Corner Resize Handle

private struct CornerResizeHandle: NSViewRepresentable {
    @Binding var liveHeight: Double?
    @Binding var liveWidth: Double?

    func makeNSView(context: Context) -> CornerResizeHandleNSView {
        CornerResizeHandleNSView(liveHeight: $liveHeight, liveWidth: $liveWidth)
    }
    func updateNSView(_ nsView: CornerResizeHandleNSView, context: Context) {
        nsView.liveHeight = $liveHeight
        nsView.liveWidth = $liveWidth
    }
}

final class CornerResizeHandleNSView: NSView {
    var liveHeight: Binding<Double?>
    var liveWidth: Binding<Double?>

    private var isTracking = false
    private var dragStartHeight: Double = 0
    private var dragStartWidth: Double = 0
    private var startScreenX: CGFloat = 0
    private var startScreenY: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    private let minHeight: Double = 240, maxHeight: Double = 720
    private let minWidth: Double = 610, maxWidth: Double = 1200

    init(liveHeight: Binding<Double?>, liveWidth: Binding<Double?>) {
        self.liveHeight = liveHeight
        self.liveWidth = liveWidth
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // 모서리 그립: 우하단 방향 대각선 3줄
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        for i in 0..<3 {
            let offset = CGFloat(i * 5 + 4)
            path.move(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 2))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + offset))
        }
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea.map { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.resizeNorthWestSouthEast.set() }
    override func mouseExited(with event: NSEvent) {
        if !isTracking { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        let settings = SettingsStore.shared.settings
        dragStartHeight = settings.expandedNotchHeight
        dragStartWidth = settings.expandedNotchWidth
        startScreenX = NSEvent.mouseLocation.x
        startScreenY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        let dx = NSEvent.mouseLocation.x - startScreenX
        let dy = NSEvent.mouseLocation.y - startScreenY
        // 아래로 드래그 = y 감소 → 높이 증가 / 오른쪽 드래그 = x 증가 → 너비 증가 (중앙 고정 ×2)
        let newHeight = min(max(dragStartHeight - dy, minHeight), maxHeight)
        let newWidth  = min(max(dragStartWidth + dx * 2, minWidth), maxWidth)
        liveHeight.wrappedValue = newHeight
        liveWidth.wrappedValue  = newWidth
        NotchWindowController.current?.updateLiveExpandedFrame(size: NSSize(width: newWidth, height: newHeight))
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        if let h = liveHeight.wrappedValue { SettingsStore.shared.settings.expandedNotchHeight = h }
        if let w = liveWidth.wrappedValue  { SettingsStore.shared.settings.expandedNotchWidth  = w }
        liveHeight.wrappedValue = nil
        liveWidth.wrappedValue  = nil
        NSCursor.arrow.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// `notch.expanded.activity` slot contributions in an isolated child so that
/// `pluginHost.contributions` changes do not re-render `NotchView` — which would
/// rebuild open context menus on every SessionActionsPlugin update.
/// Same isolation pattern as `SessionRowPluginBadges` and `SessionRowTimeAgo`.
private struct NotchActivityContributionsView: View {
    @ObservedObject private var pluginHost = AppState.shared.pluginHost

    var body: some View {
        let contributions = pluginHost.contributions[.notchExpandedActivity] ?? []
        if !contributions.isEmpty {
            PluginSlotView(contributions: contributions)
                .padding(.horizontal, 20)
        }
    }
}
