---
name: devisland-approval-proxy
description: Change DevIsland Approval Proxy behavior, IPC framing, policy evaluation, SQLite persistence, pending approval queues, replay logs, PTY transcript handling, fallback policy, or approval-related plugin observation events. Use for AppState, ApprovalProxyController, ApprovalPolicyEngine, SQLiteApprovalStore, HookSocketServer, IPCProtocol, and related tests.
---

# DevIsland Approval Proxy

Use this when changing the app-side proxy daemon behavior. Read `docs/agent/approval-proxy.md` and `docs/agent/stability-standards.md` before editing.

## Boundaries

Keep bridge scripts thin. They may receive stdin, add terminal metadata, forward IPC, and print provider-specific responses. Do not move DB access, policy evaluation, UI rendering, pack loading, audio playback, or long-running work into the bridge.

The macOS app owns:

- `HookSocketServer` / IPC listener behavior.
- `ApprovalProxyController` orchestration.
- `ApprovalPolicyEngine` rule evaluation.
- `SQLiteApprovalStore` persistence.
- `ProviderAdapter` provider response JSON.
- `AppState` pending queue and session state.

Plugin observation events are best-effort side effects. They must not gate provider responses, approval queue draining, or persistence required for the approval decision.

## Non-Blocking Rules

Do not block the UI or hook response path with heavy work.

- SQLite writes go through the persistence queue.
- AppleScript uses `Process` with timeout, not main-thread `NSAppleScript`.
- Network I/O and pack scans stay off the UI path.
- Best-effort side effects must not change approval/deny behavior.

When the app is unreachable, bridge fallback must preserve the configured policy and avoid freezing the originating CLI.

## Session And Approval Flow

Preserve FIFO handling of pending approval requests. Approval timeouts, response handlers, and selected session state must not corrupt each other.

For session close or pruning, clean associated pending requests and PTY buffers. Always consider `ptyBuffer.remove(sessionId:)` when session lifecycle logic changes.

## Tests

Choose focused tests based on the touched area:

- `ApprovalProxyControllerTests`
- `ApprovalPolicyEngineTests`
- `SQLiteApprovalStoreTests`
- `IPCProtocolTests`
- `AppStateTests`
- `HookEventNormalizerTests`
- `ProviderAdapterTests`

Then run:

```bash
./scripts/run-tests.sh
```

Use `devisland-change-verification` before final handoff.
