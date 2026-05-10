# Approval Proxy 설계 및 구현 계획

> 상태: 설계 확정 초안  
> 작성일: 2026-05-09  
> 범위: Claude Code / Codex 중심, 기존 Gemini 흐름과 호환  
> 목적: DevIsland가 향후 설정창, 정책 엔진, 고급 Hook 응답, 통신 프로토콜 개선 작업에서 계속 참조할 기준 문서

## 1. 목표

DevIsland를 단순 승인 UI에서 **Approval Proxy**로 확장한다.

핵심 기능은 다음과 같다.

- 현재 요청 승인 / 거부
- 세션 동안 승인
- 영구 승인 정책 관리
- 사용자 질문 전달 및 응답 처리
- 정책 기반 자동 승인 / 자동 거부
- Hook 이벤트 및 결정 replay log
- 외부 UI 기반 approval workflow
- PTY 기반 상호작용 보조 처리(후순위, optional)
- bridge와 app 간 IPC 프로토콜 안정화

## 2. 기존 구조와 설계 방향

현재 DevIsland는 이미 Approval Proxy의 기본 골격을 갖고 있다.

```text
AI CLI Hook
  -> scripts/devisland-bridge.sh
  -> scripts/devisland_bridge.py
  -> TCP 127.0.0.1:9090
  -> HookSocketServer
  -> AppState.handleMessage()
  -> Notch UI decision
  -> bridge provider-specific JSON output
```

따라서 별도 Node.js/Tauri daemon을 먼저 추가하지 않고, **Swift macOS app 자체를 Approval Proxy daemon + UI로 확장**한다.

권장 모듈 경계:

```text
DevIsland macOS app
  ├─ HookSocketServer / future HookIPCServer
  ├─ ApprovalProxyController
  ├─ ProviderAdapter
  │   ├─ ClaudeAdapter
  │   ├─ CodexAdapter
  │   └─ GeminiAdapter
  ├─ HookEventNormalizer
  ├─ PolicyEngine
  ├─ SQLiteApprovalStore
  ├─ SessionApprovalCache
  ├─ EventReplayLog
  ├─ QuestionBroker
  ├─ AppSettings / SettingsStore
  └─ SwiftUI Settings / Rules / Replay windows
```

Python bridge는 계속 ultra-thin으로 유지한다.

Bridge가 해야 할 일:

- stdin payload 수신
- terminal metadata 및 cli_source 부여
- app으로 envelope 전송
- app 응답을 provider별 hook response로 출력

Bridge가 하지 말아야 할 일:

- DB 접근
- UI 렌더링
- 정책 계산
- PTY 처리
- 장시간 background task

## 3. 설정창 분리

Approval Proxy 설정 항목이 많아지므로 menubar menu는 빠른 상태 확인과 긴급 조작만 담당하고, 세부 설정은 별도 창으로 분리한다.

### 3.1 Menubar menu 역할

남길 항목:

- pending request 요약
- Focus Terminal
- Approve / Deny 단축 액션
- Settings…
- Approval Rules…
- Replay Log…
- Install / Repair Hooks…
- About / Quit

제거 또는 이동할 항목:

- 노치 표시 위치
- 요청 표시 위치
- global auto-approve tool 관리
- session auto-approve tool 관리
- provider별 advanced option
- IPC/Bridge option
- replay retention / debug option

### 3.2 Settings window 구조

```text
Settings
  ├─ General
  ├─ Display
  ├─ Approval
  ├─ Providers
  │   ├─ Claude Code
  │   ├─ Codex
  │   └─ Gemini
  ├─ Bridge / IPC
  └─ Experimental / PTY

Separate windows
  ├─ Approval Rules
  └─ Replay Log
```

### 3.3 설정 저장 원칙

| 데이터 | 저장소 | 이유 |
|---|---|---|
| display 위치, window 동작 | UserDefaults | 단순 preference |
| provider feature toggle | UserDefaults 또는 SQLite settings table | UI 설정이며 export/import 필요 시 SQLite |
| approval rules | SQLite | 검색, transaction, 동시 hook race 대응 |
| session cache | SQLite | Codex session approval 안정성 |
| replay log | SQLite | append/query/retention 필요 |
| bridge token | Keychain 또는 chmod 600 file | 보안 민감 |
| PTY transcript | SQLite 또는 rotating file | 크기 관리 필요 |

