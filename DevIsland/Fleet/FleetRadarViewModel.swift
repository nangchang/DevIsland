import Combine
import Foundation

@MainActor
final class FleetRadarViewModel: ObservableObject {
    nonisolated static let defaultDebounceDuration: Duration = .milliseconds(350)

    @Published private(set) var cards: [FleetCardModel] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastCompletedAt: Date?

    private let scanner: any GitContextScanning
    private let debounceDuration: Duration
    private let refreshDiscardObserver: (@Sendable () -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var latestDescriptors: [FleetSessionDescriptor] = []
    private var latestWorkspaceRoots: Set<String> = []
    private var pendingForceRefresh = false

    init(
        scanner: any GitContextScanning = GitContextService.shared,
        debounceDuration: Duration = FleetRadarViewModel.defaultDebounceDuration,
        refreshDiscardObserver: (@Sendable () -> Void)? = nil
    ) {
        self.scanner = scanner
        self.debounceDuration = debounceDuration
        self.refreshDiscardObserver = refreshDiscardObserver
    }

    deinit {
        refreshTask?.cancel()
    }

    func update(
        sessions: [ActiveSession],
        labels: [String: String],
        forceRefresh: Bool = false
    ) {
        latestDescriptors = sessions.map { session in
            FleetSessionDescriptor(
                id: session.id,
                parentSessionID: session.parentSessionId,
                provider: session.agentKind,
                displayTitle: labels[session.id] ?? session.terminalTitle,
                terminalTitle: session.terminalTitle,
                workspaceRoot: session.workspaceRoot,
                lastEventName: session.lastEventName,
                lastToolName: session.lastToolName,
                lastMessage: session.lastMessage,
                lastActiveAt: session.lastActiveAt,
                isPending: session.isPending,
                hasMissedApproval: session.hasMissedApproval,
                isUnread: session.isUnread,
                status: session.status
            )
        }
        latestWorkspaceRoots = Self.workspaceRoots(in: latestDescriptors)
        pendingForceRefresh = pendingForceRefresh || forceRefresh

        generation = UUID()
        let refreshGeneration = generation
        let requestedRoots = latestWorkspaceRoots
        refreshTask?.cancel()

        guard !latestDescriptors.isEmpty else {
            refreshTask = nil
            pendingForceRefresh = false
            cards = []
            isRefreshing = false
            lastCompletedAt = nil
            return
        }

        isRefreshing = true
        let scanner = scanner
        let debounceDuration = debounceDuration
        let refreshDiscardObserver = refreshDiscardObserver
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounceDuration)
            } catch {
                return
            }

            let normalizedRoots = await Self.normalizeWorkspaceRoots(requestedRoots)
            guard let shouldForceRefresh = self?.consumePendingForceRefresh(
                generation: refreshGeneration,
                workspaceRoots: requestedRoots
            ) else {
                return
            }

            let states = await scanner.states(
                for: Set(normalizedRoots.values),
                forceRefresh: shouldForceRefresh
            )
            guard let self,
                  self.generation == refreshGeneration,
                  self.latestWorkspaceRoots == requestedRoots else {
                refreshDiscardObserver?()
                return
            }

