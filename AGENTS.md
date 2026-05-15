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

# Run unit tests (RECOMMENDED: Isolated Mode)
# This will not interfere with a running DevIsland instance.
./scripts/run-tests.sh

# Run unit tests via standard CLI
xcodebuild test -project DevIsland.xcodeproj -scheme DevIsland -destination 'platform=macOS'
```

Build target: **macOS 14.0+**, Xcode 15+. 

**Mandatory Requirement:** AI agents working on this codebase MUST run the existing unit tests and ensure they pass before committing any changes. Use `./scripts/run-tests.sh` to test safely while the app is running.

**Release builds** are produced by CI (`.github/workflows/release.yml`) on version tags. The workflow runs `xcodebuild archive` unsigned and packages a DMG via `hdiutil`.

## Quick Build (No Xcode)

For environments without Xcode (e.g. CI, Codex), use the shell build script:

```bash
# Full rebuild and launch (stops current process)
./scripts/build_and_run.sh

# Build only (isolated, does not stop current process)
./scripts/build_and_run.sh --no-kill --no-run
```

This compiles all `DevIsland/*.swift` sources with `swiftc`, assembles an app bundle under `dist/DevIsland.app`, and launches it. Pass `--verify` to assert the process started. Use `--no-kill --no-run` to verify compilation without interrupting your live environment.

## Multi-CLI Support

DevIsland supports multiple AI agent CLIs through the same bridge architecture.

### Supported CLIs — Quick Reference

| CLI Agent | Config File | Approval Event | Lifecycle Events | Docs |
|---|---|---|---|---|
| **Claude Code** | `~/.claude/settings.json` | `PermissionRequest` | `SessionStart`, `SessionEnd`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop` | [hooks reference](https://docs.anthropic.com/en/docs/claude-code/hooks) |
| **Codex CLI** | `~/.codex/hooks.json` + `config.toml` | `PermissionRequest` | `SessionStart`, `PreToolUse`, `PostToolUse`, `Stop` | [openai.com/codex](https://openai.com/codex) |
| **Gemini CLI** | `~/.gemini/settings.json` | `BeforeTool` | `SessionStart`, `SessionEnd`, `AfterAgent`, `Notification` | [geminicli.com/hooks](https://geminicli.com/hooks) |

---

### Claude Code Hook Spec

**Config file:** `~/.claude/settings.json` (or `.claude/settings.json` per-project)  
**Full spec:** https://docs.anthropic.com/en/docs/claude-code/hooks

> **Important (Auto-Mode):** Claude Code has an internal **Auto-Mode Classifier** that may block security-sensitive operations (like creating LaunchAgents or modifying system plists) *before* the bridge is even called. If you see "Denied by auto-mode classifier", this is an internal Claude restriction and cannot be bypassed via DevIsland. Use interactive mode for such tasks.

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
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/path/to/devisland-bridge.sh --source claude" }
        ]
      }
    ],
    "PostToolUse": [
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

DevIsland registers Claude `PreToolUse`/`PostToolUse` for progress tracking only. Approval decisions still happen exclusively through `PermissionRequest`.

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
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/path/to/devisland-bridge.sh --source codex", "timeout": 86400 }
        ]
      }
    ],
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
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/path/to/devisland-bridge.sh --source codex" }
        ]
      }
    ],
    "Stop": [
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

DevIsland uses `PermissionRequest` as the primary approval hook. Response format:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Blocked by DevIsland"
    }
  }
}
```

DevIsland keeps `PreToolUse` registered for status tracking only and returns `{}` for those events so Codex continues without a DevIsland approval prompt.

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
    ],
    "AfterAgent": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/devisland-bridge.sh --source gemini" }] }
    ],
    "Notification": [
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

If omitted, the bridge auto-detects from `hook_event_name` and payload shape (`PreToolUse` → codex, `PermissionRequest` with Codex tool metadata → codex, `PermissionRequest` with Claude permission metadata → claude, `BeforeTool` → gemini).

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
| `scripts/devisland-bridge.sh` | Bash hook entrypoint; collects terminal metadata and delegates payload handling to the Python bridge helper |
| `scripts/devisland_bridge.py` | JSON payload enrichment, TCP forwarding, and per-CLI hook response formatting |
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

## Approval Proxy Architecture

DevIsland acts as a policy-based **Approval Proxy daemon**: the macOS app itself is the daemon + UI, and the bridge scripts stay ultra-thin. No separate Node.js/Tauri process is needed.

### Module Boundaries

```
DevIsland macOS app
  ├─ HookSocketServer / HookIPCServer   — TCP + Unix domain socket listeners
  ├─ ApprovalProxyController            — orchestrates policy lookup, DB writes, response
  ├─ ProviderAdapter                    — formats decision into per-CLI hook response JSON
  │   ├─ ClaudeAdapter                  — updatedPermissions, AskUserQuestion, Elicitation
  │   ├─ CodexAdapter                   — session cache, persistent rules
  │   └─ (GeminiPromptPolicy — TODO)    — Gemini-specific policy and emulation control
  ├─ HookEventNormalizer                — normalises event names across CLI dialects
  ├─ ApprovalPolicyEngine               — 8-priority rule evaluation against SQLite
  ├─ SQLiteApprovalStore                — rules, session_cache, hook_events, decisions, pty_messages
  ├─ AppSettings / SettingsStore        — UserDefaults-backed settings with Codable structs
  └─ SwiftUI windows                    — Settings, Approval Rules, Replay Log, PTY Transcript
```

Bridge responsibilities (keep thin):
- Receive stdin payload from the CLI
- Add terminal metadata and `cli_source`
- Send IPC envelope to the app
- Write app response to stdout in the CLI-specific format

Bridge must NOT: touch the DB, render UI, compute policy, or run long background tasks.

### IPC Protocol v1

All bridge↔app communication uses **length-prefixed JSON framing** over TCP `127.0.0.1:9090` (or Unix domain socket `~/Library/Application Support/DevIsland/dev-island.sock`).

```
[4-byte big-endian length][UTF-8 JSON body]
```

**Envelope (bridge → app):**
```json
{
  "protocol": "dev-island-hook-ipc",
  "version": 1,
  "requestId": "<uuid>",
  "sentAt": "2026-05-09T12:34:56Z",
  "token": "<bridge-token or null>",
  "source": "claude",
  "payload": { "hook_event_name": "PermissionRequest", "session_id": "...", ... }
}
```

**Rich response (app → bridge):**
```json
{
  "protocol": "dev-island-hook-ipc",
  "version": 1,
  "requestId": "<same uuid>",
  "status": "ok",
  "decision": "approved",
  "reason": "matched session rule",
  "injection": null,
  "providerOutput": { "hookSpecificOutput": { "hookEventName": "PermissionRequest", "decision": { "behavior": "allow" } } }
}
```

If `providerOutput` is present, the bridge writes it to stdout verbatim. Otherwise it falls back to legacy `response`-field conversion.

**Transport failure fallback** (when app is unreachable):

| Risk level | Default action |
|---|---|
| safe / read-only | pass or allow |
| low / medium | deny (cannot prompt) |
| high / write | deny |
| critical / shell / destructive | deny |
| unknown | deny (user-overridable in settings) |

### Claude-Specific Hook Handling

- **`PermissionRequest`**: primary approval event. Response may include `updatedPermissions` to update Claude's internal permission state for the session (native mode) or rely on DevIsland `session_cache` (app/hybrid mode).
- **`PreToolUse`**: handles `AskUserQuestion` (collects answers → `updatedInput.answers`) and `ExitPlanMode` (plan approval UI).
- **`Elicitation`**: MCP server input requests.
- **`UserPromptSubmit`**: prompt policy — can rewrite or block the user's input before it reaches the model.
- **`PostToolUse`**: audit/replay log only; no approval needed.

**Claude session approval modes** (Settings > Providers > Claude Code):
- **Native** (default): DevIsland returns `updatedPermissions` with `destination: session`; Claude manages the rule internally.
- **App cache**: DevIsland stores the rule in `session_cache` and auto-allows on future requests without touching Claude's permission state.
- **Hybrid**: both; app cache is the fallback when native payload generation fails.

### Codex-Specific Hook Handling

Codex has no native session-permission mutation. DevIsland manages all session and persistent rules in SQLite. Session approval inserts a row into `session_cache`; persistent approval inserts into `rules`.

### SQLite Storage

DB path: `~/Library/Application Support/DevIsland/approval-proxy.sqlite3`  
PRAGMAs: `journal_mode=WAL`, `busy_timeout=5000`, `foreign_keys=ON`

| Table | Purpose |
|---|---|
| `rules` | persistent allow/deny rules per provider/tool/pattern |
| `session_cache` | in-session auto-allow entries (expire with session) |
| `hook_events` | append-only audit log of every received hook event |
| `approval_decisions` | decision record linked to `hook_events` (replay source of truth) |
| `pty_messages` | PTY transcript per session (provider, direction, content, timestamp) |

### PTY Wrapper (Experimental)

`scripts/devisland_pty.py` forks a child process under a PTY, forwards all I/O, and dispatches `PTYOutput` IPC events to the app so auto-inject patterns can fire. Key design points:

- Incremental UTF-8 decoder preserves multi-byte sequences across chunk boundaries.
- IPC calls are dispatched to a `ThreadPoolExecutor(max_workers=4)` to cap concurrency during burst output.
- Per-session 1 KB sliding window buffer in AppState resolves patterns split across chunk boundaries.
- `injection` field in `IPCRichResponse` carries text to write back to the PTY stdin.

### Known Gaps

| # | Location | Description |
|---|---|---|
| 1 | `ApprovalPolicyEngine.swift` | Only exact tool-name matching; Glob/Regex/Prefix modes not yet implemented |
| 2 | `AppState.sendDecision` | Claude approvals not written to `session_cache` when mode is hybrid/app |
| 3 | `AppState.globalAutoApproveTypes` | ✅ Fixed: all providers now write to SQLite via `persistApprovalScope`; in-memory sets remain as a fast-path cache |
| 4 | `ProviderAdapter.swift` | `GeminiPromptPolicy.swift` does not exist; Gemini logic is minimal hardcoded formatter |
| 5 | `AppState.swift` | 93 KB class handles too many concerns; `QuestionBroker` and `GeminiSessionState` not yet extracted |

## 📝 Commit Guidelines

To maintain a clean and maintainable history, all AI agents must follow these commit rules:

1. **Feature Branches**: Never commit directly to the `main` branch. Always create a descriptive branch (e.g., `feature/xyz` or `fix/abc`) for your changes.
2. **Atomic Commits**: Divide work into meaningful, logical units. Each commit should represent a single task or fix.
3. **Explain the "Why"**: Commit messages must not just describe *what* changed, but *why* the change was made (the rationale or the problem it solves).
4. **No Mixed Changes**: Do not mix unrelated refactorings, style changes, or multiple features into a single commit. Keep commits surgical and focused.
5. **Descriptive Tags**: Use conventional commit-style prefixes (e.g., `feat:`, `fix:`, `docs:`, `refactor:`) to categorize changes.

## project.yml

`project.yml` is the XcodeGen spec. Changing any build setting, adding a new source file to the target, or modifying entitlements should be done here, not in a hand-edited `.xcodeproj`. Re-run `xcodegen generate` after any edit.

The app is an `LSUIElement` (no Dock icon). It needs two privacy permissions already declared in `project.yml`: Apple Events (for `TerminalFocuser`) and Accessibility (for `GlobalShortcutManager`).
