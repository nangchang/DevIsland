# DevIsland Plugin Architecture Implementation Plan

## 1. 목적

이 문서는 `docs/agent/plugin-architecture.md`의 설계를 실제 코드에 적용하기 위한 단계별 구현 계획이다.

목표는 플러그인 구조를 도입하되, DevIsland의 핵심 hook/approval response path를 바꾸지 않는 것이다. 첫 구현은 앱에 컴파일된 built-in plugin만 대상으로 하며, 외부 플러그인 런타임, 네트워크 권한, 프로세스 실행 권한은 제외한다.

## 2. 성공 기준

- 기존 Claude/Codex/Gemini hook 응답 형식과 승인 동작이 바뀌지 않는다.
- `HookSocketServer`, bridge scripts, `ApprovalProxyController`, `ProviderAdapter`, `SQLiteApprovalStore`는 첫 구현 PR에서 수정하지 않는다.
- 플러그인 실패, storage 실패, UI contribution 오류가 provider response JSON을 바꾸지 않는다.
- 렌더링 경로에서 플러그인 코드를 호출하지 않는다. UI는 `PluginHost.contributions` cache만 읽는다.
- 플러그인별 permission redaction이 runner 단위로 적용된다.
- v1에서 열리는 UI surface는 `notch.expanded.activity`, `menubar.menu` 두 개뿐이다.
- 설정 화면은 contribution slot이 아니라 DevIsland host-owned `PluginSettingsView`로 구현한다.

## 3. 비목표

- 외부 사용자가 작성한 plugin package 로딩
- JavaScriptCore, worker process, native bundle runtime
- plugin network access, process execution, raw payload access
- approval decision 변경, approval prompt interception
- session row/context menu/message window contribution
- collapsed notch contribution
- custom plugin settings schema

위 항목은 v1.1 또는 v2에서 별도 설계 후 진행한다.

## 4. 구현 원칙

- `AppState`는 대규모 리팩토링하지 않는다. `pluginHost` 소유와 event emission seam만 추가한다.
- `SessionStore`는 `PluginHost`를 직접 알지 않는다. 필요한 경우 neutral callback만 제공한다.
- `PluginEventFactory`가 base event 생성과 runner별 redaction을 모두 담당한다.
- `PluginRunner`는 actor이고, built-in plugin 구현체는 plain final class다.
- storage I/O는 `PluginStorageProvider` actor 또는 전용 serial queue에서 처리한다.
- plugin enable/disable, safemode, storage reset 상태는 core settings와 분리한다.

## 5. PR 분할

### PR 0. 문서 및 경계 확인

목표:

- `plugin-architecture.md`와 이 구현 계획을 기준 문서로 확정한다.
- 첫 구현에서 건드리지 않을 파일 목록을 명확히 한다.

변경 파일:

- `docs/agent/plugin-architecture.md`
- `docs/agent/plugin-architecture-implementation-plan.md`

검증:

- 문서 변경만이면 테스트 생략 가능.

### PR 1. 타입 정의와 빈 PluginHost

목표:

- 플러그인 타입과 빈 host를 추가한다.
- 런타임 동작은 완전히 동일해야 한다.

신규 파일:

- `DevIsland/Plugins/PluginPermission.swift`
- `DevIsland/Plugins/PluginProtocol.swift`
- `DevIsland/Plugins/PluginEvent.swift`
- `DevIsland/Plugins/PluginUIContribution.swift`
- `DevIsland/Plugins/PluginHost.swift`

주요 작업:

- `PluginPermission`, `PluginManifest`, `PluginKind` 정의
- `PluginEventKind`, `PluginEvent`, `PluginSessionSnapshot`, `PluginHookSummary`, `PluginActionEvent` 정의
- `PluginUIContribution`, `PluginUIComponentDTO`, `PluginUIActionDTO`, `PluginUISlot` 정의
- `PluginHost` skeleton 추가
- `AppState`에 `let pluginHost: PluginHost` 추가
- `AppState.init`에 `enablePlugins: Bool = true` 주입 옵션 추가
- `enablePlugins == false`이면 host가 no-op이 되도록 구성

주의:

- 이 PR에서는 event emission을 추가하지 않는다.
- built-in plugin registry도 비워 둔다.
- UI에는 아무 것도 연결하지 않는다.

