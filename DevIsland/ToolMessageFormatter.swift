import Foundation

/// Formats hook event payloads into human-readable display messages for the notch UI.
enum ToolMessageFormatter {

    static func displayMessage(for toolName: String, toolInput: [String: Any]?, json: [String: Any], eventName: String) -> String {
        if HookEventNormalizer.normalizedName(eventName) == "userpromptsubmit",
           let prompt = json["prompt"] as? String {
            return prompt
        }

        if HookEventNormalizer.normalizedName(eventName) == "posttooluse" {
            return postToolMessage(from: json["tool_response"] as? [String: Any])
        }

        if let input = toolInput {
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
                    prefixedBlock("old", input["old_string"] as? String),
                    prefixedBlock("new", input["new_string"] as? String)
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
                    prefixedBlock("old", input["old_string"] as? String),
                    prefixedBlock("new", input["new_string"] as? String)
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
                return joinedMessageLines([
                    input["path"] as? String,
                    input["patch"] as? String
                ])

            default:
                return input.keys.sorted().map { key in
                    "\(key): \(input[key] ?? "")"
                }.joined(separator: "\n")
            }
        }

        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }

        if let suggestions = json["permission_suggestions"] as? [[String: Any]] {
            return suggestions.compactMap { suggestion in
                suggestion["behavior"] as? String
            }.map { "Suggested: \($0)" }.joined(separator: "\n")
        }

        return ""
    }

    static func postToolMessage(from response: [String: Any]?) -> String {
        guard let response = response else { return "Completed" }
        if let stdout = response["stdout"] as? String, !stdout.isEmpty {
            return stdout
        }
        if let stderr = response["stderr"] as? String, !stderr.isEmpty {
            return stderr
        }
        return "Completed"
    }

    private static func multiEditMessage(from input: [String: Any]) -> String {
        var lines: [String] = []
        if let filePath = input["file_path"] as? String {
            lines.append(filePath)
        }
        if let edits = input["edits"] as? [[String: Any]] {
            for (index, edit) in edits.enumerated() {
                lines.append("edit \(index + 1)")
                if let oldBlock = prefixedBlock("old", edit["old_string"] as? String) {
                    lines.append(oldBlock)
                }
                if let newBlock = prefixedBlock("new", edit["new_string"] as? String) {
                    lines.append(newBlock)
                }
            }
        }
        return joinedMessageLines(lines)
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

    static func prefixedBlock(_ label: String, _ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return "\(label):\n\(value)"
    }

    static func joinedMessageLines(_ lines: [String?]) -> String {
        lines.compactMap { line in
            guard let line = line?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
                return nil
            }
            return line
        }.joined(separator: "\n\n")
    }
}
