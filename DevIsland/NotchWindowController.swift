import AppKit
import SwiftUI
import Combine

// MARK: - Window Controller

class NotchWindowController: NSWindowController {
    private var cancellables = Set<AnyCancellable>()
    private var pendingSettle: DispatchWorkItem?
    private static let animationCanvasSize = NSSize(width: 600, height: 400)

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.animationCanvasSize),
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

        setFrame(size: Self.notchSize(expanded: AppState.shared.isNotchExpanded))

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

        if !expanded {
            let work = DispatchWorkItem { [weak self] in
                self?.setFrame(size: Self.notchSize(expanded: false))
            }
            pendingSettle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    func expandFromCollapsedWindow() {
        guard !AppState.shared.isNotchExpanded else { return }
        setFrame(size: Self.animationCanvasSize)
        DispatchQueue.main.async {
            AppState.shared.isNotchExpanded = true
        }
    }

    private func setFrame(size: NSSize) {
        guard let window = self.window, let screen = NSScreen.main else { return }
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        window.setFrame(frame, display: true, animate: false)
    }

    private static func notchSize(expanded: Bool) -> NSSize {
        expanded ? NSSize(width: 440, height: 220) : NSSize(width: 140, height: 28)
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
        let size = AppState.shared.isNotchExpanded
            ? CGSize(width: 440, height: 220)
            : bounds.size
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: bounds.height - size.height,
            width: size.width,
            height: size.height
        )
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

// MARK: - Notch View

struct NotchView: View {
    @ObservedObject var state = AppState.shared
    @State private var buddyPulse = false

    private var tool: ToolInfo { toolInfo(for: state.currentToolName) }

    var body: some View {
        VStack {
            ZStack {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: state.isNotchExpanded ? 22 : 14,
                    bottomTrailingRadius: state.isNotchExpanded ? 22 : 14,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(Color.black)
                .allowsHitTesting(!state.isNotchExpanded)
                .onTapGesture { state.isNotchExpanded = true }

                if state.isNotchExpanded {
                    expandedContent
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    collapsedContent
                        .transition(.opacity)
                }
            }
            .frame(
                width:  state.isNotchExpanded ? 440 : 140,
                height: state.isNotchExpanded ? 220 : 28
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if !state.isNotchExpanded {
                    state.isNotchExpanded = true
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.72), value: state.isNotchExpanded)

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
            HStack(spacing: 8) {
                CodexBuddyView(accent: tool.color, isActive: buddyPulse, compact: false)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text(state.currentEventName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()

                // Queue count badge
                if state.pendingCount > 1 {
                    Text("+\(state.pendingCount - 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(Capsule())
                }

                // Session ID badge
                if !state.currentSessionId.isEmpty {
                    Text(state.currentSessionId)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                // Close
                Button {
                    state.isNotchExpanded = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // ── Divider ──────────────────────────────────
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            // ── Command / Message ────────────────────────
            ScrollView {
                Text(state.currentMessage.isEmpty ? "(no details)" : state.currentMessage)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .frame(maxHeight: 68)

            Spacer()

            // ── Timeout progress bar ─────────────────────
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                    Rectangle()
                        .fill(progressColor)
                        .frame(width: geo.size.width * state.timeoutProgress)
                        .animation(.linear(duration: 0.1), value: state.timeoutProgress)
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 10)

            // ── Buttons ─────────────────────────────────
            HStack(spacing: 10) {
                // Deny
                Button(action: { state.deny() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Deny")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.red.opacity(0.15))
                    .foregroundColor(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red.opacity(0.25), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)

                // Approve
                Button(action: { state.approve() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Approve")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(tool.color.opacity(0.15))
                    .foregroundColor(tool.color)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(tool.color.opacity(0.25), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private var progressColor: Color {
        if state.timeoutProgress > 0.5  { return .green }
        if state.timeoutProgress > 0.25 { return .orange }
        return .red
    }
}
