import Darwin
import Foundation
import os

protocol GitCommandRunning: Sendable {
    func run(
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async -> GitCommandResult
}

enum GitCommandResult: Equatable, Sendable {
    case success(Data)
    case nonZeroExit(status: Int32, stderr: Data)
    case timedOut
    case outputTooLarge
    case launchFailed
}

struct GitProcessRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let environment: [String: String]
    let timeout: TimeInterval
    let maxOutputBytes: Int
}

enum GitProcessExecutionResult: Equatable, Sendable {
    case exited(status: Int32, stdout: Data, stderr: Data)
    case timedOut
    case outputTooLarge
    case launchFailed
}

protocol GitProcessExecuting: Sendable {
    func execute(_ request: GitProcessRequest) async -> GitProcessExecutionResult
}

enum GitCommandEnvironment {
    static func stable(from ambient: [String: String]) -> [String: String] {
        var environment = ambient.filter { !$0.key.hasPrefix("GIT_") }
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }
}

struct FoundationGitCommandRunner: GitCommandRunning {
    static let defaultTimeout: TimeInterval = 1.0
    static let defaultMaxOutputBytes = 1024 * 1024

    private let executor: any GitProcessExecuting

    init(executor: any GitProcessExecuting = FoundationGitProcessExecutor()) {
        self.executor = executor
    }

    func run(
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async -> GitCommandResult {
        let result = await executor.execute(
            GitProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: arguments,
                currentDirectoryURL: currentDirectory,
                environment: GitCommandEnvironment.stable(
                    from: ProcessInfo.processInfo.environment
                ),
                timeout: timeout,
                maxOutputBytes: maxOutputBytes
            )
        )

        switch result {
        case let .exited(status, stdout, _) where status == 0:
            return .success(stdout)
        case let .exited(status, _, stderr):
            return .nonZeroExit(status: status, stderr: stderr)
        case .timedOut:
            return .timedOut
        case .outputTooLarge:
            return .outputTooLarge
        case .launchFailed:
            return .launchFailed
        }
    }
}

struct FoundationGitProcessExecutor: GitProcessExecuting {
    typealias Operation = @Sendable (
        GitProcessRequest,
        GitProcessCancellation
    ) async -> GitProcessExecutionResult
    typealias TimeoutScheduler = @Sendable (
        TimeInterval,
        @escaping @Sendable () -> Void
    ) -> Void

    private let operation: Operation
    private let timeoutScheduler: TimeoutScheduler

    init() {
        operation = { request, cancellation in
            await Self.executeFoundationProcess(request, cancellation: cancellation)
        }
        timeoutScheduler = { timeout, action in
            Self.scheduleTimeout(after: timeout, action: action)
        }
    }

    init(
        operation: @escaping Operation,
        timeoutScheduler: @escaping TimeoutScheduler = { timeout, action in
            FoundationGitProcessExecutor.scheduleTimeout(after: timeout, action: action)
        }
    ) {
        self.operation = operation
        self.timeoutScheduler = timeoutScheduler
    }

    func execute(_ request: GitProcessRequest) async -> GitProcessExecutionResult {
        let cancellation = GitProcessCancellation()
        let completion = GitProcessExecutionCompletion()
        let timeout = request.timeout.isFinite ? max(0, request.timeout) : 0

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)

                timeoutScheduler(timeout) {
                    if completion.requestTimeout() {
                        cancellation.cancel()
                    }
                }
                Task.detached(priority: .utility) {
                    let result = await operation(request, cancellation)
                    completion.completeOperation(result)
                }

