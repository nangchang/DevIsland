import Foundation
import Darwin

// Policy Engine evaluates approval requests against stored rules.
// Current evaluation order: persistent rules → session cache rules → prompt
// Within persistent rules, deny-first ordering is applied via SQL ORDER BY.
//
// TODO: Implement strict cross-scope priority:
//   persistent deny > session deny > persistent allow > session allow
//   Currently a persistent allow can override a session deny.
//
// Rules are stored in SQLiteApprovalStore (rules + session_cache tables).
// Persistent rules support exact, glob, regex, commandPrefix, and pathPrefix matching.
struct ApprovalPolicyEngine {
    let store: SQLiteApprovalStore

    func evaluate(_ request: ApprovalPolicyRequest) throws -> ApprovalPolicyDecision {
        if let decision = try persistentDecision(for: request) {
            return decision
        }
        if let sessionDecision = try store.sessionDecision(for: request) {
            return sessionDecision
        }
        return .prompt
    }

    // MARK: - Matching

    private func persistentDecision(for request: ApprovalPolicyRequest) throws -> ApprovalPolicyDecision? {
        let candidates = try store.persistentCandidates(for: request)
        guard let matched = candidates.first(where: { Self.matches($0, toolName: request.toolName) }) else {
            return nil
        }
        return ApprovalPolicyDecision(action: matched.action, source: .persistentRule, ruleId: matched.id)
    }

    static func matches(_ rule: ApprovalRule, toolName: String) -> Bool {
        switch rule.matchKind {
        case .exact:
            return rule.pattern == toolName
        case .glob:
            return fnmatch(rule.pattern, toolName, FNM_PATHNAME) == 0
        case .regex:
            return regexMatches(pattern: rule.pattern, against: toolName)
        case .commandPrefix, .pathPrefix:
            return toolName.hasPrefix(rule.pattern)
        }
    }

    private static func regexMatches(pattern: String, against input: String) -> Bool {
        guard pattern.count <= 200 else { return false }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(input.startIndex..., in: input)
        return regex.firstMatch(in: input, options: .withoutAnchoringBounds, range: range) != nil
    }
}
