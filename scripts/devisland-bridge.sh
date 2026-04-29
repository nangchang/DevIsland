#!/bin/bash
# DevIsland bridge: stdin → TCP:9090 → Claude Code hook response

PAYLOAD=$(cat)

# 이벤트 종류 추출 (PermissionRequest / PreToolUse / ...)
EVENT=$(echo "$PAYLOAD" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('hook_event_name','PermissionRequest'))" \
  2>/dev/null || echo "PermissionRequest")

# 4-2: 앱 미실행 시 자동 허용 (Claude가 멈추는 것 방지)
if ! nc -z localhost 9090 2>/dev/null; then
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"$EVENT\",\"decision\":{\"behavior\":\"allow\"}}}"
  exit 0
fi

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
