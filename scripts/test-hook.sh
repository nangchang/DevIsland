#!/bin/bash

# DevIsland Hook Test CLI
# Claude Code / Codex CLI / Gemini CLI 훅 호출을 시뮬레이션합니다.

BRIDGE_SCRIPT="$(dirname "$0")/devisland-bridge.sh"

if [ ! -f "$BRIDGE_SCRIPT" ]; then
    echo "Error: devisland-bridge.sh not found at $BRIDGE_SCRIPT"
    exit 1
fi

SESSION_ID=${SESSION_ID:-"test-session-$(date +%s | cut -c 6-10)"}
DELAY=1
CLI="claude"   # claude | codex | gemini

usage() {
    echo "DevIsland Test CLI - 훅 호출을 편하게 테스트하세요"
    echo ""
    echo "사용법:"
    echo "  $0                          # 대화형 모드 (기본: Claude Code)"
    echo "  $0 --cli codex              # 대화형 모드 (Codex CLI)"
    echo "  $0 --cli gemini             # 대화형 모드 (Gemini CLI)"
    echo ""
    echo "단일 이벤트 전송:"
    echo "  $0 [옵션] start             # 세션 시작 (Claude Code)"
    echo "  $0 [옵션] bash [command]    # Bash 명령 승인 요청 (Claude Code)"
    echo "  $0 [옵션] write [path]      # 파일 쓰기 승인 요청 (Claude Code)"
    echo "  $0 [옵션] idle              # 입력 대기 알림"
    echo "  $0 [옵션] finish            # 작업 완료 알림"
    echo "  $0 [옵션] stop              # 세션 종료"
    echo "  $0 [옵션] codex-tool [name] # Codex PreToolUse 시뮬레이션"
    echo "  $0 [옵션] gemini-tool [name]# Gemini BeforeTool 시뮬레이션"
    echo ""
    echo "옵션:"
    echo "  --cli claude|codex|gemini   # CLI 종류 선택 (기본: claude)"
    echo "  -n, --no-delay              # 5초 대기 없이 즉시 실행"
    echo "  SESSION_ID=abc $0 ...       # 커스텀 세션 ID 지정"
    exit 1
}

# Safer JSON construction using Python
make_json() {
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

send_event() {
    local payload="$1"
    local cli="${2:-$CLI}"

    if [ "$DELAY" -eq 1 ]; then
        printf "⏳ 5초 후 실행합니다... "
        for i in {5..1}; do
            printf "%s " "$i"
            sleep 1
        done
        printf "\n"
    fi

    if command -v jq >/dev/null 2>&1; then
        printf "==> Sending [%s]: %s\n" "$cli" "$(printf "%s" "$payload" | jq -c .)"
    else
        printf "==> Sending [%s]: %s\n" "$cli" "$payload"
    fi

    local response
    response=$(printf "%s" "$payload" | "$BRIDGE_SCRIPT" --source "$cli")

    printf "==> Response: %s\n" "$response"

    # CLI별 응답 포맷 파싱
    case "$cli" in
        gemini)
            if printf "%s" "$response" | grep -q '"decision":[[:space:]]*"allow"'; then
                echo "✅ ALLOWED"
            elif printf "%s" "$response" | grep -q '"decision":[[:space:]]*"deny"'; then
                echo "❌ DENIED"
            elif [ -z "$response" ] || printf "%s" "$response" | grep -qE '^\{\}?$|^\s*$'; then
                echo "⏭️  PASS (To Terminal)"
            else
                echo "ℹ️  CONTINUE"
            fi
            ;;
        codex)
            # PermissionRequest와 PreToolUse 두 형식을 모두 체크
            if printf "%s" "$response" | grep -q '"behavior":[[:space:]]*"allow"' || printf "%s" "$response" | grep -q '"permissionDecision":[[:space:]]*"allow"'; then
                echo "✅ ALLOWED"
            elif printf "%s" "$response" | grep -q '"behavior":[[:space:]]*"deny"' || printf "%s" "$response" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
                echo "❌ DENIED"
            elif [ -z "$response" ] || printf "%s" "$response" | grep -qE '^\{\}?$|^\s*$'; then
                echo "⏭️  PASS (To Terminal)"
            else
                echo "ℹ️  CONTINUE"
            fi
            ;;
        *)
            # Claude Code
            if printf "%s" "$response" | grep -q '"behavior":[[:space:]]*"allow"'; then
                echo "✅ APPROVED"
            elif printf "%s" "$response" | grep -q '"behavior":[[:space:]]*"deny"'; then
                echo "❌ DENIED"
            elif [ -z "$response" ] || printf "%s" "$response" | grep -qE '^\{\}?$|^\s*$'; then
                echo "⏭️  PASS (To Terminal)"
            else
                echo "ℹ️  CONTINUE (Passive Event)"
            fi
            ;;
    esac
    echo ""
}

