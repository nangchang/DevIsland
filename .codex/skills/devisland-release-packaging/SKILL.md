---
name: devisland-release-packaging
description: Prepare DevIsland releases, version bumps, changelog entries, DMG packaging, changelog-derived GitHub release notes, release workflow updates, tag-driven releases, dry-run releases, or distribution checks. Use for CHANGELOG.md, project.yml version/build values, scripts/create-dmg.sh, scripts/extract-release-notes.sh, .github/workflows/release.yml, bump.yml, and packaging docs.
---

# DevIsland Release Packaging

Use this when preparing, reviewing, or automating a DevIsland release. Pair with `devisland-change-verification`.

## Start

Read:

- `AGENTS.md`
- `CHANGELOG.md`
- `CONTRIBUTING.md`
- `docs/agent/build-and-test.md`
- `.github/workflows/release.yml`
- `.github/workflows/bump.yml`
- `scripts/create-dmg.sh`
- `scripts/extract-release-notes.sh`

Check current version values:

```bash
rg -n "CFBundleShortVersionString|CFBundleVersion" project.yml
git tag --list 'v*' --sort=-version:refname | head
```

## Changelog

For every user-visible release, update `CHANGELOG.md` before tagging or creating a release.

Keep entries useful for users:

- Start with `## vX.Y.Z - YYYY-MM-DD`.
- Add a short Korean summary paragraph.
- Group bullets by meaningful headings such as highlights, approval/hooks, UI/UX, stability, internal/CI.
- Include a `Full Changelog` compare link from the previous tag to the new tag.

Do not rely only on generated GitHub release notes when curated release notes are expected.

## Release Notes Source

Use the relevant `CHANGELOG.md` section as the source of truth for GitHub Release body text.

When creating or updating the GitHub release manually, fill the release body from that section. The release workflow extracts the matching changelog section with `scripts/extract-release-notes.sh` and passes it as `body_path`; preserve that behavior when changing automation.

If a package or release artifact is created locally for handoff, include the same changelog-derived notes in the handoff or release draft.

## Packaging

The release workflow is `workflow_dispatch` based, checks out the requested tag, supports dry-run builds, builds on macOS, and runs:

```bash
./scripts/create-dmg.sh
```

The DMG name comes from `project.yml` as `DevIsland-VERSION-arm64.dmg`. `scripts/create-dmg.sh` runs `xcodegen generate`, archives with `xcodebuild`, extracts the app, clears extended attributes, and creates the DMG with `create-dmg`.

Do not hand-edit generated `.xcodeproj`; change `project.yml`.

## Version And Tag Flow

The bump workflow reacts to `vX.Y.Z` tags, updates `project.yml`, commits the bump, retags, and triggers release. Verify this behavior before changing version automation.

Before tagging:

- Ensure `CHANGELOG.md` has the target version.
- Ensure `project.yml` version flow is understood.
- Run the repo's required tests or explain why a release-only change skipped them.

## Checks

For release automation changes, inspect workflow syntax and run local checks where feasible:

```bash
./scripts/run-tests.sh
./scripts/build_and_run.sh --no-kill --no-run
```

For packaging changes, run or document why local DMG creation was not run. Local packaging may require Xcode.app, `xcodegen`, and `create-dmg`.
