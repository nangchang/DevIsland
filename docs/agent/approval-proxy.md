# Approval Proxy

DevIsland acts as a policy-based Approval Proxy daemon. The macOS app is both daemon and UI; no separate Node.js or Tauri process is required.

## Module Boundaries

```text
DevIsland macOS app
  ├─ HookSocketServer / HookIPCServer   — TCP + Unix domain socket listeners
  ├─ ApprovalProxyController            — orchestrates policy lookup, DB writes, response
  ├─ ProviderAdapter                    — formats decision into per-CLI hook response JSON
  ├─ HookEventNormalizer                — normalizes event names across CLI dialects
  ├─ ApprovalPolicyEngine               — 8-priority rule evaluation against SQLite
  ├─ SQLiteApprovalStore                — rules, session_cache, hook_events, decisions, pty_messages
  ├─ AppSettings / SettingsStore        — UserDefaults-backed settings
  └─ SwiftUI windows                    — Settings, Approval Rules, Replay Log, PTY Transcript
```

Bridge responsibilities:

- Receive stdin payload from the CLI.
- Add terminal metadata and `cli_source`.
- Send IPC envelope to the app.
- Write the app response to stdout in the provider format.

Bridge must not touch the DB, render UI, compute policy, load packs, or run long background work.

## IPC Protocol v1

Bridge to app communication uses length-prefixed JSON framing over TCP `127.0.0.1:9090` or Unix domain socket `~/Library/Application Support/DevIsland/dev-island.sock`.

```text
[4-byte big-endian length][UTF-8 JSON body]
```

Envelope:

```json
{
  "protocol": "dev-island-hook-ipc",
  "version": 1,
  "requestId": "<uuid>",
  "sentAt": "2026-05-09T12:34:56Z",
  "token": "<bridge-token or null>",
  "source": "claude",
  "payload": { "hook_event_name": "PermissionRequest", "session_id": "..." }
}
```

Rich response:

```json
{
  "protocol": "dev-island-hook-ipc",
  "version": 1,
  "requestId": "<same uuid>",
  "status": "ok",
  "decision": "approved",
  "reason": "matched session rule",
  "injection": null,
  "providerOutput": {
    "hookSpecificOutput": {
      "hookEventName": "PermissionRequest",
      "decision": { "behavior": "allow" }
    }
  }
}
```

If `providerOutput` is present, the bridge writes it to stdout verbatim. Otherwise it falls back to legacy `response` conversion.

## AppState Session Model

- `ActiveSession`: one per full `session_id`, displayed by first 8 chars. Tracks last event/tool/message, pending state, terminal metadata, lifecycle state, Gemini auto-edit mode, and `parentSessionId` for sub-agent hierarchy.
- `PendingRequest`: queued manual response with a `responseHandler` closure for the open TCP connection. Approval requests display before notification-priority requests, and each category is processed FIFO. Claude `AskUserQuestion` replies use notification priority. Timeout auto-denies/passes the displayed request.
- `selectedSessionId`: controls which session appears in the expanded notch. It does not affect pending queue order.

## Hook Event Handling

`AppState.handleMessage()` classifies events into:

1. Session-close events: `exit`, `shutdown`, and `sessionend` remove sessions, clean pending requests, and respond approved.
2. Notification events: update session state, respond approved.
3. Approval events: enqueue pending request and show approval UI.

Provider `Stop` hooks are handled as lifecycle/status notifications in the current app flow. OpenPeon may map `Stop` to `task.complete` for sound feedback, but that mapping does not change AppState session pruning behavior.

## Provider-Specific Notes

Claude:

- `PermissionRequest` is the primary approval event.
- `PreToolUse` handles `AskUserQuestion` and `ExitPlanMode`.
- `Elicitation` covers MCP input requests.
- `UserPromptSubmit` can rewrite or block user input.
- `PostToolUse` is audit/replay only.

Codex:

- Codex has no native session-permission mutation.
- DevIsland manages session and persistent rules in SQLite.

## SQLite Storage

DB path: `~/Library/Application Support/DevIsland/approval-proxy.sqlite3`

PRAGMAs: `journal_mode=WAL`, `busy_timeout=5000`, `foreign_keys=ON`

| Table | Purpose |
|---|---|
| `rules` | Persistent allow/deny rules per provider/tool/pattern |
| `session_cache` | In-session auto-allow entries |
| `hook_events` | Append-only audit log |
| `approval_decisions` | Decision records linked to hook events |
| `pty_messages` | PTY transcript per session |

## PTY Wrapper

`scripts/devisland_pty.py` forks a child under a PTY, forwards I/O, and dispatches `PTYOutput` IPC events. It uses an incremental UTF-8 decoder, a bounded worker pool, and per-session sliding buffers so auto-inject patterns can match output split across chunks.

## Log Files

| File | Written by | Content |
|---|---|---|
| `/tmp/DevIsland.bridge.log` | Bridge script | Per-event IPC send/receive trace |
| `/tmp/DevIsland.log` | App (LaunchAgent mode) | General app stdout |
| `/tmp/DevIsland.error.log` | App (LaunchAgent mode) | App stderr and crash output |
