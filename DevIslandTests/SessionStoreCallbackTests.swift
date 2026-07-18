import XCTest
@testable import DevIsland

final class SessionStoreCallbackTests: XCTestCase {
    var store: SessionStore!
    var changes: [SessionStoreChange] = []

    override func setUp() {
        super.setUp()
        store = SessionStore(timeoutDuration: 120, lifecycleSessionTimeout: 86400)
        changes = []
        store.onSessionChanged = { [weak self] change in
            self?.changes.append(change)
        }
    }

    override func tearDown() {
        store = nil
        changes = []
        super.tearDown()
    }

    // MARK: - insert → .started

    func testInsertEmitsStarted() {
        insertSession(id: "s1")

        XCTAssertEqual(changes.count, 1)
        guard case .started(let s) = changes[0] else {
            return XCTFail("expected .started, got \(changes[0])")
        }
        XCTAssertEqual(s.id, "s1")
    }

    // MARK: - update → .updated

    func testUpdateEmitsUpdated() {
        insertSession(id: "s1", toolName: "Read")
        changes.removeAll()

        insertSession(id: "s1", toolName: "Edit")

        XCTAssertEqual(changes.count, 1)
        guard case .updated(let s) = changes[0] else {
            return XCTFail("expected .updated, got \(changes[0])")
        }
        XCTAssertEqual(s.id, "s1")
        XCTAssertEqual(s.lastToolName, "Edit")
    }

    // MARK: - removeSession → .ended with pre-removal snapshot

    func testRemoveSessionEmitsEndedWithSnapshot() {
        insertSession(id: "s1", toolName: "Bash")
        changes.removeAll()

        store.removeSession(id: "s1")

        XCTAssertEqual(changes.count, 1)
        guard case .ended(let s) = changes[0] else {
            return XCTFail("expected .ended, got \(changes[0])")
        }
        XCTAssertEqual(s.id, "s1")
        XCTAssertEqual(s.lastToolName, "Bash")
        XCTAssertTrue(store.activeSessions.isEmpty)
    }

    func testRemoveSessionForMissingIdEmitsNothing() {
        store.removeSession(id: "nonexistent")
        XCTAssertTrue(changes.isEmpty)
    }

    // MARK: - removeSupersededCodexSessions → .ended per removed session

    func testSupersededCodexEmitsEndedPerSession() {
        // Insert two Codex sessions sharing the same TTY
        insertSession(id: "codex-1", agentKind: .codex, terminalTTY: "/dev/ttys001")
        insertSession(id: "codex-2", agentKind: .codex, terminalTTY: "/dev/ttys001")
        changes.removeAll()

        _ = store.removeSupersededCodexSessions(
            newSessionId: "codex-3",
            terminal: TerminalContext(app: "iTerm", tty: "/dev/ttys001")
        )

        XCTAssertEqual(changes.count, 2)
        let endedIds = changes.compactMap { change -> String? in
            guard case .ended(let s) = change else { return nil }
            return s.id
        }
        XCTAssertEqual(Set(endedIds), ["codex-1", "codex-2"])
    }

    // MARK: - pruneInactiveSessions → .ended per pruned session

    func testPruneEmitsEndedForExpiredSessions() {
        let shortStore = SessionStore(timeoutDuration: 0.001, lifecycleSessionTimeout: 86400)
        shortStore.onSessionChanged = { [weak self] change in self?.changes.append(change) }
        insertSession(id: "old-1", store: shortStore)
        insertSession(id: "old-2", store: shortStore)
        changes.removeAll()

        Thread.sleep(forTimeInterval: 0.01)
        _ = shortStore.pruneInactiveSessions()

        let endedIds = changes.compactMap { change -> String? in
            guard case .ended(let s) = change else { return nil }
            return s.id
        }
        XCTAssertEqual(Set(endedIds), ["old-1", "old-2"])
    }

    func testPruneDoesNotEmitForActiveSessions() {
        insertSession(id: "active")
        changes.removeAll()

        _ = store.pruneInactiveSessions()

        XCTAssertTrue(changes.isEmpty)
    }

    // MARK: - no callback registered is safe

    func testNoCallbackRegisteredIsSafe() {
        store.onSessionChanged = nil
        insertSession(id: "s1")
        store.removeSession(id: "s1")
        // No crash expected
    }

    // MARK: - snapshot preserves data from before removal

    func testEndedSnapshotPreservesLastToolName() {
        insertSession(id: "s1", toolName: "Write")
        // Update toolName to "Bash" before removal
        insertSession(id: "s1", toolName: "Bash")
        changes.removeAll()

        store.removeSession(id: "s1")

        guard case .ended(let s) = changes.first else {
            return XCTFail("expected .ended")
        }
        XCTAssertEqual(s.lastToolName, "Bash")
    }

    // MARK: - Helpers

    // MARK: - removeSession cascades to nested sub-agent rows

    func testRemoveParentCascadesToSubAgentChildren() {
        insertSession(id: "parent")
        // Two sub-agent rows nested under the parent.
        store.updateActiveSession(
            sessionId: "child-a", terminalTitle: "default", agentKind: .codex,
            terminal: TerminalContext(), toolName: "Bash", eventName: "PreToolUse",
            message: "m", isPending: false, isSubAgentSession: true, parentSessionId: "parent"
        )
        store.updateActiveSession(
            sessionId: "child-b", terminalTitle: "reviewer", agentKind: .codex,
            terminal: TerminalContext(), toolName: "Read", eventName: "PreToolUse",
            message: "m", isPending: false, isSubAgentSession: true, parentSessionId: "parent"
        )
        changes.removeAll()

        store.removeSession(id: "parent")

        XCTAssertNil(store.activeSessions.first { $0.id == "parent" })
        XCTAssertNil(store.activeSessions.first { $0.id == "child-a" })
        XCTAssertNil(store.activeSessions.first { $0.id == "child-b" })
        // Parent + both children each emit an .ended change.
        let endedIds = changes.compactMap { if case .ended(let s) = $0 { return s.id } else { return nil } }
        XCTAssertEqual(Set(endedIds), ["parent", "child-a", "child-b"])
    }

    private func insertSession(
        id: String,
        agentKind: BuddyKind = .claudeCode,
        terminalTTY: String = "",
        toolName: String = "Read",
        store storeOverride: SessionStore? = nil
    ) {
        let target = storeOverride ?? store!
        target.updateActiveSession(
            sessionId: id,
            terminalTitle: "Terminal",
            agentKind: agentKind,
            terminal: TerminalContext(app: "iTerm", tty: terminalTTY, windowId: "win1", tabIndex: "0"),
            toolName: toolName,
            eventName: "PreToolUse",
            message: "msg",
            isPending: false
        )
    }
}
