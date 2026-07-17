import AppKit
import SwiftUI
import XCTest
@testable import DevIsland

@MainActor
final class SessionCenterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var appState: AppState!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SessionCenterTests")
        defaults.removePersistentDomain(forName: "SessionCenterTests")
        appState = AppState(
            startServer: false,
            userDefaults: defaults,
            frontmostCheck: { _ in false },
            enablePlugins: false
        )
    }

    override func tearDown() {
        appState = nil
        defaults.removePersistentDomain(forName: "SessionCenterTests")
        defaults = nil
        super.tearDown()
    }

    func testTabOrderAndDefaultSelection() {
        XCTAssertEqual(SessionCenterTab.allCases, [.fleet, .sessions, .insights])
        XCTAssertEqual(SessionCenterTab.defaultTab, .fleet)
    }

    func testPresentationStateTracksEveryPresentationAndDismissal() {
        let state = SessionCenterPresentationState()

        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.presentationGeneration, 0)

        state.present()
        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.presentationGeneration, 1)

        state.present()
        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.presentationGeneration, 2)

        state.dismiss()
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.presentationGeneration, 2)
    }

    func testHostedWindowControllerReportsWindowClose() {
        var closeCount = 0
        let controller = HostedWindowController(
            title: "Session Center Test",
            size: NSSize(width: 900, height: 560),
            rootView: AnyView(EmptyView()),
            onWindowWillClose: { closeCount += 1 }
        )

        controller.window?.close()

        XCTAssertEqual(closeCount, 1)
    }

    func testSessionCenterWindowTitleFollowsLiveLanguageChanges() {
        let originalLanguage = L10n.shared.language
        addTeardownBlock { L10n.shared.language = originalLanguage }
        L10n.shared.language = .english
        let controller = HostedWindowController(
            localizedTitleKey: "winSessionHistory",
            size: NSSize(width: 900, height: 560),
            rootView: AnyView(EmptyView())
        )

        XCTAssertEqual(controller.window?.title, "Session Center")

        L10n.shared.language = .korean

        XCTAssertEqual(controller.window?.title, "세션 센터")
    }

    func testActiveFleetRendersAtSupportedSizesAndAppearances() async throws {
        let workspaceRoot = "/tmp/session-center-render"
        addOrUpdateSession(workspaceRoot: workspaceRoot, message: "Rendering")
        appState.sessionLabels["session-center"] = "Rendered Fleet Card"

        let configurations: [(NSSize, ColorScheme, NSAppearance.Name)] = [
            (NSSize(width: 900, height: 560), .light, .aqua),
            (NSSize(width: 1280, height: 800), .light, .aqua),
            (NSSize(width: 900, height: 560), .dark, .darkAqua),
            (NSSize(width: 1280, height: 800), .dark, .darkAqua),
        ]

        for (size, colorScheme, appearanceName) in configurations {
            let scanner = SessionCenterScannerStub()
            let fleetViewModel = FleetRadarViewModel(
                scanner: scanner,
                debounceDuration: .zero
            )
            let presentationState = SessionCenterPresentationState()
            presentationState.present()
            let hostingView = NSHostingView(
                rootView: SessionHistoryWindowView(
                    appState: appState,
                    presentationState: presentationState,
                    fleetViewModel: fleetViewModel
                )
                .environment(\.colorScheme, colorScheme)
            )
            hostingView.appearance = NSAppearance(named: appearanceName)
            hostingView.frame = NSRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()

            try await waitForCallCount(scanner, target: 1)
            try await waitForReadyCard(
                fleetViewModel,
                title: "Rendered Fleet Card",
                branch: "feature/session-center",
                dirtyCount: 1
            )
            hostingView.layoutSubtreeIfNeeded()

            let recordedCall = await scanner.call(at: 0)
            let call = try XCTUnwrap(recordedCall)
            let card = try XCTUnwrap(fleetViewModel.cards.first)
            let primarySnapshot: GitWorktreeSnapshot?
            if case let .ready(snapshot) = card.primaryGitState {
                primarySnapshot = snapshot
            } else {
                primarySnapshot = nil
            }
            XCTAssertEqual(call.workspaceRoots, [workspaceRoot])
            XCTAssertFalse(call.forceRefresh)
            XCTAssertEqual(fleetViewModel.cards.count, 1)
            XCTAssertEqual(card.group.root.displayTitle, "Rendered Fleet Card")
            XCTAssertEqual(primarySnapshot?.branchHead, "feature/session-center")
            XCTAssertEqual(primarySnapshot?.changedEntryCount, 1)
            XCTAssertEqual(hostingView.frame.size, size)
            XCTAssertTrue(hostingView.fittingSize.width.isFinite)
            XCTAssertTrue(hostingView.fittingSize.height.isFinite)
            XCTAssertFalse(hasAmbiguousLayout(in: hostingView))
        }
    }

    func testPresentationLifecycleCoalescesRefreshesAndSuppressesHiddenScans() async throws {
        let workspaceRoot = "/tmp/session-center-lifecycle"
        addOrUpdateSession(workspaceRoot: workspaceRoot, message: "Initial")
        appState.sessionLabels["session-center"] = "Initial label"

        let scanner = SessionCenterScannerStub()
        let fleetViewModel = FleetRadarViewModel(scanner: scanner)
        let presentationState = SessionCenterPresentationState()
        presentationState.present()
        let hostingView = NSHostingView(
            rootView: SessionHistoryWindowView(
                appState: appState,
                presentationState: presentationState,
                fleetViewModel: fleetViewModel
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        hostingView.layoutSubtreeIfNeeded()

        try await waitForCallCount(scanner, target: 1)
        appState.sessionLabels["session-center"] = "Updated label"
        addOrUpdateSession(workspaceRoot: workspaceRoot, message: "Updated")
        try await waitForCallCount(scanner, target: 2)
        try await assertNoCall(scanner, target: 3)

        presentationState.dismiss()
        await settleViewUpdates()
        XCTAssertFalse(fleetViewModel.isRefreshing)
        appState.sessionLabels["session-center"] = "Hidden label"
        addOrUpdateSession(workspaceRoot: workspaceRoot, message: "Hidden update")
        try await assertNoCall(scanner, target: 3)

        presentationState.present()
        try await waitForCallCount(scanner, target: 3)
        try await waitForReadyCard(
            fleetViewModel,
            title: "Hidden label",
            branch: "feature/session-center",
            dirtyCount: 1
        )

        let callsCount = await scanner.callsCount()
        let recordedReopenedCall = await scanner.call(at: 2)
        let reopenedCall = try XCTUnwrap(recordedReopenedCall)
        XCTAssertEqual(callsCount, 3)
        XCTAssertEqual(reopenedCall.workspaceRoots, [workspaceRoot])
        XCTAssertFalse(reopenedCall.forceRefresh)
        XCTAssertEqual(hostingView.frame.size, NSSize(width: 900, height: 560))
    }

    private func addOrUpdateSession(workspaceRoot: String, message: String) {
        appState.sessionStore.updateActiveSession(
            sessionId: "session-center",
            terminalTitle: "Injected Session",
            agentKind: .codex,
            terminal: TerminalContext(),
            toolName: "Read",
            eventName: "PostToolUse",
            message: message,
            isPending: false,
            workspaceRoot: workspaceRoot
        )
    }

    private func waitForCallCount(
        _ scanner: SessionCenterScannerStub,
        target: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                await scanner.waitForCallCount(target)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SessionCenterWaitTimeout()
            }
            _ = try await group.next()
        }
    }

    private func waitForReadyCard(
        _ viewModel: FleetRadarViewModel,
        title: String,
        branch: String,
        dirtyCount: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask { @MainActor in
                while true {
                    if viewModel.cards.count == 1,
                       let card = viewModel.cards.first,
                       card.group.root.displayTitle == title,
                       case let .ready(snapshot) = card.primaryGitState,
                       snapshot.branchHead == branch,
                       snapshot.changedEntryCount == dirtyCount {
                        return
                    }
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SessionCenterWaitTimeout()
            }
            _ = try await group.next()
        }
    }

    private func assertNoCall(
        _ scanner: SessionCenterScannerStub,
        target: Int
    ) async throws {
        do {
            try await waitForCallCount(scanner, target: target, timeout: .milliseconds(450))
            XCTFail("Unexpected Fleet refresh call \(target)")
        } catch is SessionCenterWaitTimeout {
            // Expected: a hidden or coalesced update must not reach the scanner.
        }
    }

    private func settleViewUpdates() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    private func hasAmbiguousLayout(in view: NSView) -> Bool {
        view.hasAmbiguousLayout || view.subviews.contains(where: hasAmbiguousLayout)
    }
}

