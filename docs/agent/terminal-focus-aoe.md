# Terminal Focus And AoE Navigation

DevIsland terminal focusing is best effort. It must not block hook responses, approval decisions, or UI responsiveness.

## Current PR Status

PR: <https://github.com/nangchang/DevIsland/pull/336>

Branch: `codex/improve-aoe-terminal-navigation`

Last implementation commit: `ead0c4b fix: improve AoE terminal navigation support`

As of 2026-06-28, the PR has:

- Split AoE manager navigation out of the old generic non-WezTerm AppleScript path.
- Kept the existing WezTerm CLI path for pane activation and `send-text`.
- Added explicit iTerm manager navigation with `write text ... newline false`.
- Added cmux manager navigation using raw AppleEvent codes for `CmuxInTx` against the focused terminal in the selected workspace.
- Added Apple Terminal manager navigation with a System Events keystroke fallback after Terminal tab focus.
- Added regression coverage in `TerminalFocuserTests` for terminal-specific manager navigation script generation.
- Added bridge shell coverage for detached `aoe_*` tmux sessions forwarding `TERM_MANAGER_SESSION_TITLE`.
- Documented terminal-specific strategy, limits, and manual verification steps in this file.

Verification already run for the PR:

- `python3 -m unittest scripts.test_devisland_bridge_shell`
- cmux raw-event AppleScript compile check with `osacompile`
- `./scripts/run-tests.sh`

Known follow-up risks:

- Apple Terminal navigation is less deterministic than iTerm, WezTerm, or cmux because it uses System Events keystrokes and requires Accessibility permission.
- Detached AoE manager detection still uses the `aoe_*` tmux session-name convention plus `pgrep -nx aoe`, so multiple AoE manager processes may be ambiguous.
- Manual verification is still needed in real iTerm, WezTerm, cmux, and Apple Terminal windows with active AoE dashboards.

## AoE Session Navigation

Agent of Empires (`aoe`) runs agent sessions under tmux. DevIsland captures two pieces of state for detached AoE sessions:

- `terminal_tty`: the outer terminal TTY that owns the AoE manager UI.
- `terminal_manager_session_title`: the AoE session title parsed from tmux session names like `aoe_Bohemians_abc123`.

When a user focuses a DevIsland session with `terminal_manager_session_title`, DevIsland first focuses the terminal app, then sends the AoE TUI navigation sequence:

```text
Ctrl+Q, /, <session title>, Enter
```

`Ctrl+Q` is best effort and is intended to leave AoE live mode before starting the search.

## App Strategies

| Terminal app | Strategy |
|---|---|
| WezTerm | Use the WezTerm CLI to activate the target pane, then `wezterm cli send-text --no-paste` to send AoE navigation text. |
| iTerm | Use iTerm AppleScript to select the target window/tab/session, then `write text ... newline false` on the current session. |
| cmux | Use cmux AppleScript raw event codes to target the focused terminal in the selected workspace and input text directly. |
| Apple Terminal | Use Terminal AppleScript for window/tab focus, then System Events keystrokes for AoE navigation because Terminal has no direct "input text into existing tab" command. |

## Limits

- Apple Terminal AoE navigation requires Accessibility permission for DevIsland because it uses System Events keystrokes.
- System Events sends keys to the frontmost app. DevIsland focuses Terminal first, but this remains less deterministic than iTerm, WezTerm, or cmux APIs.
- cmux uses raw AppleEvent codes for input because its scripting dictionary exposes `input text`, but natural-language AppleScript parsing is fragile for that command.
- Detached AoE detection currently infers the manager process from the tmux session prefix (`aoe_*`) and `pgrep -nx aoe`. Multiple AoE manager processes can still be ambiguous.

## Manual Verification

For each terminal app:

1. Launch an AoE dashboard in the terminal app.
2. Start at least two AoE sessions with distinct titles.
3. Trigger a DevIsland event from a non-selected AoE session.
4. Press Focus Terminal in DevIsland.
5. Verify the terminal app is frontmost and AoE selects the expected session title.

For Apple Terminal, also verify DevIsland has Accessibility permission in System Settings before testing AoE navigation.
