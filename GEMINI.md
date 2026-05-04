# 🏝️ DevIsland Project Instructions

This document provides essential context and instructions for AI agents working on the DevIsland project. DevIsland is a macOS application that provides a "Dynamic Island" style dashboard for monitoring and controlling AI agents (like Claude Code).

## 🏗️ Project Overview

- **Core Purpose**: Real-time monitoring and control of AI agent activities via a notch-integrated UI.
- **Technology Stack**:
  - **Language**: Swift 5.10+
  - **Frameworks**: SwiftUI, Combine, AppKit (NSPanel), Network.framework (TCP Sockets).
  - **Platform**: macOS 14.0+ (Sonoma and later).
- **Key Architecture**:
  - **MVVM-like**: `AppState` (singleton `@ObservableObject`) manages the core logic and state.
  - **Communication**: A bash bridge (`devisland-bridge.sh`) sends JSON payloads over TCP (port 9090) to the app.
  - **UI**: `NotchWindowController` manages a specialized `NSPanel` (non-activating, borderless, floating) that hosts SwiftUI views.

## 🚀 Building and Running

### Building with XcodeGen (Recommended for Development)

This project uses **XcodeGen**. Do not commit the `.xcodeproj` file.

```bash
# 1. Install XcodeGen if you haven't
brew install xcodegen

# 2. Generate the project file (re-run if project.yml changes)
xcodegen generate

# 3. Open and build in Xcode
open DevIsland.xcodeproj
```

### Quick Build & Run (CLI only)

For a quick build without generating an Xcode project:

```bash
bash scripts/build_and_run.sh
```
This script compiles assets and Swift sources, assembles the app bundle in `dist/`, and launches it.

## 🛠️ Development Conventions

### Coding Style
- **Swift**: Follow standard Swift API Design Guidelines. Use `PascalCase` for types and `camelCase` for variables/functions.
- **Simplicity**: Prioritize surgical changes. Avoid over-engineering or speculative abstractions.
- **State Management**: Use `AppState.shared` for global app state and session management.

### Communication & CLI Support
- **Hook Events**: The app receives events via `HookSocketServer` on port 9090.
- **Supported CLIs**:
  - **Claude Code**: Uses `PermissionRequest` for approvals.
  - **Gemini CLI**: Uses `BeforeTool` for approvals; other lifecycle events (`SessionStart`, etc.) are also tracked.
  - **Codex CLI**: Uses `PreToolUse` for approvals.
- **Bridge**: `scripts/devisland-bridge.sh` is the interface between CLI agents and the app. It auto-detects the source CLI based on event names.
- **Installation**: `scripts/install-bridge.sh` configures the respective settings files (e.g., `~/.gemini/settings.json`).

### Key Components
| File | Responsibility |
|---|---|
| `DevIslandApp.swift` | App entry, MenuBar UI, and `AppDelegate` initialization. |
| `AppState.swift` | Logic for socket messages, session pruning, and pending request queue. |
| `NotchWindowController.swift` | Management of the `NSPanel` and its display logic (positioning, expanding/collapsing). |
| `HookSocketServer.swift` | TCP server implementation using `NWListener`. |
| `GlobalShortcutManager.swift` | Handling global hotkeys (⌘⇧Y / ⌘⇧N). |
| `TerminalFocuser.swift` | AppleScript logic to focus the terminal after an action. |

## 📝 Critical Notes

- **Permissions**: The app requires **Accessibility** (for global shortcuts) and **Automation/Apple Events** (to focus the terminal) permissions.
- **LSUIElement**: The app is a "UI Element" (`LSUIElement = true`), meaning it has no Dock icon and primarily lives in the Menu Bar and the Notch.
- **Window Level**: The notch window sits at `.mainMenu + 1` level to appear over most other windows, including full-screen apps (if configured).
- **Logging**:
  - Bridge logs: `/tmp/DevIsland.bridge.log`
  - App logs: `/tmp/DevIsland.log` and `/tmp/DevIsland.error.log` (when run via LaunchAgent).

## 🤝 Contribution Guidelines

- Always run `xcodegen generate` after modifying `project.yml`.
- Ensure changes to the UI account for both collapsed and expanded states in `NotchWindowController`.
- Maintain the surgical change policy: only modify what is necessary for the task at hand.
