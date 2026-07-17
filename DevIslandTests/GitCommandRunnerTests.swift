import Foundation
import XCTest
@testable import DevIsland

final class GitCommandRunnerTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/fleet radar")

    func testMapsSuccessfulExecutionAndDiscardsStderr() async {
        let runner = FoundationGitCommandRunner(
            executor: StubGitProcessExecutor(
                result: .exited(
                    status: 0,
                    stdout: Data("result".utf8),
                    stderr: Data("ignored".utf8)
                )
            )
        )

        let result = await run(runner)

        XCTAssertEqual(result, .success(Data("result".utf8)))
    }

    func testMapsNonZeroExitWithOnlyCapturedStderr() async {
        let runner = FoundationGitCommandRunner(
            executor: StubGitProcessExecutor(
                result: .exited(
                    status: 128,
                    stdout: Data("ignored".utf8),
                    stderr: Data("fatal".utf8)
                )
            )
        )

        let result = await run(runner)

        XCTAssertEqual(result, .nonZeroExit(status: 128, stderr: Data("fatal".utf8)))
    }

    func testMapsTimedOutExecution() async {
        let runner = FoundationGitCommandRunner(executor: StubGitProcessExecutor(result: .timedOut))

        let result = await run(runner)

        XCTAssertEqual(result, .timedOut)
    }

    func testMapsOversizedOutput() async {
        let runner = FoundationGitCommandRunner(executor: StubGitProcessExecutor(result: .outputTooLarge))

        let result = await run(runner)

        XCTAssertEqual(result, .outputTooLarge)
    }

    func testMapsLaunchFailure() async {
        let runner = FoundationGitCommandRunner(executor: StubGitProcessExecutor(result: .launchFailed))

        let result = await run(runner)

        XCTAssertEqual(result, .launchFailed)
    }

    func testPassesArgumentsDirectoryLimitsAndStableEnvironmentWithoutShell() async {
        let recorder = GitProcessRequestRecorder()
        let executor = StubGitProcessExecutor { request in
            recorder.record(request)
            return .exited(status: 0, stdout: Data(), stderr: Data())
        }
        let runner = FoundationGitCommandRunner(executor: executor)

        _ = await runner.run(
            arguments: ["status", "--porcelain=v2", "path with spaces"],
            currentDirectory: directory,
            timeout: 0.75,
            maxOutputBytes: 321
        )

        let request = recorder.request
        XCTAssertEqual(request?.executableURL.path, "/usr/bin/git")
        XCTAssertEqual(request?.arguments, ["status", "--porcelain=v2", "path with spaces"])
        XCTAssertEqual(request?.currentDirectoryURL, directory)
        XCTAssertEqual(request?.timeout, 0.75)
        XCTAssertEqual(request?.maxOutputBytes, 321)
        XCTAssertEqual(request?.environment["LC_ALL"], "C")
        XCTAssertEqual(request?.environment["LANG"], "C")
        XCTAssertEqual(request?.environment["GIT_OPTIONAL_LOCKS"], "0")
    }

    func testStableEnvironmentRemovesEveryAmbientGitVariable() {
        let gitKeys = [
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_CONFIG_COUNT",
            "GIT_CONFIG_KEY_0",
            "GIT_CONFIG_VALUE_0",
            "GIT_TRACE",
            "GIT_OPTIONAL_LOCKS",
        ]
        var ambient = Dictionary(uniqueKeysWithValues: gitKeys.map { ($0, "injected") })
        ambient["PATH"] = "/usr/bin:/bin"
        ambient["LC_ALL"] = "ko_KR.UTF-8"
        ambient["LANG"] = "ko_KR.UTF-8"

        let environment = GitCommandEnvironment.stable(from: ambient)

        for key in gitKeys where key != "GIT_OPTIONAL_LOCKS" {
            XCTAssertNil(environment[key], key)
        }
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["LC_ALL"], "C")
        XCTAssertEqual(environment["LANG"], "C")
        XCTAssertEqual(environment["GIT_OPTIONAL_LOCKS"], "0")
    }

    func testCallerCancellationWaitsForInjectedOperationCleanup() async {
        let gate = AsyncGate()
        let cancellationSignal = AsyncSignal()
        let completionSignal = AsyncSignal()
        let executor = FoundationGitProcessExecutor { _, cancellation in
            cancellation.register {
                cancellationSignal.signal()
            }
            await gate.enterAndWaitForResume()
            return .timedOut
        }
        let runner = FoundationGitCommandRunner(executor: executor)
        let task = Task {
            let result = await self.run(runner)
            completionSignal.signal()
            return result
        }

        await gate.waitUntilEntered()
        task.cancel()
        await cancellationSignal.wait()
        XCTAssertFalse(completionSignal.hasSignalled)

        await gate.resume()
        let result = await task.value
        XCTAssertEqual(result, .timedOut)
        XCTAssertTrue(completionSignal.hasSignalled)
    }

    func testCallerTimeoutWaitsForInjectedOperationCleanup() async {
        let gate = AsyncGate()
        let cancellationSignal = AsyncSignal()
        let cancellationCount = LockIsolated(0)
        let completionSignal = AsyncSignal()
        let timeoutScheduler = ManualTimeoutScheduler()
        let executor = FoundationGitProcessExecutor(
            operation: { _, cancellation in
                cancellation.register {
                    cancellationCount.withValue { $0 += 1 }
                    cancellationSignal.signal()
                }
                await gate.enterAndWaitForResume()
                return .launchFailed
            },
            timeoutScheduler: { timeout, action in
                timeoutScheduler.schedule(timeout, action)
            }
        )
        let runner = FoundationGitCommandRunner(executor: executor)
        let task = Task {
            let result = await self.run(runner)
            completionSignal.signal()
            return result
        }

        await gate.waitUntilEntered()
        timeoutScheduler.fire()
        task.cancel()
        await cancellationSignal.wait()
        XCTAssertFalse(completionSignal.hasSignalled)
        XCTAssertEqual(cancellationCount.value, 1)

        await gate.resume()
        let result = await task.value
        XCTAssertEqual(result, .timedOut)
        XCTAssertTrue(completionSignal.hasSignalled)
    }

    func testCompletedOperationIgnoresLateTimeout() async {
        let cancellationSignal = AsyncSignal()
        let timeoutScheduler = ManualTimeoutScheduler()
        let executor = FoundationGitProcessExecutor(
            operation: { _, cancellation in
                cancellation.register {
                    cancellationSignal.signal()
                }
                return .exited(status: 0, stdout: Data("done".utf8), stderr: Data())
            },
            timeoutScheduler: { timeout, action in
                timeoutScheduler.schedule(timeout, action)
            }
        )
        let runner = FoundationGitCommandRunner(executor: executor)

        let result = await run(runner)
        timeoutScheduler.fire()

        XCTAssertEqual(result, .success(Data("done".utf8)))
        XCTAssertFalse(cancellationSignal.hasSignalled)
    }

    func testFoundationExecutorDrainsLargeStdoutAndStderrWithoutDeadlock() async {
        let chunkSize = 1_024
        let iterationCount = 256
        let stdoutChunk = String(repeating: "o", count: chunkSize)
        let stderrChunk = String(repeating: "e", count: chunkSize)
        let program = """
        BEGIN {
            for (i = 0; i < \(iterationCount); i++) {
                printf "%s", "\(stdoutChunk)"
                printf "%s", "\(stderrChunk)" > "/dev/stderr"
            }
        }
        """

        let result = await executeProcess(
            executablePath: "/usr/bin/awk",
            arguments: [program],
            timeout: 5,
            maxOutputBytes: chunkSize * iterationCount
        )

        XCTAssertEqual(
            result,
            .exited(
                status: 0,
                stdout: Data(repeating: 0x6f, count: chunkSize * iterationCount),
                stderr: Data(repeating: 0x65, count: 8 * 1_024)
            )
        )
    }

    func testFoundationExecutorReportsOutputTooLargeBeforeTimeout() async {
        let result = await executeProcess(
            executablePath: "/usr/bin/yes",
            arguments: [],
            timeout: 5,
            maxOutputBytes: 4 * 1_024
        )

        XCTAssertEqual(result, .outputTooLarge)
    }

    func testFoundationExecutorTimesOutAfterProcessLaunch() async {
        let markerURL = processMarkerURL()
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let result = await executeProcess(
            executablePath: "/usr/bin/awk",
            arguments: longRunningAWKArguments(markerURL: markerURL),
            timeout: 1,
            maxOutputBytes: 1_024
        )

        XCTAssertEqual(result, .timedOut)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testFoundationExecutorCancelsAfterProcessLaunch() async {
        let markerURL = processMarkerURL()
        defer { try? FileManager.default.removeItem(at: markerURL) }
        let executor = FoundationGitProcessExecutor()
        let request = processRequest(
            executablePath: "/usr/bin/awk",
            arguments: longRunningAWKArguments(markerURL: markerURL),
            timeout: 5,
            maxOutputBytes: 1_024
        )
        let task = Task {
            await executor.execute(request)
        }
        let didLaunch = await waitForProcessMarker(at: markerURL)

        task.cancel()
        let result = await task.value

        XCTAssertTrue(didLaunch)
        XCTAssertEqual(result, .timedOut)
    }

    func testStdoutAccumulatorAcceptsExactLimit() {
        var accumulator = GitStdoutAccumulator(limit: 4)

        let exceeded = accumulator.append(Data([0, 1, 2, 3]))

        XCTAssertFalse(exceeded)
        XCTAssertFalse(accumulator.exceededLimit)
        XCTAssertEqual(accumulator.data, Data([0, 1, 2, 3]))
    }

    func testStdoutAccumulatorRejectsLimitPlusOneAndDiscardsAllOutput() {
        var accumulator = GitStdoutAccumulator(limit: 4)

        XCTAssertFalse(accumulator.append(Data([0, 1, 2, 3])))
        XCTAssertTrue(accumulator.append(Data([4])))
        XCTAssertFalse(accumulator.append(Data([5])))

        XCTAssertTrue(accumulator.exceededLimit)
        XCTAssertTrue(accumulator.data.isEmpty)
    }

    func testStderrAccumulatorKeepsOnlyFirstEightKiB() {
        var accumulator = GitStderrAccumulator(limit: 8 * 1024)
        let prefix = Data(repeating: 0x61, count: 8 * 1024)

        accumulator.append(prefix)
        accumulator.append(Data(repeating: 0x62, count: 512))

        XCTAssertEqual(accumulator.data, prefix)
    }

    func testPipeDrainerReturnsAllChunksAfterEOF() async throws {
        let pipe = Pipe()
        let expected = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
        let drainer = GitPipeDrainer(
            handle: pipe.fileHandleForReading,
            mode: .stdout(limit: expected.count)
        )
        drainer.start(readChunkSize: 1_024)

        try pipe.fileHandleForWriting.write(contentsOf: expected)
        try pipe.fileHandleForWriting.close()
        let result = await Task.detached(priority: .utility) {
            drainer.waitForResult(until: .now() + 1)
        }.value

        XCTAssertEqual(result, .data(expected))
    }

    func testStderrPipeDrainerContinuesDrainingAfterCaptureLimit() async throws {
        let pipe = Pipe()
        let expected = Data(repeating: 0x61, count: 4)
        let drainer = GitPipeDrainer(handle: pipe.fileHandleForReading, mode: .stderr(limit: 4))
        drainer.start(readChunkSize: 1_024)

        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 0x61, count: 128 * 1024))
        try pipe.fileHandleForWriting.close()
        let result = await Task.detached(priority: .utility) {
            drainer.waitForResult(until: .now() + 1)
        }.value

        XCTAssertEqual(result, .data(expected))
    }

    func testStoppingPipeDrainerBeforeEOFFailsInsteadOfReturningPartialData() async throws {
        let pipe = Pipe()
        let drainer = GitPipeDrainer(handle: pipe.fileHandleForReading, mode: .stdout(limit: 32))
        let dataRead = AsyncSignal()
        drainer.start(
            readChunkSize: 16,
            onData: {
                dataRead.signal()
            }
        )

        try pipe.fileHandleForWriting.write(contentsOf: Data("partial".utf8))
        await dataRead.wait()
        drainer.requestStop()
        let result = await Task.detached(priority: .utility) {
            drainer.waitForResult(until: .now() + 0.2)
        }.value
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(result, .readFailed)
    }

    func testStoppingPipeDrainerBeforeStartFinishesAsReadFailure() async throws {
        let pipe = Pipe()
        let drainer = GitPipeDrainer(handle: pipe.fileHandleForReading, mode: .stdout(limit: 32))

        drainer.requestStop()
        drainer.start(readChunkSize: 16)
        let result = await Task.detached(priority: .utility) {
            drainer.waitForResult(until: .now() + 0.2)
        }.value
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(result, .readFailed)
    }

    func testPipeDrainerStopsAtOutputLimitAndSignalsOnce() async throws {
        let pipe = Pipe()
        let tooLargeCount = LockIsolated(0)
        let drainer = GitPipeDrainer(handle: pipe.fileHandleForReading, mode: .stdout(limit: 4))
        drainer.start(
            readChunkSize: 3,
            onTooLarge: {
                tooLargeCount.withValue { $0 += 1 }
            }
        )

        try pipe.fileHandleForWriting.write(contentsOf: Data("oversized".utf8))
        let result = await Task.detached(priority: .utility) {
            drainer.waitForResult(until: .now() + 0.2)
        }.value
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(result, .tooLarge)
        XCTAssertEqual(tooLargeCount.value, 1)
    }

    func testFirstTimeoutOrCancellationIsNotOverriddenByLateOversizedOutput() {
        XCTAssertEqual(
            GitProcessResultResolver.resolve(
                outcome: .timedOut,
                stdout: .tooLarge,
                stderr: .data(Data())
            ),
            .timedOut
        )
        XCTAssertEqual(
            GitProcessResultResolver.resolve(
                outcome: .cancelled,
                stdout: .tooLarge,
                stderr: .data(Data())
            ),
            .timedOut
        )
    }

    func testExitedOutcomeIsCorrectedWhenDrainFindsOversizedOutput() {
        XCTAssertEqual(
            GitProcessResultResolver.resolve(
                outcome: .exited(0),
                stdout: .tooLarge,
                stderr: .data(Data())
            ),
            .outputTooLarge
        )
    }

    func testCleanupStopsDrainsAndTerminatesOnlyOnce() {
        let recorder = CleanupRecorder(terminateSucceeds: true)
        let cleanup = recorder.makeCoordinator()

        cleanup.begin()
        cleanup.begin()
        cleanup.processDidLaunch()

        XCTAssertEqual(recorder.snapshot.stopCount, 1)
        XCTAssertEqual(recorder.snapshot.terminateAttemptCount, 1)
        XCTAssertEqual(recorder.snapshot.terminateCount, 1)
    }

    func testCleanupRetriesTerminateExactlyOnceAfterProcessLaunch() {
        let recorder = CleanupRecorder(terminateSucceeds: false)
        let cleanup = recorder.makeCoordinator()

        cleanup.begin()
        recorder.terminateSucceeds = true
        cleanup.processDidLaunch()

        XCTAssertEqual(recorder.snapshot.stopCount, 1)
        XCTAssertEqual(recorder.snapshot.terminateAttemptCount, 2)
        XCTAssertEqual(recorder.snapshot.terminateCount, 1)

        cleanup.processDidLaunch()
        XCTAssertEqual(recorder.snapshot.terminateAttemptCount, 2)
        XCTAssertEqual(recorder.snapshot.terminateCount, 1)
    }

    func testTimeoutFirstOutcomeTriggersCleanupExactlyOnce() {
        let recorder = CleanupRecorder(terminateSucceeds: true)
        let state = GitProcessOutcomeState(cleanup: recorder.makeCoordinator())

        let outcome = state.waitForOutcome(until: .now())
        state.finish(.outputTooLarge)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(state.outcome, .timedOut)
        XCTAssertEqual(recorder.snapshot.stopCount, 1)
        XCTAssertEqual(recorder.snapshot.terminateCount, 1)
    }

    func testCancellationFirstOutcomeTriggersCleanupExactlyOnce() {
        let recorder = CleanupRecorder(terminateSucceeds: true)
        let state = GitProcessOutcomeState(cleanup: recorder.makeCoordinator())
        let cancellation = GitProcessCancellation()
        cancellation.register {
            state.finish(.cancelled)
        }

        cancellation.cancel()
        cancellation.cancel()
        state.finish(.outputTooLarge)

        XCTAssertEqual(state.outcome, .cancelled)
        XCTAssertEqual(recorder.snapshot.stopCount, 1)
        XCTAssertEqual(recorder.snapshot.terminateCount, 1)
    }

    func testCleanupWaitsForExitAndEscalatesAfterTerminationGrace() async {
        let forceSignal = AsyncSignal()
        let completionSignal = AsyncSignal()
        let recorder = CleanupRecorder(
            terminateSucceeds: true,
            forceTerminateSucceeds: true,
            onForceTerminate: { forceSignal.signal() }
        )
        let cleanup = recorder.makeCoordinator()
        cleanup.begin()

        let waiter = Task.detached {
            cleanup.waitForProcessExit(terminationGrace: 0)
            completionSignal.signal()
        }
        await forceSignal.wait()
        XCTAssertFalse(completionSignal.hasSignalled)

        cleanup.processDidExit()
        await completionSignal.wait()
        _ = await waiter.value

        XCTAssertEqual(recorder.snapshot.forceTerminateAttemptCount, 1)
        XCTAssertEqual(recorder.snapshot.forceTerminateCount, 1)
    }

    private func run(_ runner: FoundationGitCommandRunner) async -> GitCommandResult {
        await runner.run(
            arguments: ["status"],
            currentDirectory: directory,
            timeout: FoundationGitCommandRunner.defaultTimeout,
            maxOutputBytes: FoundationGitCommandRunner.defaultMaxOutputBytes
        )
    }

    private func executeProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async -> GitProcessExecutionResult {
        await FoundationGitProcessExecutor().execute(
            processRequest(
                executablePath: executablePath,
                arguments: arguments,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes
            )
        )
    }

    private func processRequest(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) -> GitProcessRequest {
        GitProcessRequest(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: GitCommandEnvironment.stable(from: ProcessInfo.processInfo.environment),
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
    }

    private func processMarkerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("devisland-git-command-runner-\(UUID().uuidString)")
    }

    private func longRunningAWKArguments(markerURL: URL) -> [String] {
        let program = #"BEGIN { print "launched" > marker; close(marker); while (1) {} }"#
        return ["-v", "marker=\(markerURL.path)", program]
    }

    private func waitForProcessMarker(at markerURL: URL) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: markerURL.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: markerURL.path)
    }
}

