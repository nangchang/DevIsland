# DevIsland 테스트 커버리지·적절성 검토

- 작성일: 2026-06-12
- 측정 방법: `xcodebuild test -enableCodeCoverage YES` 실측 (`main` 21af169, 테스트 전체 통과, 테스트 실행 약 32초)
- 관련 문서: [project-review-and-roadmap.md](project-review-and-roadmap.md) §4, [refactoring-plan.md](refactoring-plan.md) Track R0

---

## 1. 핵심 수치

| 지표 | 값 |
|---|---|
| 전체 라인 커버리지 | **41.9%** (10,920 / 26,055) |
| UI·L10n·창 코드 제외 로직 커버리지 | **66.9%** (8,466 / 12,646) |
| 테스트 파일 / 테스트 함수 | 30개 / 401개 |
| 테스트 스위트 실행 시간 | 약 32초 (빌드 제외) — 빠른 편 |
| `Thread.sleep` 사용 | 2곳 (양호 — 대부분 폴링 `waitUntil` 헬퍼 사용) |

전체 41.9%라는 숫자는 실태보다 나쁘게 보인다. `Localizable.swift`(함수 386개, 9.3%)와 SwiftUI 뷰 파일들이 분모의 절반을 차지하기 때문이다. **로직 계층만 보면 66.9%로, 핵심 도메인은 상당히 잘 커버되어 있다.** 문제는 평균이 아니라 분포다 — 아래에서 보듯 커버리지가 얇은 곳이 하필 보안 임계 코드와 겹친다.

## 2. 영역별 커버리지

### 잘 커버된 영역 (현 상태 유지)

| 파일 | 커버리지 | 평가 |
|---|---|---|
| 플러그인 시스템 (PluginHost 91%, Runner·EventProcessor·EventFactory 100%, built-in 4종 89~99%) | ★ | 최근 작성된 코드답게 설계 단계부터 테스트 동반. safemode·probation·mid-drain 경합까지 결정론적으로 검증 — **프로젝트의 모범 사례** |
| `AppState.swift` 75% | ★ | `handleMessage` 호출 83회로 파싱→분류→응답을 end-to-end 검증, 응답 JSON 문자열 직접 단언 56회 (사실상 미니 golden test) |
| `PTYCoordinator` 95%, `PTYSessionBuffer` 100% | ★ | 슬라이딩 윈도우 청크 경계 매칭까지 검증 |
| `SQLiteApprovalStore` 85% | ○ | DB 파일 권한(0600) 검증 테스트까지 존재. 단, v1→v5 마이그레이션 경로는 최신 스키마 생성만 확인 |
| `ProviderAdapter` 93%, `HookEventHandler` 89%(간접), `HookEventNormalizer` 98%, `IPCProtocol` 97% | ○ | provider 응답 형식 보존이라는 핵심 계약을 잘 방어 |
| `SessionStore` 95%, `SettingsStore` 82%, `ToolMessageFormatter` 85% | ○ | |

### 사각지대 — 보안·신뢰 임계 코드 (P1)

**커버리지 밀도가 위험도와 역전되어 있다.** 가장 위험한 코드가 가장 얇다:

| 파일 | 커버리지 | 누락된 것 |
|---|---|---|
| `HookSocketServer.swift` | **2.4%** | IPC 진입점 전체가 무테스트. 4바이트 길이 프레이밍, raw/framed 판별(첫 바이트 peek), 부분 수신, 1MB 초과 페이로드 거부, Unix 소켓 권한·stale 소켓 처리 — 전부 루프백 실소켓으로 테스트 가능한 순수 프로토콜 로직 |
| `BridgeTokenManager.swift` | **0%** | grace mode 진입/이탈, reload, 불일치 거부 — 검토 보고서 S2·S3의 핵심인데 단위 테스트가 하나도 없다 |
| `ApprovalPolicyEngine.swift` | 71% | 테스트 6개뿐. **`glob`·`regex` matchKind는 테스트 0개** (exact·commandPrefix·pathPrefix만 존재). regex 비anchored 매칭(S6), `FNM_PATHNAME` 의미, 5단계 우선순위 전조합, 200자 패턴 제한이 모두 미검증 |
| `ToolKnowledge.swift` | 58% (테스트 3개) | `autoApproveSafeTools` 자동 승인이 이 위험도 분류표에 의존하는데 분류 자체의 회귀 방어가 없다 |
| `TerminalFocuser.swift` | 20% (테스트 1개) | `normalizedAppName`만 테스트. AppleScript 생성(이스케이프 포함)·tmux 인자 조립은 순수 함수로 추출하면 테스트 가능하나 현재 private |
| `UpdateChecker.swift` | 24% | 버전 비교 `isNewer`조차 테스트 0 — 잘못되면 업데이트 무한 제안/누락 |

