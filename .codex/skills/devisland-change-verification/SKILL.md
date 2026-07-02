---
name: devisland-change-verification
description: Verify DevIsland repository changes before commit or handoff. Use when Codex changes DevIsland code, tests, project.yml, scripts, docs, packaging, skills, plugin architecture, or agent instructions and needs the project-specific build, test, documentation, and working-tree checks.
---

# DevIsland Change Verification

Use this as the common finish line for DevIsland changes. Keep the check proportional to the risk, but do not skip verification silently.

## Start

Read `AGENTS.md` first. For build details, read `docs/agent/build-and-test.md`.

Check the worktree before editing and before final handoff:

```bash
git status --short
```

Do not revert or stage unrelated user changes.

## Standard Verification

Run the existing unit test wrapper before committing code changes:

```bash
./scripts/run-tests.sh
```

Prefer this over ad hoc `xcodebuild test`; it runs in isolated mode and avoids interfering with a running DevIsland instance.

For quick compile verification without killing or launching the app:

```bash
./scripts/build_and_run.sh --no-kill --no-run
```

Use this when tests are too broad for the immediate task, after project generation changes, or when the change is UI/runtime-facing.

## Project File Changes

If `project.yml` changes, regenerate the Xcode project:

```bash
xcodegen generate
```

Never hand-edit generated `.xcodeproj` content. If source membership, resources, entitlements, build settings, or package dependencies need to change, update `project.yml`.

## Documentation Check

After code, behavior, settings, commands, architecture, hook semantics, or packaging changes, decide whether docs must change. Check these docs by area:

- Build and tests: `docs/agent/build-and-test.md`
- Hooks and provider semantics: `docs/agent/hook-providers.md`
- Approval proxy, IPC, SQLite, PTY: `docs/agent/approval-proxy.md`
- Notch settings and UI behavior: `docs/agent/ui-customization.md`
- OpenPeon CESP: `docs/agent/openpeon-cesp.md`
- Caffeine power behavior: `docs/agent/caffeine.md`
- Terminal focus and AoE navigation: `docs/agent/terminal-focus-aoe.md`
- Plugin platform changes: `docs/agent/plugin-architecture.md` and `docs/agent/plugin-architecture-implementation-plan.md`
- Stability rules: `docs/agent/stability-standards.md`
- Top-level agent rules: `AGENTS.md`

If docs do not need changes, state that explicitly in the handoff.

## Handoff

Report:

- Changed behavior and important files.
- Verification commands run and their result.
- Any skipped checks and why.
- Remaining untracked or unrelated files.
