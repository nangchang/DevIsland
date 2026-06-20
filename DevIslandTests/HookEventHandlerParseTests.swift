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

    func testAuthenticatedEnvelopeRequirementRejectsFramedPlainJSON() {
        let message = #"{"hook_event_name":"SessionStart","session_id":"bypass"}"#

        guard case .denied = HookEventHandler.parse(
            message,
            authentication: .authenticatedEnvelopeRequired,
            validateToken: { _ in true }
        ) else {
            return XCTFail("TCP framed plain JSON must not fall back to legacy parsing")
        }
    }

    func testAuthenticatedEnvelopeRequirementRejectsUnsupportedVersion() {
        let message = envelopeMessage(version: IPCEnvelope.currentVersion + 1, token: "valid")

        guard case .denied = HookEventHandler.parse(
            message,
            authentication: .authenticatedEnvelopeRequired,
            validateToken: { $0 == "valid" }
        ) else {
            return XCTFail("Unsupported IPC versions must be denied")
        }
    }

    func testAuthenticatedEnvelopeRequirementRejectsInvalidToken() {
        let message = envelopeMessage(token: "invalid")

        guard case .denied = HookEventHandler.parse(
            message,
            authentication: .authenticatedEnvelopeRequired,
            validateToken: { $0 == "valid" }
        ) else {
            return XCTFail("Invalid IPC tokens must be denied")
        }
    }

    func testAuthenticatedEnvelopeRequirementAcceptsValidEnvelope() {
        let message = envelopeMessage(token: "valid")

        guard case .parsed(let event) = HookEventHandler.parse(
            message,
            authentication: .authenticatedEnvelopeRequired,
            validateToken: { $0 == "valid" }
        ) else {
            return XCTFail("Valid authenticated envelope should be parsed")
        }
        XCTAssertEqual(event.sessionId, "secure-session")
        XCTAssertEqual(event.requestId, "secure-request")
    }

    private func envelopeMessage(
        version: Int = IPCEnvelope.currentVersion,
        token: String?
    ) -> String {
        let tokenJSON = token.map { #""\#($0)""# } ?? "null"
        return """
        {"protocol":"\(IPCEnvelope.protocolName)","version":\(version),"requestId":"secure-request","sentAt":"2026-06-20T00:00:00Z","token":\(tokenJSON),"source":"claude","payload":{"hook_event_name":"SessionStart","session_id":"secure-session"}}
        """
    }
}