            let groups = Self.groups(from: self.latestDescriptors)
            self.cards = Self.makeCards(
                groups: groups,
                normalizedRoots: normalizedRoots,
                states: states
            )
            self.lastCompletedAt = Date()
            self.isRefreshing = false
        }
    }

    private func consumePendingForceRefresh(
        generation refreshGeneration: UUID,
        workspaceRoots requestedRoots: Set<String>
    ) -> Bool? {
        guard generation == refreshGeneration,
              latestWorkspaceRoots == requestedRoots else {
            return nil
        }
        let shouldForceRefresh = pendingForceRefresh
        pendingForceRefresh = false
        return shouldForceRefresh
    }

    private static func workspaceRoots(
        in descriptors: [FleetSessionDescriptor]
    ) -> Set<String> {
        Set(descriptors.compactMap { descriptor in
            guard let root = descriptor.workspaceRoot, !root.isEmpty else { return nil }
            return root
        })
    }

    nonisolated private static func normalizeWorkspaceRoots(
        _ roots: Set<String>
    ) async -> [String: String] {
        await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: roots.map { root in
                guard root.hasPrefix("/"), !root.contains("\0") else {
                    return (root, root)
                }
                let normalized = URL(fileURLWithPath: root)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                return (root, normalized)
            })
        }.value
    }

    private static func groups(
        from descriptors: [FleetSessionDescriptor]
    ) -> [FleetSessionGroup] {
        let descriptorsByID = Dictionary(
            descriptors.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rootsByID: [String: (descriptor: FleetSessionDescriptor, isOrphan: Bool)] = [:]
        var childrenByRootID: [String: [FleetSessionDescriptor]] = [:]

        for descriptor in descriptors {
            let root = rootDescriptor(for: descriptor, in: descriptorsByID)
            rootsByID[root.descriptor.id] = root
            if root.descriptor.id != descriptor.id {
                childrenByRootID[root.descriptor.id, default: []].append(descriptor)
            }
        }

        return rootsByID.values.map { root in
            let children = childrenByRootID[root.descriptor.id, default: []].sorted {
                if $0.lastActiveAt != $1.lastActiveAt {
                    return $0.lastActiveAt > $1.lastActiveAt
                }
                return $0.id < $1.id
            }
            return FleetSessionGroup(
                root: root.descriptor,
                children: children,
                isOrphan: root.isOrphan
            )
        }
    }

    private static func rootDescriptor(
        for descriptor: FleetSessionDescriptor,
        in descriptorsByID: [String: FleetSessionDescriptor]
    ) -> (descriptor: FleetSessionDescriptor, isOrphan: Bool) {
        var current = descriptor
        var visited: Set<String> = [descriptor.id]

        while let parentID = current.parentSessionID {
            guard let parent = descriptorsByID[parentID] else {
                return (current, true)
            }
            guard visited.insert(parent.id).inserted else {
                return (descriptor, true)
            }
            current = parent
        }
        return (current, false)
    }

    private static func makeCards(
        groups: [FleetSessionGroup],
        normalizedRoots: [String: String],
        states: [String: GitSnapshotState]
    ) -> [FleetCardModel] {
        let snapshots = states.values.compactMap(snapshot(from:))
        let overlapsByWorktree = FleetOverlapAnalyzer.analyze(snapshots: snapshots)

        return groups.map { group in
            let groupKeys: Set<String> = Set(
                ([group.root] + group.children).compactMap { descriptor in
                    guard let root = descriptor.workspaceRoot, !root.isEmpty else { return nil }
                    return normalizedRoots[root]
                }
            )
            let groupStates = states.filter { groupKeys.contains($0.key) }
            let groupSnapshots = groupStates.values.compactMap(snapshot(from:))
            let overlaps = mergedOverlaps(
                for: groupSnapshots,
                overlapsByWorktree: overlapsByWorktree
            )
            let attentions = attentionKinds(
                group: group,
                states: groupStates.values,
                hasOverlap: !overlaps.isEmpty
            )
            let primary = attentions.min { $0.rawValue < $1.rawValue } ?? .live

            return FleetCardModel(
                group: group,
                gitStates: groupStates,
                primaryGitState: primaryGitState(
                    for: group,
                    normalizedRoots: normalizedRoots,
                    states: states
                ),
                overlaps: overlaps,
                primaryAttention: primary,
                secondaryAttention: attentions.subtracting([primary])
            )
        }.sorted(by: cardComesBefore)
    }

    private static func primaryGitState(
        for group: FleetSessionGroup,
        normalizedRoots: [String: String],
        states: [String: GitSnapshotState]
    ) -> GitSnapshotState? {
        if let root = group.root.workspaceRoot, !root.isEmpty {
            guard let key = normalizedRoots[root] else { return nil }
            return states[key]
        }

        for child in group.children {
            guard let root = child.workspaceRoot, !root.isEmpty,
                  let key = normalizedRoots[root],
                  let state = states[key] else {
                continue
            }
            return state
        }
        return nil
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

    private static func mergedOverlaps(
        for snapshots: [GitWorktreeSnapshot],
        overlapsByWorktree: [GitWorktreeID: [FleetOverlapPeer]]
    ) -> [FleetOverlapPeer] {
        var peersByID: [FleetOverlapID: FleetOverlapPeer] = [:]
        for snapshot in snapshots {
            for peer in overlapsByWorktree[snapshot.worktreeID, default: []] {
                peersByID[peer.id] = peer
            }
        }
        return peersByID.values.sorted(by: overlapComesBefore)
    }

    private static func overlapComesBefore(
        _ lhs: FleetOverlapPeer,
        _ rhs: FleetOverlapPeer
    ) -> Bool {
        if lhs.repositoryID.commonGitDirectory != rhs.repositoryID.commonGitDirectory {
            return lhs.repositoryID.commonGitDirectory < rhs.repositoryID.commonGitDirectory
        }
        if lhs.localWorktreeID.topLevelPath != rhs.localWorktreeID.topLevelPath {
            return lhs.localWorktreeID.topLevelPath < rhs.localWorktreeID.topLevelPath
        }
        if lhs.peerBranch != rhs.peerBranch {
            return lhs.peerBranch < rhs.peerBranch
        }
        return lhs.peerWorktreeID.topLevelPath < rhs.peerWorktreeID.topLevelPath
    }

    private static func attentionKinds(
        group: FleetSessionGroup,
        states: Dictionary<String, GitSnapshotState>.Values,
        hasOverlap: Bool
    ) -> Set<FleetAttentionKind> {
        let sessions = [group.root] + group.children
        var attentions: Set<FleetAttentionKind> = []

        if sessions.contains(where: { $0.isPending || $0.hasMissedApproval }) {
            attentions.insert(.needsDecision)
        }
        if sessions.contains(where: { descriptor in
            switch descriptor.status {
            case .policyDenied, .timeoutBypassed:
                return true
            case .idle, .pending, .autoApproved, .policyApproved:
                return false
            }
        }) || states.contains(where: { state in
            snapshot(from: state)?.hasUnmergedEntries == true
        }) {
            attentions.insert(.blocked)
        }
        if hasOverlap {
            attentions.insert(.overlapRisk)
        }
        if sessions.contains(where: \.isUnread) {
            attentions.insert(.unread)
        }
        if attentions.isEmpty {
            attentions.insert(.live)
        }
        return attentions
    }

    private static func cardComesBefore(
        _ lhs: FleetCardModel,
        _ rhs: FleetCardModel
    ) -> Bool {
        if lhs.primaryAttention.rawValue != rhs.primaryAttention.rawValue {
            return lhs.primaryAttention.rawValue < rhs.primaryAttention.rawValue
        }

        let lhsNewest = newestActivity(in: lhs.group)
        let rhsNewest = newestActivity(in: rhs.group)
        if lhsNewest != rhsNewest {
            return lhsNewest > rhsNewest
        }

        let titleOrder = lhs.group.root.displayTitle.localizedStandardCompare(
            rhs.group.root.displayTitle
        )
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        return lhs.group.root.id < rhs.group.root.id
    }

    private static func newestActivity(in group: FleetSessionGroup) -> Date {
        ([group.root] + group.children)
            .map(\.lastActiveAt)
            .max() ?? group.root.lastActiveAt
    }
}
