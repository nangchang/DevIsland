import XCTest
@testable import DevIsland

final class FleetRadarModelsTests: XCTestCase {
    func testGitSnapshotStatesUseValueEquality() {
        let snapshot = makeSnapshot()

        XCTAssertEqual(GitSnapshotState.ready(snapshot), .ready(makeSnapshot()))
        XCTAssertEqual(
            GitSnapshotState.stale(snapshot, .timedOut),
            .stale(makeSnapshot(), .timedOut)
        )
        XCTAssertEqual(
            GitSnapshotState.unavailable(.notRepository),
            .unavailable(.notRepository)
        )
        XCTAssertNotEqual(GitSnapshotState.ready(snapshot), .stale(snapshot, .timedOut))
        XCTAssertNotEqual(
            GitSnapshotState.unavailable(.notRepository),
            .unavailable(.commandFailed)
        )
    }

    func testFleetCardModelsUseValueEqualityAndForwardGroupID() {
        let first = makeCard()
        let second = makeCard()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id, "session-root")
        XCTAssertEqual(first.group.id, "session-root")
        XCTAssertNotEqual(
            first,
            FleetCardModel(
                group: first.group,
                gitStates: first.gitStates,
                primaryGitState: first.primaryGitState,
                overlaps: first.overlaps,
                primaryAttention: .blocked,
                secondaryAttention: first.secondaryAttention
            )
        )
        XCTAssertNotEqual(
            first,
            FleetCardModel(
                group: first.group,
                gitStates: first.gitStates,
                primaryGitState: nil,
                overlaps: first.overlaps,
                primaryAttention: first.primaryAttention,
                secondaryAttention: first.secondaryAttention
            )
        )
    }

    func testOverlapPeerIDIsStableForEquivalentValues() {
        let peer = makeOverlapPeer()
        let equivalentPeer = makeOverlapPeer()

        XCTAssertEqual(peer.id, equivalentPeer.id)
        XCTAssertEqual(Set([peer.id, equivalentPeer.id]).count, 1)
    }

    func testOverlapPeerIDDistinguishesRepositoryAndDirectionalWorktreePair() {
        let peer = makeOverlapPeer()
        let otherRepository = FleetOverlapPeer(
            repositoryID: GitRepositoryID(commonGitDirectory: "/repo-b/.git"),
            localWorktreeID: peer.localWorktreeID,
            peerWorktreeID: peer.peerWorktreeID,
            peerBranch: peer.peerBranch,
            paths: peer.paths
        )
        let otherLocalWorktree = FleetOverlapPeer(
            repositoryID: peer.repositoryID,
            localWorktreeID: GitWorktreeID(topLevelPath: "/repo/worktree-c"),
            peerWorktreeID: peer.peerWorktreeID,
            peerBranch: peer.peerBranch,
            paths: peer.paths
        )
        let otherPeerWorktree = FleetOverlapPeer(
            repositoryID: peer.repositoryID,
            localWorktreeID: peer.localWorktreeID,
            peerWorktreeID: GitWorktreeID(topLevelPath: "/repo/worktree-c"),
            peerBranch: peer.peerBranch,
            paths: peer.paths
        )
        let reversedPair = FleetOverlapPeer(
            repositoryID: peer.repositoryID,
            localWorktreeID: peer.peerWorktreeID,
            peerWorktreeID: peer.localWorktreeID,
            peerBranch: "main",
            paths: peer.paths
        )

        XCTAssertNotEqual(peer.id, otherRepository.id)
        XCTAssertNotEqual(peer.id, otherLocalWorktree.id)
        XCTAssertNotEqual(peer.id, otherPeerWorktree.id)
        XCTAssertNotEqual(peer.id, reversedPair.id)
    }

    func testAttentionRawPrioritiesAreStable() {
        XCTAssertEqual(FleetAttentionKind.needsDecision.rawValue, 0)
        XCTAssertEqual(FleetAttentionKind.blocked.rawValue, 1)
        XCTAssertEqual(FleetAttentionKind.overlapRisk.rawValue, 2)
        XCTAssertEqual(FleetAttentionKind.unread.rawValue, 3)
        XCTAssertEqual(FleetAttentionKind.live.rawValue, 4)
    }

    func testCardReportsStaleOverlapEvidenceFromEitherDirection() {
        let peer = makeOverlapPeer()
        let localStale = FleetOverlapPeer(
            repositoryID: peer.repositoryID,
            localWorktreeID: peer.localWorktreeID,
            peerWorktreeID: peer.peerWorktreeID,
            peerBranch: peer.peerBranch,
            paths: peer.paths,
            localIsStale: true
        )
        let peerStale = FleetOverlapPeer(
            repositoryID: peer.repositoryID,
            localWorktreeID: peer.localWorktreeID,
            peerWorktreeID: peer.peerWorktreeID,
            peerBranch: peer.peerBranch,
            paths: peer.paths,
            peerIsStale: true
        )

        XCTAssertFalse(makeCard(overlaps: [peer]).hasStaleOverlapEvidence)
        XCTAssertTrue(makeCard(overlaps: [localStale]).hasStaleOverlapEvidence)
        XCTAssertTrue(makeCard(overlaps: [peerStale]).hasStaleOverlapEvidence)
        XCTAssertNotEqual(localStale, peerStale)
    }

    func testNotchSummaryUsesPrimarySnapshotAndOverlapState() throws {
        let summary = try XCTUnwrap(makeCard().notchSummary)

        XCTAssertEqual(summary.branchHead, "main")
        XCTAssertEqual(summary.changedEntryCount, 2)
        XCTAssertFalse(summary.hasUnmergedEntries)
        XCTAssertTrue(summary.hasOverlap)
        XCTAssertFalse(summary.isPrimaryStale)
        XCTAssertFalse(summary.hasStaleOverlapEvidence)
    }

    func testNotchSummaryKeepsPrimaryAndOverlapStalenessDistinct() throws {
        let snapshot = makeSnapshot()
        let primaryStale = replacingPrimaryState(
            in: makeCard(overlaps: []),
            with: .stale(snapshot, .timedOut)
        )
        let overlapStale = replacingPrimaryState(
            in: makeCard(overlaps: [
                FleetOverlapPeer(
                    repositoryID: GitRepositoryID(commonGitDirectory: "/repo/.git"),
                    localWorktreeID: snapshot.worktreeID,
                    peerWorktreeID: GitWorktreeID(topLevelPath: "/repo/worktree-b"),
                    peerBranch: "feature/b",
                    paths: ["README.md"],
                    peerIsStale: true
                ),
            ]),
            with: .ready(snapshot)
        )

        let primarySummary = try XCTUnwrap(primaryStale.notchSummary)
        XCTAssertTrue(primarySummary.isPrimaryStale)
        XCTAssertFalse(primarySummary.hasStaleOverlapEvidence)

        let overlapSummary = try XCTUnwrap(overlapStale.notchSummary)
        XCTAssertFalse(overlapSummary.isPrimaryStale)
        XCTAssertTrue(overlapSummary.hasStaleOverlapEvidence)
    }

    func testNotchSummaryPreservesCleanUnmergedAndDetachedValues() throws {
        let cleanSnapshot = makeSnapshot(
            branchHead: "detached@01234567",
            changedPaths: [],
            changedEntryCount: 0
        )
        let unmergedSnapshot = makeSnapshot(hasUnmergedEntries: true)

        let cleanSummary = try XCTUnwrap(
            replacingPrimaryState(in: makeCard(), with: .ready(cleanSnapshot)).notchSummary
        )
        XCTAssertEqual(cleanSummary.branchHead, "detached@01234567")
        XCTAssertEqual(cleanSummary.changedEntryCount, 0)

        let unmergedSummary = try XCTUnwrap(
            replacingPrimaryState(in: makeCard(), with: .ready(unmergedSnapshot)).notchSummary
        )
        XCTAssertTrue(unmergedSummary.hasUnmergedEntries)
    }

    func testNotchSummaryIsUnavailableWithoutUsablePrimarySnapshot() {
        XCTAssertNil(replacingPrimaryState(in: makeCard(), with: nil).notchSummary)
        XCTAssertNil(
            replacingPrimaryState(
                in: makeCard(),
                with: .unavailable(.notRepository)
            ).notchSummary
        )
    }

    func testNotchPresentationMapsOnlyRootsAndHidesCompactSummaries() {
        let root = makeCard(rootID: "root")
        let child = makeDescriptor(id: "child", parentSessionID: "root")
        let grouped = replacingGroup(
            in: root,
            with: FleetSessionGroup(root: root.group.root, children: [child], isOrphan: false)
        )
        let orphan = makeCard(
            rootID: "orphan",
            parentSessionID: "missing-parent",
            isOrphan: true
        )

        let expanded = FleetNotchSummaryPresentation.summariesBySessionID(
            from: [grouped, orphan],
            compact: false
        )
        XCTAssertEqual(Set(expanded.keys), ["root", "orphan"])
        XCTAssertNil(expanded["child"])
        XCTAssertTrue(
            FleetNotchSummaryPresentation.summariesBySessionID(
                from: [grouped, orphan],
                compact: true
            ).isEmpty
        )
    }

    private func makeSnapshot(
        branchHead: String = "main",
        changedPaths: Set<String> = ["Sources/App.swift", "README.md"],
        changedEntryCount: Int = 2,
        hasUnmergedEntries: Bool = false
    ) -> GitWorktreeSnapshot {
        GitWorktreeSnapshot(
            repositoryID: GitRepositoryID(commonGitDirectory: "/repo/.git"),
            worktreeID: GitWorktreeID(topLevelPath: "/repo/worktree-a"),
            branchHead: branchHead,
            headOID: "0123456789abcdef",
            changedPaths: changedPaths,
            changedEntryCount: changedEntryCount,
            hasUnmergedEntries: hasUnmergedEntries,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeOverlapPeer() -> FleetOverlapPeer {
        FleetOverlapPeer(
            repositoryID: GitRepositoryID(commonGitDirectory: "/repo-a/.git"),
            localWorktreeID: GitWorktreeID(topLevelPath: "/repo/worktree-a"),
            peerWorktreeID: GitWorktreeID(topLevelPath: "/repo/worktree-b"),
            peerBranch: "feature/b",
            paths: ["Sources/App.swift"]
        )
    }

    private func makeDescriptor(
        id: String,
        parentSessionID: String?
    ) -> FleetSessionDescriptor {
        FleetSessionDescriptor(
            id: id,
            parentSessionID: parentSessionID,
            provider: .codex,
            displayTitle: "Fleet task",
            terminalTitle: "codex",
            workspaceRoot: "/repo/worktree-a",
            lastEventName: "Stop",
            lastToolName: "Bash",
            lastMessage: "Done",
            lastActiveAt: Date(timeIntervalSince1970: 2_000),
            isPending: false,
            hasMissedApproval: false,
            isUnread: true,
            status: .idle
        )
    }

    private func makeCard(
        overlaps: [FleetOverlapPeer]? = nil,
        rootID: String = "session-root",
        parentSessionID: String? = nil,
        isOrphan: Bool = false
    ) -> FleetCardModel {
        let root = makeDescriptor(id: rootID, parentSessionID: parentSessionID)
        let group = FleetSessionGroup(root: root, children: [], isOrphan: isOrphan)

        return FleetCardModel(
            group: group,
            gitStates: ["/repo/worktree-a": .ready(makeSnapshot())],
            primaryGitState: .ready(makeSnapshot()),
            overlaps: overlaps ?? [makeOverlapPeer()],
            primaryAttention: .unread,
            secondaryAttention: [.overlapRisk]
        )
    }

    private func replacingGroup(
        in card: FleetCardModel,
        with group: FleetSessionGroup
    ) -> FleetCardModel {
        FleetCardModel(
            group: group,
            gitStates: card.gitStates,
            primaryGitState: card.primaryGitState,
            overlaps: card.overlaps,
            primaryAttention: card.primaryAttention,
            secondaryAttention: card.secondaryAttention
        )
    }

    private func replacingPrimaryState(
        in card: FleetCardModel,
        with primaryGitState: GitSnapshotState?
    ) -> FleetCardModel {
        FleetCardModel(
            group: card.group,
            gitStates: card.gitStates,
            primaryGitState: primaryGitState,
            overlaps: card.overlaps,
            primaryAttention: card.primaryAttention,
            secondaryAttention: card.secondaryAttention
        )
    }
}
