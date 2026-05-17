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
        switch agentKind {
        case .claudeCode:
            return claudeCategory(normalizedEvent: normalizedEvent, notificationType: notificationType, message: message, payload: payload)
        case .gemini:
            return geminiCategory(normalizedEvent: normalizedEvent, message: message, payload: payload)
        case .codex:
            return codexCategory(normalizedEvent: normalizedEvent, message: message, payload: payload)
        default:
            return commonCategory(normalizedEvent: normalizedEvent, message: message, payload: payload)
        }
    }

    private static func claudeCategory(
        normalizedEvent: String,
        notificationType: String,
        message: String,
        payload: [String: Any]?
    ) -> CESPCategory? {
        switch normalizedEvent {
        case "sessionstart", "startup", "init":
            return .sessionStart
        case "permissionrequest", "elicitation":
            return .inputRequired
        case "pretooluse":
            return .taskAcknowledge
        case "stop":
            // Sound feedback treats Stop as task completion without changing AppState's
            // lifecycle/pruning rules for provider sessions.
            return .taskComplete
        case "sessionend", "exit", "shutdown":
            return .sessionEnd
        case "notification":
            let type = notificationType.lowercased()
            if type == "input_required" || type == "permission_prompt" {
                return .inputRequired
            }
            // For Claude notifications, only treat as error if the type is explicitly error-related.
            // Generic 'message' matching is avoided here because Claude often mentions 'error'
            // in non-failure conversational contexts.
            if type.contains("error") || type.contains("fatal") || type.contains("fail") {
                return .taskError
            }
            // Fall back to checking the machine-readable payload for failure signals,
            // but ignore the descriptive 'message'.
            if let payload, containsFailure(in: payload) {
                return .taskError
            }
            return nil
        default:
            return isFailurePayload(payload, message: message) ? .taskError : nil
        }
    }

    private static func geminiCategory(
        normalizedEvent: String,
        message: String,
        payload: [String: Any]?
    ) -> CESPCategory? {
        switch normalizedEvent {
        case "sessionstart", "startup", "init":
            return .sessionStart
        case "afteragent":
            return .inputRequired
        case "beforetool":
            return .taskAcknowledge
        case "stop":
            // Sound feedback treats Stop as task completion without changing AppState's
            // lifecycle/pruning rules for provider sessions.
            return .taskComplete
        case "precompact":
            return .resourceLimit
        case "notification":
            if containsResourceLimitKeyword(message) {
                return .resourceLimit
            }
            return isFailurePayload(payload, message: message) ? .taskError : nil
        default:
            return isFailurePayload(payload, message: message) ? .taskError : nil
        }
    }

    private static func codexCategory(
        normalizedEvent: String,
        message: String,
        payload: [String: Any]?
    ) -> CESPCategory? {
        switch normalizedEvent {
        case "sessionstart", "startup", "init":
            return .sessionStart
        case "permissionrequest":
            return .inputRequired
        case "pretooluse":
            return .taskAcknowledge
        case "posttooluse":
            // For Codex tool results, prioritize machine-readable signals in the payload.
            // Avoid generic 'message' matching to prevent false positives from conversational text.
            if let payload, containsFailure(in: payload) {
                return .taskError
            }
            // Even if message contains 'error', if payload doesn't confirm it, treat as complete.
            return .taskComplete
        case "sessionend", "exit", "shutdown":
            return .sessionEnd
        default:
            return isFailurePayload(payload, message: message) ? .taskError : nil
        }
    }

    private static func commonCategory(
        normalizedEvent: String,
        message: String,
        payload: [String: Any]?
    ) -> CESPCategory? {
        switch normalizedEvent {
        case "sessionstart", "startup", "init":
            return .sessionStart
        case "permissionrequest", "elicitation", "beforetool":
            return .inputRequired
        case "pretooluse":
            return .taskAcknowledge
        case "posttooluse", "stop", "afteragent":
            return isFailurePayload(payload, message: message) ? .taskError : .taskComplete
        case "sessionend", "exit", "shutdown":
            return .sessionEnd
        default:
            return isFailurePayload(payload, message: message) ? .taskError : nil
        }
    }

    // MARK: - Helpers

    static func isFailurePayload(_ payload: [String: Any]?, message: String) -> Bool {
        if containsFailureKeyword(message) {
            return true
        }
        guard let payload else { return false }
        return containsFailure(in: payload)
    }

    private static let conversationalKeys: Set<String> = ["message", "prompt", "stdout", "stderr", "description"]

    private static func containsFailure(in value: Any, key: String? = nil) -> Bool {
        if let key = key?.lowercased(), conversationalKeys.contains(key) {
            return false
        }

        // This intentionally catches only clear machine-readable or textual failures.
        // User-denied approvals are handled by the approval flow, not as task errors.
        if let dict = value as? [String: Any] {
            for (k, nested) in dict {
                let lowerKey = k.lowercased()
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
                if containsFailure(in: nested, key: k) {
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
        // s? covers plurals ("errors", "exceptions").
        // Note: \b treats _ as a word char, so snake_case ("error_code") and camelCase
        // ("NullPointerException") are not matched here.
        let pattern = #"(?<!no\s)\b(error|failed|exception|timeout)s?\b"#
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsResourceLimitKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["rate limit", "token", "quota", "context", "limit"].contains { lower.contains($0) }
    }
}
