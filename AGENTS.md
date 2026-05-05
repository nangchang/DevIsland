# AGENTS.md

General project documentation for AI coding agents working in this repository.

## What This Project Is

DevIsland is a macOS menubar + notch-overlay app that intercepts Claude Code hook events in real time. When Claude Code tries to execute a tool, the bash bridge forwards the event over TCP to the running DevIsland app, which displays it in a Dynamic Island–style panel at the top of the screen. The user can approve or deny from the UI (or via ⌘⇧Y / ⌘⇧N), and the bridge relays that decision back to Claude Code as a hook response.

## Build & Run

This project uses **XcodeGen** — there is no committed `.xcodeproj`.

```bash
# One-time setup
brew install xcodegen

# Generate the Xcode project (re-run after editing project.yml)
xcodegen generate

# Open in Xcode
open DevIsland.xcodeproj
```

Build target: **macOS 14.0+**, Xcode 15+. There are no tests in the project.

**Release builds** are produced by CI (`.github/workflows/release.yml`) on version tags. The workflow runs `xcodebuild archive` unsigned and packages a DMG via `hdiutil`.

## Quick Build (No Xcode)

For environments without Xcode (e.g. CI, Codex), use the shell build script:

```bash
./scripts/build_and_run.sh
```

This compiles all `DevIsland/*.swift` sources with `swiftc`, assembles an app bundle under `dist/DevIsland.app`, and launches it. Pass `--verify` to assert the process started. This path is also wired as the `.codex/environments/environment.toml` Run action.

## Multi-CLI Support

DevIsland supports multiple AI agent CLIs through the same bridge architecture.

### Supported CLIs — Quick Reference

| CLI Agent | Config File | Approval Event | Lifecycle Events | Docs |
|---|---|---|---|---|
| **Claude Code** | `~/.claude/settings.json` | `PermissionRequest` | `SessionStart`, `SessionEnd`, `Notification`, `Stop`, … | [hooks reference](https://docs.anthropic.com/en/docs/claude-code/hooks) |
| **Codex CLI** | `~/.codex/hooks.json` + `config.toml` | `PreToolUse` | `SessionStart`, `SessionEnd`, `PostToolUse`, `Stop` | [openai.com/codex](https://openai.com/codex) |
| **Gemini CLI** | `~/.gemini/settings.json` | `BeforeTool` | `SessionStart`, `SessionEnd`, `AfterTool`, `BeforeAgent`, … | [geminicli.com/hooks](https://geminicli.com/hooks) |

---

### Claude Code Hook Spec

**Config file:** `~/.claude/settings.json` (or `.claude/settings.json` per-project)  
**Full spec:** https://docs.anthropic.com/en/docs/claude-code/hooks

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/path/to/devisland-bridge.sh --source claude", "timeout": 86400 }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/path/to/devisland-bridge.sh --source claude" }
        ]
      }
    ]
  }
}
```

DevIsland uses `PermissionRequest` as the primary approval hook. Response format:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" }
  }
}
```

Exit codes: `0` = success, `2` = hard block (stderr shown to user), other = warning.

---

### Codex CLI Hook Spec

**Config files:** `~/.codex/hooks.json` + `~/.codex/config.toml`  
**Full spec:** https://openai.com/codex (Hooks section)

Requires feature flag in `config.toml`:
```toml
[features]
codex_hooks = true
```

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/path/to/devisland-bridge.sh --source codex" }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/path/to/devisland-bridge.sh --source codex" }
        ]
      }
    ]
  }
}
```

DevIsland uses `PreToolUse` as the primary approval hook. Response format:

```json
{ "decision": "block", "reason": "Blocked by DevIsland" }
```

`decision`: `"approve"` | `"block"`. Omit or return `{}` to allow.

---

### Gemini CLI Hook Spec

**Config file:** `~/.gemini/settings.json` (user-level) or `.gemini/settings.json` (project-level)  
**Full spec:** https://geminicli.com/hooks

```json
{
  "hooks": {
    "BeforeTool": [
      {
        "matcher": "*",
        "hooks": [
          { "name": "devisland", "type": "command", "command": "/path/to/devisland-bridge.sh --source gemini", "timeout": 86400000 }
        ]
      }
    ],
    "SessionStart": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/devisland-bridge.sh --source gemini" }] }
    ],
    "SessionEnd": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/devisland-bridge.sh --source gemini" }] }
    ]
  }
}
```

> **Note:** Gemini's `timeout` is in **milliseconds** (unlike Claude/Codex which use seconds).

DevIsland uses `BeforeTool` as the primary approval hook. Response format:

```json
{ "decision": "deny", "reason": "Blocked by DevIsland" }
```

`decision`: `"allow"` | `"deny"`. Return `{}` or omit to allow.  
Exit code `2` = hard block (stderr used as rejection reason).

---

### Bridge Arguments
The bridge script supports an explicit `--source` flag to identify the originating CLI:
- `devisland-bridge.sh --source claude`
- `devisland-bridge.sh --source codex`
- `devisland-bridge.sh --source gemini`

If omitted, the bridge auto-detects from `hook_event_name` (`PermissionRequest` → claude, `PreToolUse` → codex, `BeforeTool` → gemini).

### Communication Flow

```
CLI Agent (hook event)
  → devisland-bridge.sh  (stdin → JSON → TCP:9090, waits up to 300s)
    → HookSocketServer   (NWListener, port 9090)
      → AppState.handleMessage()
        → UI decision (approve / deny / timeout)
          → TCP response → bridge → CLI-specific JSON response → CLI Agent
