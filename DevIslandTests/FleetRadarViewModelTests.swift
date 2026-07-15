import XCTest
@testable import DevIsland

@MainActor
final class FleetRadarViewModelTests: XCTestCase {
    func testGroupsChildrenUnderParentSortsThemAndUsesSessionLabels() async {
        let scanner = FleetRadarScannerFake(responses: [[:]])
        let viewModel = makeViewModel(scanner: scanner)
        let parent = makeSession(
            id: "parent",
            terminalTitle: "Parent terminal",
            workspaceRoot: "/repo/main",
            lastActiveAt: date(10)
        )
        let laterChild = makeSession(
            id: "child-b",
            terminalTitle: "Child B terminal",
            parentSessionID: parent.id,
            workspaceRoot: "/repo/feature-b",
            lastActiveAt: date(30)
        )
        let sameTimeChild = makeSession(
            id: "child-a",
            terminalTitle: "Child A terminal",
            parentSessionID: parent.id,
            workspaceRoot: "/repo/feature-a",
            lastActiveAt: date(30)
        )

        viewModel.update(
            sessions: [laterChild, parent, sameTimeChild],
            labels: ["parent": "Fleet root", "child-a": "Labeled child"]
        )
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        XCTAssertEqual(viewModel.cards.count, 1)
        XCTAssertEqual(viewModel.cards[0].group.root.displayTitle, "Fleet root")
        XCTAssertEqual(viewModel.cards[0].group.children.map(\.id), ["child-a", "child-b"])
        XCTAssertEqual(viewModel.cards[0].group.children[0].displayTitle, "Labeled child")
        let call = await scanner.call(at: 0)
        XCTAssertEqual(call.workspaceRoots, ["/repo/feature-a", "/repo/feature-b", "/repo/main"])
    }

    func testMissingParentCreatesAnOrphanCard() async {
        let scanner = FleetRadarScannerFake(responses: [[:]])
        let viewModel = makeViewModel(scanner: scanner)
        let orphan = makeSession(id: "orphan", parentSessionID: "closed-parent")

        viewModel.update(sessions: [orphan], labels: [:])
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        XCTAssertEqual(viewModel.cards.map(\.id), ["orphan"])
        XCTAssertTrue(viewModel.cards[0].group.isOrphan)
        XCTAssertTrue(viewModel.cards[0].group.children.isEmpty)
    }

    func testMultiLevelChildrenJoinTopRootAndOrphanDescendantsJoinOrphanAncestor() async {
        let scanner = FleetRadarScannerFake(responses: [[:]])
        let viewModel = makeViewModel(scanner: scanner)
        let root = makeSession(id: "root", lastActiveAt: date(10))
        let child = makeSession(
            id: "child",
            parentSessionID: root.id,
            lastActiveAt: date(20)
        )
        let grandchild = makeSession(
            id: "grandchild",
            parentSessionID: child.id,
            lastActiveAt: date(30)
        )
        let orphanRoot = makeSession(
            id: "orphan-root",
            parentSessionID: "closed-parent",
            lastActiveAt: date(40)
        )
        let orphanDescendant = makeSession(
            id: "orphan-descendant",
            parentSessionID: orphanRoot.id,
            lastActiveAt: date(50)
        )

        viewModel.update(
            sessions: [grandchild, orphanDescendant, child, orphanRoot, root],
            labels: [:]
        )
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        let cards = Dictionary(uniqueKeysWithValues: viewModel.cards.map { ($0.id, $0) })
        XCTAssertEqual(cards["root"]?.group.children.map(\.id), ["grandchild", "child"])
        XCTAssertFalse(cards["root"]?.group.isOrphan ?? true)
        XCTAssertEqual(
            cards["orphan-root"]?.group.children.map(\.id),
            ["orphan-descendant"]
        )
        XCTAssertTrue(cards["orphan-root"]?.group.isOrphan ?? false)
    }

