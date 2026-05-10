import Foundation

struct ClaudePromptPolicy {
    static func denialReason(for prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sensitivePatterns = [
            #"(?i)\b(password|passwd|secret|api[_-]?key|token|private[_-]?key)\s*[:=]\s*\S+"#,
            #"(?i)-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----"#
        ]

        if sensitivePatterns.contains(where: { trimmed.matches(pattern: $0) }) {
            return "Prompt contains a value that looks like a secret. Remove the secret and try again."
        }

        return nil
    }
}

private extension String {
    func matches(pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.firstMatch(in: self, range: range) != nil
    }
}
