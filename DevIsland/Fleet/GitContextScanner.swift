import Darwin
import Foundation

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
                    if completion.resolve(.timedOut) {
                        cancellation.cancel()
                    }
                }
                Task.detached(priority: .utility) {
                    let result = await operation(request, cancellation)
                    completion.resolve(result)
                }

                if Task.isCancelled, completion.resolve(.timedOut) {
                    cancellation.cancel()
                }
            }
        } onCancel: {
            if completion.resolve(.timedOut) {
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
    private var result: GitProcessExecutionResult?

    func install(_ continuation: CheckedContinuation<GitProcessExecutionResult, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    @discardableResult
    func resolve(_ result: GitProcessExecutionResult) -> Bool {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: result)
        return true
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
    private let stopDrains: @Sendable () -> Void
    private let terminateIfRunning: @Sendable () -> Bool
    private var hasBegun = false
    private var hasSentTerminate = false
    private var hasExited = false

    init(
        stopDrains: @escaping @Sendable () -> Void,
        terminateIfRunning: @escaping @Sendable () -> Bool
    ) {
        self.stopDrains = stopDrains
        self.terminateIfRunning = terminateIfRunning
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
        hasExited = true
        lock.unlock()
    }

    private func sendTerminateIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard hasBegun, !hasExited, !hasSentTerminate else { return }
        hasSentTerminate = terminateIfRunning()
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
