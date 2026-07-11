import Foundation
import os

/// Records hook events and approval decisions to the replay log (SQLite via ApprovalProxyController).
///
/// Uses pre-reserved negative IDs so that hook-event and decision rows can be inserted on a
/// serial background queue while preserving FK ordering — see `recordHookEvent` for the scheme.
final class ReplayRecorder {
    private let proxy: ApprovalProxyController?
    private let queue: DispatchQueue

    private static let eventIdLock = NSLock()
    private static var nextEventId: Int64 = -Int64(Date().timeIntervalSince1970 * 1_000_000)

    init(proxy: ApprovalProxyController?, queue: DispatchQueue) {
        self.proxy = proxy
        self.queue = queue
    }

    /// Reserves a unique negative event ID, enqueues the insert, and returns the ID immediately.
    /// The caller can attach a decision row to the same serial queue and it will be ordered after the insert.
    @discardableResult
    func recordHookEvent(
        requestId: String?,
        provider: ProviderKind,
        sessionId: String,
        eventName: String,
        toolName: String,
        payload: [String: Any]?
    ) -> Int64? {
        guard let proxy else { return nil }
        let payloadJSON = payload.map { Self.payloadString(from: $0) } ?? "{}"
        let eventId = Self.makeEventId()
        queue.async {
            do {
                try proxy.recordHookEvent(
                    id: eventId,
                    requestId: requestId,
                    provider: provider,
                    sessionId: sessionId,
                    eventName: eventName,
                    toolName: toolName,
                    payloadJSON: payloadJSON
                )
            } catch {
                Log.session.error("Failed to record hook event: \(error, privacy: .private)")
            }
        }
        return eventId
    }

    /// Enqueues a decision insert. If the insert fails when a `hookEventId` was provided,
    /// retries without the FK so the decision is never silently dropped.
    func recordDecision(
        hookEventId: Int64?,
        provider: ProviderKind,
        sessionId: String,
        toolName: String,
        workspaceRoot: String?,
        action: RuleAction,
        source: ApprovalPolicyDecision.Source,
        reason: String?
    ) {
        guard let proxy, !sessionId.isEmpty, !toolName.isEmpty else { return }
        let request = ApprovalPolicyRequest(
            provider: provider,
            sessionId: sessionId,
            toolName: toolName,
            workspaceRoot: workspaceRoot
        )
        let decision = ApprovalPolicyDecision(action: action, source: source, ruleId: nil)
        queue.async {
            do {
                try proxy.recordDecision(
                    hookEventId: hookEventId,
                    request: request,
                    decision: decision,
                    reason: reason
                )
            } catch {
                Log.session.error("Failed to record decision: \(error, privacy: .private)")
                if hookEventId != nil {
                    do {
                        try proxy.recordDecision(
                            hookEventId: nil,
                            request: request,
                            decision: decision,
                            reason: reason
                        )
                    } catch {
                        Log.session.error("Failed to record decision without hook event: \(error, privacy: .private)")
                    }
                }
            }
        }
    }

    static func payloadString(from payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func makeEventId() -> Int64 {
        eventIdLock.lock()
        defer { eventIdLock.unlock() }
        let id = nextEventId
        nextEventId -= 1
        return id
    }
}