# ── Claude Code 이벤트 빌더 ──────────────────────────────────────────────

make_claude_permission() {
    local tool="$1"
    local tool_input="$2"
    make_json hook_event_name PermissionRequest session_id "$SESSION_ID" \
        tool_name "$tool" tool_input "$tool_input"
}

# ── Codex CLI 이벤트 빌더 ────────────────────────────────────────────────

make_codex_event() {
    local event="${1:-PreToolUse}"
    local tool="$2"
    local tool_input="$3"
    make_json hook_event_name "$event" session_id "$SESSION_ID" \
        tool_name "$tool" tool_input "$tool_input" cwd "$(pwd)"
}

# ── Gemini CLI 이벤트 빌더 ──────────────────────────────────────────────

make_gemini_event() {
    local event="${1:-onToolCall}"
    local tool="$2"
    local tool_input="$3"
    make_json event "$event" session_id "$SESSION_ID" \
        tool_name "$tool" tool_input "$tool_input" cwd "$(pwd)"
}

# ── 대화형 모드 ─────────────────────────────────────────────────────────

interactive_claude() {
    echo "🤖 Claude Code 훅 테스트"
    echo "Session ID: $SESSION_ID"
    echo "----------------------------"
    send_event "$(make_json hook_event_name SessionStart session_id "$SESSION_ID")" claude

    while true; do
        echo "무엇을 테스트하시겠습니까?"
        echo "1) 일반 Bash 명령 (ls -la)"
        echo "2) 위험한 Bash 명령 (rm -rf /)"
        echo "3) 파일 쓰기 (test.txt)"
        echo "4) 파일 읽기 (AppState.swift)"
        echo "5) 커스텀 알림 (Notification)"
        echo "6) 입력 대기 알림 (idle_prompt)"
        echo "7) 작업 완료 알림 (Stop)"
        echo "8) 세션 종료 (SessionEnd)"
        echo "d) 5초 지연 모드 토글 (현재: $([ "$DELAY" -eq 1 ] && echo "ON" || echo "OFF"))"
        echo "q) 그냥 종료"
        read -p "선택: " choice
        case "$choice" in
            1)
                input=$(make_json command "ls -la" description "파일 목록 보기")
                send_event "$(make_claude_permission bash "$input")" claude ;;
            2)
                input=$(make_json command "rm -rf /" description "전체 파일 삭제 (위험!)")
                send_event "$(make_claude_permission bash "$input")" claude ;;
            3)
                input=$(make_json file_path "test.txt" content "Hello DevIsland!")
                send_event "$(make_claude_permission write "$input")" claude ;;
            4)
                input=$(make_json file_path "DevIsland/AppState.swift")
                send_event "$(make_claude_permission read "$input")" claude ;;
            5)
                read -p "알림 메시지: " msg
                send_event "$(make_json hook_event_name Notification session_id "$SESSION_ID" message "$msg")" claude ;;
            6)
                send_event "$(make_json hook_event_name Notification session_id "$SESSION_ID" notification_type idle_prompt message "클로드가 다음 입력을 기다리고 있습니다.")" claude ;;
            7)
                send_event "$(make_json hook_event_name Stop session_id "$SESSION_ID" message "작업이 모두 완료되었습니다.")" claude ;;
            8)
                send_event "$(make_json hook_event_name SessionEnd session_id "$SESSION_ID")" claude
                break ;;
            d|D)
                if [ "$DELAY" -eq 1 ]; then DELAY=0; else DELAY=1; fi
                echo "지연 모드가 $([ "$DELAY" -eq 1 ] && echo "켜졌습니다" || echo "꺼졌습니다")." ;;
            q|Q) echo "Bye!"; exit 0 ;;
            *) echo "잘못된 선택입니다." ;;
        esac
    done
}