### 사각지대 — 타이머·시간 의존 동작 (P2)

승인 타임아웃 자동 pass(`startTimeout` → `sendDecision(passToTerminal: true)`)와 알림 자동 접힘 타이머는 **사용자 신뢰에 직결되는 동작인데 테스트가 없다** (플러그인 timeout 테스트만 존재). 현재 `Timer.scheduledTimer` + 0.1초 폴링 구조라 테스트하기 어렵다 — 리팩토링 계획 R3의 `CountdownTimer` 통합 시 시간 주입(clock injection)을 함께 설계해야 한다.

### 사각지대 — UI 로직 (P3)

SwiftUI 뷰 0%대는 예상 범위지만, 뷰 파일 안에 **추출 가능한 순수 로직**이 섞여 있다:

- `MarkdownView.swift` 0% — diff 렌더링, 링크/이미지 안전성 처리 등 파싱 로직 포함 (마크다운 렌더링 스킬 문서가 명시하는 책임)
- `NotchWindowController.swift` 50% — 스크린 선정·노치 좌표 계산은 순수 계산 (리팩토링 R4의 `ScreenTargeting` 추출 시 테스트 동반)
- `SessionMessageWindow` 0.7%, `NotchComponents` 4.4%, `SettingsWindow` 0%

## 3. 브리지 스크립트 (Swift 외부)

| 대상 | 상태 |
|---|---|
| `scripts/test_devisland_bridge.py` (28개 테스트) | 이벤트 정규화·passive 필터·`final_output` 포맷·매니페스트 동기화는 잘 커버. **그러나 `_parse_response`(framed/legacy/fail-closed 분기), `fallback_decision`(fail-open 정책), `send_to_app`(transport 폴백)은 테스트 0** — 브리지에서 가장 중요한 안전장치가 미검증 |
| CI 연결 | **없음** — 이 테스트는 어떤 워크플로우에서도 실행되지 않는다 (검토 보고서 T1) |
| `devisland-bridge.sh` (267줄) | 테스트 0. 터미널 감지 분기(iTerm/Terminal/cmux/Ghostty/Warp/VSCode/ClaudeDesktop)와 tmux 폴백이 전부 무방비 |
| `devisland_pty.py` | 테스트 0 |

## 4. 테스트 적절성 평가 (숫자 너머)

### 잘 하고 있는 것

1. **행동 기반 검증**: AppStateTests가 내부 상태가 아니라 `handleMessage` → 응답 JSON이라는 외부 계약을 단언한다. 리팩토링 내성이 높은 올바른 방향.
2. **의존성 주입 활용**: 격리된 `UserDefaults(suiteName:)` + `frontmostCheck` 클로저 mock으로 AppleScript 의존성을 끊었다.
3. **비동기 처리 규율**: 고정 sleep 대신 폴링 `waitUntil` 헬퍼, `Thread.sleep`은 2곳뿐. 최근 커밋(f3aa6fa)에서 mid-drain 테스트를 결정론적으로 고친 것도 좋은 신호.
4. **회귀 테스트 문화**: 버그 수정 시 "Before the fix …" 주석과 함께 재현 테스트를 남긴다 (예: `testRestoredSessionPreservesPersistedStartTime`).

### 문제 패턴

1. **전역 싱글톤 오염**: AppStateTests의 노치 확장 테스트 4종이 `SettingsStore.shared.settings`를 직접 변경한다. 테스트 호스트가 실제 앱(`DevIsland Dev`)이므로 **개발자의 로컬 dev 앱 설정(UserDefaults.standard)이 테스트 실행으로 바뀐다.** 더 나쁜 것은 복원 방식 — `defer { …expandOnTaskCompletion = true }`처럼 원래 값이 아닌 *가정된 기본값*으로 복원해, 사용자가 false로 써두었다면 테스트가 설정을 영구히 뒤집는다. → AppState에 SettingsStore(또는 설정 스냅샷)를 주입하는 구조 변경 필요 (리팩토링 R2와 연계).
2. **모놀리식 테스트 파일**: AppStateTests 2,318줄/66개 테스트에 분류·큐·PTY·리플레이·UI 확장이 혼재 (리팩토링 계획 R6에서 분할 예정).
3. **negative/abuse 케이스 부족**: 비정상 입력(깨진 UTF-8, 초과 페이로드, 잘못된 framing, 위조 토큰)에 대한 테스트가 거의 없다. 승인 게이트는 정상 경로보다 **악의적·비정상 경로의 방어가 본질**이다.
4. **간접 커버리지 의존**: `HookEventHandler`·`GeminiSessionState`·`ClaudePromptPolicy` 등은 AppStateTests를 통해서만 커버된다. 동작은 검증되지만, 실패 시 원인 위치가 흐려지고 AppState 리팩토링 때 함께 흔들린다.

