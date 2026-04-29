#!/bin/bash
# DevIsland bridge: stdin → TCP:9090 → Claude Code hook response

PAYLOAD=$(cat)

# 앱 미실행 시 hook이 없는 것과 동일하게 기본 동작으로 통과
if ! nc -z localhost 9090 2>/dev/null; then
  exit 0
fi

# 현재 터미널 창/탭 타이틀 추출
TERM_TITLE="Terminal"
if [ "$TERM_PROGRAM" = "iTerm.app" ]; then
  TERM_TITLE=$(osascript -e 'tell application "iTerm" to get name of current session of current window' 2>/dev/null || echo "iTerm")
elif [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
  TERM_TITLE=$(osascript -e 'tell application "Terminal" to get name of selected tab of front window' 2>/dev/null || echo "Terminal")
elif [ -n "$GHOSTTY_BIN_DIR" ]; then
  TERM_TITLE="Ghostty"
fi

# 페이로드에 터미널 정보 추가
PAYLOAD=$(echo "$PAYLOAD" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); d['terminal_title']='$TERM_TITLE'; print(json.dumps(d))")

# 이벤트 종류 추출 (PermissionRequest / PreToolUse / Stop / ...)
EVENT=$(echo "$PAYLOAD" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('hook_event_name', d.get('event', 'PermissionRequest')))" \
  2>/dev/null || echo "PermissionRequest")

# 디버그 로그 기록
echo "[$(date '+%H-%m-%d %H:%M:%S')] Raw Payload: $PAYLOAD" >> /tmp/DevIsland.bridge.log
echo "[$(date '+%H-%m-%d %H:%M:%S')] Event Detected: $EVENT" >> /tmp/DevIsland.bridge.log

# 앱으로 전달 후 응답 대기 (최대 300초)
RAW=$(echo "$PAYLOAD" | nc -w 300 localhost 9090)
RESULT=$(echo "$RAW" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('response','denied'))" \
  2>/dev/null || echo "denied")

# 4-1: 이벤트별 응답 형식 분기
# PermissionRequest → behavior: deny  /  PreToolUse → behavior: block
if [ "$RESULT" = "approved" ]; then
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"$EVENT\",\"decision\":{\"behavior\":\"allow\"}}}"
else
  BEHAVIOR=$( [ "$EVENT" = "PreToolUse" ] && echo "block" || echo "deny" )
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"$EVENT\",\"decision\":{\"behavior\":\"$BEHAVIOR\",\"message\":\"DevIsland에서 거절되었습니다.\"}}}"
fi

exit 0
