import AppKit
import SwiftUI

struct FleetRadarView: View {
    @ObservedObject var viewModel: FleetRadarViewModel
    @ObservedObject private var l10n = L10n.shared

    let sessions: [ActiveSession]
    let labels: [String: String]
    let onShowDetail: (String) -> Void
    let onFocusTerminal: (String) -> Void
    let isPresented: Bool
    let presentationGeneration: UInt64

    init(
        viewModel: FleetRadarViewModel,
        sessions: [ActiveSession],
        labels: [String: String],
        onShowDetail: @escaping (String) -> Void,
        onFocusTerminal: @escaping (String) -> Void,
        isPresented: Bool = true,
        presentationGeneration: UInt64 = 0
    ) {
        self.viewModel = viewModel
        self.sessions = sessions
        self.labels = labels
        self.onShowDetail = onShowDetail
        self.onFocusTerminal = onFocusTerminal
        self.isPresented = isPresented
        self.presentationGeneration = presentationGeneration
    }

    var body: some View {
        VStack(spacing: 0) {
            FleetToolbar(
                cardCount: viewModel.cards.count,
                worktreeCount: Self.worktreeCount(in: viewModel.cards),
                overlapPairCount: Self.overlapPairCount(in: viewModel.cards),
                isRefreshing: viewModel.isRefreshing,
                lastCompletedAt: viewModel.lastCompletedAt,
                onRefresh: { refresh() }
            )
            Divider()

            if sessions.isEmpty {
                ContentUnavailableView(
                    l10n.fleetEmptyState,
                    systemImage: "rectangle.stack.badge.plus"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.cards.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(l10n.fleetRefreshing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 280, maximum: 420),
                                spacing: 12,
                                alignment: .top
                            )
                        ],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        let peerTitles = Self.peerTitles(in: viewModel.cards)
                        ForEach(viewModel.cards) { card in
                            FleetCardView(
                                card: card,
                                peerTitles: peerTitles,
                                onShowDetail: onShowDetail,
                                onFocusTerminal: onFocusTerminal,
                                onRetry: { refresh() }
                            )
                        }
                    }
                    .padding(16)
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
        }
        .onAppear {
            guard isPresented else { return }
            refresh(forceRefresh: false)
        }
        .onChange(of: sessions) { _, _ in
            guard isPresented else { return }
            refresh(forceRefresh: false)
        }
        .onChange(of: labels) { _, _ in
            guard isPresented else { return }
            refresh(forceRefresh: false)
        }
        .onChange(of: presentationGeneration) { _, _ in
            guard isPresented else { return }
            refresh(forceRefresh: false)
        }
        .onChange(of: isPresented) { _, isPresented in
            guard !isPresented else { return }
            viewModel.cancelRefresh()
        }
    }

    private func refresh(forceRefresh: Bool = true) {
        viewModel.update(
            sessions: sessions,
            labels: labels,
            forceRefresh: forceRefresh
        )
    }

    private static func worktreeCount(in cards: [FleetCardModel]) -> Int {
        Set(cards.flatMap { card in
            card.gitStates.values.compactMap { state -> FleetPeerKey? in
                guard let snapshot = snapshot(from: state) else { return nil }
                return FleetPeerKey(snapshot: snapshot)
            }
        }).count
    }

    private static func overlapPairCount(in cards: [FleetCardModel]) -> Int {
        Set(cards.flatMap { card in
            card.overlaps.map(FleetOverlapPairKey.init)
        }).count
    }

    private static func peerTitles(
        in cards: [FleetCardModel]
    ) -> [FleetPeerKey: String] {
        var titles: [FleetPeerKey: String] = [:]
        for card in cards {
            for state in card.gitStates.values {
                guard let snapshot = snapshot(from: state) else { continue }
                let key = FleetPeerKey(snapshot: snapshot)
                if titles[key] == nil {
                    titles[key] = card.group.root.displayTitle
                }
            }
        }
        return titles
    }

    private static func snapshot(
        from state: GitSnapshotState
    ) -> GitWorktreeSnapshot? {
        switch state {
        case let .ready(snapshot), let .stale(snapshot, _):
            return snapshot
        case .unavailable:
            return nil
        }
    }
}

private struct FleetToolbar: View {
    @ObservedObject private var l10n = L10n.shared

    let cardCount: Int
    let worktreeCount: Int
    let overlapPairCount: Int
    let isRefreshing: Bool
    let lastCompletedAt: Date?
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(l10n.fleetTitle)
                .font(.headline)

