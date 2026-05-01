#!/bin/bash
# DevIsland bridge: stdin → TCP:9090 → Claude Code hook response

PAYLOAD=$(cat)

# 앱 미실행 시 hook이 없는 것과 동일하게 기본 동작으로 통과
if ! nc -z localhost 9090 2>/dev/null; then
  exit 0
fi

# 현재 터미널 창/탭 타이틀 추출 (TTY로 정확한 창/탭 특정)
TERM_TITLE="Terminal"
CURRENT_TTY=$(tty 2>/dev/null)

if [ "$TERM_PROGRAM" = "iTerm.app" ]; then
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
  if [ -n "$CURRENT_TTY" ]; then
    TERM_TITLE=$(osascript << ASEOF
tell application "Terminal"
  set ttyPath to "$CURRENT_TTY"
  repeat with aWin in windows
    repeat with aTab in tabs of aWin
      if tty of aTab is ttyPath then
        return name of aWin
      end if
    end repeat
  end repeat
  return name of front window
end tell
ASEOF
    2>/dev/null)
  else
    TERM_TITLE=$(osascript -e 'tell application "Terminal" to get name of front window' 2>/dev/null)
  fi
elif [ -n "$GHOSTTY_BIN_DIR" ]; then
  TERM_TITLE=$(osascript -e 'tell application "Ghostty" to get name of front window' 2>/dev/null || echo "Ghostty")
elif [ "$TERM_PROGRAM" = "WarpTerminal" ]; then
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

# 페이로드에 터미널 정보 추가 (python3 앞에 환경 변수 설정해 파이프 오른쪽 프로세스에 전달)
PAYLOAD=$(printf "%s" "$PAYLOAD" | TERM_TITLE="$TERM_TITLE" python3 -c \
  'import os,sys,json; d=json.load(sys.stdin); d["terminal_title"]=os.environ.get("TERM_TITLE", "Terminal"); print(json.dumps(d))')

# 이벤트 종류 추출 (PermissionRequest / PreToolUse / Stop / ...)
EVENT=$(printf "%s" "$PAYLOAD" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('hook_event_name', d.get('event', 'PermissionRequest')))" \
  2>/dev/null || echo "PermissionRequest")

# 디버그 로그 기록
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Raw Payload: $PAYLOAD" >> /tmp/DevIsland.bridge.log
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Event Detected: $EVENT" >> /tmp/DevIsland.bridge.log

case "$EVENT" in
  PermissionRequest|SessionStart|SessionEnd)
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

EVENT="$EVENT" RESULT="$RESULT" python3 -c '
import json
import os

event = os.environ.get("EVENT", "")
result = os.environ.get("RESULT", "denied")
approved = result == "approved"
message = "DevIsland에서 거절되었습니다."

if event == "PermissionRequest":
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "allow" if approved else "deny",
            },
        }
    }
    if not approved:
        output["hookSpecificOutput"]["decision"]["message"] = message
else:
    output = {"continue": True, "suppressOutput": True}

print(json.dumps(output, ensure_ascii=False))
'

exit 0