    func testChildPendingRaisesParentAttentionAndPreservesOtherAttentionKinds() async {
        let main = snapshot(
            worktree: "/repo/main",
            paths: ["Sources/Shared.swift"],
            hasUnmergedEntries: true
        )
        let feature = snapshot(
            worktree: "/repo/feature",
            branch: "feature/radar",
            paths: ["Sources/Shared.swift"]
        )
        let scanner = FleetRadarScannerFake(responses: [[
            "/repo/main": .ready(main),
            "/repo/feature": .ready(feature),
        ]])
        let viewModel = makeViewModel(scanner: scanner)
        let parent = makeSession(
            id: "parent",
            workspaceRoot: "/repo/main",
            isUnread: true,
            status: .policyDenied(date(1))
        )
        let child = makeSession(
            id: "child",
            parentSessionID: parent.id,
            workspaceRoot: "/repo/feature",
            isPending: true
        )

        viewModel.update(sessions: [parent, child], labels: [:])
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        let card = try! XCTUnwrap(viewModel.cards.first)
        XCTAssertEqual(card.primaryAttention, .needsDecision)
        XCTAssertEqual(
            card.secondaryAttention,
            [.blocked, .overlapRisk, .unread, .live]
        )
        XCTAssertEqual(card.overlaps.count, 2)
    }

    func testStandaloneAttentionKindsUseRawPriorityOrder() async {
        let overlapA = snapshot(
            worktree: "/repo/a",
            branch: "a",
            paths: ["Sources/Shared.swift"]
        )
        let overlapB = snapshot(
            worktree: "/repo/b",
            branch: "b",
            paths: ["Sources/Shared.swift"]
        )
        let scanner = FleetRadarScannerFake(responses: [[
            "/repo/a": .ready(overlapA),
            "/repo/b": .ready(overlapB),
        ]])
        let viewModel = makeViewModel(scanner: scanner)

        viewModel.update(
            sessions: [
                makeSession(id: "live", lastActiveAt: date(500)),
                makeSession(id: "unread", lastActiveAt: date(400), isUnread: true),
                makeSession(
                    id: "overlap-b",
                    workspaceRoot: "/repo/b",
                    lastActiveAt: date(200)
                ),
                makeSession(
                    id: "missed",
                    lastActiveAt: date(100),
                    hasMissedApproval: true
                ),
                makeSession(
                    id: "overlap-a",
                    workspaceRoot: "/repo/a",
                    lastActiveAt: date(300)
                ),
            ],
            labels: [:]
        )
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        XCTAssertEqual(
            viewModel.cards.map(\.id),
            ["missed", "overlap-a", "overlap-b", "unread", "live"]
        )
        XCTAssertEqual(
            viewModel.cards.map(\.primaryAttention),
            [.needsDecision, .overlapRisk, .overlapRisk, .unread, .live]
        )
        XCTAssertEqual(viewModel.cards[0].secondaryAttention, [.live])
        XCTAssertEqual(viewModel.cards[1].secondaryAttention, [.live])
        XCTAssertEqual(viewModel.cards[3].secondaryAttention, [.live])
        XCTAssertEqual(viewModel.cards[4].secondaryAttention, [])
    }

    func testTimeoutAndStaleUnmergedSnapshotsAreBlocked() async {
        let unmerged = snapshot(worktree: "/repo/unmerged", hasUnmergedEntries: true)
        let scanner = FleetRadarScannerFake(responses: [[
            "/repo/unmerged": .stale(unmerged, .timedOut),
        ]])
        let viewModel = makeViewModel(scanner: scanner)
        let timeout = makeSession(id: "timeout", status: .timeoutBypassed(date(1)))
        let gitBlocked = makeSession(id: "git", workspaceRoot: "/repo/unmerged")

        viewModel.update(sessions: [timeout, gitBlocked], labels: [:])
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        XCTAssertEqual(viewModel.cards.map(\.primaryAttention), [.blocked, .blocked])
    }

