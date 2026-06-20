# DevIsland 전체 코드·문서 검토 보고서 및 발전 계획

- 작성일: 2026-06-12
- 검토 기준: `main` (21af169, v0.11.1-dev) 전체 소스, 스크립트, 문서, CI 워크플로우
- 검토 범위: Swift 소스 약 31,000줄(테스트 포함), 브리지 스크립트(bash/python), `docs/` 전체, GitHub Actions 5종

---

## 1. 총평

DevIsland는 **설계 문서의 품질과 코드의 일치도가 높은 편**이다. 특히 플러그인 아키텍처(격리, 권한 모델, safemode, contribution cache)는 설계 → 단계별 PR → 마이그레이션까지 일관되게 진행됐고, 401개의 단위 테스트가 핵심 로직(정책 엔진, IPC, 이벤트 정규화, 플러그인 디스패치)을 커버한다. 브리지의 fail-open 기본값, framed 응답 버전 불일치 시 fail-closed 처리, AppleScript 인자 이스케이프(Swift 측), Unix 소켓 0600 권한 등 의도적인 안전장치도 잘 갖춰져 있다.

반면 **승인 프록시라는 보안 도구의 성격에 비해 IPC 입구의 방어가 약하다.** TCP 리스너가 루프백으로 제한되지 않고, 레거시 raw JSON 경로는 토큰 검증을 우회하며, 민감한 훅 페이로드 전문이 world-readable한 `/tmp` 로그에 남는다. 또한 정책 평가용 SQLite 읽기가 메인 스레드에서 동기 실행되는 등 자체 안정성 기준(`stability-standards.md`)과 어긋나는 지점이 있다.

| 영역 | 평가 |
|---|---|
| 아키텍처 설계·문서화 | 우수 — 플러그인/승인 프록시 설계 문서가 실제 코드와 대체로 일치 |
| 테스트 | 양호 — Swift 401개 테스트. 단, Python/쉘 브리지는 CI 미연결 |
| 보안 | **보강 필요** — IPC 입구 인증·바인딩, 로그 민감정보, 업데이트 검증 |
| 안정성 | 양호하나 메인 스레드 DB 읽기 등 자체 기준 위반 지점 존재 |
| 문서 최신성 | 대체로 양호하나 4건의 불일치 발견 (§4) |

---

## 2. 문제점 — 보안 (우선순위 P1)

### S1. TCP 리스너가 모든 인터페이스에 바인딩됨

