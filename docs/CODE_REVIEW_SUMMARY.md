# 🏝️ DevIsland Code Review Summary (2026-05-15)

이 문서는 DevIsland 프로젝트의 현재 상태를 진단하고, 안정성과 유지보수성을 높이기 위한 기술적 검토 결과를 정리한 보고서입니다.

## 1. 핵심 진단 및 우선순위 (Action Plan)

가장 시급한 과제는 **"구조적 리팩토링보다 실제 사용자 장애(UI 프리징)로 이어질 수 있는 메인 스레드 블로킹 해소"**입니다.

| 우선순위 | 작업 내용 | 기대 효과 |
|:---:|:---|:---|
| **P0 (즉시)** | `TerminalFocuser`의 AppleScript 기반 포커스 확인/복귀를 메인 UI 흐름에서 분리하고, 각각 timeout 및 실패 시 승인 흐름을 계속하는 fallback 정책 도입 | UI 프리징 및 비치볼 현상 방지 |
| **P1 (즉시)** | DB 쓰기 작업의 `.sync` 제거/최소화. `recordHookEvent`는 replay event-decision ordering 보장, `persistApprovalScope`는 버튼 응답성과 저장 실패 처리를 별도 설계 | 소켓 처리 응답성 및 버튼 클릭 반응성 향상 |
| **P2 (단기)** | SQLite 로그 정리 로직 도입 (보존 기간은 설정 가능하게, PTY transcript는 hook_events보다 짧은 주기 검토) | DB 비대화 방지, 장기 성능 유지, 민감 정보 보관 위험 완화 |
| **P3 (단기)** | 세션 종료/pruning 시 PTY 버퍼 키 제거 및 에이전트 간 approval scope 영속성 로직 일관성 확보 | 자원 관리 효율화 및 리플레이/정책 엔진 신뢰도 향상 |
| **P4 (장기)** | `AppState`의 단계적 분해 (SessionStore, ReplayRecorder 등 분리) | 코드 복잡도 감소 및 유지보수성 향상 |

---

## 2. 상세 검토 내용

### 🚨 안정성 및 성능 (Stability & Performance)
*   **메인 스레드 블로킹 (AppleScript)**: `TerminalFocuser.swift`에서 `NSAppleScript` 호출 시 `DispatchQueue.main.sync`를 사용하여 메인 스레드를 점유합니다. `osascript` 프로세스를 직접 띄우는 구조는 아니지만, Apple Event 대상 앱의 응답이 늦어질 경우 앱 전체가 멈출 수 있는 위험이 있습니다. 포커스 확인/복귀는 best-effort 기능으로 취급하고, 실패 또는 timeout이 승인 응답 흐름을 막지 않도록 설계해야 합니다.
*   **동기적 DB 작업**: `AppState.swift`의 소켓 처리 및 승인 로직이 DB insert 완료를 기다리는(`sync`) 구조입니다. `approvalPersistenceQueue`는 `utility` QoS의 백그라운드 큐이므로, 해당 `.sync` 호출이 메인 스레드에서 이뤄질 경우 고주파 이벤트 발생 시 잠재적 병목 지점이 됩니다. 다만 `recordReplayHookEvent`는 `hookEventId`를 즉시 반환해 decision과 연결하므로, 단순 async 전환은 replay log의 event-decision 연결성을 깨뜨릴 수 있습니다. `recordHookEvent` 경로는 event와 decision 기록의 ordering 보장을 함께 설계해야 하며, `persistApprovalScope` 경로는 사용자 승인 응답을 막지 않으면서 저장 실패를 로깅/복구하는 별도 처리가 필요합니다.
*   **로그 무한 증식**: `hook_events`, `approval_decisions`, `pty_messages` 등의 테이블에 데이터 보존 정책(TTL/Pruning)이 없어 파일 크기가 지속적으로 증가합니다. 특히 PTY transcript는 터미널 출력이 포함될 수 있으므로 성능 이슈뿐 아니라 민감 정보 보관 위험도 함께 고려해야 합니다.

