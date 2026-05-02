#!/bin/bash

# DevIsland Hook Test CLI
# This script simulates Claude Code calling the bridge script with various events.

BRIDGE_SCRIPT="$(dirname "$0")/devisland-bridge.sh"

if [ ! -f "$BRIDGE_SCRIPT" ]; then
    echo "Error: devisland-bridge.sh not found at $BRIDGE_SCRIPT"
    exit 1
fi

# Default session ID
SESSION_ID=${SESSION_ID:-"test-session-$(date +%s | cut -c 6-10)"}
DELAY=0

usage() {
    echo "DevIsland Test CLI - 편하게 훅 호출을 테스트하세요"
    echo ""
    echo "사용법:"
    echo "  $0                      # 대화형 모드 실행"
    echo "  $0 start                # 세션 시작"
    echo "  $0 bash [command]       # Bash 명령 승인 요청"
    echo "  $0 write [path] [cont]  # 파일 쓰기 승인 요청"
    echo "  $0 stop                 # 세션 종료"
    echo ""
    echo "옵션:"
    echo "  -d, --delay             # 실행 전 5초 대기"
    echo "  SESSION_ID=abc $0 ...   # 커스텀 세션 ID 지정"
    exit 1
}

send_event() {
    local payload="$1"
    
    if [ "$DELAY" -eq 1 ]; then
        printf "⏳ 5초 후 실행합니다... "
        for i in {5..1}; do
            printf "%s " "$i"
            sleep 1
        done
        printf "\n"
        DELAY=0 # 한 번 지연 후 초기화 (연속 호출 방지)
    fi

    # Pretty print payload for log if jq is available
    if command -v jq >/dev/null 2>&1; then
        printf "==> Sending: %s\n" "$(printf "%s" "$payload" | jq -c .)"
    else
        printf "==> Sending: %s\n" "$payload"
    fi
    
    local response
    response=$(printf "%s" "$payload" | "$BRIDGE_SCRIPT")
    
    printf "==> Response: %s\n" "$response"
    # Refined grep patterns for JSON structure
    if printf "%s" "$response" | grep -q '"behavior":[[:space:]]*"allow"'; then
        echo "✅ APPROVED"
    elif printf "%s" "$response" | grep -q '"behavior":[[:space:]]*"deny"'; then
        echo "❌ DENIED"
    else
        echo "ℹ️  CONTINUE (Passive Event)"
    fi
    echo ""
}

# Safer JSON construction using Python
make_json() {
    # Usage: make_json key1 value1 key2 value2 ...
    # If a value starts with { it is treated as a JSON object
    python3 -c '
import sys, json
args = sys.argv[1:]
d = {}
for i in range(0, len(args), 2):
    k = args[i]
    v = args[i+1]
    if v.startswith("{") and v.endswith("}"):
        try:
            v = json.loads(v)
        except:
            pass
    d[k] = v
print(json.dumps(d))
' "$@"
}

interactive() {
    echo "🏝️  DevIsland Hook Test CLI"
    echo "Session ID: $SESSION_ID"
    echo "---------------------------"
    
    # 세션 시작 알림
    send_event "$(make_json event SessionStart session_id "$SESSION_ID")"
    
    while true; do
        echo "무엇을 테스트하시겠습니까?"
        echo "1) 일반 Bash 명령 (ls -la)"
        echo "2) 위험한 Bash 명령 (rm -rf /)"
        echo "3) 파일 쓰기 (example.txt)"
        echo "4) 파일 읽기 (AppState.swift)"
        echo "5) 커스텀 알림 보내기"
        echo "6) 세션 종료 및 나가기"
        echo "d) 5초 지연 모드 토글 (현재: $([ "$DELAY" -eq 1 ] && echo "ON" || echo "OFF"))"
        echo "q) 그냥 종료 (세션 유지)"
        
        read -p "선택: " choice
        
        case "$choice" in
            1)
                input=$(make_json command "ls -la" description "파일 목록 보기")
                send_event "$(make_json event PermissionRequest session_id "$SESSION_ID" tool_name bash tool_input "$input")"
                ;;
            2)
                input=$(make_json command "rm -rf /" description "전체 파일 삭제 (위험!)")
                send_event "$(make_json event PermissionRequest session_id "$SESSION_ID" tool_name bash tool_input "$input")"
                ;;
            3)
                input=$(make_json file_path "test.txt" content "Hello DevIsland!")
                send_event "$(make_json event PermissionRequest session_id "$SESSION_ID" tool_name write tool_input "$input")"
                ;;
            4)
                input=$(make_json file_path "DevIsland/AppState.swift")
                send_event "$(make_json event PermissionRequest session_id "$SESSION_ID" tool_name read tool_input "$input")"
                ;;
            5)
                read -p "알림 메시지: " msg
                send_event "$(make_json event Notification session_id "$SESSION_ID" message "$msg")"
                ;;
            6)
                send_event "$(make_json event SessionEnd session_id "$SESSION_ID")"
                break
                ;;
            d|D)
                if [ "$DELAY" -eq 1 ]; then DELAY=0; else DELAY=1; fi
                echo "지연 모드가 $([ "$DELAY" -eq 1 ] && echo "켜졌습니다" || echo "꺼졌습니다")."
                ;;
            q|Q)
                echo "Bye!"
                exit 0
                ;;
            *)
                echo "잘못된 선택입니다."
                ;;
        esac
    done
}

# Parse options
while [[ "$1" =~ ^- ]]; do
    case "$1" in
        -d|--delay)
            DELAY=1
            shift
            ;;
        *)
            usage
            ;;
    esac
done

COMMAND=$1
shift

if [ -z "$COMMAND" ]; then
    interactive
    exit 0
fi

case "$COMMAND" in
    start)
        send_event "$(make_json event SessionStart session_id "$SESSION_ID")"
        ;;
    bash)
        CMD=${1:-"ls -la"}
        input=$(make_json command "$CMD")
        send_event "$(make_json event PermissionRequest session_id "$SESSION_ID" tool_name bash tool_input "$input")"
        ;;
    write)
        FILE=${1:-"test.txt"}
        CONTENT=${2:-"Hello World"}
        input=$(make_json file_path "$FILE" content "$CONTENT")
        send_event "$(make_json event PermissionRequest session_id "$SESSION_ID" tool_name write tool_input "$input")"
        ;;
    notification)
        MSG=${1:-"Hello from CLI"}
        send_event "$(make_json event Notification session_id "$SESSION_ID" message "$MSG")"
        ;;
    stop)
        send_event "$(make_json event SessionEnd session_id "$SESSION_ID")"
        ;;
    *)
        usage
        ;;
esac
