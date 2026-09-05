# Terminal Focus And AoE Navigation

DevIsland terminal focusing is best effort. It must not block hook responses, approval decisions, or UI responsiveness.

## AoE Session Navigation

Agent of Empires (`aoe`) runs agent sessions under tmux. For detached AoE sessions, the bridge captures:

- `terminal_tty`: the outer terminal TTY that owns the AoE manager UI.
- `terminal_manager_session_title`: the AoE session title parsed from tmux session names like `aoe_Bohemians_abc123`.

When a user focuses a DevIsland session with `terminal_manager_session_title`, the default behavior is **AoE dashboard search**: supported terminal integrations first focus the terminal app, then send the AoE TUI navigation sequence:

```text
Ctrl+Q, /, <session title>, Enter
```

`Ctrl+Q` is best effort and is intended to leave AoE live-send mode before starting the search.

Users can switch **General → AoE Session Focus** to **tmux client switch** to focus the owning terminal and use tmux metadata to select the target client/pane without typing into AoE.

## App Strategies

| Terminal app | Strategy |
|---|---|
| WezTerm | Default: use the WezTerm CLI to activate the target pane, then send AoE navigation text through `wezterm cli send-text --no-paste`. Optional tmux client switch mode activates/switches the target pane without sending text. |
| iTerm | Default: use AppleScript to select the target window/tab/session, then send AoE navigation text with `write text ... newline false`. Optional tmux client switch mode uses tmux metadata after focus without sending text. |
| cmux | Focus the owning workspace/terminal only. AoE dashboard session selection is unsupported. |
| Apple Terminal | Focus the owning window/tab only. AoE dashboard session selection is unsupported. |
| Orca | Focus the target terminal tab via the Orca CLI (`orca terminal switch --terminal <handle>`), then raise the app. AoE dashboard session selection is unsupported — not for lack of text injection, but because no terminal handle is available for this case (see Limits). |

## Limits

- cmux exposes `input text`, but manual testing showed `Ctrl+Q`, `Ctrl+B q`, and `/title` input can reach the selected agent session instead of reliably controlling the AoE dashboard.
- Apple Terminal does not expose a reliable equivalent to iTerm's `write text ... newline false` or WezTerm's `send-text` for driving an existing AoE dashboard without leaking text into the selected agent session.
- AoE currently has `session attach`, `send`, `list --json`, and HTTP API surfaces, but no confirmed public command/API that selects an existing dashboard row in the already-running TUI.
- Detached AoE detection infers the manager process from the tmux session prefix (`aoe_*`) and prefers a matching process with an attached TTY. Multiple visible AoE manager processes may still be ambiguous.
- Orca's CLI *does* expose reliable, focus-independent text/keystroke injection (`orca terminal send --terminal <handle> --text <text>`) — verified to deliver raw control bytes (e.g. Ctrl+Q) into the target pty even while Orca is not frontmost, the same property WezTerm's `--no-paste` and iTerm's AppleScript `write text` provide. So Orca *could* drive the same AoE navigation sequence in principle. The actual blocker is upstream: the bridge only populates `terminal_manager_session_title` for a *detached* AoE tmux session (no attached client), and in exactly that case `ORCA_TERMINAL_HANDLE`/`ORCA_TAB_ID`/`ORCA_WORKTREE_ID` are absent from the tmux session's process environment — confirmed by inspecting a nested tmux pane's own env directly, tmux does not propagate them into panes it spawns. DevIsland therefore has no terminal handle to target, and Orca's CLI has no documented selector to resolve a handle from an arbitrary OS tty/pid (only `orca diagnostics memory --json`, an undocumented diagnostics surface not listed among the CLI's selectors, happens to expose per-session pids that could be tty-correlated as an unofficial workaround).

## Manual Verification

For iTerm and WezTerm with the default **AoE dashboard search** mode:

1. Launch an AoE dashboard in the terminal app.
2. Start at least two AoE sessions with distinct titles.
3. Trigger a DevIsland event from a non-selected AoE session.
4. Press Focus Terminal in DevIsland.
5. Verify the terminal app is frontmost and AoE selects the expected session title.

With **tmux client switch** mode, step 5 is different: verify the terminal app is frontmost and tmux switches to the expected session/pane without `/session title` appearing in the agent stdin.

For cmux, Apple Terminal, and Orca, step 5 is different: verify only that the terminal app is frontmost and the owning workspace/tab/terminal is selected when DevIsland has matching metadata. AoE session row selection is not expected.
