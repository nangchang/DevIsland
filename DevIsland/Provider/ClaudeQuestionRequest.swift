import Foundation

struct ClaudeQuestionRequest: Equatable {
    struct Option: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
        let detail: String?
        let preview: String?
    }

    struct Question: Identifiable, Equatable {
        let id: String
        let answerKey: String
        let title: String?
        let prompt: String
        let options: [Option]
        let allowsMultipleSelection: Bool
        let allowsTextInput: Bool
    }

    let originalInput: [String: AnyJSON]
    let questions: [Question]

    var isEmpty: Bool {
        questions.isEmpty
    }

    static func parse(toolInput: [String: Any]?) -> ClaudeQuestionRequest? {
        guard let toolInput else { return nil }
        guard let originalInput = AnyJSON.object(from: toolInput) else { return nil }

        let rawQuestions: [[String: Any]]
        if let questions = toolInput["questions"] as? [[String: Any]], !questions.isEmpty {
            rawQuestions = questions
        } else {
            rawQuestions = [toolInput]
        }

        let questions = rawQuestions.enumerated().compactMap { index, rawQuestion in
            Question.parse(rawQuestion, index: index)
        }
        guard !questions.isEmpty else { return nil }
        return ClaudeQuestionRequest(originalInput: originalInput, questions: questions)
    }

    func updatedInput(answers: [String: ClaudeQuestionAnswer]) -> [String: AnyJSON]? {
        var output = originalInput
        var answerObject: [String: AnyJSON] = [:]

        for question in questions {
            guard let answer = answers[question.id],
                  let value = answer.jsonValue(for: question) else {
                return nil
            }
            answerObject[question.answerKey] = value
        }

        guard !answerObject.isEmpty else { return nil }
        output["answers"] = .object(answerObject)
        return output
    }
}

struct ClaudeQuestionAnswer: Equatable {
    var selectedOptionIds: Set<String> = []
    var usesCustomText = false
    var text: String = ""

    func jsonValue(for question: ClaudeQuestionRequest.Question) -> AnyJSON? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.options.isEmpty {
            return trimmed.isEmpty ? nil : .string(trimmed)
        }

        let selectedOptions = question.options.filter { selectedOptionIds.contains($0.id) }
        if question.allowsMultipleSelection {
            var values = selectedOptions.map { AnyJSON.string($0.value) }
            if usesCustomText && !trimmed.isEmpty {
                values.append(.string(trimmed))
            }
            guard !values.isEmpty else { return nil }
            return .array(values)
        }

        if usesCustomText {
            return trimmed.isEmpty ? nil : .string(trimmed)
        }

        guard let selected = selectedOptions.first else { return nil }
        return .string(selected.value)
    }
}

extension ClaudeQuestionRequest.Question {
    fileprivate static func parse(_ raw: [String: Any], index: Int) -> ClaudeQuestionRequest.Question? {
        let title = firstString(in: raw, keys: ["header", "title", "label"])
        let prompt = firstString(in: raw, keys: ["question", "prompt", "message", "description", "text"])
            ?? title
            ?? "Question \(index + 1)"
        let answerKey = prompt
        let options = parseOptions(raw["options"] ?? raw["choices"])
        let allowsMultipleSelection = boolValue(raw["multiSelect"])
            ?? boolValue(raw["multi_select"])
            ?? boolValue(raw["multiple"])
            ?? false
        let explicitTextInput = boolValue(raw["textInput"])
            ?? boolValue(raw["text_input"])
            ?? boolValue(raw["freeform"])
            ?? boolValue(raw["allowCustom"])
            ?? boolValue(raw["allow_custom"])
        let allowsTextInput = explicitTextInput ?? true

        return ClaudeQuestionRequest.Question(
            id: stableQuestionId(raw: raw, prompt: prompt, index: index),
            answerKey: answerKey,
            title: title,
            prompt: prompt,
            options: options,
            allowsMultipleSelection: allowsMultipleSelection,
            allowsTextInput: allowsTextInput
        )
    }

    private static func parseOptions(_ value: Any?) -> [ClaudeQuestionRequest.Option] {
        if let options = value as? [[String: Any]] {
            return options.enumerated().compactMap { index, option in
                let label = firstString(in: option, keys: ["label", "title", "value", "id"])
                let value = firstString(in: option, keys: ["value", "label", "title", "id"])
                guard let label, let value else { return nil }
                return ClaudeQuestionRequest.Option(
                    id: stableOptionId(raw: option, label: label, index: index),
                    label: label,
                    value: value,
                    detail: firstString(in: option, keys: ["description", "detail", "help"]),
                    preview: firstString(in: option, keys: ["preview"])
                )
            }
        }

        if let options = value as? [String] {
            return options.enumerated().map { index, option in
                ClaudeQuestionRequest.Option(
                    id: "option-\(index)-\(option)",
                    label: option,
                    value: option,
                    detail: nil,
                    preview: nil
                )
            }
        }

        if let options = value as? [Any] {
            return options.enumerated().compactMap { index, option in
                guard let label = displayString(option) else { return nil }
                return ClaudeQuestionRequest.Option(
                    id: "option-\(index)-\(label)",
                    label: label,
                    value: label,
                    detail: nil,
                    preview: nil
                )
            }
        }

        return []
    }

    private static func stableQuestionId(raw: [String: Any], prompt: String, index: Int) -> String {
        firstString(in: raw, keys: ["id", "key", "name"]) ?? "question-\(index)-\(prompt)"
    }

    private static func stableOptionId(raw: [String: Any], label: String, index: Int) -> String {
        firstString(in: raw, keys: ["id", "key", "value", "label"]) ?? "option-\(index)-\(label)"
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        if let int = value as? Int { return int != 0 }
        return nil
    }

    private static func displayString(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
