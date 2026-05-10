import XCTest
@testable import DevIsland

final class ProviderAdapterTests: XCTestCase {
    func testClaudePermissionRequestApprovalOutput() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "PermissionRequest",
            source: "claude"
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        let decision = hookOutput?["decision"] as? [String: Any]
        XCTAssertEqual(hookOutput?["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
    }

    func testClaudePermissionRequestDenyOutput() {
        let output = ProviderAdapter.providerOutput(
            decision: "denied",
            event: "PermissionRequest",
            source: "claude"
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        let decision = hookOutput?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
        XCTAssertEqual(decision?["message"] as? String, ProviderAdapter.denialMessage)
    }

    func testCodexLifecycleOutputContinues() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "SessionStart",
            source: "codex"
        )

        XCTAssertEqual(output?["continue"]?.rawValue as? Bool, true)
    }

    func testCodexPreToolUseDenyOutput() {
        let output = ProviderAdapter.providerOutput(
            decision: "denied",
            event: "PreToolUse",
            source: "codex"
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        XCTAssertEqual(hookOutput?["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hookOutput?["permissionDecision"] as? String, "deny")
    }

    func testGeminiDenyOutput() {
        let output = ProviderAdapter.providerOutput(
            decision: "denied",
            event: "BeforeTool",
            source: "gemini"
        )

        XCTAssertEqual(output?["decision"]?.rawValue as? String, "deny")
        XCTAssertEqual(output?["reason"]?.rawValue as? String, ProviderAdapter.denialMessage)
    }

    func testClaudePassOutput() {
        let output = ProviderAdapter.providerOutput(
            decision: "pass",
            event: "PermissionRequest",
            source: "ClaudeCode"
        )

        XCTAssertEqual(output?["continue"]?.rawValue as? Bool, true)
        XCTAssertEqual(output?["suppressOutput"]?.rawValue as? Bool, true)
    }

    func testProviderKindOverloadAvoidsSourceStringBranching() {
        let output = ProviderAdapter.providerOutput(
            decision: "denied",
            event: "BeforeTool",
            provider: .gemini
        )

        XCTAssertEqual(output?["decision"]?.rawValue as? String, "deny")
    }
}
