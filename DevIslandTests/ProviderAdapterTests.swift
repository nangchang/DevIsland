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

    func testClaudePreToolUseApprovalWithoutHandledInputContinues() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "PreToolUse",
            provider: .claude,
            toolName: "Bash",
            toolInput: [
                "command": .string("npm test")
            ]
        )

        XCTAssertEqual(output?["continue"]?.rawValue as? Bool, true)
        XCTAssertEqual(output?["suppressOutput"]?.rawValue as? Bool, true)
        XCTAssertNil(output?["hookSpecificOutput"])
    }

    func testClaudeAskUserQuestionPreToolUseWithoutAnswersContinues() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "PreToolUse",
            provider: .claude,
            toolName: "AskUserQuestion",
            toolInput: [
                "questions": .array([
                    .object([
                        "id": .string("q1"),
                        "prompt": .string("Proceed?")
                    ])
                ])
            ]
        )

        XCTAssertEqual(output?["continue"]?.rawValue as? Bool, true)
        XCTAssertEqual(output?["suppressOutput"]?.rawValue as? Bool, true)
        XCTAssertNil(output?["hookSpecificOutput"])
    }

    func testClaudeAskUserQuestionPreToolUsePreservesExistingAnswers() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "PreToolUse",
            provider: .claude,
            toolName: "AskUserQuestion",
            toolInput: [
                "questions": .array([
                    .object([
                        "id": .string("q1"),
                        "prompt": .string("Proceed?")
                    ])
                ]),
                "answers": .object([
                    "q1": .string("Yes")
                ])
            ]
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        let updatedInput = hookOutput?["updatedInput"] as? [String: Any]
        let questions = updatedInput?["questions"] as? [[String: Any]]
        let answers = updatedInput?["answers"] as? [String: Any]

        XCTAssertEqual(hookOutput?["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hookOutput?["permissionDecision"] as? String, "allow")
        XCTAssertEqual(questions?.first?["id"] as? String, "q1")
        XCTAssertEqual(answers?["q1"] as? String, "Yes")
    }

    func testRichResponseUsesSubmittedQuestionAnswersForProviderOutput() throws {
        let rawResponse = """
        {
            "response": "approved",
            "tool_input": {
                "questions": [
                    {
                        "question": "Which framework?",
                        "options": [
                            { "label": "SwiftUI" },
                            { "label": "AppKit" }
                        ]
                    }
                ],
                "answers": {
                    "Which framework?": "SwiftUI"
                }
            }
        }
        """

        let rich = AppState.richResponseString(
            fromLegacyResponse: rawResponse,
            requestId: "question-request",
            source: "claude",
            event: "PreToolUse",
            toolName: "AskUserQuestion"
        )
        let data = try XCTUnwrap(rich.data(using: .utf8))
        let decoded = try JSONDecoder().decode(IPCRichResponse.self, from: data)
        let hookOutput = decoded.providerOutput?["hookSpecificOutput"]?.rawValue as? [String: Any]
        let updatedInput = hookOutput?["updatedInput"] as? [String: Any]
        let answers = updatedInput?["answers"] as? [String: Any]

        XCTAssertEqual(hookOutput?["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hookOutput?["permissionDecision"] as? String, "allow")
        XCTAssertEqual(answers?["Which framework?"] as? String, "SwiftUI")
    }

    func testClaudeExitPlanModePreToolUseReturnsUpdatedInput() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "PreToolUse",
            provider: .claude,
            toolName: "ExitPlanMode",
            toolInput: [
                "plan": .string("Implement the feature")
            ]
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        let updatedInput = hookOutput?["updatedInput"] as? [String: Any]

        XCTAssertEqual(hookOutput?["permissionDecision"] as? String, "allow")
        XCTAssertEqual(updatedInput?["plan"] as? String, "Implement the feature")
    }

    func testClaudeUserPromptSubmitDenyBlocksPrompt() {
        let output = ProviderAdapter.providerOutput(
            decision: "denied",
            event: "UserPromptSubmit",
            provider: .claude,
            denialMessage: "Prompt contains a secret"
        )

        XCTAssertEqual(output?["decision"]?.rawValue as? String, "block")
        XCTAssertEqual(output?["reason"]?.rawValue as? String, "Prompt contains a secret")
    }

    func testClaudeUserPromptSubmitApprovalContinues() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "UserPromptSubmit",
            provider: .claude
        )

        XCTAssertEqual(output?["continue"]?.rawValue as? Bool, true)
        XCTAssertEqual(output?["suppressOutput"]?.rawValue as? Bool, true)
    }

    func testClaudeElicitationDenyDeclinesRequest() {
        let output = ProviderAdapter.providerOutput(
            decision: "denied",
            event: "Elicitation",
            provider: .claude
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        XCTAssertEqual(hookOutput?["hookEventName"] as? String, "Elicitation")
        XCTAssertEqual(hookOutput?["action"] as? String, "decline")
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

        // PermissionRequest + pass → empty dict so Claude Code falls back to native UI
        XCTAssertNotNil(output)
        XCTAssertTrue(output?.isEmpty == true)
    }

    func testClaudePassNonPermissionRequestOutput() {
        let output = ProviderAdapter.providerOutput(
            decision: "pass",
            event: "PreToolUse",
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

    // MARK: - Normalized event name tests

    func testClaudePreToolUseLowercaseEventRoutes() {
        let output = ProviderAdapter.providerOutput(
            decision: "denied",
            event: "pretooluse",
            provider: .claude,
            toolName: "Bash",
            denialMessage: "Denied by DevIsland."
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        XCTAssertEqual(hookOutput?["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hookOutput?["permissionDecision"] as? String, "deny")
    }

    func testClaudePreToolUseMixedCaseEventRoutes() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "pre_tool_use",
            provider: .claude,
            toolName: "Bash",
            toolInput: ["command": .string("ls")]
        )

        XCTAssertEqual(output?["continue"]?.rawValue as? Bool, true)
        XCTAssertEqual(output?["suppressOutput"]?.rawValue as? Bool, true)
    }

    func testClaudePermissionRequestLowercaseEventRoutes() {
        let output = ProviderAdapter.providerOutput(
            decision: "approved",
            event: "permissionrequest",
            provider: .claude
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        XCTAssertEqual(hookOutput?["hookEventName"] as? String, "PermissionRequest")
        let decision = hookOutput?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
    }

    func testClaudePermissionRequestUppercaseEventRoutes() {
        let output = ProviderAdapter.providerOutput(
            decision: "denied",
            event: "PERMISSIONREQUEST",
            provider: .claude,
            denialMessage: "Denied by DevIsland."
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        XCTAssertEqual(hookOutput?["hookEventName"] as? String, "PermissionRequest")
        let decision = hookOutput?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
    }

    func testClaudePassPermissionRequestLowercaseFallsThrough() {
        let output = ProviderAdapter.providerOutput(
            decision: "pass",
            event: "permissionrequest",
            source: "claude"
        )

        // pass + permissionrequest → empty dict (native UI fallback)
        XCTAssertNotNil(output)
        XCTAssertTrue(output?.isEmpty == true)
    }

    func testCodexPreToolUseLowercaseEventRoutes() {
        let output = ProviderAdapter.providerOutput(
            decision: "denied",
            event: "pretooluse",
            source: "codex",
            denialMessage: "Denied by DevIsland."
        )

        let hookOutput = output?["hookSpecificOutput"]?.rawValue as? [String: Any]
        XCTAssertEqual(hookOutput?["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hookOutput?["permissionDecision"] as? String, "deny")
    }
}