## 4. Claude Code 설계

Claude는 native hook 기능을 가장 적극적으로 활용한다.

### 4.1 사용할 이벤트

| 이벤트 | 목적 |
|---|---|
| PermissionRequest | 승인/거부/세션 승인/영구 승인 |
| PreToolUse | AskUserQuestion, ExitPlanMode, input rewrite, defer 처리 |
| Elicitation | MCP server 입력 요청 처리 |
| UserPromptSubmit | prompt policy 적용 |
| PostToolUse | replay log, audit, optional context |

### 4.2 Claude 세션 승인 모드 옵션

요구사항: **Claude의 “세션 동안 승인”을 native 기능으로 처리할지, DevIsland 앱 내부 cache로 처리할지 선택 가능해야 한다.**

Settings > Providers > Claude Code에 다음 옵션을 추가한다.

```text
Claude Session Approval Mode
  (•) Native Claude permissions, recommended
  ( ) DevIsland-managed session cache
  ( ) Hybrid: native first, app cache fallback
```

#### Option A. Native Claude permissions, recommended

동작:

1. 사용자가 “세션 동안 승인”을 선택한다.
2. DevIsland가 현재 요청의 tool/pattern에 맞는 permission rule을 만든다.
3. Claude `PermissionRequest` 응답에 `updatedPermissions`를 포함한다.
4. `destination`은 `session`을 사용한다.
5. Claude가 같은 세션에서 해당 rule을 native로 적용한다.

응답 예시:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow",
      "updatedPermissions": [
        {
          "type": "addRules",
          "rules": [
            {
              "toolName": "Bash",
              "ruleContent": "npm test"
            }
          ],
          "behavior": "allow",
          "destination": "session"
        }
      ]
    }
  }
}
```

장점:

- Claude의 permission engine과 UI 상태가 일치한다.
- 같은 세션 내 반복 요청이 Claude 내부에서 줄어든다.
- DevIsland가 재시작되어도 Claude session permission이 유지될 수 있다(Claude session lifetime 내).

주의:

- Claude의 deny/ask rule은 여전히 평가된다. Hook이 allow를 반환해도 matching deny rule을 override하지 않는다.
- `updatedPermissions` entry에는 `type`, `rules`, `behavior`, `destination`을 정확히 포함해야 한다.
- `destination: session`은 in-memory이며 세션 종료 시 폐기된다.

#### Option B. DevIsland-managed session cache

동작:

1. 사용자가 “세션 동안 승인”을 선택한다.
2. DevIsland가 SQLite `session_cache`에 provider/session/tool/pattern/action을 저장한다.
3. 이후 같은 session_id 요청이 오면 DevIsland가 자동 allow를 반환한다.
4. Claude에는 단순 allow 응답만 보낸다.

응답 예시:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
```

장점:

- Codex와 같은 내부 정책 흐름을 재사용할 수 있다.
- Claude native permission mutation을 원하지 않는 사용자에게 안전한 옵션을 제공한다.
- DevIsland replay log와 policy engine의 결과를 단일 source of truth로 유지하기 쉽다.

단점:

- Claude 자체 permission 상태와 DevIsland cache가 다를 수 있다.
- DevIsland가 종료되거나 hook bridge 연결이 실패하면 session approval UX가 끊길 수 있다.

#### Option C. Hybrid

동작:

1. 기본적으로 native `updatedPermissions(destination: session)`를 사용한다.
2. 동시에 DevIsland `session_cache`에도 같은 rule을 저장한다.
3. native 응답 생성 실패, Claude payload에 rule suggestion 정보가 부족한 경우, 또는 설정상 native 적용이 비활성화된 provider state에서는 app cache를 fallback으로 사용한다.

장점:

- Claude와 DevIsland 양쪽 상태를 모두 활용한다.
- 구현 중 migration과 debugging에 유리하다.

단점:

- 중복 상태 관리가 필요하다.
- replay log에 native/app cache 중 어느 쪽이 실제 결정을 만들었는지 명확히 기록해야 한다.

