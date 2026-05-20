import Foundation

/// Gemini-specific policy helpers, mirroring ClaudePromptPolicy in structure.
///
/// Stateless utilities for:
/// - BeforeTool hook response formatting
/// - Interactive tool classification (tools that need terminal interaction)
/// - Emulation-mode approval gate (for --auto-approve / --yolo sessions)
struct GeminiPromptPolicy {

    // MARK: - Response formatting

    static func beforeToolOutput(allow: Bool, denialMessage: String) -> [String: AnyJSON] {
        var output: [String: AnyJSON] = ["decision": .string(allow ? "allow" : "deny")]
        if !allow {
            output["reason"] = .string(denialMessage)
        }
        return output
    }

    // MARK: - Interactive tool classification

    /// Tools that require terminal keyboard input from the user.
    /// DevIsland auto-approves these and expands the notch to prompt the user to return to the terminal.
    private static let interactiveToolNames: Set<String> = ["ask_user", "exit_plan_mode", "run_shell_command"]

    /// Returns true if the tool requires terminal interaction (user must act in the terminal directly).
    /// `isPlanAction` covers temporary file edits under `.gemini/tmp/` during plan phase.
    static func isInteractiveTool(_ toolName: String, isPlanAction: Bool) -> Bool {
        interactiveToolNames.contains(toolName) || isPlanAction
    }

    // MARK: - Emulation mode gate

    /// Returns true if the emulation mode logic should force an approval prompt for this tool,
    /// overriding auto-approve. Only applies when `emulateGeminiInteractiveMode` is active.
    ///
    /// High-risk tools that the user has not explicitly approved require the approval UI
    /// even in --auto-approve / --yolo sessions.
    static func emulationShouldForceApproval(toolName: String, isExplicitlyApproved: Bool) -> Bool {
        ToolKnowledge.risk(for: toolName) != .safe && !isExplicitlyApproved
    }
}
