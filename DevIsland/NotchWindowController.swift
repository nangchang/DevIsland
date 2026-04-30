import AppKit
import SwiftUI
import Combine

// MARK: - Window Controller

class NotchWindowController: NSWindowController {
    private var cancellables = Set<AnyCancellable>()
    private var pendingSettle: DispatchWorkItem?
    private static let collapsedSize = NSSize(width: 140, height: 28)
    private static let expandedSize = NSSize(width: 680, height: 300)

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .mainMenu + 1
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        self.init(window: panel)

        let notchView = NotchHostingView(rootView: NotchView())
        notchView.wantsLayer = true
        notchView.layer?.backgroundColor = .clear
        panel.contentView = notchView
        
        updateWindowFrame(animate: false)

        AppState.shared.$isNotchExpanded
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                self?.handleExpansionChange(expanded)
            }
            .store(in: &cancellables)
    }

    private func handleExpansionChange(_ expanded: Bool) {
        pendingSettle?.cancel()
        
        if expanded {
            // 확장 시: 먼저 윈도우 프레임을 키워 '캔버스'를 확보 (딜레이 없음)
            updateWindowFrame(animate: false)
        } else {
            // 축소 시: SwiftUI 애니메이션이 끝난 후 프레임을 줄여 점프 방지
            let work = DispatchWorkItem { [weak self] in
                self?.updateWindowFrame(animate: false)
            }
            pendingSettle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    func updateWindowFrame(animate: Bool = true, sizeOverride: NSSize? = nil) {
        guard let window = window, let screen = NSScreen.main else { return }
        
        let expanded = AppState.shared.isNotchExpanded
        let size = sizeOverride ?? (expanded ? Self.expandedSize : Self.collapsedSize)
        
        // 화면 중앙(midX)과 상단(maxY)을 기준으로 좌표 계산
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        
        let newFrame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        window.setFrame(newFrame, display: true, animate: animate)
    }

    func expandFromCollapsedWindow() {
        guard !AppState.shared.isNotchExpanded else { return }
        
        // 1. 프레임을 먼저 키움 (캔버스 확보)
        updateWindowFrame(animate: false, sizeOverride: Self.expandedSize)
        
        // 2. 아주 미세한 딜레이 후 SwiftUI 확장 시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            AppState.shared.isNotchExpanded = true
        }
    }

    private static func notchSize(expanded: Bool) -> NSSize {
        expanded ? NSSize(width: 680, height: 300) : NSSize(width: 140, height: 28)
    }
}

// MARK: - Passthrough Hosting View

class NotchHostingView: NSHostingView<NotchView> {
    // 투명 픽셀 영역에서 OS 수준 click-through가 동작하도록 비불투명 처리
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard notchHitRect().contains(point) else { return nil }
        return super.hitTest(point) ?? self  // SwiftUI 내부 이벤트 라우팅 유지
    }

    override func mouseDown(with event: NSEvent) {
        if !AppState.shared.isNotchExpanded {
            (window?.windowController as? NotchWindowController)?.expandFromCollapsedWindow()
            return
        }

        super.mouseDown(with: event)
    }

    private func notchHitRect() -> CGRect {
        // 동적 프레임 모드에서는 윈도우 전체가 곧 노치이므로 bounds 전체를 리턴
        return bounds
    }
}

// MARK: - Tool Info

struct ToolInfo {
    let icon: String
    let color: Color
    let label: String
}

func toolInfo(for name: String) -> ToolInfo {
    switch name {
    case "Bash":       return ToolInfo(icon: "terminal.fill",          color: .orange, label: "Bash")
    case "Write":      return ToolInfo(icon: "doc.badge.plus",         color: Color(red: 0.3, green: 0.6, blue: 1.0), label: "Write")
    case "Edit":       return ToolInfo(icon: "pencil.and.outline",     color: Color(red: 0.3, green: 0.85, blue: 0.5), label: "Edit")
    case "Read":       return ToolInfo(icon: "doc.text",               color: .gray,   label: "Read")
    case "MultiEdit":  return ToolInfo(icon: "doc.on.doc",             color: Color(red: 0.3, green: 0.85, blue: 0.5), label: "MultiEdit")
    case "WebFetch":   return ToolInfo(icon: "globe",                  color: .purple, label: "WebFetch")
    case "WebSearch":  return ToolInfo(icon: "magnifyingglass",        color: Color(red: 0.2, green: 0.8, blue: 0.9), label: "WebSearch")
    case "Glob":       return ToolInfo(icon: "folder.badge.magnifyingglass", color: .yellow, label: "Glob")
    case "Grep":       return ToolInfo(icon: "text.magnifyingglass",   color: Color(red: 1.0, green: 0.8, blue: 0.2), label: "Grep")
    case "Agent":      return ToolInfo(icon: "person.2.fill",          color: .mint,   label: "Agent")
    default:           return ToolInfo(icon: "cpu",                    color: .white,  label: name.isEmpty ? "Tool" : name)
    }
}

