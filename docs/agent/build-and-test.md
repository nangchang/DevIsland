# Build And Test

DevIsland uses XcodeGen. There is no committed `.xcodeproj`.

## Standard Workflow

```bash
# One-time setup
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open DevIsland.xcodeproj

# Run unit tests, recommended
./scripts/run-tests.sh

# Run unit tests via standard CLI
xcodebuild test -project DevIsland.xcodeproj -scheme DevIsland -destination 'platform=macOS'
```

Build target: macOS 14.0+, Xcode 15+.

AI agents must run the existing unit tests before committing code changes. Prefer `./scripts/run-tests.sh` because it uses isolated mode and will not interfere with a running DevIsland instance.

## Quick Build

For environments without Xcode project workflows, use:

```bash
# Full rebuild and launch
./scripts/build_and_run.sh

# Build only, without killing or launching the app
./scripts/build_and_run.sh --no-kill --no-run
```

The script compiles all Swift sources under `DevIsland/`, assembles `dist/DevIsland.app`, and can launch it. Pass `--verify` to assert the process started.

Release builds are produced by CI on version tags. The release workflow runs `xcodebuild archive` unsigned and packages a DMG via `hdiutil`.
