#!/bin/bash
# DevIsland bridge: stdin → TCP:9090 → Claude Code hook response

PAYLOAD=$(cat)

# 이벤트 종류 추출 (PermissionRequest / PreToolUse / ...)
EVENT=$(echo "$PAYLOAD" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('hook_event_name','PermissionRequest'))" \
  2>/dev/null || echo "PermissionRequest")

# 앱 미실행 시 다이얼로그로 처리 방식 선택
if ! nc -z localhost 9090 2>/dev/null; then
  CHOICE=$(osascript -e 'button returned of (display dialog "DevIsland가 실행 중이지 않습니다." buttons {"거부", "대기", "허용"} default button "허용" with title "DevIsland")')
  case "$CHOICE" in
    "허용")
      exit 0  # JSON 없이 종료 → hook 없는 것과 동일한 기본 동작
      ;;
    "대기")
      while ! nc -z localhost 9090 2>/dev/null; do sleep 2; done
      ;;
    "거부")
      BEHAVIOR=$( [ "$EVENT" = "PreToolUse" ] && echo "block" || echo "deny" )
      echo "{\"hookSpecificOutput\":{\"hookEventName\":\"$EVENT\",\"decision\":{\"behavior\":\"$BEHAVIOR\",\"message\":\"DevIsland가 실행 중이지 않아 거절되었습니다.\"}}}"
      exit 0
      ;;
  esac
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