```

### Key Files

| File | Responsibility |
|---|---|
| `DevIslandApp.swift` | `@main` entry, `MenuBarExtra`, `AppDelegate` (creates `NotchWindowController`) |
| `AppState.swift` | Singleton `ObservableObject`; owns the socket server, session list, pending queue, timeout timer |
| `HookSocketServer.swift` | Raw TCP server via `Network.framework`; one connection per hook event |
| `NotchWindowController.swift` | `NSPanel` positioned at the top-center of the main screen; hosts all SwiftUI views including `NotchView`, `SessionRowView`, `CodexBuddyView`, and `toolInfo()` |
| `GlobalShortcutManager.swift` | Global `NSEvent` monitor for ⌘⇧Y / ⌘⇧N (requires Accessibility permission) |
| `TerminalFocuser.swift` | `NSAppleScript` activation of the first detected terminal app after a decision |
| `scripts/devisland-bridge.sh` | Bash hook handler; appends `terminal_title` to payload, forwards to app, converts response to per-CLI JSON format |
| `scripts/install-bridge.sh` | Registers hooks in Claude / Codex / Gemini config files |
| `scripts/test-hook.sh` | Manual test CLI; simulates hook events for all three CLIs |

### AppState Session Model

- **`ActiveSession`** — one per unique `session_id` prefix (first 8 chars). Tracks the last tool/event/message and whether it has a pending approval. Pruned after 120 s of inactivity.
- **`PendingRequest`** — queued hook event with a `responseHandler` closure that writes back to the open TCP connection. Processed FIFO; a 120-second timeout auto-denies.
- **`selectedSessionId`** — which session's data is shown in the left panel of the expanded notch. Switching sessions does not affect the pending queue order.

### Hook Event Handling (AppState.handleMessage)

Events are classified into three buckets:

1. **Stop events** (`stop`, `exit`, `shutdown`, `sessionend`, …) — remove the session from `activeSessions`, respond `approved` immediately.
2. **Notification events** (`sessionstart`, `notification`, `posttooluse`, `precompact`, `subagentstop`, …) — update session state, respond `approved` immediately (no user action needed).
3. **Approval events** (`permissionrequest`, `pretooluse`, `beforetool`, …) — added to `pendingQueue` and shown in the UI for user decision.

### Gemini-Specific UX Optimizations

DevIsland includes advanced logic to handle the unique security and workflow characteristics of the Gemini CLI.

#### 1. Auto-Edit Mode Tracking
DevIsland tracks the transition between **Plan mode** (where Gemini proposes changes) and **Auto-Edit mode** (where Gemini executes approved changes).
- **Trigger**: When the user approves a plan in the terminal (`exit_plan_mode`), DevIsland switches the session to `isAutoEditActive = true`.
- **Behavior**: While in Auto-Edit mode, all subsequent tool calls (like `write_file`, `replace`) are automatically approved by DevIsland to allow uninterrupted execution of the approved plan.
- **Reset**: When the agent returns to planning (`enter_plan_mode`), the session reverts to manual approval mode.

#### 2. Interactive Notifications (Double-Prompt Prevention)
Some tools require user input in the terminal regardless of DevIsland's approval (e.g., `ask_user`, `run_shell_command`, or any tool acting on `.gemini/tmp/` files during planning).
- **Strategy**: Instead of showing a blocking "Approve/Deny" prompt (which would force the user to click in DevIsland AND then type in the terminal), DevIsland **auto-approves** these tools immediately.
- **User Awareness**: It simultaneously expands the Notch UI with a notification message: *"Check terminal for input (\(tool_name))"*.
- **UI Tagging**: Tools acting on `.gemini/tmp/` files are suffixed with `(Plan)` in the UI (e.g., `write_file (Plan)`) to clearly distinguish them from actual codebase edits.

#### 3. Gemini Interactive Emulation
Since the Gemini CLI's `BeforeTool` hook cannot override the CLI's internal security policy (PolicyEngine), DevIsland provides an **Emulation Mode**.
- **Usage**: Run Gemini CLI with `--auto-approve` or `--yolo` (to disable terminal prompts) and enable **"Gemini Interactive Emulation"** in the DevIsland menu.
- **Behavior**: DevIsland takes over the role of the terminal prompt. It will block and ask for approval for any tool classified as high-risk by `ToolKnowledge`, while letting safe tools pass. This moves the control interface from the terminal to the DevIsland GUI.

#### 4. Safe Tool Auto-Approval
Users can toggle **"Auto-approve Safe tools"** in the menu bar. When enabled, any tool classified as `Safe` by heuristics (e.g., `read_file`, `grep_search`, `list_dir`) is automatically approved without user interaction, ensuring that purely observational agent activities do not interrupt the developer.

### Window Mechanics

`NotchWindowController` creates a borderless, non-activating `NSPanel` at `.mainMenu + 1` level with `collectionBehavior: [.canJoinAllSpaces, .stationary]`. It toggles between two fixed sizes:

- Collapsed: 140 × 28
- Expanded: 680 × 300

`NotchHostingView` overrides `hitTest` so transparent regions pass clicks through to whatever is beneath the window. A click on the collapsed notch calls `expandFromCollapsedWindow()`, which grows the frame first (to reserve canvas space) then sets `isNotchExpanded = true` with a 20ms delay so SwiftUI animates into an already-large frame without clipping artifacts.

On collapse, the frame shrinks after a 0.45 s delay (matching the SwiftUI spring animation) to avoid a jump.

### project.yml

`project.yml` is the XcodeGen spec. Changing any build setting, adding a new source file to the target, or modifying entitlements should be done here, not in a hand-edited `.xcodeproj`. Re-run `xcodegen generate` after any edit.

The app is an `LSUIElement` (no Dock icon). It needs two privacy permissions already declared in `project.yml`: Apple Events (for `TerminalFocuser`) and Accessibility (for `GlobalShortcutManager`).