## 5. 권고 — 테스트 백로그

### P1 (보안 하드닝 v0.12와 같은 구간에서, 코드 수정 전 회귀 방어용)

| # | 항목 | 비고 |
|---|---|---|
| 1 | `ApprovalPolicyEngine` 매칭 매트릭스 테스트: matchKind 5종 × allow/deny × 우선순위 5단계 조합, regex anchoring 케이스, glob `FNM_PATHNAME` 의미, 200자 제한 | S6 수정(anchored regex)과 한 PR — 수정 전 현재 동작 고정 → 수정 → 기대 동작 갱신 |
| 2 | `HookSocketServer` 프로토콜 테스트: 루프백 실소켓으로 framed/raw 판별, 부분 수신, 초과 페이로드 거부, Unix 소켓 권한·stale 소켓, **루프백 외 인터페이스 접속 거부**(S1 수정 검증) | S1·S2 수정의 머지 게이트 |
| 3 | `BridgeTokenManager` 단위 테스트: grace mode, reload, 불일치 거부, 파일 생성 실패 시 동작 | 임시 디렉토리 주입 가능하도록 `tokenURL` 주입 변경 필요 (소규모) |
| 4 | Python transport 테스트: 가짜 서버 소켓으로 `_parse_response`의 framed/legacy/fail-closed 3분기, `fallback_decision`, UDS→TCP 폴백 | CI 연결(T1)과 한 PR |
| 5 | golden response 스냅샷 테스트 | 리팩토링 R0와 동일 항목 — 이 문서의 P1 전체가 R0의 구체화다 |

### P2 (리팩토링 트랙과 연계)

- 승인 타임아웃 자동 pass·알림 자동 접힘 테스트 — R3 `CountdownTimer`에 clock 주입을 설계하면서 작성
- `ToolKnowledge` 위험도 분류표 스냅샷 테스트 (분류 변경이 diff에 드러나게)
- `UpdateChecker.isNewer` 버전 비교 테스트 (`1.0.0-dev` vs `1.0.0`, 자릿수 차이 등)
- AppStateTests의 `SettingsStore.shared` 직접 조작 제거 — 설정 주입으로 전환하고 저장/복원 헬퍼 도입
- `devisland-bridge.sh` 스모크 테스트: 고정 환경변수 + osascript stub(PATH 조작)으로 terminal 감지 분기 검증

### P3

- `MarkdownView` 로직(diff 파싱, 링크 안전성)을 뷰에서 분리해 단위 테스트
- `NotchWindowController` 스크린 계산 테스트 (R4 `ScreenTargeting` 추출과 동반)
- SQLite 마이그레이션 경로 테스트: v1~v4 스키마 fixture DB를 만들어 v5 마이그레이션 후 데이터 보존 검증
- AppStateTests 분할 (R6)

### CI 커버리지 게이트 방식 (권고)

전체 % 게이트(예: "40% 이상")는 이 코드베이스에서 무의미하다 — UI·L10n이 분모를 지배하고, 새 뷰 파일 하나가 수치를 떨어뜨린다. 대신:

1. **임계 파일 목록 게이트**: `Bridge/`, `Approval/`, `Provider/` 디렉토리는 파일별 최소 커버리지(제안: 80%)를 CI에서 검증 (`xccov view --report --json` 파싱 스크립트)
2. **로직 커버리지 지표 추적**: UI·L10n 제외 수치(현재 66.9%)를 PR 코멘트로 리포트해 추세만 관찰
3. 신규 코드는 플러그인 시스템 수준(90%+)을 기본 기대치로

---

## 6. 결론

테스트 스위트의 **품질(행동 기반, DI, 비동기 규율)은 좋고, 양(로직 66.9%)도 준수하다.** 결함은 배치다: 플러그인처럼 새로 설계된 저위험 영역은 90~100%인 반면, 승인 게이트의 신뢰가 실제로 걸려 있는 IPC 진입점·토큰 검증·정책 매칭·타임아웃 동작이 0~71%에 머문다. 위 P1 다섯 항목은 전부 기술 로드맵 v0.12(보안 하드닝)·리팩토링 R0(안전망)와 같은 작업 단위로 묶이므로, 별도 트랙이 아니라 **해당 PR들의 머지 조건**으로 편입하는 것을 권고한다.
