import Foundation

struct ApprovalPolicyEngine {
    let store: SQLiteApprovalStore

    func evaluate(_ request: ApprovalPolicyRequest) throws -> ApprovalPolicyDecision {
        if let persistentDecision = try store.persistentDecision(for: request) {
            return persistentDecision
        }
        if let sessionDecision = try store.sessionDecision(for: request) {
            return sessionDecision
        }
        return .prompt
    }
}
