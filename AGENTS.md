# AGENTS.md

General project instructions for AI coding agents working in this repository.

## What This Project Is

DevIsland is a macOS menubar + notch-overlay app that intercepts Claude Code, Codex CLI, and Gemini CLI hook events in real time. The bridge forwards hook payloads to the running app, DevIsland displays activity and approval prompts in a Dynamic Island-style panel, and the bridge relays allow/deny decisions back to the originating CLI.

## Start Here

Read this file before editing. Open the referenced docs only when the task touches that area.

| Topic | Document |
|---|---|
| Build, tests, project generation | [docs/agent/build-and-test.md](docs/agent/build-and-test.md) |
| Claude/Codex/Gemini/Antigravity hook setup and response shapes | [docs/agent/hook-providers.md](docs/agent/hook-providers.md) |
| Approval Proxy, IPC, SQLite, PTY, known gaps | [docs/agent/approval-proxy.md](docs/agent/approval-proxy.md) |
| UI Customization (Notch settings) | [docs/agent/ui-customization.md](docs/agent/ui-customization.md) |
| Plugin architecture, host surfaces, permissions | [docs/agent/plugin-architecture.md](docs/agent/plugin-architecture.md) |
| Terminal focus and AoE session navigation | [docs/agent/terminal-focus-aoe.md](docs/agent/terminal-focus-aoe.md) |
| Caffeine power and session-timeout behavior | [docs/agent/caffeine.md](docs/agent/caffeine.md) |
| OpenPeon CESP sound packs | [docs/agent/openpeon-cesp.md](docs/agent/openpeon-cesp.md) |
| Performance and stability rules | [docs/agent/stability-standards.md](docs/agent/stability-standards.md) |

## One-Time Local Setup

After cloning, run these once to configure the development environment:

```bash
# XcodeGen — generate .xcodeproj from project.yml
# SwiftLint — run the same structural gate used by CI
brew install xcodegen swiftlint
xcodegen generate

# xcode-build-server — gives SourceKit-LSP full project context
# Eliminates false-positive "Cannot find type X in scope" errors in editors/AI tools
brew install xcode-build-server
xcode-build-server config -scheme DevIsland -project DevIsland.xcodeproj
```

`buildServer.json` is gitignored (contains machine-local DerivedData paths). Re-run `xcode-build-server config` if you switch schemes or DerivedData is cleaned.

## Mandatory Checks

- Run SwiftLint before committing Swift source changes:

```bash
swiftlint lint --no-cache
```

- Run the existing unit tests before committing any code change:

```bash
./scripts/run-tests.sh
```

- Use the repository `.swiftlint.yml`; it enforces structural limits such as file length, type body length, and function parameter count.
- Use `./scripts/run-tests.sh` instead of ad hoc test commands unless there is a strong reason. It runs in isolated mode and will not interfere with a running DevIsland instance.
- If you touch `project.yml`, regenerate the Xcode project with `xcodegen generate`.
- For quick compile verification without interrupting a live app, use:

```bash
./scripts/build_and_run.sh --no-kill --no-run
```

## Non-Negotiable Architecture Rules

- Keep bridge scripts thin. They receive stdin payloads, add terminal metadata, forward IPC, and print provider-specific responses. Do not move DB access, policy evaluation, UI rendering, pack loading, CESP mapping, audio playback, or long-running work into the bridge.
- Never block the UI or hook response path with heavy work. AppleScript, SQLite writes, network I/O, pack scans, and validation must run asynchronously or off the main thread as appropriate.
- Sound playback and other best-effort side effects must never change approval/deny behavior or delay hook responses.
- Preserve provider-specific hook semantics. Claude, Codex, and Gemini have different approval events and response formats.
- Do not hand-edit a generated `.xcodeproj`; update `project.yml` and regenerate.
- The app is an `LSUIElement` and relies on Apple Events for terminal focusing and Accessibility for global shortcuts.

## Key Files

| File | Responsibility |
|---|---|
| `DevIslandApp.swift` | `@main` entry, `MenuBarExtra`, `AppDelegate` |
| `AppState.swift` | Socket lifecycle and session state; assembles and delegates event classification, approval flow, and plugin/Caffeine wiring |
| `ApprovalFlowCoordinator.swift` | Pending queue, display selection, decision dispatch, approval timeout (extracted from `AppState`, R2-c) |
| `HookEventRouter.swift` / `HookEventClassifier.swift` | Pure, side-effect-free event classification and `handleParsedEvent` phase dispatch (R2-a) |
| `HookSocketServer.swift` | Loopback TCP + Unix socket listener, one-connection-per-hook event handling |
| `PluginHost.swift` | Plugin lifecycle, event dispatch, host command/effect execution |
| `ApprovalProxyController.swift` | Policy lookup, persistence, and rich IPC response orchestration |
| `ProviderAdapter.swift` | Provider-specific hook response JSON |
| `SQLiteApprovalStore.swift` | Rules, session cache, replay log, decisions, PTY transcript storage |
| `SettingsStore.swift` | UserDefaults-backed app and bridge runtime settings |
| `NotchWindowController.swift` | NSPanel and SwiftUI notch UI host |
| `Plugins/BuiltIn/OpenPeon/` | OpenPeon plugin, CESP models, pack store/validation, event mapping, audio playback |
| `scripts/devisland-bridge.sh` | Shell hook entrypoint |
| `scripts/devisland_bridge.py` | Payload enrichment, IPC forwarding, provider response formatting |
| `scripts/install-bridge.sh` | Hook registration for Claude, Codex, Gemini, and Antigravity |
| `scripts/test-hook.sh` | Manual hook simulation |

## Commit Guidelines

1. **Feature Branches**: Never commit directly to `main`. Always use a descriptive branch.
2. **Atomic Commits**: Each commit should represent one logical task or fix.
3. **Commit Message Convention**:
    * **Title**: Must be in English, following Conventional Commits (e.g., `feat:`, `fix:`, `docs:`).
    * **Body**: Must include a detailed explanation in **Korean**, focusing on the "Why" and the rationale behind the change.
4. **Propose & Confirm Protocol**: Before performing any mutation (file edit, branch creation, commit), the agent MUST propose the plan and the draft commit message to the user and obtain explicit approval.
5. **Explain the Why**: Commit messages must describe the rationale or problem solved, not just “feedback applied”.
6. **No Mixed Changes**: Do not mix unrelated refactors, style changes, docs, and features in one commit.
7. **Update Documentation After Changes**: When finishing work, check whether code, behavior, settings, commands, or architecture docs need updates. Update the relevant docs in the same logical change, or explicitly explain why no documentation update is needed.
8. **Descriptive Tags**: Use conventional prefixes such as `feat:`, `fix:`, `docs:`, `refactor:`.
9. **AI Attribution**: When an AI agent creates a commit, append a `Co-Authored-By:` trailer to the message. For GitHub comments or issues, append a `> 🤖 Generated with [<Tool>](url)` footer.

## Working Tree Safety

- The worktree may contain user changes. Do not revert or overwrite changes you did not make.
- Stage explicit paths. Avoid broad `git add -A` when unrelated changes might exist.
- Do not use destructive commands such as `git reset --hard` or `git checkout --` unless explicitly requested.

## project.yml

`project.yml` is the XcodeGen spec. Changing build settings, source membership, resources, or entitlements belongs there, followed by `xcodegen generate`.
