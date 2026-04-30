#!/usr/bin/env bash
set -euo pipefail

APP_NAME="DevIsland"
BUNDLE_ID="com.hoin.DevIsland"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
EXECUTABLE="$MACOS_DIR/$APP_NAME"

cd "$ROOT_DIR"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME" || true
  sleep 0.3
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc \
  DevIsland/*.swift \
  -target "$(uname -m)-apple-macos14.0" \
  -o "$EXECUTABLE"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAccessibilityUsageDescription</key>
  <string>Global shortcuts require accessibility permission.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>DevIsland focuses Terminal after approve or deny actions.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

chmod +x "$EXECUTABLE"
/usr/bin/open -n "$APP_BUNDLE"

if [[ "${1:-}" == "--verify" ]]; then
  sleep 1
  pgrep -x "$APP_NAME" >/dev/null
  echo "$APP_NAME launched"
fi
