import XCTest
@testable import DevIsland

final class ApprovalDisplayStateTests: XCTestCase {
    private func populatedState() -> ApprovalDisplayState {
        var state = ApprovalDisplayState()
        state.responseHandler = { _ in }
        state.sessionId = "session-1"
        state.toolName = "Bash"
        state.eventName = "PermissionRequest"
        state.message = "run ls?"
        state.rawToolName = "Bash"
        state.agentKind = .claudeCode
        state.workspaceRoot = "/tmp/project"
        state.hookEventId = 42
        state.isShowingRequest = true
        state.showingRequestId = UUID()
        return state
    }

    func testHasResponseHandlerTracksHandlerPresence() {
        var state = ApprovalDisplayState()
        XCTAssertFalse(state.hasResponseHandler)
        state.responseHandler = { _ in }
        XCTAssertTrue(state.hasResponseHandler)
    }

    func testClearResetsAllFields() {
        var state = populatedState()
        state.clear()

        XCTAssertFalse(state.hasResponseHandler)
        XCTAssertEqual(state.sessionId, "")
        XCTAssertEqual(state.toolName, "")
        XCTAssertEqual(state.eventName, "")
        XCTAssertEqual(state.message, "")
        XCTAssertEqual(state.rawToolName, "")
        XCTAssertNil(state.agentKind)
        XCTAssertNil(state.workspaceRoot)
        XCTAssertNil(state.hookEventId)
        XCTAssertFalse(state.isShowingRequest)
        XCTAssertNil(state.showingRequestId)
    }

    func testClearResponseStateKeepsDisplayedText() {
        var state = populatedState()
        state.clearResponseState()

        XCTAssertFalse(state.hasResponseHandler)
        XCTAssertNil(state.hookEventId)
        XCTAssertFalse(state.isShowingRequest)
        XCTAssertNil(state.showingRequestId)

        XCTAssertEqual(state.sessionId, "session-1")
        XCTAssertEqual(state.toolName, "Bash")
        XCTAssertEqual(state.eventName, "PermissionRequest")
        XCTAssertEqual(state.message, "run ls?")
        XCTAssertEqual(state.rawToolName, "Bash")
        XCTAssertEqual(state.agentKind, .claudeCode)
        XCTAssertEqual(state.workspaceRoot, "/tmp/project")
    }

    func testClearDisplayTextKeepsResponseState() {
        var state = populatedState()
        let showingId = state.showingRequestId
        state.clearDisplayText()

        XCTAssertEqual(state.sessionId, "")
        XCTAssertEqual(state.toolName, "")
        XCTAssertEqual(state.eventName, "")
        XCTAssertEqual(state.message, "")

        XCTAssertTrue(state.hasResponseHandler)
        XCTAssertEqual(state.hookEventId, 42)
        XCTAssertTrue(state.isShowingRequest)
        XCTAssertEqual(state.showingRequestId, showingId)
        XCTAssertEqual(state.rawToolName, "Bash")
        XCTAssertEqual(state.agentKind, .claudeCode)
        XCTAssertEqual(state.workspaceRoot, "/tmp/project")
    }
}