권장 기본값: **Native Claude permissions**

### 4.3 Claude 영구 승인

Claude 영구 승인도 설정으로 destination을 선택 가능하게 한다.

```text
Claude Persistent Approval Destination
  ( ) localSettings      .claude/settings.local.json
  ( ) projectSettings    .claude/settings.json
  (•) userSettings       ~/.claude/settings.json
```

단, projectSettings는 repo에 commit될 수 있으므로 UI에서 warning을 표시한다.

### 4.4 Claude AskUserQuestion / Elicitation

`AskUserQuestion`과 `ExitPlanMode`는 `PreToolUse`에서 처리한다.

- `AskUserQuestion`: 질문 UI를 표시하고 `updatedInput.answers`를 포함해 allow.
- `ExitPlanMode`: plan approval UI를 표시하고 필요 시 `updatedInput`으로 승인 내용을 반영.
- non-interactive mode에서는 `defer` 지원을 옵션으로 둔다.

`AskUserQuestion` 응답은 원본 `questions` 배열을 보존하고 `answers` object를 추가해야 한다.

## 5. Codex 설계

Codex는 native session permission mutation이 없다고 가정하고 DevIsland cache 중심으로 처리한다.

### 5.1 사용할 이벤트

| 이벤트 | 목적 |
|---|---|
| PermissionRequest | 승인/거부/session cache/persistent rule |
| PreToolUse | 상태 추적, replay log, policy preview |
| PostToolUse | replay log |
| SessionStart | session lifecycle |
| Stop | session cleanup |
| UserPromptSubmit | 지원 확인 후 prompt policy |

### 5.2 Codex 세션 승인

```text
PermissionRequest
  -> normalize event
  -> explicit deny check
  -> persistent allow check
  -> session_cache check
  -> heuristic policy
  -> UI prompt
  -> session approval 선택 시 SQLite session_cache insert
  -> current request allow
```

### 5.3 Codex 영구 승인

우선 DevIsland SQLite `rules`를 source of truth로 한다.

중기 이후 Codex 외부 rule/config sync는 `CodexRuleSyncAdapter`로 분리한다.

## 6. Policy Engine

### 6.1 우선순위

```text
1. provider hard deny / unsupported state
2. explicit persistent deny
3. explicit session deny
4. explicit persistent allow
5. explicit session allow
6. project/workspace rule
7. heuristic policy
8. fallback policy
```

### 6.2 Rule model

```swift
struct ApprovalRule: Identifiable, Codable {
    var id: UUID
    var provider: ProviderKind        // claude, codex, gemini, any
    var toolName: String
    var matchKind: MatchKind          // exact, glob, regex, commandPrefix, pathPrefix
    var pattern: String
    var action: RuleAction            // allow, deny, prompt
    var scope: RuleScope              // once, session, persistent
    var riskFloor: ToolRiskLevel?
    var workspaceRoot: String?
    var createdAt: Date
    var expiresAt: Date?
    var enabled: Bool
}
```

### 6.3 Regex 안전성

기본 UI에서는 exact, commandPrefix, pathPrefix, glob을 우선 제공한다.

Regex는 advanced mode에서만 제공하고 다음 검증을 적용한다.

- 최대 길이 제한
- catastrophic backtracking 위험 패턴 차단
- 저장 전 compile validation
- UI에서 advanced warning 표시

## 7. SQLite 상태 관리

DB 위치:

```text
~/Library/Application Support/DevIsland/approval-proxy.sqlite3
```

PRAGMA:

```sql
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;
```

주요 테이블:

```text
rules
session_cache
hook_events
approval_decisions
pty_messages
settings(optional)
```

`session_cache`는 provider, session_id, tool_name, pattern, action, expires_at index를 가져야 한다.

`hook_events`와 `approval_decisions`는 replay log의 source of truth가 된다.

## 8. Bridge/App 통신 방식

### 8.1 현재 방식

현재는 bridge가 매 hook마다 TCP `127.0.0.1:9090`에 연결하고, JSON을 전송한 뒤 응답을 받는다.

```text
bridge process
  -> TCP connect 127.0.0.1:9090
  -> send JSON
  -> shutdown write
  -> recv until EOF
  -> provider-specific stdout
```

