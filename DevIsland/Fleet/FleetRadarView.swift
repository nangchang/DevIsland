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
