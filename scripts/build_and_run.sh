#!/usr/bin/env bash
set -euo pipefail

APP_NAME="DevIsland"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
EXECUTABLE="$MACOS_DIR/$APP_NAME"

cd "$ROOT_DIR"

NO_KILL=false
NO_RUN=false
for arg in "$@"; do
  if [[ "$arg" == "--no-kill" ]]; then NO_KILL=true; fi
  if [[ "$arg" == "--no-run" ]]; then NO_RUN=true; fi
done

if [[ "$NO_KILL" == "false" ]]; then
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME" || true
    sleep 0.3
  fi
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/scripts/devisland-bridge.sh" "$RESOURCES_DIR/"
cp "$ROOT_DIR/scripts/devisland_bridge.py" "$RESOURCES_DIR/"
cp "$ROOT_DIR/scripts/install-bridge.sh" "$RESOURCES_DIR/"

# Compile assets
echo "Compiling assets..."
xcrun actool "$ROOT_DIR/DevIsland/Assets.xcassets" \
  --compile "$RESOURCES_DIR" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$DIST_DIR/Assets-Partial.plist"
rm "$DIST_DIR/Assets-Partial.plist" # Clean up unused partial plist

# Compile Swift sources
swiftc \
  DevIsland/*.swift \
  -target "$(uname -m)-apple-macos14.0" \
  -o "$EXECUTABLE"

# Extract metadata from project.yml (robustly handle missing keys or missing quotes)
VERSION=$(grep "CFBundleShortVersionString:" "$ROOT_DIR/project.yml" | head -n 1 | sed -E 's/.*: +"([^"]+)".*/\1/' | sed -E 's/.*: +([^ ]+).*/\1/' | head -n 1)
BUILD=$(grep "CFBundleVersion:" "$ROOT_DIR/project.yml" | head -n 1 | sed -E 's/.*: +"([^"]+)".*/\1/' | sed -E 's/.*: +([^ ]+).*/\1/' | head -n 1)
BUNDLE_ID_PREFIX=$(grep "bundleIdPrefix:" "$ROOT_DIR/project.yml" | head -n 1 | sed -E 's/.*: +"?([^"]+)"?/\1/' | head -n 1)
BUNDLE_ID="${BUNDLE_ID_PREFIX:-com.hoin}.${APP_NAME}"

if [[ -z "$VERSION" ]]; then VERSION="1.0.0"; fi
if [[ -z "$BUILD" ]]; then BUILD="1"; fi

echo "Building $APP_NAME $VERSION ($BUILD) with ID $BUNDLE_ID..."

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
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
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

echo "Ad-hoc signing..."
xattr -cr "$APP_BUNDLE"
codesign -s - --force --deep --arch arm64 "$APP_BUNDLE"

if [[ "$NO_RUN" == "false" ]]; then
  /usr/bin/open -n "$APP_BUNDLE"
  if [[ "${1:-}" == "--verify" ]]; then
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME launched"
  fi
else
  echo "Build complete. App not launched due to --no-run."
fi
