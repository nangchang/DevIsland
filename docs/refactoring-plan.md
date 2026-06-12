# DevIsland 코드 구조 개선·리팩토링 계획

- 작성일: 2026-06-12
- 기준 커밋: `main` (21af169, v0.11.1-dev)
- 선행 문서: [project-review-and-roadmap.md](project-review-and-roadmap.md) — 본 계획은 검토 보고서 §3(A2 등)에서 식별한 구조 문제의 실행 계획이다.

---

## 1. 목표와 원칙

### 목표

1. `AppState`(2,591줄) god object를 책임 단위로 분해해 변경 비용을 낮춘다.
2. `DispatchQueue` + `MainActor.assumeIsolated` + Combine + Task가 섞인 동시성 모델을 `@MainActor` 중심으로 통일해 크래시·레이스 위험을 없앤다.
3. 반복되는 데이터 묶음(터미널 메타데이터 7필드)과 하드코딩 JSON 응답 문자열을 타입으로 승격해 중복을 제거한다.
4. 1,000줄대 UI 파일을 분할해 노치/설정 작업의 리뷰 단위를 줄인다.
5. 같은 기능이 두 언어로 중복 구현된 곳(브리지 설치: Swift vs bash/python)을 단일화한다.

### 원칙 (모든 PR에 적용)

- **행동 불변(behavior-preserving)**: 리팩토링 PR은 provider 응답 JSON, 승인 흐름, UI 동작을 바꾸지 않는다. 기능 변경과 리팩토링을 한 PR에 섞지 않는다.
- **작은 PR**: 한 PR은 하나의 추출/이동만 수행한다. 파일 이동과 로직 변경을 분리한다.
- **테스트 우선**: 추출 대상에 테스트가 없으면 **현재 동작을 고정하는 테스트를 먼저 추가**한 뒤 리팩토링한다 (특히 Phase R0의 golden response 테스트).
- **보안 PR과 분리**: 검토 보고서의 v0.12 보안 하드닝(S1~S4)을 먼저 머지한다. 보안 수정이 리팩토링 위에서 충돌하지 않도록 순서를 고정한다.
- 매 PR 후 `./scripts/run-tests.sh` 통과 + `docs/agent/*` 구현 계획서 진행 현황 갱신.

---

## 2. 현재 구조 진단

### 2.1 레이어 현황

```text
[현재]                                  [목표]
Bridge ── HookSocketServer              Bridge ── HookSocketServer (transport별 분리)
            │                                       │
            ▼                                       ▼
AppState (2,591줄)                      HookEventRouter        ← 이벤트 분류 (순수 로직)
  · 이벤트 분류 Phase 1~4                 ApprovalFlowCoordinator ← pending queue·결정·타임아웃
  · pending queue 관리                    NotchPresentationModel  ← 노치 표시 상태 (@Published)
  · 승인 결정·타임아웃                     AppState (조립 전용)    ← 위 컴포넌트 소유·배선
  · 노치 표시 상태                                  │
  · Caffeine/플러그인 배선                          ▼
            │                            SessionStore / ReplayRecorder / PTYCoordinator (유지)
            ▼
SessionStore / ReplayRecorder / …
```

### 2.2 정량 근거 (smell 인벤토리)

