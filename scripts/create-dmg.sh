#!/usr/bin/env bash
set -euo pipefail

APP_NAME="DevIsland"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
EXPORT_DIR="$BUILD_DIR/Export"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"

VERSION="$(grep 'CFBundleShortVersionString:' "$ROOT_DIR/project.yml" | sed -E 's/.*: "(.*)"/\1/')"
ARCH="arm64"
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH}"
DMG_PATH="$ROOT_DIR/${DMG_NAME}.dmg"

cd "$ROOT_DIR"

# xcodebuild은 Command Line Tools가 아닌 Xcode.app이 필요함
XCODE_PATH="$(xcode-select -p 2>/dev/null || true)"
if [[ "$XCODE_PATH" != */Xcode*.app/* ]]; then
  XCODE_APP="$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' 2>/dev/null | head -1)"
  if [[ -z "$XCODE_APP" ]]; then
    echo "오류: Xcode.app이 설치되어 있지 않습니다." >&2
    echo "App Store에서 Xcode를 설치한 후 다시 실행하세요." >&2
    exit 1
  fi
  echo "Xcode 개발자 디렉토리로 전환합니다: $XCODE_APP"
  sudo xcode-select -s "$XCODE_APP/Contents/Developer"
fi

if ! command -v xcodegen &>/dev/null; then
  echo "오류: xcodegen이 설치되어 있지 않습니다. 'brew install xcodegen'로 설치해주세요." >&2
  exit 1
fi

if ! command -v create-dmg &>/dev/null; then
  echo "오류: create-dmg가 설치되어 있지 않습니다. 'brew install create-dmg'로 설치해주세요." >&2
  exit 1
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
  ARCHS=arm64
  CODE_SIGN_IDENTITY="-"
  CODE_SIGNING_REQUIRED=YES
  CODE_SIGNING_ALLOWED=YES
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

echo "Cleaning extended attributes..."
xattr -cr "$EXPORT_DIR/$APP_NAME.app"

# resources/scripts는 project.yml에 이미 resource로 등록되어 있어 xcodebuild가 처리함
# 중복 복사 제거

echo "DMG 생성 중 (create-dmg 사용)..."
rm -f "$DMG_PATH" "$ROOT_DIR"/rw.*."${DMG_NAME}.dmg"

# Resources/DMG/dmg_background.png 를 배경으로 사용
CREATE_DMG_OPTIONS=(
  --volname "$APP_NAME"
  --background "$ROOT_DIR/Resources/DMG/dmg_background.png"
  --window-pos 200 120
  --window-size 600 400
  --icon-size 120
  --icon "$APP_NAME.app" 150 200
  --hide-extension "$APP_NAME.app"
  --app-drop-link 450 200
  --no-internet-enable
)

run_create_dmg() {
  create-dmg \
    "${CREATE_DMG_OPTIONS[@]}" \
    "$@" \
    "$DMG_PATH" \
    "$EXPORT_DIR/"
}

if run_create_dmg; then
  :
else
  create_dmg_status=$?
  # create-dmg 1.2.3 uses exit 64 when its Finder AppleScript fails.
  if [[ "$create_dmg_status" -ne 64 ]]; then
    echo "오류: create-dmg가 실패했습니다(종료 코드: ${create_dmg_status}). 자동 재시도를 건너뜁니다." >&2
    exit "$create_dmg_status"
  fi

  echo "경고: Finder DMG 레이아웃 생성에 실패했습니다." >&2
  echo "경고: Finder 자동화를 건너뛴 기본 레이아웃으로 다시 시도합니다." >&2
  rm -f "$DMG_PATH" "$ROOT_DIR"/rw.*."${DMG_NAME}.dmg"
  run_create_dmg --skip-jenkins
fi

echo "DMG 무결성 확인 중..."
hdiutil verify "$DMG_PATH"

echo ""
echo "완료: $DMG_PATH"
