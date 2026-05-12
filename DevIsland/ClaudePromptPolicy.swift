import Foundation

struct ClaudePromptPolicy {
    private static let sensitiveRegexes: [NSRegularExpression] = {
        let patterns = [
            #"(?i)\b(password|passwd|secret|api[_-]?key|token|private[_-]?key)\s*[:=]\s*\S+"#,
            #"(?i)-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func denialReason(for prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if sensitiveRegexes.contains(where: { $0.firstMatch(in: trimmed, range: range) != nil }) {
            return "Prompt contains a value that looks like a secret. Remove the secret and try again."
        }

        return nil
    }
}
