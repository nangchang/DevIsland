---
name: devisland-hook-providers
description: Change DevIsland Claude Code, Codex CLI, Gemini CLI, or Antigravity CLI hook handling, hook classification/normalization, provider response JSON, bridge install scripts, source detection, integrated app detection, interactive prompt behavior, or provider-specific approval semantics.
---

# DevIsland Hook Providers

Use this when touching provider-specific hook behavior. Read `docs/agent/hook-providers.md`; also read `docs/agent/approval-proxy.md` if the change reaches app-side decisions.

## Provider Semantics

Do not generalize provider outputs blindly. Claude, Codex, Gemini, and Antigravity use different event names, timeout units, payload fields, and response shapes.

Claude:

- `PermissionRequest` is the primary approval event.
- `PreToolUse` can handle selected interactive tools such as `AskUserQuestion` and `ExitPlanMode`.
- `PostToolUse` is audit/replay; `PostToolUseFailure` is the failure signal.
- Claude Auto Mode may block before DevIsland sees an event.

Codex:

- `PermissionRequest` is the approval event.
- `PreToolUse` is status tracking only and should continue without a DevIsland prompt.
- Codex lacks native session-permission mutation; DevIsland owns SQLite rules.
- New `SessionStart` in the same terminal identity can imply older Codex session end.

Gemini:

- `BeforeTool` is the primary approval event.
- Hook timeouts are milliseconds.
- `{}` or omitted decision allows the action.
- Interactive emulation and safe-tool auto approval must avoid double prompting.

Antigravity:

- `PreToolUse` is the primary approval event.
- Payloads use camelCase fields such as `conversationId`, `workspacePaths`, and `toolCall`.
- The bridge normalizes Antigravity payloads into DevIsland's internal session, cwd, tool name, and tool input fields.
- Returning `ask` delegates bypass/unavailable cases back to Antigravity's native permission flow.

## Response JSON

Use `ProviderAdapter` for provider output. Do not assemble provider JSON ad hoc unless the adapter is the code under change.

Preserve hard-deny messages and exit behavior for each provider. A malformed response can hang or unblock the wrong CLI action.

## Bridge And Install Scripts

Bridge responsibilities stay thin:

- Read stdin payload.
- Add terminal metadata and `cli_source`.
- Send IPC envelope.
- Print provider output.

When changing `scripts/install-bridge.sh`, `scripts/devisland-bridge.sh`, or `scripts/devisland_bridge.py`, update README or provider docs if user setup changes.

For source and integration detection, preserve VS Code, Claude Desktop, WezTerm, tmux, and Antigravity payload behavior documented in `docs/agent/hook-providers.md`.

## Tests

Prefer focused tests:

- `ProviderAdapterTests`
- `HookEventNormalizerTests`
- `HookEventClassifierTests`
- `GoldenResponseTests`
- `ToolMessageFormatterTests`
- `ClaudeQuestionRequestTests`
- `CodexRuleSyncAdapterTests`
- `ToolKnowledgeTests`
- `AppStateTests`

Run `./scripts/run-tests.sh` before handoff for behavior changes.