    func testCardsSortByAttentionNewestActivityTitleAndSessionID() async {
        let scanner = FleetRadarScannerFake(responses: [[:]])
        let viewModel = makeViewModel(scanner: scanner)
        let decision = makeSession(id: "decision", lastActiveAt: date(1), isPending: true)
        let newest = makeSession(id: "newest", terminalTitle: "Z", lastActiveAt: date(30))
        let task10 = makeSession(id: "task-10", terminalTitle: "Task 10", lastActiveAt: date(20))
        let task2 = makeSession(id: "task-2", terminalTitle: "Task 2", lastActiveAt: date(20))
        let tiedB = makeSession(id: "b", terminalTitle: "Same", lastActiveAt: date(10))
        let tiedA = makeSession(id: "a", terminalTitle: "Same", lastActiveAt: date(10))

        viewModel.update(
            sessions: [tiedB, task10, decision, tiedA, newest, task2],
            labels: [:]
        )
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        XCTAssertEqual(
            viewModel.cards.map(\.id),
            ["decision", "newest", "task-2", "task-10", "a", "b"]
        )
    }

    func testStaleGenerationResultDoesNotReplaceNewerCards() async {
        let firstGate = AsyncGate()
        let discardSignal = FleetRadarDiscardSignal()
        let oldSnapshot = snapshot(worktree: "/repo/old", branch: "old")
        let newSnapshot = snapshot(worktree: "/repo/new", branch: "new")
        let scanner = FleetRadarScannerFake(
            responses: [
                ["/repo/old": .ready(oldSnapshot)],
                ["/repo/new": .ready(newSnapshot)],
            ],
            gates: [firstGate, nil]
        )
        let viewModel = makeViewModel(
            scanner: scanner,
            refreshDiscardObserver: {
                Task { await discardSignal.signal() }
            }
        )

        viewModel.update(
            sessions: [makeSession(id: "old", workspaceRoot: "/repo/old")],
            labels: [:]
        )
        await firstGate.waitUntilEntered()

        viewModel.update(
            sessions: [makeSession(id: "new", workspaceRoot: "/repo/new")],
            labels: [:]
        )
        await scanner.waitForCallCount(2)
        await waitUntilRefreshCompletes(viewModel)
        let expectedCards = viewModel.cards
        let expectedCompletedAt = viewModel.lastCompletedAt

        await firstGate.resume()
        await discardSignal.wait()
        XCTAssertEqual(viewModel.cards, expectedCards)
        XCTAssertFalse(viewModel.isRefreshing)
        XCTAssertEqual(viewModel.lastCompletedAt, expectedCompletedAt)
        XCTAssertEqual(viewModel.cards.map(\.id), ["new"])
        XCTAssertEqual(viewModel.cards[0].gitStates["/repo/new"], .ready(newSnapshot))
    }

    func testForceRefreshFlagIsForwarded() async {
        let scanner = FleetRadarScannerFake(responses: [[:]])
        let viewModel = makeViewModel(scanner: scanner)

        viewModel.update(
            sessions: [makeSession(id: "session")],
            labels: [:],
            forceRefresh: true
        )
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        let call = await scanner.call(at: 0)
        XCTAssertTrue(call.forceRefresh)
    }

    func testEmptySessionsResetImmediatelyAndBlockInFlightResult() async {
        let gate = AsyncGate()
        let discardSignal = FleetRadarDiscardSignal()
        let scanner = FleetRadarScannerFake(
            responses: [["/repo": .ready(snapshot(worktree: "/repo"))]],
            gates: [gate]
        )
        let viewModel = makeViewModel(
            scanner: scanner,
            refreshDiscardObserver: {
                Task { await discardSignal.signal() }
            }
        )

        viewModel.update(
            sessions: [makeSession(id: "session", workspaceRoot: "/repo")],
            labels: [:]
        )
        await gate.waitUntilEntered()
        XCTAssertTrue(viewModel.isRefreshing)

        viewModel.update(sessions: [], labels: [:])
        XCTAssertEqual(viewModel.cards, [])
        XCTAssertFalse(viewModel.isRefreshing)
        XCTAssertNil(viewModel.lastCompletedAt)

        await gate.resume()
        await discardSignal.wait()
        XCTAssertEqual(viewModel.cards, [])
        XCTAssertFalse(viewModel.isRefreshing)
        XCTAssertNil(viewModel.lastCompletedAt)
    }

