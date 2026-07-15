import Foundation

struct GitRepositoryID: Hashable, Sendable {
    let commonGitDirectory: String
}

struct GitWorktreeID: Hashable, Sendable {
    let topLevelPath: String
}

struct GitWorktreeSnapshot: Equatable, Sendable {
    let repositoryID: GitRepositoryID
    let worktreeID: GitWorktreeID
    let branchHead: String
    let headOID: String?
    let changedPaths: Set<String>
    let changedEntryCount: Int
    let hasUnmergedEntries: Bool
    let capturedAt: Date
}

enum GitSnapshotFailure: Equatable, Sendable {
    case missingWorkspace
    case notRepository
    case timedOut
    case outputTooLarge
    case launchFailed
    case commandFailed
    case malformedOutput
}

enum GitSnapshotState: Equatable, Sendable {
    case ready(GitWorktreeSnapshot)
    case stale(GitWorktreeSnapshot, GitSnapshotFailure)
    case unavailable(GitSnapshotFailure)
}

struct FleetOverlapID: Hashable, Sendable {
    let repositoryID: GitRepositoryID
    let localWorktreeID: GitWorktreeID
    let peerWorktreeID: GitWorktreeID
}

struct FleetOverlapPeer: Equatable, Identifiable, Sendable {
    let repositoryID: GitRepositoryID
    let localWorktreeID: GitWorktreeID
    let peerWorktreeID: GitWorktreeID
    let peerBranch: String
    let paths: [String]

    var id: FleetOverlapID {
        FleetOverlapID(
            repositoryID: repositoryID,
            localWorktreeID: localWorktreeID,
            peerWorktreeID: peerWorktreeID
        )
    }
}

enum FleetAttentionKind: Int, Hashable, Sendable {
    case needsDecision = 0
    case blocked = 1
    case overlapRisk = 2
    case unread = 3
    case live = 4
}

struct FleetSessionDescriptor: Equatable {
    let id: String
    let parentSessionID: String?
    let provider: BuddyKind
    let displayTitle: String
    let terminalTitle: String
    let workspaceRoot: String?
    let lastEventName: String
    let lastToolName: String
    let lastMessage: String
    let lastActiveAt: Date
    let isPending: Bool
    let hasMissedApproval: Bool
    let isUnread: Bool
    let status: SessionStatus
}

struct FleetSessionGroup: Identifiable, Equatable {
    let root: FleetSessionDescriptor
    let children: [FleetSessionDescriptor]
    let isOrphan: Bool

    var id: String { root.id }
}

struct FleetCardModel: Identifiable, Equatable {
    let group: FleetSessionGroup
    let gitStates: [String: GitSnapshotState]
    let primaryGitState: GitSnapshotState?
    let overlaps: [FleetOverlapPeer]
    let primaryAttention: FleetAttentionKind
    let secondaryAttention: Set<FleetAttentionKind>

    var id: String { group.id }
}
