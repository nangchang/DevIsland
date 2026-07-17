# Build And Test

DevIsland uses XcodeGen. There is no committed `.xcodeproj`.

## Standard Workflow

```bash
# One-time setup
brew install xcodegen xcode-build-server swiftlint

# Generate the Xcode project
xcodegen generate

# Configure SourceKit-LSP (eliminates false-positive cross-file errors in editors/AI tools)
# buildServer.json is gitignored — run once per machine, re-run after DerivedData clean
xcode-build-server config -scheme DevIsland -project DevIsland.xcodeproj

# Open in Xcode
open DevIsland.xcodeproj

# Lint Swift sources
swiftlint lint --no-cache

# Run unit tests, recommended
./scripts/run-tests.sh

# Run unit tests via standard CLI
xcodebuild test -project DevIsland.xcodeproj -scheme DevIsland -destination 'platform=macOS'
```

Build target: macOS 15.0+, Xcode 16+.

AI agents must run `swiftlint lint --no-cache` before committing Swift source changes and the existing unit tests before committing any code changes. Run lint before tests when both apply so structural regressions fail early. Prefer `./scripts/run-tests.sh` because it uses isolated mode and will not interfere with a running DevIsland instance.

The repository `.swiftlint.yml` is a structural gate for Swift sources. It enforces limits such as file length, type body length, and function parameter count; keep these checks passing instead of bypassing them for new code.

## Quick Build

For environments without Xcode project workflows, use:

```bash
# Full rebuild and launch
./scripts/build_and_run.sh

# Build only, without killing or launching the app
./scripts/build_and_run.sh --no-kill --no-run
```

The script runs `xcodegen generate` then `xcodebuild build`, copies the Debug result to `dist/DevIsland Dev.app`, and can launch it. Pass `--verify` to assert the process started.

Release builds are produced by CI on version tags. The release workflow runs `xcodebuild archive` unsigned and packages a DMG via `hdiutil`.