| # | Smell | 근거 (grep 실측) |
|---|---|---|
| 1 | AppState god object | 2,591줄. 이벤트 분류·큐·결정·표시 상태·Caffeine 배선이 한 클래스 |
| 2 | 터미널 메타데이터 튜플 중복 | `terminalTmuxSocket:` 파라미터가 비테스트 코드 24곳. `ActiveSession` 7필드, `ParsedHookEvent` 7필드, `PendingItem` 6필드, `updateActiveSession` 파라미터 20+개, `FrontmostCheck` 클로저 파라미터 7개 |
| 3 | JSON 응답 문자열 하드코딩 | `"{\"response\": \"approved\"}"` 류 문자열 27곳 (AppState에만 25곳) |
| 4 | 표시 상태 리셋 블록 중복 | `claudeQuestionState.reset()` 9회, `isShowingRequest = false` 8회 — 동일한 8줄 리셋 블록이 stop/supersede/dismiss/showNext에 반복 |
| 5 | `MainActor.assumeIsolated` 산재 | AppState에만 18회. 비메인 접근 시 즉시 크래시하는 가정이 코드 전체에 분산 |
| 6 | 브리지 설치 로직 이중화 | `DevIslandApp.swift` 내 Swift installer ~500줄(`patchClaudeSettings`/`patchCodexHooks`/`patchGeminiSettings`)이 `scripts/install-bridge.sh`의 Python 패치 로직과 같은 일을 별도 구현 |
| 7 | 거대 UI 파일 | `SettingsWindow.swift` 1,307줄(전 탭 단일 파일), `NotchView.swift` 1,061줄(NotchView struct 하나가 588줄), `NotchWindowController.swift` 803줄(윈도우 + 스크린 타겟팅 + AX 풀스크린 감지) |
| 8 | 로깅 | `print()` 87곳, `os.Logger` 0곳 |
| 9 | UserDefaults 키 분산 | AppState가 `"claudeSessionApprovalMode"` 등 키 문자열을 직접 읽음 (SettingsStore.DefaultsKey 우회) |
| 10 | 거대 테스트 파일 | `AppStateTests.swift` 2,318줄 단일 파일 |
| 11 | 타이머 로직 중복 | `startTimeout`/`startNotificationAutoCollapseTimer`가 같은 0.1초 폴링 카운트다운 패턴을 별도 구현 |

---

## 3. 리팩토링 트랙

의존 관계 순서대로 트랙을 나눈다. **R0 → R1 → R2 → R3**은 순차, **R4·R5·R6**은 R1 이후 병렬 가능.

### Track R0. 안전망 구축 (리팩토링 전 필수)

행동 불변을 기계적으로 검증할 장치를 먼저 만든다.

- **Golden response 테스트**: 대표 훅 시나리오(승인/거부/pass/notification/stop/question × claude/codex/gemini)에 대해 `handleMessage` → 최종 응답 JSON 문자열을 스냅샷으로 고정. 리팩토링 중 응답이 1바이트라도 바뀌면 실패하게 한다. 기존 `AppStateTests`·`ProviderAdapterTests`가 부분 커버하지만, **분류 Phase 1~4 전체를 통과하는 end-to-end 케이스**를 명시적으로 추가한다.
- CI에 Python 브리지 테스트(`scripts/test_devisland_bridge.py`)와 shellcheck 연결 (검토 보고서 T1·T3와 동일 항목 — 리팩토링 안전망을 겸한다).

검증: 새 테스트가 현재 `main`에서 green인지 확인 후 머지.

> R0의 구체적 테스트 항목(정책 엔진 매칭 매트릭스, 소켓 프로토콜, 토큰 매니저, Python transport)은 [test-coverage-review.md](test-coverage-review.md) §5 P1 백로그로 상세화되어 있다.

### Track R1. 도메인 모델 타입화 (저위험·고효과 — 가장 먼저)

**R1-a. `TerminalIdentity` 도입**

```swift
struct TerminalIdentity: Equatable, Codable {
    var app: String        // "iTerm", "Terminal", …
    var title: String
    var tty: String
    var windowId: String
    var tabIndex: String
    var tmux: TmuxIdentity?  // pane, socket, client
}
```

적용 대상: `ParsedHookEvent`, `ActiveSession`, `PendingItem`, `SessionStore.updateActiveSession`(파라미터 20+개 → 핵심 5~6개), `AppState.FrontmostCheck`(7개 클로저 파라미터 → 1개), `TerminalFocuser.isSessionFrontmost`/`focusTerminal`(8개 → 1개).

기계적 변경이지만 영향 범위가 24곳+테스트라 **두 PR로 분할**: (1) 타입 추가 + `ParsedHookEvent`/`SessionStore` 적용, (2) `TerminalFocuser`/`AppState` 콜백 적용.

**R1-b. `HookResponse` 타입 도입**

```swift
enum HookDecision: String { case approved, denied, pass }
struct HookResponse {  // "{\"response\":\"approved\"}" 등 27곳 대체
    var decision: HookDecision
    var reason: String?
    var approvalScope: RuleScope?
    var toolInput: [String: AnyJSON]?
    func jsonString() -> String
}
```

`responseHandler: (String) -> Void` 시그니처는 유지하고 호출부만 `HookResponse(...).jsonString()`으로 교체해 IPC 계약을 건드리지 않는다. 검토 보고서 A5(invalid pending에 approved 응답)의 수정도 이 타입 도입 후 한 줄 변경이 된다.