interactive_codex() {
    echo "📦 Codex CLI 훅 테스트"
    echo "Session ID: $SESSION_ID"
    echo "----------------------------"
    send_event "$(make_json event SessionStart session_id "$SESSION_ID")" codex

    while true; do
        echo "무엇을 테스트하시겠습니까?"
        echo "1) PreToolUse (조회성 - 알림)"
        echo "2) PreToolUse (위험 - 승인 폴백)"
        echo "3) apply_patch (PreToolUse)"
        echo "4) 커스텀 질문 (Notification)"
        echo "5) 툴 완료 (PostToolUse)"
        echo "6) 작업 완료 알림 (Stop)"
        echo "7) 승인 요청 (PermissionRequest - 권장)"
        echo "8) 세션 종료 (SessionEnd)"
        echo "d) 5초 지연 모드 토글 (현재: $([ "$DELAY" -eq 1 ] && echo "ON" || echo "OFF"))"
        echo "q) 종료"
        read -p "선택: " choice
        case "$choice" in
            1)
                input=$(make_json command "ls -la")
                send_event "$(make_codex_event PreToolUse shell "$input")" codex ;;
            2)
                input=$(make_json command "rm -rf /")
                send_event "$(make_codex_event PreToolUse shell "$input")" codex ;;
            3)
                input=$(make_json path "src/main.py" patch "- old line\n+ new line")
                send_event "$(make_codex_event PreToolUse apply_patch "$input")" codex ;;
            4)
                read -p "질문 메시지: " msg
                send_event "$(make_json hook_event_name Notification session_id "$SESSION_ID" message "$msg")" codex ;;
            5)
                send_event "$(make_json hook_event_name PostToolUse session_id "$SESSION_ID")" codex ;;
            6)
                send_event "$(make_json hook_event_name Stop session_id "$SESSION_ID" message "작업이 완료되었습니다.")" codex ;;
            7)
                read -p "도구 이름: " tool
                read -p "도구 입력: " input
                send_event "$(make_codex_event PermissionRequest "$tool" "$input")" codex ;;
            8)
                send_event "$(make_json hook_event_name SessionEnd session_id "$SESSION_ID")" codex
                break ;;
            d|D)
                if [ "$DELAY" -eq 1 ]; then DELAY=0; else DELAY=1; fi
                echo "지연 모드가 $([ "$DELAY" -eq 1 ] && echo "켜졌습니다" || echo "꺼졌습니다")." ;;
            q|Q) echo "Bye!"; exit 0 ;;
            *) echo "잘못된 선택입니다." ;;
        esac
    done
}

