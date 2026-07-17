import Foundation
import os

protocol GitContextScanning: Sendable {
    func states(
        for workspaceRoots: Set<String>,
        forceRefresh: Bool
    ) async -> [String: GitSnapshotState]
}

protocol GitContextClock: Sendable {
    func now() -> Date
    func monotonicNow() -> TimeInterval
}

private struct SystemGitContextClock: GitContextClock {
    func now() -> Date { Date() }
    func monotonicNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

private struct GitRootIdentity: Sendable {
    let repositoryID: GitRepositoryID
    let worktreeID: GitWorktreeID

    var snapshotCacheKey: GitSnapshotCacheKey {
        GitSnapshotCacheKey(repositoryID: repositoryID, worktreeID: worktreeID)
    }
}

private struct GitSnapshotCacheKey: Hashable, Sendable {
    let repositoryID: GitRepositoryID
    let worktreeID: GitWorktreeID
}

private enum GitRootIdentificationResult: Sendable {
    case identified(GitRootIdentity)
    case failed(GitSnapshotFailure)
}

private struct GitRootResolution: Sendable {
    let result: GitRootIdentificationResult
    let previousIdentity: GitRootIdentity?
}

private struct CachedGitRootIdentification: Sendable {
    let result: GitRootIdentificationResult
    let capturedAt: TimeInterval
    var lastAccessedAt: TimeInterval
    let lastSuccessfulIdentity: GitRootIdentity?
}

private struct CachedGitSnapshot: Sendable {
    let state: GitSnapshotState
    let capturedAt: TimeInterval
    var lastAccessedAt: TimeInterval
}

private struct GitWorkspaceRequest: Sendable {
    let key: String
    let directory: URL?
}

private enum GitSnapshotBuildResult: Sendable {
    case success(GitWorktreeSnapshot)
    case failure(GitSnapshotFailure)
}

private actor GitScanConcurrencyLimiter {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = limit
    }

    func run(
        _ operation: @escaping @Sendable () async -> GitCommandResult
    ) async -> GitCommandResult {
        await acquire()
        let result = await operation()
        release()
        return result
    }

