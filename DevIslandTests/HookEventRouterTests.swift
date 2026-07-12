import XCTest
@testable import DevIsland

final class HookEventRouterTests: XCTestCase {

    // MARK: - Helpers

    private func parsed(_ json: String) throws -> ParsedHookEvent {
        guard case .parsed(let h) = HookEventHandler.parse(json) else {
            throw XCTSkip("message did not parse into a hook event")
        }
        return h
    }

    private func route(
        _ json: String,
        settings: HookRoutingSettings = HookRoutingSettings()
    ) throws -> RoutedHookEvent {
        HookEventRouter.route(try parsed(json), settings: settings)
    }

    // MARK: - Integration-disabled pass (route precedence over everything)

    func testVSCodeDisabledRoutesToIntegrationPass() throws {
        let r = try route("""
        { "hook_event_name": "PermissionRequest", "session_id": "s1", "terminal_app": "VSCode", "tool_name": "Bash" }
        """)
        XCTAssertEqual(r.route, .integrationDisabledPass)
    }

    func testClaudeDesktopDisabledRoutesToIntegrationPass() throws {
        let r = try route("""
        { "hook_event_name": "PermissionRequest", "session_id": "s1", "terminal_app": "ClaudeDesktop", "tool_name": "Bash" }
        """)
        XCTAssertEqual(r.route, .integrationDisabledPass)
    }

    func testCodexDesktopDisabledRoutesToIntegrationPass() throws {
        let r = try route("""
        { "hook_event_name": "PermissionRequest", "session_id": "s1", "terminal_app": "CodexDesktop", "tool_name": "shell" }
        """)
        XCTAssertEqual(r.route, .integrationDisabledPass)
    }

    func testVSCodeDisabledPassWinsOverStop() throws {
        let r = try route("""
        { "hook_event_name": "SessionEnd", "session_id": "s1", "terminal_app": "VSCode", "cli_source": "claude" }
        """)
        XCTAssertEqual(r.route, .integrationDisabledPass)
    }

    func testVSCodeEnabledRoutesToApproval() throws {
        let r = try route("""
        { "hook_event_name": "PermissionRequest", "session_id": "s1", "terminal_app": "VSCode", "cli_source": "claude", "tool_name": "Bash" }
        """, settings: HookRoutingSettings(processVSCode: true))
        XCTAssertEqual(r.route, .approval)
    }

    // MARK: - Sub-agent / PTY output

    func testSubAgentSessionRoutesToSubAgent() throws {
        let r = try route("""
        { "hook_event_name": "PreToolUse", "session_id": "sub1", "parent_session_id": "parent1", "cli_source": "claude", "tool_name": "Bash" }
        """)
        XCTAssertEqual(r.route, .subAgent)
    }

    func testPTYOutputRoutesToPtyOutput() throws {
        let r = try route("""
        { "hook_event_name": "PTYOutput", "session_id": "s1", "cli_source": "codex", "content": "hello" }
        """)
        XCTAssertEqual(r.route, .ptyOutput)
    }

    // MARK: - Stop / prompt policy / question passthrough / notification

    func testStopEventRoutesToStop() throws {
        let r = try route("""
        { "hook_event_name": "SessionEnd", "session_id": "s1", "cli_source": "claude" }
        """)
        XCTAssertEqual(r.route, .stop)
    }