                if Task.isCancelled, completion.requestTimeout() {
                    cancellation.cancel()
                }
            }
        } onCancel: {
            if completion.requestTimeout() {
                cancellation.cancel()
            }
        }
    }

    private static func executeFoundationProcess(
        _ request: GitProcessRequest,
        cancellation: GitProcessCancellation
    ) async -> GitProcessExecutionResult {
        FoundationProcessOperation.run(request, cancellation: cancellation)
    }

    private static func scheduleTimeout(
        after timeout: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) {
        Task.detached(priority: .utility) {
            let maximumSeconds = Double(UInt64.max) / 1_000_000_000
            let nanoseconds = UInt64(min(timeout, maximumSeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            action()
        }
    }
}

private final class GitProcessExecutionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GitProcessExecutionResult, Never>?
    private var timeoutRequested = false
    private var operationCompleted = false

    func install(_ continuation: CheckedContinuation<GitProcessExecutionResult, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func requestTimeout() -> Bool {
        lock.lock()
        guard !operationCompleted, !timeoutRequested else {
            lock.unlock()
            return false
        }
        timeoutRequested = true
        lock.unlock()
        return true
    }

    func completeOperation(_ result: GitProcessExecutionResult) {
        lock.lock()
        guard !operationCompleted else {
            lock.unlock()
            return
        }
        operationCompleted = true
        let finalResult: GitProcessExecutionResult = timeoutRequested ? .timedOut : result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: finalResult)
    }
}

final class GitProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var handlers: [@Sendable () -> Void] = []

    func register(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            handler()
        } else {
            handlers.append(handler)
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let registeredHandlers = handlers
        handlers.removeAll()
        lock.unlock()

        registeredHandlers.forEach { $0() }
    }
}

enum GitProcessOutcome: Equatable, Sendable {
    case exited(Int32)
    case timedOut
    case outputTooLarge
    case launchFailed
    case cancelled

    var requiresCleanup: Bool {
        switch self {
        case .timedOut, .outputTooLarge, .cancelled:
            return true
        case .exited, .launchFailed:
            return false
        }
    }
}

final class GitProcessOutcomeState: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private let cleanup: GitProcessCleanupCoordinator
    private var storedOutcome: GitProcessOutcome?

    init(cleanup: GitProcessCleanupCoordinator) {
        self.cleanup = cleanup
    }

    var outcome: GitProcessOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return storedOutcome
    }

    @discardableResult
    func finish(_ outcome: GitProcessOutcome) -> Bool {
        lock.lock()
        guard storedOutcome == nil else {
            lock.unlock()
            return false
        }
        storedOutcome = outcome
        lock.unlock()

        if outcome.requiresCleanup {
            cleanup.begin()
        }
        completion.signal()
        return true
    }

    func waitForOutcome(until deadline: DispatchTime) -> GitProcessOutcome {
        if completion.wait(timeout: deadline) == .timedOut {
            finish(.timedOut)
        }

        lock.lock()
        defer { lock.unlock() }
        return storedOutcome ?? .launchFailed
    }
}

final class GitProcessCleanupCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let processExit = DispatchSemaphore(value: 0)
    private let stopDrains: @Sendable () -> Void
    private let terminateIfRunning: @Sendable () -> Bool
    private let forceTerminateIfRunning: @Sendable () -> Bool
    private var hasBegun = false
    private var hasSentTerminate = false
    private var hasSentForceTerminate = false
    private var hasExited = false

    init(
        stopDrains: @escaping @Sendable () -> Void,
        terminateIfRunning: @escaping @Sendable () -> Bool,
        forceTerminateIfRunning: @escaping @Sendable () -> Bool = { false }
    ) {
        self.stopDrains = stopDrains
        self.terminateIfRunning = terminateIfRunning
        self.forceTerminateIfRunning = forceTerminateIfRunning
    }

    func begin() {
        lock.lock()
        guard !hasBegun else {
            lock.unlock()
            return
        }
        hasBegun = true
        lock.unlock()

        stopDrains()
        sendTerminateIfNeeded()
    }

    func processDidLaunch() {
        sendTerminateIfNeeded()
    }

    func processDidExit() {
        lock.lock()
        guard !hasExited else {
            lock.unlock()
            return
        }
        hasExited = true
        lock.unlock()
        processExit.signal()
    }

    func waitForProcessExit(terminationGrace: TimeInterval) {
        if processExit.wait(timeout: .now() + max(0, terminationGrace)) == .success {
            return
        }
        sendForceTerminateIfNeeded()
        processExit.wait()
    }

    private func sendTerminateIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard hasBegun, !hasExited, !hasSentTerminate else { return }
        hasSentTerminate = terminateIfRunning()
    }

    private func sendForceTerminateIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasExited, !hasSentForceTerminate else { return }
        hasSentForceTerminate = forceTerminateIfRunning()
    }
}

