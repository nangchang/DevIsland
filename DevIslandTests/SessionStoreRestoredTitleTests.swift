import XCTest
@testable import DevIsland

final class SessionStoreRestoredTitleTests: XCTestCase {
    func testExplicitNonGenericTitleWins() {
        XCTAssertEqual(
            SessionStore.restoredTitle(fromPayload: ["terminal_title": "my-project", "cwd": "/Users/me/other"]),
            "my-project"
        )
    }

    func testGenericTitleFallsBackToCwdLastComponent() {
        XCTAssertEqual(
            SessionStore.restoredTitle(fromPayload: ["terminal_title": "Terminal", "cwd": "/Users/me/proj"]),
            "proj"
        )
    }

    func testEmptyTitleIsGenericAndFallsBackToCwd() {
        XCTAssertEqual(
            SessionStore.restoredTitle(fromPayload: ["terminal_title": "", "cwd": "/x/y"]),
            "y"
        )
    }

    func testMissingTitleUsesCwd() {
        XCTAssertEqual(
            SessionStore.restoredTitle(fromPayload: ["cwd": "/a/b/work"]),
            "work"
        )
    }

    func testGenericTitleWithoutCwdReturnsSession() {
        XCTAssertEqual(
            SessionStore.restoredTitle(fromPayload: ["terminal_title": "iTerm"]),
            "Session"
        )
    }

    func testRootCwdReturnsSession() {
        XCTAssertEqual(
            SessionStore.restoredTitle(fromPayload: ["terminal_title": "Terminal", "cwd": "/"]),
            "Session"
        )
    }

    func testEmptyPayloadReturnsSession() {
        XCTAssertEqual(SessionStore.restoredTitle(fromPayload: [:]), "Session")
    }
}
