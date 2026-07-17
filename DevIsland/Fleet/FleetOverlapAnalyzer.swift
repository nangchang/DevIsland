enum FleetOverlapAnalyzer {
    static func analyze(
        snapshots: [GitWorktreeSnapshot]
    ) -> [GitWorktreeID: [FleetOverlapPeer]] {
        let repositories = deduplicatedRepositories(from: snapshots)
        var overlaps: [GitWorktreeID: [FleetOverlapPeer]] = [:]

        for worktreesByID in repositories.values {
            let worktrees = worktreesByID.values.sorted {
                $0.worktreeID.topLevelPath < $1.worktreeID.topLevelPath
            }
            guard worktrees.count > 1 else { continue }

            for lhsIndex in 0..<(worktrees.count - 1) {
                for rhsIndex in (lhsIndex + 1)..<worktrees.count {
                    let lhs = worktrees[lhsIndex]
                    let rhs = worktrees[rhsIndex]
                    let paths = lhs.changedPaths.intersection(rhs.changedPaths).sorted()
                    guard !paths.isEmpty else { continue }

                    overlaps[lhs.worktreeID, default: []].append(
                        makePeer(local: lhs, peer: rhs, paths: paths)
                    )
                    overlaps[rhs.worktreeID, default: []].append(
                        makePeer(local: rhs, peer: lhs, paths: paths)
                    )
                }
            }
        }

        for worktreeID in Array(overlaps.keys) {
            overlaps[worktreeID]?.sort(by: peerComesBefore)
        }
        return overlaps
    }

    private static func deduplicatedRepositories(
        from snapshots: [GitWorktreeSnapshot]
    ) -> [GitRepositoryID: [GitWorktreeID: GitWorktreeSnapshot]] {
        var repositories: [GitRepositoryID: [GitWorktreeID: GitWorktreeSnapshot]] = [:]

        for snapshot in snapshots {
            if repositories[snapshot.repositoryID]?[snapshot.worktreeID] != nil {
                continue
            }
            repositories[snapshot.repositoryID, default: [:]][snapshot.worktreeID] = snapshot
        }

        return repositories
    }

    private static func makePeer(
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

    private static func peerComesBefore(_ lhs: FleetOverlapPeer, _ rhs: FleetOverlapPeer) -> Bool {
        if lhs.peerBranch != rhs.peerBranch {
            return lhs.peerBranch < rhs.peerBranch
        }
        return lhs.peerWorktreeID.topLevelPath < rhs.peerWorktreeID.topLevelPath
    }
}
