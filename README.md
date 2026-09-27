# DevIsland

**DevIsland** is an open-source macOS menu bar app that shows Claude Code, Codex CLI, Gemini CLI, and Antigravity CLI activity and approval requests in the notch area in real time. It receives CLI hook events, tracks session state, and lets you handle allow or deny decisions quickly from a Dynamic Island-style panel.

## Key Features

- **Notch overlay UI**: Stays behind the notch until agent activity or an approval request arrives, then expands when needed.
- **Real-time session monitoring**: Tracks activity, unread events, and approval state for Claude, Codex, Gemini, and Antigravity sessions.
- **Fleet Radar**: A local-first Session Center dashboard for active coding agents, Git worktree state, changed-path overlap warnings, and attention-ranked work.
- **Approval proxy**: Lets you allow or deny higher-risk tool requests in the app, then stores reusable allow rules in SQLite.
- **Agent message display**: Renders hook-delivered messages, Markdown, and edit or replace diffs in an easy-to-read in-app view.
- **Sub-agent grouping**: Organizes sub-agent sessions under their parent session to make parallel work easier to follow.
- **Caffeine**: Prevents display and system idle sleep while on AC power or a connected VPN, with configurable Wi-Fi exclusions and an optional session idle timeout.
- **Terminal focus restoration**: Guides you back to the relevant terminal (iTerm, WezTerm, Ghostty, Apple Terminal, cmux, Orca, and more) when a task needs attention.
- **OpenPeon CESP sound packs**: Maps audio feedback to hook events such as approval requests, task completion, errors, and resource limits.

## Installation

Requires macOS 15 or later on Apple Silicon (arm64); Intel Macs are not currently supported.

Download the latest DMG from [GitHub Releases](https://github.com/nangchang/DevIsland/releases/latest).

1. Open the DMG and drag `DevIsland.app` to `/Applications`.
2. Try to open `/Applications/DevIsland.app` once and let macOS block the unnotarized app.
3. Choose **Apple menu > System Settings > Privacy & Security**. In the **Security** section, select **Open Anyway** for DevIsland. This option is available for about one hour after the blocked launch attempt.
4. Authenticate when prompted, then confirm **Open**. See [Apple's guide to overriding app security settings](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac).
5. Open **Settings** to choose the language and other preferences, install the desired provider bridge from the menu bar app's hook-install actions, then choose **Session Center…**.

## How It Works

DevIsland runs its approval proxy and UI inside the macOS app, without a separate background daemon.

```text
CLI Hook
  -> devisland-bridge.sh
    -> HookSocketServer
      -> ApprovalProxyController
        -> ApprovalPolicyEngine
        -> ProviderAdapter
        -> UI decision when needed
      -> bridge response
```

- The bridge is a thin layer that enriches stdin payloads and forwards them to the app.
- The app handles policy evaluation, session caching, UI decisions, and provider-specific response JSON.
- Rules, session cache, event logs, approval decisions, and PTY messages are stored in `~/Library/Application Support/DevIsland/approval-proxy.sqlite3`.

For more detail, see [docs/agent/approval-proxy.md](docs/agent/approval-proxy.md).

## Getting Started

### 1. Generate and run the project

DevIsland uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate its Xcode project.

```bash
brew install xcodegen
xcodegen generate
open DevIsland.xcodeproj
```

To verify a build without Xcode, run:

```bash
./scripts/build_and_run.sh --no-kill --no-run
```

### 2. Install the bridge

Install the bridge to forward hook events from terminal-based coding agents to DevIsland.

```bash
# Install for every supported CLI
./scripts/install-bridge.sh --all

# Install only the providers you use
./scripts/install-bridge.sh --claude
./scripts/install-bridge.sh --codex
./scripts/install-bridge.sh --gemini
./scripts/install-bridge.sh --antigravity
```

See [docs/agent/hook-providers.md](docs/agent/hook-providers.md) for bridge installation details and provider-specific response formats.

To keep DevIsland session and status tracking while Codex Auto-review handles approvals, use the installed wrapper with the Auto-review profile:

```bash
"$HOME/Library/Application Support/DevIsland/codex-devisland-auto" --profile auto-review
```

On this path, only Codex `PermissionRequest` events pass through to Codex; lifecycle hooks continue to be forwarded to DevIsland. Add the command as a shell alias if you use it often.

### 3. Test

Use the isolated test script so an existing app instance is not disturbed.

```bash
./scripts/run-tests.sh
```

See [docs/agent/build-and-test.md](docs/agent/build-and-test.md) for the full build and test workflow.

## Settings

### Claude approval mode

Choose how Claude approvals are handled in **Settings > Providers > Claude Code**.

- **Native**: Uses Claude's internal rules.
- **App cache**: Uses the DevIsland SQLite approval cache.
- **Hybrid**: Uses both Claude's internal rules and the DevIsland cache.

### Gemini / Antigravity CLI

Run Gemini CLI with `--yolo` or `--auto-approve`, then enable normal-mode emulation in **Settings > Providers > Gemini / Antigravity** to use the DevIsland approval UI instead of terminal prompts. Safe tools, such as file reads, can be auto-approved to reduce notch interruptions. Antigravity CLI shares this same emulation setting.

### Launch at login

Copy the app to `/Applications/DevIsland.app`, then install the LaunchAgent to start it automatically when you log in.

```bash
./scripts/install-launch-agent.sh
```

To remove it:

```bash
PLIST=~/Library/LaunchAgents/kr.or.nes.DevIsland.plist
launchctl unload "$PLIST" 2>/dev/null; rm -f "$PLIST"
```

### OpenPeon CESP sound packs

DevIsland reads [OpenPeon CESP](https://openpeon.com/spec) v1.0 sound packs to add audio feedback to hook events. The default pack location is `~/.openpeon/packs`.

```text
~/.openpeon/packs/
  sample-pack/
    openpeon.json
    sounds/
      approval.mp3
      done.wav
```

Supported categories include `session.start`, `task.acknowledge`, `task.complete`, `task.error`, `input.required`, `resource.limit`, `session.end`, `task.progress`, and `user.spam`. See [docs/agent/openpeon-cesp.md](docs/agent/openpeon-cesp.md) for details.

## Troubleshooting

### Claude Code requests denied in `auto` mode

Claude Code's `auto` mode can block some actions with its own security policy before DevIsland's bridge is called. In that case, the notch approval UI does not appear and you see `Denied by auto-mode classifier`.

Run the task in interactive mode instead of `auto` mode. Interactive mode lets you approve the action directly through DevIsland.

## Development and Contributions

- See [CHANGELOG.md](CHANGELOG.md) for release notes.
- See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution and development guidelines.
- See [AGENTS.md](AGENTS.md) for agent-work instructions.

## License

DevIsland is distributed under the MIT License.

---

Created by [nangchang](https://github.com/nangchang)