검증: R0 golden 테스트 + 기존 401개 테스트 무변경 통과.

### Track R2. AppState 분해

원칙: **로직을 새 타입으로 옮기되 AppState의 public API는 유지**(UI가 `AppState.shared.approve()` 등을 계속 호출). 한 PR에 한 컴포넌트만 추출.

**R2-a. `HookEventRouter` 추출 (분류 로직 — 순수 함수화)**

`handleParsedEvent`의 Phase 2b 분류(stop/notification/approval/question/interactive/bypass 판정, `isApprovalEvent`, `shouldSupersedeCodexSessionsOnStart` 등)를 입력(`ParsedHookEvent`, 설정 스냅샷) → 출력(`RoutedHookEvent` enum) 순수 타입으로 추출한다. 부수효과(응답 전송, 세션 갱신)는 AppState에 남긴다.

효과: 분류 로직이 처음으로 **UI·소켓 없이 단위 테스트 가능**해진다. AppStateTests의 분류 관련 케이스를 RouterTests로 이전.

**R2-b. `ApprovalDisplayState` 추출 (리셋 블록 중복 제거)**

`currentResponseHandler`/`currentSessionId`/`currentToolName`/`currentEventName`/`currentMessage`/`currentRawToolName`/`currentAgentKind`/`currentWorkspaceRoot`/`currentHookEventId`/`isShowingRequest`/`showingRequestId`를 하나의 구조체로 묶고, 9곳에 반복되는 리셋 블록을 `displayState.clear()` 하나로 대체한다.

**R2-c. `ApprovalFlowCoordinator` 추출**

pending queue 진입(`enqueueManualRequest`), 표시 선정(`showNextRequest`/`nextPendingRequestToDisplay`/preempt), 결정 전송(`sendDecision`), 타임아웃을 묶어 이동. `SessionStore`·`ReplayRecorder`는 주입받는다. AppState는 이 coordinator를 소유하고 위임만 한다.

**R2-d. Caffeine/플러그인 배선 이동**

`setupCaffeine()`과 plugin 이벤트 배선을 `AppState.init`에서 별도 `AppWiring`(또는 `AppDelegate`)으로 이동해 init을 50줄 이하로 줄인다.

목표 결과: AppState ≤ 600줄, 추출된 각 타입 ≤ 400줄.

검증: 각 PR마다 golden 테스트 + AppStateTests 통과. 추출된 타입의 신규 단위 테스트 추가.

### Track R3. 동시성 모델 통일

R2로 타입이 작아진 뒤에 수행해야 변경 면적이 작다.

1. `NotchPresentationModel`(R2-b 결과물)과 `ApprovalFlowCoordinator`를 `@MainActor`로 선언.
2. `AppState` 전체를 `@MainActor`로 선언하고, 비메인 진입점을 두 곳으로 한정:
   - `HookSocketServer` 콜백 → 이미 `DispatchQueue.main.async`로 hop하므로 `Task { @MainActor … }`로 교체
   - `isTerminalFrontmostAsync`/AppleScript → `Task.detached` + `await MainActor.run` 복귀
