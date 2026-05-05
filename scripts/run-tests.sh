#!/usr/bin/env bash
# scripts/run-tests.sh
# 
# Runs unit tests for DevIsland in an isolated environment.
# This script ensures that running tests does not interfere with a live DevIsland process
# by using a separate DerivedData directory and signaling to the app to disable side effects.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DERIVED_DATA="/tmp/DevIsland-Test-DerivedData"

echo "🏝️  Running DevIsland Unit Tests (Isolated Mode)..."

cd "$ROOT_DIR"

# 1. Ensure project is generated
xcodegen generate

# 2. Run tests with xcodebuild
# - Use a temporary derived data path to avoid locking files used by Xcode or the live app.
# - The XcodeGen test scheme passes XCODE_RUNNING_UNIT_TESTS=1 to disable socket server and hotkeys.
# - Use -quiet to keep output clean, only showing results/errors.

echo "⏳ Building and testing..."

xcodebuild test \
    -project DevIsland.xcodeproj \
    -scheme DevIsland \
    -destination 'platform=macOS' \
    -derivedDataPath "$TEMP_DERIVED_DATA" \
    -quiet

echo "✅ All tests passed!"
