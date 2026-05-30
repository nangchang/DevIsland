#!/bin/bash
# DevIsland bridge: stdin → DevIsland IPC → CLI hook response

# -------------------------------------------------------------------
# 인자 파싱 (CLI 소스 명시적 지정 지원)
# -------------------------------------------------------------------
CLI_SOURCE_ARG=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --source) CLI_SOURCE_ARG="$2"; shift ;;
        *) ;;
    esac
    shift
done

PAYLOAD=$(cat)

# 현재 터미널 창/탭 타이틀 추출 (TTY로 정확한 창/탭 특정)
TERM_TITLE="Terminal"
TERM_APP=""
TERM_WINDOW_ID=""
TERM_TAB_INDEX=""
TERM_TMUX_SOCKET=""
TERM_TMUX_CLIENT=""
TERM_TMUX_PANE="${TMUX_PANE:-}"

current_tty() {
  local tty_path
  tty_path=$(tty 2>/dev/null)
  if [ -n "$tty_path" ] && [ "$tty_path" != "not a tty" ]; then
    printf '%s\n' "$tty_path"
    return
  fi

  local pid="$$"
  local tty_name
  local parent
  while [ -n "$pid" ] && [ "$pid" != "0" ]; do
    tty_name=$(ps -o tty= -p "$pid" 2>/dev/null | awk '{print $1}')
    if [ -n "$tty_name" ] && [ "$tty_name" != "??" ] && [ "$tty_name" != "?" ]; then
      case "$tty_name" in
        /dev/*) printf '%s\n' "$tty_name" ;;
        *) printf '/dev/%s\n' "$tty_name" ;;
      esac
      return
    fi
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | awk '{print $1}')
    [ "$parent" = "$pid" ] && break
    pid="$parent"
  done
}

CURRENT_TTY=$(current_tty)
CURRENT_TTY_NAME="${CURRENT_TTY##*/}"

# tmux 안에서는 inner PTY 대신 outer(client) TTY 사용
# 터미널 앱(iTerm/Terminal)은 outer TTY만 알고 있기 때문에
# inner PTY로는 올바른 창/탭을 찾을 수 없음
if [ -n "$TMUX" ]; then
  TERM_TMUX_SOCKET="${TMUX%%,*}"
  CLIENT_TTY=""
  TERM_TMUX_CLIENT=""
  while IFS='|' read -r client_name client_tty client_pane; do
    if [ "$client_pane" = "$TERM_TMUX_PANE" ]; then
      TERM_TMUX_CLIENT="$client_name"
      CLIENT_TTY="$client_tty"
      break
    fi
  done < <(tmux list-clients -F '#{client_name}|#{client_tty}|#{pane_id}' 2>/dev/null)

  if [ -z "$CLIENT_TTY" ]; then
    CLIENT_TTY=$(tmux display-message -p '#{client_tty}' 2>/dev/null)
    TERM_TMUX_CLIENT=$(tmux display-message -p '#{client_name}' 2>/dev/null)
  fi
  if [ -n "$CLIENT_TTY" ]; then
    CURRENT_TTY="$CLIENT_TTY"
    CURRENT_TTY_NAME="${CURRENT_TTY##*/}"
  fi
fi

# tmux 안에서 TERM_PROGRAM이 없거나 "tmux"로 덮여 있으면 각 앱 블록을 TTY 매칭으로 순서대로 시도
_TMUX_FALLBACK=0
if [ -n "$TMUX" ] && { [ -z "$TERM_PROGRAM" ] || [ "$TERM_PROGRAM" = "tmux" ]; }; then
  _TMUX_FALLBACK=1
fi

