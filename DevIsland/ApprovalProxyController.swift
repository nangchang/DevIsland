import Foundation

final class ApprovalProxyController {
    let store: SQLiteApprovalStore
    private let policyEngine: ApprovalPolicyEngine

    init(store: SQLiteApprovalStore) {
        self.store = store
        self.policyEngine = ApprovalPolicyEngine(store: store)
    }

    convenience init(databaseURL: URL = SQLiteApprovalStore.defaultDatabaseURL) throws {
        try self.init(store: SQLiteApprovalStore(databaseURL: databaseURL))
    }

    @discardableResult
    func recordHookEvent(
        requestId: String?,
        provider: ProviderKind,
        sessionId: String,
        eventName: String,
        toolName: String,
        payloadJSON: String,
        receivedAt: Date = Date()
    ) throws -> Int64 {
        try store.insertHookEvent(
            requestId: requestId,
            provider: provider,
            sessionId: sessionId,
            eventName: eventName,
            toolName: toolName,
            payloadJSON: payloadJSON,
            receivedAt: receivedAt
        )
    }

    func evaluate(_ request: ApprovalPolicyRequest) throws -> ApprovalPolicyDecision {
        try policyEngine.evaluate(request)
    }

    @discardableResult
    func recordDecision(
        hookEventId: Int64?,
        request: ApprovalPolicyRequest,
        decision: ApprovalPolicyDecision,
        reason: String? = nil,
        decidedAt: Date = Date()
    ) throws -> Int64 {
        try store.insertDecision(
            hookEventId: hookEventId,
            provider: request.provider,
            sessionId: request.sessionId,
            toolName: request.toolName,
            action: decision.action,
            source: decision.source,
            reason: reason,
            decidedAt: decidedAt
        )
    }

    func replayLog(limit: Int = 200) throws -> [ReplayLogEntry] {
        try store.replayLog(limit: limit)
    }
}
