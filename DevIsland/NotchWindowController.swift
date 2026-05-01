import AppKit
import SwiftUI
import Combine

// MARK: - Window Controller

fileprivate let collapsedNotchSize = NSSize(width: 248, height: 32)
fileprivate let expandedNotchSize = NSSize(width: 680, height: 300)
fileprivate let notchHorizontalOffset: CGFloat = -10

class NotchWindowController: NSWindowController {
    private var cancellables = Set<AnyCancellable>()
    private var pendingSettle: DispatchWorkItem?
    private var pinnedCenterX: CGFloat?

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: expandedNotchSize),
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

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.pinnedCenterX = nil
                self?.updateWindowFrame(animate: false)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: panel)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.pinnedCenterX = nil
                self?.updateWindowFrame(animate: false)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
        }
    }

    func updateWindowFrame(animate: Bool = true, sizeOverride: NSSize? = nil) {
        guard let window = window else { return }
        let screen = targetScreen(for: window)
        
        let expanded = AppState.shared.isNotchExpanded
        let size = sizeOverride ?? Self.notchSize(expanded: expanded)
        
        let centerX = pinnedCenterX ?? (Self.notchCenterX(on: screen) + notchHorizontalOffset)
        pinnedCenterX = centerX

        let x = centerX - size.width / 2
        let y = screen.frame.maxY - size.height
        
        let newFrame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        window.setFrame(newFrame, display: true, animate: animate)
    }

    func expandFromCollapsedWindow() {
        guard !AppState.shared.isNotchExpanded else { return }
        
        // 프레임과 SwiftUI 상태를 같은 런루프에서 바꿔 중간 위치가 보이지 않게 한다.
        updateWindowFrame(animate: false, sizeOverride: expandedNotchSize)
        AppState.shared.isNotchExpanded = true
    }

    private static func notchSize(expanded: Bool) -> NSSize {
        expanded ? expandedNotchSize : collapsedNotchSize
    }

    private static func notchCenterX(on screen: NSScreen) -> CGFloat {
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           !leftArea.isEmpty,
           !rightArea.isEmpty {
            return round((leftArea.maxX + rightArea.minX) / 2)
        }

        return round(screen.frame.midX)
    }

    private func targetScreen(for window: NSWindow) -> NSScreen {
        if let windowScreen = window.screen {
            return windowScreen
        }

        let mouseLocation = NSEvent.mouseLocation
        if let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return mouseScreen
        }

        return NSScreen.main ?? NSScreen.screens.first!
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

enum BuddyKind {
    case codex
    case claudeCode

    init(from terminalTitle: String) {
        let lower = terminalTitle.lowercased()
        if lower.contains("claude") {
            self = .claudeCode
        } else {
            self = .codex
        }
    }

    var accentColor: Color {
        switch self {
        case .codex:     return Color(red: 0.34, green: 0.38, blue: 1.0)
        case .claudeCode: return Color(red: 0.82, green: 0.42, blue: 0.30)
        }
    }

    var accessibilityName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude Code"
        }
    }
}

private struct PixelCell {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let color: Color

    init(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ color: Color) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.color = color
    }
}

struct CLIBuddyView: View {
    let accent: Color
    let isActive: Bool
    let compact: Bool
    let kind: BuddyKind

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let bob = isActive ? -size * 0.05 : size * 0.03

            ZStack {
                Capsule()
                    .fill(accent.opacity(0.22))
                    .frame(width: size * 0.64, height: size * 0.12)
                    .blur(radius: size * 0.02)
                    .offset(y: size * 0.38)

                pixelBody(size: size)
                    .offset(y: bob)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityLabel(kind == .codex ? "Codex Buddy" : "Claude Code Buddy")
    }

    private func pixelBody(size: CGFloat) -> some View {
        return ZStack {
            mascotSprite(size: size)
                .shadow(color: Color.black.opacity(0.25), radius: size * 0.04, y: size * 0.03)
        }
        .frame(width: size, height: size)
    }

    private func mascotSprite(size: CGFloat) -> some View {
        pixelGrid(size: size, cells: kind == .codex ? codexCells : claudeCells)
    }

