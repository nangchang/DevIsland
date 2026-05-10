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

    func testClaudeSessionApprovalIncludesNativeUpdatedPermissions() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "PermissionRequest",
            provider: .claude,
            approvalScope: .session,
            toolName: "Bash",
            ruleContent: "npm test",
            claudeSessionApprovalMode: .nativePermissions
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        let decision = hookOutput?["decision"] as? [String: Any]
        let updatedPermissions = decision?["updatedPermissions"] as? [[String: Any]]
        let update = updatedPermissions?.first
        let rules = update?["rules"] as? [[String: Any]]

        XCTAssertEqual(update?["type"] as? String, "addRules")
        XCTAssertEqual(update?["behavior"] as? String, "allow")
        XCTAssertEqual(update?["destination"] as? String, "session")
        XCTAssertEqual(rules?.first?["toolName"] as? String, "Bash")
        XCTAssertEqual(rules?.first?["ruleContent"] as? String, "npm test")
    }

    func testClaudeAppSessionCacheModeDoesNotEmitUpdatedPermissions() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "PermissionRequest",
            provider: .claude,
            approvalScope: .session,
            toolName: "Bash",
            ruleContent: "npm test",
            claudeSessionApprovalMode: .appSessionCache
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        let decision = hookOutput?["decision"] as? [String: Any]

        XCTAssertNil(decision?["updatedPermissions"])
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
    }

    func testClaudePersistentApprovalUsesConfiguredDestination() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "PermissionRequest",
            provider: .claude,
            approvalScope: .persistent,
            toolName: "Bash",
            ruleContent: "npm test",
            claudePersistentApprovalDestination: .projectSettings
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        let decision = hookOutput?["decision"] as? [String: Any]
        let updatedPermissions = decision?["updatedPermissions"] as? [[String: Any]]

        XCTAssertEqual(updatedPermissions?.first?["destination"] as? String, "projectSettings")
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
