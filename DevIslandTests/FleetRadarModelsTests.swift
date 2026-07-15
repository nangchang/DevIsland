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

    private func makeSnapshot() -> GitWorktreeSnapshot {
        GitWorktreeSnapshot(
            repositoryID: GitRepositoryID(commonGitDirectory: "/repo/.git"),
            worktreeID: GitWorktreeID(topLevelPath: "/repo/worktree-a"),
            branchHead: "main",
            headOID: "0123456789abcdef",
            changedPaths: ["Sources/App.swift", "README.md"],
            changedEntryCount: 2,
            hasUnmergedEntries: false,
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

    private func makeCard() -> FleetCardModel {
        let root = FleetSessionDescriptor(
            id: "session-root",
            parentSessionID: nil,
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
        let group = FleetSessionGroup(root: root, children: [], isOrphan: false)

        return FleetCardModel(
            group: group,
            gitStates: ["/repo/worktree-a": .ready(makeSnapshot())],
            primaryGitState: .ready(makeSnapshot()),
            overlaps: [makeOverlapPeer()],
            primaryAttention: .unread,
            secondaryAttention: [.overlapRisk]
        )
    }
}
