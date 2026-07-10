#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -------------------------------------------------------------------
# 브리지 스크립트 위치 확인
# -------------------------------------------------------------------
BRIDGE_SRC="$SCRIPT_DIR/devisland-bridge.sh"
PY_BRIDGE_SRC="$SCRIPT_DIR/devisland_bridge.py"
MANIFEST_SRC="$SCRIPT_DIR/hook_events.json"
INSTALL_HOOKS_SRC="$SCRIPT_DIR/install_hooks.py"
if [ ! -f "$BRIDGE_SRC" ]; then
    BUNDLE_SRC="/Applications/DevIsland.app/Contents/Resources/devisland-bridge.sh"
    if [ -f "$BUNDLE_SRC" ]; then
        BRIDGE_SRC="$BUNDLE_SRC"
        PY_BRIDGE_SRC="/Applications/DevIsland.app/Contents/Resources/devisland_bridge.py"
        MANIFEST_SRC="/Applications/DevIsland.app/Contents/Resources/hook_events.json"
        INSTALL_HOOKS_SRC="/Applications/DevIsland.app/Contents/Resources/install_hooks.py"
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
if [ ! -f "$INSTALL_HOOKS_SRC" ]; then
    echo "오류: install_hooks.py 를 찾을 수 없습니다."
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

    python3 "$INSTALL_HOOKS_SRC" claude "$SETTINGS_FILE" "$BRIDGE_DEST"

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
    
    python3 "$INSTALL_HOOKS_SRC" codex-hooks "$CODEX_HOOKS" "$BRIDGE_DEST"

    # config.toml에서 features 활성화 및 구형 [[hooks]] 제거
    echo "✓ Codex CLI config.toml 패치 중 (hooks feature 활성화 및 정리)..."
    python3 "$INSTALL_HOOKS_SRC" codex-config "$CODEX_CONFIG" "$BRIDGE_DEST"

    echo "✓ Codex CLI 설치 완료."
fi

# -------------------------------------------------------------------
# Gemini CLI 설치  (~/.gemini/settings.json)
# -------------------------------------------------------------------
if $INSTALL_GEMINI; then
    GEMINI_SETTINGS="$HOME/.gemini/settings.json"
    mkdir -p "$(dirname "$GEMINI_SETTINGS")"

    python3 "$INSTALL_HOOKS_SRC" gemini "$GEMINI_SETTINGS" "$BRIDGE_DEST"

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

    python3 "$INSTALL_HOOKS_SRC" antigravity "$ANTIGRAVITY_HOOKS" "$BRIDGE_DEST" "$LEGACY_ANTIGRAVITY_HOOKS" "$LEGACY_ANTIGRAVITY_DIR"

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
