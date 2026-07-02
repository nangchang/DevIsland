import Foundation

// Pure routing of a parsed hook event to the handler `AppState.handleParsedEvent`
// should invoke. This is the dispatch half of the `HookEventRouter` proposed in
// issue #239 (refactoring-plan R2-a); `HookEventClassifier` is the classification
// half and is invoked from here. It performs no side effects and reads no
// `AppState` instance state — it is a function of `ParsedHookEvent` plus the
// snapshots captured by the caller.

/// UserDefaults-derived settings the router needs. Captured once per event by
/// the caller so routing sees one consistent value set.
struct HookRoutingSettings {
    var processVSCode = false
    var processClaudeDesktop = false
    var processCodexDesktop = false
    var emulateGeminiInteractiveMode = false
}

/// Volatile approval state for the event's session. Read by the caller only
/// when an event reaches the approval phase (`route == .approval`) so the
/// session-store read timing stays identical to the pre-extraction code.
struct ApprovalStateSnapshot {
    var globalAutoApproveTools: Set<String> = []
    var sessionAutoApproveTools: Set<String> = []
    var isAutoEditActive = false
    var autoApproveSafeTools = false
}

/// Result of the volatile auto-approve judgment for an approval-phase event.
struct ApprovalRouting: Equatable {
    let isInteractive: Bool
    /// In-memory fast-path verdict: global/bypass/interactive, session tools,
    /// Auto-Edit mode, or the safe-tool option — after the emulation override.
    let isAutoApproved: Bool
    let isAutoEditActive: Bool
    let isSafeAutoApprove: Bool
    /// True when Gemini/Antigravity interactive emulation forced this tool to
    /// require manual approval (caller logs the override).
    let isEmulationForced: Bool
}

/// Routing outcome: which `handleParsedEvent` phase handles the event, plus
/// the classification the downstream handlers render/replay with.
struct RoutedHookEvent {
    enum Route: Equatable {
        /// Terminal integration is disabled in settings — respond `pass`
        /// without recording a replay event.
        case integrationDisabledPass
        /// Sub-agent session lifecycle/status event.
        case subAgent
        /// PTY output chunk — processed separately to avoid replay log pollution.
        case ptyOutput
        /// Session-close event — prune the session and respond approved.
        case stop
        /// Claude UserPromptSubmit blocked by prompt policy.
        case promptPolicyDenied(reason: String)
        /// Claude user-question follow-up (PermissionRequest/PostToolUse) — pass
        /// without notification.
        case userQuestionPassthrough
        /// Status/notification event — update session state and respond.
        case notification
        /// Non-approval event, or Gemini normal mode where BeforeTool is not
        /// enforced — respond approved.
        case nonApprovalAutoApprove(isGeminiNormalMode: Bool)
        /// Approval event with no tool name and no message — respond approved.
        case emptyApprovalAutoApprove
        /// Claude AskUserQuestion structured reply request.
        case claudeQuestion
        /// Approval event that proceeds to the evaluation hierarchy
        /// (focus pass → persistent policy → volatile auto-approve → manual queue).
        case approval
    }

    let route: Route
    let classification: HookEventClassification
}

enum HookEventRouter {

    /// Mirrors `handleParsedEvent`'s phase order: integration bypass → sub-agent
    /// → PTY output → stop → prompt policy → question passthrough → notification
    /// → non-approval guards → question/approval.
    static func route(_ h: ParsedHookEvent, settings: HookRoutingSettings) -> RoutedHookEvent {
        let c = HookEventClassifier.classify(h)

        // When integrations are disabled, "pass" bypasses DevIsland's approval.
        // For Claude/Codex, this delegates to their native terminal prompts.
        // For Gemini, BeforeTool hook returns {} which does not enforce auto-approval itself;
        // rather, Gemini CLI preserves its own configured approval behavior (interactive prompt or --auto-approve).
        switch h.terminal.app {
        case "VSCode" where !settings.processVSCode,
             "ClaudeDesktop" where !settings.processClaudeDesktop,
             "CodexDesktop" where !settings.processCodexDesktop:
            return RoutedHookEvent(route: .integrationDisabledPass, classification: c)
        default:
            break
        }

        if h.isSubAgentSession {
            return RoutedHookEvent(route: .subAgent, classification: c)
        }

        if h.event == "PTYOutput" {
            return RoutedHookEvent(route: .ptyOutput, classification: c)
        }

        if c.isStop {
            return RoutedHookEvent(route: .stop, classification: c)
        }

        if c.normalizedEvent == "userpromptsubmit", h.agentKind == .claudeCode,
           let prompt = h.parsedJSON["prompt"] as? String,
           let denialReason = ClaudePromptPolicy.denialReason(for: prompt) {
            return RoutedHookEvent(route: .promptPolicyDenied(reason: denialReason), classification: c)
        }

        if h.agentKind == .claudeCode,
           (c.normalizedEvent == "permissionrequest" || c.normalizedEvent == "posttooluse"),
           c.isUserQuestionTool {
            return RoutedHookEvent(route: .userQuestionPassthrough, classification: c)
        }

        if c.isNotification {
            return RoutedHookEvent(route: .notification, classification: c)
        }

        let isGeminiNormalMode = h.agentKind == .gemini && !settings.emulateGeminiInteractiveMode
        guard c.isApproval && !isGeminiNormalMode else {
            return RoutedHookEvent(
                route: .nonApprovalAutoApprove(isGeminiNormalMode: isGeminiNormalMode),
                classification: c
            )
        }

        guard !h.toolName.isEmpty || !h.displayMsg.isEmpty else {
            return RoutedHookEvent(route: .emptyApprovalAutoApprove, classification: c)
        }

        if c.isClaudeQuestionRequest {
            return RoutedHookEvent(route: .claudeQuestion, classification: c)
        }

        return RoutedHookEvent(route: .approval, classification: c)
    }

