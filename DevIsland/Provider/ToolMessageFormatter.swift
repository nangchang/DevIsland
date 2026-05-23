import Foundation

/// Formats hook event payloads into human-readable display messages for the notch UI.
enum ToolMessageFormatter {

    static func displayMessage(for toolName: String, toolInput: [String: Any]?, json: [String: Any], eventName: String) -> String {
        if HookEventNormalizer.normalizedName(eventName) == "userpromptsubmit",
           let prompt = json["prompt"] as? String {
            return prompt
        }

        if HookEventNormalizer.normalizedName(eventName) == "posttooluse" {
            return postToolMessage(from: json["tool_response"], json: json)
        }

        if HookEventNormalizer.normalizedName(eventName) == "stop" {
            return firstString(
                in: json,
                keys: ["last_assistant_message", "message", "summary", "output", "result"]
            ) ?? ""
        }

        if let input = toolInput {
            if HookEventNormalizer.isUserQuestionTool(toolName),
               let message = userQuestionMessage(from: input) {
                return message
            }

            let lowerToolName = toolName.lowercased()
            switch lowerToolName {
            // Claude Code
            case "bash":
                return joinedMessageLines([
                    input["description"] as? String,
                    input["command"] as? String
                ])
            case "write":
                return joinedMessageLines([
                    input["file_path"] as? String,
                    input["content"] as? String
                ])
            case "edit":
                return joinedMessageLines([
                    input["file_path"] as? String,
                    diffBlock(old: input["old_string"] as? String, new: input["new_string"] as? String)
                ])
            case "multiedit":
                return multiEditMessage(from: input)
            case "read":
                return readMessage(from: input)
            case "webfetch":
                return joinedMessageLines([
                    input["url"] as? String,
                    input["prompt"] as? String
                ])

            // Gemini CLI
            case "run_shell_command":
                return joinedMessageLines([
                    input["description"] as? String,
                    input["command"] as? String
                ])
            case "write_file":
                return joinedMessageLines([
                    input["file_path"] as? String,
                    input["content"] as? String
                ])
            case "read_file":
                return joinedMessageLines([
                    input["file_path"] as? String,
                    "lines: \(input["start_line"] ?? 1) - \(input["end_line"] ?? "")"
                ])
            case "replace":
                return joinedMessageLines([
                    input["file_path"] as? String,
                    input["instruction"] as? String,
                    diffBlock(old: input["old_string"] as? String, new: input["new_string"] as? String)
                ])
            case "grep_search":
                return joinedMessageLines([
                    "pattern: \(input["pattern"] ?? "")",
                    "include: \(input["include_pattern"] ?? "")"
                ])
            case "glob":
                return "pattern: \(input["pattern"] ?? "")"
            case "web_fetch":
                return "prompt: \(input["prompt"] ?? "")"

            // Codex CLI
            case "shell":
                return input["command"] as? String ?? ""
            case "apply_patch":
                if let patch = input["patch"] as? String {
                    return joinedMessageLines([
                        input["path"] as? String,
                        "```diff\n\(patch)\n```"
                    ])
                }
                return input["path"] as? String ?? ""

            default:
                return input.keys.sorted().map { key in
                    "\(key): \(input[key] ?? "")"
                }.joined(separator: "\n")
            }
        }

        if let message = firstString(in: json, keys: ["message", "last_assistant_message"]) {
            return message
        }

        if let suggestions = json["permission_suggestions"] as? [[String: Any]] {
            return suggestions.compactMap { suggestion in
                suggestion["behavior"] as? String
            }.map { "Suggested: \($0)" }.joined(separator: "\n")
        }

        return ""
    }

    private static func userQuestionMessage(from input: [String: Any]) -> String? {
        if let questions = input["questions"] as? [[String: Any]], !questions.isEmpty {
            let blocks = questions.enumerated().compactMap { index, question in
                questionMessage(from: question, index: index + 1, includeOrdinal: questions.count > 1)
            }
            return joinedMessageLines(blocks)
        }

        return questionMessage(from: input, index: 1, includeOrdinal: false)
    }

