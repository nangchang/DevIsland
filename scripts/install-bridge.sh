#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
BRIDGE_DEST="$HOOKS_DIR/devisland-bridge.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

# Find bridge script: prefer sibling in source tree, fall back to app bundle
BRIDGE_SRC="$SCRIPT_DIR/devisland-bridge.sh"
if [ ! -f "$BRIDGE_SRC" ]; then
    BUNDLE_SRC="/Applications/DevIsland.app/Contents/Resources/devisland-bridge.sh"
    if [ -f "$BUNDLE_SRC" ]; then
        BRIDGE_SRC="$BUNDLE_SRC"
    else
        echo "오류: devisland-bridge.sh 를 찾을 수 없습니다."
        echo "DevIsland.app 이 /Applications 에 설치되어 있는지 확인해주세요."
        exit 1
    fi
fi

echo "DevIsland 브리지 스크립트 설치 중..."
mkdir -p "$HOOKS_DIR"

# Symlink when running from source; copy when running from app bundle
if [[ "$SCRIPT_DIR" == *.app/Contents/Resources* ]]; then
    cp "$BRIDGE_SRC" "$BRIDGE_DEST"
    echo "✓ 브리지 스크립트 복사 완료: $BRIDGE_DEST"
else
    ln -sf "$BRIDGE_SRC" "$BRIDGE_DEST"
    echo "✓ 브리지 스크립트 링크 생성: $BRIDGE_DEST"
fi
chmod +x "$BRIDGE_DEST"

# Create minimal settings.json if it doesn't exist
if [ ! -f "$SETTINGS_FILE" ]; then
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
    echo "✓ Created $SETTINGS_FILE"
fi

cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"
echo "✓ Settings backup created: ${SETTINGS_FILE}.bak"

python3 - "$SETTINGS_FILE" "$BRIDGE_DEST" << 'EOF'
import json, sys

path, bridge_path = sys.argv[1], sys.argv[2]

with open(path) as f:
    data = json.load(f)

data.setdefault('hooks', {})

hook_config = {
    "matcher": ".*",
    "hooks": [{"type": "command", "command": bridge_path, "timeout": 86400}]
}
notif_config = {
    "hooks": [{"type": "command", "command": bridge_path}]
}

for key, config in [
    ('SessionStart', notif_config), ('Stop', notif_config),
    ('PostToolUse', notif_config), ('Notification', notif_config),
    ('PermissionRequest', hook_config), ('PreToolUse', hook_config),
]:
    data['hooks'].setdefault(key, [])
    if not any(bridge_path in json.dumps(h) for h in data['hooks'][key]):
        data['hooks'][key].append(config)

with open(path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
EOF

echo "✓ Claude Code settings updated."
echo ""
echo "설치 완료! Claude Code 세션을 재시작해주세요."