이 방식은 단순하고 현재 규모에서는 충분히 빠르다. 실제 latency에서 큰 비용은 socket보다 hook process spawn, shell metadata collection, Python interpreter startup일 가능성이 높다.

### 8.2 단기 개선 계획: TCP 유지 + protocol v1

단기에는 TCP를 유지하되 다음을 추가한다.

- protocol envelope
- requestId
- auth token
- length-prefixed framing
- rich response
- risk-based transport failure fallback
- backward compatibility for raw JSON payload

Envelope 예시:

```json
{
  "protocol": "dev-island-hook-ipc",
  "version": 1,
  "requestId": "uuid",
  "sentAt": "2026-05-09T12:34:56Z",
  "token": "redacted",
  "source": "codex",
  "payload": {
    "hook_event_name": "PermissionRequest",
    "session_id": "...",
    "tool_name": "shell",
    "tool_input": {}
  }
}
```

Framing:

```text
4-byte big-endian payload length
UTF-8 JSON bytes
```

Rich response 예시:

```json
{
  "protocol": "dev-island-hook-ipc",
  "version": 1,
  "requestId": "same uuid",
  "status": "ok",
  "decision": "approved",
  "reason": "matched session rule",
  "providerOutput": {
    "hookSpecificOutput": {
      "hookEventName": "PermissionRequest",
      "decision": {
        "behavior": "allow"
      }
    }
  }
}
```

Bridge 출력 원칙:

1. `providerOutput`이 있으면 그대로 stdout에 출력한다.
2. 없으면 legacy `response` 값을 기존 방식으로 provider-specific response로 변환한다.
3. transport failure 시 risk-based fallback을 적용한다.

Fallback 기본값:

| risk | transport/app failure |
|---|---|
| safe/read-only | pass 또는 allow 가능 |
| low/medium | prompt 불가 시 deny 권장 |
| high/write | deny |
| critical/shell/destructive | deny |
| unknown | deny 기본, user override 가능 |

### 8.3 중기 계획: Unix Domain Socket 기본화

중기에는 Unix domain socket을 기본 transport로 바꾼다.

```text
~/Library/Application Support/DevIsland/dev-island.sock
```

장점:

- TCP port collision 제거
- local IPC 목적에 더 적합
- parent directory chmod 700 + socket file 권한으로 접근 제어 가능
- token과 조합해 이중 방어 가능
- loopback TCP보다 효율적

전환 전략:

1. `BridgeTransport` abstraction 추가.
2. TCP transport를 compatibility mode로 유지.
3. Unix domain socket transport 추가.
4. Settings > Bridge / IPC에서 transport 선택 가능하게 한다.
5. app은 UDS listen 실패 시 TCP fallback 가능.
6. bridge는 config 파일에서 transport를 읽고, UDS 실패 시 설정에 따라 TCP fallback.

Bridge config 예시:

```json
{
  "version": 1,
  "transport": "unix",
  "socketPath": "/Users/me/Library/Application Support/DevIsland/dev-island.sock",
  "tcpHost": "127.0.0.1",
  "tcpPort": 9090,
  "connectTimeoutSeconds": 5,
  "responseTimeoutSeconds": 300,
  "tokenPath": "/Users/me/Library/Application Support/DevIsland/bridge-token",
  "fallbackToTcp": true
}
```

비추천 transport:

- FIFO/named pipe: 동시 request/response 처리와 cleanup이 복잡하다.
- XPC: macOS native이지만 Python bridge 연동과 packaging/signing 복잡도가 높다.
- persistent helper: 아직 병목 증거가 없으며 process가 하나 더 늘어난다.

## 9. App 내부 성능 계획

`HookSocketServer`는 payload 수신 후 바로 main queue로 넘기는 현재 구조를 갖고 있다. Approval Proxy 구현 시 JSON normalize, token validation, SQLite write, policy lookup은 background queue에서 처리한다.

권장 흐름:

```text
IPC server
  -> IPCQueue
     -> decode envelope
     -> validate token
     -> normalize event
     -> insert hook_events
     -> policy lookup
     -> immediate decision? respond directly
     -> needs UI? dispatch to main queue pending queue
```

