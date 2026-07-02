---
name: devisland-terminal-focus
description: Change DevIsland terminal focusing, terminal metadata, AoE navigation, cmux/iTerm/Terminal/WezTerm selection, focus buttons, AppleScript execution, timeout bypass handling, or post-approval focus restoration. Use for TerminalFocuser, AppState focus calls, PTY coordination, bridge terminal enrichment, and related tests.
---

# DevIsland Terminal Focus

Use this for focus restoration and terminal-selection work. Read `docs/agent/stability-standards.md`, `docs/agent/terminal-focus-aoe.md`, and the terminal-related parts of `docs/agent/approval-proxy.md`.

## Invariants

Terminal focusing is best effort. It must not block hook responses, approval decisions, or UI responsiveness.

Use `Process` with `/usr/bin/osascript` and a timeout. Do not use main-thread `NSAppleScript`.

After scripted focusing, re-check whether the intended terminal is actually focused when the workflow depends on it. Recent fixes needed explicit rechecks after focus scripts and after focus actions.

## Metadata

Preserve terminal identity fields from bridge enrichment. Session selection and focus actions may depend on tty/window/tab metadata.

For Codex sessions, a new `SessionStart` in the same terminal identity can close older Codex sessions. Do not apply that rule to Claude, Gemini, or sub-agent sessions sharing a tty.

For detached AoE sessions, preserve `terminal_manager_session_title` and the outer `terminal_tty`. AoE dashboard navigation depends on both.

## AoE And Terminal Apps

Treat WezTerm, iTerm, cmux, Terminal.app, and other terminal hosts as separate focus cases when behavior diverges. Avoid a generic AppleScript path if a provider needs different selection semantics.

Pass dynamic values (cmux workspace ids, session titles) to `osascript` as argv arguments, never by interpolating them into the AppleScript source string.

Supported AoE dashboard row selection currently differs by host:

- WezTerm can activate the target pane and send AoE navigation text through `wezterm cli`.
- iTerm can select the target session and send navigation text through AppleScript.
- cmux and Apple Terminal focus the owning terminal only; AoE row selection is not expected.

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

If manual verification is needed, list terminal app, tab/window scenario, AoE status if relevant, and expected focus result.
