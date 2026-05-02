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
        echo -n "⏳ 5초 후 실행합니다... "
        for i in {5..1}; do
            echo -n "$i "
            sleep 1
        done
        echo ""
        DELAY=0 # 한 번 지연 후 초기화 (연속 호출 방지)
    fi

    # Pretty print payload for log if jq is available
    if command -v jq >/dev/null 2>&1; then
        echo "==> Sending: $(echo "$payload" | jq -c .)"
    else
        echo "==> Sending: $payload"
    fi
    
    local response
    response=$(echo "$payload" | "$BRIDGE_SCRIPT")
    
    echo "==> Response: $response"
    if echo "$response" | grep -q "allow"; then
        echo "✅ APPROVED"
    elif echo "$response" | grep -q "deny"; then
        echo "❌ DENIED"
    else
        echo "ℹ️  CONTINUE (Passive Event)"
    fi
    echo ""
}

interactive() {
    echo "🏝️  DevIsland Hook Test CLI"
    echo "Session ID: $SESSION_ID"
    echo "---------------------------"
    
    # 세션 시작 알림
    send_event "{\"event\": \"SessionStart\", \"session_id\": \"$SESSION_ID\"}"
    
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
                send_event "{\"event\": \"PermissionRequest\", \"session_id\": \"$SESSION_ID\", \"tool_name\": \"bash\", \"tool_input\": {\"command\": \"ls -la\", \"description\": \"파일 목록 보기\"}}"
                ;;
            2)
                send_event "{\"event\": \"PermissionRequest\", \"session_id\": \"$SESSION_ID\", \"tool_name\": \"bash\", \"tool_input\": {\"command\": \"rm -rf /\", \"description\": \"전체 파일 삭제 (위험!)\"}}"
                ;;
            3)
                send_event "{\"event\": \"PermissionRequest\", \"session_id\": \"$SESSION_ID\", \"tool_name\": \"write\", \"tool_input\": {\"file_path\": \"test.txt\", \"content\": \"Hello DevIsland!\"}}"
                ;;
            4)
                send_event "{\"event\": \"PermissionRequest\", \"session_id\": \"$SESSION_ID\", \"tool_name\": \"read\", \"tool_input\": {\"file_path\": \"DevIsland/AppState.swift\"}}"
                ;;
            5)
                read -p "알림 메시지: " msg
                send_event "{\"event\": \"Notification\", \"session_id\": \"$SESSION_ID\", \"message\": \"$msg\"}"
                ;;
            6)
                send_event "{\"event\": \"SessionEnd\", \"session_id\": \"$SESSION_ID\"}"
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
        send_event "{\"event\": \"SessionStart\", \"session_id\": \"$SESSION_ID\"}"
        ;;
    bash)
        CMD=${1:-"ls -la"}
        send_event "{\"event\": \"PermissionRequest\", \"session_id\": \"$SESSION_ID\", \"tool_name\": \"bash\", \"tool_input\": {\"command\": \"$CMD\"}}"
        ;;
    write)
        FILE=${1:-"test.txt"}
        CONTENT=${2:-"Hello World"}
        send_event "{\"event\": \"PermissionRequest\", \"session_id\": \"$SESSION_ID\", \"tool_name\": \"write\", \"tool_input\": {\"file_path\": \"$FILE\", \"content\": \"$CONTENT\"}}"
        ;;
    notification)
        MSG=${1:-"Hello from CLI"}
        send_event "{\"event\": \"Notification\", \"session_id\": \"$SESSION_ID\", \"message\": \"$MSG\"}"
        ;;
    stop)
        send_event "{\"event\": \"SessionEnd\", \"session_id\": \"$SESSION_ID\"}"
        ;;
    *)
        usage
        ;;
esac
