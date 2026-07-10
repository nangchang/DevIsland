#!/usr/bin/env bash
# scripts/run-tests.sh
# 
# Runs unit tests for DevIsland in an isolated environment.
# This script ensures that running tests does not interfere with a live DevIsland process
# by using a separate DerivedData directory and signaling to the app to disable side effects.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DERIVED_DATA="/tmp/DevIsland-Test-DerivedData"
HOST_ARCH="$(uname -m)"

echo "🏝️  Running DevIsland Unit Tests (Isolated Mode)..."

cd "$ROOT_DIR"

export PYTHONDONTWRITEBYTECODE=1

echo "Running bridge script tests..."
python3 scripts/test_devisland_bridge.py
python3 scripts/test_devisland_bridge_shell.py
python3 scripts/test_install_hooks.py

# 1. Ensure project is generated
xcodegen generate

# 2. Run tests with xcodebuild
# - Use a temporary derived data path to avoid locking files used by Xcode or the live app.
# - The XcodeGen test scheme passes XCODE_RUNNING_UNIT_TESTS=1 to disable socket server and hotkeys.
# - Use the host architecture to avoid xcodebuild's duplicate macOS destination warning.
# - Filter Xcode/CoreSimulator version-mismatch noise. This project only runs macOS tests,
#   but recent Xcode versions still probe CoreSimulator while resolving destinations.

echo "⏳ Building and testing..."

xcodebuild test \
    -project DevIsland.xcodeproj \
    -scheme DevIsland \
    -destination "platform=macOS,arch=${HOST_ARCH}" \
    -derivedDataPath "$TEMP_DERIVED_DATA" \
    -quiet 2>&1 | awk '
        /DVTErrorPresenter: Unable to load simulator devices\./ { skip = 1; next }
        skip && /^--$/ { skipDashCount += 1; if (skipDashCount >= 2) { skip = 0; skipDashCount = 0 }; next }
        skip { next }
        /iOSSimulator: .*CoreSimulator is out of date/ { next }
        /CoreSimulator is out of date\./ { next }
        { print }
    '

echo "✅ All tests passed!"