if [ -n "$CURRENT_TTY" ] && { [ "$TERM_PROGRAM" = "iTerm.app" ] || { [ "$_TMUX_FALLBACK" = "1" ] && osascript -e 'return (application "iTerm2" is running) or (application "iTerm" is running)' 2>/dev/null | grep -q "true"; }; }; then
  ITERM_INFO=$(osascript 2>> /tmp/DevIsland.bridge.log << ASEOF
if not ((application "iTerm2" is running) or (application "iTerm" is running)) then return ""
tell application "iTerm"
  set ttyPath to "$CURRENT_TTY"
  set ttyName to "$CURRENT_TTY_NAME"
  repeat with aWindow in windows
    repeat with aTab in tabs of aWindow
      set tabIndex to 0
      repeat with candidateTab in tabs of aWindow
        set tabIndex to tabIndex + 1
        if candidateTab is aTab then exit repeat
      end repeat
      repeat with aSession in sessions of aTab
        try
          set sessionTTY to tty of aSession
          if sessionTTY is ttyPath or sessionTTY is ttyName then
            return (name of aSession) & ":::" & (id of aWindow as text) & ":::" & (tabIndex as text)
          end if
        end try
      end repeat
    end repeat
  end repeat
  return ""
end tell
ASEOF
)
  if [ -n "$ITERM_INFO" ]; then
    TERM_APP="iTerm"
    TERM_TITLE=$(printf '%s' "$ITERM_INFO" | awk -F ':::' '{print $1}')
    TERM_WINDOW_ID=$(printf '%s' "$ITERM_INFO" | awk -F ':::' '{print $2}')
    TERM_TAB_INDEX=$(printf '%s' "$ITERM_INFO" | awk -F ':::' '{print $3}')
  fi
fi

if [ -z "$TERM_APP" ] && [ -n "$CURRENT_TTY" ] && { [ "$TERM_PROGRAM" = "Apple_Terminal" ] || { [ "$_TMUX_FALLBACK" = "1" ] && osascript -e 'return (application "Terminal" is running)' 2>/dev/null | grep -q "true"; }; }; then
  TERM_INFO=$(osascript 2>> /tmp/DevIsland.bridge.log << ASEOF
if not (application "Terminal" is running) then return ""
tell application "Terminal"
  set ttyPath to "$CURRENT_TTY"
  set ttyName to "$CURRENT_TTY_NAME"
  repeat with aWin in windows
    set tabIndex to 0
    repeat with aTab in tabs of aWin
      set tabIndex to tabIndex + 1
      try
        set tabTTY to tty of aTab
        if tabTTY is ttyPath or tabTTY is ttyName then
          return (name of aWin) & ":::" & (id of aWin as text) & ":::" & (tabIndex as text)
        end if
      end try
    end repeat
  end repeat
  return ""
end tell
ASEOF
)
  if [ -n "$TERM_INFO" ]; then
    TERM_APP="Terminal"
    TERM_TITLE=$(printf '%s' "$TERM_INFO" | awk -F ':::' '{print $1}')
    TERM_WINDOW_ID=$(printf '%s' "$TERM_INFO" | awk -F ':::' '{print $2}')
    TERM_TAB_INDEX=$(printf '%s' "$TERM_INFO" | awk -F ':::' '{print $3}')
  fi
fi

if [ -z "$TERM_APP" ] && [ -n "$CURRENT_TTY" ] && { [ -n "$CMUX_WORKSPACE_ID" ] || [ -n "$CMUX_SURFACE_ID" ]; }; then
  if osascript -e 'return (application "cmux" is running)' 2>/dev/null | grep -q "true"; then
    TERM_APP="cmux"
    # ID로 워크스페이스 이름을 조회 — current-workspace는 포커스 상태에 따라 바뀌므로 사용 안 함
    if [ -n "$CMUX_WORKSPACE_ID" ]; then
      TERM_TITLE=$(osascript 2>/dev/null << ASEOF
tell application "cmux"
  repeat with aWindow in windows
    repeat with aTab in tabs of aWindow
      if (id of aTab as text) is "$CMUX_WORKSPACE_ID" then
        return name of aTab
      end if
    end repeat
  end repeat
  return ""
end tell
ASEOF
)
    fi
    TERM_WINDOW_ID="${CMUX_WORKSPACE_ID:-}"
    TERM_TAB_INDEX="${CMUX_SURFACE_ID:-}"
  fi
fi

if [ -z "$TERM_APP" ] && [ -n "$CURRENT_TTY" ] && [ -n "$GHOSTTY_BIN_DIR" ]; then
  if osascript -e 'return (application "Ghostty" is running)' 2>/dev/null | grep -q "true"; then
    TERM_APP="Ghostty"
    TERM_TITLE=$(osascript -e 'tell application "Ghostty" to get name of front window' 2>/dev/null || echo "Ghostty")
  fi
fi

