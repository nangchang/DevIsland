#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -------------------------------------------------------------------
# 브리지 스크립트 위치 확인
# -------------------------------------------------------------------
BRIDGE_SRC="$SCRIPT_DIR/devisland-bridge.sh"
PY_BRIDGE_SRC="$SCRIPT_DIR/devisland_bridge.py"
MANIFEST_SRC="$SCRIPT_DIR/hook_events.json"
if [ ! -f "$BRIDGE_SRC" ]; then
    BUNDLE_SRC="/Applications/DevIsland.app/Contents/Resources/devisland-bridge.sh"
    if [ -f "$BUNDLE_SRC" ]; then
        BRIDGE_SRC="$BUNDLE_SRC"
        PY_BRIDGE_SRC="/Applications/DevIsland.app/Contents/Resources/devisland_bridge.py"
        MANIFEST_SRC="/Applications/DevIsland.app/Contents/Resources/hook_events.json"
    else
        echo "오류: devisland-bridge.sh 를 찾을 수 없습니다."
        echo "DevIsland.app 이 /Applications 에 설치되어 있는지 확인해주세요."
        exit 1
    fi
fi
if [ ! -f "$PY_BRIDGE_SRC" ]; then
    echo "오류: devisland_bridge.py 를 찾을 수 없습니다."
    echo "DevIsland.app 이 /Applications 에 설치되어 있는지 확인해주세요."
    exit 1
fi
if [ ! -f "$MANIFEST_SRC" ]; then
    echo "오류: hook_events.json 를 찾을 수 없습니다."
    echo "DevIsland.app 이 /Applications 에 설치되어 있는지 확인해주세요."
    exit 1
fi

# -------------------------------------------------------------------
# 설치 대상 선택 (기본: --all)
# -------------------------------------------------------------------
INSTALL_CLAUDE=false
INSTALL_CODEX=false
INSTALL_GEMINI=false
INSTALL_ANTIGRAVITY=false

for arg in "$@"; do
    case "$arg" in
        --claude)      INSTALL_CLAUDE=true ;;
        --codex)       INSTALL_CODEX=true  ;;
        --gemini)      INSTALL_GEMINI=true ;;
        --antigravity) INSTALL_ANTIGRAVITY=true ;;
        --all)         INSTALL_CLAUDE=true; INSTALL_CODEX=true; INSTALL_GEMINI=true; INSTALL_ANTIGRAVITY=true ;;
    esac
done

# 아무 플래그도 없으면 전부 설치
if ! $INSTALL_CLAUDE && ! $INSTALL_CODEX && ! $INSTALL_GEMINI && ! $INSTALL_ANTIGRAVITY; then
    INSTALL_CLAUDE=true
    INSTALL_CODEX=true
    INSTALL_GEMINI=true
    INSTALL_ANTIGRAVITY=true
fi

echo "DevIsland 브리지 스크립트 설치 중..."

# -------------------------------------------------------------------
# 구 경로 정리 (~/.claude/hooks, ~/.local/share/devisland 로 이전)
# -------------------------------------------------------------------
for OLD_BRIDGE in \
    "$HOME/.claude/hooks/devisland-bridge.sh" \
    "$HOME/.local/share/devisland/devisland-bridge.sh"
do
    if [ -f "$OLD_BRIDGE" ] || [ -L "$OLD_BRIDGE" ]; then
        rm -f "$OLD_BRIDGE"
        echo "✓ 구 경로 브리지 파일 제거: $OLD_BRIDGE"
    fi
done

# -------------------------------------------------------------------
# 브리지 스크립트를 ~/Library/Application Support/DevIsland/ 에 배치
# -------------------------------------------------------------------
HOOKS_DIR="$HOME/Library/Application Support/DevIsland"
BRIDGE_DEST="$HOOKS_DIR/devisland-bridge.sh"
PY_BRIDGE_DEST="$HOOKS_DIR/devisland_bridge.py"
MANIFEST_DEST="$HOOKS_DIR/hook_events.json"

mkdir -p "$HOOKS_DIR"
rm -f "$BRIDGE_DEST"
rm -f "$PY_BRIDGE_DEST"
rm -f "$MANIFEST_DEST"
if [[ "$SCRIPT_DIR" == *.app/Contents/Resources* ]]; then
    cp "$BRIDGE_SRC" "$BRIDGE_DEST"
    cp "$PY_BRIDGE_SRC" "$PY_BRIDGE_DEST"
    cp "$MANIFEST_SRC" "$MANIFEST_DEST"
    echo "✓ 브리지 스크립트 복사 완료: $BRIDGE_DEST"
else
    ln -sf "$BRIDGE_SRC" "$BRIDGE_DEST"
    ln -sf "$PY_BRIDGE_SRC" "$PY_BRIDGE_DEST"
    ln -sf "$MANIFEST_SRC" "$MANIFEST_DEST"
    echo "✓ 브리지 스크립트 링크 생성: $BRIDGE_DEST"
