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
- Sub-agent hooks carry `agent_id`/`agent_type` and reuse the parent `session_id` — Codex never sends Claude's `parent_session_id`, so `agent_id` is the only child identity. Only ThreadSpawn sub-agents fire hooks; internal/guardian-review sessions (`approvals_reviewer = "guardian_subagent"`) run none. `SubagentStart`/`SubagentStop` only reach DevIsland after a bridge reinstall registers them.
- DevIsland keys the sub-agent's nested row on `agent_id` (parent = the shared `session_id`) and responds `pass` — it does not decide a sub-agent's approval. Resolve child/parent id inside `handleSubAgentEvent`; never overwrite `ParsedHookEvent.sessionId`. Bridge logs only summarize events — inspect real payload fields like `agent_id` in `approval-proxy.sqlite3` `hook_events.payload_json`.

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
- Prefilter ignored hook events before terminal detection (performance — keep the prefilter ahead of heavy work).
- Add terminal metadata and `cli_source`.
- Send IPC envelope.
- Print provider output.

When changing `scripts/install-bridge.sh`, `scripts/devisland-bridge.sh`, or `scripts/devisland_bridge.py`, update README or provider docs if user setup changes.

Adding a hook event to a provider in `scripts/hook_events.json` requires syncing five spots or Python tests fail: `_FALLBACK_PASSIVE_EVENTS` (devisland_bridge.py), the `NORM_EVENT` prefilter `case` (devisland-bridge.sh), the passive-events regression test (test_devisland_bridge.py), and the `golden/` + `swift_old/` install fixtures (regenerate by running `install_hooks.py` on the matching `inputs/` fixture).

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