    func testInFlightScanDoesNotKeepViewModelAlive() async {
        let gate = AsyncGate()
        let scanner = FleetRadarScannerFake(responses: [[:]], gates: [gate])
        var viewModel: FleetRadarViewModel? = makeViewModel(scanner: scanner)
        weak let weakViewModel = viewModel

        viewModel?.update(
            sessions: [makeSession(id: "session", workspaceRoot: "/repo")],
            labels: [:]
        )
        await gate.waitUntilEntered()

        viewModel = nil
        XCTAssertNil(weakViewModel)

        await gate.resume()
    }

    func testDebounceCoalescesRapidUpdatesAndLatchesForceRefresh() async {
        XCTAssertEqual(FleetRadarViewModel.defaultDebounceDuration, .milliseconds(350))
        let scanner = FleetRadarScannerFake(responses: [[:]])
        let viewModel = FleetRadarViewModel(
            scanner: scanner,
            debounceDuration: .milliseconds(20)
        )

        viewModel.update(
            sessions: [makeSession(id: "first", workspaceRoot: "/repo/first")],
            labels: [:],
            forceRefresh: true
        )
        viewModel.update(
            sessions: [makeSession(id: "second", workspaceRoot: "/repo/second")],
            labels: [:]
        )
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        let callsCount = await scanner.callsCount()
        let call = await scanner.call(at: 0)
        XCTAssertEqual(callsCount, 1)
        XCTAssertEqual(call.workspaceRoots, ["/repo/second"])
        XCTAssertTrue(call.forceRefresh)
        XCTAssertEqual(viewModel.cards.map(\.id), ["second"])
    }

    func testEmptyResetClearsLatchedForceRefresh() async {
        let scanner = FleetRadarScannerFake(responses: [[:]])
        let viewModel = FleetRadarViewModel(
            scanner: scanner,
            debounceDuration: .milliseconds(20)
        )

        viewModel.update(
            sessions: [makeSession(id: "force", workspaceRoot: "/repo/force")],
            labels: [:],
            forceRefresh: true
        )
        viewModel.update(sessions: [], labels: [:])
        viewModel.update(
            sessions: [makeSession(id: "normal", workspaceRoot: "/repo/normal")],
            labels: [:]
        )
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        let call = await scanner.call(at: 0)
        XCTAssertFalse(call.forceRefresh)
        XCTAssertEqual(call.workspaceRoots, ["/repo/normal"])
    }

    func testForceRefreshConsumedByStartedScanDoesNotForceLaterUpdate() async {
        let gate = AsyncGate()
        let scanner = FleetRadarScannerFake(
            responses: [[:], [:]],
            gates: [gate, nil]
        )
        let viewModel = makeViewModel(scanner: scanner)

        viewModel.update(
            sessions: [makeSession(id: "force", workspaceRoot: "/repo/force")],
            labels: [:],
            forceRefresh: true
        )
        await gate.waitUntilEntered()
        viewModel.update(
            sessions: [makeSession(id: "normal", workspaceRoot: "/repo/normal")],
            labels: [:]
        )
        await scanner.waitForCallCount(2)
        await waitUntilRefreshCompletes(viewModel)

        let first = await scanner.call(at: 0)
        let second = await scanner.call(at: 1)
        XCTAssertTrue(first.forceRefresh)
        XCTAssertFalse(second.forceRefresh)
        await gate.resume()
    }