private struct SessionCenterWaitTimeout: Error {}

private actor SessionCenterScannerStub: GitContextScanning {
    struct Call: Sendable {
        let workspaceRoots: Set<String>
        let forceRefresh: Bool
    }

    private struct Waiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var calls: [Call] = []
    private var waiters: [UUID: Waiter] = [:]

    func states(
        for workspaceRoots: Set<String>,
        forceRefresh: Bool
    ) async -> [String: GitSnapshotState] {
        calls.append(Call(workspaceRoots: workspaceRoots, forceRefresh: forceRefresh))
        resumeSatisfiedWaiters()
        return Dictionary(uniqueKeysWithValues: workspaceRoots.map { root in
            (root, .ready(GitWorktreeSnapshot(
                repositoryID: GitRepositoryID(commonGitDirectory: "/tmp/session-center.git"),
                worktreeID: GitWorktreeID(topLevelPath: root),
                branchHead: "feature/session-center",
                headOID: "0123456789abcdef",
                changedPaths: ["Sources/SessionCenter.swift"],
                changedEntryCount: 1,
                hasUnmergedEntries: false,
                capturedAt: Date()
            )))
        })
    }

    func waitForCallCount(_ target: Int) async {
        guard calls.count < target else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if calls.count >= target {
                    continuation.resume()
                } else {
                    waiters[id] = Waiter(target: target, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func callsCount() -> Int { calls.count }

    func call(at index: Int) -> Call? {
        guard calls.indices.contains(index) else { return nil }
        return calls[index]
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = waiters.filter { calls.count >= $0.value.target }
        for (id, waiter) in satisfied {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }
}