// MARK: - Buddy Mascot

struct CodexBuddyView: View {
    let accent: Color
    let isActive: Bool
    let compact: Bool

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let bob = isActive ? -size * 0.05 : size * 0.03

            ZStack {
                Capsule()
                    .fill(accent.opacity(0.18))
                    .frame(width: size * 0.62, height: size * 0.13)
                    .blur(radius: size * 0.03)
                    .offset(y: size * 0.39)

                buddyBody(size: size)
                    .offset(y: bob)

                threadMark(size: size)
                    .offset(x: -size * 0.02, y: bob - size * 0.02)

                eyes(size: size)
                    .offset(y: bob)

                if !compact {
                    toolBadge(size: size)
                        .offset(x: size * 0.27, y: -size * 0.24 + bob)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityLabel("Codex Buddy")
    }

    private func buddyBody(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.14, blue: 0.18),
                        Color(red: 0.04, green: 0.05, blue: 0.07)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .stroke(accent.opacity(0.65), lineWidth: max(1, size * 0.045))
            )
            .overlay(
                Circle()
                    .fill(accent.opacity(0.24))
                    .frame(width: size * 0.22, height: size * 0.22)
                    .blur(radius: size * 0.08)
                    .offset(x: -size * 0.18, y: -size * 0.16)
            )
            .frame(width: size * 0.74, height: size * 0.68)
    }

    private func threadMark(size: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: size * 0.35, y: size * 0.35))
            path.addCurve(
                to: CGPoint(x: size * 0.64, y: size * 0.35),
                control1: CGPoint(x: size * 0.43, y: size * 0.16),
                control2: CGPoint(x: size * 0.59, y: size * 0.16)
            )
            path.addCurve(
                to: CGPoint(x: size * 0.36, y: size * 0.62),
                control1: CGPoint(x: size * 0.70, y: size * 0.53),
                control2: CGPoint(x: size * 0.52, y: size * 0.70)
            )
        }
        .stroke(accent.opacity(0.82), style: StrokeStyle(lineWidth: max(1, size * 0.045), lineCap: .round))
        .frame(width: size, height: size)
    }

    private func eyes(size: CGFloat) -> some View {
        HStack(spacing: size * 0.12) {
            Capsule()
                .fill(Color.white.opacity(0.86))
                .frame(width: size * 0.08, height: size * 0.11)
            Capsule()
                .fill(Color.white.opacity(0.86))
                .frame(width: size * 0.08, height: size * 0.11)
        }
        .offset(y: size * 0.04)
    }

    private func toolBadge(size: CGFloat) -> some View {
        Circle()
            .fill(Color.black.opacity(0.9))
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: max(1, size * 0.025))
            )
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.18, weight: .bold))
                    .foregroundColor(accent)
            )
            .frame(width: size * 0.32, height: size * 0.32)
    }
}

// MARK: - Components

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

// MARK: - Session Row

struct SessionRowView: View {
    let session: ActiveSession
    let isCurrent: Bool
    
    @State private var timeAgo: String = ""
    private var tool: ToolInfo { toolInfo(for: session.lastToolName) }
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        Button(action: { AppState.shared.selectedSessionId = session.id }) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tool.color.opacity(0.15))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: tool.icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(tool.color)
                    
                    if session.isPending {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.black, lineWidth: 2))
                            .offset(x: 12, y: 12)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(session.terminalTitle)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        Text(timeAgo)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    
                    HStack(spacing: 6) {
                        Text(String(session.id.prefix(8)))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                        
                        Text("•")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.2))
                        
                        Text(session.lastEventName)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(tool.color.opacity(0.8))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isCurrent ? Color.white.opacity(0.1) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isCurrent ? tool.color.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onAppear { updateTimeAgo() }
        .onReceive(timer) { _ in updateTimeAgo() }
    }
    
    private func updateTimeAgo() {
        let diff = Int(Date().timeIntervalSince(session.lastActiveAt))
        if diff < 5 { timeAgo = "Just now" }
        else if diff < 60 { timeAgo = "\(diff)s ago" }
        else { timeAgo = "\(diff/60)m ago" }
    }
}

// MARK: - Notch View

struct NotchView: View {
    @ObservedObject var state = AppState.shared
    @State private var buddyPulse = false

    private var tool: ToolInfo { toolInfo(for: state.currentToolName) }

