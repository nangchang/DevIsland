#!/usr/bin/env bash
set -euo pipefail

SCHEME_NAME="DevIsland"
APP_NAME="DevIsland Dev"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
DIST_APP="$DIST_DIR/$APP_NAME.app"

cd "$ROOT_DIR"

NO_KILL=false
NO_RUN=false
VERIFY=false
for arg in "$@"; do
  if [[ "$arg" == "--no-kill" ]]; then NO_KILL=true; fi
  if [[ "$arg" == "--no-run" ]]; then NO_RUN=true; fi
  if [[ "$arg" == "--verify" ]]; then VERIFY=true; fi
done

if [[ "$NO_KILL" == "false" ]]; then
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME" || true
    sleep 0.3
  fi
fi

# project.yml → .xcodeproj 동기화
echo "Generating Xcode project..."
xcodegen generate --quiet

# xcodebuild: SPM 패키지 해소 + 컴파일 + 번들 조립 모두 처리
echo "Building $SCHEME_NAME..."
xcodebuild build \
  -scheme "$SCHEME_NAME" \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  -configuration Debug \
  -quiet

# dist/ 에 복사 (기존 동작과 동일하게 유지)
mkdir -p "$DIST_DIR"
rm -rf "$DIST_APP"
cp -R "$APP_BUNDLE" "$DIST_APP"

echo "Ad-hoc signing..."
xattr -cr "$DIST_APP"
codesign -s - --force --deep --arch arm64 "$DIST_APP"

if [[ "$NO_RUN" == "false" ]]; then
  /usr/bin/open -n "$DIST_APP"
  if [[ "$VERIFY" == "true" ]]; then
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME launched"
  fi
else
  echo "Build complete. App not launched due to --no-run."
fi

# 브릿지가 이미 설치되어 있으면 빌드 결과물로 즉시 갱신
BRIDGE_INSTALL_DIR="$HOME/Library/Application Support/DevIsland"
BRIDGE_DEST="$BRIDGE_INSTALL_DIR/devisland-bridge.sh"
HELPER_DEST="$BRIDGE_INSTALL_DIR/devisland_bridge.py"
BRIDGE_SOURCE="$ROOT_DIR/scripts/devisland-bridge.sh"
HELPER_SOURCE="$ROOT_DIR/scripts/devisland_bridge.py"
if [[ -e "$BRIDGE_DEST" ]]; then
  if ! cmp -s "$BRIDGE_SOURCE" "$BRIDGE_DEST"; then
    cp "$BRIDGE_SOURCE" "$BRIDGE_DEST"
  fi
  if ! cmp -s "$HELPER_SOURCE" "$HELPER_DEST"; then
    cp "$HELPER_SOURCE" "$HELPER_DEST"
  fi
  chmod 755 "$BRIDGE_DEST" "$HELPER_DEST"
  echo "브릿지 스크립트 갱신 완료: $BRIDGE_DEST"
fi
