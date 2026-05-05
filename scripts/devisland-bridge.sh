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

# 페이로드에 터미널 정보 및 소스 정보 추가
PAYLOAD=$(printf "%s" "$PAYLOAD" | TERM_TITLE="$TERM_TITLE" TERM_APP="$TERM_APP" TERM_TTY="$CURRENT_TTY" TERM_WINDOW_ID="$TERM_WINDOW_ID" TERM_TAB_INDEX="$TERM_TAB_INDEX" CLI_SOURCE_ARG="$CLI_SOURCE_ARG" python3 -c \
  'import os,sys,json; d=json.load(sys.stdin); d["terminal_title"]=os.environ.get("TERM_TITLE", "Terminal"); d["terminal_app"]=os.environ.get("TERM_APP", ""); d["terminal_tty"]=os.environ.get("TERM_TTY", ""); d["terminal_window_id"]=os.environ.get("TERM_WINDOW_ID", ""); d["terminal_tab_index"]=os.environ.get("TERM_TAB_INDEX", ""); d["cli_source"]=os.environ.get("CLI_SOURCE_ARG", ""); print(json.dumps(d))')

# 이벤트 종류 및 툴 이름 추출 (PermissionRequest / PreToolUse / BeforeTool / Stop / ...)
EVENT=$(printf "%s" "$PAYLOAD" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('hook_event_name', d.get('event', 'PermissionRequest')))" \
  2>/dev/null || echo "PermissionRequest")

TOOL_NAME=$(printf "%s" "$PAYLOAD" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name', ''))" \
  2>/dev/null || echo "")

# CLI 종류 감지 (인자 우선, 그 후 필드 구조 기준)
if [ -n "$CLI_SOURCE_ARG" ]; then
  CLI_SOURCE="$CLI_SOURCE_ARG"
else
  case "$EVENT" in
    PreToolUse)                                               CLI_SOURCE="codex"  ;;
    onToolCall|BeforeTool|AfterTool|BeforeAgent|AfterAgent|\
  BeforeModel|AfterModel|BeforeToolSelection|PreCompress)    CLI_SOURCE="gemini" ;;
    onSessionStart|onSessionEnd|SessionStart|SessionEnd|Notification|Stop|session_start|session_end)
      # 페이로드 구조로 추가 판별
      CLI_SOURCE=$(printf "%s" "$PAYLOAD" | python3 -c '
  import sys, json
  d = json.load(sys.stdin)
  if "hook_event_name" in d: print("claude")
  elif "decision" in d or "reason" in d or "onToolCall" in str(d): print("gemini")
  elif "event" in d and not "hook_event_name" in d: print("gemini") 
  else: print("claude")
  ' 2>/dev/null || echo "claude")
      ;;
    *)           CLI_SOURCE="claude" ;;
  esac
fi

# 디버그 로그 기록
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Raw Payload: $PAYLOAD" >> /tmp/DevIsland.bridge.log
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Event Detected: $EVENT (Source: $CLI_SOURCE)" >> /tmp/DevIsland.bridge.log

case "$EVENT" in
  # Claude / Codex / Gemini 공통 라이프사이클 및 승인 요청
  PermissionRequest|SessionStart|SessionEnd|Notification|Stop|PreToolUse|PostToolUse|BeforeTool|onToolCall|onSessionStart|onSessionEnd|session_start|session_end|AfterAgent|AfterModel|AfterTurn)
    ;;
  # Gemini 기타 상세 이벤트 (관찰용으로 앱에 전달 가능하나 현재는 즉시 통과)
  AfterTool|BeforeAgent|BeforeModel|BeforeToolSelection|PreCompress)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Gemini lifecycle event passthrough: $EVENT" >> /tmp/DevIsland.bridge.log
    printf '{}\n'
    exit 0
    ;;
  *)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Passive event suppressed before app: $EVENT" >> /tmp/DevIsland.bridge.log
    printf '%s\n' '{"continue":true,"suppressOutput":true}'
    exit 0
    ;;
esac

# 앱으로 전달 후 응답 대기 (최대 300초)
RAW=$(printf "%s" "$PAYLOAD" | python3 -c '
import socket
import sys

payload = sys.stdin.buffer.read()
with socket.create_connection(("127.0.0.1", 9090), timeout=5) as sock:
    sock.settimeout(300)
    sock.sendall(payload)
    sock.shutdown(socket.SHUT_WR)

    chunks = []
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        chunks.append(chunk)

sys.stdout.buffer.write(b"".join(chunks))
' 2>/dev/null || true)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Raw Response: $RAW" >> /tmp/DevIsland.bridge.log
RESULT=$(printf "%s" "$RAW" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('response','denied'))" \
  2>/dev/null || echo "denied")
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Result: $RESULT" >> /tmp/DevIsland.bridge.log

EVENT="$EVENT" RESULT="$RESULT" CLI_SOURCE="$CLI_SOURCE" TOOL_NAME="$TOOL_NAME" PAYLOAD="$PAYLOAD" python3 -c '
import json
import os

event = os.environ.get("EVENT", "")
result = os.environ.get("RESULT", "denied")
cli_source = os.environ.get("CLI_SOURCE", "claude")
tool_name = os.environ.get("TOOL_NAME", "")
payload_str = os.environ.get("PAYLOAD", "{}")
message = "DevIsland에서 거절되었습니다."

try:
    payload = json.loads(payload_str)
    file_path = payload.get("tool_input", {}).get("file_path", "")
    is_plan_action = ".gemini/tmp/" in file_path
except:
    is_plan_action = False

if result == "pass":
    if cli_source == "claude":
        print("{\"continue\": true, \"suppressOutput\": true}")
    else:
        # gemini 포함 다른 CLI는 터미널에 제어권을 넘깁니다.
        print("{}")
    import sys
    sys.exit(0)

allow = (result == "approved")
if cli_source == "gemini":
    # Gemini CLI: { "decision": "allow" | "deny", "reason": "...", "skip_prompt": true }
    output = {"decision": "allow" if allow else "deny"}
    if allow:
        # 터미널 프롬프트가 강제되거나 상호작용이 필요한 툴들은 skip_prompt를 생략합니다.
        interactive_tools = ["ask_user", "exit_plan_mode", "run_shell_command"]
        if tool_name not in interactive_tools and not is_plan_action:
            output["skip_prompt"] = True
    if not allow:
        output["reason"] = message
elif cli_source == "codex":
    # Codex CLI: official response format
    # PreToolUse: { "hookSpecificOutput": { "permissionDecision": "allow" | "deny", "permissionDecisionReason": "..." } }
    # PermissionRequest: { "hookSpecificOutput": { "decision": { "behavior": "allow" | "deny", "message": "..." } } }
    if event == "PreToolUse":
        output = {
            "hookSpecificOutput": {
                "permissionDecision": "allow" if allow else "deny",
                "permissionDecisionReason": message if not allow else ""
            }
        }
    elif event == "PermissionRequest":
        output = {
            "hookSpecificOutput": {
                "decision": {
                    "behavior": "allow" if allow else "deny",
                    "message": message if not allow else ""
                }
            }
        }
    else:
        output = {"continue": True}
elif event == "PermissionRequest" and result in ("approved", "denied"):
    # Claude Code
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "allow" if result == "approved" else "deny",
            },
        }
    }
    if result != "approved":
        output["hookSpecificOutput"]["decision"]["message"] = message
else:
    output = {"continue": True, "suppressOutput": True}

print(json.dumps(output, ensure_ascii=False))
'

exit 0