    func testReadyAndStaleSnapshotsParticipateInOverlapButUnavailableDoesNot() async {
        let ready = snapshot(
            worktree: "/repo/ready",
            paths: ["Sources/Shared.swift"]
        )
        let stale = snapshot(
            worktree: "/repo/stale",
            branch: "stale",
            paths: ["Sources/Shared.swift"]
        )
        let scanner = FleetRadarScannerFake(responses: [[
            "/repo/ready": .ready(ready),
            "/repo/stale": .stale(stale, .timedOut),
            "/repo/unavailable": .unavailable(.commandFailed),
        ]])
        let viewModel = makeViewModel(scanner: scanner)

        viewModel.update(
            sessions: [
                makeSession(id: "ready", workspaceRoot: "/repo/ready"),
                makeSession(id: "stale", workspaceRoot: "/repo/stale"),
                makeSession(id: "unavailable", workspaceRoot: "/repo/unavailable"),
            ],
            labels: [:]
        )
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        let cards = Dictionary(uniqueKeysWithValues: viewModel.cards.map { ($0.id, $0) })
        XCTAssertEqual(cards["ready"]?.overlaps.count, 1)
        XCTAssertEqual(cards["stale"]?.overlaps.count, 1)
        XCTAssertEqual(cards["unavailable"]?.overlaps, [])
        XCTAssertEqual(cards["unavailable"]?.primaryAttention, .live)
    }

    func testEachCardExcludesGitStatesFromOtherGroups() async {
        let firstState = GitSnapshotState.ready(
            snapshot(repository: "/first/.git", worktree: "/first")
        )
        let secondState = GitSnapshotState.unavailable(.notRepository)
        let scanner = FleetRadarScannerFake(responses: [[
            "/first": firstState,
            "/second": secondState,
        ]])
        let viewModel = makeViewModel(scanner: scanner)

        viewModel.update(
            sessions: [
                makeSession(id: "first", workspaceRoot: "/first"),
                makeSession(id: "second", workspaceRoot: "/second"),
            ],
            labels: [:]
        )
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        let cards = Dictionary(uniqueKeysWithValues: viewModel.cards.map { ($0.id, $0) })
        XCTAssertEqual(cards["first"]?.gitStates, ["/first": firstState])
        XCTAssertEqual(cards["first"]?.primaryGitState, firstState)
        XCTAssertEqual(cards["second"]?.gitStates, ["/second": secondState])
        XCTAssertEqual(cards["second"]?.primaryGitState, secondState)
    }

    func testSameWorktreeRootsDeduplicateAndStablySortOverlapPeers() async {
        let paths: Set<String> = ["z.swift", "a.swift"]
        let local = snapshot(worktree: "/repo/main", paths: paths)
        let alpha = snapshot(
            worktree: "/repo/peer-alpha",
            branch: "alpha",
            paths: paths
        )
        let zeta = snapshot(
            worktree: "/repo/peer-zeta",
            branch: "zeta",
            paths: paths
        )
        let scanner = FleetRadarScannerFake(responses: [[
            "/repo/main": .ready(local),
            "/repo/main/Sources": .ready(local),
            "/repo/peer-zeta": .ready(zeta),
            "/repo/peer-alpha": .ready(alpha),
        ]])
        let viewModel = makeViewModel(scanner: scanner)
        let root = makeSession(id: "local", workspaceRoot: "/repo/main")
        let aliasChild = makeSession(
            id: "local-alias",
            parentSessionID: root.id,
            workspaceRoot: "/repo/main/Sources"
        )

        viewModel.update(
            sessions: [
                makeSession(id: "zeta", workspaceRoot: "/repo/peer-zeta"),
                aliasChild,
                makeSession(id: "alpha", workspaceRoot: "/repo/peer-alpha"),
                root,
            ],
            labels: [:]
        )
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        let localCard = try! XCTUnwrap(viewModel.cards.first { $0.id == "local" })
        XCTAssertEqual(localCard.overlaps.map(\.peerBranch), ["alpha", "zeta"])
        XCTAssertEqual(localCard.overlaps.map(\.paths), [["a.swift", "z.swift"], ["a.swift", "z.swift"]])
        XCTAssertEqual(Set(localCard.overlaps.map(\.id)).count, 2)
    }