    private func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

actor GitContextService: GitContextScanning {
    static let shared = GitContextService()

    private static let snapshotTTL: TimeInterval = 2
    private static let cacheRetention: TimeInterval = 10 * 60
    private static let maximumConcurrentScans = 4
    private static let revParseArguments = [
        "rev-parse",
        "--path-format=absolute",
        "--show-toplevel",
        "--git-common-dir",
    ]
    private static let statusArguments = [
        "-c",
        "core.fsmonitor=false",
        "status",
        "--porcelain=v2",
        "--branch",
        "-z",
        "--untracked-files=all",
        "--no-ahead-behind",
    ]

    private let runner: any GitCommandRunning
    private let clock: any GitContextClock
    private let limiter: GitScanConcurrencyLimiter
    private let snapshotInFlightObserver: (@Sendable () -> Void)?
    private var snapshotCache: [GitSnapshotCacheKey: CachedGitSnapshot] = [:]
    private var rootCache: [String: CachedGitRootIdentification] = [:]
    private var identificationInFlight: [
        String: Task<GitRootIdentificationResult, Never>
    ] = [:]
    private var snapshotInFlight: [
        GitSnapshotCacheKey: Task<GitSnapshotState, Never>
    ] = [:]

    init(
        runner: any GitCommandRunning = FoundationGitCommandRunner(),
        clock: any GitContextClock = SystemGitContextClock(),
        snapshotInFlightObserver: (@Sendable () -> Void)? = nil
    ) {
        self.runner = runner
        self.clock = clock
        self.snapshotInFlightObserver = snapshotInFlightObserver
        limiter = GitScanConcurrencyLimiter(limit: Self.maximumConcurrentScans)
    }

    func states(
        for workspaceRoots: Set<String>,
        forceRefresh: Bool = false
    ) async -> [String: GitSnapshotState] {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let monotonicNow = clock.monotonicNow()
        pruneCaches(now: monotonicNow)

        let requests = Self.normalizedRequests(for: workspaceRoots)
        var output: [String: GitSnapshotState] = [:]
        let validRequests = requests.filter { request in
            guard request.directory != nil else {
                output[request.key] = .unavailable(.missingWorkspace)
                return false
            }
            return true
        }

        let resolutions = await resolveIdentifications(
            validRequests,
            forceRefresh: forceRefresh
        )
        var identitiesByCacheKey: [GitSnapshotCacheKey: GitRootIdentity] = [:]
        for request in validRequests {
            guard let resolution = resolutions[request.key] else { continue }
            if case let .identified(identity) = resolution.result {
                identitiesByCacheKey[identity.snapshotCacheKey] = identity
            }
        }

        let snapshots = await resolveSnapshots(
            Array(identitiesByCacheKey.values).sorted {
                if $0.worktreeID.topLevelPath != $1.worktreeID.topLevelPath {
                    return $0.worktreeID.topLevelPath < $1.worktreeID.topLevelPath
                }
                return $0.repositoryID.commonGitDirectory
                    < $1.repositoryID.commonGitDirectory
            },
            forceRefresh: forceRefresh
        )

        for request in validRequests {
            guard let resolution = resolutions[request.key] else { continue }
            switch resolution.result {
            case let .identified(identity):
                output[request.key] = snapshots[identity.snapshotCacheKey]
                    ?? .unavailable(.commandFailed)
            case let .failed(failure):
                output[request.key] = staleFallback(
                    for: resolution.previousIdentity,
                    failure: failure,
                    now: clock.monotonicNow()
                )
            }
        }

        var staleCount = 0
        var unavailableCount = 0
        var failureCounts: [String: Int] = [:]
        var operationalFailureCount = 0
        for state in output.values {
            let failure: GitSnapshotFailure?
            switch state {
            case .ready:
                failure = nil
            case let .stale(_, staleFailure):
                staleCount += 1
                failure = staleFailure
            case let .unavailable(unavailableFailure):
                unavailableCount += 1
                failure = unavailableFailure
            }
            if let failure {
                failureCounts[Self.failureLabel(failure), default: 0] += 1
                if failure != .missingWorkspace, failure != .notRepository {
                    operationalFailureCount += 1
                }
            }
        }
        let failureSummary = failureCounts.isEmpty
            ? "none"
            : failureCounts.keys.sorted().map {
                "\($0)=\(failureCounts[$0, default: 0])"
            }.joined(separator: ",")
        let elapsedMilliseconds = Int(
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        )
        if operationalFailureCount > 0 {
            Log.fleet.error(
                "Git context scan roots=\(workspaceRoots.count, privacy: .public) stale=\(staleCount, privacy: .public) unavailable=\(unavailableCount, privacy: .public) failures=\(failureSummary, privacy: .public) elapsed_ms=\(elapsedMilliseconds, privacy: .public)"
            )
        } else {
            Log.fleet.debug(
                "Git context scan roots=\(workspaceRoots.count, privacy: .public) stale=\(staleCount, privacy: .public) unavailable=\(unavailableCount, privacy: .public) failures=\(failureSummary, privacy: .public) elapsed_ms=\(elapsedMilliseconds, privacy: .public)"
            )
        }
        return output
    }

    private func resolveIdentifications(
        _ requests: [GitWorkspaceRequest],
        forceRefresh: Bool
    ) async -> [String: GitRootResolution] {
        var results: [String: GitRootResolution] = [:]
        for start in stride(from: 0, to: requests.count, by: Self.maximumConcurrentScans) {
            let end = min(start + Self.maximumConcurrentScans, requests.count)
            let chunk = Array(requests[start..<end])
            await withTaskGroup(of: (String, GitRootResolution).self) { group in
                for request in chunk {
                    group.addTask {
                        let result = await self.identification(
                            for: request,
                            forceRefresh: forceRefresh
                        )
                        return (request.key, result)
                    }
                }
                for await (key, result) in group {
                    results[key] = result
                }
            }
        }
        return results
    }

    private func identification(
        for request: GitWorkspaceRequest,
        forceRefresh: Bool
    ) async -> GitRootResolution {
        guard let directory = request.directory else {
            return GitRootResolution(
                result: .failed(.missingWorkspace),
                previousIdentity: nil
            )
        }

        if let task = identificationInFlight[request.key] {
            let result = await task.value
            return GitRootResolution(
                result: result,
                previousIdentity: rootCache[request.key]?.lastSuccessfulIdentity
            )
        }

        let now = clock.monotonicNow()
        if !forceRefresh, var cached = rootCache[request.key] {
            let shouldReuse: Bool
            switch cached.result {
            case .identified:
                shouldReuse = true
            case .failed:
                shouldReuse = now - cached.capturedAt < Self.snapshotTTL
            }
            if shouldReuse {
                cached.lastAccessedAt = now
                rootCache[request.key] = cached
                return GitRootResolution(
                    result: cached.result,
                    previousIdentity: cached.lastSuccessfulIdentity
                )
            }
        }

        let previousIdentity = rootCache[request.key]?.lastSuccessfulIdentity
        let runner = runner
        let limiter = limiter
        let task = Task<GitRootIdentificationResult, Never> {
            let result = await limiter.run {
                await runner.run(
                    arguments: Self.revParseArguments,
                    currentDirectory: directory,
                    timeout: FoundationGitCommandRunner.defaultTimeout,
                    maxOutputBytes: FoundationGitCommandRunner.defaultMaxOutputBytes
                )
            }
            return Self.identificationResult(from: result)
        }
        identificationInFlight[request.key] = task
        let result = await task.value
        identificationInFlight.removeValue(forKey: request.key)

        let capturedAt = clock.monotonicNow()
        let successfulIdentity: GitRootIdentity?
        switch result {
        case let .identified(identity):
            successfulIdentity = identity
        case .failed:
            successfulIdentity = previousIdentity
        }
        rootCache[request.key] = CachedGitRootIdentification(
            result: result,
            capturedAt: capturedAt,
            lastAccessedAt: capturedAt,
            lastSuccessfulIdentity: successfulIdentity
        )
        return GitRootResolution(result: result, previousIdentity: previousIdentity)
    }

    private func resolveSnapshots(
        _ identities: [GitRootIdentity],
        forceRefresh: Bool
    ) async -> [GitSnapshotCacheKey: GitSnapshotState] {
        var results: [GitSnapshotCacheKey: GitSnapshotState] = [:]
        for start in stride(from: 0, to: identities.count, by: Self.maximumConcurrentScans) {
            let end = min(start + Self.maximumConcurrentScans, identities.count)
            let chunk = Array(identities[start..<end])
            await withTaskGroup(of: (GitSnapshotCacheKey, GitSnapshotState).self) { group in
                for identity in chunk {
                    group.addTask {
                        let state = await self.snapshot(
                            for: identity,
                            forceRefresh: forceRefresh
                        )
                        return (identity.snapshotCacheKey, state)
                    }
                }
                for await (cacheKey, state) in group {
                    results[cacheKey] = state
                }
            }
        }
        return results
    }

    private func snapshot(
        for identity: GitRootIdentity,
        forceRefresh: Bool
    ) async -> GitSnapshotState {
        let cacheKey = identity.snapshotCacheKey
        if let task = snapshotInFlight[cacheKey] {
            snapshotInFlightObserver?()
            return await task.value
        }

        let now = clock.monotonicNow()
        if !forceRefresh, var cached = snapshotCache[cacheKey],
           case .ready = cached.state,
           now - cached.capturedAt < Self.snapshotTTL {
            cached.lastAccessedAt = now
            snapshotCache[cacheKey] = cached
            return cached.state
        }

        let previous: GitWorktreeSnapshot?
        if var cached = snapshotCache[cacheKey],
           let cachedSnapshot = Self.previousSnapshot(from: cached.state) {
            cached.lastAccessedAt = now
            snapshotCache[cacheKey] = cached
            previous = cachedSnapshot
        } else {
            previous = nil
        }
        let runner = runner
        let limiter = limiter
        let clock = clock
        let task = Task<GitSnapshotState, Never> {
            let commandResult = await limiter.run {
                await runner.run(
                    arguments: Self.statusArguments,
                    currentDirectory: URL(fileURLWithPath: identity.worktreeID.topLevelPath),
                    timeout: FoundationGitCommandRunner.defaultTimeout,
                    maxOutputBytes: FoundationGitCommandRunner.defaultMaxOutputBytes
                )
            }
            switch Self.snapshotResult(
                from: commandResult,
                identity: identity,
                capturedAt: clock.now()
            ) {
            case let .success(snapshot):
                return .ready(snapshot)
            case let .failure(failure):
                if let previous {
                    return .stale(previous, failure)
                }
                return .unavailable(failure)
            }
        }
        snapshotInFlight[cacheKey] = task
        let state = await task.value
        snapshotInFlight.removeValue(forKey: cacheKey)

        let capturedAt = clock.monotonicNow()
        snapshotCache[cacheKey] = CachedGitSnapshot(
            state: state,
            capturedAt: capturedAt,
            lastAccessedAt: capturedAt
        )
        return state
    }

    private func staleFallback(
        for identity: GitRootIdentity?,
        failure: GitSnapshotFailure,
        now: TimeInterval
    ) -> GitSnapshotState {
        guard let identity,
              var cached = snapshotCache[identity.snapshotCacheKey],
              let previous = Self.previousSnapshot(from: cached.state) else {
            return .unavailable(failure)
        }
        cached.lastAccessedAt = now
        snapshotCache[identity.snapshotCacheKey] = cached
        return .stale(previous, failure)
    }

    private func pruneCaches(now: TimeInterval) {
        rootCache = rootCache.filter {
            now - $0.value.lastAccessedAt < Self.cacheRetention
        }
        snapshotCache = snapshotCache.filter {
            now - $0.value.lastAccessedAt < Self.cacheRetention
        }
    }

    private static func normalizedRequests(
        for workspaceRoots: Set<String>
    ) -> [GitWorkspaceRequest] {
        var requestsByKey: [String: GitWorkspaceRequest] = [:]
        for root in workspaceRoots.sorted() {
            guard !root.isEmpty, !root.contains("\0"), root.hasPrefix("/") else {
                requestsByKey[root] = GitWorkspaceRequest(key: root, directory: nil)
                continue
            }

            let canonicalURL = URL(fileURLWithPath: root)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let key = canonicalURL.path
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: key,
                isDirectory: &isDirectory
            )
            requestsByKey[key] = GitWorkspaceRequest(
                key: key,
                directory: exists && isDirectory.boolValue ? canonicalURL : nil
            )
        }
        return requestsByKey.values.sorted { $0.key < $1.key }
    }

