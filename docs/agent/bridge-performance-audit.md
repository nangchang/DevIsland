# Bridge Performance Audit

This note records the June 27, 2026 audit of DevIsland log growth and hook-path overhead.

## Summary

DevIsland does not currently show runaway bridge log growth on the inspected machine, but a few paths can still grow without rotation or can add latency to every hook invocation.

The most direct hook latency issue was the shell bridge running terminal detection before ignored explicit events could be suppressed. The first mitigation is a shell-native prefilter for explicit `--event` hooks before `tty`, `ps`, `tmux`, and `osascript` detection, without adding another Python startup to forwarded hooks.

## Current Handoff Status

Last updated: 2026-06-28 KST.

- Branch: `codex/bridge-prefilter-performance`
- Draft PR: https://github.com/nangchang/DevIsland/pull/337
- PR base: `main`
- Initial implementation commit: `7bc1b54 fix: prefilter ignored hooks before terminal detection`
- Handoff status commit: `9e16866 docs: record bridge performance handoff status`
- Changed files in the first PR commit:
  - `scripts/devisland-bridge.sh`
  - `scripts/devisland_bridge.py`
  - `scripts/test_devisland_bridge.py`
  - `scripts/test_devisland_bridge_shell.py`
  - `docs/agent/bridge-performance-audit.md`
- Validation completed before opening PR #337:
  - `python3 scripts/test_devisland_bridge.py`
  - `python3 scripts/test_devisland_bridge_shell.py`
  - `./scripts/run-tests.sh`

Implementation state:

- The first mitigation is implemented and covered by focused tests.
- After PR review, the prefilter is shell-native instead of Python-based so forwarded `--event` hooks still launch Python exactly once.
- The shell bridge only runs the early prefilter when `--event` is already available.
- Payload-only event paths continue through the existing Python helper path.
- PR #337 is open and no longer draft.

Recommended next steps:

1. Watch PR checks after the review-fix commit is pushed.
2. Re-check unresolved review threads and confirm the double Python startup concern is addressed.
3. If continuing performance work, start with unbounded `/tmp` log rotation or `os.Logger` migration.
4. Do not broaden prefiltering to payload-only event paths without measuring the parsing cost or implementing a shell-native payload parser.

## Observed Local State

- `~/Library/Logs/DevIsland/bridge.log`: about 2.5 MB.
- `/tmp/DevIsland.bridge.log`: about 4 KB.
- `~/Library/Application Support/DevIsland/approval-proxy.sqlite3`: about 88 MB, plus WAL.
- `hook_events`: 12,233 rows.
- `approval_decisions`: 10,830 rows.
- `pty_messages`: 0 rows.
- Oldest retained hook event: 2026-05-28 UTC.

The SQLite data matches the default 30-day replay retention window. The database size is mainly replay payload content, especially `PostToolUse` rows.

## Log Growth Findings

### Bounded

- `scripts/devisland_bridge.py` writes `~/Library/Logs/DevIsland/bridge.log`.
- It rotates once when the file exceeds 5 MB, so normal bridge helper logging is bounded to roughly the active file plus one rotated file.

### Not Bounded

- `scripts/devisland-bridge.sh` appends selected fallback and AppleScript stderr output to `/tmp/DevIsland.bridge.log`.
- `scripts/install-launch-agent.sh` routes app stdout and stderr to `/tmp/DevIsland.log` and `/tmp/DevIsland.error.log`.
- Swift code still uses many `print()` calls. In LaunchAgent mode, those prints can accumulate in the unrotated `/tmp` files.

### Retained By Window, But Can Grow While Running

- Replay and PTY rows are pruned by `SQLiteApprovalStore.pruneOldLogs`.
- App startup schedules the prune on the persistence queue.
- There is no periodic prune while the app stays open for a long time.
- There is no automatic vacuum or WAL checkpoint policy to shrink the file after deletes.

## Hook Latency Findings

### Terminal Detection Before Suppression

Before the first mitigation, `scripts/devisland-bridge.sh` performed terminal detection for every hook before invoking `scripts/devisland_bridge.py`.

That meant ignored or retired events still paid for:

- `tty`
- parent-process `ps` walks
- `tmux list-clients` / `tmux display-message`
- app-specific `osascript`

### Focus Check Before Fast Approvals

Approval handling checks whether the terminal session is frontmost before persistent policy and volatile auto-approval checks. The focus check runs off the main thread, but the hook response waits for it. The AppleScript timeout is 1.5 seconds.

### Synchronous SQLite Reads In Decision Path

Persistent policy evaluation reads SQLite synchronously from the callback that resumes on the main queue. SQLite uses a 5 second busy timeout, so write contention can delay UI and hook response handling.

### Replay Payload Serialization

Replay inserts happen on a background queue, but payload conversion to pretty-printed JSON happens before enqueueing. Large `PostToolUse` payloads can therefore add CPU and memory work to the hook path.

### PTY Wrapper

PTY support is disabled by default. If enabled, output chunks are sent to the app over IPC and persisted to SQLite. The wrapper caps concurrent IPC calls, but high-output commands can still add overhead.

## Improvement Plan

1. Prefilter ignored explicit hook events before terminal detection.
   - Normalize the CLI-supplied `--event` in Bash.
   - Suppress unknown explicit events before terminal detection.
   - Preserve existing suppress output.
   - Keep forwarded hooks to one Python startup.

2. Rotate or redirect unbounded `/tmp` logs.
   - Prefer `os.Logger` for Swift diagnostics.
   - If LaunchAgent file logs remain, add log rotation or move them under `~/Library/Logs/DevIsland` with bounded retention.

3. Add periodic SQLite pruning.
   - Keep startup pruning.
   - Schedule a low-priority periodic prune for long-running app sessions.

4. Reduce replay payload cost.
   - Consider truncating or summarizing large `PostToolUse` payload fields.
   - Consider making full payload replay an explicit setting.

5. Move policy reads off the main response continuation.
   - Evaluate rules on the approval persistence queue or a dedicated read queue.
   - Keep hook response ordering and provider semantics intact.

6. Cache terminal metadata cautiously.
   - Use a short TTL keyed by TTY, tmux pane, and terminal app.
   - Keep this behind the prefilter fix so cache correctness is easier to reason about.

## First Mitigation

The first mitigation is implemented in the bridge script for hooks with an explicit `--event` argument:

- `scripts/devisland-bridge.sh` normalizes `--event` using lowercase conversion and underscore/hyphen removal.
- Known events from `scripts/hook_events.json` continue to terminal detection.
- Unknown explicit events return the existing suppress response and exit before terminal detection.
- A focused shell test keeps the Bash allowlist in sync with `scripts/hook_events.json`.

This keeps provider hook behavior unchanged for forwarded events, avoids terminal metadata work for explicit events DevIsland would not send to the app, and avoids the double Python startup concern raised in PR review.