fi
chmod +x "$BRIDGE_DEST"
chmod +x "$PY_BRIDGE_DEST"

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
bridge_command = f'"{bridge_path}" --source claude'

with open(path) as f:
    data = json.load(f)

data.setdefault('hooks', {})

approval_config  = {"hooks": [{"type": "command", "command": bridge_command, "timeout": 86400}]}
lifecycle_config = {"hooks": [{"type": "command", "command": bridge_command}]}

def remove_bridge_hooks(entries):
    cleaned = []
    for entry in entries:
        sub_hooks = [h for h in entry.get("hooks", []) if "devisland-bridge.sh" not in h.get("command", "")]
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
    ('PreToolUse',        lifecycle_config),
    ('PostToolUse',       lifecycle_config),
    ('PostToolUseFailure', lifecycle_config),
    ('UserPromptSubmit',  lifecycle_config),
    ('Elicitation',       lifecycle_config),
    ('PermissionRequest', approval_config),
]:
    data['hooks'].setdefault(key, [])
    data['hooks'][key] = remove_bridge_hooks(data['hooks'][key])
    data['hooks'][key].append(config)

for key in ['SubagentStop', 'PreCompact', 'StopFailure']:
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
bridge_command = f'"{bridge_path}" --source codex'

data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        pass

data.setdefault('hooks', {})

# 공식 JSON 규격: {"EventName": [{"matcher": "*", "hooks": [{"type": "command", "command": "..."}]}]}
events_lifecycle = ["SessionStart", "PostToolUse", "Stop"]
events_status = ["PreToolUse"]
events_approval = ["PermissionRequest"]
retired_events = ["SessionEnd"]

for event in events_lifecycle + events_status + events_approval:
    event_configs = data['hooks'].get(event, [])
    if not isinstance(event_configs, list):
        event_configs = []

    # PermissionRequest만 실제 승인 대기 이벤트이므로 타임아웃을 길게 설정함 (86400초 = 24시간)
    h_cmd = {"type": "command", "command": bridge_command}
    if event in events_approval:
        h_cmd["timeout"] = 86400

    found = False
    for config in event_configs:
        if config.get("matcher") == "*":
            sub_hooks = config.get("hooks", [])
            sub_hooks = [h for h in sub_hooks if "devisland-bridge.sh" not in h.get("command", "")]
            sub_hooks.append(h_cmd)
            config["hooks"] = sub_hooks
            found = True
            break

    if not found:
        event_configs.append({
            "matcher": "*",
            "hooks": [h_cmd]
        })
    
    data['hooks'][event] = event_configs

for event in retired_events:
    cleaned = []
    for config in data['hooks'].get(event, []):
        sub_hooks = [h for h in config.get("hooks", []) if "devisland-bridge.sh" not in h.get("command", "")]
        if sub_hooks:
            updated = dict(config)
            updated["hooks"] = sub_hooks
            cleaned.append(updated)
    if cleaned:
        data['hooks'][event] = cleaned
    else:
        data['hooks'].pop(event, None)

