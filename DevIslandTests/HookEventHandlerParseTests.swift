import XCTest
@testable import DevIsland

final class HookEventHandlerParseTests: XCTestCase {
    private func parsedEvent(_ json: [String: Any]) -> ParsedHookEvent? {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let message = String(data: data, encoding: .utf8) else { return nil }
        guard case .parsed(let event) = HookEventHandler.parse(message) else { return nil }
        return event
    }

    func testGenericTitleFallsBackToCwdLastComponent() {
        let event = parsedEvent([
            "hook_event_name": "PreToolUse",
            "session_id": "session-1",
            "terminal_title": "Terminal",
            "cwd": "/Users/me/proj"
        ])
        XCTAssertEqual(event?.terminalTitle, "proj")
    }

    func testGenericTitleWithEmptyCwdKeepsGenericTitle() {
        let event = parsedEvent([
            "hook_event_name": "PreToolUse",
            "session_id": "session-1",
            "terminal_title": "Terminal",
            "cwd": ""
        ])
        XCTAssertEqual(event?.terminalTitle, "Terminal")
    }

    func testGenericTitleWithRootCwdKeepsGenericTitle() {
        let event = parsedEvent([
            "hook_event_name": "PreToolUse",
            "session_id": "session-1",
            "terminal_title": "Terminal",
            "cwd": "/"
        ])
        XCTAssertEqual(event?.terminalTitle, "Terminal")
    }

    func testExplicitNonGenericTitleIsPreserved() {
        let event = parsedEvent([
            "hook_event_name": "PreToolUse",
            "session_id": "session-1",
            "terminal_title": "my-project",
            "cwd": "/Users/me/other"
        ])
        XCTAssertEqual(event?.terminalTitle, "my-project")
    }
}