    private var codexCells: [PixelCell] {
        let fur = Color(red: 0.34, green: 0.38, blue: 1.0)
        let shade = Color(red: 0.15, green: 0.22, blue: 0.88)
        let ink = Color.white.opacity(0.94)

        return terminalBaseCells(kind: .codex) + [
            PixelCell(2, 1, 2, 3, fur),
            PixelCell(12, 1, 2, 3, fur),
            PixelCell(3, 3, 10, 1, fur),
            PixelCell(1, 4, 14, 1, fur),
            PixelCell(0, 5, 16, 6, fur),
            PixelCell(1, 11, 14, 1, shade),
            PixelCell(3, 12, 10, 1, shade),
            PixelCell(5, 6, 1, 1, ink),
            PixelCell(6, 7, 1, 1, ink),
            PixelCell(5, 8, 1, 1, ink),
            PixelCell(9, 9, 4, 1, ink)
        ]
    }

    private var claudeCells: [PixelCell] {
        let fur = Color(red: 0.82, green: 0.42, blue: 0.30)
        let dark = Color(red: 0.47, green: 0.22, blue: 0.16)
        let ink = Color(red: 0.09, green: 0.04, blue: 0.03)

        return terminalBaseCells(kind: .claudeCode) + [
            PixelCell(3, 1, 2, 2, fur),
            PixelCell(11, 1, 2, 2, fur),
            PixelCell(3, 3, 3, 1, fur),
            PixelCell(10, 3, 3, 1, fur),
            PixelCell(4, 4, 8, 1, fur),
            PixelCell(2, 5, 12, 1, fur),
            PixelCell(1, 6, 14, 4, fur),
            PixelCell(2, 10, 12, 2, fur),
            PixelCell(4, 12, 8, 1, dark),
            PixelCell(0, 8, 3, 2, fur),
            PixelCell(13, 8, 3, 2, fur),
            PixelCell(0, 10, 2, 1, fur),
            PixelCell(14, 10, 2, 1, fur),
            PixelCell(5, 7, 1, 1, ink),
            PixelCell(10, 7, 1, 1, ink),
            PixelCell(4, 11, 2, 1, dark),
            PixelCell(10, 11, 2, 1, dark),
            PixelCell(3, 13, 3, 1, dark),
            PixelCell(10, 13, 3, 1, dark)
        ]
    }

    private func terminalBaseCells(kind: BuddyKind) -> [PixelCell] {
        let shell = kind == .codex
            ? Color(red: 0.08, green: 0.09, blue: 0.12)
            : Color(red: 0.09, green: 0.08, blue: 0.07)
        let rim = kind == .codex
            ? Color(red: 0.24, green: 0.27, blue: 0.34)
            : Color(red: 0.32, green: 0.24, blue: 0.20)
        let title = kind == .codex
            ? rim
            : rim
        let text = kind == .codex
            ? Color.white.opacity(0.45)
            : Color.white.opacity(0.42)

        return [
            PixelCell(1, 13, 14, 1, rim),
            PixelCell(1, 14, 14, 2, shell),
            PixelCell(1, 14, 14, 1, title),
            PixelCell(3, 14, 1, 1, Color.red.opacity(0.82)),
            PixelCell(5, 14, 1, 1, Color.yellow.opacity(0.82)),
            PixelCell(7, 14, 1, 1, Color.green.opacity(0.82)),
            PixelCell(9, 15, 4, 1, text.opacity(0.36))
        ]
    }

