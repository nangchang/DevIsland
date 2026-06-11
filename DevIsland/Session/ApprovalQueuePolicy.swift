import Foundation

// Pure selection and validation policy for the pending approval queue.
//
// This is the decision half of the `ApprovalRequestCoordinator` proposed in
// issue #239: it decides *which* pending request to display next, whether a
// request is a valid approval request, and whether an incoming request should
// preempt the one currently shown. The stateful display, preemption, and
// timeout machinery remains in `AppState`.
enum ApprovalQueuePolicy {
    // Approval requests take priority over Claude questions in the notch.
    static func isPriority(_ request: PendingRequest) -> Bool {
        request.claudeQuestion == nil
    }

    static func isValidApprovalRequest(_ request: PendingRequest) -> Bool {
        if request.claudeQuestion != nil {
            return request.agentKind == .claudeCode &&
                HookEventNormalizer.normalizedName(request.eventName) == "pretooluse" &&
                HookEventNormalizer.isUserQuestionTool(request.rawToolName)
        }
        return HookEventNormalizer.isApprovalEvent(HookEventNormalizer.normalizedName(request.eventName), for: request.agentKind)
            && (!request.toolName.isEmpty || !request.message.isEmpty)
    }

    // Picks the next request to display: a priority request whose session has a
    // pop-out window first (so it can be acted on directly in that window), then
    // the first priority request, then the head of the queue.
    static func nextToDisplay(in queue: [PendingRequest], hasWindow: (String) -> Bool) -> PendingRequest? {
        let withWindow = queue.first { isPriority($0) && hasWindow($0.sessionId) }
        if let withWindow { return withWindow }

        return queue.first(where: isPriority) ?? queue.first
    }

    // True when an incoming priority request should preempt the request currently
    // shown — i.e. the request is a priority request and what's showing is not.
    static func showingIsLowerPriority(
        than request: PendingRequest,
        showingRequestId: UUID?,
        queue: [PendingRequest]
    ) -> Bool {
        guard isPriority(request),
              let showingRequestId,
              let showing = queue.first(where: { $0.id == showingRequestId }) else {
            return false
        }
        return !isPriority(showing)
    }
}