struct GitStdoutAccumulator: Equatable, Sendable {
    private(set) var data = Data()
    private(set) var exceededLimit = false
    let limit: Int

    @discardableResult
    mutating func append(_ chunk: Data) -> Bool {
        guard !exceededLimit else { return false }
        if chunk.count > limit - data.count {
            exceededLimit = true
            data.removeAll(keepingCapacity: false)
            return true
        }
        data.append(chunk)
        return false
    }
}

struct GitStderrAccumulator: Equatable, Sendable {
    private(set) var data = Data()
    let limit: Int

    mutating func append(_ chunk: Data) {
        let remaining = limit - data.count
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
    }
}

enum GitProcessDrainResult: Equatable, Sendable {
    case data(Data)
    case tooLarge
    case readFailed
}

enum GitProcessResultResolver {
    static func resolve(
        outcome: GitProcessOutcome,
        stdout: GitProcessDrainResult,
        stderr: GitProcessDrainResult
    ) -> GitProcessExecutionResult {
        switch outcome {
        case .timedOut, .cancelled:
            return .timedOut
        case .outputTooLarge:
            return .outputTooLarge
        case .launchFailed:
            return .launchFailed
        case let .exited(status):
            if stdout == .tooLarge {
                return .outputTooLarge
            }
            guard case let .data(stdoutData) = stdout,
                  case let .data(stderrData) = stderr else {
                return .launchFailed
            }
            return .exited(status: status, stdout: stdoutData, stderr: stderrData)
        }
    }
}

private enum FoundationProcessOperation {
    private static let stderrCaptureLimit = 8 * 1024
    private static let readChunkSize = 32 * 1024
    private static let pollIntervalMilliseconds: Int32 = 25
    private static let drainGrace: TimeInterval = 0.2
    private static let terminationGrace: TimeInterval = 0.2

    static func run(
        _ request: GitProcessRequest,
        cancellation: GitProcessCancellation
    ) -> GitProcessExecutionResult {
        guard request.maxOutputBytes >= 0 else { return .outputTooLarge }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutDrainer = GitPipeDrainer(
            handle: stdoutPipe.fileHandleForReading,
            mode: .stdout(limit: request.maxOutputBytes)
        )
        let stderrDrainer = GitPipeDrainer(
            handle: stderrPipe.fileHandleForReading,
            mode: .stderr(limit: stderrCaptureLimit)
        )
        let cleanup = GitProcessCleanupCoordinator(
            stopDrains: {
                stdoutDrainer.requestStop()
                stderrDrainer.requestStop()
            },
            terminateIfRunning: {
                guard process.isRunning else { return false }
                process.terminate()
                return true
            },
            forceTerminateIfRunning: {
                guard process.isRunning else { return false }
                return Darwin.kill(process.processIdentifier, SIGKILL) == 0
            }
        )
        let state = GitProcessOutcomeState(cleanup: cleanup)

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.currentDirectoryURL
        process.environment = request.environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        cancellation.register {
            state.finish(.cancelled)
        }

        guard state.outcome == nil else {
            closeAllHandles(stdoutPipe)
            closeAllHandles(stderrPipe)
            return .timedOut
        }

        do {
            try process.run()
        } catch {
            state.finish(.launchFailed)
            closeAllHandles(stdoutPipe)
            closeAllHandles(stderrPipe)
            return state.outcome == .cancelled ? .timedOut : .launchFailed
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        Task.detached(priority: .utility) {
            stdoutDrainer.run(
                readChunkSize: readChunkSize,
                pollIntervalMilliseconds: pollIntervalMilliseconds,
                onTooLarge: {
                    state.finish(.outputTooLarge)
                }
            )
        }
        Task.detached(priority: .utility) {
            stderrDrainer.run(
                readChunkSize: readChunkSize,
                pollIntervalMilliseconds: pollIntervalMilliseconds
            )
        }
        Task.detached(priority: .utility) {
            process.waitUntilExit()
            let status = process.terminationStatus
            cleanup.processDidExit()
            state.finish(.exited(status))
        }

        cleanup.processDidLaunch()
        let outcome = state.waitForOutcome(until: .distantFuture)

        guard case .exited = outcome else {
            cleanup.waitForProcessExit(terminationGrace: terminationGrace)
            let drainDeadline = DispatchTime.now() + drainGrace
            _ = stdoutDrainer.waitForResult(until: drainDeadline)
            _ = stderrDrainer.waitForResult(until: drainDeadline)
            return GitProcessResultResolver.resolve(
                outcome: outcome,
                stdout: .readFailed,
                stderr: .readFailed
            )
        }

        let drainDeadline = DispatchTime.now() + drainGrace
        var stdout = stdoutDrainer.waitForResult(until: drainDeadline)
        var stderr = stderrDrainer.waitForResult(until: drainDeadline)
        if stdout == nil || stderr == nil {
            stdoutDrainer.requestStop()
            stderrDrainer.requestStop()
            let stopDeadline = DispatchTime.now() + Double(pollIntervalMilliseconds) / 500.0
            if stdout == nil {
                stdout = stdoutDrainer.waitForResult(until: stopDeadline)
            }
            if stderr == nil {
                stderr = stderrDrainer.waitForResult(until: stopDeadline)
            }
        }

        return GitProcessResultResolver.resolve(
            outcome: outcome,
            stdout: stdout ?? .readFailed,
            stderr: stderr ?? .readFailed
        )
    }

    private static func closeAllHandles(_ pipe: Pipe) {
        pipe.fileHandleForReading.closeFile()
        pipe.fileHandleForWriting.closeFile()
    }
}

final class GitPipeDrainer: @unchecked Sendable {
    enum Mode {
        case stdout(limit: Int)
        case stderr(limit: Int)
    }

