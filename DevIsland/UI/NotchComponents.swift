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

// MARK: - Session Row View

struct SessionRowView: View {
    let session: ActiveSession
    let isCurrent: Bool

    @ObservedObject private var l10n = L10n.shared
    @State private var timeAgo: String = ""
    private var tool: ToolInfo { toolInfo(for: session.lastToolName) }
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

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { AppState.shared.showSessionDetail(session.id) }) {
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
                            if session.isUnread {
                                Circle()
                                    .fill(Color.blue.opacity(0.85))
                                    .frame(width: 6, height: 6)
                            }

                            Text(session.terminalTitle)
                                .font(.system(size: 12, weight: session.isUnread ? .heavy : .bold))
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
                                .lineLimit(1)

                            if let statusLabel = statusLabel {
                                Text(statusLabel)
                                    .font(.system(size: 8, weight: .black))
                                    .foregroundColor(statusColor)
                                    .lineLimit(1)
                            }

                            if session.isAutoEditActive {
                                Text(l10n.statusAutoEdit)
                                    .font(.system(size: 8, weight: .black))
                                    .foregroundColor(Color(red: 1.0, green: 0.7, blue: 0.2))
                                    .lineLimit(1)
                            }

                            if !session.lastToolName.isEmpty {
                                Text(session.lastToolName)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }

                        if !session.lastMessage.isEmpty {
                            Text(session.lastMessage)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
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
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Focus terminal")

            Button(action: { AppState.shared.dismissSession(session.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.65))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(session.isPending ? l10n.helpDismissPending : l10n.helpDismissSession)
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
        .onAppear { updateTimeAgo() }
        .onReceive(Self.sharedTimer) { _ in updateTimeAgo() }
    }

    private func updateTimeAgo() {
        let diff = Int(Date().timeIntervalSince(session.lastActiveAt))
        let l = L10n.shared
        if diff < 5 { timeAgo = l.timeJustNow() }
        else if diff < 60 { timeAgo = l.timeSecsAgo(diff) }
        else { timeAgo = l.timeMinsAgo(diff / 60) }
    }
}
