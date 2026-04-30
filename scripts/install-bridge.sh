#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
BRIDGE_DEST="$HOOKS_DIR/devisland-bridge.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "Linking DevIsland bridge script..."

mkdir -p "$HOOKS_DIR"

ln -sf "$SCRIPT_DIR/devisland-bridge.sh" "$BRIDGE_DEST"
chmod +x "$BRIDGE_DEST"
chmod +x "$SCRIPT_DIR/devisland-bridge.sh"

echo "✓ Bridge script linked to: $BRIDGE_DEST"

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

data['hooks']['SessionStart'] = [notif_config]
data['hooks']['Stop'] = [notif_config]
data['hooks']['PermissionRequest'] = [hook_config]
data['hooks']['PreToolUse'] = [hook_config]

with open(path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
EOF

echo "✓ Claude Code settings updated."
echo ""
echo "Installation complete! Please restart your Claude Code sessions."
