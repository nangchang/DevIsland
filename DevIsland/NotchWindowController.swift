import AppKit
import SwiftUI

// MARK: - Window Controller

class NotchWindowController: NSWindowController {
    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        self.init(window: panel)

        let notchView = NSHostingView(rootView: NotchView())
        panel.contentView = notchView

        positionUnderNotch()
    }

    func positionUnderNotch() {
        guard let window = self.window, let screen = NSScreen.main else { return }
        let screenRect = screen.frame
        let windowRect = window.frame
        let x = (screenRect.width - windowRect.width) / 2
        let y = screenRect.height - windowRect.height
        window.setFrameOrigin(NSPoint(x: x, y: y))
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

// MARK: - Notch View

struct NotchView: View {
    @ObservedObject var state = AppState.shared

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
            .animation(.spring(response: 0.42, dampingFraction: 0.72), value: state.isNotchExpanded)
            .onTapGesture {
                if !state.isNotchExpanded { state.isNotchExpanded = true }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    // MARK: Collapsed

    var collapsedContent: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 6, height: 6)
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
                Image(systemName: tool.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(tool.color)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text(state.currentEventName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()

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
