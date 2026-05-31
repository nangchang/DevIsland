import XCTest
@testable import DevIsland

final class ClaudeQuestionStateTests: XCTestCase {

    private var state: ClaudeQuestionState!

    override func setUp() {
        super.setUp()
        state = ClaudeQuestionState()
    }

    override func tearDown() {
        state = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Single-select question with two string options and no text-input.
    private func makeSingleSelectRequest(
        questionId: String = "q1",
        options: [String] = ["Alpha", "Beta"],
        allowsTextInput: Bool = false
    ) -> ClaudeQuestionRequest {
        let rawOptions = options.map { ["label": $0, "value": $0] }
        let toolInput: [String: Any] = [
            "id": questionId,
            "question": "Pick one",
            "options": rawOptions,
            "textInput": allowsTextInput
        ]
        return ClaudeQuestionRequest.parse(toolInput: toolInput)!
    }

    /// Multi-select question with options.
    private func makeMultiSelectRequest(
        questionId: String = "q1",
        options: [String] = ["X", "Y", "Z"]
    ) -> ClaudeQuestionRequest {
        let rawOptions = options.map { ["label": $0, "value": $0] }
        let toolInput: [String: Any] = [
            "id": questionId,
            "question": "Pick many",
            "options": rawOptions,
            "multiSelect": true
        ]
        return ClaudeQuestionRequest.parse(toolInput: toolInput)!
    }

    /// Free-text (no options) question.
    private func makeTextRequest(questionId: String = "q1") -> ClaudeQuestionRequest {
        let toolInput: [String: Any] = [
            "id": questionId,
            "question": "Enter text"
        ]
        return ClaudeQuestionRequest.parse(toolInput: toolInput)!
    }

    // MARK: - Initial state

    func testInitialStateIsEmpty() {
        XCTAssertNil(state.currentClaudeQuestion)
        XCTAssertTrue(state.currentClaudeQuestionAnswers.isEmpty)
    }

    // MARK: - reset()

    func testResetClearsBothVars() {
        let req = makeSingleSelectRequest()
        state.setQuestion(req, answers: ["q1": ClaudeQuestionAnswer()])
        XCTAssertNotNil(state.currentClaudeQuestion)
        XCTAssertFalse(state.currentClaudeQuestionAnswers.isEmpty)

        state.reset()
        XCTAssertNil(state.currentClaudeQuestion)
        XCTAssertTrue(state.currentClaudeQuestionAnswers.isEmpty)
    }

    // MARK: - setQuestion(_:answers:)

    func testSetQuestionStoresBothVars() {
        let req = makeSingleSelectRequest()
        var answer = ClaudeQuestionAnswer()
        answer.selectedOptionIds = ["Alpha"]
        state.setQuestion(req, answers: ["q1": answer])

        XCTAssertEqual(state.currentClaudeQuestion, req)
        XCTAssertEqual(state.currentClaudeQuestionAnswers["q1"]?.selectedOptionIds, ["Alpha"])
    }

    // MARK: - setOption (single-select)

    func testSetOptionSingleSelectReplacesSelection() {
        let req = makeSingleSelectRequest()
        let question = req.questions[0]
        let alpha = question.options[0]
        let beta  = question.options[1]

        state.setQuestion(req, answers: [:])
        state.setOption(questionId: question.id, optionId: alpha.id)
        XCTAssertEqual(state.currentClaudeQuestionAnswers[question.id]?.selectedOptionIds, [alpha.id])

        state.setOption(questionId: question.id, optionId: beta.id)
        XCTAssertEqual(state.currentClaudeQuestionAnswers[question.id]?.selectedOptionIds, [beta.id])
    }

    func testSetOptionSingleSelectClearsCustomText() {
        let req = makeSingleSelectRequest(allowsTextInput: true)
        let question = req.questions[0]
        let alpha = question.options[0]

        state.setQuestion(req, answers: [:])
        state.setCustomAnswerEnabled(questionId: question.id, isEnabled: true)
        XCTAssertTrue(state.currentClaudeQuestionAnswers[question.id]?.usesCustomText == true)

        state.setOption(questionId: question.id, optionId: alpha.id)
        XCTAssertFalse(state.currentClaudeQuestionAnswers[question.id]?.usesCustomText == true)
    }

    func testSetOptionNoopWhenNoQuestion() {
        // Should not crash when there's no current question
        state.setOption(questionId: "nonexistent", optionId: "opt")
        XCTAssertTrue(state.currentClaudeQuestionAnswers.isEmpty)
    }

    // MARK: - setOption (multi-select)

    func testSetOptionMultiSelectTogglesOn() {
        let req = makeMultiSelectRequest()
        let question = req.questions[0]
        let x = question.options[0]
        let y = question.options[1]

        state.setQuestion(req, answers: [:])
        state.setOption(questionId: question.id, optionId: x.id)
        state.setOption(questionId: question.id, optionId: y.id)

        let selected = state.currentClaudeQuestionAnswers[question.id]?.selectedOptionIds
        XCTAssertEqual(selected, [x.id, y.id])
    }

    func testSetOptionMultiSelectTogglesOff() {
        let req = makeMultiSelectRequest()
        let question = req.questions[0]
        let x = question.options[0]

        state.setQuestion(req, answers: [:])
        state.setOption(questionId: question.id, optionId: x.id)
        XCTAssertEqual(state.currentClaudeQuestionAnswers[question.id]?.selectedOptionIds, [x.id])

        state.setOption(questionId: question.id, optionId: x.id)
        XCTAssertTrue(state.currentClaudeQuestionAnswers[question.id]?.selectedOptionIds.isEmpty == true)
    }

    // MARK: - setCustomAnswerEnabled

    func testSetCustomAnswerEnabledTrue() {
        let req = makeSingleSelectRequest(allowsTextInput: true)
        let question = req.questions[0]
        let alpha = question.options[0]

        state.setQuestion(req, answers: [:])
        state.setOption(questionId: question.id, optionId: alpha.id)
        state.setCustomAnswerEnabled(questionId: question.id, isEnabled: true)

        let answer = state.currentClaudeQuestionAnswers[question.id]
        XCTAssertTrue(answer?.usesCustomText == true)
        // Single-select: enabling custom text clears selected options
        XCTAssertTrue(answer?.selectedOptionIds.isEmpty == true)
    }

    func testSetCustomAnswerEnabledFalse() {
        let req = makeSingleSelectRequest(allowsTextInput: true)
        let question = req.questions[0]

        state.setQuestion(req, answers: [:])
        state.setCustomAnswerEnabled(questionId: question.id, isEnabled: true)
        state.setCustomAnswerEnabled(questionId: question.id, isEnabled: false)
        XCTAssertFalse(state.currentClaudeQuestionAnswers[question.id]?.usesCustomText == true)
    }

    // MARK: - setText

    func testSetTextUpdatesAnswer() {
        let req = makeTextRequest()
        let question = req.questions[0]

        state.setQuestion(req, answers: [:])
        state.setText(questionId: question.id, text: "Hello")
        XCTAssertEqual(state.currentClaudeQuestionAnswers[question.id]?.text, "Hello")
    }

    func testSetTextCreatesAnswerEntryIfMissing() {
        let req = makeTextRequest()
        let question = req.questions[0]

        state.setQuestion(req, answers: [:])
        state.setText(questionId: question.id, text: "world")
        XCTAssertEqual(state.currentClaudeQuestionAnswers[question.id]?.text, "world")
    }

    // MARK: - canSubmit

    func testCanSubmitFalseWhenNoQuestion() {
        XCTAssertFalse(state.canSubmit())
    }

    func testCanSubmitFalseWhenOptionNotSelected() {
        let req = makeSingleSelectRequest()
        let question = req.questions[0]
        state.setQuestion(req, answers: [question.id: ClaudeQuestionAnswer()])
        XCTAssertFalse(state.canSubmit())
    }

    func testCanSubmitTrueWhenOptionSelected() {
        let req = makeSingleSelectRequest()
        let question = req.questions[0]
        let option = question.options[0]

        state.setQuestion(req, answers: [:])
        state.setOption(questionId: question.id, optionId: option.id)
        XCTAssertTrue(state.canSubmit())
    }

    func testCanSubmitTrueWhenTextProvided() {
        let req = makeTextRequest()
        let question = req.questions[0]

        state.setQuestion(req, answers: [:])
        state.setText(questionId: question.id, text: "Some answer")
        XCTAssertTrue(state.canSubmit())
    }

    // MARK: - buildSubmitInput

    func testBuildSubmitInputNilWhenNoQuestion() {
        XCTAssertNil(state.buildSubmitInput())
    }

    func testBuildSubmitInputNilWhenNoAnswers() {
        let req = makeSingleSelectRequest()
        let question = req.questions[0]
        state.setQuestion(req, answers: [question.id: ClaudeQuestionAnswer()])
        XCTAssertNil(state.buildSubmitInput())
    }

    func testBuildSubmitInputReturnsDictWithAnswers() {
        let req = makeSingleSelectRequest()
        let question = req.questions[0]
        let option = question.options[1] // "Beta"

        state.setQuestion(req, answers: [:])
        state.setOption(questionId: question.id, optionId: option.id)

        let result = state.buildSubmitInput()
        XCTAssertNotNil(result)
        // "answers" key must be present
        if case .object(let answersWrapper) = result?["answers"] {
            if case .string(let value) = answersWrapper["Pick one"] {
                XCTAssertEqual(value, "Beta")
            } else {
                XCTFail("Expected string value for 'Pick one' answer")
            }
        } else {
            XCTFail("Expected 'answers' object in submit input")
        }
    }

    // MARK: - defaultAnswers

    func testDefaultAnswersPreSelectsFirstOptionForSingleSelectNoText() {
        let req = makeSingleSelectRequest(allowsTextInput: false)
        let question = req.questions[0]
        let answers = ClaudeQuestionState.defaultAnswers(for: req)
        XCTAssertEqual(answers[question.id]?.selectedOptionIds, [question.options[0].id])
    }

    func testDefaultAnswersDoesNotPreSelectForMultiSelect() {
        let req = makeMultiSelectRequest()
        let question = req.questions[0]
        let answers = ClaudeQuestionState.defaultAnswers(for: req)
        XCTAssertTrue(answers[question.id]?.selectedOptionIds.isEmpty == true)
    }

    func testDefaultAnswersDoesNotPreSelectForTextInput() {
        let req = makeSingleSelectRequest(allowsTextInput: true)
        let question = req.questions[0]
        let answers = ClaudeQuestionState.defaultAnswers(for: req)
        XCTAssertTrue(answers[question.id]?.selectedOptionIds.isEmpty == true)
    }

    func testDefaultAnswersCreatesEntryForTextOnlyQuestion() {
        let req = makeTextRequest()
        let question = req.questions[0]
        let answers = ClaudeQuestionState.defaultAnswers(for: req)
        XCTAssertNotNil(answers[question.id])
        XCTAssertTrue(answers[question.id]?.selectedOptionIds.isEmpty == true)
    }
}