검증:

- `./scripts/run-tests.sh`
- 필요 시 `./scripts/build_and_run.sh --no-kill --no-run`
- 기존 approval/manual prompt 동작이 바뀌지 않았는지 수동 smoke check

### PR 2. PluginEventFactory와 permission redaction

목표:

- hook/session 데이터를 plugin DTO로 변환하는 순수 변환 계층을 추가한다.
- runner별 permission redaction을 구현한다.

신규 파일:

- `DevIsland/Plugins/PluginEventFactory.swift`

주요 작업:

- `ParsedHookEvent` -> base `PluginEvent` 변환
- `ActiveSession` -> `PluginSessionSnapshot` 변환
- `PluginEventFactory.redactedEvent(from:permissions:)` 구현
- `readTerminalMetadata`가 없으면 `cwd`, `terminalApp` 제거
- `readSessionEvents`가 없으면 hook event의 `session` snapshot 제거
- `readRawPayload`, `readPtyTranscript`는 v1에서 어떤 DTO에도 포함하지 않음

테스트:

- hook summary에 raw payload가 포함되지 않는지
- token-like string, home path, 긴 heredoc body redaction
- `readTerminalMetadata` 유무에 따른 field 차이
- `readSessionEvents` 없는 hook subscriber가 session snapshot을 받지 않는지

검증:

- `./scripts/run-tests.sh`

### PR 3. PluginRunner와 PluginHost dispatch

목표:

- event queue, runner fan-out, contribution cache를 구현한다.
- 아직 등록된 플러그인은 없다.

신규 파일:

- `DevIsland/Plugins/PluginRunner.swift`
- `DevIsland/Plugins/PluginEventProcessor.swift`
- `DevIsland/Plugins/PluginEffectExecutor.swift`

주요 작업:

- `PluginRunner` actor 구현
- `PluginRunner.handle(_:storageSnapshot:)`에서 `onEvent` 후 `makeUIContribution` 호출
- elapsed time 측정과 `PluginFailure` 생성
- `PluginHost.enqueue(_:)` MainActor FIFO 구현
- `QueuedPluginEvent.baseEvent`와 runner 목록 저장
- `PluginEventProcessor`가 runner별로 `redactedEvent(from:permissions:)` 적용
- `PluginHost.applySnapshots`에서 cache 일괄 교체
- contribution dedup 기준 구현
  - 전역 slot: `(pluginID)`
  - session slot: `(pluginID, targetSessionID)`
- `PluginEffectExecutor`는 이 PR에서 no-op 또는 logging-only로 시작 가능

테스트:

- event enqueue 순서 보존
- 한 event 안에서 여러 runner fan-out
- runner별 redaction이 다르게 적용되는지
- thrown error가 contribution clear로 이어지는지
- timeout 초과가 failure counter로 기록되는지
- 플러그인 0개 상태에서 no-op인지

검증:

- `./scripts/run-tests.sh`

### PR 4. PluginContributionRenderer와 no-op UI 삽입

목표:

- 렌더링 경로에서 contribution cache만 읽는 UI 연결을 추가한다.
- contribution이 없을 때 기존 UI 레이아웃이 변하지 않아야 한다.

신규 파일:

- `DevIsland/UI/PluginContributionRenderer.swift`

주요 작업:

- `PluginSlotView` 추가
- `PluginContributionRenderer`에서 `metric`, `badge`, `button`, `text` 렌더링
- SF Symbol validation 또는 fallback
- 텍스트 길이 제한과 line limit 적용
- `NotchView`의 expanded activity 영역에 `PluginSlotView(slot: .notchExpandedActivity)` 삽입
- `MenuBarMenu`에 `PluginSlotView(slot: .menubarMenu)` 또는 menu 전용 renderer 삽입

MenuBar 렌더링 제약:

- `metric`은 disabled menu row 또는 label/value row로 렌더링한다.
- `text`는 짧은 `Text` row로 렌더링한다.
- `button`은 `Button`으로 렌더링한다.
- 복잡한 layout, nested panel, custom SwiftUI view는 v1에서 금지한다.

테스트:

- empty contribution이면 UI가 기존과 동일하게 동작
- 긴 label/value가 잘리는지
- action 없는 component는 click target이 없는지
- invalid icon name fallback/drop

검증:

- `./scripts/run-tests.sh`
- `./scripts/build_and_run.sh --no-kill --no-run`
- 가능하면 앱 실행 후 notch/menu smoke check

### PR 5. Event emission seam

목표:

- 기존 core flow를 기다리지 않는 best-effort plugin event emission을 추가한다.

변경 파일:

- `DevIsland/Core/AppState.swift`
- `DevIsland/Session/SessionStore.swift`

주요 작업:

- `SessionStoreChange` neutral event 정의
- `SessionStore.onSessionChanged` callback 추가
- `AppState`가 callback을 받아 `PluginEventFactory`로 `session.started`, `session.updated`, `session.ended` 생성
- `handleParsedEvent`에서 `hook.received` 발행
- `handleNotificationEvent`에서 실제 표시 상태 변화 후 `notification.shown` 발행
- `approval.decided`는 아직 발행하지 않는다

주의:

- `SessionStore`가 `PluginHost`나 plugin type을 import하지 않게 한다.
- provider response 전송 전에 plugin processing을 기다리지 않는다.
- emission 실패는 log만 남기고 core flow에 영향 주지 않는다.

테스트:

- session update callback이 new/update/remove를 구분하는지
- pruned/superseded/dismissed session이 모두 `session.ended`로 이어지는지
- hook response payload가 변경되지 않는지

검증:

- `./scripts/run-tests.sh`
- 기존 hook simulation 가능하면 `scripts/test-hook.sh`로 smoke check

### PR 6. Tick lifecycle

목표:

- 중앙 1Hz tick loop를 구현한다.
- 개별 플러그인은 timer를 만들지 않는다.

변경 파일:

- `DevIsland/Plugins/PluginHost.swift`
- `DevIsland/Core/DevIslandApp.swift`
- `DevIsland/UI/NotchView.swift`

주요 작업:

- `PluginHost.startTicking()`, `stopTicking()` 구현
- app start 시 `plugin.started`, `app.started` 발행
- app termination 시 tick cancel
- UI surface visible state 보고
- `needsTick(surfaceState:)`가 true인 플러그인이 있을 때만 `plugin.tick` 발행

테스트:

- tick 필요한 플러그인이 없으면 tick event 없음
- visible surface 변경이 `needsTick` 판단에 반영
- disable/safemode plugin은 tick 대상 제외

검증:

- `./scripts/run-tests.sh`

### PR 7. SessionTimerPlugin built-in

목표:

- 첫 core-aware built-in plugin을 추가한다.
- `notch.expanded.activity` slot만 사용한다.

신규 파일:

- `DevIsland/Plugins/BuiltIn/SessionTimerPlugin.swift`

주요 작업:

- session start/update/end 관찰
- 현재 selected/current session 기준 elapsed 표시
- `readSessionEvents`, `showNotchCard` permission 사용
- no storage
- no notification

테스트:

- session start 후 elapsed metric contribution 생성
- session end 후 contribution evict
- permission 없는 경우 session event 미수신

검증:

- `./scripts/run-tests.sh`
- `./scripts/build_and_run.sh --no-kill --no-run`
- notch expanded smoke check

### PR 8. PomodoroPlugin built-in and menubar.menu

목표:

- DevIsland core와 무관한 utility plugin을 추가한다.
- `menubar.menu`와 `notch.expanded.activity`를 사용한다.

신규 파일:

- `DevIsland/Plugins/BuiltIn/PomodoroPlugin.swift`

주요 작업:

- start/pause action 처리
- `plugin.action.invoked` target plugin 라우팅
- `timer.startStop` capability 처리
- completed 시 `notification.show` effect 요청
- storage persistence는 아직 선택 사항

테스트:

- menu button action이 해당 plugin에만 되돌아가는지
- 다른 plugin은 action event를 받지 않는지
- running 상태에서 tick이 남은 시간을 감소시키는지

검증:

- `./scripts/run-tests.sh`
- menubar smoke check

### PR 9. PluginStorageProvider

목표:

- plugin별 durable key-value storage를 구현한다.
- approval DB와 queue는 공유하지 않는다.

신규 파일:

- `DevIsland/Plugins/PluginStorage.swift`

주요 작업:

- plugin ID별 namespace
- `snapshot(limit:)`
- `set`, `delete`, `increment`
- quota 적용
- key/value 길이 제한
- storage effect 처리
- storage reset API

주의:

- `Approval/SQLiteApprovalStore.swift`를 재사용하지 않는다.
- `AppState.approvalPersistenceQueue`를 공유하지 않는다.
- storage effect 실패는 plugin failure/log로만 처리한다.

테스트:

- plugin별 isolation
- quota 초과
- increment atomicity
- snapshot limit
- storage effect 후 다음 event에서 snapshot 반영

검증:

- `./scripts/run-tests.sh`

### PR 10. PluginSettingsView

목표:

- 플러그인 목록과 상태 관리를 Settings UI에 추가한다.
- v1에서는 plugin-provided settings UI를 렌더링하지 않는다.

신규 파일:

- `DevIsland/Settings/PluginSettingsView.swift`
- `DevIsland/Plugins/PluginSettingsStore.swift`

변경 파일:

- `DevIsland/Settings/SettingsWindow.swift`

주요 작업:

- plugin list
- enable/disable toggle
- safemode 상태 표시
- failure count/last error 표시
- storage reset button
- settings persistence

테스트:

- disable 시 contribution 제거
- disable 시 tick 대상 제외
- enable 시 plugin.started 발행
- safemode reset 동작

검증:

- `./scripts/run-tests.sh`
- settings window smoke check

### PR 11. Safemode hardening

목표:

- plugin failure가 반복될 때 자동으로 safemode에 진입한다.

주요 작업:

- 60초 이내 3회 실패 임계값
- thrown error는 contribution clear
- timeout은 failure 기록하되 기존 contribution 유지 가능
- safemode plugin은 event/tick/action 대상 제외
- user reset 후 1회 제한 재시도

테스트:

- thrown error 3회 후 safemode
- timeout 3회 후 safemode
- safemode 진입 시 contribution 제거
- reset 후 재시도

검증:

- `./scripts/run-tests.sh`

## 6. v1.1 후보

v1이 안정화된 뒤 다음 순서로 확장한다.

1. `approval.decided` 관찰 이벤트
2. `notch.session.row`
3. `session.context-menu`
4. `session.message`
5. plugin custom settings schema

각 항목은 별도 PR로 진행한다.

## 7. v2 후보

- declarative utility preset
- signed plugin package
- external worker process
- JavaScriptCore runtime
- network permission with allowlist
- raw payload permission with explicit user consent

## 8. 테스트 매트릭스

| 영역 | 테스트 |
| :--- | :--- |
| EventFactory | redaction, base event 생성, provider normalization |
| PluginHost | FIFO, fan-out, safemode, contribution cache |
| PluginRunner | actor serialization, thrown error, timeout |
| Renderer | empty contribution, invalid component/icon, action routing |
| Storage | namespace isolation, quota, snapshot, increment |
| Settings | enable/disable, reset storage, safemode reset |
| AppState seam | response payload 불변, session ended 누락 없음 |

## 9. 수동 smoke check

각 runtime-facing PR 이후 최소 다음을 확인한다.

- Claude/Codex/Gemini hook response가 기존과 동일하게 반환되는지
- approval prompt 표시와 approve/deny 동작이 기존과 같은지
- notification hook이 기존처럼 session/unread 상태를 갱신하는지
- expanded notch에서 contribution이 approval UI를 가리지 않는지
- MenuBarExtra에서 plugin row가 기존 메뉴 동작을 방해하지 않는지
- plugin disable 시 UI contribution이 즉시 사라지는지

## 10. 중단 기준

다음 상황이면 구현을 멈추고 설계를 재검토한다.

- bridge script나 `HookSocketServer`를 수정해야 plugin 기능이 동작하는 경우
- provider response 생성 전에 plugin result를 기다려야 하는 경우
- plugin이 `AppState` private approval state에 접근해야 하는 경우
- renderer에서 plugin method를 직접 호출해야 하는 경우
- plugin storage가 approval DB 또는 approval persistence queue를 공유해야 하는 경우

이 중 하나라도 필요해지면 v1 built-in API 범위를 넘은 것이다.
