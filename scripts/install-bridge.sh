#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -------------------------------------------------------------------
# 브리지 스크립트 위치 확인
# -------------------------------------------------------------------
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

# -------------------------------------------------------------------
# 설치 대상 선택 (기본: --all)
# -------------------------------------------------------------------
INSTALL_CLAUDE=false
INSTALL_CODEX=false
INSTALL_GEMINI=false

for arg in "$@"; do
    case "$arg" in
        --claude) INSTALL_CLAUDE=true ;;
        --codex)  INSTALL_CODEX=true  ;;
        --gemini) INSTALL_GEMINI=true ;;
        --all)    INSTALL_CLAUDE=true; INSTALL_CODEX=true; INSTALL_GEMINI=true ;;
    esac
done

# 아무 플래그도 없으면 전부 설치
if ! $INSTALL_CLAUDE && ! $INSTALL_CODEX && ! $INSTALL_GEMINI; then
    INSTALL_CLAUDE=true
    INSTALL_CODEX=true
    INSTALL_GEMINI=true
fi

echo "DevIsland 브리지 스크립트 설치 중..."

# -------------------------------------------------------------------
# 브리지 스크립트를 ~/.claude/hooks/ 에 배치 (공유)
# -------------------------------------------------------------------
HOOKS_DIR="$HOME/.claude/hooks"
BRIDGE_DEST="$HOOKS_DIR/devisland-bridge.sh"

mkdir -p "$HOOKS_DIR"
rm -f "$BRIDGE_DEST"
if [[ "$SCRIPT_DIR" == *.app/Contents/Resources* ]]; then
    cp "$BRIDGE_SRC" "$BRIDGE_DEST"
    echo "✓ 브리지 스크립트 복사 완료: $BRIDGE_DEST"
else
    ln -sf "$BRIDGE_SRC" "$BRIDGE_DEST"
    echo "✓ 브리지 스크립트 링크 생성: $BRIDGE_DEST"
fi
chmod +x "$BRIDGE_DEST"

# -------------------------------------------------------------------
# Claude Code 설치
# -------------------------------------------------------------------
if $INSTALL_CLAUDE; then
    SETTINGS_FILE="$HOME/.claude/settings.json"

    if [ ! -f "$SETTINGS_FILE" ]; then
        mkdir -p "$(dirname "$SETTINGS_FILE")"
        echo '{}' > "$SETTINGS_FILE"
        echo "✓ Created $SETTINGS_FILE"
    fi

    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"
    echo "✓ Claude Code settings backup: ${SETTINGS_FILE}.bak"

    python3 - "$SETTINGS_FILE" "$BRIDGE_DEST" << 'EOF'
import json, sys

path, bridge_path = sys.argv[1], sys.argv[2]
bridge_command = f"{bridge_path} --source claude"

with open(path) as f:
    data = json.load(f)

data.setdefault('hooks', {})

approval_config  = {"hooks": [{"type": "command", "command": bridge_command, "timeout": 86400}]}
lifecycle_config = {"hooks": [{"type": "command", "command": bridge_command}]}

def remove_bridge_hooks(entries):
    cleaned = []
    for entry in entries:
        sub_hooks = [h for h in entry.get("hooks", []) if bridge_path not in h.get("command", "")]
        if sub_hooks:
            updated = dict(entry)
            updated["hooks"] = sub_hooks
            cleaned.append(updated)
    return cleaned

for key, config in [
    ('SessionStart',      lifecycle_config),
    ('SessionEnd',        lifecycle_config),
    ('Notification',      lifecycle_config),
    ('Stop',              lifecycle_config),
    ('PermissionRequest', approval_config),
]:
    data['hooks'].setdefault(key, [])
    data['hooks'][key] = remove_bridge_hooks(data['hooks'][key])
    data['hooks'][key].append(config)

for key in ['SubagentStop', 'PreToolUse', 'PostToolUse', 'PreCompact', 'StopFailure']:
    entries = remove_bridge_hooks(data['hooks'].get(key, []))
    if entries:
        data['hooks'][key] = entries
    else:
        data['hooks'].pop(key, None)

