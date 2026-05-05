#!/bin/bash
# DevIsland bridge: stdin → TCP:9090 → Claude Code hook response

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

# 앱 미실행 시 hook이 없는 것과 동일하게 기본 동작으로 통과
if ! nc -z localhost 9090 2>/dev/null; then
  exit 0
fi

# 현재 터미널 창/탭 타이틀 추출 (TTY로 정확한 창/탭 특정)
TERM_TITLE="Terminal"
TERM_APP="${TERM_PROGRAM:-}"
TERM_WINDOW_ID=""
TERM_TAB_INDEX=""

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

if [ "$TERM_PROGRAM" = "iTerm.app" ]; then
  TERM_APP="iTerm"
  if [ -n "$CURRENT_TTY" ]; then
    TERM_TITLE=$(osascript << ASEOF
tell application "iTerm"
  set ttyPath to "$CURRENT_TTY"
  repeat with aWindow in windows
    repeat with aTab in tabs of aWindow
      repeat with aSession in sessions of aTab
        if tty of aSession is ttyPath then
          return name of aSession
        end if
      end repeat
    end repeat
  end repeat
  return name of current session of current window
end tell
ASEOF
    2>/dev/null || echo "iTerm")
  else
    TERM_TITLE=$(osascript -e 'tell application "iTerm" to get name of current session of current window' 2>/dev/null || echo "iTerm")
  fi
elif [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
  TERM_APP="Terminal"
  if [ -n "$CURRENT_TTY" ]; then
    TERM_INFO=$(osascript << ASEOF
tell application "Terminal"
  set ttyPath to "$CURRENT_TTY"
  repeat with aWin in windows
    set tabIndex to 0
    repeat with aTab in tabs of aWin
      set tabIndex to tabIndex + 1
      if tty of aTab is ttyPath then
        return (name of aWin) & ":::" & (id of aWin as text) & ":::" & (tabIndex as text)
      end if
    end repeat
  end repeat
  return (name of front window) & ":::" & (id of front window as text) & ":::1"
end tell
ASEOF
    2>/dev/null)
    TERM_TITLE=$(printf '%s' "$TERM_INFO" | awk -F ':::' '{print $1}')
    TERM_WINDOW_ID=$(printf '%s' "$TERM_INFO" | awk -F ':::' '{print $2}')
    TERM_TAB_INDEX=$(printf '%s' "$TERM_INFO" | awk -F ':::' '{print $3}')
  else
    TERM_TITLE=$(osascript -e 'tell application "Terminal" to get name of front window' 2>/dev/null)
  fi
elif [ -n "$GHOSTTY_BIN_DIR" ]; then
  TERM_APP="Ghostty"
  TERM_TITLE=$(osascript -e 'tell application "Ghostty" to get name of front window' 2>/dev/null || echo "Ghostty")
elif [ "$TERM_PROGRAM" = "WarpTerminal" ]; then
  TERM_APP="Warp"
  TERM_TITLE="Warp"
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
    python3 "$PY_BRIDGE" --source "$CLI_SOURCE_ARG"

exit 0