with open(path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
EOF

    # config.toml에서 features 활성화 및 구형 [[hooks]] 제거
    echo "✓ Codex CLI config.toml 패치 중 (hooks feature 활성화 및 정리)..."
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

# [features] 섹션 안에서 hooks feature flag를 활성화하고 deprecated codex_hooks는 제거
features_idx = None
for i, line in enumerate(new_lines):
    if line.strip() == '[features]':
        features_idx = i
        break

if features_idx is not None:
    features_end = features_idx + 1
    while features_end < len(new_lines):
        if new_lines[features_end].strip().startswith('['):
            break
        features_end += 1

    found_hooks = False
    feature_lines = []
    for line in new_lines[features_idx + 1:features_end]:
        stripped = line.strip()
        key = stripped.split('=', 1)[0].strip() if '=' in stripped else ''
        if key == 'hooks':
            feature_lines.append('hooks = true\n')
            found_hooks = True
        elif key == 'codex_hooks':
            continue
        else:
            feature_lines.append(line)

    if not found_hooks:
        feature_lines.append('hooks = true\n')

    new_lines = new_lines[:features_idx + 1] + feature_lines + new_lines[features_end:]
else:
    if new_lines and not new_lines[-1].endswith('\n'):
        new_lines.append('\n')
    new_lines.append('\n[features]\nhooks = true\n')

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
bridge_command = f'"{bridge_path}" --source gemini'

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

for event in ["BeforeTool", "SessionStart", "SessionEnd", "AfterAgent", "Notification"]:
    event_configs = hooks.get(event, [])
    if not isinstance(event_configs, list):
        event_configs = []
    
    found = False
    for config in event_configs:
        if config.get("matcher") == "*":
            sub_hooks = config.get("hooks", [])
            sub_hooks = [h for h in sub_hooks if "devisland-bridge.sh" not in h.get("command", "")]
            hook_entry = {"type": "command", "command": bridge_command}
            if event == "BeforeTool":
                hook_entry["timeout"] = 86400000
            sub_hooks.append(hook_entry)
            config["hooks"] = sub_hooks
            found = True
            break
    
    if not found:
        hook_entry = {"type": "command", "command": bridge_command}
        if event == "BeforeTool":
            hook_entry["timeout"] = 86400000
        event_configs.append({
            "matcher": "*",
            "hooks": [hook_entry]
        })
    
    hooks[event] = event_configs

for event in ["AfterTool", "BeforeAgent", "BeforeModel", "BeforeToolSelection", "AfterModel", "PreCompress"]:
    cleaned = []
    for config in hooks.get(event, []):
        sub_hooks = [h for h in config.get("hooks", []) if "devisland-bridge.sh" not in h.get("command", "")]
        if sub_hooks:
            updated = dict(config)
            updated["hooks"] = sub_hooks
            cleaned.append(updated)
    if cleaned:
        hooks[event] = cleaned
    else:
        hooks.pop(event, None)

data['hooks'] = hooks

with open(path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
EOF

    echo "✓ Gemini CLI 훅 등록 완료: $GEMINI_SETTINGS"
fi

# -------------------------------------------------------------------
# Antigravity CLI 설치  (~/.gemini/config/hooks.json)
# -------------------------------------------------------------------
if $INSTALL_ANTIGRAVITY; then
    ANTIGRAVITY_DIR="$HOME/.gemini/config"
    ANTIGRAVITY_HOOKS="$ANTIGRAVITY_DIR/hooks.json"
    LEGACY_ANTIGRAVITY_DIR="$HOME/.gemini/antigravity-cli"
    LEGACY_ANTIGRAVITY_HOOKS="$LEGACY_ANTIGRAVITY_DIR/hooks.json"
    mkdir -p "$ANTIGRAVITY_DIR"

    python3 - "$ANTIGRAVITY_HOOKS" "$BRIDGE_DEST" "$LEGACY_ANTIGRAVITY_HOOKS" "$LEGACY_ANTIGRAVITY_DIR" << 'EOF'
import json, sys, os

path, bridge_path, legacy_path, legacy_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
same_hooks_file = (
    os.path.exists(path)
    and os.path.exists(legacy_path)
    and os.path.samefile(path, legacy_path)
)

def bridge_command(event):
    return f'"{bridge_path}" --source antigravity --event {event}'

def is_bridge_command(command):
    return "devisland-bridge.sh" in command or "devisland-bridge-antigravity.sh" in command

data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)

devisland_config = data.setdefault('devisland', {})
devisland_config['enabled'] = True

events_matcher_based = ["PreToolUse", "PostToolUse"]
events_direct = ["PreInvocation", "PostInvocation", "Stop"]

for event in events_matcher_based:
    event_configs = devisland_config.get(event, [])
    if not isinstance(event_configs, list):
        event_configs = []

    h_cmd = {"type": "command", "command": bridge_command(event)}
    if event == "PreToolUse":
        h_cmd["timeout"] = 86400

    found = False
    for config in event_configs:
        if config.get("matcher") == "*":
            sub_hooks = config.get("hooks", [])
            sub_hooks = [h for h in sub_hooks if not is_bridge_command(h.get("command", ""))]
            sub_hooks.append(h_cmd)
            config["hooks"] = sub_hooks
            found = True
            break

    if not found:
        event_configs.append({
            "matcher": "*",
            "hooks": [h_cmd]
        })
    devisland_config[event] = event_configs

for event in events_direct:
    event_configs = devisland_config.get(event, [])
    if not isinstance(event_configs, list):
        event_configs = []

    event_configs = [h for h in event_configs if not is_bridge_command(h.get("command", ""))]
    h_cmd = {"type": "command", "command": bridge_command(event)}
    event_configs.append(h_cmd)
    devisland_config[event] = event_configs

with open(path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

if os.path.exists(legacy_path) and not same_hooks_file:
    try:
        with open(legacy_path) as f:
            legacy_data = json.load(f)
        legacy_data.pop("devisland", None)
        with open(legacy_path, "w") as f:
            json.dump(legacy_data, f, indent=2, ensure_ascii=False)
    except Exception:
        pass

for name in ["devisland-bridge-antigravity.sh", "devisland_bridge.py", "hook_events.json"]:
    try:
        os.remove(os.path.join(legacy_dir, name))
    except FileNotFoundError:
        pass
EOF

    echo "✓ Antigravity CLI 훅 등록 완료: $ANTIGRAVITY_HOOKS"
fi

echo ""
echo "설치 완료!"
if $INSTALL_CLAUDE; then echo "  • Claude Code: ~/.claude/settings.json"; fi
if $INSTALL_CODEX;  then echo "  • Codex CLI:   ~/.codex/hooks.json 및 config.toml"; fi
if $INSTALL_GEMINI; then echo "  • Gemini CLI:  ~/.gemini/settings.json"; fi
if $INSTALL_ANTIGRAVITY; then echo "  • Antigravity CLI: ~/.gemini/config/hooks.json"; fi
echo ""
echo "각 CLI 세션을 재시작해주세요."