    // [디자인 결정] 툴 필터링 및 자동 승인 전략
    // -------------------------------------------------------------------
    // 1. 완전 무시 (Bypass): 시스템에 영향이 없는 순수 내부 상태/UI 업데이트 툴들.
    //    - 브릿지가 아닌 앱 단계에서 처리하는 이유: 앱이 에이전트의 현재 진행 상태를 계속 추적하여
    //      UI를 동기화하고 세션 상태(예: Auto-Edit 모드 여부)를 관리해야 하기 때문입니다.
    private static let bypassTools: Set<String> = ["update_topic", "activate_skill"]

    /// Volatile auto-approve judgment for an `.approval`-routed event.
    /// (전역 설정 + 세션별 툴 등록 + 현재가 자동 편집 모드인지 + Safe 등급 툴 자동 승인 옵션)
    static func approvalRouting(
        _ h: ParsedHookEvent,
        settings: HookRoutingSettings,
        state: ApprovalStateSnapshot
    ) -> ApprovalRouting {
        // 2. 터미널 유도 알림 (Interactive): 사용자가 터미널에서 직접 키보드 입력을 해야 하는 툴들.
        //    - 목적: "DevIsland에서 승인 클릭" + "터미널에서 Y/Enter 입력" 이라는 '이중 승인'의 번거로움을 해결합니다.
        //    - 동작: 앱에서는 즉시 승인(approved)을 보내어 터미널에 프롬프트가 즉시 뜨게 하되,
        //           노치 UI를 펼쳐 사용자에게 터미널로 돌아가야 함을 알립니다.
        //    - 대상: 직접 입력(ask_user), 계획 승인(exit_plan_mode), 자체 보안 정책상 터미널 확인이 강제되는 툴(run_shell_command),
        //           그리고 계획 단계에서 발생하는 임시 파일 작업들(.gemini/tmp/).
        let isInteractive = GeminiPromptPolicy.isInteractiveTool(h.toolName, isPlanAction: h.isPlanAction)

        var isAutoApprovedGlobal = state.globalAutoApproveTools.contains(h.toolName)
            || bypassTools.contains(h.toolName)
            || isInteractive
        let isAutoApprovedSession = state.sessionAutoApproveTools.contains(h.toolName)
        var isAutoEditActive = state.isAutoEditActive
        let isSafeAutoApprove = state.autoApproveSafeTools && (ToolKnowledge.risk(for: h.toolName) == .safe)

        // [핵심] Gemini 호환 일반 모드 에뮬레이션 로직
        // Gemini/Antigravity가 --auto-approve나 --yolo로 실행되어 터미널 프롬프트가 뜨지 않는 상황일 때,
        // DevIsland가 'Interactive 모드'처럼 위험한 툴을 선별해서 승인 창을 띄웁니다.
        var isEmulationForced = false
        if settings.emulateGeminiInteractiveMode && (h.agentKind == .gemini || h.agentKind == .antigravity) {
            let isExplicitlyApproved = state.globalAutoApproveTools.contains(h.toolName) || isAutoApprovedSession
            if GeminiPromptPolicy.emulationShouldForceApproval(toolName: h.toolName, isExplicitlyApproved: isExplicitlyApproved) {
                isAutoApprovedGlobal = false
                isAutoEditActive = false
                isEmulationForced = true
            }
        }

        return ApprovalRouting(
            isInteractive: isInteractive,
            isAutoApproved: isAutoApprovedGlobal || isAutoApprovedSession || isAutoEditActive || isSafeAutoApprove,
            isAutoEditActive: isAutoEditActive,
            isSafeAutoApprove: isSafeAutoApprove,
            isEmulationForced: isEmulationForced
        )
    }

    /// Codex `clear`/`startup`/`resume` starts supersede that terminal's
    /// previous Codex sessions.
    static func shouldSupersedeCodexSessionsOnStart(source: String) -> Bool {
        let normalized = HookEventNormalizer.normalizedName(source)
        return ["clear", "startup", "resume"].contains(normalized)
    }
}
