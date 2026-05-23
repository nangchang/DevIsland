import XCTest
@testable import DevIsland

final class ClaudeQuestionRequestTests: XCTestCase {
    func testParsesSingleChoiceQuestionAndBuildsAnswers() {
        let input: [String: Any] = [
            "questions": [[
                "header": "Framework",
                "question": "Which framework should I use?",
                "options": [
                    ["label": "SwiftUI", "description": "Native macOS UI"],
                    ["label": "AppKit"]
                ],
                "multiSelect": false
            ]]
        ]

        let request = ClaudeQuestionRequest.parse(toolInput: input)
        XCTAssertEqual(request?.questions.count, 1)
        let question = request?.questions.first
        XCTAssertEqual(question?.title, "Framework")
        XCTAssertEqual(question?.prompt, "Which framework should I use?")
        XCTAssertEqual(question?.options.count, 2)
        XCTAssertEqual(question?.allowsMultipleSelection, false)
        XCTAssertEqual(question?.allowsTextInput, true)

        var answer = ClaudeQuestionAnswer()
        answer.selectedOptionIds = [question?.options.first?.id ?? ""]
        let updated = request?.updatedInput(answers: [question?.id ?? "": answer])
        let answers = updated?["answers"]?.rawValue as? [String: Any]

        XCTAssertEqual(answers?["Which framework should I use?"] as? String, "SwiftUI")
    }

    func testSingleChoiceQuestionCanUseCustomTextAnswer() {
        let input: [String: Any] = [
            "questions": [[
                "question": "Which framework should I use?",
                "options": [
                    ["label": "SwiftUI"],
                    ["label": "AppKit"]
                ]
            ]]
        ]

        let request = ClaudeQuestionRequest.parse(toolInput: input)
        guard let question = request?.questions.first else {
            XCTFail("Expected a parsed question")
            return
        }

        var answer = ClaudeQuestionAnswer()
        answer.usesCustomText = true
        answer.text = "UIKit via Catalyst"

        let updated = request?.updatedInput(answers: [question.id: answer])
        let answers = updated?["answers"]?.rawValue as? [String: Any]

        XCTAssertEqual(answers?["Which framework should I use?"] as? String, "UIKit via Catalyst")
    }

    func testParsesMultipleSelectionAndTextQuestions() {
        let input: [String: Any] = [
            "questions": [
                [
                    "question": "Pick targets",
                    "options": [
                        ["label": "Unit tests"],
                        ["label": "Build"]
                    ],
                    "multiSelect": true
                ],
                [
                    "question": "Anything else?"
                ]
            ]
        ]

        let request = ClaudeQuestionRequest.parse(toolInput: input)
        XCTAssertEqual(request?.questions.count, 2)
        guard let first = request?.questions.first, let second = request?.questions.dropFirst().first else {
            XCTFail("Expected two questions")
            return
        }

        var firstAnswer = ClaudeQuestionAnswer()
        firstAnswer.selectedOptionIds = Set(first.options.map(\.id))
        firstAnswer.usesCustomText = true
        firstAnswer.text = "Manual smoke test"
        var secondAnswer = ClaudeQuestionAnswer()
        secondAnswer.text = "Run actionlint if available."

        let updated = request?.updatedInput(answers: [
            first.id: firstAnswer,
            second.id: secondAnswer
        ])
        let answers = updated?["answers"]?.rawValue as? [String: Any]

        XCTAssertEqual(answers?["Pick targets"] as? [String], ["Unit tests", "Build", "Manual smoke test"])
        XCTAssertEqual(answers?["Anything else?"] as? String, "Run actionlint if available.")
    }

    func testRequiresAllAnswersBeforeBuildingUpdatedInput() {
        let input: [String: Any] = [
            "questions": [
                ["question": "One?"],
                ["question": "Two?"]
            ]
        ]

        let request = ClaudeQuestionRequest.parse(toolInput: input)
        guard let first = request?.questions.first else {
            XCTFail("Expected a parsed question")
            return
        }
        var answer = ClaudeQuestionAnswer()
        answer.text = "Only one"

        XCTAssertNil(request?.updatedInput(answers: [first.id: answer]))
    }
}