    private static func identificationResult(
        from commandResult: GitCommandResult
    ) -> GitRootIdentificationResult {
        switch commandResult {
        case let .success(data):
            guard let identity = parseIdentification(data) else {
                return .failed(.malformedOutput)
            }
            return .identified(identity)
        case let .nonZeroExit(_, stderr):
            guard let message = String(data: stderr, encoding: .utf8) else {
                return .failed(.commandFailed)
            }
            return .failed(
                message.contains("not a git repository")
                    ? .notRepository
                    : .commandFailed
            )
        case .timedOut:
            return .failed(.timedOut)
        case .outputTooLarge:
            return .failed(.outputTooLarge)
        case .launchFailed:
            return .failed(.launchFailed)
        }
    }

    private static func parseIdentification(_ data: Data) -> GitRootIdentity? {
        guard data.last == Character("\n").asciiValue,
              let output = String(data: data, encoding: .utf8),
              !output.contains("\r"),
              !output.contains("\0") else {
            return nil
        }
        let withoutFinalLF = output.dropLast()
        let lines = withoutFinalLF.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.count == 2,
              lines.allSatisfy({ !$0.isEmpty && $0.hasPrefix("/") }) else {
            return nil
        }

        let topLevel = URL(fileURLWithPath: String(lines[0]))
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let commonGitDirectory = URL(fileURLWithPath: String(lines[1]))
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return GitRootIdentity(
            repositoryID: GitRepositoryID(commonGitDirectory: commonGitDirectory),
            worktreeID: GitWorktreeID(topLevelPath: topLevel)
        )
    }