    private func pixelGrid(size: CGFloat, cells: [PixelCell]) -> some View {
        let unit = size / 16

        return ZStack(alignment: .topLeading) {
            ForEach(cells.indices, id: \.self) { index in
                let cell = cells[index]
                Rectangle()
                    .fill(cell.color)
                    .frame(width: unit * CGFloat(cell.width), height: unit * CGFloat(cell.height))
                    .offset(x: unit * CGFloat(cell.x), y: unit * CGFloat(cell.y))
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
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

struct AgentRequestBadge: View {
    let kind: BuddyKind
    let tool: ToolInfo
    let isActive: Bool
    var size: CGFloat = 48

    private var mascotSize: CGFloat { size * 0.72 }
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

            CLIBuddyView(accent: kind.accentColor, isActive: isActive, compact: size < 40, kind: kind)
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
                ZStack(alignment: .topTrailing) {
                    AgentRequestBadge(
                        kind: session.agentKind,
                        tool: tool,
                        isActive: session.isPending,
                        size: 32
                    )

                    if session.isPending {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.black, lineWidth: 2))
                            .offset(x: 4, y: -4)
                    }
                }
                .frame(width: 36, height: 36)
                
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
    private var hasApprovalRequest: Bool { state.pendingCount > 0 }
    private var headerTitle: String { hasApprovalRequest ? tool.label : "Sessions" }
    private var displayedSessionId: String {
        state.currentSessionId.isEmpty ? (state.selectedSessionId ?? "") : state.currentSessionId
    }
    private var notchSize: NSSize {
        state.isNotchExpanded ? expandedNotchSize : collapsedNotchSize
    }

    private var currentBuddyKind: BuddyKind {
        let session = state.activeSessions.first { $0.id == state.currentSessionId }
            ?? state.activeSessions.first { $0.id == state.selectedSessionId }
            ?? state.activeSessions.first
        return session?.agentKind ?? BuddyKind(from: "")
    }

    private var notchExpansionAnimation: Animation {
        state.isNotchExpanded
            ? .spring(response: 0.35, dampingFraction: 0.75)
            : .easeOut(duration: 0.28)
    }

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
                        width: notchSize.width,
                        height: notchSize.height,
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
                        width: notchSize.width,
                        height: notchSize.height,
                        alignment: .top
                    )
                }
            }
            .frame(
                width: notchSize.width,
                height: notchSize.height,
                alignment: .top
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if !state.isNotchExpanded {
                    (NSApp.windows.first { $0.windowController is NotchWindowController }?.windowController as? NotchWindowController)?.expandFromCollapsedWindow()
                }
            }
            .animation(notchExpansionAnimation, value: state.isNotchExpanded)

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
        ZStack {
            Text("DevIsland")
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 11, weight: .semibold))

            HStack {
                CLIBuddyView(
                    accent: BuddyKind.claudeCode.accentColor,
                    isActive: buddyPulse,
                    compact: true,
                    kind: .claudeCode
                )
                .frame(width: 18, height: 18)
                .offset(x: -4, y: 4)

                Spacer(minLength: 0)

                CLIBuddyView(accent: BuddyKind.codex.accentColor, isActive: buddyPulse, compact: true, kind: .codex)
                    .frame(width: 18, height: 18)
                    .offset(x: 4, y: 4)
            }
        }
        .padding(.horizontal, 12)
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
                            text: state.pendingCount > 0 ? "Approval Required" : "Monitoring",
                            color: state.pendingCount > 0 ? .orange : .green.opacity(0.6)
                        )
                    }
                    
                    if !displayedSessionId.isEmpty {
                        HStack(spacing: 6) {
                            TagView(icon: "terminal.fill", text: String(displayedSessionId.prefix(8)))
                            TagView(icon: "macwindow", text: state.activeSessions.first(where: { $0.id == displayedSessionId })?.terminalTitle ?? "Unknown")
                            if state.pendingCount > 1 {
                                TagView(icon: "list.bullet", text: "\(state.pendingCount) tasks queued", color: .orange.opacity(0.2))
                            }
                        }
                    } else if state.pendingCount > 1 {
                        HStack(spacing: 6) {
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
            if hasApprovalRequest {
                approvalContent
            } else {
                sessionsContent
            }
        }
    }

    private var approvalContent: some View {
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
                    .frame(maxHeight: 120)
                }
                
                Spacer()
                
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
            .frame(width: state.activeSessions.isEmpty ? 680 : 420)
            
            if !state.activeSessions.isEmpty {
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

    private var sessionsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AGENT SESSIONS")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.white.opacity(0.3))
                .padding(.horizontal, 20)
            
            if state.activeSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.1))
                    Text("Listening for AI Agents...")
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

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(state.activeSessions) { session in
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
