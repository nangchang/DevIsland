#!/bin/bash
set -e

BRIDGE_SRC="/Volumes/data/Github/DevIsland/scripts/devisland-bridge.sh"
HOOKS_DIR="$HOME/.claude/hooks"
BRIDGE_DEST="$HOOKS_DIR/devisland-bridge.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"
SCRIPT_DIR="/Volumes/data/Github/DevIsland/scripts"

echo "Linking DevIsland bridge script..."

# Create hooks directory if not exists
mkdir -p "$HOOKS_DIR"

# Link bridge script
ln -sf "$SCRIPT_DIR/devisland-bridge.sh" "$BRIDGE_DEST"
chmod +x "$BRIDGE_DEST"
chmod +x "$SCRIPT_DIR/devisland-bridge.sh"

echo "✓ Bridge script linked to: $BRIDGE_DEST"

# Backup settings
if [ -f "$SETTINGS_FILE" ]; then
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"
    echo "✓ Settings backup created: ${SETTINGS_FILE}.bak"
    
    # Update settings.json using python for robust JSON manipulation
    python3 - << EOF
import json
import os

path = os.path.expanduser("$SETTINGS_FILE")
bridge_path = os.path.expanduser("$BRIDGE_DEST")

with open(path, 'r') as f:
    data = json.load(f)

if 'hooks' not in data:
    data['hooks'] = {}

hook_config = {
    "matcher": ".*",
    "hooks": [
        {
            "type": "command",
            "command": bridge_path,
            "timeout": 86400
        }
    ]
}

# Notification style hooks (no matcher needed)
notif_config = {
    "hooks": [
        {
            "type": "command",
            "command": bridge_path
        }
    ]
}

data['hooks']['SessionStart'] = [notif_config]
data['hooks']['Stop'] = [notif_config]
data['hooks']['PermissionRequest'] = [hook_config]
data['hooks']['PreToolUse'] = [hook_config]

with open(path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
EOF
    echo "✓ Claude Code settings updated."
else
    echo "⚠ Claude Code settings file not found at $SETTINGS_FILE"
fi

echo ""
echo "Installation complete! Please restart your Claude Code sessions."