    func testPrimaryGitStateUsesCanonicalSymlinkRootAheadOfDifferentChild() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("FleetRadarViewModelTests-\(UUID().uuidString)")
        let realRoot = base.appendingPathComponent("real", isDirectory: true)
        let subdirectory = realRoot.appendingPathComponent("Sources", isDirectory: true)
        let childRoot = base.appendingPathComponent("child", isDirectory: true)
        let alias = base.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: childRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: realRoot)
        defer { try? fileManager.removeItem(at: base) }

        let canonicalSubdirectory = subdirectory.resolvingSymlinksInPath().path
        let canonicalChildRoot = childRoot.resolvingSymlinksInPath().path
        let rootSnapshot = snapshot(worktree: realRoot.path)
        let childSnapshot = snapshot(
            repository: "/child/.git",
            worktree: childRoot.path,
            branch: "child"
        )
        let scanner = FleetRadarScannerFake(responses: [[
            canonicalSubdirectory: .stale(rootSnapshot, .timedOut),
            canonicalChildRoot: .ready(childSnapshot),
        ]])
        let viewModel = makeViewModel(scanner: scanner)
        let root = makeSession(
            id: "root",
            workspaceRoot: alias.appendingPathComponent("Sources").path
        )
        let child = makeSession(
            id: "child",
            parentSessionID: root.id,
            workspaceRoot: childRoot.path
        )

        viewModel.update(sessions: [root, child], labels: [:])
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        let call = await scanner.call(at: 0)
        XCTAssertEqual(call.workspaceRoots, [canonicalSubdirectory, canonicalChildRoot])
        XCTAssertEqual(
            Set(viewModel.cards[0].gitStates.keys),
            [canonicalSubdirectory, canonicalChildRoot]
        )
        XCTAssertEqual(
            viewModel.cards[0].primaryGitState,
            .stale(rootSnapshot, .timedOut)
        )
    }

    func testPrimaryGitStateFallsBackToFirstSortedChildWhenRootHasNoWorkspace() async {
        let firstState = GitSnapshotState.unavailable(.notRepository)
        let secondSnapshot = snapshot(worktree: "/repo/second")
        let scanner = FleetRadarScannerFake(responses: [[
            "/repo/first": firstState,
            "/repo/second": .ready(secondSnapshot),
        ]])
        let viewModel = makeViewModel(scanner: scanner)
        let root = makeSession(id: "root", workspaceRoot: nil)
        let firstChild = makeSession(
            id: "first",
            parentSessionID: root.id,
            workspaceRoot: "/repo/first",
            lastActiveAt: date(30)
        )
        let secondChild = makeSession(
            id: "second",
            parentSessionID: root.id,
            workspaceRoot: "/repo/second",
            lastActiveAt: date(20)
        )

        viewModel.update(sessions: [secondChild, root, firstChild], labels: [:])
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        XCTAssertEqual(viewModel.cards[0].group.children.map(\.id), ["first", "second"])
        XCTAssertEqual(viewModel.cards[0].primaryGitState, firstState)
    }

    func testRelativeAndNULRootsRemainUnchangedForScannerValidation() async {
        let relative = "relative/workspace"
        let withNUL = "/tmp/bad\0workspace"
        let scanner = FleetRadarScannerFake(responses: [[
            relative: .unavailable(.missingWorkspace),
            withNUL: .unavailable(.missingWorkspace),
        ]])
        let viewModel = makeViewModel(scanner: scanner)
        let root = makeSession(id: "root", workspaceRoot: relative)
        let child = makeSession(id: "child", parentSessionID: root.id, workspaceRoot: withNUL)

        viewModel.update(sessions: [root, child], labels: [:])
        await scanner.waitForCallCount(1)
        await waitUntilRefreshCompletes(viewModel)

        let call = await scanner.call(at: 0)
        XCTAssertEqual(call.workspaceRoots, [relative, withNUL])
        XCTAssertEqual(Set(viewModel.cards[0].gitStates.keys), [relative, withNUL])
    }

    private func makeViewModel(
        scanner: FleetRadarScannerFake,
        refreshDiscardObserver: (@Sendable () -> Void)? = nil
    ) -> FleetRadarViewModel {
        FleetRadarViewModel(
            scanner: scanner,
            debounceDuration: .zero,
            refreshDiscardObserver: refreshDiscardObserver
        )
    }

    private func waitUntilRefreshCompletes(
        _ viewModel: FleetRadarViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if !viewModel.isRefreshing { return }
            await Task.yield()
        }
        XCTFail("Fleet refresh did not complete", file: file, line: line)
    }

    private func makeSession(
        id: String,
        terminalTitle: String? = nil,
        parentSessionID: String? = nil,
        workspaceRoot: String? = nil,
        lastActiveAt: Date = Date(timeIntervalSince1970: 100),
        isPending: Bool = false,
        hasMissedApproval: Bool = false,
        isUnread: Bool = false,
        status: SessionStatus = .idle
    ) -> ActiveSession {
        ActiveSession(
            id: id,
            terminalTitle: terminalTitle ?? id,
            agentKind: .codex,
            terminal: TerminalContext(),
            lastToolName: "Bash",
            lastEventName: "Stop",
            lastMessage: "Message",
            startTime: Date(timeIntervalSince1970: 0),
            lastActiveAt: lastActiveAt,
            isPending: isPending,
            isLifecycleTracked: true,
            isSubAgentSession: parentSessionID != nil,
            isAutoEditActive: false,
            isUnread: isUnread,
            hasMissedApproval: hasMissedApproval,
            status: status,
            parentSessionId: parentSessionID,
            workspaceRoot: workspaceRoot
        )
    }

    private func snapshot(
        repository: String = "/repo/.git",
        worktree: String,
        branch: String = "main",
        paths: Set<String> = [],
        hasUnmergedEntries: Bool = false
    ) -> GitWorktreeSnapshot {
        GitWorktreeSnapshot(
            repositoryID: GitRepositoryID(commonGitDirectory: repository),
            worktreeID: GitWorktreeID(topLevelPath: worktree),
            branchHead: branch,
            headOID: "0123456789abcdef",
            changedPaths: paths,
            changedEntryCount: paths.count,
            hasUnmergedEntries: hasUnmergedEntries,
            capturedAt: date(100)
        )
    }

    private func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }
}