### 🏗️ 아키텍처 (Architecture)
*   **God Object (`AppState`)**: 2,300줄에 달하는 `AppState`가 UI, IPC, 정책, 영속성 등 모든 책임을 지고 있습니다. 이는 변경 비용을 높이고 사이드 이펙트 위험을 키우는 구조적 부채입니다. 단번에 대규모 분해하기보다 `ReplayRecorder`(hook/decision/PTY DB 기록), `PTYSessionBuffer`(sliding window와 injection match), `SessionStore`(active/pending session 상태)처럼 독립도가 높은 단위부터 단계적으로 추출하는 것이 현실적입니다.
*   **데이터 일관성 결함**: 승인 decision 자체는 provider와 무관하게 replay log에 기록되지만, Claude의 session/persistent approval scope가 SQLite `session_cache`/rules와 일관되게 동기화되지 않는 gap-2가 남아 있습니다. 이로 인해 provider별 정책 엔진과 replay 기반 진단의 신뢰도가 달라질 수 있습니다.

### 🛠️ 구현 및 UX (Implementation & UX)
*   **Private API 리스크**: 노치 영역 감지를 위한 `auxiliaryTopLeftArea` 접근은 실용적이나, 비공개 KVC 접근이므로 macOS 업데이트 시 예고 없이 동작이 깨질 수 있습니다. 현재 직접 배포(dmg) 구조에서는 감수 가능한 선택이고 값이 없을 때는 화면 중앙으로 fallback하지만, KVC 접근 자체의 동작 변경 가능성에 대비해 macOS 버전별 검증과 graceful degradation 테스트가 필요합니다.
*   **PTY 자원 관리**: PTY sliding window 버퍼는 세션별 1KB로 제한되어 실질적 메모리 영향은 작습니다. 다만 injection 패턴 매치 시 빈 문자열(`""`)로 초기화하는 처리와 별개로, 세션 종료/pruning 경로에서 딕셔너리 키 자체를 `removeValue(forKey:)`로 제거하는 것이 더 명확한 자원 관리입니다.
*   **서버 실패 대응**: `NWListener`가 `.failed` 상태로 들어가면 앱은 `onServerFailed`를 호출해 alert 후 종료합니다. 그러나 `startTCP`의 리스너 생성 `catch` 블록에는 `onServerFailed` 호출이 누락되어 있습니다(`startUnix`의 `catch`는 정상 호출). 이 경우 앱은 실행 중이지만 소켓이 열리지 않아 어떤 훅 이벤트도 받지 못하는 **무음 장애(Silent Failure)** 상태가 됩니다. TCP `catch` 경로의 콜백 누락 버그 수정과 함께, 재시도 로직이나 포트 점유 안내 등 UX 개선이 필요합니다. transport fallback은 앱 단독 변경으로 끝나지 않고 bridge 설정 및 설치 스크립트와 함께 검토해야 합니다.

---

## 3. 검토 의견 종합 결과
본 검토는 코드에서 발견된 실제 `TODO` 주석과 구조적 병목 지점을 근거로 작성되었습니다. 특히 **P0/P1에 해당하는 동기 작업의 비동기화**가 앱의 사용자 경험(UX) 안정성에 가장 큰 기여를 할 것으로 판단됩니다. 단, DB 비동기화는 replay log의 event-decision 연결성과 ordering을 보존하는 방식으로 설계해야 하며, AppleScript 기반 포커스 확인/복귀는 실패해도 승인 응답 흐름을 막지 않는 best-effort 경로로 다루는 것이 바람직합니다.

---

## 4. 진행 기록

