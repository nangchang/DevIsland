#!/bin/bash
# DevIsland bridge: stdin → DevIsland IPC → CLI hook response

# -------------------------------------------------------------------
# 인자 파싱 (CLI 소스 명시적 지정 지원)
# -------------------------------------------------------------------
CLI_SOURCE_ARG=""
HOOK_EVENT_ARG=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --source) CLI_SOURCE_ARG="$2"; shift ;;
        --event) HOOK_EVENT_ARG="$2"; shift ;;
        *) ;;
    esac
    shift
done

PAYLOAD=$(cat)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_BRIDGE="$SCRIPT_DIR/devisland_bridge.py"

# Keep this list in sync with scripts/hook_events.json. The shell bridge only
# uses it when the CLI already supplied --event, so forwarded hooks still start
# Python exactly once.
if [ -n "$HOOK_EVENT_ARG" ]; then
  NORM_EVENT=$(printf "%s" "$HOOK_EVENT_ARG" | tr '[:upper:]' '[:lower:]' | tr -d '_-')
  case "$NORM_EVENT" in
    permissionrequest|sessionstart|sessionend|notification|stop|pretooluse|posttooluse|posttoolusefailure|userpromptsubmit|elicitation|beforetool|afteragent|preinvocation|postinvocation|subagentstart|subagentstop)
      ;;
    *)
      printf '{"continue":true,"suppressOutput":true}\n'
      exit 0
      ;;
  esac
fi

# -------------------------------------------------------------------
# TTY 탐지
# -------------------------------------------------------------------
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

process_chain_contains_wezterm() {
  local pid="$1"
  local pname parent depth
  depth=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$depth" -lt 8 ]; do
    pname=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '\n')
    case "$pname" in
      *WezTerm.app/Contents/MacOS/*|*wezterm-gui*|*wezterm*)
        return 0
        ;;
    esac
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$parent" ] || [ "$parent" = "$pid" ]; then break; fi
    pid="$parent"
    depth=$((depth + 1))
  done
  return 1
}

tmux_client_pid_for_tty() {
  local target_tty="$1"
  local client_tty client_pid
  while IFS='|' read -r client_tty client_pid; do
    if [ "$client_tty" = "$target_tty" ]; then
      printf '%s\n' "$client_pid"
      return
    fi
  done < <(tmux list-clients -F '#{client_tty}|#{client_pid}' 2>/dev/null)
}

CURRENT_TTY=$(current_tty)
CURRENT_TTY_NAME="${CURRENT_TTY##*/}"

# -------------------------------------------------------------------
# tmux: inner PTY 대신 outer(client) TTY 사용
# 터미널 앱(iTerm/Terminal)은 outer TTY만 알고 있기 때문에
# inner PTY로는 올바른 창/탭을 찾을 수 없음
# -------------------------------------------------------------------
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