    private let handle: FileHandle
    private let mode: Mode
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var shouldStop = false
    private var result: GitProcessDrainResult?

    init(handle: FileHandle, mode: Mode) {
        self.handle = handle
        self.mode = mode
    }

    func requestStop() {
        lock.lock()
        shouldStop = true
        lock.unlock()
    }

    func run(
        readChunkSize: Int,
        pollIntervalMilliseconds: Int32,
        onTooLarge: @escaping @Sendable () -> Void = {},
        onData: @escaping @Sendable () -> Void = {}
    ) {
        let fileDescriptor = handle.fileDescriptor
        var stdoutAccumulator: GitStdoutAccumulator?
        var stderrAccumulator: GitStderrAccumulator?
        switch mode {
        case let .stdout(limit):
            stdoutAccumulator = GitStdoutAccumulator(limit: limit)
        case let .stderr(limit):
            stderrAccumulator = GitStderrAccumulator(limit: limit)
        }

        var readFailed = false
        var reachedEOF = false
        var buffer = [UInt8](repeating: 0, count: readChunkSize)
        while !stopRequested {
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, pollIntervalMilliseconds)
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                readFailed = true
                break
            }

            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 {
                reachedEOF = true
                break
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                readFailed = true
                break
            }

            let chunk = Data(buffer.prefix(Int(count)))
            if var accumulator = stdoutAccumulator {
                if accumulator.append(chunk) {
                    onTooLarge()
                }
                stdoutAccumulator = accumulator
            } else if var accumulator = stderrAccumulator {
                accumulator.append(chunk)
                stderrAccumulator = accumulator
            }
            onData()
        }

        let finalResult: GitProcessDrainResult
        if let accumulator = stdoutAccumulator, accumulator.exceededLimit {
            finalResult = .tooLarge
        } else if readFailed || !reachedEOF {
            finalResult = .readFailed
        } else if let accumulator = stdoutAccumulator {
            finalResult = .data(accumulator.data)
        } else {
            finalResult = .data(stderrAccumulator?.data ?? Data())
        }
        handle.closeFile()
        finish(finalResult)
    }

    func waitForResult(until deadline: DispatchTime) -> GitProcessDrainResult? {
        guard completion.wait(timeout: deadline) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private var stopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldStop
    }

    private func finish(_ result: GitProcessDrainResult) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()
        completion.signal()
    }
}

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