### 2026-05-16 — PR #91 (`fix/p0-terminal-focuser`)
*   **문서화 완료**: 본 코드 리뷰 요약과 P0~P4 우선순위 action plan을 추가했습니다. 커밋: `dcfccd4`.
*   **P0 1차 구현**: `AppState`의 승인/알림/큐 표시 경로에서 터미널 포커스 체크를 비동기화하고, `TerminalFocuser`의 AppleScript timeout/fallback 처리를 추가했습니다. 커밋: `2c1197d`.
*   **리뷰 반영**: `NSAppleScript`를 background thread에서 실행하지 않도록 제거하고, `/usr/bin/osascript`를 `Process`로 실행하도록 변경했습니다. timeout 시 child process를 `terminate()`하고 필요 시 `SIGKILL`로 정리합니다. `frontmostCheck` 접근은 `isTerminalFrontmostAsync` helper로 통일했고, `AppState` 들여쓰기 지적도 정리했습니다. 커밋: `be9c4c5`.
*   **검증**: `swiftc -parse DevIsland/TerminalFocuser.swift DevIsland/AppState.swift`, `git diff --check`, `./scripts/run-tests.sh` 통과. 테스트 중 CoreSimulator out-of-date 경고가 출력됐지만 macOS unit test는 정상 완료됐습니다.
*   **남은 작업**: PR review thread는 일부 GitHub상 unresolved로 남아 있으나, 주요 코멘트는 최신 커밋에서 outdated 처리되거나 코드로 반영되었습니다. 다음 우선순위는 P1(DB `.sync` 제거/최소화)입니다.

### 2026-05-16 — P1 시작 (`fix/p1-async-approval-persistence`)
*   **승인 scope 저장 비동기화**: `persistApprovalScope`의 `approvalPersistenceQueue.sync`를 `async`로 변경했습니다. `sendDecision`에서 decision 기록 작업이 먼저 enqueue되고 approval scope 저장이 같은 serial queue에 뒤따르므로 저장 순서는 유지하면서 버튼 응답 경로는 DB 쓰기를 기다리지 않습니다.
*   **Replay event 기록 비동기화**: `recordReplayHookEvent`가 DB autoincrement id를 기다리지 않도록 앱에서 음수 hook event id를 예약한 뒤 hook event insert를 비동기로 enqueue합니다. decision insert는 같은 serial queue에 뒤따르므로 event-decision ordering과 FK 연결을 유지합니다.
*   **Fallback 보강**: hook event insert 실패 등으로 decision FK 기록이 실패하면 hook event 없이 decision만 재기록하도록 fallback을 추가했습니다.
*   **테스트 보강**: `SQLiteApprovalStoreTests`에 예약 음수 id로 hook event와 decision이 replay log에서 연결되는 케이스를 추가했습니다.
*   **테스트 출력 정리**: `scripts/run-tests.sh`에서 host architecture를 명시해 중복 macOS destination 경고를 제거하고, macOS 테스트와 무관한 Xcode/CoreSimulator version-mismatch 잡음만 필터링하도록 변경했습니다.
*   **검증**: `./scripts/run-tests.sh` 통과. CoreSimulator out-of-date 경고 없이 macOS unit test가 정상 완료됐습니다.

### 2026-05-16 — P2 시작 (`fix/p2-log-pruning`)
*   **`SQLiteApprovalStore.pruneOldLogs`**: `hook_events`와 연결된 `approval_decisions`를 `received_at` 기준으로, `pty_messages`를 `created_at` 기준으로 삭제하는 메서드를 추가했습니다. FK 제약(`FOREIGN KEY … REFERENCES hook_events(id)`)을 고려해 decisions → hook_events 순으로 삭제합니다.
*   **`ApprovalProxyController.pruneOldLogs`**: store 메서드 래퍼 추가.
*   **`AppState.init`**: 앱 시작 시 `approvalPersistenceQueue.async`로 pruning을 호출합니다. `SettingsStore`(`@MainActor`)를 직접 참조하지 않고 주입된 `userDefaults`에서 키를 읽어 actor 격리 오류를 회피했습니다.
*   **Settings UI**: Approval 탭에 "Log retention" 섹션을 추가해 `replayRetentionDays` Stepper를 노출했습니다(`ptyTranscriptRetentionDays`는 기존 Experimental 탭에 이미 있음).
*   **테스트 2개**: 오래된 hook/decision 행 삭제, 오래된 PTY 메시지 삭제를 각각 검증합니다.
*   **검증**: `./scripts/run-tests.sh` 통과. 커밋: `9fa5b36`.