if [ -z "$TERM_APP" ] && [ -n "$CURRENT_TTY" ] && [ "$TERM_PROGRAM" = "WarpTerminal" ]; then
  if osascript -e 'return (application "Warp" is running)' 2>/dev/null | grep -q "true"; then
    TERM_APP="Warp"
    TERM_TITLE="Warp"
  fi
fi

# VS Code integrated terminal (TERM_PROGRAM=vscode, has TTY)
# TERM_PROGRAM=vscode is set by all VS Code variants (Insiders, VSCodium, etc.) — no app check needed
if [ -z "$TERM_APP" ] && [ "$TERM_PROGRAM" = "vscode" ]; then
  TERM_APP="VSCode"
  _dir=$(basename "$PWD" 2>/dev/null)
  TERM_TITLE="${_dir:-VS Code}"
fi

# VS Code extension host (no TTY, VSCODE_PID / VSCODE_IPC_HOOK / VSCODE_IPC_HOOK_CLI)
if [ -z "$TERM_APP" ] && { [ -n "${VSCODE_PID:-}" ] || [ -n "${VSCODE_IPC_HOOK:-}" ] || [ -n "${VSCODE_IPC_HOOK_CLI:-}" ]; }; then
  if osascript -e 'return application id "com.microsoft.VSCode" is running' 2>/dev/null | grep -q "true"; then
    TERM_APP="VSCode"
    _dir=$(basename "$PWD" 2>/dev/null)
    TERM_TITLE="${_dir:-VS Code}"
  fi
fi

# Claude Desktop app: CLAUDE_CODE_DESKTOP 환경변수 또는 부모 프로세스 체인에서 "Claude" 앱 탐지
if [ -z "$TERM_APP" ]; then
  _is_claude_desktop=0
  if [ -n "${CLAUDE_CODE_DESKTOP:-}" ]; then
    _is_claude_desktop=1
  else
    _pid=$$
    for _i in 1 2 3 4 5; do
      _ppid=$(ps -p "$_pid" -o ppid= 2>/dev/null | tr -d ' ')
      [ -z "$_ppid" ] || [ "$_ppid" = "0" ] && break
      _pname=$(ps -p "$_ppid" -o comm= 2>/dev/null | tr -d ' ')
      if echo "$_pname" | grep -q "Claude\.app/Contents/MacOS/Claude$"; then
        _is_claude_desktop=1
        break
      fi
      _pid="$_ppid"
    done
  fi
  if [ "$_is_claude_desktop" = "1" ]; then
    TERM_APP="ClaudeDesktop"
    _dir=$(basename "$PWD" 2>/dev/null)
    TERM_TITLE="${_dir:-Claude}"
  fi
fi

if [ -z "$TERM_APP" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Ignoring non-terminal hook source: TERM_PROGRAM=${TERM_PROGRAM:-} TERM_TTY=${CURRENT_TTY:-}" >> /tmp/DevIsland.bridge.log
  exit 0
fi

# 타이틀을 얻지 못한 경우 현재 디렉토리 이름으로 폴백 (루트 '/' 제외)
if [ -z "$TERM_TITLE" ] || [ "$TERM_TITLE" = "Terminal" ]; then
  _dir=$(basename "$PWD" 2>/dev/null)
  if [ -n "$_dir" ] && [ "$_dir" != "/" ]; then
    TERM_TITLE="$_dir"
  else
    TERM_TITLE="Claude"
  fi
fi

# 페이로드 처리, TCP 송수신, CLI별 응답 변환은 Python helper가 담당한다.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_BRIDGE="$SCRIPT_DIR/devisland_bridge.py"

if [ ! -f "$PY_BRIDGE" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Python bridge helper missing: $PY_BRIDGE" >> /tmp/DevIsland.bridge.log
  exit 0
fi

printf "%s" "$PAYLOAD" \
  | TERM_TITLE="$TERM_TITLE" \
    TERM_APP="$TERM_APP" \
    TERM_TTY="$CURRENT_TTY" \
    TERM_WINDOW_ID="$TERM_WINDOW_ID" \
    TERM_TAB_INDEX="$TERM_TAB_INDEX" \
    TERM_TMUX_PANE="$TERM_TMUX_PANE" \
    TERM_TMUX_SOCKET="$TERM_TMUX_SOCKET" \
    TERM_TMUX_CLIENT="$TERM_TMUX_CLIENT" \
    python3 "$PY_BRIDGE" --source "$CLI_SOURCE_ARG"

exit 0