private final class CleanupRecorder: @unchecked Sendable {
    struct Snapshot {
        var stopCount = 0
        var terminateAttemptCount = 0
        var terminateCount = 0
        var terminateSucceeds: Bool
        var forceTerminateAttemptCount = 0
        var forceTerminateCount = 0
        var forceTerminateSucceeds: Bool
    }

    private let state: LockIsolated<Snapshot>
    private let onForceTerminate: @Sendable () -> Void

    init(
        terminateSucceeds: Bool,
        forceTerminateSucceeds: Bool = false,
        onForceTerminate: @escaping @Sendable () -> Void = {}
    ) {
        state = LockIsolated(
            Snapshot(
                terminateSucceeds: terminateSucceeds,
                forceTerminateSucceeds: forceTerminateSucceeds
            )
        )
        self.onForceTerminate = onForceTerminate
    }

    var snapshot: Snapshot { state.value }

    var terminateSucceeds: Bool {
        get { state.value.terminateSucceeds }
        set { state.withValue { $0.terminateSucceeds = newValue } }
    }

    func makeCoordinator() -> GitProcessCleanupCoordinator {
        GitProcessCleanupCoordinator(
            stopDrains: {
                self.state.withValue { $0.stopCount += 1 }
            },
            terminateIfRunning: {
                self.state.withValue {
                    $0.terminateAttemptCount += 1
                    if $0.terminateSucceeds {
                        $0.terminateCount += 1
                        return true
                    }
                    return false
                }
            },
            forceTerminateIfRunning: {
                self.onForceTerminate()
                return self.state.withValue {
                    $0.forceTerminateAttemptCount += 1
                    if $0.forceTerminateSucceeds {
                        $0.forceTerminateCount += 1
                        return true
                    }
                    return false
                }
            }
        )
    }
}

private final class ManualTimeoutScheduler: @unchecked Sendable {
    private let action = LockIsolated<(@Sendable () -> Void)?>(nil)

    func schedule(_ timeout: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        _ = timeout
        self.action.withValue { $0 = action }
    }

    func fire() {
        action.value?()
    }
}

private struct StubGitProcessExecutor: GitProcessExecuting {
    private let operation: @Sendable (GitProcessRequest) async -> GitProcessExecutionResult

    init(result: GitProcessExecutionResult) {
        operation = { _ in result }
    }

    init(operation: @escaping @Sendable (GitProcessRequest) async -> GitProcessExecutionResult) {
        self.operation = operation
    }

    func execute(_ request: GitProcessRequest) async -> GitProcessExecutionResult {
        await operation(request)
    }
}

private final class GitProcessRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: GitProcessRequest?

    var request: GitProcessRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func record(_ request: GitProcessRequest) {
        lock.lock()
        storedRequest = request
        lock.unlock()
    }
}

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasSignalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSignalled
    }

    func signal() {
        lock.lock()
        guard !isSignalled else {
            lock.unlock()
            return
        }
        isSignalled = true
        let registeredWaiters = waiters
        waiters.removeAll()
        lock.unlock()

        registeredWaiters.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isSignalled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