with open(path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
EOF

    echo "✓ Claude Code 훅 등록 완료."
fi

# -------------------------------------------------------------------
# Codex CLI 설치  (~/.codex/hooks.json + config.toml)
# -------------------------------------------------------------------
if $INSTALL_CODEX; then
    CODEX_CONFIG="$HOME/.codex/config.toml"
    CODEX_HOOKS="$HOME/.codex/hooks.json"
    mkdir -p "$(dirname "$CODEX_HOOKS")"

    echo "✓ Codex CLI 훅 등록 중 (~/.codex/hooks.json)..."
    
    python3 - "$CODEX_HOOKS" "$BRIDGE_DEST" << 'EOF'
import json, sys, os

path, bridge_path = sys.argv[1], sys.argv[2]
bridge_command = f"{bridge_path} --source codex"

data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        pass

data.setdefault('hooks', {})

# 공식 JSON 규격: {"EventName": [{"matcher": "*", "hooks": [{"type": "command", "command": "..."}]}]}
events = ["SessionStart", "SessionEnd", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop"]
for event in events:
    event_configs = data['hooks'].get(event, [])
    if not isinstance(event_configs, list):
        event_configs = []
    
    found = False
    for config in event_configs:
        if config.get("matcher") == "*":
            sub_hooks = config.get("hooks", [])
            sub_hooks = [h for h in sub_hooks if bridge_path not in h.get("command", "")]
            sub_hooks.append({"type": "command", "command": bridge_command})
            config["hooks"] = sub_hooks
            found = True
            break
    
    if not found:
        event_configs.append({
            "matcher": "*",
            "hooks": [{"type": "command", "command": bridge_command}]
        })
    
    data['hooks'][event] = event_configs

with open(path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
EOF

    # config.toml에서 features 활성화 및 구형 [[hooks]] 제거
    echo "✓ Codex CLI config.toml 패치 중 (Features 활성화 및 정리)..."
    python3 - "$CODEX_CONFIG" "$BRIDGE_DEST" << 'EOF'
import sys, os

path, bridge_path = sys.argv[1], sys.argv[2]

lines = []
if os.path.exists(path):
    with open(path, 'r') as f:
        lines = f.readlines()

new_lines = []
skip = False
for line in lines:
    strip_line = line.strip()
    # 구형 [[hooks.]] 또는 [hooks] 섹션 제거 (hooks.json으로 일원화)
    if strip_line.startswith('[hooks]') or strip_line.startswith('[[hooks.'):
        skip = True
        continue
    if skip and strip_line.startswith('[') and not strip_line.startswith('[[hooks.'):
        skip = False
    if not skip:
        new_lines.append(line)

# features 확인 및 활성화
if not any('codex_hooks' in l for l in new_lines):
    if new_lines and not new_lines[-1].endswith('\n'):
        new_lines.append('\n')
    new_lines.append('\n[features]\ncodex_hooks = true\n')

with open(path, 'w') as f:
    f.writelines(new_lines)
EOF

    echo "✓ Codex CLI 설치 완료."
fi

# -------------------------------------------------------------------
# Gemini CLI 설치  (~/.gemini/settings.json)
# -------------------------------------------------------------------
if $INSTALL_GEMINI; then
    GEMINI_SETTINGS="$HOME/.gemini/settings.json"
    mkdir -p "$(dirname "$GEMINI_SETTINGS")"

    python3 - "$GEMINI_SETTINGS" "$BRIDGE_DEST" << 'EOF'
import json, sys, os

path, bridge_path = sys.argv[1], sys.argv[2]
bridge_command = f"{bridge_path} --source gemini"

data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        pass

hooks = data.get('hooks', {})
if not isinstance(hooks, dict):
    hooks = {}

for event in ["BeforeTool", "SessionStart", "SessionEnd"]:
    event_configs = hooks.get(event, [])
    if not isinstance(event_configs, list):
        event_configs = []
    
    found = False
    for config in event_configs:
        if config.get("matcher") == "*":
            sub_hooks = config.get("hooks", [])
            sub_hooks = [h for h in sub_hooks if bridge_path not in h.get("command", "")]
            sub_hooks.append({"type": "command", "command": bridge_command})
            config["hooks"] = sub_hooks
            found = True
            break
    
    if not found:
        event_configs.append({
            "matcher": "*",
            "hooks": [{"type": "command", "command": bridge_command}]
        })
    
    hooks[event] = event_configs

data['hooks'] = hooks

with open(path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
EOF

    echo "✓ Gemini CLI 훅 등록 완료: $GEMINI_SETTINGS"
fi

echo ""
echo "설치 완료!"
if $INSTALL_CLAUDE; then echo "  • Claude Code: ~/.claude/settings.json"; fi
if $INSTALL_CODEX;  then echo "  • Codex CLI:   ~/.codex/hooks.json 및 config.toml"; fi
if $INSTALL_GEMINI; then echo "  • Gemini CLI:  ~/.gemini/settings.json"; fi
echo ""
echo "각 CLI 세션을 재시작해주세요."
