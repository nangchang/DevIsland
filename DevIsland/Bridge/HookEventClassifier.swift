import Foundation

// Pure classification of a parsed hook event into the derived flags that
// `AppState.handleParsedEvent` uses to route the event (stop / approval /
// notification) and to render it.
//
// This is the classification half of the `HookEventRouter` proposed in
// issue #239. It deliberately performs no side effects and reads no
// `AppState` instance state — it is a function of `ParsedHookEvent` plus
// the static helpers in `HookEventNormalizer` and `ClaudeQuestionRequest`.
struct HookEventClassification {
    // Display name with the empty-toolName fallbacks applied (Elicitation,
    // User Prompt, …). Use from Phase 2b onward; Phase 1 (sub-agent) keeps
    // using the raw `ParsedHookEvent.displayToolName`.
    let displayToolName: String
    let normalizedEvent: String
    let isUserQuestionTool: Bool
    let claudeQuestion: ClaudeQuestionRequest?
    let isClaudeQuestionRequest: Bool
    let isStop: Bool
    let isApproval: Bool
    let isNotification: Bool
    let isCodexStatusOnlyLifecycleEvent: Bool
    // Tool name to record in the replay log — falls back to the display name
    // when the raw tool name is empty.
    let replayToolName: String
}

enum HookEventClassifier {
    private static let stopEvents: Set<String> = ["exit", "shutdown", "sessionend"]
    private static let notificationEvents: Set<String> = [
        "sessionstart", "notification", "posttooluse", "precompact", "subagentstop",
        "startup", "init", "afteragent"
    ]

    static func classify(_ h: ParsedHookEvent) -> HookEventClassification {
        let normalizedEvent = HookEventNormalizer.normalizedName(h.event)

        var displayToolName = h.displayToolName
        if displayToolName.isEmpty {
            if normalizedEvent == "elicitation" {
                if let serverName = h.parsedJSON["mcp_server_name"] as? String, !serverName.isEmpty {
                    displayToolName = "Elicitation (\(serverName))"
                } else {
                    displayToolName = "Elicitation"
                }
            } else if normalizedEvent == "userpromptsubmit" {
                displayToolName = "User Prompt"
            } else {
                displayToolName = h.toolName
            }
        }

        let isUserQuestionTool = HookEventNormalizer.isUserQuestionTool(h.toolName)
        let claudeQuestion = (h.agentKind == .claudeCode && normalizedEvent == "pretooluse" && isUserQuestionTool)
            ? ClaudeQuestionRequest.parse(toolInput: h.toolInput)
            : nil
        let isClaudeQuestionRequest = claudeQuestion != nil
        let isStop = stopEvents.contains(normalizedEvent)
        let isApproval = isClaudeQuestionRequest
            || (HookEventNormalizer.isApprovalEvent(normalizedEvent, for: h.agentKind) && !isUserQuestionTool)
        let isNotification = (!isStop && !isApproval) || notificationEvents.contains(normalizedEvent)
        let isCodexStatusOnlyLifecycleEvent = h.agentKind == .codex
            && (normalizedEvent == "pretooluse" || normalizedEvent == "posttooluse")
        let replayToolName = h.toolName.isEmpty ? displayToolName : h.toolName

        return HookEventClassification(
            displayToolName: displayToolName,
            normalizedEvent: normalizedEvent,
            isUserQuestionTool: isUserQuestionTool,
            claudeQuestion: claudeQuestion,
            isClaudeQuestionRequest: isClaudeQuestionRequest,
            isStop: isStop,
            isApproval: isApproval,
            isNotification: isNotification,
            isCodexStatusOnlyLifecycleEvent: isCodexStatusOnlyLifecycleEvent,
            replayToolName: replayToolName
        )
    }
}