    private static func questionMessage(from input: [String: Any], index: Int, includeOrdinal: Bool) -> String? {
        var lines: [String] = []
        let title = firstString(in: input, keys: ["header", "title", "label"])
        let body = firstString(in: input, keys: ["question", "prompt", "message", "description", "text"])

        if includeOrdinal {
            lines.append(title.map { "\(index). \($0)" } ?? "Question \(index)")
        } else if let title {
            lines.append(title)
        }

        if let body, body != title {
            lines.append(body)
        }

        if let options = optionsMessage(from: input["options"] ?? input["choices"]) {
            lines.append("Options:\n\(options)")
        }

        if (input["multiSelect"] as? Bool) == true || (input["multi_select"] as? Bool) == true {
            lines.append("Multiple selections allowed")
        }

        return joinedMessageLines(lines)
    }

    private static func optionsMessage(from value: Any?) -> String? {
        guard let value else { return nil }

        let labels: [String]
        if let options = value as? [[String: Any]] {
            labels = options.compactMap { option in
                let label = firstString(in: option, keys: ["label", "title", "value", "id"])
                let description = firstString(in: option, keys: ["description", "detail", "help"])
                guard let label else { return nil }
                if let description, description != label {
                    return "\(label) - \(description)"
                }
                return label
            }
        } else if let options = value as? [String] {
            labels = options
        } else if let options = value as? [Any] {
            labels = options.compactMap { displayString($0) }
        } else {
            labels = []
        }

        guard !labels.isEmpty else { return nil }
        return labels.enumerated()
            .map { index, label in "\(index + 1). \(label)" }
            .joined(separator: "\n")
    }

    private static func postToolMessage(from response: Any?, json: [String: Any]) -> String {
        if let response = response as? [String: Any],
           let message = firstString(in: response, keys: ["stdout", "stderr", "message", "output", "result", "summary"]) {
            return message
        }

        if let message = displayString(response) {
            return message
        }

        if let message = firstString(in: json, keys: ["message", "summary", "output", "result"]) {
            return message
        }

        return "Completed"
    }

    private static func multiEditMessage(from input: [String: Any]) -> String {
        var parts: [String?] = []
        if let filePath = input["file_path"] as? String {
            parts.append(filePath)
        }
        if let edits = input["edits"] as? [[String: Any]] {
            for edit in edits {
                parts.append(diffBlock(old: edit["old_string"] as? String, new: edit["new_string"] as? String))
            }
        }
        return joinedMessageLines(parts)
    }

    private static func readMessage(from input: [String: Any]) -> String {
        var lines: [String] = []
        if let filePath = input["file_path"] as? String {
            lines.append(filePath)
        }
        let details = ["offset", "limit"].compactMap { key -> String? in
            guard let value = input[key] else { return nil }
            return "\(key): \(value)"
        }.joined(separator: ", ")
        if !details.isEmpty {
            lines.append(details)
        }
        return joinedMessageLines(lines)
    }

    private static func diffBlock(old: String?, new: String?) -> String? {
        var lines: [String] = []
        if let old, !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for line in old.components(separatedBy: "\n") {
                lines.append("- \(line)")
            }
        }
        if let new, !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for line in new.components(separatedBy: "\n") {
                lines.append("+ \(line)")
            }
        }
        guard !lines.isEmpty else { return nil }
        return "```diff\n\(lines.joined(separator: "\n"))\n```"
    }

    private static func prefixedBlock(_ label: String, _ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return "\(label):\n\(value)"
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = displayString(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    private static func displayString(_ value: Any?) -> String? {
        guard let value else { return nil }
        let string: String
        if let value = value as? String {
            string = value
        } else if let value = value as? CustomStringConvertible {
            string = value.description
        } else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func joinedMessageLines(_ lines: [String?]) -> String {
        lines.compactMap { line in
            guard let line = line?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
                return nil
            }
            return line
        }.joined(separator: "\n\n")
    }
}