            toolbarCount(l10n.fleetActiveCardsCount(cardCount), icon: "person.2.fill")
            toolbarCount(l10n.fleetWorktreesCount(worktreeCount), icon: "arrow.triangle.branch")
            toolbarCount(
                l10n.fleetOverlapPairsCount(overlapPairCount),
                icon: "exclamationmark.triangle.fill"
            )

            Spacer(minLength: 12)

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(l10n.fleetRefreshing)
            }

            if let lastCompletedAt {
                FleetRelativeTimeView(
                    date: lastCompletedAt,
                    prefix: l10n.fleetUpdated
                )
                .foregroundStyle(.secondary)
            }

            Button(action: onRefresh) {
                Label(l10n.fleetRefresh, systemImage: "arrow.clockwise")
            }
            .help(l10n.fleetRefreshHelp)
            .accessibilityLabel(l10n.fleetRefresh)
            .accessibilityHint(l10n.fleetRefreshHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func toolbarCount(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct FleetCardView: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var showsAllChildren = false
    @State private var showsOverlapPopover = false

    let card: FleetCardModel
    let peerTitles: [FleetPeerKey: String]
    let onShowDetail: (String) -> Void
    let onFocusTerminal: (String) -> Void
    let onRetry: () -> Void

    private var root: FleetSessionDescriptor { card.group.root }

    private var workspacePath: String? {
        nonempty(root.workspaceRoot)
    }

    private var overlapSections: [FleetOverlapSection] {
        FleetOverlapSection.make(from: card.overlaps, peerTitles: peerTitles)
    }

    private var newestActivityAt: Date {
        ([root] + card.group.children).map(\.lastActiveAt).max() ?? root.lastActiveAt
    }

    private var hiddenChildCount: Int {
        max(card.group.children.count - 3, 0)
    }

    private var requiresRetry: Bool {
        guard case let .unavailable(failure) = card.primaryGitState else {
            return false
        }
        switch failure {
        case .timedOut, .outputTooLarge, .launchFailed, .commandFailed, .malformedOutput:
            return true
        case .missingWorkspace, .notRepository:
            return false
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {
                onShowDetail(root.id)
            } label: {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(l10n.fleetShowDetailHelp)

            cardContent
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .frame(minHeight: 38, alignment: .top)
                .allowsHitTesting(false)

            FleetGitSummaryView(
                state: card.primaryGitState,
                worktreeCount: uniqueWorktreeCount
            )
            .frame(minHeight: 44, alignment: .topLeading)
            .allowsHitTesting(false)

            if !overlapSections.isEmpty {
                FleetOverlapSummary(
                    sections: overlapSections,
                    showsPopover: $showsOverlapPopover
                )
            }

            recentActivity
                .allowsHitTesting(false)

            if !card.group.children.isEmpty {
                subagents
                    .allowsHitTesting(false)
            }

            Divider()
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: root.provider.fleetSymbol)
                    .foregroundStyle(root.provider.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(root.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .help(root.displayTitle)

                    HStack(spacing: 6) {
                        Text(root.provider.accessibilityName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if card.group.isOrphan {
                            Label(l10n.fleetOrphanSubagent, systemImage: "link.badge.plus")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 4)

                FleetAttentionBadge(kind: card.primaryAttention, isPrimary: true)
                FleetRelativeTimeView(date: newestActivityAt)
                    .foregroundStyle(.secondary)
            }

            if !card.secondaryAttention.isEmpty {
                HStack(spacing: 4) {
                    ForEach(
                        card.secondaryAttention.sorted(by: { $0.rawValue < $1.rawValue }),
                        id: \.rawValue
                    ) { attention in
                        FleetAttentionBadge(kind: attention, isPrimary: false)
                    }
                }
            }
        }
    }

    private var recentActivity: some View {
        let values = [root.lastEventName, root.lastToolName, root.lastMessage]
            .filter { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: 3) {
            Label(l10n.fleetRecentActivity, systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(values.isEmpty ? l10n.fleetNoRecentActivity : values.joined(separator: " • "))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(values.joined(separator: " • "))
        }
    }

    private var subagents: some View {
        let displayedChildren = showsAllChildren
            ? card.group.children
            : Array(card.group.children.prefix(3))

        return VStack(alignment: .leading, spacing: 6) {
            Label(l10n.fleetSubagents, systemImage: "person.2")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(displayedChildren, id: \.id) { child in
                FleetSubagentRow(session: child)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                actionButton(
                    title: l10n.fleetShowDetail,
                    help: l10n.fleetShowDetailHelp,
                    symbol: "sidebar.right"
                ) {
                    onShowDetail(root.id)
                }

                actionButton(
                    title: l10n.fleetFocusTerminal,
                    help: l10n.fleetFocusTerminalHelp,
                    symbol: "terminal"
                ) {
                    onFocusTerminal(root.id)
                }

                if let workspacePath {
                    actionButton(
                        title: l10n.fleetOpenInFinder,
                        help: l10n.fleetOpenInFinderHelp,
                        symbol: "folder"
                    ) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: workspacePath))
                    }

                    actionButton(
                        title: l10n.fleetCopyPath,
                        help: l10n.fleetCopyPathHelp,
                        symbol: "doc.on.clipboard"
                    ) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(workspacePath, forType: .string)
                    }
                }

                if !overlapSections.isEmpty {
                    actionButton(
                        title: l10n.fleetOverlapDetails,
                        help: l10n.fleetOverlapDetailsHelp,
                        symbol: "info.circle"
                    ) {
                        showsOverlapPopover = true
                    }
                }

                Spacer(minLength: 0)
            }

            if requiresRetry || hiddenChildCount > 0 {
                HStack(spacing: 12) {
                    if requiresRetry {
                        actionButton(
                            title: l10n.fleetRetry,
                            help: l10n.fleetRetry,
                            symbol: "arrow.clockwise",
                            showsTitle: true
                        ) {
                            onRetry()
                        }
                    }

                    if hiddenChildCount > 0 {
                        let title = showsAllChildren
                            ? l10n.fleetShowFewer
                            : l10n.fleetMoreSubagents(hiddenChildCount)
                        actionButton(
                            title: title,
                            help: title,
                            symbol: showsAllChildren ? "chevron.up" : "chevron.down",
                            showsTitle: true
                        ) {
                            showsAllChildren.toggle()
                        }
                    }

                    Spacer(minLength: 0)
                }
                .font(.caption)
            }
        }
    }

    private func actionButton(
        title: String,
        help: String,
        symbol: String,
        showsTitle: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if showsTitle {
                Label(title, systemImage: symbol)
            } else {
                Label(title, systemImage: symbol)
                    .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }

    private var uniqueWorktreeCount: Int {
        Set(card.gitStates.values.compactMap { state -> FleetPeerKey? in
            switch state {
            case let .ready(snapshot), let .stale(snapshot, _):
                return FleetPeerKey(snapshot: snapshot)
            case .unavailable:
                return nil
            }
        }).count
    }

    private var accessibilityLabel: String {
        let branch: String
        let dirty: String
        switch card.primaryGitState {
        case let .ready(snapshot), let .stale(snapshot, _):
            branch = snapshot.branchHead
            dirty = snapshot.changedEntryCount == 0
                ? l10n.fleetClean
                : l10n.fleetDirtyCount(snapshot.changedEntryCount)
        case .unavailable, .none:
            branch = l10n.fleetUnavailable
            dirty = l10n.fleetUnavailable
        }

        return l10n.fleetCardAccessibility(
            root.displayTitle,
            root.provider.accessibilityName,
            l10n.fleetAttention(card.primaryAttention),
            branch,
            dirty,
            l10n.fleetOverlapCount(overlapSections.count)
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct FleetGitSummaryView: View {
    @ObservedObject private var l10n = L10n.shared

    let state: GitSnapshotState?
    let worktreeCount: Int

    var body: some View {
        switch state {
        case let .ready(snapshot):
            summary(snapshot: snapshot, isStale: false)
        case let .stale(snapshot, _):
            summary(snapshot: snapshot, isStale: true)
        case let .unavailable(failure):
            unavailable(failure)
        case nil:
            statusLabel(
                l10n.fleetWorkspaceUnavailable,
                symbol: "folder.badge.questionmark",
                color: .secondary
            )
        }
    }

    private func summary(
        snapshot: GitWorktreeSnapshot,
        isStale: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label(snapshot.branchHead, systemImage: "arrow.triangle.branch")
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if isStale {
                    statusLabel(
                        l10n.fleetStale,
                        symbol: "clock.badge.exclamationmark",
                        color: .orange
                    )
                }
                if snapshot.hasUnmergedEntries {
                    statusLabel(
                        l10n.fleetUnmerged,
                        symbol: "exclamationmark.triangle.fill",
                        color: .red
                    )
                }
            }

            HStack(spacing: 8) {
                Label(
                    snapshot.worktreeID.topLevelPath.fleetLastPathComponent,
                    systemImage: "folder"
                )
                .lineLimit(1)
                .truncationMode(.middle)

                if snapshot.changedEntryCount == 0 {
                    statusLabel(l10n.fleetClean, symbol: "checkmark.circle.fill", color: .green)
                } else {
                    statusLabel(
                        l10n.fleetDirtyCount(snapshot.changedEntryCount),
                        symbol: "pencil.circle.fill",
                        color: .orange
                    )
                }

                if worktreeCount > 1 {
                    statusLabel(
                        l10n.fleetWorktreesCount(worktreeCount),
                        symbol: "square.stack.3d.up.fill",
                        color: .blue
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func unavailable(_ failure: GitSnapshotFailure) -> some View {
        switch failure {
        case .missingWorkspace:
            statusLabel(
                l10n.fleetWorkspaceUnavailable,
                symbol: "folder.badge.questionmark",
                color: .secondary
            )
        case .notRepository:
            statusLabel(
                l10n.fleetNotRepository,
                symbol: "arrow.triangle.branch",
                color: .secondary
            )
        case .timedOut, .outputTooLarge, .launchFailed, .commandFailed, .malformedOutput:
            statusLabel(
                l10n.fleetGitContextUnavailable,
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )
        }
    }

    private func statusLabel(
        _ text: String,
        symbol: String,
        color: Color
    ) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

private struct FleetAttentionBadge: View {
    @ObservedObject private var l10n = L10n.shared

    let kind: FleetAttentionKind
    let isPrimary: Bool

    var body: some View {
        Label(l10n.fleetAttention(kind), systemImage: kind.fleetSymbol)
            .font(isPrimary ? .caption.weight(.semibold) : .caption2)
            .foregroundStyle(kind.fleetColor)
            .padding(.horizontal, isPrimary ? 7 : 5)
            .padding(.vertical, isPrimary ? 3 : 2)
            .background(kind.fleetColor.opacity(0.12))
            .clipShape(Capsule())
            .fixedSize()
    }
}

private struct FleetOverlapSummary: View {
    @ObservedObject private var l10n = L10n.shared

    let sections: [FleetOverlapSection]
    @Binding var showsPopover: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(l10n.fleetOverlapRisk, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            if let first = sections.first {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(first.peerTitle)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text("\(first.peerBranch) • \(first.peerWorktreeName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(l10n.fleetFilesCount(first.paths.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if sections.count > 1 {
                Text(l10n.fleetMoreOverlaps(sections.count - 1))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showsPopover = true
        }
        .help(l10n.fleetOverlapDetailsHelp)
        .accessibilityHidden(true)
        .popover(isPresented: $showsPopover, arrowEdge: Edge.trailing) {
            FleetOverlapPopover(sections: sections)
        }
    }
}

private struct FleetOverlapPopover: View {
    @ObservedObject private var l10n = L10n.shared

    let sections: [FleetOverlapSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.fleetOverlapDetails)
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(section.peerTitle)
                                .font(.callout.weight(.semibold))
                            Text("\(section.peerBranch) • \(section.peerWorktreeName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(Array(section.paths.prefix(20)), id: \.self) { path in
                                Text(path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if section.paths.count > 20 {
                                Text(l10n.fleetMoreFiles(section.paths.count - 20))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Label(
                l10n.fleetOverlapDisclaimer,
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 420, height: 460, alignment: .topLeading)
    }
}

private struct FleetSubagentRow: View {
    @ObservedObject private var l10n = L10n.shared

    let session: FleetSessionDescriptor

    private var attention: FleetAttentionKind {
        if session.isPending || session.hasMissedApproval {
            return .needsDecision
        }
        switch session.status {
        case .policyDenied, .timeoutBypassed:
            return .blocked
        case .idle, .pending, .autoApproved, .policyApproved:
            break
        }
        return session.isUnread ? .unread : .live
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: session.provider.fleetSymbol)
                .foregroundStyle(session.provider.accentColor)
                .accessibilityHidden(true)

            Text(session.displayTitle)
                .font(.caption)
                .lineLimit(1)

            Spacer(minLength: 4)

            Circle()
                .fill(attention.fleetColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Image(systemName: attention.fleetSymbol)
                .font(.caption2)
                .foregroundStyle(attention.fleetColor)
                .accessibilityHidden(true)
            Text(l10n.fleetAttention(attention))
                .font(.caption2)
                .foregroundStyle(attention.fleetColor)

            FleetRelativeTimeView(date: session.lastActiveAt)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FleetRelativeTimeView: View {
    @ObservedObject private var l10n = L10n.shared

    let date: Date
    var prefix: String?

    init(date: Date, prefix: String? = nil) {
        self.date = date
        self.prefix = prefix
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let relative = relativeText(now: context.date)
            Text(prefix.map { "\($0) \(relative)" } ?? relative)
                .font(.caption2)
                .lineLimit(1)
        }
    }

    private func relativeText(now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: l10n.isKorean ? "ko_KR" : "en_US")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

private struct FleetPeerKey: Hashable {
    let repositoryPath: String
    let worktreePath: String

    init(snapshot: GitWorktreeSnapshot) {
        repositoryPath = snapshot.repositoryID.commonGitDirectory
        worktreePath = snapshot.worktreeID.topLevelPath
    }

    init(repositoryID: GitRepositoryID, worktreeID: GitWorktreeID) {
        repositoryPath = repositoryID.commonGitDirectory
        worktreePath = worktreeID.topLevelPath
    }
}

private struct FleetOverlapPairKey: Hashable {
    let repositoryPath: String
    let firstWorktreePath: String
    let secondWorktreePath: String

    init(peer: FleetOverlapPeer) {
        repositoryPath = peer.repositoryID.commonGitDirectory
        firstWorktreePath = min(
            peer.localWorktreeID.topLevelPath,
            peer.peerWorktreeID.topLevelPath
        )
        secondWorktreePath = max(
            peer.localWorktreeID.topLevelPath,
            peer.peerWorktreeID.topLevelPath
        )
    }
}

private struct FleetOverlapSection: Identifiable {
    let peerKey: FleetPeerKey
    let peerTitle: String
    let peerBranch: String
    let peerWorktreeName: String
    let paths: [String]

    var id: FleetPeerKey { peerKey }

    static func make(
        from overlaps: [FleetOverlapPeer],
        peerTitles: [FleetPeerKey: String]
    ) -> [FleetOverlapSection] {
        struct Accumulator {
            let branch: String
            var paths: Set<String>
        }

        var byPeer: [FleetPeerKey: Accumulator] = [:]
        for overlap in overlaps {
            let key = FleetPeerKey(
                repositoryID: overlap.repositoryID,
                worktreeID: overlap.peerWorktreeID
            )
            if byPeer[key] == nil {
                byPeer[key] = Accumulator(branch: overlap.peerBranch, paths: [])
            }
            byPeer[key]?.paths.formUnion(overlap.paths)
        }

        return byPeer.map { key, accumulator in
            FleetOverlapSection(
                peerKey: key,
                peerTitle: peerTitles[key] ?? key.worktreePath.fleetLastPathComponent,
                peerBranch: accumulator.branch,
                peerWorktreeName: key.worktreePath.fleetLastPathComponent,
                paths: accumulator.paths.sorted()
            )
        }.sorted { lhs, rhs in
            let titleOrder = lhs.peerTitle.localizedStandardCompare(rhs.peerTitle)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            if lhs.peerBranch != rhs.peerBranch {
                return lhs.peerBranch < rhs.peerBranch
            }
            return lhs.peerKey.worktreePath < rhs.peerKey.worktreePath
        }
    }
}

private extension BuddyKind {
    var fleetSymbol: String {
        switch self {
        case .claudeCode: return "c.circle.fill"
        case .codex: return "o.circle.fill"
        case .gemini: return "g.circle.fill"
        case .antigravity: return "a.circle.fill"
        case .island: return "circle.fill"
        }
    }
}

private extension FleetAttentionKind {
    var fleetSymbol: String {
        switch self {
        case .needsDecision: return "hand.raised.fill"
        case .blocked: return "xmark.octagon.fill"
        case .overlapRisk: return "exclamationmark.triangle.fill"
        case .unread: return "circle.fill"
        case .live: return "waveform.path.ecg"
        }
    }

    var fleetColor: Color {
        switch self {
        case .needsDecision: return .orange
        case .blocked: return .red
        case .overlapRisk: return .orange
        case .unread: return .blue
        case .live: return .green
        }
    }
}

private extension String {
    var fleetLastPathComponent: String {
        let trimmed = trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? self
    }
}
