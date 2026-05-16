import Foundation

enum CESPEventMapper {
    static func category(
        event: String,
        normalizedEvent: String,
        agentKind: BuddyKind,
        toolName: String,
        notificationType: String,
        message: String,
        payload: [String: Any]?
    ) -> CESPCategory? {
        switch normalizedEvent {
        case "sessionstart", "startup", "init":
            return .sessionStart
        case "permissionrequest", "beforetool", "elicitation":
            return .inputRequired
        case "pretooluse":
            return .taskAcknowledge
        case "posttooluse":
            return isFailurePayload(payload, message: message) ? .taskError : .taskComplete
        case "stop", "afteragent":
            return .taskComplete
        case "sessionend", "exit", "shutdown":
            return .sessionEnd
        case "precompact":
            return .resourceLimit
        case "notification":
            let type = notificationType.lowercased()
            if type == "input_required" || type == "permission_prompt" {
                return .inputRequired
            }
            if containsResourceLimitKeyword(message) {
                return .resourceLimit
            }
            return isFailurePayload(payload, message: message) ? .taskError : nil
        default:
            return isFailurePayload(payload, message: message) ? .taskError : nil
        }
    }

    static func isFailurePayload(_ payload: [String: Any]?, message: String) -> Bool {
        if containsFailureKeyword(message) {
            return true
        }
        guard let payload else { return false }
        return containsFailure(in: payload)
    }

    private static func containsFailure(in value: Any) -> Bool {
        if let dict = value as? [String: Any] {
            for (key, nested) in dict {
                let lowerKey = key.lowercased()
                if ["error", "errors", "exception", "failed", "failure"].contains(lowerKey) {
                    return true
                }
                if lowerKey == "success", let success = nested as? Bool, success == false {
                    return true
                }
                if lowerKey == "status",
                   let status = nested as? String,
                   ["failed", "failure", "error"].contains(status.lowercased()) {
                    return true
                }
                if containsFailure(in: nested) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains { containsFailure(in: $0) }
        } else if let string = value as? String {
            return containsFailureKeyword(string)
        }
        return false
    }

    private static func containsFailureKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Negative lookbehind excludes negated phrases ("no errors", "no timeout").
        // s? covers plurals ("errors", "exceptions"). Underscore is not a \b boundary,
        // so snake_case tokens like "error_code" or "timeout_error" are still matched.
        let pattern = #"(?<!no\s)\b(error|failed|exception|timeout)s?\b"#
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsResourceLimitKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["rate limit", "token", "quota", "context", "limit"].contains { lower.contains($0) }
    }
}
