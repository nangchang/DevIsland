# Build And Test

DevIsland uses XcodeGen. There is no committed `.xcodeproj`.

## Standard Workflow

```bash
# One-time setup
brew install xcodegen xcode-build-server

# Generate the Xcode project
xcodegen generate

# Configure SourceKit-LSP (eliminates false-positive cross-file errors in editors/AI tools)
# buildServer.json is gitignored — run once per machine, re-run after DerivedData clean
xcode-build-server config -scheme DevIsland -project DevIsland.xcodeproj

# Open in Xcode
open DevIsland.xcodeproj

# Run unit tests, recommended
./scripts/run-tests.sh

# Run unit tests via standard CLI
xcodebuild test -project DevIsland.xcodeproj -scheme DevIsland -destination 'platform=macOS'
```

Build target: macOS 15.0+, Xcode 16+.

AI agents must run the existing unit tests before committing code changes. Prefer `./scripts/run-tests.sh` because it uses isolated mode and will not interfere with a running DevIsland instance.

## Quick Build

For environments without Xcode project workflows, use:

```bash
# Full rebuild and launch
./scripts/build_and_run.sh

# Build only, without killing or launching the app
./scripts/build_and_run.sh --no-kill --no-run
```

The script runs `xcodegen generate` then `xcodebuild build`, copies the result to `dist/DevIsland.app`, and can launch it. Pass `--verify` to assert the process started.

Release builds are produced by CI on version tags. The release workflow runs `xcodebuild archive` unsigned and packages a DMG via `hdiutil`.
