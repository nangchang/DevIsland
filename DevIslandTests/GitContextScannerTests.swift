import Foundation
import XCTest
@testable import DevIsland

final class GitContextScannerTests: XCTestCase, @unchecked Sendable {
    private let oid = String(repeating: "a", count: 40)
    private var tempDirectory: URL!
    private var repository: URL!
    private var commonGitDirectory: URL!
    private var clock: ScannerTestClock!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitContextScannerTests-\(UUID().uuidString)")
        repository = tempDirectory.appendingPathComponent("repo")
        commonGitDirectory = repository.appendingPathComponent(".git")
        try FileManager.default.createDirectory(
            at: commonGitDirectory,
            withIntermediateDirectories: true
        )
        clock = ScannerTestClock(Date(timeIntervalSince1970: 1_000))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testBuildsSnapshotUsingExactCommandsAndCanonicalInputKey() async throws {
        let nested = repository.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let runner = ScannerFakeRunner { call in
            if call.isRevParse {
                return .success(self.identificationData())
            }
            return .success(self.statusData(path: "Sources/App.swift"))
        }
        let service = GitContextService(runner: runner, clock: clock)

        let states = await service.states(for: [nested.path], forceRefresh: false)

        let snapshot = try readySnapshot(states[nested.path])
        XCTAssertEqual(snapshot.repositoryID, GitRepositoryID(commonGitDirectory: commonGitDirectory.path))
        XCTAssertEqual(snapshot.worktreeID, GitWorktreeID(topLevelPath: repository.path))
        XCTAssertEqual(snapshot.branchHead, "main")
        XCTAssertEqual(snapshot.headOID, oid)
        XCTAssertEqual(snapshot.changedPaths, ["Sources/App.swift"])
        XCTAssertEqual(snapshot.changedEntryCount, 1)
        XCTAssertFalse(snapshot.hasUnmergedEntries)
        XCTAssertEqual(snapshot.capturedAt, clock.now())

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].arguments, revParseArguments)
        XCTAssertEqual(calls[0].currentDirectory.path, nested.path)
        XCTAssertEqual(calls[1].arguments, statusArguments)
        XCTAssertEqual(calls[1].currentDirectory.path, repository.path)
        XCTAssertTrue(calls.allSatisfy { $0.timeout == 1.0 })
        XCTAssertTrue(calls.allSatisfy { $0.maxOutputBytes == 1_048_576 })
    }

    func testClassifiesOnlyFixedEnglishNonRepositoryStderrAsNotRepository() async {
        let runner = ScannerFakeRunner { _ in
            .nonZeroExit(
                status: 128,
                stderr: Data("fatal: not a git repository (or any parent)".utf8)
            )
        }
        let service = GitContextService(runner: runner, clock: clock)

        let states = await service.states(for: [repository.path], forceRefresh: false)

        XCTAssertEqual(states[repository.path], .unavailable(.notRepository))
        let callCount = await runner.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testMapsOtherRevParseNonZeroAndInvalidStderrToCommandFailure() async {
        let results: [GitCommandResult] = [
            .nonZeroExit(status: 129, stderr: Data("usage: git rev-parse".utf8)),
            .nonZeroExit(status: 128, stderr: Data([0xff])),
        ]

        for result in results {
            let runner = ScannerFakeRunner { _ in result }
            let service = GitContextService(runner: runner, clock: clock)
            let states = await service.states(for: [repository.path], forceRefresh: false)
            XCTAssertEqual(states[repository.path], .unavailable(.commandFailed))
        }
    }

    func testRejectsMalformedRevParseOutput() async {
        let fixtures: [Data] = [
            Data("\(repository.path)\n\(commonGitDirectory.path)".utf8),
            Data("\(repository.path)\n\(commonGitDirectory.path)\nextra\n".utf8),
            Data("\(repository.path)\r\n\(commonGitDirectory.path)\n".utf8),
            Data("\(repository.path)\n\(commonGitDirectory.path)\0\n".utf8),
            Data("relative\n\(commonGitDirectory.path)\n".utf8),
            Data([0xff, 0x0a]),
        ]

        for fixture in fixtures {
            let runner = ScannerFakeRunner { _ in .success(fixture) }
            let service = GitContextService(runner: runner, clock: clock)
            let states = await service.states(for: [repository.path], forceRefresh: false)
            XCTAssertEqual(states[repository.path], .unavailable(.malformedOutput))
        }
    }

    func testMapsStatusFailureWithoutPreviousSnapshotToUnavailable() async {
        let runner = ScannerFakeRunner { call in
            call.isRevParse
                ? .success(self.identificationData())
                : .nonZeroExit(status: 1, stderr: Data("status failed".utf8))
        }
        let service = GitContextService(runner: runner, clock: clock)

        let states = await service.states(for: [repository.path], forceRefresh: false)

        XCTAssertEqual(states[repository.path], .unavailable(.commandFailed))
    }

    func testMapsStatusParserFailureToMalformedOutput() async {
        let runner = ScannerFakeRunner { call in
            call.isRevParse
                ? .success(self.identificationData())
                : .success(Data("not porcelain v2\0".utf8))
        }
        let service = GitContextService(runner: runner, clock: clock)

        let states = await service.states(for: [repository.path], forceRefresh: false)

        XCTAssertEqual(states[repository.path], .unavailable(.malformedOutput))
    }

    func testMapsEveryRunnerFailureForIdentificationAndStatus() async {
        let cases: [(GitCommandResult, GitSnapshotFailure)] = [
            (.timedOut, .timedOut),
            (.outputTooLarge, .outputTooLarge),
            (.launchFailed, .launchFailed),
        ]

        for (result, failure) in cases {
            let identificationRunner = ScannerFakeRunner { _ in result }
            let identificationService = GitContextService(
                runner: identificationRunner,
                clock: clock
            )
            let identificationStates = await identificationService.states(
                for: [repository.path],
                forceRefresh: false
            )
            XCTAssertEqual(identificationStates[repository.path], .unavailable(failure))

            let statusRunner = ScannerFakeRunner { call in
                call.isRevParse ? .success(self.identificationData()) : result
            }
            let statusService = GitContextService(runner: statusRunner, clock: clock)
            let statusStates = await statusService.states(
                for: [repository.path],
                forceRefresh: false
            )
            XCTAssertEqual(statusStates[repository.path], .unavailable(failure))
        }
    }

    func testReturnsPreviousReadySnapshotAsStaleWhenStatusRefreshFails() async throws {
        let statusAttempt = LockIsolated(0)
        let runner = ScannerFakeRunner { call in
            if call.isRevParse { return .success(self.identificationData()) }
            return statusAttempt.withValue { attempt in
                attempt += 1
                return attempt == 1
                    ? .success(self.statusData(path: "Sources/App.swift"))
                    : .timedOut
            }
        }
        let service = GitContextService(runner: runner, clock: clock)
        let initial = await service.states(for: [repository.path], forceRefresh: false)
        let previous = try readySnapshot(initial[repository.path])
        clock.advance(by: 2)

        let refreshed = await service.states(for: [repository.path], forceRefresh: false)

        XCTAssertEqual(refreshed[repository.path], .stale(previous, .timedOut))
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.filter(\.isRevParse).count, 1)
        XCTAssertEqual(calls.filter(\.isStatus).count, 2)
    }

    func testReturnsPreviousReadySnapshotAsStaleWhenForcedIdentificationFails() async throws {
        let identificationAttempt = LockIsolated(0)
        let runner = ScannerFakeRunner { call in
            if call.isRevParse {
                return identificationAttempt.withValue { attempt in
                    attempt += 1
                    return attempt == 1
                        ? .success(self.identificationData())
                        : .timedOut
                }
            }
            return .success(self.statusData(path: "Sources/App.swift"))
        }
        let service = GitContextService(runner: runner, clock: clock)
        let initial = await service.states(for: [repository.path], forceRefresh: false)
        let previous = try readySnapshot(initial[repository.path])

        let refreshed = await service.states(for: [repository.path], forceRefresh: true)

        XCTAssertEqual(refreshed[repository.path], .stale(previous, .timedOut))
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.filter(\.isRevParse).count, 2)
        XCTAssertEqual(calls.filter(\.isStatus).count, 1)
    }

    func testTTLHitReusesRootIdentityAndSnapshotWithoutRunnerCall() async {
        let runner = successfulRunner()
        let service = GitContextService(runner: runner, clock: clock)
        _ = await service.states(for: [repository.path], forceRefresh: false)

        let states = await service.states(for: [repository.path], forceRefresh: false)

        XCTAssertNotNil(states[repository.path])
        let callCount = await runner.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testFailureIdentityIsCachedForTwoSecondsThenRetried() async {
        let runner = ScannerFakeRunner { _ in
            .nonZeroExit(status: 128, stderr: Data("fatal: not a git repository".utf8))
        }
        let service = GitContextService(runner: runner, clock: clock)
        _ = await service.states(for: [repository.path], forceRefresh: false)
        _ = await service.states(for: [repository.path], forceRefresh: false)
        let cachedCallCount = await runner.callCount()
        XCTAssertEqual(cachedCallCount, 1)

        clock.adjustWall(by: -3_600)
        clock.advanceMonotonic(by: 2)
        _ = await service.states(for: [repository.path], forceRefresh: false)

        let refreshedCallCount = await runner.callCount()
        XCTAssertEqual(refreshedCallCount, 2)
    }

    func testUnavailableStatusResultIsRetriedImmediately() async {
        let runner = ScannerFakeRunner { call in
            call.isRevParse ? .success(self.identificationData()) : .timedOut
        }
        let service = GitContextService(runner: runner, clock: clock)
        _ = await service.states(for: [repository.path], forceRefresh: false)

        let second = await service.states(for: [repository.path], forceRefresh: false)

        XCTAssertEqual(second[repository.path], .unavailable(.timedOut))
        let callCount = await runner.callCount()
        XCTAssertEqual(callCount, 3)
    }

    func testStaleStatusResultIsRetriedImmediatelyAndKeepsPreviousSnapshot() async throws {
        let statusAttempt = LockIsolated(0)
        let runner = ScannerFakeRunner { call in
            if call.isRevParse { return .success(self.identificationData()) }
            return statusAttempt.withValue { attempt in
                attempt += 1
                return attempt == 1 ? .success(self.statusData()) : .timedOut
            }
        }
        let service = GitContextService(runner: runner, clock: clock)
        let first = await service.states(for: [repository.path], forceRefresh: false)
        let previous = try readySnapshot(first[repository.path])
        clock.advanceMonotonic(by: 2)

        let stale = await service.states(for: [repository.path], forceRefresh: false)
        let retried = await service.states(for: [repository.path], forceRefresh: false)

        XCTAssertEqual(stale[repository.path], .stale(previous, .timedOut))
        XCTAssertEqual(retried[repository.path], .stale(previous, .timedOut))
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.filter(\.isRevParse).count, 1)
        XCTAssertEqual(calls.filter(\.isStatus).count, 3)
    }

    func testReadySnapshotTTLUsesMonotonicTimeWhenWallClockMovesBackward() async {
        let runner = successfulRunner()
        let service = GitContextService(runner: runner, clock: clock)
        _ = await service.states(for: [repository.path], forceRefresh: false)
        clock.adjustWall(by: -3_600)
        clock.advanceMonotonic(by: 2)

        _ = await service.states(for: [repository.path], forceRefresh: false)

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.filter(\.isRevParse).count, 1)
        XCTAssertEqual(calls.filter(\.isStatus).count, 2)
    }

    func testForceRefreshRerunsIdentificationAndStatus() async {
        let runner = successfulRunner()
        let service = GitContextService(runner: runner, clock: clock)
        _ = await service.states(for: [repository.path], forceRefresh: false)

        _ = await service.states(for: [repository.path], forceRefresh: true)

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.filter(\.isRevParse).count, 2)
        XCTAssertEqual(calls.filter(\.isStatus).count, 2)
    }

    func testRootAndSubdirectoryUseCanonicalInputKeysAndScanStatusOnce() async throws {
        let subdirectory = repository.appendingPathComponent("Sources/Nested")
        try FileManager.default.createDirectory(
            at: subdirectory,
            withIntermediateDirectories: true
        )
        let runner = successfulRunner()
        let service = GitContextService(runner: runner, clock: clock)

        let states = await service.states(
            for: [repository.path + "/", subdirectory.path],
            forceRefresh: false
        )

        XCTAssertEqual(Set(states.keys), [repository.path, subdirectory.path])
        XCTAssertNotNil(states[repository.path])
        XCTAssertNotNil(states[subdirectory.path])
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.filter(\.isRevParse).count, 2)
        XCTAssertEqual(calls.filter(\.isStatus).count, 1)
    }

    func testForceRefreshRerunsEveryDistinctInputIdentityButOneStatusPerWorktree() async throws {
        let subdirectory = repository.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let runner = successfulRunner()
        let service = GitContextService(runner: runner, clock: clock)
        let roots = Set([repository.path, subdirectory.path])
        _ = await service.states(for: roots, forceRefresh: false)

        _ = await service.states(for: roots, forceRefresh: true)

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.filter(\.isRevParse).count, 4)
        XCTAssertEqual(calls.filter(\.isStatus).count, 2)
    }

    func testSymlinkAliasUsesCanonicalOutputKeyAndDeduplicatesIdentification() async throws {
        let alias = tempDirectory.appendingPathComponent("repo-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)
        let runner = successfulRunner()
        let service = GitContextService(runner: runner, clock: clock)

        let states = await service.states(
            for: [repository.path, alias.path],
            forceRefresh: false
        )

        XCTAssertEqual(Set(states.keys), [repository.path])
        let callCount = await runner.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testConcurrentRequestsShareIdentificationAndSnapshotInFlightTasks() async {
        let gate = AsyncGate()
        let runner = ScannerFakeRunner { call in
            if call.isRevParse {
                await gate.enterAndWaitForResume()
                return .success(self.identificationData())
            }
            return .success(self.statusData())
        }
        let service = GitContextService(runner: runner, clock: clock)
        async let first = service.states(for: [repository.path], forceRefresh: true)
        await gate.waitUntilEntered()
        async let second = service.states(for: [repository.path], forceRefresh: true)
        for _ in 0..<10 { await Task.yield() }
        await gate.resume()

        _ = await (first, second)

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.filter(\.isRevParse).count, 1)
        XCTAssertEqual(calls.filter(\.isStatus).count, 1)
    }

    func testConcurrentRequestsJoinStatusInFlightTask() async {
        let statusGate = AsyncGate()
        let joinedInFlight = ScannerAsyncSignal()
        let runner = ScannerFakeRunner { call in
            if call.isRevParse { return .success(self.identificationData()) }
            await statusGate.enterAndWaitForResume()
            return .timedOut
        }
        let service = GitContextService(
            runner: runner,
            clock: clock,
            snapshotInFlightObserver: {
                joinedInFlight.signal()
            }
        )
        async let first = service.states(for: [repository.path], forceRefresh: true)
        await statusGate.waitUntilEntered()
        async let second = service.states(for: [repository.path], forceRefresh: false)
        await joinedInFlight.wait()
        await statusGate.resume()

        let (firstStates, secondStates) = await (first, second)

        XCTAssertEqual(firstStates[repository.path], .unavailable(.timedOut))
        XCTAssertEqual(secondStates[repository.path], .unavailable(.timedOut))
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.filter(\.isRevParse).count, 1)
        XCTAssertEqual(calls.filter(\.isStatus).count, 1)
    }

    func testRepositoryIdentitySeparatesSnapshotCacheAndInFlightStatus() async throws {
        let otherCommonGitDirectory = repository.appendingPathComponent(".git-reinitialized")
        try FileManager.default.createDirectory(
            at: otherCommonGitDirectory,
            withIntermediateDirectories: true
        )
        let identificationAttempt = LockIsolated(0)
        let statusAttempt = LockIsolated(0)
        let firstStatusGate = AsyncGate()
        let runner = ScannerFakeRunner { call in
            if call.isRevParse {
                let attempt = identificationAttempt.withValue { value in
                    value += 1
                    return value
                }
                let commonDirectory = attempt == 1
                    ? self.commonGitDirectory!
                    : otherCommonGitDirectory
                return .success(
                    self.identificationData(commonGitDirectory: commonDirectory)
                )
            }

            let attempt = statusAttempt.withValue { value in
                value += 1
                return value
            }
            if attempt == 1 {
                await firstStatusGate.enterAndWaitForResume()
            }
            return attempt == 3 ? .timedOut : .success(self.statusData())
        }
        let service = GitContextService(runner: runner, clock: clock)
        async let first = service.states(for: [repository.path], forceRefresh: true)
        await firstStatusGate.waitUntilEntered()
        async let second = service.states(for: [repository.path], forceRefresh: true)
        await runner.waitUntilCallCount(4)
        await firstStatusGate.resume()

        let (firstStates, secondStates) = await (first, second)
        let firstSnapshot = try readySnapshot(firstStates[repository.path])
        let secondSnapshot = try readySnapshot(secondStates[repository.path])
        XCTAssertEqual(firstSnapshot.repositoryID.commonGitDirectory, commonGitDirectory.path)
        XCTAssertEqual(
            secondSnapshot.repositoryID.commonGitDirectory,
            otherCommonGitDirectory.path
        )

        let failedRefresh = await service.states(
            for: [repository.path],
            forceRefresh: true
        )

        XCTAssertEqual(failedRefresh[repository.path], .stale(secondSnapshot, .timedOut))
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.filter(\.isRevParse).count, 3)
        XCTAssertEqual(calls.filter(\.isStatus).count, 3)
        let metrics = await runner.metrics()
        XCTAssertLessThanOrEqual(metrics.maximumConcurrentCalls, 4)
    }

    func testScanningUsesAtMostFourConcurrentGitCommands() async throws {
        let roots = try (0..<8).map { index -> URL in
            let root = tempDirectory.appendingPathComponent("repo-\(index)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
        let firstWave = ScannerWaveGate(target: 4)
        let runner = ScannerFakeRunner { call in
            if call.isRevParse {
                await firstWave.waitForWave()
                let gitDirectory = call.currentDirectory.appendingPathComponent(".git")
                return .success(
                    Data("\(call.currentDirectory.path)\n\(gitDirectory.path)\n".utf8)
                )
            }
            return .success(self.statusData())
        }
        let service = GitContextService(runner: runner, clock: clock)

        let states = await service.states(
            for: Set(roots.map(\.path)),
            forceRefresh: false
        )

        XCTAssertEqual(states.count, 8)
        let metrics = await runner.metrics()
        XCTAssertEqual(metrics.maximumConcurrentCalls, 4)
        XCTAssertLessThanOrEqual(metrics.maximumConcurrentCalls, 4)
    }

    func testLazyPruneDropsRootAliasAndSnapshotAfterTenMinutes() async {
        let runner = successfulRunner()
        let service = GitContextService(runner: runner, clock: clock)
        _ = await service.states(for: [repository.path], forceRefresh: false)
        clock.adjustWall(by: -3_600)
        clock.advanceMonotonic(by: 600)

        _ = await service.states(for: [repository.path], forceRefresh: false)

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.filter(\.isRevParse).count, 2)
        XCTAssertEqual(calls.filter(\.isStatus).count, 2)
    }

    func testInvalidMissingAndNonDirectoryRootsNeverInvokeRunner() async throws {
        let missing = tempDirectory.appendingPathComponent("missing/../missing-root")
        let file = tempDirectory.appendingPathComponent("file.txt")
        try Data("file".utf8).write(to: file)
        let runner = successfulRunner()
        let service = GitContextService(runner: runner, clock: clock)
        let roots: Set<String> = ["", "relative/path", "bad\0path", missing.path, file.path]

        let states = await service.states(for: roots, forceRefresh: false)

        XCTAssertEqual(states[""], .unavailable(.missingWorkspace))
        XCTAssertEqual(states["relative/path"], .unavailable(.missingWorkspace))
        XCTAssertEqual(states["bad\0path"], .unavailable(.missingWorkspace))
        XCTAssertEqual(
            states[missing.standardizedFileURL.path],
            .unavailable(.missingWorkspace)
        )
        XCTAssertEqual(states[file.path], .unavailable(.missingWorkspace))
        let callCount = await runner.callCount()
        XCTAssertEqual(callCount, 0)
    }

    private var revParseArguments: [String] {
        ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"]
    }

    private var statusArguments: [String] {
        [
            "-c", "core.fsmonitor=false", "status", "--porcelain=v2", "--branch", "-z",
            "--untracked-files=all", "--no-ahead-behind",
        ]
    }

    private func identificationData(commonGitDirectory: URL? = nil) -> Data {
        let commonDirectory = commonGitDirectory ?? self.commonGitDirectory!
        return Data("\(repository.path)\n\(commonDirectory.path)\n".utf8)
    }

    private func statusData(path: String? = nil) -> Data {
        var tokens = ["# branch.oid \(oid)", "# branch.head main"]
        if let path {
            tokens.append(
                "1 .M N... 100644 100644 100644 \(oid) \(oid) \(path)"
            )
        }
        return Data((tokens.joined(separator: "\0") + "\0").utf8)
    }

    private func successfulRunner() -> ScannerFakeRunner {
        ScannerFakeRunner { call in
            call.isRevParse
                ? .success(self.identificationData())
                : .success(self.statusData())
        }
    }

    private func readySnapshot(
        _ state: GitSnapshotState?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> GitWorktreeSnapshot {
        guard case let .ready(snapshot) = state else {
            XCTFail("Expected ready snapshot, got \(String(describing: state))", file: file, line: line)
            throw ScannerTestError.unexpectedState
        }
        return snapshot
    }
}

private enum ScannerTestError: Error {
    case unexpectedState
}

private final class ScannerTestClock: GitContextClock, @unchecked Sendable {
    private struct State {
        var wallDate: Date
        var monotonicTime: TimeInterval
    }

    private let state: LockIsolated<State>

    init(_ date: Date) {
        state = LockIsolated(
            State(wallDate: date, monotonicTime: date.timeIntervalSince1970)
        )
    }

    func now() -> Date { state.value.wallDate }
    func monotonicNow() -> TimeInterval { state.value.monotonicTime }

    func advance(by interval: TimeInterval) {
        state.withValue {
            $0.wallDate = $0.wallDate.addingTimeInterval(interval)
            $0.monotonicTime += interval
        }
    }

    func adjustWall(by interval: TimeInterval) {
        state.withValue { $0.wallDate = $0.wallDate.addingTimeInterval(interval) }
    }

    func advanceMonotonic(by interval: TimeInterval) {
        state.withValue { $0.monotonicTime += interval }
    }
}

private struct ScannerGitCall: Sendable {
    let arguments: [String]
    let currentDirectory: URL
    let timeout: TimeInterval
    let maxOutputBytes: Int

    var isRevParse: Bool { arguments.first == "rev-parse" }
    var isStatus: Bool {
        arguments.starts(with: ["-c", "core.fsmonitor=false", "status"])
    }
}

private actor ScannerFakeRunner: GitCommandRunning {
    typealias Handler = @Sendable (ScannerGitCall) async -> GitCommandResult

    struct Metrics: Sendable {
        let maximumConcurrentCalls: Int
    }

    private let handler: Handler
    private var calls: [ScannerGitCall] = []
    private var activeCalls = 0
    private var maximumConcurrentCalls = 0
    private var callCountWaiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func run(
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async -> GitCommandResult {
        let call = ScannerGitCall(
            arguments: arguments,
            currentDirectory: currentDirectory,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
        calls.append(call)
        resumeSatisfiedCallCountWaiters()
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        let result = await handler(call)
        activeCalls -= 1
        return result
    }

    func recordedCalls() -> [ScannerGitCall] { calls }
    func callCount() -> Int { calls.count }
    func waitUntilCallCount(_ target: Int) async {
        guard calls.count < target else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((target, continuation))
        }
    }

    func metrics() -> Metrics {
        Metrics(maximumConcurrentCalls: maximumConcurrentCalls)
    }

    private func resumeSatisfiedCallCountWaiters() {
        let satisfied = callCountWaiters.filter { calls.count >= $0.target }
        callCountWaiters.removeAll { calls.count >= $0.target }
        satisfied.forEach { $0.continuation.resume() }
    }
}

private actor ScannerWaveGate {
    private let target: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: Int) {
        self.target = target
    }

    func waitForWave() async {
        guard count < target else { return }
        count += 1
        if count == target {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class ScannerAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        isSignaled = true
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isSignaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
