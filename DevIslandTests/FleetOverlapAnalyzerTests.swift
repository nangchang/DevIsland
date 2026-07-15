import XCTest
@testable import DevIsland

final class FleetOverlapAnalyzerTests: XCTestCase {
    func testSameRepositoryDifferentWorktreesWithSharedPathProduceDirectionalPeers() {
        let main = makeSnapshot(
            worktree: "/repo/main",
            branch: "main",
            paths: ["Sources/Shared.swift"]
        )
        let feature = makeSnapshot(
            worktree: "/repo/feature",
            branch: "feature/radar",
            paths: ["Sources/Shared.swift"]
        )

        let result = FleetOverlapAnalyzer.analyze(snapshots: [main, feature])

        XCTAssertEqual(
            result[main.worktreeID],
            [peer(local: main, peer: feature, paths: ["Sources/Shared.swift"])]
        )
        XCTAssertEqual(
            result[feature.worktreeID],
            [peer(local: feature, peer: main, paths: ["Sources/Shared.swift"])]
        )
    }

    func testSameRepositoryWithDifferentChangedPathsProducesNoOverlap() {
        let main = makeSnapshot(worktree: "/repo/main", branch: "main", paths: ["README.md"])
        let feature = makeSnapshot(
            worktree: "/repo/feature",
            branch: "feature/radar",
            paths: ["Sources/App.swift"]
        )

        XCTAssertEqual(FleetOverlapAnalyzer.analyze(snapshots: [main, feature]), [:])
    }

    func testDifferentRepositoriesWithSameChangedPathProduceNoOverlap() {
        let first = makeSnapshot(
            repository: "/repo-a/.git",
            worktree: "/repo-a/main",
            branch: "main",
            paths: ["Sources/App.swift"]
        )
        let second = makeSnapshot(
            repository: "/repo-b/.git",
            worktree: "/repo-b/main",
            branch: "main",
            paths: ["Sources/App.swift"]
        )

        XCTAssertEqual(FleetOverlapAnalyzer.analyze(snapshots: [first, second]), [:])
    }

    func testDuplicateSnapshotProducesOnePeerPerWorktreeRegardlessOfInputOrder() {
        let local = makeSnapshot(
            worktree: "/repo/main",
            branch: "main",
            paths: ["Sources/Shared.swift"]
        )
        let duplicate = local
        let feature = makeSnapshot(
            worktree: "/repo/feature",
            branch: "feature/radar",
            paths: ["Sources/Shared.swift"]
        )

        let forward = FleetOverlapAnalyzer.analyze(snapshots: [local, duplicate, feature])
        let reversed = FleetOverlapAnalyzer.analyze(snapshots: [feature, duplicate, local])

        XCTAssertEqual(reversed, forward)
        XCTAssertEqual(
            forward[local.worktreeID],
            [peer(local: local, peer: feature, paths: ["Sources/Shared.swift"])]
        )
        XCTAssertEqual(
            forward[feature.worktreeID],
            [peer(local: feature, peer: local, paths: ["Sources/Shared.swift"])]
        )
        XCTAssertEqual(forward.count, 2)
    }

    func testRenameOldPathOverlapsWithPeerModification() {
        let rename = makeSnapshot(
            worktree: "/repo/rename",
            branch: "feature/rename",
            paths: ["Sources/New.swift", "Sources/Old.swift"]
        )
        let edit = makeSnapshot(
            worktree: "/repo/edit",
            branch: "feature/edit",
            paths: ["Sources/Old.swift"]
        )

        let result = FleetOverlapAnalyzer.analyze(snapshots: [rename, edit])

        XCTAssertEqual(
            result[rename.worktreeID],
            [peer(local: rename, peer: edit, paths: ["Sources/Old.swift"])]
        )
    }

    func testStaleDerivedSnapshotCanBeAnalyzedWhenCallerIncludesIt() {
        let ready = makeSnapshot(
            worktree: "/repo/main",
            branch: "main",
            paths: ["Sources/App.swift"]
        )
        let stale = makeSnapshot(
            worktree: "/repo/feature",
            branch: "feature/radar",
            paths: ["Sources/App.swift"]
        )
        let state = GitSnapshotState.stale(stale, .timedOut)
        guard case let .stale(staleSnapshot, _) = state else {
            return XCTFail("Expected stale snapshot state")
        }

        let result = FleetOverlapAnalyzer.analyze(snapshots: [ready, staleSnapshot])

        XCTAssertEqual(
            result[ready.worktreeID],
            [peer(local: ready, peer: staleSnapshot, paths: ["Sources/App.swift"])]
        )
    }

    func testEmptyChangedPathsProduceNoOverlap() {
        let clean = makeSnapshot(worktree: "/repo/main", branch: "main", paths: [])
        let changed = makeSnapshot(
            worktree: "/repo/feature",
            branch: "feature/radar",
            paths: ["Sources/App.swift"]
        )

        XCTAssertEqual(FleetOverlapAnalyzer.analyze(snapshots: [clean, changed]), [:])
        XCTAssertEqual(FleetOverlapAnalyzer.analyze(snapshots: []), [:])
    }

    func testPeersAndPathsHaveDeterministicSortOrder() {
        let local = makeSnapshot(
            worktree: "/repo/a",
            branch: "local",
            paths: ["z.swift", "a.swift", "m.swift"]
        )
        let alphaB = makeSnapshot(
            worktree: "/repo/b",
            branch: "alpha",
            paths: ["z.swift", "a.swift", "m.swift"]
        )
        let alphaC = makeSnapshot(
            worktree: "/repo/c",
            branch: "alpha",
            paths: ["a.swift"]
        )
        let zeta = makeSnapshot(
            worktree: "/repo/z",
            branch: "zeta",
            paths: ["z.swift"]
        )

        let forward = FleetOverlapAnalyzer.analyze(
            snapshots: [zeta, alphaC, local, alphaB]
        )
        let reversed = FleetOverlapAnalyzer.analyze(
            snapshots: [alphaB, local, alphaC, zeta]
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(
            forward[local.worktreeID],
            [
                peer(local: local, peer: alphaB, paths: ["a.swift", "m.swift", "z.swift"]),
                peer(local: local, peer: alphaC, paths: ["a.swift"]),
                peer(local: local, peer: zeta, paths: ["z.swift"]),
            ]
        )
    }

    private func makeSnapshot(
        repository: String = "/repo/.git",
        worktree: String,
        branch: String,
        paths: Set<String>
    ) -> GitWorktreeSnapshot {
        GitWorktreeSnapshot(
            repositoryID: GitRepositoryID(commonGitDirectory: repository),
            worktreeID: GitWorktreeID(topLevelPath: worktree),
            branchHead: branch,
            headOID: "0123456789abcdef",
            changedPaths: paths,
            changedEntryCount: paths.count,
            hasUnmergedEntries: false,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func peer(
        local: GitWorktreeSnapshot,
        peer: GitWorktreeSnapshot,
        paths: [String]
    ) -> FleetOverlapPeer {
        FleetOverlapPeer(
            repositoryID: local.repositoryID,
            localWorktreeID: local.worktreeID,
            peerWorktreeID: peer.worktreeID,
            peerBranch: peer.branchHead,
            paths: paths
        )
    }
}
