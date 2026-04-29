#!/bin/bash
set -e

PLIST_LABEL="kr.or.nes.DevIsland"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"
APP_BINARY="/Applications/DevIsland.app/Contents/MacOS/DevIsland"

if [ ! -f "$APP_BINARY" ]; then
    echo "오류: $APP_BINARY 를 찾을 수 없습니다."
    echo "Xcode에서 빌드 후 /Applications 에 복사해주세요."
    exit 1
fi

mkdir -p "$LAUNCH_AGENTS_DIR"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_BINARY}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/DevIsland.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/DevIsland.error.log</string>
</dict>
</plist>
EOF

# 기존에 로드된 경우 언로드 후 재등록
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "✓ LaunchAgent 등록 완료: $PLIST_PATH"
echo "  로그인 시 DevIsland가 자동으로 시작됩니다."
echo ""
echo "제거하려면:"
echo "  launchctl unload $PLIST_PATH && rm $PLIST_PATH"
