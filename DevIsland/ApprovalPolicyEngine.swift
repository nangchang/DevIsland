import Foundation

// Policy Engine evaluates approval requests against stored rules in priority order:
// 1. explicit persistent deny  2. explicit session deny
// 3. explicit persistent allow  4. explicit session allow
// 5. project/workspace rule  6. heuristic policy  7. fallback policy
//
// Rules are stored in SQLiteApprovalStore (rules + session_cache tables).
// Current implementation performs only exact tool-name matching against stored rules.
//
// TODO(gap-1): Add Glob and Regex matching modes for ApprovalRule.matchKind.
//   Design: ApprovalRule.matchKind: MatchKind { exact, glob, regex, commandPrefix, pathPrefix }
//   - Glob/commandPrefix/pathPrefix: expose in default UI.
//   - Regex: advanced mode only; apply max-length limit, catastrophic-backtracking
//     pattern block, and compile-time validation before storing.
//   See AGENTS.md "Approval Proxy Architecture → Known Gaps" for the full gap list.
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
