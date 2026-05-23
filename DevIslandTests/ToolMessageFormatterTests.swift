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

    func testSkipsDescriptionOnlyOptions() {
        let input: [String: Any] = [
            "question": "Which framework should I use?",
            "options": [
                ["description": "Native macOS UI"],
                ["label": "AppKit", "description": "Classic macOS UI"]
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
            Which framework should I use?

            Options:
            1. AppKit - Classic macOS UI
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

    func testFormatsClaudeStopLastAssistantMessage() {
        let message = ToolMessageFormatter.displayMessage(
            for: "",
            toolInput: nil,
            json: [
                "hook_event_name": "Stop",
                "session_id": "claude-session",
                "last_assistant_message": "Implemented the requested change and tests passed."
            ],
            eventName: "Stop"
        )

        XCTAssertEqual(message, "Implemented the requested change and tests passed.")
    }

    func testClaudeStopLastAssistantMessageTakesPrecedence() {
        let message = ToolMessageFormatter.displayMessage(
            for: "",
            toolInput: nil,
            json: [
                "hook_event_name": "Stop",
                "session_id": "claude-session",
                "message": "Task completed",
                "last_assistant_message": "Actual assistant response"
            ],
            eventName: "Stop"
        )

        XCTAssertEqual(message, "Actual assistant response")
    }

    // MARK: - UserPromptSubmit

    func testFormatsUserPromptSubmitEvent() {
        let message = ToolMessageFormatter.displayMessage(
            for: "",
            toolInput: nil,
            json: ["prompt": "What is Swift?"],
            eventName: "UserPromptSubmit"
        )

        XCTAssertEqual(message, "What is Swift?")
    }

    // MARK: - multiSelect

    func testMultiSelectQuestionIncludesLabel() {
        let input: [String: Any] = [
            "question": "Pick all that apply",
            "options": ["Swift", "Python"],
            "multiSelect": true
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "AskUserQuestion",
            toolInput: input,
            json: ["hook_event_name": "PreToolUse"],
            eventName: "PreToolUse"
        )

        XCTAssertTrue(message.contains("Multiple selections allowed"))
    }

    // MARK: - PostToolUse fallback

    func testPostToolFallsBackToCompleted() {
        let message = ToolMessageFormatter.displayMessage(
            for: "shell",
            toolInput: nil,
            json: [
                "hook_event_name": "PostToolUse",
                "tool_name": "shell"
            ],
            eventName: "PostToolUse"
        )

        XCTAssertEqual(message, "Completed")
    }

    // MARK: - Claude Code 도구별 포맷팅

    func testFormatsBashCommand() {
        let input: [String: Any] = [
            "description": "List files",
            "command": "ls -la"
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "bash",
            toolInput: input,
            json: [:],
            eventName: "PreToolUse"
        )

        XCTAssertEqual(message, "List files\n\nls -la")
    }

    func testFormatsWriteCommand() {
        let input: [String: Any] = [
            "file_path": "/tmp/test.swift",
            "content": "let x = 42"
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "write",
            toolInput: input,
            json: [:],
            eventName: "PreToolUse"
        )

        XCTAssertEqual(message, "/tmp/test.swift\n\nlet x = 42")
    }

    func testFormatsEditCommand() {
        let input: [String: Any] = [
            "file_path": "/tmp/test.swift",
            "old_string": "let x = 0",
            "new_string": "let x = 42"
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "edit",
            toolInput: input,
            json: [:],
            eventName: "PreToolUse"
        )

        XCTAssertEqual(message, "/tmp/test.swift\n\nold:\nlet x = 0\n\nnew:\nlet x = 42")
    }

    func testFormatsReadCommand() {
        let input: [String: Any] = [
            "file_path": "/tmp/test.swift",
            "offset": 10,
            "limit": 50
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "read",
            toolInput: input,
            json: [:],
            eventName: "PreToolUse"
        )

        XCTAssertEqual(message, "/tmp/test.swift\n\noffset: 10, limit: 50")
    }

    func testFormatsReadWithoutOffsetLimit() {
        let input: [String: Any] = ["file_path": "/tmp/test.swift"]

        let message = ToolMessageFormatter.displayMessage(
            for: "read",
            toolInput: input,
            json: [:],
            eventName: "PreToolUse"
        )

        XCTAssertEqual(message, "/tmp/test.swift")
    }

    func testFormatsWebfetchCommand() {
        let input: [String: Any] = [
            "url": "https://example.com",
            "prompt": "Summarize this page"
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "webfetch",
            toolInput: input,
            json: [:],
            eventName: "PreToolUse"
        )

        XCTAssertEqual(message, "https://example.com\n\nSummarize this page")
    }

    // MARK: - Codex 도구별 포맷팅

    func testFormatsCodexShellCommand() {
        let input: [String: Any] = ["command": "git log --oneline"]

        let message = ToolMessageFormatter.displayMessage(
            for: "shell",
            toolInput: input,
            json: [:],
            eventName: "PreToolUse"
        )

        XCTAssertEqual(message, "git log --oneline")
    }

    func testFormatsApplyPatch() {
        let input: [String: Any] = [
            "path": "src/main.py",
            "patch": "- old line\n+ new line"
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "apply_patch",
            toolInput: input,
            json: [:],
            eventName: "PreToolUse"
        )

        XCTAssertEqual(message, "src/main.py\n\n- old line\n+ new line")
    }

    // MARK: - json 폴백 분기

    func testFormatsJsonMessageFallback() {
        let message = ToolMessageFormatter.displayMessage(
            for: "unknown_tool",
            toolInput: nil,
            json: ["message": "Processing complete"],
            eventName: "SomeEvent"
        )

        XCTAssertEqual(message, "Processing complete")
    }

    func testFormatsPermissionSuggestions() {
        let message = ToolMessageFormatter.displayMessage(
            for: "",
            toolInput: nil,
            json: [
                "permission_suggestions": [
                    ["behavior": "npm install"],
                    ["behavior": "git commit"]
                ]
            ],
            eventName: "SomeEvent"
        )

        XCTAssertEqual(message, "Suggested: npm install\nSuggested: git commit")
    }

    func testReturnsEmptyStringWhenNoData() {
        let message = ToolMessageFormatter.displayMessage(
            for: "unknown_tool",
            toolInput: nil,
            json: [:],
            eventName: "SomeEvent"
        )

        XCTAssertEqual(message, "")
    }

    // MARK: - 엣지 케이스

    func testEmptyQuestionsArrayFallsBackToTopLevel() {
        let input: [String: Any] = [
            "questions": [] as [[String: Any]],
            "question": "Fallback question"
        ]

        let message = ToolMessageFormatter.displayMessage(
            for: "ask_user",
            toolInput: input,
            json: ["hook_event_name": "PreToolUse"],
            eventName: "PreToolUse"
        )

        XCTAssertEqual(message, "Fallback question")
    }

    func testCaseInsensitiveToolMatching() {
        let input: [String: Any] = ["command": "echo test"]

        let message = ToolMessageFormatter.displayMessage(
            for: "BASH",
            toolInput: input,
            json: [:],
            eventName: "PreToolUse"
        )

        XCTAssertEqual(message, "echo test")
    }
}