interactive_gemini() {
    echo "✨ Gemini CLI 훅 테스트"
    echo "Session ID: $SESSION_ID"
    echo "----------------------------"
    send_event "$(make_gemini_event SessionStart)" gemini

    while true; do
        echo "무엇을 테스트하시겠습니까?"
        echo "1) run_shell_command (ls -la)"
        echo "2) 위험한 run_shell_command (rm -rf /)"
        echo "3) write_file (test.txt)"
        echo "4) read_file (README.md)"
        echo "5) 커스텀 질문 (Notification)"
        echo "6) 작업 완료 알림 (AfterAgent)"
        echo "7) 세션 종료 (SessionEnd)"
        echo "d) 5초 지연 모드 토글 (현재: $([ "$DELAY" -eq 1 ] && echo "ON" || echo "OFF"))"
        echo "q) 종료"
        read -p "선택: " choice
        case "$choice" in
            1)
                input=$(make_json command "ls -la")
                send_event "$(make_gemini_event BeforeTool run_shell_command "$input")" gemini ;;
            2)
                input=$(make_json command "rm -rf /")
                send_event "$(make_gemini_event BeforeTool run_shell_command "$input")" gemini ;;
            3)
                input=$(make_json path "test.txt" content "Hello from Gemini!")
                send_event "$(make_gemini_event BeforeTool write_file "$input")" gemini ;;
            4)
                input=$(make_json path "README.md")
                send_event "$(make_gemini_event BeforeTool read_file "$input")" gemini ;;
            5)
                read -p "질문 메시지: " msg
                send_event "$(make_json event BeforeTool session_id "$SESSION_ID" message "$msg")" gemini ;;
            6)
                send_event "$(make_gemini_event AfterAgent)" gemini ;;
            7)
                send_event "$(make_gemini_event SessionEnd)" gemini
                break ;;
            d|D)
                if [ "$DELAY" -eq 1 ]; then DELAY=0; else DELAY=1; fi
                echo "지연 모드가 $([ "$DELAY" -eq 1 ] && echo "켜졌습니다" || echo "꺼졌습니다")." ;;
            q|Q) echo "Bye!"; exit 0 ;;
            *) echo "잘못된 선택입니다." ;;
        esac
    done
}

# ── 옵션 파싱 ────────────────────────────────────────────────────────────

while [[ "$1" =~ ^- ]]; do
    case "$1" in
        --cli)
            shift
            case "$1" in
                claude|codex|gemini) CLI="$1" ;;
                *) echo "Error: --cli 값은 claude, codex, gemini 중 하나여야 합니다."; exit 1 ;;
            esac
            shift ;;
        -n|--no-delay)
            DELAY=0; shift ;;
        -d|--delay)
            DELAY=1; shift ;;
        *) usage ;;
    esac
done

COMMAND=$1
shift || true

# ── 명령 실행 ────────────────────────────────────────────────────────────

if [ -z "$COMMAND" ]; then
    case "$CLI" in
        codex)  interactive_codex ;;
        gemini) interactive_gemini ;;
        *)      interactive_claude ;;
    esac
    exit 0
fi

case "$COMMAND" in
    # ── Claude Code 이벤트 ──────────────────────────────────────────────
    start)
        send_event "$(make_json hook_event_name SessionStart session_id "$SESSION_ID")" claude ;;
    bash)
        CMD=${1:-"ls -la"}
        input=$(make_json command "$CMD")
        send_event "$(make_claude_permission bash "$input")" claude ;;
    write)
        FILE=${1:-"test.txt"}
        CONTENT=${2:-"Hello World"}
        input=$(make_json file_path "$FILE" content "$CONTENT")
        send_event "$(make_claude_permission write "$input")" claude ;;
    notification)
        MSG=${1:-"Hello from CLI"}
        send_event "$(make_json hook_event_name Notification session_id "$SESSION_ID" message "$MSG")" claude ;;
    idle)
        send_event "$(make_json hook_event_name Notification session_id "$SESSION_ID" notification_type idle_prompt message "입력을 기다리는 중...")" claude ;;
    finish)
        send_event "$(make_json hook_event_name Stop session_id "$SESSION_ID" message "완료되었습니다.")" claude ;;
    stop)
        send_event "$(make_json hook_event_name SessionEnd session_id "$SESSION_ID")" claude ;;

    # ── Codex CLI 이벤트 ────────────────────────────────────────────────
    codex-tool)
        TOOL=${1:-"shell"}
        CMD=${2:-"ls -la"}
        input=$(make_json command "$CMD")
        send_event "$(make_codex_event PreToolUse "$TOOL" "$input")" codex ;;

    # ── Gemini CLI 이벤트 ───────────────────────────────────────────────
    gemini-tool)
        TOOL=${1:-"run_shell_command"}
        CMD=${2:-"ls -la"}
        input=$(make_json command "$CMD")
        send_event "$(make_gemini_event onToolCall "$TOOL" "$input")" gemini ;;

    *) usage ;;
esac
