import XCTest
@testable import DevIsland

// Snapshot tests for the handleMessage → responseHandler JSON contract.
//
// Every test here pins the *exact set of top-level keys and values* that
// AppState emits for a representative hook scenario. If a refactoring PR
// accidentally adds, removes, or renames a key the affected test turns red.
//
// Coverage matrix (scenario × provider):
//   stop         × claude / codex / gemini
//   notification × claude / codex / gemini
//   pass         × VSCode-bypass / claude-user-question-passthrough
//   normal-mode  × gemini-beforetool (auto-approved)
//   approve      × claude / codex / gemini-interactive
//   deny         × claude / codex
//   policy-deny  × claude-userpromptsubmit
//   question     × claude-askuserquestion
final class GoldenResponseTests: XCTestCase {

    private var appState: AppState!
    private var mockDefaults: UserDefaults!
    private var suiteId: String!

    override func setUp() {
        super.setUp()
        suiteId = "GoldenResponseTests-\(UUID().uuidString)"
        mockDefaults = UserDefaults(suiteName: suiteId)
        appState = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in false }
        )
    }

    override func tearDown() {
        appState = nil
        mockDefaults.removePersistentDomain(forName: suiteId)
        mockDefaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func decoded(_ response: String) -> [String: Any]? {
        guard let data = response.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Asserts that `response` is valid JSON with exactly the key–value pairs
    /// in `expected` and no other top-level keys.
    private func assertGolden(
        _ response: String,
        expected: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let obj = decoded(response) else {
            XCTFail("Not valid JSON: \(response)", file: file, line: line)
            return
        }
        for (key, value) in expected {
            XCTAssertEqual(
                obj[key] as? String, value,
                "'\(key)' mismatch", file: file, line: line
            )
        }
        let extra = Set(obj.keys).subtracting(Set(expected.keys))
        XCTAssertTrue(extra.isEmpty, "Unexpected keys: \(extra)", file: file, line: line)
    }

    /// Spins the run loop in short bursts until `condition` is true or `timeout` elapses.
    /// Prefer this over fixed-duration RunLoop waits so tests exit as soon as the async
    /// work completes rather than always sleeping for the worst-case duration.
    private func spinRunLoop(timeout: TimeInterval = 1.0, until condition: () -> Bool) {
        let limit = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < limit {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func waitForDisplayedPendingRequest(in state: AppState, timeout: TimeInterval = 2.0) {
        spinRunLoop(timeout: timeout) {
            state.sessionStore.pendingCount == 1 && state.hasResponseHandler
        }
    }

    // MARK: - Stop × claude / codex / gemini

    func testClaudeStopYieldsApproved() {
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"sessionend","session_id":"stop-claude","cli_source":"claude"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "approved"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testCodexStopYieldsApproved() {
        // Codex emits "Stop" (not "SessionEnd" which is retired for Codex)
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"Stop","session_id":"stop-codex","cli_source":"codex"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "approved"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testGeminiStopYieldsApproved() {
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"sessionend","session_id":"stop-gemini","cli_source":"gemini"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "approved"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    // MARK: - Notification × claude / codex / gemini

    func testClaudeSessionStartYieldsApproved() {
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"sessionstart","session_id":"notif-claude","cli_source":"claude"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "approved"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testCodexPostToolUseYieldsApproved() {
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"posttooluse","session_id":"notif-codex","cli_source":"codex","tool_name":"shell"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "approved"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testGeminiAfterAgentYieldsApproved() {
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"afteragent","session_id":"notif-gemini","cli_source":"gemini"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "approved"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    // MARK: - Pass (bypass) scenarios

    func testVSCodeBypassYieldsPass() {
        // processVSCodeEnabled defaults to false → all VSCode hooks pass through
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"PermissionRequest","session_id":"pass-vscode","terminal_app":"VSCode","tool_name":"Bash"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "pass"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testClaudeUserQuestionPostToolUseYieldsPass() {
        // PostToolUse carrying a user-question tool name passes through for Claude (Phase 2e)
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"PostToolUse","session_id":"pass-uq","cli_source":"claude","tool_name":"ask_user"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "pass"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    // MARK: - Gemini normal mode (non-interactive, BeforeTool auto-approved)

    func testGeminiNormalModeBeforeToolYieldsApproved() {
        // emulateGeminiInteractiveMode defaults to false → BeforeTool is not an approval event
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"BeforeTool","session_id":"normal-gemini","cli_source":"gemini","tool_name":"shell_command"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "approved"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    // MARK: - Approve × claude / codex / gemini-interactive

    func testClaudePermissionRequestApproveYieldsApproved() {
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"PermissionRequest","session_id":"appr-claude","cli_source":"claude","tool_name":"Bash","tool_input":{"command":"echo hi"}}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "approved"])
            exp.fulfill()
        }
        waitForDisplayedPendingRequest(in: appState)
        XCTAssertEqual(appState.sessionStore.pendingCount, 1)
        XCTAssertTrue(appState.hasResponseHandler)
        appState.approve()
        wait(for: [exp], timeout: 2)
    }

    func testCodexPermissionRequestApproveYieldsApproved() {
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"PermissionRequest","session_id":"appr-codex","cli_source":"codex","tool_name":"shell"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "approved"])
            exp.fulfill()
        }
        waitForDisplayedPendingRequest(in: appState)
        XCTAssertEqual(appState.sessionStore.pendingCount, 1)
        XCTAssertTrue(appState.hasResponseHandler)
        appState.approve()
        wait(for: [exp], timeout: 2)
    }

    func testGeminiInteractiveBeforeToolApproveYieldsApproved() {
        mockDefaults.set(true, forKey: "emulateGeminiInteractiveMode")
        let state = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _ in false }
        )
        let exp = expectation(description: #function)
        state.handleMessage(
            #"{"hook_event_name":"BeforeTool","session_id":"appr-gemini","cli_source":"gemini","tool_name":"shell_command"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "approved"])
            exp.fulfill()
        }
        waitForDisplayedPendingRequest(in: state)
        XCTAssertEqual(state.sessionStore.pendingCount, 1)
        XCTAssertTrue(state.hasResponseHandler)
        state.approve()
        wait(for: [exp], timeout: 2)
    }

    // MARK: - Deny × claude / codex

    func testClaudePermissionRequestDenyYieldsDenied() {
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"PermissionRequest","session_id":"deny-claude","cli_source":"claude","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "denied"])
            exp.fulfill()
        }
        waitForDisplayedPendingRequest(in: appState)
        XCTAssertEqual(appState.sessionStore.pendingCount, 1)
        XCTAssertTrue(appState.hasResponseHandler)
        appState.deny()
        wait(for: [exp], timeout: 2)
    }

    func testCodexPermissionRequestDenyYieldsDenied() {
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"PermissionRequest","session_id":"deny-codex","cli_source":"codex","tool_name":"shell"}"#
        ) { [self] r in
            assertGolden(r, expected: ["response": "denied"])
            exp.fulfill()
        }
        waitForDisplayedPendingRequest(in: appState)
        XCTAssertEqual(appState.sessionStore.pendingCount, 1)
        XCTAssertTrue(appState.hasResponseHandler)
        appState.deny()
        wait(for: [exp], timeout: 2)
    }

    // MARK: - Policy denial (immediate, with reason)

    func testClaudeUserPromptSubmitPolicyDenialYieldsDeniedWithReason() {
        let exp = expectation(description: #function)
        appState.handleMessage(
            #"{"hook_event_name":"UserPromptSubmit","session_id":"policy-deny","cli_source":"claude","prompt":"api_key=sk-secret"}"#
        ) { [self] r in
            guard let obj = decoded(r) else {
                XCTFail("Not valid JSON")
                exp.fulfill()
                return
            }
            XCTAssertEqual(obj["response"] as? String, "denied", "response must be denied")
            XCTAssertNotNil(obj["reason"] as? String, "reason must be present for policy denial")
            let extra = Set(obj.keys).subtracting(["response", "reason"])
            XCTAssertTrue(extra.isEmpty, "Unexpected keys: \(extra)")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    // MARK: - Question × claude (AskUserQuestion structured reply)

    func testClaudeAskUserQuestionSubmitYieldsApprovedWithToolInput() {
        let exp = expectation(description: #function)
        appState.handleMessage("""
            {
                "hook_event_name": "PreToolUse",
                "session_id": "question-claude",
                "cli_source": "claude",
                "tool_name": "AskUserQuestion",
                "tool_input": {
                    "questions": [
                        {
                            "question": "Which framework?",
                            "options": [{"label": "SwiftUI"}, {"label": "AppKit"}]
                        }
                    ]
                }
            }
            """) { [self] r in
            guard let obj = decoded(r) else {
                XCTFail("Not valid JSON"); exp.fulfill(); return
            }
            XCTAssertEqual(obj["response"] as? String, "approved", "response must be approved")
            let toolInput = obj["tool_input"] as? [String: Any]
            XCTAssertNotNil(toolInput?["answers"], "tool_input.answers must be present")
            let extra = Set(obj.keys).subtracting(["response", "tool_input"])
            XCTAssertTrue(extra.isEmpty, "Unexpected keys: \(extra)")
            exp.fulfill()
        }

        waitForDisplayedPendingRequest(in: appState)
        XCTAssertEqual(appState.sessionStore.pendingCount, 1)
        XCTAssertTrue(appState.hasResponseHandler)
        XCTAssertNotNil(appState.currentClaudeQuestion)

        guard let question = appState.currentClaudeQuestion?.questions.first,
              let appKit = question.options.last else {
            XCTFail("Expected parsed question options"); return
        }
        appState.setClaudeQuestionOption(questionId: question.id, optionId: appKit.id)
        appState.submitClaudeQuestion()

        wait(for: [exp], timeout: 2)
        spinRunLoop { appState.sessionStore.pendingCount == 0 }
        XCTAssertEqual(appState.sessionStore.pendingCount, 0)
    }
}