# detached tmux 세션 (클라이언트 없음) 에서 세션을 관리하는 외부 프로세스(예: aoe)를
# 세션명 prefix로 찾아 outer TTY를 복원한다.
# 예) 세션명 "aoe_Bohemians_xxx" → prefix "aoe" → pgrep aoe → ps -o tty= → /dev/ttys002
TERM_MANAGER_SESSION_TITLE=""
if [ -n "$TMUX" ] && [ -z "$CLIENT_TTY" ]; then
  _session_name=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
  _tool_prefix="${_session_name%%_*}"
  if [ -n "$_tool_prefix" ] && [ "$_tool_prefix" != "$_session_name" ]; then
    _mgr_pid=""
    _mgr_tty=""
    while read -r _candidate_pid; do
      [ -n "$_candidate_pid" ] || continue
      _candidate_tty=$(ps -o tty= -p "$_candidate_pid" 2>/dev/null | awk '{print $1}')
      if [ -n "$_candidate_tty" ] && [ "$_candidate_tty" != "??" ] && [ "$_candidate_tty" != "?" ]; then
        _mgr_pid="$_candidate_pid"
        _mgr_tty="$_candidate_tty"
        break
      fi
    done < <(pgrep -x "$_tool_prefix" 2>/dev/null)
    if [ -z "$_mgr_pid" ]; then
      _mgr_pid=$(pgrep -nx "$_tool_prefix" 2>/dev/null)
    fi
    if [ -n "$_mgr_pid" ]; then
      if [ -z "$_mgr_tty" ]; then
        _mgr_tty=$(ps -o tty= -p "$_mgr_pid" 2>/dev/null | awk '{print $1}')
      fi
      if [ -n "$_mgr_tty" ] && [ "$_mgr_tty" != "??" ] && [ "$_mgr_tty" != "?" ]; then
        case "$_mgr_tty" in
          /dev/*) CURRENT_TTY="$_mgr_tty" ;;
          *) CURRENT_TTY="/dev/$_mgr_tty" ;;
        esac
        CURRENT_TTY_NAME="${CURRENT_TTY##*/}"
      fi
      # tmux 세션이 상속한 TERM_PROGRAM/WEZTERM_PANE이 틀릴 수 있으므로
      # manager 프로세스의 부모 체인을 탐색해 실제 터미널 앱을 감지한다.
      _check_pid="$_mgr_pid"
      for _depth in 1 2 3 4 5; do
        _pname=$(ps -o comm= -p "$_check_pid" 2>/dev/null | tr -d ' ')
        _pname_lc=$(printf '%s' "$_pname" | tr '[:upper:]' '[:lower:]')
        case "$_pname_lc" in
          *iterm*) TERM_PROGRAM="iTerm.app"; unset WEZTERM_PANE; break ;;
          *wezterm*) TERM_PROGRAM="WezTerm"; break ;;
          *ghostty*) TERM_PROGRAM="Ghostty"; unset WEZTERM_PANE; break ;;
          *terminal*) TERM_PROGRAM="Apple_Terminal"; unset WEZTERM_PANE; break ;;
          *alacritty*) TERM_PROGRAM="Alacritty"; unset WEZTERM_PANE; break ;;
          *warp*) TERM_PROGRAM="WarpTerminal"; unset WEZTERM_PANE; break ;;
          *kitty*) TERM_PROGRAM="kitty"; unset WEZTERM_PANE; break ;;
          *cmux*) unset WEZTERM_PANE; break ;;
        esac
        _ppid=$(ps -o ppid= -p "$_check_pid" 2>/dev/null | tr -d ' ')
        [ -z "$_ppid" ] || [ "$_ppid" = "0" ] || [ "$_ppid" = "1" ] && break
        _check_pid="$_ppid"
      done
    fi
    # 세션명 두 번째 컴포넌트가 TUI 세션 타이틀 (예: aoe_Bohemians_xxx → Bohemians)
    # 알려진 TUI 매니저만 허용 — 다른 도구의 detached 세션에 의도치 않은 키 입력 방지
    case "$_tool_prefix" in
      aoe)
        _without_prefix="${_session_name#${_tool_prefix}_}"
        _extracted_title="${_without_prefix%_*}"
        if [ -n "$_extracted_title" ] && [ "$_extracted_title" != "$_without_prefix" ]; then
          TERM_MANAGER_SESSION_TITLE="$_extracted_title"
        fi
        ;;
    esac
  fi
fi

# -------------------------------------------------------------------
# 터미널 앱 감지 함수들
#
# 규칙:
#   - 성공 시 TERM_APP, TERM_TITLE, TERM_WINDOW_ID, TERM_TAB_INDEX 설정 후 return 0
#   - 해당 없으면 return 1
#   - 새 터미널 앱: 함수 추가 후 _DETECTORS 배열에 등록만 하면 됨
# -------------------------------------------------------------------

