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
./script/build_and_run.sh
```

This compiles all `DevIsland/*.swift` sources with `swiftc`, assembles an app bundle under `dist/DevIsland.app`, and launches it. Pass `--verify` to assert the process started. This path is also wired as the `.codex/environments/environment.toml` Run action.

## Architecture

### Communication Flow

```
Claude Code (hook event)
  → devisland-bridge.sh  (stdin → JSON → TCP:9090, waits up to 300s)
    → HookSocketServer   (NWListener, port 9090)
      → AppState.handleMessage()
        → UI decision (approve / deny / timeout)
          → TCP response → bridge → Claude Code hook output
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
| `scripts/devisland-bridge.sh` | Bash hook handler; appends `terminal_title` to payload, forwards to app, converts response to hook output format |

### AppState Session Model

- **`ActiveSession`** — one per unique `session_id` prefix (first 8 chars). Tracks the last tool/event/message and whether it has a pending approval. Pruned after 120 s of inactivity.
- **`PendingRequest`** — queued hook event with a `responseHandler` closure that writes back to the open TCP connection. Processed FIFO; a 120-second timeout auto-denies.
- **`selectedSessionId`** — which session's data is shown in the left panel of the expanded notch. Switching sessions does not affect the pending queue order.

### Hook Event Handling (AppState.handleMessage)

Events are classified into three buckets:

1. **Stop events** (`stop`, `exit`, `shutdown`, `sessionend`) — remove the session from `activeSessions`, respond `approved` immediately.
2. **Notification events** (`sessionstart`, `session_start`, `posttooluse`, `post_tool_use`, `notification`, etc.) — update session state, respond `approved` immediately (no user action needed).
3. **Everything else** — treated as a permission request; added to `pendingQueue` and shown in the UI for user decision.

### Window Mechanics

`NotchWindowController` creates a borderless, non-activating `NSPanel` at `.mainMenu + 1` level with `collectionBehavior: [.canJoinAllSpaces, .stationary]`. It toggles between two fixed sizes:

- Collapsed: 140 × 28
- Expanded: 680 × 300

`NotchHostingView` overrides `hitTest` so transparent regions pass clicks through to whatever is beneath the window. A click on the collapsed notch calls `expandFromCollapsedWindow()`, which grows the frame first (to reserve canvas space) then sets `isNotchExpanded = true` with a 20ms delay so SwiftUI animates into an already-large frame without clipping artifacts.

On collapse, the frame shrinks after a 0.45 s delay (matching the SwiftUI spring animation) to avoid a jump.

### project.yml

`project.yml` is the XcodeGen spec. Changing any build setting, adding a new source file to the target, or modifying entitlements should be done here, not in a hand-edited `.xcodeproj`. Re-run `xcodegen generate` after any edit.

The app is an `LSUIElement` (no Dock icon). It needs two privacy permissions already declared in `project.yml`: Apple Events (for `TerminalFocuser`) and Accessibility (for `GlobalShortcutManager`).
