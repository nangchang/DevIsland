# DevIsland

**DevIsland** is an open-source macOS menu bar app that shows Claude Code, Codex CLI, and Gemini CLI activity and approval requests in the notch area in real time. It receives CLI hook events, tracks session state, and lets you handle allow or deny decisions quickly from a Dynamic Island-style panel.

## Key Features

- **Notch overlay UI**: Stays behind the notch until agent activity or an approval request arrives, then expands when needed.
- **Real-time session monitoring**: Tracks activity, unread events, and approval state for Claude, Codex, and Gemini sessions.
- **Fleet Radar**: A local-first Session Center dashboard for active coding agents, Git worktree state, changed-path overlap warnings, and attention-ranked work.
- **Approval proxy**: Lets you allow or deny higher-risk tool requests in the app, then stores reusable allow rules in SQLite.
- **Agent message display**: Renders hook-delivered messages, Markdown, and edit or replace diffs in an easy-to-read in-app view.
- **Sub-agent grouping**: Organizes sub-agent sessions under their parent session to make parallel work easier to follow.
- **Terminal focus restoration**: Guides you back to the relevant terminal when a task needs attention.
- **OpenPeon CESP sound packs**: Maps audio feedback to hook events such as approval requests, task completion, errors, and resource limits.

## OpenAI Build Week 2026 Scope

- Implementation start: 2026-07-16 04:40 KST
- Baseline before Fleet Radar: `1fc23ce` (`v0.14.1-dev`). Existing DevIsland functionality above belongs to this baseline.
- Fleet Radar implementation start: `ab847ba`. The Fleet tab, local Git worktree state, changed-path overlap analysis, attention ranking, and related tests and documentation are the Build Week additions. The detailed scope is fixed in the [Fleet Radar implementation plan](docs/agent/fleet-radar-implementation-plan.md).

## What Was Built During Build Week

DevIsland now includes **Fleet Radar**, a local-first dashboard for deciding which active coding agent needs attention and spotting when parallel Git worktrees are modifying the same paths. Choose **Session Center…** from the menu bar app and select the default **Fleet** tab; the existing **Sessions** and **Insights** tabs remain available in the same standard macOS window.

| Before Build Week (`1fc23ce`) | Added during Build Week |
|---|---|
| Notch activity and approval UI | Attention-ranked cards for active parent sessions |
| Session tracking and sub-agent relationships | Sub-agents nested under their parent Fleet card |
| Session History and Insights | Session Center with Fleet, Sessions, and Insights tabs |
| Workspace paths attached to sessions | Read-only branch, detached HEAD, clean or dirty, and unmerged status |
| Explicit terminal focus and session detail actions | Separate Show Detail and Focus Terminal actions on each card |
| No cross-worktree Git analysis | Same-repository, different-worktree changed-path overlap warnings |

The overlap badge is an early warning, **not merge-conflict detection**. It compares changed paths only when active worktrees share a repository identity and have different worktree roots. Scanning uses bounded `/usr/bin/git` reads behind an actor cache. Fleet performs no Git writes, network requests, automatic agent orchestration, or background polling; ahead or behind, pull request, and CI status are intentionally outside this MVP.

### Codex and GPT-5.6 workflow

Codex and GPT-5.6 were used throughout the Build Week work: to explore the existing session architecture, design the Fleet Radar data flow and SwiftUI surfaces, implement the feature, and verify multi-worktree scenarios. Codex also helped turn the working demo into a concise submission video.

Watch the [Fleet Radar demo on YouTube](https://youtu.be/P4oRNJsYCQA). The reproducible scenario is documented in the [Fleet Radar Build Week demo runbook](docs/agent/fleet-radar-demo.md).

### Install the Build Week DMG (macOS 15+)

The locally generated, checksum-verified handoff artifact is `DevIsland-0.14.1-dev-arm64.dmg`. It is an arm64 development build with an ad-hoc signature but no Developer ID signature or notarization, and is intentionally ignored by Git. Launching it on a separate clean Mac has not yet been verified.

1. Open the DMG and drag `DevIsland.app` to `/Applications`.
2. Try to open `/Applications/DevIsland.app` once and let macOS block the unnotarized app.
3. Choose **Apple menu > System Settings > Privacy & Security**. In the **Security** section, select **Open Anyway** for DevIsland. This option is available for about one hour after the blocked launch attempt.
4. Authenticate when prompted, then confirm **Open**. See [Apple's guide to overriding app security settings](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac).
5. Open **Settings** to choose the language and other preferences, install the desired provider bridge from the menu bar app's hook-install actions, then choose **Session Center…**.

To reproduce the DMG from source, you need Xcode 16+, XcodeGen, and `create-dmg`:

```bash
brew install xcodegen create-dmg
./scripts/create-dmg.sh
```

On the Build Week verification Mac, repeated official packaging attempts—including a run with GUI automation privileges—completed the Release archive, but Finder automation was unavailable while `create-dmg` applied its window layout:

```text
execution error: Finder got an error: AppleEvent timed out. (-1712)
Failed running AppleScript
```

If that environment-specific error recurs, `scripts/create-dmg.sh` cleans the partial output and automatically retries the official `create-dmg` flow with `--skip-jenkins`, then requires `hdiutil verify` to pass. The fallback skips Finder's custom icon positions and window layout, but the resulting read-only DMG remains installable and contains both `DevIsland.app` and the Applications link.

To build and test without launching or terminating a running DevIsland instance:

```bash
./scripts/run-tests.sh
./scripts/build_and_run.sh --no-kill --no-run
```

### Reproduce the worktree-overlap demo

Use the fixed English [Fleet Radar Build Week demo runbook](docs/agent/fleet-radar-demo.md). It defines three exact branch, worktree, file, and session-label fixtures; the pending-approval cue; the Detail-versus-Focus sequence; and complete cleanup commands. The overlap analysis stays local and does not modify any repository.

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

### Gemini CLI

Run Gemini CLI with `--yolo` or `--auto-approve`, then enable normal-mode emulation in DevIsland to use the DevIsland approval UI instead of terminal prompts. Safe tools, such as file reads, can be auto-approved to reduce notch interruptions.

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