    private static func snapshotResult(
        from commandResult: GitCommandResult,
        identity: GitRootIdentity,
        capturedAt: Date
    ) -> GitSnapshotBuildResult {
        switch commandResult {
        case let .success(data):
            do {
                let parsed = try GitStatusPorcelainV2Parser.parse(data)
                return .success(
                    GitWorktreeSnapshot(
                        repositoryID: identity.repositoryID,
                        worktreeID: identity.worktreeID,
                        branchHead: parsed.branchHead,
                        headOID: parsed.headOID,
                        changedPaths: parsed.changedPaths,
                        changedEntryCount: parsed.changedEntryCount,
                        hasUnmergedEntries: parsed.hasUnmergedEntries,
                        capturedAt: capturedAt
                    )
                )
            } catch {
                return .failure(.malformedOutput)
            }
        case .nonZeroExit:
            return .failure(.commandFailed)
        case .timedOut:
            return .failure(.timedOut)
        case .outputTooLarge:
            return .failure(.outputTooLarge)
        case .launchFailed:
            return .failure(.launchFailed)
        }
    }

    private static func previousSnapshot(
        from state: GitSnapshotState
    ) -> GitWorktreeSnapshot? {
        switch state {
        case let .ready(snapshot), let .stale(snapshot, _):
            return snapshot
        case .unavailable:
            return nil
        }
    }

    private static func failureLabel(_ failure: GitSnapshotFailure) -> String {
        switch failure {
        case .missingWorkspace: return "missingWorkspace"
        case .notRepository: return "notRepository"
        case .timedOut: return "timedOut"
        case .outputTooLarge: return "outputTooLarge"
        case .launchFailed: return "launchFailed"
        case .commandFailed: return "commandFailed"
        case .malformedOutput: return "malformedOutput"
        }
    }
}
