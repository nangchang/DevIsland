---
name: devisland-terminal-focus
description: Change DevIsland terminal focusing, terminal metadata, cmux/iTerm/Terminal tab selection, focus buttons, AppleScript execution, timeout bypass handling, or post-approval focus restoration. Use for TerminalFocuser, AppState focus calls, PTY coordination, and related tests.
---

# DevIsland Terminal Focus

Use this for focus restoration and terminal-selection work. Read `docs/agent/stability-standards.md` and the terminal-related parts of `docs/agent/approval-proxy.md`.

## Invariants

Terminal focusing is best effort. It must not block hook responses, approval decisions, or UI responsiveness.

Use `Process` with `/usr/bin/osascript` and a timeout. Do not use main-thread `NSAppleScript`.

After scripted focusing, re-check whether the intended terminal is actually focused when the workflow depends on it. Recent fixes needed explicit rechecks after focus scripts and after focus actions.

## Metadata

Preserve terminal identity fields from bridge enrichment. Session selection and focus actions may depend on tty/window/tab metadata.

For Codex sessions, a new `SessionStart` in the same terminal identity can close older Codex sessions. Do not apply that rule to Claude, Gemini, or sub-agent sessions sharing a tty.

## cmux And Terminal Apps

Treat cmux, iTerm, Terminal.app, and other terminal hosts as separate focus cases when behavior diverges. Avoid a generic AppleScript path if a provider needs different selection semantics.

When changing focus behavior, inspect:

- `DevIsland/Terminal/TerminalFocuser.swift`
- `DevIsland/Core/AppState.swift`
- `DevIsland/Terminal/PTYCoordinator.swift`
- `scripts/devisland_bridge.py`

## Tests And Checks

Use or update `TerminalFocuserTests` for parsing, command construction, and edge cases. Run:

```bash
./scripts/run-tests.sh
```

If manual verification is needed, list terminal app, tab/window scenario, and expected focus result.
