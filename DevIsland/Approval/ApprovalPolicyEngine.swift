import Foundation
import Darwin

// Policy Engine evaluates approval requests against stored rules.
// Strict priority: persistent deny > session deny > persistent allow > session allow > prompt
//
// Rules are stored in SQLiteApprovalStore (rules + session_cache tables).
// Persistent rules support exact, glob, regex, commandPrefix, and pathPrefix matching.
// commandPrefix and pathPrefix match against toolInput when available.
struct ApprovalPolicyEngine {
    let store: SQLiteApprovalStore

    func evaluate(_ request: ApprovalPolicyRequest) throws -> ApprovalPolicyDecision {
        let persistentMatches = try store.persistentCandidates(for: request)
            .filter { Self.matches($0, request: request) }
        let sessionDecision = try store.sessionDecision(for: request)

        // 1. Persistent deny
        if let deny = persistentMatches.first(where: { $0.action == .deny }) {
            return ApprovalPolicyDecision(action: .deny, source: .persistentRule, ruleId: deny.id)
        }
        // 2. Session deny
        if sessionDecision?.action == .deny {
            return sessionDecision!
        }
        // 3. Persistent allow
        if let allow = persistentMatches.first(where: { $0.action == .allow }) {
            return ApprovalPolicyDecision(action: .allow, source: .persistentRule, ruleId: allow.id)
        }
        // 4. Session allow
        if sessionDecision?.action == .allow {
            return sessionDecision!
        }
        return .prompt
    }

    // MARK: - Matching

    static func matches(_ rule: ApprovalRule, request: ApprovalPolicyRequest) -> Bool {
        matches(rule, toolName: request.toolName, toolInput: request.toolInput)
    }

    static func matches(_ rule: ApprovalRule, toolName: String) -> Bool {
        matches(rule, toolName: toolName, toolInput: nil)
    }

    private static func matches(_ rule: ApprovalRule, toolName: String, toolInput: [String: Any]?) -> Bool {
        switch rule.matchKind {
        case .exact:
            return rule.pattern == toolName
        case .glob:
            return fnmatch(rule.pattern, toolName, FNM_PATHNAME) == 0
        case .regex:
            return regexMatches(pattern: rule.pattern, against: toolName)
        case .commandPrefix:
            guard rule.toolName == toolName,
                  let command = toolInput?["command"] as? String else { return false }
            return command.hasPrefix(rule.pattern)
        case .pathPrefix:
            guard rule.toolName == toolName else { return false }
            let path = (toolInput?["path"] as? String) ?? (toolInput?["file_path"] as? String)
            guard let path else { return false }
            return path.hasPrefix(rule.pattern)
        }
    }

    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func regexMatches(pattern: String, against input: String) -> Bool {
        guard pattern.count <= 200 else { return false }
        let key = pattern as NSString
        let regex: NSRegularExpression
        if let cached = regexCache.object(forKey: key) {
            regex = cached
        } else {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else { return false }
            regexCache.setObject(compiled, forKey: key)
            regex = compiled
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.firstMatch(in: input, options: .withoutAnchoringBounds, range: range) != nil
    }
}