    var body: some View {
        HStack {
            Spacer()
            
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    // Background
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: state.isNotchExpanded ? 24 : 14,
                        bottomTrailingRadius: state.isNotchExpanded ? 24 : 14,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .fill(Color.black)
                    .frame(
                        width:  state.isNotchExpanded ? 680 : 140,
                        height: state.isNotchExpanded ? 300 : 28,
                        alignment: .top
                    )

                    VStack(alignment: .center, spacing: 0) {
                        if state.isNotchExpanded {
                            expandedContent
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        } else {
                            collapsedContent
                                .transition(.opacity)
                        }
                        
                        if !state.isNotchExpanded {
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(
                        width:  state.isNotchExpanded ? 680 : 140,
                        height: state.isNotchExpanded ? 300 : 28,
                        alignment: .top
                    )
                }
            }
            .frame(
                width:  state.isNotchExpanded ? 680 : 140,
                height: state.isNotchExpanded ? 300 : 28,
                alignment: .top
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if !state.isNotchExpanded {
                    (NSApp.windows.first { $0.windowController is NotchWindowController }?.windowController as? NotchWindowController)?.expandFromCollapsedWindow()
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: state.isNotchExpanded)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                buddyPulse = true
            }
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    // MARK: Collapsed

    var collapsedContent: some View {
        HStack(spacing: 6) {
            CodexBuddyView(accent: tool.color, isActive: buddyPulse, compact: true)
                .frame(width: 18, height: 18)
            Text("DevIsland")
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 11, weight: .semibold))
        }
    }

    // MARK: Expanded

    var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(tool.color.opacity(0.15))
                        .frame(width: 48, height: 48)
                    CodexBuddyView(accent: tool.color, isActive: buddyPulse, compact: false)
                        .frame(width: 34, height: 34)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(tool.label)
                            .font(.system(size: 18, weight: .black))
                            .foregroundColor(.white)
                        
                        StatusBadge(
                            text: state.pendingCount > 0 ? "Approval Required" : "Monitoring",
                            color: state.pendingCount > 0 ? .orange : .green.opacity(0.6)
                        )
                    }
                    
                    HStack(spacing: 6) {
                        TagView(icon: "terminal.fill", text: state.currentSessionId.isEmpty ? "No Session" : String(state.currentSessionId.prefix(8)))
                        TagView(icon: "macwindow", text: state.activeSessions.first(where: { $0.id == state.currentSessionId })?.terminalTitle ?? "Unknown")
                        if state.pendingCount > 1 {
                            TagView(icon: "list.bullet", text: "\(state.pendingCount) tasks queued", color: .orange.opacity(0.2))
                        }
                    }
                }

                Spacer()

                // Close Button
                Button {
                    state.dismissCurrentRequest()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.2))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            // ── Main Dashboard ──────────────────────────
            HStack(alignment: .top, spacing: 0) {
                
                // LEFT: Focus Area
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("ACTIVE ACTION")
                                .font(.system(size: 9, weight: .black))
                                .foregroundColor(.white.opacity(0.3))
                            Spacer()
                            Text(state.currentEventName)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(tool.color)
                        }
                        .padding(.horizontal, 20)
                        
                        ScrollView {
                            Text(state.currentMessage.isEmpty ? "Waiting for next agent request..." : state.currentMessage)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                        }
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                        .frame(maxHeight: 120)
                    }
                    
                    Spacer()
                    
                    // Progress & Actions
                    VStack(spacing: 12) {
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
                        
                        HStack(spacing: 12) {
                            Button(action: { state.deny() }) {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Deny Request")
                                }
                                .font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)

                            Button(action: { state.approve() }) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("Approve")
                                }
                                .font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(tool.color.opacity(0.15))
                                .foregroundColor(tool.color)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 20)
                }
                .frame(width: 420)
                
                // Vertical Divider
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
                    .padding(.vertical, 20)
                
                // RIGHT: Session List
                VStack(alignment: .leading, spacing: 12) {
                    Text("AGENT SESSIONS")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.horizontal, 20)
                    
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(state.activeSessions) { session in
                                SessionRowView(
                                    session: session,
                                    isCurrent: session.id == state.currentSessionId
                                )
                            }
                            
                            if state.activeSessions.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: 24))
                                        .foregroundColor(.white.opacity(0.1))
                                    Text("Listening for AI Agents...")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.white.opacity(0.2))
                                }
                                .padding(.top, 40)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 12)
        }
    }

    private var progressColor: Color {
        if state.timeoutProgress > 0.5  { return .green }
        if state.timeoutProgress > 0.25 { return .orange }
        return .red
    }
}
