import XCTest
@testable import DevIsland

/// AppState init 직후의 플러그인/Caffeine 배선 상태를 고정한다 (R2-d 안전망).
/// 배선 로직이 AppWiring으로 이동해도 이 테스트는 변경 없이 통과해야 한다.
@MainActor
final class AppWiringTests: XCTestCase {
    private var mockDefaults: UserDefaults!
    private var appState: AppState!

    override func setUp() {
        super.setUp()
        mockDefaults = UserDefaults(suiteName: "AppWiringTests")
        mockDefaults.removePersistentDomain(forName: "AppWiringTests")
        appState = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in false }
        )
    }

    override func tearDown() {
        appState = nil
        mockDefaults.removePersistentDomain(forName: "AppWiringTests")
        mockDefaults = nil
        super.tearDown()
    }

    // MARK: - Plugin host callbacks

    func testPluginHostCallbacksAreWiredAfterInit() {
        XCTAssertNotNil(appState.pluginHost.sessionCommandHandler)
        XCTAssertNotNil(appState.pluginHost.selectedSessionProvider)
        XCTAssertNotNil(appState.pluginHost.compactRegionSelectionProvider)
        XCTAssertNotNil(appState.pluginHost.activeSessionsProvider)
    }

    func testSessionStoreChangeCallbackIsWiredAfterInit() {
        XCTAssertNotNil(appState.sessionStore.onSessionChanged)
    }

    func testSelectedSessionProviderTracksSelectedSession() {
        appState.sessionStore.selectedSessionId = "session-abc"
        XCTAssertEqual(appState.pluginHost.selectedSessionProvider?(), "session-abc")
    }

    func testActiveSessionsProviderReturnsSnapshotsOfActiveSessions() {
        appState.sessionStore.updateActiveSession(
            sessionId: "session-xyz",
            terminalTitle: "Terminal",
            agentKind: .claudeCode,
            terminal: TerminalContext(app: "iTerm", tty: "", windowId: "win1", tabIndex: "0"),
            toolName: "Read",
            eventName: "PreToolUse",
            message: "msg",
            isPending: false
        )
        let snapshots = appState.pluginHost.activeSessionsProvider?() ?? []
        XCTAssertEqual(snapshots.map(\.id), ["session-xyz"])
    }

    // MARK: - Caffeine

    func testCaffeineStatusCallbackIsWiredAfterInit() {
        XCTAssertNotNil(appState.caffeineCoordinator.onStatusChanged)
    }
}
