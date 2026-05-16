# Stability Standards

DevIsland is a workflow-critical monitoring tool. It must not interfere with the developer’s primary terminal or destabilize the system.

## Non-Blocking UI

Heavy work must not run on the main thread or block hook response handling.

- AppleScript: use `Process` with `/usr/bin/osascript` and a timeout; never use `NSAppleScript` on the main thread.
- SQLite writes: use the serial `approvalPersistenceQueue` and `.async`.
- Network I/O: keep off the UI path.
- OpenPeon packs: directory scans, manifest reads, and validation must run outside the main thread.
- Audio playback may run on `MainActor` because `AVAudioPlayer` expects a run-loop thread, but it must be best-effort and fast.

## Resource Management

- Always call `ptyBuffer.remove(sessionId:)` when a session ends or is pruned.
- SQLite logs are pruned after the configured retention window.
- Retained `AVAudioPlayer` instances must be removed when playback finishes, and failed `play()` calls must not be retained.

## Silent Failure Prevention

Every error path in `HookSocketServer`, bridge IPC, persistence, and pack loading should either surface a user-facing notification/status or have a robust fallback. Silent drops make hook workflows feel frozen.

## Transport Failure Fallback

When the app is unreachable, the bridge default is `pass` so the originating CLI can continue with its native prompt or fallback behavior. Users who prefer fail-closed behavior can opt into `deny` with `approvalFallbackPolicy`.

| Risk level | Default action |
|---|---|
| safe / read-only | pass |
| low / medium | pass |
| high / write | pass |
| critical / shell / destructive | pass |
| unknown | pass unless explicitly configured to deny |
