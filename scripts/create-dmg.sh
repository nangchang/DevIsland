#!/usr/bin/env bash
set -euo pipefail

APP_NAME="DevIsland"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
EXPORT_DIR="$BUILD_DIR/Export"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
DMG_PATH="$ROOT_DIR/$APP_NAME.dmg"

cd "$ROOT_DIR"

# xcodebuild은 Command Line Tools가 아닌 Xcode.app이 필요함
XCODE_PATH="$(xcode-select -p 2>/dev/null || true)"
if [[ "$XCODE_PATH" != */Xcode*.app/* ]]; then
  XCODE_APP="$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' 2>/dev/null | head -1)"
  if [[ -z "$XCODE_APP" ]]; then
    echo "오류: Xcode.app이 설치되어 있지 않습니다."
    echo "App Store에서 Xcode를 설치한 후 다시 실행하세요."
    exit 1
  fi
  echo "Xcode 개발자 디렉토리로 전환합니다: $XCODE_APP"
  sudo xcode-select -s "$XCODE_APP/Contents/Developer"
fi

if ! command -v xcodegen &>/dev/null; then
  echo "XcodeGen이 없습니다. Homebrew로 설치합니다..."
  brew install xcodegen
fi

echo "Xcode 프로젝트 생성 중..."
xcodegen generate

echo "아카이브 빌드 중..."
BUILD_CMD=(
  xcodebuild archive
  -project "$APP_NAME.xcodeproj"
  -scheme "$APP_NAME"
  -configuration Release
  -archivePath "$ARCHIVE_PATH"
  -destination "platform=macOS"
  CODE_SIGN_IDENTITY=""
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
  SKIP_INSTALL=NO
)
if command -v xcpretty &>/dev/null; then
  "${BUILD_CMD[@]}" | xcpretty
else
  "${BUILD_CMD[@]}"
fi

echo "앱 추출 중..."
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_DIR/"

RESOURCES_DIR="$EXPORT_DIR/$APP_NAME.app/Contents/Resources"
mkdir -p "$RESOURCES_DIR"
cp "$ROOT_DIR/scripts/devisland-bridge.sh" "$RESOURCES_DIR/"
cp "$ROOT_DIR/scripts/install-bridge.sh" "$RESOURCES_DIR/"

echo "DMG 생성 중..."
rm -f "$DMG_PATH"
ln -sf /Applications "$EXPORT_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$EXPORT_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -f "$EXPORT_DIR/Applications"

echo ""
echo "완료: $DMG_PATH"