[HookSocketServer.swift:43](../DevIsland/Bridge/HookSocketServer.swift#L43)의 `startTCP`는 `NWParameters.tcp`로 `NWListener`를 만들 뿐 로컬 엔드포인트를 제한하지 않는다. NWListener의 기본 동작은 **모든 인터페이스(0.0.0.0) 바인딩**이므로, 같은 네트워크의 다른 기기가 9090 포트에 접속할 수 있다. 설정 enum 이름(`tcpLoopback`)과 문서(`approval-proxy.md`의 "TCP `127.0.0.1:9090`")는 루프백을 전제하지만 실제 바인딩은 그렇지 않다.

**권고**: `NWParameters`에 `requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: …)`를 지정하거나 `requiredInterfaceType = .loopback`을 설정. 단위 테스트로 외부 인터페이스 접속 거부를 검증.

### S2. 레거시 raw JSON 경로가 토큰 검증을 우회함

[HookEventHandler.swift:43-57](../DevIsland/Bridge/HookEventHandler.swift#L43)에서 토큰 검증은 IPC envelope으로 디코딩된 경우에만 수행된다. 첫 바이트가 `{`인 raw JSON은 **토큰 없이 그대로 처리**된다. S1과 결합하면 LAN의 공격자가 다음을 할 수 있다:

- 가짜 승인 요청을 노치에 띄워 사용자 피로/혼동 유발 (승인 스푸핑)
- 가짜 세션·알림 이벤트로 UI 및 SQLite 감사 로그 오염
- `PTYOutput` 이벤트 대량 전송으로 DB 팽창

**권고**: raw JSON 경로는 Unix 소켓(파일 권한으로 보호됨)에서만 허용하고 TCP에서는 차단하거나, 차기 버전에서 raw JSON 경로 자체를 deprecate. 최소한 토큰 파일이 존재할 때는 raw JSON도 거부해야 한다.

### S3. 토큰 grace mode의 영구화 위험

[BridgeTokenManager.swift:59-70](../DevIsland/Bridge/BridgeTokenManager.swift#L59) — 토큰 파일이 없으면 모든 요청을 수락한다. 전환기 편의용 설계인 것은 이해되나, `generateIfNeeded()`가 실패하면(디렉토리 생성 실패 등) 조용히 grace mode로 영구 잔류한다. 또한 비교가 상수 시간이 아니다(로컬 위협 모델에서는 경미).

**권고**: grace mode 동작 시 설정 화면/메뉴에 경고 상태 표시. 일정 버전 이후 grace mode 제거.

### S4. 민감 정보가 world-readable 로그에 평문 기록됨

- [devisland_bridge.py:352](../scripts/devisland_bridge.py#L352) `log(f"Raw Payload: {dump(payload)}")` — 훅 페이로드 전문(명령어, 파일 경로, 프롬프트 본문, 명령 인자 속 시크릿 가능)이 `/tmp/DevIsland.bridge.log`(기본 0644, 모든 로컬 사용자 읽기 가능)에 기록된다.
- [HookSocketServer.swift:326,394](../DevIsland/Bridge/HookSocketServer.swift#L394) `print("Received raw JSON/framed message: …")` — 앱도 페이로드 전문을 stdout에 출력하며, LaunchAgent 모드에서는 `/tmp/DevIsland.log`로 흘러간다.
- 두 로그 모두 **로테이션이 없어** 장기 실행 시 무한히 커진다.

**권고**: (1) 페이로드 전문 로깅을 디버그 플래그 뒤로 이동하고 기본은 이벤트명/세션ID 요약만 기록, (2) 로그 파일 위치를 `~/Library/Logs/DevIsland/`로 이동하고 0600 생성, (3) 크기 기반 로테이션 추가.

### S5. 자동 업데이트에 코드서명 검증이 없음

[UpdateChecker.swift](../DevIsland/Utility/UpdateChecker.swift)는 GitHub 릴리스 DMG를 내려받아 마운트 후 앱을 교체하지만, 다운로드 산출물의 **codesign/공증 검증 단계가 없다**. 릴리스 빌드 자체도 unsigned로 패키징된다(`build-and-test.md`: "xcodebuild archive unsigned"). HTTPS + GitHub가 1차 방어이긴 하나, 승인 게이트 역할을 하는 앱으로서는 공급망 방어가 더 필요하다.

**권고**: Developer ID 서명·공증 도입(릴리스 워크플로우에 시크릿 주입) 후, 업데이트 설치 전 `codesign --verify` + Team ID 고정 검증. 장기적으로 Sparkle(EdDSA 서명) 검토.

### S6. 기타 (낮음)

- **regex allow 규칙의 비anchored 매칭**: [ApprovalPolicyEngine.swift:81](../DevIsland/Approval/ApprovalPolicyEngine.swift#L81)이 `firstMatch`(부분 일치)를 사용하므로 `Read`라는 regex allow 규칙이 `ReadDangerousTool`에도 매치된다. allow 규칙은 전체 일치(`^…$` 암묵 적용)로 좁히는 편이 안전하다.
- **bash 브리지의 AppleScript 변수 보간**: [devisland-bridge.sh:91,161](../scripts/devisland-bridge.sh#L161) 등에서 `$CURRENT_TTY`, `$CMUX_WORKSPACE_ID`를 heredoc AppleScript 문자열에 직접 보간한다. Swift 측(`appleScriptLiteral`)과 달리 이스케이프가 없다. 환경변수 출처상 위험도는 낮지만 방어 일관성이 깨져 있다.
- **PTY transcript 평문 저장**: 명령 출력 전체가 `approval-proxy.sqlite3`에 저장된다. 보존기간 프루닝은 있으나, 설정 화면에 데이터 민감성 안내와 즉시 삭제 버튼이 있으면 좋다.

---

## 3. 문제점 — 안정성·성능·코드 품질 (P2)

### A1. 정책 평가 SQLite 읽기가 메인 스레드에서 동기 실행

[AppState.swift:1893](../DevIsland/Core/AppState.swift#L1893)의 `approvalProxy.evaluate(request)`는 `isTerminalFrontmostAsync` 완료 콜백(메인 큐) 안에서 동기 실행된다. `persistentCandidates`/`sessionDecision`은 SQLite 읽기이며 `busy_timeout=5000`이므로, 쓰기 경합 시 **메인 스레드가 최대 5초 블록**될 수 있다. 시작 시 `restoreOpenSessions`도 메인에서 동기 쿼리다. 이는 자체 문서 `stability-standards.md`("SQLite writes: use the serial approvalPersistenceQueue")의 정신과 어긋난다 — 쓰기는 큐를 타지만 읽기는 안 탄다.

**권고**: 정책 평가를 `approvalPersistenceQueue`(또는 별도 읽기 큐)로 옮기고 콜백으로 복귀. WAL이므로 읽기 동시성은 충분하다.

### A2. AppState의 비대함과 취약한 스레딩 모델

`AppState.swift`는 2,591줄로 socket 수명주기, 이벤트 분류, pending queue, 승인 흐름, 노치 표시 상태, Caffeine 배선까지 담는다. SessionStore/PTYCoordinator/ReplayRecorder 분리는 진행됐으나:

- 클래스가 `@MainActor`가 아니며, 대신 `MainActor.assumeIsolated`가 십수 곳에 산재한다. `assumeIsolated`는 메인 스레드가 아니면 **즉시 크래시**하므로, `AppState.shared`(lazy static)가 비메인에서 처음 접근되는 경로가 하나라도 생기면 런타임 트랩이 된다.
- `sendDecision`은 일부 상태를 동기 변경하고 일부는 `DispatchQueue.main.async`로 변경해, 호출 스레드에 따라 순서가 달라질 수 있다.

**권고**: 중기 과제로 `AppState`를 `@MainActor`로 선언하고 socket 진입점에서만 명시적 hop. 이벤트 분류 로직(Phase 1~4)을 별도 타입(예: `HookEventRouter`)으로 추출하면 파일 크기와 테스트 용이성이 동시에 개선된다.

### A3. 훅 1건당 브리지 오버헤드가 큼

매 훅 이벤트마다 `devisland-bridge.sh`가 (1) `tty`/`ps` 체인 탐색, (2) **iTerm/Terminal의 전체 창·탭·세션을 AppleScript로 열거**, (3) `python3` 인터프리터 기동을 수행한다. 탭이 많은 환경에서는 AppleScript 열거만으로 수백 ms가 걸릴 수 있고, `PostToolUse`처럼 빈번한 이벤트에 그대로 곱해진다.

**권고**: TTY → 터미널 메타데이터 결과를 TTY별 캐시 파일(예: `/tmp/devisland-meta-$TTY`, TTL 수십 초)로 저장해 세션 중 반복 조회를 제거. 장기적으로는 상주형 브리지 헬퍼(소켓 유지) 검토.

### A4. PTY 래퍼의 터미널 처리 한계

[devisland_pty.py](../scripts/devisland_pty.py)는 raw mode 설정(`tty.setraw`)과 창 크기 전파(`SIGWINCH`/`TIOCSWINSZ`)가 없어 풀스크린/인터랙티브 CLI에서 입력 echo·레이아웃이 깨질 수 있다. 또한 `select` 타임아웃 0.05초 폴링은 유휴 시에도 CPU를 소모한다(경미).

### A5. 큐 정리 시 자동 승인 응답

[AppState.swift:1779-1785](../DevIsland/Core/AppState.swift#L1779) `discardInvalidPendingRequests`는 유효하지 않다고 판단한 pending 요청에 `"approved"`를 응답한다. 분류 버그로 승인 이벤트가 잘못 "invalid" 판정되면 **조용히 승인**되는 경로다. `"pass"`(CLI 자체 프롬프트로 위임)가 더 안전한 기본값이다.

### Q1. 로깅 인프라 부재

`print()` 호출이 87곳, `os.Logger` 사용은 0곳이다. 레벨·카테고리·privacy 마킹이 없어 릴리스 빌드에서 로그 통제가 불가능하고, S4의 민감정보 문제와도 직결된다. → `os.Logger` + privacy 지정자(`\(x, privacy: .private)`) 전환 권고.

### Q2. 수제 로컬라이제이션

[Localizable.swift](../DevIsland/Utility/Localizable.swift) (560줄)는 en/ko 문자열을 하드코딩한 싱글톤이다. Xcode String Catalog(`.xcstrings`)로 이전하면 언어 추가·번역 검수·미번역 검출이 표준 도구로 해결된다.

### Q3. 잡동사니

- 저장소 루트에 `commit_msg.txt`(과거 커밋 메시지 임시 파일)가 커밋되어 있다 — 삭제 및 `.gitignore` 추가 대상.
- `AppState`가 `"claudeSessionApprovalMode"` 등 UserDefaults 키 문자열을 직접 읽는다(SettingsStore 우회) — 키 정의 일원화 필요.

---

## 4. 문제점 — 문서·테스트·CI (P3)

### 문서 불일치

| # | 문서 | 문제 |
|---|---|---|
| D1 | `CLAUDE.md` | "install-bridge.sh는 `/Volumes/data/Github/DevIsland/scripts`를 하드코딩" — 현재 코드는 `SCRIPT_DIR` 자동 탐지 + 앱 번들 폴백으로 동작하므로 설명이 낡았다 |
| D2 | `docs/agent/approval-proxy.md` | "8-priority rule evaluation"이라고 적었으나 실제 엔진은 5단계(persistent deny > session deny > persistent allow > session allow > prompt)다 |
| D3 | `docs/agent/plugin-architecture-implementation-plan.md` | 당시에는 "다음 단계: Migration Track M0"로 멈춰 있었으나 현재 문서는 OpenPeon, Caffeine, SessionStats, session surfaces, v1.3 settings schema/i18n 완료 상태로 갱신됨 |
| D4 | `README.md` | showcase 이미지가 `main` 브랜치 `Assets/showcase.png`를 참조하지만 저장소에 해당 파일이 없다 → 이미지 깨짐 |

추가로 `stability-standards.md`의 transport fallback 표는 모든 위험 등급이 "pass"라 표 형태의 의미가 없다 — 한 문장으로 줄이고 `approvalFallbackPolicy` opt-in만 설명하는 편이 명확하다.

### 테스트·CI 공백

> 커버리지 실측(전체 41.9%, 로직 66.9%)과 테스트 적절성의 상세 분석은 [test-coverage-review.md](test-coverage-review.md) 참고.

| # | 항목 | 내용 |
|---|---|---|
| T1 | Python 브리지 테스트 미연결 | `scripts/test_devisland_bridge.py`가 존재하지만 어떤 워크플로우에서도 실행되지 않는다. CI에 `python3 -m pytest`(또는 직접 실행) 스텝 추가 필요 |
| T2 | 쉘 브리지 무테스트 | `devisland-bridge.sh`(267줄, 터미널 감지 분기 다수)는 테스트가 전혀 없다. bats 또는 고정 환경변수 기반 스모크 테스트 권고 |
| T3 | 린트 부재 | SwiftLint/SwiftFormat, shellcheck, ruff 모두 미적용. CI에 shellcheck만 추가해도 브리지 안전성이 오른다 |
| T4 | main push 빌드 없음 | CI는 PR 트리거뿐이라 머지 직후 회귀는 nightly(최대 24시간 후)에야 발견된다 |

---

## 5. 잘 되어 있는 점 (유지할 것)

- **플러그인 아키텍처**: 격리 원칙(승인 흐름 불간섭, sanitized DTO, cached rendering), actor 기반 runner, safemode/probation, 권한↔capability 매핑이 설계 문서와 구현 모두에서 일관됨.
- **승인 응답 경로의 방어**: framed 요청에 unframed 응답이 오면 fail-closed(`devisland_bridge.py:_parse_response`), 의도적 fail-open 기본값의 근거가 코드 주석과 문서에 명시됨.
- **SQLite 운영**: WAL + busy_timeout + FULLMUTEX, deterministic rule ID, 보존기간 프루닝, 스키마 버전 관리.
- **TerminalFocuser**: AppleScript 인자 이스케이프, tmux 인자 배열 전달(쉘 미경유), 프로세스 타임아웃·SIGKILL 폴백.
- **문서 체계**: AGENTS.md 허브 + 주제별 `docs/agent/*` 분리, 에이전트 스킬(`.claude/skills`, `.codex/skills`) 이중 제공.
- **테스트 격리**: `run-tests.sh`의 분리된 DerivedData + `XCODE_RUNNING_UNIT_TESTS` 게이트.

---

## 6. 개선 권고 우선순위

| 순위 | 항목 | 난이도 | 효과 |
|---|---|---|---|
| 1 | S1 TCP 루프백 바인딩 제한 | 낮음 (수 줄) | 원격 공격면 제거 |
| 2 | S2 raw JSON 토큰 우회 차단 | 낮음 | 인증 우회 제거 |
| 3 | S4 로그 민감정보 축소 + 로테이션 | 낮음 | 정보 노출 제거 |
| 4 | A1 정책 평가 DB 읽기 비메인화 | 중간 | UI 멈춤 방지 |
| 5 | T1/T3 브리지 테스트 CI 연결 + shellcheck | 낮음 | 회귀 방지 |
| 6 | D1~D4 문서 동기화 | 낮음 | 에이전트/기여자 혼선 제거 |
| 7 | A5 invalid pending 응답을 pass로 변경 | 낮음 | 의도치 않은 승인 방지 |
| 8 | Q1 os.Logger 전환 | 중간 | S4와 시너지 |
| 9 | S5 서명·공증 + 업데이트 검증 | 높음 (인증서 필요) | 배포 신뢰 |
| 10 | A2 AppState @MainActor화·분해 | 높음 | 장기 유지보수성 |

---

## 7. 향후 발전 계획 (로드맵 제안)

> 이 절은 기술 부채·보안 중심의 로드맵이다. 신규 기능과 제품 방향은 [product-vision-and-roadmap.md](product-vision-and-roadmap.md)에서 별도로 다룬다.

### 7.1 단기 — v0.12 "Security Hardening" (2~4주)

목표: 승인 프록시로서의 신뢰 경계 확립.

- IPC 입구 하드닝: 루프백 바인딩(S1), TCP raw JSON 차단(S2), grace mode 경고 UI(S3)
- 로그 위생: 페이로드 전문 로깅 debug 게이트화, `~/Library/Logs` 이동, 로테이션(S4)
- `discardInvalidPendingRequests` 응답을 `pass`로 변경(A5)
- 남은 문서 불일치 동기화(D1, D4 등) + `stability-standards.md` fallback 표 정리. D3(플러그인 구현 계획)는 현재 완료 상태로 보정됨
- CI: Python 브리지 테스트 + shellcheck 추가(T1, T3), main push 빌드(T4)

### 7.2 중기 — v0.13~v0.15 "Performance & Platform" (1~2개월)

> 이 단계의 구조 개선 항목(A2 등)은 [refactoring-plan.md](refactoring-plan.md)에 PR 단위 실행 계획으로 상세화되어 있다.

- **브리지 성능**: TTY별 터미널 메타데이터 캐시로 훅당 osascript 호출 제거(A3). 측정 지표: PostToolUse 훅 왕복 시간 p95
- **메인 스레드 정리**: 정책 평가 읽기 큐 이동(A1), `AppState` `@MainActor` 선언 및 이벤트 라우터 추출(A2)
- **관측성**: `os.Logger` 전환(Q1) + 노치/설정에 브리지 상태 진단 뷰(최근 이벤트, 토큰 모드, transport)
- **플러그인 확장**: v1.1 session surface 슬롯(`notch.session.row`, `session.context-menu`, `session.message`)과 `approval.decided`는 완료됨. 남은 후보는 `notch.expanded.details`, session detail timeline/summary, collapsed notch exclusive region provider(선언형 교체)
- **로컬라이제이션**: String Catalog 이전(Q2), 언어 추가 기반 마련

### 7.3 장기 — v1.0 "Trusted Release" 및 v2

- **v1.0 조건**: Developer ID 서명·공증 릴리스, 업데이트 서명 검증(S5), grace mode 제거, raw JSON 레거시 경로 제거, 문서·코드 완전 동기화
- **플러그인 v2** (설계 문서 로드맵 준수): declarative preset → 외부 plugin runtime(worker process 격리) → signed plugin distribution. v1 built-in에서 검증된 capability만 단계적으로 개방
- **PTY 통합 강화**: raw mode/SIGWINCH 지원(A4), 또는 PTY 래퍼를 옵트인 실험 기능에서 정식 기능으로 승격할지 여부 결정
- **확장 검토 항목** (수요 검증 후): 추가 터미널(WezTerm, Alacritty/kitty — AppleScript 미지원이라 별도 전략 필요), 추가 CLI 에이전트 어댑터, 승인 통계 대시보드(`approval.decided` + `SessionStatsPlugin` 기반 확장)

### 7.4 로드맵 운영 원칙

- 보안 항목(S1~S5)은 기능 개발보다 우선한다 — 이 앱의 존재 이유가 "승인 게이트"이기 때문.
- 각 단계는 기존 원칙 유지: 브리지는 얇게, hook 응답 경로는 플러그인·UI와 격리, provider 의미론 보존.
- 문서 동기화는 코드 변경과 같은 PR에서 처리한다(AGENTS.md 커밋 가이드라인 7항 준수).

---

## 부록 A. 검토한 주요 파일

| 영역 | 파일 |
|---|---|
| IPC/브리지 | `HookSocketServer.swift`, `HookEventHandler.swift`, `IPCProtocol.swift`, `BridgeTokenManager.swift`, `devisland-bridge.sh`, `devisland_bridge.py`, `devisland_pty.py`, `install-bridge.sh` |
| 코어 | `AppState.swift`(전체), `DevIslandApp.swift`, `SessionStore` 연동부 |
| 승인 | `ApprovalPolicyEngine.swift`, `ApprovalProxyController.swift`, `SQLiteApprovalStore.swift`(부분) |
| 터미널 | `TerminalFocuser.swift`(전체) |
| 플러그인 | `PluginHost.swift`(부분), 설계·구현계획 문서 전체 |
| 기타 | `UpdateChecker.swift`, `Localizable.swift`, `AppRelocator.swift`, `project.yml` |
| 문서 | `README.md`, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `docs/agent/*` 8종 |
| CI | `ci.yml`, `release.yml`, `nightly.yml`, `codeql.yml`, `bump.yml` |

## 부록 B. 검토에서 제외/보류한 영역

- UI 레이어(`NotchView`, `NotchComponents`, `SettingsWindow` 등)는 구조 수준만 확인했고 뷰 로직 정밀 검토는 하지 않았다.
- OpenPeon CESP 오디오 경로와 Caffeine 모니터 구현은 테스트 존재 여부만 확인했다.
- `SQLiteApprovalStore`의 마이그레이션 v1→v5 경로는 정밀 검토하지 않았다.

이 영역들은 별도 검토가 필요하면 후속 작업으로 진행한다.