private actor FleetRadarDiscardSignal {
    private var didSignal = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        didSignal = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !didSignal else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor FleetRadarScannerFake: GitContextScanning {
    struct Call: Sendable {
        let workspaceRoots: Set<String>
        let forceRefresh: Bool
    }

    private let responses: [[String: GitSnapshotState]]
    private let gates: [AsyncGate?]
    private var calls: [Call] = []
    private var callCountWaiters: [(
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    init(
        responses: [[String: GitSnapshotState]],
        gates: [AsyncGate?] = []
    ) {
        self.responses = responses
        self.gates = gates
    }

    func states(
        for workspaceRoots: Set<String>,
        forceRefresh: Bool
    ) async -> [String: GitSnapshotState] {
        let index = calls.count
        calls.append(Call(workspaceRoots: workspaceRoots, forceRefresh: forceRefresh))
        resumeSatisfiedWaiters()
        if index < gates.count, let gate = gates[index] {
            await gate.enterAndWaitForResume()
        }
        guard !responses.isEmpty else { return [:] }
        return responses[min(index, responses.count - 1)]
    }

    func waitForCallCount(_ target: Int) async {
        guard calls.count < target else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((target, continuation))
        }
    }

    func callsCount() -> Int { calls.count }

    func call(at index: Int) -> Call { calls[index] }

    private func resumeSatisfiedWaiters() {
        var pending: [(
            target: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for waiter in callCountWaiters {
            if calls.count >= waiter.target {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        callCountWaiters = pending
    }
}