detect_iterm() {
  [ -n "$CURRENT_TTY" ] || return 1
  [ "$TERM_PROGRAM" = "iTerm.app" ] || { [ "$_TMUX_FALLBACK" = "1" ] && osascript -e 'return (application "iTerm2" is running) or (application "iTerm" is running)' 2>/dev/null | grep -q "true"; } || return 1
  local info
  info=$(osascript 2>> /tmp/DevIsland.bridge.log << ASEOF
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
  [ -n "$info" ] || return 1
  TERM_APP="iTerm"
  TERM_TITLE=$(printf '%s' "$info" | awk -F ':::' '{print $1}')
  TERM_WINDOW_ID=$(printf '%s' "$info" | awk -F ':::' '{print $2}')
  TERM_TAB_INDEX=$(printf '%s' "$info" | awk -F ':::' '{print $3}')
}

detect_apple_terminal() {
  [ -n "$CURRENT_TTY" ] || return 1
  [ "$TERM_PROGRAM" = "Apple_Terminal" ] || { [ "$_TMUX_FALLBACK" = "1" ] && osascript -e 'return (application "Terminal" is running)' 2>/dev/null | grep -q "true"; } || return 1
  local info
  info=$(osascript 2>> /tmp/DevIsland.bridge.log << ASEOF
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
  if [ -z "$info" ]; then
    [ "$TERM_PROGRAM" = "Apple_Terminal" ] && [ -n "$TERM_MANAGER_SESSION_TITLE" ] || return 1
    TERM_APP="Terminal"
    TERM_TITLE="Terminal"
    TERM_WINDOW_ID=""
    TERM_TAB_INDEX=""
    return 0
  fi
  TERM_APP="Terminal"
  TERM_TITLE=$(printf '%s' "$info" | awk -F ':::' '{print $1}')
  TERM_WINDOW_ID=$(printf '%s' "$info" | awk -F ':::' '{print $2}')
  TERM_TAB_INDEX=$(printf '%s' "$info" | awk -F ':::' '{print $3}')
}

detect_cmux() {
  [ -n "$CURRENT_TTY" ] || return 1
  { [ -n "$CMUX_WORKSPACE_ID" ] || [ -n "$CMUX_SURFACE_ID" ]; } || return 1
  osascript -e 'return (application "cmux" is running)' 2>/dev/null | grep -q "true" || return 1
  TERM_APP="cmux"
  if [ -n "$CMUX_WORKSPACE_ID" ]; then
    TERM_TITLE=$(osascript - "$CMUX_WORKSPACE_ID" 2>/dev/null << 'ASEOF'
on run argv
  set workspaceID to item 1 of argv
  tell application "cmux"
    repeat with aWindow in windows
      repeat with aTab in tabs of aWindow
        if (id of aTab as text) is workspaceID then
          return name of aTab
        end if
      end repeat
    end repeat
    return ""
  end tell
end run
ASEOF
)
  fi
  TERM_WINDOW_ID="${CMUX_WORKSPACE_ID:-}"
  TERM_TAB_INDEX="${CMUX_SURFACE_ID:-}"
}

detect_ghostty() {
  [ -n "$CURRENT_TTY" ] || return 1
  [ -n "$GHOSTTY_BIN_DIR" ] || return 1
  osascript -e 'return (application "Ghostty" is running)' 2>/dev/null | grep -q "true" || return 1
  TERM_APP="Ghostty"
  TERM_TITLE=$(osascript -e 'tell application "Ghostty" to get name of front window' 2>/dev/null || echo "Ghostty")
}

detect_warp() {
  [ -n "$CURRENT_TTY" ] || return 1
  [ "$TERM_PROGRAM" = "WarpTerminal" ] || return 1
  osascript -e 'return (application "Warp" is running)' 2>/dev/null | grep -q "true" || return 1
  TERM_APP="Warp"
  TERM_TITLE="Warp"
}

# WezTerm: TERM_PROGRAM=WezTerm 또는 WEZTERM_PANE 환경변수로 감지
detect_wezterm() {
  [ -n "$CURRENT_TTY" ] || return 1
  { [ "$TERM_PROGRAM" = "WezTerm" ] || [ -n "${WEZTERM_PANE:-}" ]; } || return 1
  TERM_APP="WezTerm"
  local _dir
  _dir=$(basename "$PWD" 2>/dev/null)
  TERM_TITLE="${_dir:-WezTerm}"
  TERM_WINDOW_ID="${WEZTERM_PANE:-}"
}

# WezTerm (tmux 내부): tmux client pid의 부모 프로세스 체인에서 WezTerm 탐지
# TERM_WINDOW_ID: tmux 내부에서는 WEZTERM_PANE이 전달되지 않으므로 미설정
detect_wezterm_tmux() {
  [ -n "$CURRENT_TTY" ] || return 1
  [ -n "$TMUX" ] || return 1
  [ "$_TMUX_FALLBACK" = "1" ] || return 1
  local _tmux_client_pid
  _tmux_client_pid=$(tmux_client_pid_for_tty "$CURRENT_TTY")
  [ -n "$_tmux_client_pid" ] || return 1
  process_chain_contains_wezterm "$_tmux_client_pid" || return 1
  TERM_APP="WezTerm"
  local _dir
  _dir=$(basename "$PWD" 2>/dev/null)
  TERM_TITLE="${_dir:-WezTerm}"
}

# VS Code integrated terminal (TERM_PROGRAM=vscode, has TTY)
# TERM_PROGRAM=vscode is set by all VS Code variants (Insiders, VSCodium, etc.) — no app check needed
detect_vscode_integrated() {
  [ "$TERM_PROGRAM" = "vscode" ] || return 1
  TERM_APP="VSCode"
  local _dir
  _dir=$(basename "$PWD" 2>/dev/null)
  TERM_TITLE="${_dir:-VS Code}"
}

# VS Code extension host (no TTY, VSCODE_PID / VSCODE_IPC_HOOK / VSCODE_IPC_HOOK_CLI)
detect_vscode_extension_host() {
  { [ -n "${VSCODE_PID:-}" ] || [ -n "${VSCODE_IPC_HOOK:-}" ] || [ -n "${VSCODE_IPC_HOOK_CLI:-}" ]; } || return 1
  osascript -e 'return application id "com.microsoft.VSCode" is running' 2>/dev/null | grep -q "true" || return 1
  TERM_APP="VSCode"
  local _dir
  _dir=$(basename "$PWD" 2>/dev/null)
  TERM_TITLE="${_dir:-VS Code}"
}

# Claude Desktop app: CLAUDE_CODE_DESKTOP 환경변수 또는 부모 프로세스 체인에서 "Claude" 앱 탐지
detect_claude_desktop() {
  local _is=0
  if [ -n "${CLAUDE_CODE_DESKTOP:-}" ]; then
    _is=1
  else
    local _pid=$$
    local _ppid _pname
    for _i in 1 2 3 4 5; do
      _ppid=$(ps -p "$_pid" -o ppid= 2>/dev/null | tr -d ' ')
      [ -z "$_ppid" ] || [ "$_ppid" = "0" ] && break
      _pname=$(ps -p "$_ppid" -o comm= 2>/dev/null | tr -d ' ')
      if echo "$_pname" | grep -q "Claude\.app/Contents/MacOS/Claude$"; then
        _is=1; break
      fi
      _pid="$_ppid"
    done
  fi
  [ "$_is" = "1" ] || return 1
  TERM_APP="ClaudeDesktop"
  local _dir
  _dir=$(basename "$PWD" 2>/dev/null)
  TERM_TITLE="${_dir:-Claude}"
}

# Codex Desktop app: CODEX_SHELL 환경변수 또는 부모 프로세스 체인에서 "Codex" 앱 탐지
detect_orca() {
  [ "$TERM_PROGRAM" = "Orca" ] || return 1
  TERM_APP="Orca"
  # TERM_WINDOW_ID carries the terminal handle (used by `orca terminal switch --terminal <handle>`)
  TERM_WINDOW_ID="${ORCA_TERMINAL_HANDLE:-}"
  TERM_TAB_INDEX="${ORCA_TAB_ID:-}"
  local _worktree_path
  _worktree_path="${ORCA_WORKTREE_ID##*::}"
  TERM_TITLE=$(basename "${_worktree_path:-$PWD}" 2>/dev/null)
  TERM_TITLE="${TERM_TITLE:-Orca}"
}

detect_codex_desktop() {
  local _is=0
  if [ -n "${CODEX_SHELL:-}" ]; then
    _is=1
  else
    local _pid=$$
    local _ppid _pname
    for _i in 1 2 3 4 5; do
      _ppid=$(ps -p "$_pid" -o ppid= 2>/dev/null | tr -d ' ')
      [ -z "$_ppid" ] || [ "$_ppid" = "0" ] && break
      _pname=$(ps -p "$_ppid" -o comm= 2>/dev/null | tr -d ' ')
      if echo "$_pname" | grep -q "Codex.*\.app/Contents/MacOS/Codex$"; then
        _is=1; break
      fi
      _pid="$_ppid"
    done
  fi
  [ "$_is" = "1" ] || return 1
  TERM_APP="CodexDesktop"
  local _dir
  _dir=$(basename "$PWD" 2>/dev/null)
  TERM_TITLE="${_dir:-Codex}"
}

# -------------------------------------------------------------------
# 터미널 앱 감지 실행 — 첫 번째 성공한 detector에서 중단
# 새 터미널 추가: detect_<name>() 함수를 위에 추가하고 여기에 이름만 등록
# -------------------------------------------------------------------
_DETECTORS=(
  detect_iterm
  detect_apple_terminal
  detect_wezterm
  detect_cmux
  detect_ghostty
  detect_warp
  detect_wezterm_tmux
  detect_vscode_integrated
  detect_vscode_extension_host
  detect_claude_desktop
  detect_codex_desktop
  detect_orca
)

for _fn in "${_DETECTORS[@]}"; do
  "$_fn" && break
done

# 감지 실패 시 페이로드에 이미 터미널 정보가 있다면 재사용 (replay 등)
if [ -z "$TERM_APP" ]; then
  _payload_term_app=$(echo "$PAYLOAD" | grep -o '"terminal_app"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | cut -d'"' -f4 2>/dev/null || echo "")
  if [ -n "$_payload_term_app" ]; then
    TERM_APP="$_payload_term_app"
    TERM_TITLE=$(echo "$PAYLOAD" | grep -o '"terminal_title"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | cut -d'"' -f4 2>/dev/null || echo "")
    CURRENT_TTY=$(echo "$PAYLOAD" | grep -o '"terminal_tty"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | cut -d'"' -f4 2>/dev/null || echo "")
    TERM_WINDOW_ID=$(echo "$PAYLOAD" | grep -o '"terminal_window_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | cut -d'"' -f4 2>/dev/null || echo "")
    TERM_TAB_INDEX=$(echo "$PAYLOAD" | grep -o '"terminal_tab_index"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | cut -d'"' -f4 2>/dev/null || echo "")
  fi
fi

# 터미널 감지 완전 실패 — CLI별 기본값으로 조기 종료
if [ -z "$TERM_APP" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Ignoring non-terminal hook source: TERM_PROGRAM=${TERM_PROGRAM:-} TERM_TTY=${CURRENT_TTY:-}" >> /tmp/DevIsland.bridge.log
  if [ "$CLI_SOURCE_ARG" = "antigravity" ] && [ "$HOOK_EVENT_ARG" = "PreToolUse" ]; then
    echo '{"decision": "ask"}'
  elif [ "$CLI_SOURCE_ARG" = "gemini" ]; then
    echo '{}'
  elif [ "$CLI_SOURCE_ARG" = "claude" ]; then
    echo '{"continue": true, "suppressOutput": true}'
  elif [ "$CLI_SOURCE_ARG" = "codex" ]; then
    echo '{"continue": true}'
  else
    echo '{}'
  fi
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

# -------------------------------------------------------------------
# 페이로드 처리, TCP 송수신, CLI별 응답 변환은 Python helper가 담당한다.
# -------------------------------------------------------------------

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
    TERM_MANAGER_SESSION_TITLE="$TERM_MANAGER_SESSION_TITLE" \
    python3 "$PY_BRIDGE" --source "$CLI_SOURCE_ARG" --event "$HOOK_EVENT_ARG"

exit 0
