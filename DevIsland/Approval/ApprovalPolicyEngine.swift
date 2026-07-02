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
            // Allow rules use full-match to prevent over-granting (S6).
            // Deny rules use substring match to preserve maximum blocking coverage:
            // a deny pattern should catch any tool name that contains it, not just
            // exact matches, so upgrading cannot silently weaken an existing deny rule.
            if rule.action == .allow {
                return regexMatchesFull(pattern: rule.pattern, against: toolName)
            } else {
                return regexMatchesSubstring(pattern: rule.pattern, against: toolName)
            }
        case .commandPrefix:
            guard rule.toolName == toolName,
                  let command = toolInput?["command"] as? String else { return false }
            return commandPrefixMatches(command: command, pattern: rule.pattern, action: rule.action)
        case .pathPrefix:
            guard rule.toolName == toolName else { return false }
            let path = (toolInput?["path"] as? String) ?? (toolInput?["file_path"] as? String)
            guard let path else { return false }
            return path.hasPrefix(rule.pattern)
        }
    }

    private static func commandPrefixMatches(command: String, pattern: String, action: RuleAction) -> Bool {
        guard !pattern.isEmpty, command.hasPrefix(pattern) else { return false }
        guard hasSafeCommandPrefixBoundary(command: command, pattern: pattern) else { return false }
        if action == .deny { return true }
        return !containsShellControlSyntax(command)
    }

    private static func hasSafeCommandPrefixBoundary(command: String, pattern: String) -> Bool {
        guard command.count > pattern.count else { return true }
        guard let patternEnd = pattern.unicodeScalars.last else { return false }

        if CharacterSet.whitespacesAndNewlines.contains(patternEnd) || patternEnd == "/" {
            return true
        }

        let nextIndex = command.index(command.startIndex, offsetBy: pattern.count)
        return command[nextIndex].unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func containsShellControlSyntax(_ command: String) -> Bool {
        if command.contains("$(") || command.contains("=(") { return true }
        for scalar in command.unicodeScalars {
            switch scalar {
            case ";", "&", "|", "<", ">", "`", "\n", "\r", "\0":
                return true
            default:
                continue
            }
        }
        return false
    }

    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func compiledRegex(pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache.setObject(compiled, forKey: key)
        return compiled
    }

    /// Full-string match: compiles with ^(?:pattern)$ so alternation (e.g. "Read|ReadTool")
    /// evaluates correctly. Without anchors, firstMatch returns the leftmost branch ("Read")
    /// and the range comparison would fail for inputs like "ReadTool".
    /// Used for allow rules to prevent over-granting (S6).
    private static func regexMatchesFull(pattern: String, against input: String) -> Bool {
        guard pattern.count <= 200 else { return false }
        guard let regex = compiledRegex(pattern: "^(?:\(pattern))$") else { return false }
        let range = NSRange(input.startIndex..., in: input)
        return regex.firstMatch(in: input, options: [], range: range) != nil
    }

    /// Substring match: the pattern may match anywhere in the tool name.
    /// Used for deny rules to preserve maximum blocking coverage on upgrade.
    private static func regexMatchesSubstring(pattern: String, against input: String) -> Bool {
        guard pattern.count <= 200 else { return false }
        guard let regex = compiledRegex(pattern: pattern) else { return false }
        let range = NSRange(input.startIndex..., in: input)
        return regex.firstMatch(in: input, options: [], range: range) != nil
    }
}
