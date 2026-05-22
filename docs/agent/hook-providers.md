# Hook Providers

DevIsland supports Claude Code, Codex CLI, and Gemini CLI through the same bridge architecture.

## Quick Reference

| CLI Agent | Config File | Approval Event | Lifecycle Events |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` | `PermissionRequest` | `SessionStart`, `SessionEnd`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `Stop` |
| Codex CLI | `~/.codex/hooks.json` + `config.toml` | `PermissionRequest` | `SessionStart`, `PreToolUse`, `PostToolUse`, `Stop` |
| Gemini CLI | `~/.gemini/settings.json` | `BeforeTool` | `SessionStart`, `SessionEnd`, `AfterAgent`, `Notification` |

The bridge supports an explicit source flag:

```bash
devisland-bridge.sh --source claude
devisland-bridge.sh --source codex
devisland-bridge.sh --source gemini
```

If omitted, source is inferred from `hook_event_name`, payload shape, and terminal metadata.

## Claude Code

Config file: `~/.claude/settings.json` or project-local `.claude/settings.json`.

Claude Code may block security-sensitive operations in Auto Mode before DevIsland sees the event. If the user sees “Denied by auto-mode classifier”, that is a Claude restriction; use interactive mode.

DevIsland uses `PermissionRequest` for standard tool approval. `PostToolUse` is audit/replay tracking for successful tool completion, and `PostToolUseFailure` is the failure signal used for error sound feedback. Claude `PreToolUse` is mostly status tracking, but selected tools such as `AskUserQuestion` and `ExitPlanMode` can return Claude-specific hook output to preserve or update tool input.

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

`decision` is `allow` or `deny`; returning `{}` or omitting a decision allows the action. Exit code `2` is a hard block and stderr is used as the rejection reason.

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