3. `MainActor.assumeIsolated` 18곳 제거 — `@MainActor` 격리가 컴파일 타임에 보장하므로 런타임 트랩 가정이 사라진다.
4. `Timer.scheduledTimer` 2종을 공용 `CountdownTimer`(async 스트림 기반) 헬퍼로 통합 (smell #11).
5. 완료 후 `SWIFT_STRICT_CONCURRENCY = targeted` → `complete`를 단계적으로 적용해 회귀를 컴파일러가 잡게 한다.

검증: 전체 테스트 + 수동 스모크(승인/거부/타임아웃/포커스 bypass/노치 확장·축소). 스레드 새니타이저(TSan) 1회 실행.

### Track R4. UI 레이어 분할 (R1 이후 병렬 가능)

행동 변화 없는 **파일 분할 위주**라 위험이 낮다. 단, `project.yml`이 디렉토리 재귀 포함이므로 파일 추가 후 `xcodegen generate`만 필요.

| 대상 | 분할안 |
|---|---|
| `SettingsWindow.swift` (1,307줄) | `Settings/Panes/` 디렉토리에 탭별 파일(General/Island/Approval/Sound/Integrations/Advanced) + `HostedWindowController.swift` 분리 |
| `NotchView.swift` (1,061줄) | `NotchCollapsedView`, `NotchExpandedView`(본체), `NotchResizeHandles`(3종 NSViewRepresentable), `MessageMouseDownMonitor` 4파일로 분리. NotchView struct(588줄) 내부는 header/approval/session-list 서브뷰로 추출 |
| `NotchWindowController.swift` (803줄) | 스크린 선정·AX 풀스크린 감지(`targetScreen`/`frontmostApplicationIsFullScreen` 등 ~250줄)를 `ScreenTargeting` enum으로 추출 — 이 로직은 순수 계산이 많아 추출 시 테스트 가능 |
| `DevIslandApp.swift` (743줄) | §R5에서 installer 추출 후 자연히 ~200줄로 축소 |

### Track R5. 브리지 설치 로직 단일화

현재 Claude/Codex/Gemini 훅 설정 패치 로직이 **두 곳**에 있다:

- `scripts/install-bridge.sh` 내 inline Python 3블록
- `DevIslandApp.swift` 내 Swift 구현(`patchClaudeSettings` 등, ~500줄)

훅 이벤트 목록이 바뀔 때마다 두 구현을 같이 고쳐야 하며, 이미 `hook_events.json` 매니페스트가 "단일 소스" 역할로 도입돼 있으므로 설치 로직도 같은 방향으로 정리한다.

1. **R5-a**: Swift installer를 `Core/BridgeInstaller.swift`로 추출 (파일 이동만, DevIslandApp 분량 축소).
2. **R5-b**: `BridgeInstaller`가 등록할 이벤트 목록을 `hook_events.json`에서 읽도록 변경 (현재 하드코딩).
3. **R5-c**: `install-bridge.sh`의 inline Python을 별도 `scripts/install_hooks.py`로 추출하고 동일하게 매니페스트를 읽게 한 뒤, 앱 내 installer가 장기적으로 이 스크립트를 호출할지(단일 구현) 아니면 Swift 구현을 유지할지 결정한다. **권고: 앱이 번들된 `install_hooks.py`를 호출하는 단일 구현** — 셸 설치 경로와 앱 내 설치 경로가 완전히 같은 코드를 타게 된다.

검증: 설치 → `~/.claude/settings.json`/`~/.codex/hooks.json`/`~/.gemini/settings.json` diff가 리팩토링 전후 동일함을 fixture 테스트로 확인 (기존 `test_devisland_bridge.py`에 케이스 추가).

### Track R6. 크로스커팅 정리 (상시 병행)

| 항목 | 내용 |
|---|---|
| 로깅 | `print()` 87곳 → `os.Logger` 카테고리별(`bridge`, `approval`, `ui`, `plugin`) 전환. 페이로드는 `.private` 마킹 — 검토 보고서 S4·Q1과 한 작업으로 처리 |
| UserDefaults 키 | AppState의 직접 키 문자열 접근을 `SettingsStore.DefaultsKey` 경유로 통일. 장기적으로 설정 읽기는 `SettingsStore.shared.settings` 스냅샷만 사용 |
| L10n | `Localizable.swift`(560줄) → String Catalog 이전. 기계적 대량 변경이므로 별도 PR, 다른 리팩토링과 절대 혼합 금지 |
| 테스트 분할 | `AppStateTests.swift`(2,318줄)를 R2 추출 단위에 맞춰 RouterTests/ApprovalFlowTests/DisplayStateTests로 분할 — R2 각 PR에 동반 |
| 정적 분석 | SwiftLint 도입(우선 `file_length`, `type_body_length`, `function_parameter_count` 룰) — 이 계획의 회귀(파일 재비대화)를 CI가 막게 한다 |

---

## 4. PR 시퀀스 요약

| 순서 | PR | 트랙 | 크기 | 선행 조건 |
|---|---|---|---|---|
| 1 | golden response 테스트 추가 | R0 | S | 보안 v0.12 머지 후 |
| 2 | CI에 python 테스트·shellcheck 연결 | R0 | S | — |
| 3 | `TerminalIdentity` 타입 + ParsedHookEvent/SessionStore 적용 | R1-a | M | 1 |
| 4 | `TerminalIdentity` TerminalFocuser/AppState 적용 | R1-a | M | 3 |
| 5 | `HookResponse` 타입화 (27곳 교체) | R1-b | M | 1 |
| 6 | `HookEventRouter` 추출 + RouterTests | R2-a | L | 5 |
| 7 | `ApprovalDisplayState` 추출 (리셋 블록 통합) | R2-b | M | 6 |
| 8 | `ApprovalFlowCoordinator` 추출 | R2-c | L | 7 |
| 9 | Caffeine/플러그인 배선 이동 | R2-d | S | 8 |
| 10 | `@MainActor` 통일 + assumeIsolated 제거 | R3 | L | 9 |
| 11 | `CountdownTimer` 통합 | R3 | S | 10 |
| 12 | strict concurrency 단계 상향 | R3 | M | 10 |
| 13~16 | UI 파일 분할 4건 (각각 독립 PR) | R4 | M×4 | 3 이후 아무 때나 |
| 17 | `BridgeInstaller` 추출 | R5-a | M | — |
| 18 | 매니페스트 기반 설치 + 스크립트 단일화 | R5-b/c | L | 17, 2 |
| 상시 | os.Logger·키 일원화·L10n·SwiftLint | R6 | S~L | 항목별 독립 |

크기 기준: S ≤ 150줄 diff, M ≤ 500줄, L ≤ 1,000줄 (테스트 포함).

예상 기간: 주당 2~3 PR 페이스로 약 6~8주. 검토 보고서 로드맵과의 매핑 — R0·R1은 v0.12 직후, R2·R3은 v0.13 "Performance & Platform"의 일부, R4~R6은 v0.13~v0.15에 분산.

---

## 5. 리스크와 가드레일

| 리스크 | 가드레일 |
|---|---|
| 리팩토링 중 provider 응답 변형 | R0 golden 테스트가 모든 PR의 머지 게이트. 응답 문자열 비교는 키 정렬 후 바이트 동등성 |
| `@MainActor` 전환 시 데드락/순서 변경 | R3는 R2 완료 후에만 시작. 전환 PR은 한 타입씩. TSan 1회 + 수동 스모크 체크리스트(`plugin-architecture-implementation-plan.md` §9 재사용) |
| 대량 기계적 변경(R1, L10n)과 기능 PR 충돌 | 기계적 변경 PR은 작성 후 24시간 내 머지하는 것을 원칙으로 하고, 열려 있는 기능 브랜치가 적은 시점에 수행 |
| UI 파일 분할 후 xcodeproj 불일치 | 분할 PR 체크리스트에 `xcodegen generate` + `verify-build` 포함 (워크트리 규칙과 동일) |
| 두 설치 구현 단일화 중 사용자 설정 파괴 | R5는 fixture 기반 before/after diff 테스트를 먼저 추가. 설치 스크립트는 항상 `.bak` 백업 유지 |

### 중단 기준

다음이 발생하면 해당 트랙을 멈추고 계획을 재검토한다.

- golden 테스트가 의도하지 않은 diff를 보이는데 원인을 한 PR 안에서 설명할 수 없는 경우
- R2 추출 과정에서 `PendingRequest.responseHandler` 호출 시점이 기존과 달라져야만 하는 경우 (승인 흐름의 의미 변경 — 리팩토링 범위 밖)
- R3에서 `HookSocketServer`나 bridge script의 수정이 필요해지는 경우

---

## 6. 완료 정의 (Definition of Done)

- [ ] AppState ≤ 600줄, 단일 파일 1,000줄 초과 소스 0개 (SQLiteApprovalStore 제외 — DAO 특성상 허용)
- [ ] `MainActor.assumeIsolated` 사용 0곳
- [ ] 하드코딩 `{"response": …}` 문자열 0곳 (테스트 제외)
- [ ] 터미널 메타데이터가 `TerminalIdentity` 단일 타입으로만 전달
- [ ] 훅 설치 로직 단일 구현 (매니페스트 기반)
- [ ] `print()` 0곳, `os.Logger` 카테고리 4종 운영
- [ ] SwiftLint CI 게이트 (file_length 등 구조 룰)
- [ ] `docs/agent/*` 아키텍처 문서가 분해된 구조를 반영
