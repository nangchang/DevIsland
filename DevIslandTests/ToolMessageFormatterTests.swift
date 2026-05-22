import XCTest
@testable import DevIsland

final class ToolMessageFormatterTests: XCTestCase {
    func testFormatsClaudeAskUserQuestionPayload() {
        let input: [String: Any] = [
            "questions": [
                [
                    "header": "Framework",
                    "question": "Which framework should I use?",
                    "options": [
                        ["label": "SwiftUI", "description": "Native macOS UI"],
                        ["label": "AppKit"]
                    ],
                    "multiSelect": false
                ]
            ]
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "AskUserQuestion",
            toolInput: input,
            json: [
                "hook_event_name": "PreToolUse",
                "tool_name": "AskUserQuestion",
                "tool_input": input
            ],
            eventName: "PreToolUse"
        )

        XCTAssertEqual(
            message,
            """
            Framework

            Which framework should I use?

            Options:
            1. SwiftUI - Native macOS UI
            2. AppKit
            """
        )
    }

    func testFormatsMultipleQuestionPayloadsWithOrdinals() {
        let input: [String: Any] = [
            "questions": [
                [
                    "header": "Scope",
                    "question": "Where should this apply?",
                    "options": ["Session", "Always"]
                ],
                [
                    "question": "Run tests after changing it?",
                    "options": ["Yes", "No"]
                ]
            ]
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "request_user_input",
            toolInput: input,
            json: [
                "hook_event_name": "PermissionRequest",
                "tool_name": "request_user_input",
                "tool_input": input
            ],
            eventName: "PermissionRequest"
        )

        XCTAssertTrue(message.contains("1. Scope"))
        XCTAssertTrue(message.contains("Question 2"))
        XCTAssertTrue(message.contains("1. Yes"))
        XCTAssertFalse(message.contains("questions:"))
    }

    func testFormatsSingleQuestionFallbackShape() {
        let input: [String: Any] = [
            "question": "Which branch should I use?",
            "choices": [
                ["label": "main"],
                ["label": "feature/dev-island"]
            ]
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "ask_user",
            toolInput: input,
            json: [
                "hook_event_name": "PermissionRequest",
                "tool_name": "ask_user",
                "tool_input": input
            ],
            eventName: "PermissionRequest"
        )

        XCTAssertEqual(
            message,
            """
            Which branch should I use?

            Options:
            1. main
            2. feature/dev-island
            """
        )
    }

    func testFormatsStringPostToolResponse() {
        let message = ToolMessageFormatter.displayMessage(
            for: "shell",
            toolInput: nil,
            json: [
                "hook_event_name": "PostToolUse",
                "tool_name": "shell",
                "tool_response": "Codex turn completed"
            ],
            eventName: "PostToolUse"
        )

        XCTAssertEqual(message, "Codex turn completed")
    }

    func testFormatsPostToolMessageField() {
        let response: [String: Any] = [
            "message": "Waiting for the next prompt"
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "shell",
            toolInput: nil,
            json: [
                "hook_event_name": "PostToolUse",
                "tool_name": "shell",
                "tool_response": response
            ],
            eventName: "PostToolUse"
        )

        XCTAssertEqual(message, "Waiting for the next prompt")
    }

    func testFormatsTopLevelPostToolMessageWhenResponseIsMissing() {
        let message = ToolMessageFormatter.displayMessage(
            for: "shell",
            toolInput: nil,
            json: [
                "hook_event_name": "PostToolUse",
                "tool_name": "shell",
                "message": "Task completed with no changes"
            ],
            eventName: "PostToolUse"
        )

        XCTAssertEqual(message, "Task completed with no changes")
    }
}
