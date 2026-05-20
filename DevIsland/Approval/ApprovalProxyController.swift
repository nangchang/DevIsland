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
        id: Int64? = nil,
        requestId: String?,
        provider: ProviderKind,
        sessionId: String,
        eventName: String,
        toolName: String,
        payloadJSON: String,
        receivedAt: Date = Date()
    ) throws -> Int64 {
        try store.insertHookEvent(
            id: id,
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

    @discardableResult
    func recordPTYMessage(
        sessionId: String,
        provider: ProviderKind,
        direction: PTYDirection,
        content: String,
        createdAt: Date = Date()
    ) throws -> Int64 {
        try store.insertPTYMessage(
            sessionId: sessionId,
            provider: provider,
            direction: direction,
            content: content,
            createdAt: createdAt
        )
    }

    func ptyMessages(sessionId: String? = nil, limit: Int = 500) throws -> [PTYMessage] {
        try store.ptyMessages(sessionId: sessionId, limit: limit)
    }

    func pruneOldLogs(replayRetentionDays: Int, ptyRetentionDays: Int) throws {
        try store.pruneOldLogs(replayRetentionDays: replayRetentionDays, ptyRetentionDays: ptyRetentionDays)
    }
}
