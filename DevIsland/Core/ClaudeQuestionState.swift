import Foundation

/// Manages Claude AskUserQuestion interactive state:
/// the current question being displayed and the user's in-progress answers.
///
/// AppState owns an instance and forwards its `objectWillChange` to its own,
/// so SwiftUI views that observe `AppState` re-render automatically when this state changes.
/// Views that bind to this object directly may also hold it as `@ObservedObject`.
final class ClaudeQuestionState: ObservableObject {
    @Published var currentClaudeQuestion: ClaudeQuestionRequest?
    @Published var currentClaudeQuestionAnswers: [String: ClaudeQuestionAnswer] = [:]

    // MARK: - Mutation helpers

    func reset() {
        currentClaudeQuestion = nil
        currentClaudeQuestionAnswers = [:]
    }

    func setQuestion(_ question: ClaudeQuestionRequest, answers: [String: ClaudeQuestionAnswer]) {
        currentClaudeQuestion = question
        currentClaudeQuestionAnswers = answers
    }

    // MARK: - Answer editing

    func setOption(questionId: String, optionId: String) {
        guard let question = currentClaudeQuestion?.questions.first(where: { $0.id == questionId }) else { return }
        var answer = currentClaudeQuestionAnswers[questionId] ?? ClaudeQuestionAnswer()
        if !question.allowsMultipleSelection {
            answer.usesCustomText = false
        }
        if question.allowsMultipleSelection {
            if answer.selectedOptionIds.contains(optionId) {
                answer.selectedOptionIds.remove(optionId)
            } else {
                answer.selectedOptionIds.insert(optionId)
            }
        } else {
            answer.selectedOptionIds = [optionId]
        }
        currentClaudeQuestionAnswers[questionId] = answer
    }

    func setCustomAnswerEnabled(questionId: String, isEnabled: Bool) {
        guard let question = currentClaudeQuestion?.questions.first(where: { $0.id == questionId }) else { return }
        var answer = currentClaudeQuestionAnswers[questionId] ?? ClaudeQuestionAnswer()
        answer.usesCustomText = isEnabled
        if isEnabled && !question.allowsMultipleSelection {
            answer.selectedOptionIds = []
        }
        currentClaudeQuestionAnswers[questionId] = answer
    }

    func setText(questionId: String, text: String) {
        var answer = currentClaudeQuestionAnswers[questionId] ?? ClaudeQuestionAnswer()
        answer.text = text
        currentClaudeQuestionAnswers[questionId] = answer
    }

    // MARK: - Submission validation

    func canSubmit() -> Bool {
        guard let question = currentClaudeQuestion else { return false }
        return question.updatedInput(answers: currentClaudeQuestionAnswers) != nil
    }

    /// Builds the tool-input payload to send as the submit decision.
    /// Returns nil if no question is active or the current answers are incomplete.
    func buildSubmitInput() -> [String: AnyJSON]? {
        guard let question = currentClaudeQuestion else { return nil }
        return question.updatedInput(answers: currentClaudeQuestionAnswers)
    }

    // MARK: - Defaults

    static func defaultAnswers(for request: ClaudeQuestionRequest) -> [String: ClaudeQuestionAnswer] {
        var answers: [String: ClaudeQuestionAnswer] = [:]
        for question in request.questions {
            var answer = ClaudeQuestionAnswer()
            if !question.allowsMultipleSelection, !question.allowsTextInput,
               let firstOption = question.options.first {
                answer.selectedOptionIds = [firstOption.id]
            }
            answers[question.id] = answer
        }
        return answers
    }
}