UI main queue에는 실제 UI 갱신이 필요한 요청만 전달한다.

## 10. 구현 단계

진행 원칙:

- 각 Phase 작업을 시작하거나 완료할 때 이 섹션의 `상태`와 체크리스트를 같은 변경 안에서 갱신한다.
- 코드만 먼저 진행하지 않는다. Approval Proxy는 장기 설계 문서가 기준이므로, 구현 상태와 문서 상태가 어긋나면 다음 작업자가 잘못된 우선순위를 잡기 쉽다.
- 부분 구현은 `🔧 진행 중`으로 표시하고, 완료된 하위 항목은 체크된 bullet로 남긴다.

### Phase 1. 문서화 및 설정창 기반

> 상태: ✅ 완료

- 이 문서를 repository에 추가한다.
- Settings window scaffold 추가.
- menubar menu를 quick action 중심으로 축소한다.
- AppSettings / SettingsStore를 추가한다.
- Claude session approval mode 설정값을 추가한다.

### Phase 2. IPC protocol v1

> 상태: ✅ 완료

- [x] bridge envelope 추가.
- [x] app envelope parser 추가.
- [x] raw JSON backward compatibility 유지.
- [x] token 파일 생성/검증 추가.
- [x] length-prefixed framing 추가.
- [x] rich response 추가.
- [x] transport failure fallback 정책 추가.

### Phase 3. ApprovalProxyController / PolicyEngine

> 상태: ✅ 완료

- [x] AppState.handleMessage에서 provider/policy 책임 분리.
- [x] HookEventNormalizer 추가.
- [x] ProviderAdapter 추가.
- [x] ApprovalProxyController / PolicyEngine 추가.
- [x] SQLiteApprovalStore 추가.
- [x] session_cache / rules / replay log 테이블 추가.

### Phase 4. Claude advanced hooks

> 상태: 📅 예정

- Claude `PermissionRequest.updatedPermissions` 지원.
- Claude session approval mode: native/app/hybrid 지원.
- Claude persistent destination 설정 지원.
- `PreToolUse` AskUserQuestion / ExitPlanMode 처리.
- `Elicitation` 처리.
- `UserPromptSubmit` prompt policy 처리.

### Phase 5. Codex cache/rules

> 상태: 📅 예정

- Codex session cache 안정화.
- persistent rules UI 연결.
- optional Codex external rule sync adapter 설계/구현.

### Phase 6. Unix domain socket

> 상태: 📅 예정

- HookIPCServer transport abstraction.
- UDS listener 구현.
- bridge UDS client 구현.
- Settings > Bridge / IPC transport 선택.
- TCP fallback 유지.

### Phase 7. Replay / PTY

> 상태: 📅 예정

- Replay Log window 추가.
- event replay / rule creation from event 추가.
- PTY wrapper는 experimental로 분리해 optional 구현.

## 11. 우선 구현해야 할 설정값

```swift
enum ClaudeSessionApprovalMode: String, CaseIterable, Identifiable {
    case nativePermissions
    case appSessionCache
    case hybrid
}

enum ClaudePersistentApprovalDestination: String, CaseIterable, Identifiable {
    case localSettings
    case projectSettings
    case userSettings
}

enum BridgeTransportKind: String, CaseIterable, Identifiable {
    case tcpLoopback
    case unixDomainSocket
}
```

UserDefaults key 초안:

```text
claudeSessionApprovalMode
claudePersistentApprovalDestination
bridgeTransportKind
bridgeSocketPath
bridgeTcpPort
bridgeConnectTimeoutSeconds
bridgeResponseTimeoutSeconds
bridgeFallbackToTcp
approvalFallbackPolicy
replayRetentionDays
```

## 12. 검증 계획

문서 이후 구현 단계별로 다음 테스트를 추가한다.

- SettingsStore default/migration tests
- ClaudeAdapter updatedPermissions output tests
- Claude app-cache session approval output tests
- Codex session cache policy tests
- IPC envelope encode/decode tests
- legacy raw JSON compatibility tests
- token validation tests
- rich response bridge formatting tests
- timeout/fallback policy tests

기존 mandatory test command:

```bash
./scripts/run-tests.sh
```
