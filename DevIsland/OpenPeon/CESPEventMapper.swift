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
        case .antigravity:
            return antigravityCategory(normalizedEvent: normalizedEvent, message: message, payload: payload)
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
        case "posttooluse":
            return nil
        case "posttoolusefailure":
            return .taskError
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

    private static func antigravityCategory(
        normalizedEvent: String,
        message: String,
        payload: [String: Any]?
    ) -> CESPCategory? {
        switch normalizedEvent {
        case "preinvocation":
            return nil
        case "postinvocation":
            return nil
        case "pretooluse":
            return .taskAcknowledge
        case "posttooluse":
            return nil
        case "stop":
            return .taskComplete
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
            if let payload, containsStructuredFailure(in: payload) {
                return .taskError
            }
            // Codex PostToolUse is per-tool output, not turn completion.
            return nil
        case "stop":
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
    private static let outputContainerKeys: Set<String> = ["tool_response"]

    private static func containsStructuredFailure(in value: Any, key: String? = nil) -> Bool {
        if let key = key?.lowercased(), outputContainerKeys.contains(key) {
            guard let dict = value as? [String: Any] else { return false }
            return containsExplicitFailureFields(in: dict)
        }

        if let dict = value as? [String: Any] {
            if containsExplicitFailureFields(in: dict) {
                return true
            }
            for (nestedKey, nested) in dict {
                if containsStructuredFailure(in: nested, key: nestedKey) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains { containsStructuredFailure(in: $0) }
        }
        return false
    }

    private static func containsExplicitFailureFields(in dict: [String: Any]) -> Bool {
        for (key, nested) in dict {
            let lowerKey = key.lowercased()
            if ["error", "errors", "exception", "failed", "failure"].contains(lowerKey),
               hasMeaningfulFailureValue(nested) {
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
        }
        return false
    }

    private static func hasMeaningfulFailureValue(_ value: Any) -> Bool {
        if value is NSNull {
            return false
        }
        if let bool = value as? Bool {
            return bool
        }
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let array = value as? [Any] {
            return !array.isEmpty
        }
        if let dict = value as? [String: Any] {
            return !dict.isEmpty
        }
        return true
    }

    // Legacy/common fallback used outside provider-specific completion mappings.
    // Codex PostToolUse and Claude PostToolUse avoid this text scanner because
    // their tool output can legitimately contain error-related words.
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
