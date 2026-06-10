# Hook Providers

DevIsland supports Claude Code, Codex CLI, and Gemini CLI through the same bridge architecture.

## Quick Reference

| CLI Agent | Config File | Approval Event | Lifecycle Events |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` | `PermissionRequest` | `SessionStart`, `SessionEnd`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `Stop` |
| Codex CLI | `~/.codex/hooks.json` + `config.toml` | `PermissionRequest` | `SessionStart`, `PreToolUse`, `PostToolUse`, `Stop` |
| Gemini CLI | `~/.gemini/settings.json` | `BeforeTool` | `SessionStart`, `SessionEnd`, `AfterAgent`, `Notification` |
| Antigravity CLI | `~/.gemini/config/hooks.json` | `PreToolUse` | `PreInvocation`, `PostInvocation`, `PostToolUse`, `Stop` |

The bridge supports an explicit source flag:

```bash
devisland-bridge.sh --source claude
devisland-bridge.sh --source codex
devisland-bridge.sh --source gemini
devisland-bridge.sh --source antigravity
```

If omitted, source is inferred from `hook_event_name`, payload shape, and terminal metadata.

## Claude Code

Config file: `~/.claude/settings.json` or project-local `.claude/settings.json`.

Claude Code may block security-sensitive operations in Auto Mode before DevIsland sees the event. If the user sees “Denied by auto-mode classifier”, that is a Claude restriction; use interactive mode.

DevIsland uses `PermissionRequest` for standard tool approval. `PostToolUse` is audit/replay tracking for successful tool completion, and `PostToolUseFailure` is the failure signal used for error sound feedback. Claude `PreToolUse` is mostly status tracking, but selected tools such as `AskUserQuestion` and `ExitPlanMode` can return Claude-specific hook output to preserve or update tool input.

`AskUserQuestion` is handled directly in the DevIsland notch UI when possible. The app supports single-choice questions, multi-select questions, multiple questions in one payload, and free-form text questions. Option questions also offer an "Other" path so users can submit a custom text answer. Submitted answers are returned through Claude `PreToolUse` output as `updatedInput`, preserving the original `questions` payload and adding an `answers` object. Follow-up `PermissionRequest` and `PostToolUse` events for the same user-question tools are passed through without a second notification.

Approval output:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" }
  }
}
```

Exit codes: `0` success, `2` hard block with stderr shown to the user, other values warning.

## Codex CLI

Config files: `~/.codex/hooks.json` and `~/.codex/config.toml`.

Required feature flag:

```toml
[features]
hooks = true
```

DevIsland uses `PermissionRequest` for approval. `PreToolUse` is status tracking only and returns `{}` so Codex continues without a DevIsland prompt.
Codex does not emit `SessionEnd`; `SessionStart` may have `source` values `startup`, `resume`, or `clear`. DevIsland treats a new Codex `SessionStart` in the same terminal identity as an implicit end for older Codex sessions only. Claude, Gemini, and sub-agent sessions sharing the same tty are preserved.

Deny output:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Blocked by DevIsland"
    }
  }
}
```

## Gemini CLI

Config file: `~/.gemini/settings.json` or project-local `.gemini/settings.json`.

Gemini uses `BeforeTool` as the primary approval event. Gemini hook timeouts are in milliseconds, unlike Claude/Codex seconds.

Response format:

```json
{ "decision": "deny", "reason": "Blocked by DevIsland" }
```

`decision` is `allow` or `deny`; returning `{}` or omitting a decision allows the action (meaning the hook itself does not veto/deny the tool execution). Gemini CLI does not delegate approval to the hook itself; instead, returning `{}` or omitting the decision delegates the final approval path back to Gemini CLI's own execution configuration (which prompts the user in the terminal unless run with `--auto-approve` or `--yolo`). Exit code `2` is a hard block and stderr is used as the rejection reason.

## VS Code / Claude Desktop Integration

VS Code and Claude Desktop sessions are opt-in (`processVSCodeEnabled`, `processClaudeDesktopEnabled` both default `false`). When disabled, hooks are passed through (`pass` response) and not shown in the notch.

### VS Code detection (bridge)

- Integrated terminal: `TERM_PROGRAM=vscode` — this is the official VS Code standard and applies to all variants (Insiders, VSCodium). No app-running check needed.
- Extension host (no TTY): `VSCODE_PID` / `VSCODE_IPC_HOOK` / `VSCODE_IPC_HOOK_CLI` present → verify with `osascript -e 'return application id "com.microsoft.VSCode" is running'`.

### Claude Desktop detection (bridge)

Claude Desktop has no distinguishing environment variable. Detection walks the parent process chain (up to 5 levels) looking for a process whose `comm` path matches `Claude\.app/Contents/MacOS/Claude$`.

Note: `ps -o comm=` on macOS returns the full executable path, not the process name — string equality against `"Claude"` will never match.

Process chain: `Claude.app/MacOS/Claude` → `Contents/Helpers/disclaimer` → `claude` (Claude Code) → hook script (3 levels up).

### AppleScript / focus

Use bundle IDs, not app names — `"VSCode"` and `"ClaudeDesktop"` are not recognized application names by macOS:
- `tell application id "com.microsoft.VSCode" to activate`
- `tell application id "com.anthropic.claudefordesktop" to activate`

For VS Code, prefer `open -a "Visual Studio Code" <workspaceRoot>` over AppleScript — it targets the correct window when multiple VS Code instances are open.

## Communication Flow

```text
CLI Agent hook event
  -> devisland-bridge.sh
    -> HookSocketServer on TCP 9090 or Unix domain socket
      -> AppState / ApprovalProxyController
        -> UI or policy decision
          -> bridge response -> CLI-specific JSON
```

## Gemini UX Notes

- `exit_plan_mode` switches a session into Auto-Edit mode.
- `enter_plan_mode` resets the session to manual approval mode.
- Interactive tools such as `ask_user`, `exit_plan_mode`, `run_shell_command`, and Gemini plan-temp file actions may be auto-approved while DevIsland shows a “check terminal” notification to avoid double prompting.
- Gemini Interactive Emulation lets DevIsland act as the approval surface when Gemini is run with `--auto-approve` or `--yolo`.
- Safe-tool auto approval can allow read-only tools such as `read_file`, `grep_search`, and `list_dir`.

## Antigravity CLI

Config file: `~/.gemini/config/hooks.json` for global customization, or workspace-local `.agents/hooks.json`.

Antigravity uses `PreToolUse` as the primary approval event, but its stdin payload uses camelCase fields such as `conversationId`, `workspacePaths`, and `toolCall.name`. The bridge normalizes these into DevIsland's internal `session_id`, `cwd`, `tool_name`, and `tool_input` fields before forwarding IPC.

Antigravity `PreToolUse` output supports `allow`, `deny`, `ask`, and `force_ask`. DevIsland returns `allow` or `deny` only for explicit app decisions. When DevIsland is bypassing or unavailable, it returns `ask` so Antigravity's native permission flow remains in control.

```json
{ "decision": "deny", "reason": "Blocked by DevIsland" }
```

`PostToolUse` returns `{}`. `PreInvocation`, `PostInvocation`, and `Stop` are lifecycle events and are forwarded for status/replay tracking only. Interactive emulation and safe-tool auto-approval behaviors are shared with Gemini CLI.