    func testClaudePromptPolicyDenialRoutesWithReason() throws {
        let r = try route("""
        { "hook_event_name": "UserPromptSubmit", "session_id": "s1", "cli_source": "claude", "prompt": "api_key=sk-secret" }
        """)
        guard case .promptPolicyDenied(let reason) = r.route else {
            return XCTFail("Expected promptPolicyDenied, got \(r.route)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testClaudeSafePromptRoutesToNotification() throws {
        let r = try route("""
        { "hook_event_name": "UserPromptSubmit", "session_id": "s1", "cli_source": "claude", "prompt": "hello world" }
        """)
        XCTAssertEqual(r.route, .notification)
    }

    func testClaudeUserQuestionPostToolUseRoutesToPassthrough() throws {
        let r = try route("""
        { "hook_event_name": "PostToolUse", "session_id": "s1", "cli_source": "claude", "tool_name": "ask_user" }
        """)
        XCTAssertEqual(r.route, .userQuestionPassthrough)
    }

    func testSessionStartRoutesToNotification() throws {
        let r = try route("""
        { "hook_event_name": "sessionstart", "session_id": "s1", "cli_source": "claude" }
        """)
        XCTAssertEqual(r.route, .notification)
    }

    func testCodexPreToolUseRoutesToNotification() throws {
        let r = try route("""
        { "hook_event_name": "PreToolUse", "session_id": "s1", "cli_source": "codex", "tool_name": "shell" }
        """)
        XCTAssertEqual(r.route, .notification)
        XCTAssertTrue(r.classification.isCodexStatusOnlyLifecycleEvent)
    }

    func testWrappedCodexPermissionRequestRoutesToNativeApproval() throws {
        let r = try route("""
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "cli_source": "codex",
            "devisland_approval_owner": "codex",
            "tool_name": "Bash"
        }
        """)
        XCTAssertEqual(r.route, .codexApprovalPassthrough)
    }

    func testWrappedCodexLifecycleEventStillRoutesToNotification() throws {
        let r = try route("""
        {
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "cli_source": "codex",
            "devisland_approval_owner": "codex",
            "tool_name": "Bash"
        }
        """)
        XCTAssertEqual(r.route, .notification)
    }

    func testCodexOwnerMarkerDoesNotAffectClaudeApproval() throws {
        let r = try route("""
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "cli_source": "claude",
            "devisland_approval_owner": "codex",
            "tool_name": "Bash"
        }
        """)
        XCTAssertEqual(r.route, .approval)
    }

    // MARK: - Gemini normal mode / empty approval

    func testGeminiNormalModeBeforeToolRoutesToNonApproval() throws {
        let r = try route("""
        { "hook_event_name": "BeforeTool", "session_id": "s1", "cli_source": "gemini", "tool_name": "run_shell_command" }
        """)
        XCTAssertEqual(r.route, .nonApprovalAutoApprove(isGeminiNormalMode: true))
    }

    func testGeminiEmulationModeBeforeToolRoutesToApproval() throws {
        let r = try route("""
        { "hook_event_name": "BeforeTool", "session_id": "s1", "cli_source": "gemini", "tool_name": "run_shell_command" }
        """, settings: HookRoutingSettings(emulateGeminiInteractiveMode: true))
        XCTAssertEqual(r.route, .approval)
    }

    func testEmptyApprovalRequestRoutesToEmptyAutoApprove() throws {
        let r = try route("""
        { "hook_event_name": "PermissionRequest", "session_id": "s1", "cli_source": "claude" }
        """)
        XCTAssertEqual(r.route, .emptyApprovalAutoApprove)
    }

    // MARK: - Claude question / approval

    func testClaudeAskUserQuestionRoutesToClaudeQuestion() throws {
        let r = try route("""
        {
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "cli_source": "claude",
            "tool_name": "AskUserQuestion",
            "tool_input": { "questions": [ { "question": "Q?", "options": [ { "label": "A" } ] } ] }
        }
        """)
        XCTAssertEqual(r.route, .claudeQuestion)
        XCTAssertNotNil(r.classification.claudeQuestion)
    }

    func testClaudePermissionRequestRoutesToApproval() throws {
        let r = try route("""
        { "hook_event_name": "PermissionRequest", "session_id": "s1", "cli_source": "claude", "tool_name": "Bash" }
        """)
        XCTAssertEqual(r.route, .approval)
    }

    // MARK: - approvalRouting: volatile auto-approve judgment

    private func approvalRouting(
        _ json: String,
        settings: HookRoutingSettings = HookRoutingSettings(),
        state: ApprovalStateSnapshot = ApprovalStateSnapshot()
    ) throws -> ApprovalRouting {
        HookEventRouter.approvalRouting(try parsed(json), settings: settings, state: state)
    }

    private let claudeBashRequest = """
    { "hook_event_name": "PermissionRequest", "session_id": "s1", "cli_source": "claude", "tool_name": "Bash" }
    """

    func testNoRuleMatchesYieldsManualApproval() throws {
        let routing = try approvalRouting(claudeBashRequest)
        XCTAssertFalse(routing.isAutoApproved)
        XCTAssertFalse(routing.isInteractive)
        XCTAssertFalse(routing.isEmulationForced)
    }

    func testBypassToolIsAutoApproved() throws {
        let routing = try approvalRouting("""
        { "hook_event_name": "BeforeTool", "session_id": "s1", "cli_source": "gemini", "tool_name": "update_topic" }
        """)
        XCTAssertTrue(routing.isAutoApproved)
    }

    func testInteractiveToolIsAutoApprovedAndFlagged() throws {
        let routing = try approvalRouting("""
        { "hook_event_name": "BeforeTool", "session_id": "s1", "cli_source": "gemini", "tool_name": "exit_plan_mode" }
        """)
        XCTAssertTrue(routing.isInteractive)
        XCTAssertTrue(routing.isAutoApproved)
    }

    func testPlanActionFileEditIsInteractive() throws {
        let routing = try approvalRouting("""
        {
            "hook_event_name": "BeforeTool",
            "session_id": "s1",
            "cli_source": "gemini",
            "tool_name": "write_file",
            "tool_input": { "file_path": "/work/.gemini/tmp/plan.md" }
        }
        """)
        XCTAssertTrue(routing.isInteractive)
        XCTAssertTrue(routing.isAutoApproved)
    }

    func testGlobalAutoApproveToolIsAutoApproved() throws {
        let routing = try approvalRouting(
            claudeBashRequest,
            state: ApprovalStateSnapshot(globalAutoApproveTools: ["Bash"])
        )
        XCTAssertTrue(routing.isAutoApproved)
    }

    func testSessionAutoApproveToolIsAutoApproved() throws {
        let routing = try approvalRouting(
            claudeBashRequest,
            state: ApprovalStateSnapshot(sessionAutoApproveTools: ["Bash"])
        )
        XCTAssertTrue(routing.isAutoApproved)
    }

    func testAutoEditModeIsAutoApproved() throws {
        let routing = try approvalRouting(
            claudeBashRequest,
            state: ApprovalStateSnapshot(isAutoEditActive: true)
        )
        XCTAssertTrue(routing.isAutoApproved)
        XCTAssertTrue(routing.isAutoEditActive)
    }

    func testSafeToolWithSafeAutoApproveOptionIsAutoApproved() throws {
        let routing = try approvalRouting("""
        { "hook_event_name": "PermissionRequest", "session_id": "s1", "cli_source": "claude", "tool_name": "Read" }
        """, state: ApprovalStateSnapshot(autoApproveSafeTools: true))
        XCTAssertTrue(routing.isSafeAutoApprove)
        XCTAssertTrue(routing.isAutoApproved)
    }

    func testRiskyToolWithSafeAutoApproveOptionIsNotAutoApproved() throws {
        let routing = try approvalRouting(
            claudeBashRequest,
            state: ApprovalStateSnapshot(autoApproveSafeTools: true)
        )
        XCTAssertFalse(routing.isSafeAutoApprove)
        XCTAssertFalse(routing.isAutoApproved)
    }

    // MARK: - approvalRouting: Gemini/Antigravity emulation override

    private let geminiShellRequest = """
    { "hook_event_name": "BeforeTool", "session_id": "s1", "cli_source": "gemini", "tool_name": "run_shell_command" }
    """

    func testEmulationForcesApprovalForRiskyInteractiveTool() throws {
        // run_shell_command is interactive (auto-approved by default), but emulation
        // must force the approval UI for non-safe tools the user has not registered.
        let routing = try approvalRouting(
            geminiShellRequest,
            settings: HookRoutingSettings(emulateGeminiInteractiveMode: true),
            state: ApprovalStateSnapshot(isAutoEditActive: true)
        )
        XCTAssertTrue(routing.isEmulationForced)
        XCTAssertFalse(routing.isAutoApproved)
        XCTAssertFalse(routing.isAutoEditActive, "emulation must clear Auto-Edit for forced tools")
    }

    func testEmulationSkipsExplicitlyApprovedTool() throws {
        let routing = try approvalRouting(
            geminiShellRequest,
            settings: HookRoutingSettings(emulateGeminiInteractiveMode: true),
            state: ApprovalStateSnapshot(globalAutoApproveTools: ["run_shell_command"])
        )
        XCTAssertFalse(routing.isEmulationForced)
        XCTAssertTrue(routing.isAutoApproved)
    }

    func testEmulationDoesNotForceSafeTool() throws {
        let routing = try approvalRouting("""
        { "hook_event_name": "BeforeTool", "session_id": "s1", "cli_source": "gemini", "tool_name": "view_file" }
        """, settings: HookRoutingSettings(emulateGeminiInteractiveMode: true))
        XCTAssertFalse(routing.isEmulationForced)
    }

    func testEmulationAppliesToAntigravity() throws {
        let routing = try approvalRouting("""
        { "hook_event_name": "BeforeTool", "session_id": "s1", "cli_source": "antigravity", "tool_name": "run_shell_command" }
        """, settings: HookRoutingSettings(emulateGeminiInteractiveMode: true))
        XCTAssertTrue(routing.isEmulationForced)
        XCTAssertFalse(routing.isAutoApproved)
    }

    func testEmulationDoesNotApplyToClaude() throws {
        let routing = try approvalRouting(
            claudeBashRequest,
            settings: HookRoutingSettings(emulateGeminiInteractiveMode: true)
        )
        XCTAssertFalse(routing.isEmulationForced)
    }

    // MARK: - Codex session supersede on start

    func testCodexStartSourcesSupersedeSessions() {
        XCTAssertTrue(HookEventRouter.shouldSupersedeCodexSessionsOnStart(source: "clear"))
        XCTAssertTrue(HookEventRouter.shouldSupersedeCodexSessionsOnStart(source: "Startup"))
        XCTAssertTrue(HookEventRouter.shouldSupersedeCodexSessionsOnStart(source: "resume"))
        XCTAssertFalse(HookEventRouter.shouldSupersedeCodexSessionsOnStart(source: "compact"))
        XCTAssertFalse(HookEventRouter.shouldSupersedeCodexSessionsOnStart(source: ""))
    }
}
