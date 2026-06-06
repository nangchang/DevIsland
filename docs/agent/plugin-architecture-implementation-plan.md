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

## 현재 진행 현황

- 기준 브랜치: `origin/main`
- 작업 브랜치: `codex/plugin-event-factory`
- 완료 단계:
  - PR 1. 타입 정의와 빈 `PluginHost` — `0792d2c feat: add plugin host skeleton`
  - PR 2. `PluginEventFactory`와 permission redaction — 완료 (`feat: add plugin event factory`)
- 마지막 검증:
  - `./scripts/run-tests.sh` 통과 (2026-06-06)
- 다음 단계:
  - PR 3. `PluginRunner`와 `PluginHost` dispatch

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

- 설계 문서 §6 전체 타입을 정의한다. 프로토콜·DTO·host skeleton이 같은 PR에서 컴파일되어야 하므로 아래를 모두 포함한다.
  - identity/permission: `PluginPermission`, `PluginManifest`, `PluginKind`
  - event: `PluginEventKind`, `PluginEvent`, `PluginSessionSnapshot`, `PluginHookSummary`, `PluginActionEvent`, `PluginApprovalSummary`
  - 실행 컨텍스트/effect: `PluginContext`, `PluginEffect`
  - UI: `PluginUIContribution`, `PluginUIComponentDTO`, `PluginUIActionDTO`, `PluginUISlot`, `PluginUIContext`, `PluginSurfaceState`, `PluginActionRouting`, `PluginUIComponentType`, `PluginUITone`
  - 결과/오류: `PluginContributionSnapshot`, `PluginFailure`
- `DevIslandPlugin` 프로토콜 정의 (`onEvent`는 `PluginContext`/`[PluginEffect]`, `makeUIContribution`은 `PluginUIContext`, `needsTick`은 `PluginSurfaceState`에 의존하므로 위 타입이 선행되어야 함)
- `PluginHost` skeleton 추가
- `AppState`에 `let pluginHost: PluginHost` 추가
- `AppState.init`에 `enablePlugins: Bool = true` 주입 옵션 추가
- `enablePlugins == false`이면 host가 no-op이 되도록 구성

`PluginEvent.approval` 필드는 v1 struct에 포함하되 v1에서는 항상 `nil`로 둔다(실제 `approval.decided` emission은 v1.1, §6 참고). 필드를 미리 둬서 v1.1에서 struct 시그니처가 바뀌지 않게 한다.

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
- `PluginEventFactory`를 mutable 상태 없는 `Sendable` value type(`struct`)으로 구현 — runner fan-out task에서 공유되므로 내부 cache·mutable formatter 보관 금지 (아키텍처 문서 §10.2 참고)

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
- `DevIsland/Plugins/PluginStorage.swift` (stub `PluginStorageProvider`만; 실구현은 PR9)

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
- **stub `PluginStorageProvider` 추가**: `PluginEventProcessor`와 `PluginEffectExecutor`가 설계 §10.2상 `init(storageProvider:)`를 받고 `snapshot(forPluginID:)`를 호출하므로, 빈 snapshot(`[:]`) 반환·write no-op 형태의 stub을 먼저 둔다. 실제 SQLite 구현은 PR9에서 이 stub을 대체한다.
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
- `session.ended`용 change는 제거 전 `ActiveSession` snapshot을 포함하도록 설계
- `AppState`가 직접 `sessionStore.activeSessions.remove(...)` 하는 경로를 `SessionStore` 메서드로 중앙화
- `handleParsedEvent`에서 `hook.received` 발행
- `handleNotificationEvent`에서 실제 표시 상태 변화 후 `notification.shown` 발행
- `approval.decided`는 아직 발행하지 않는다

주의:

- `SessionStore`가 `PluginHost`나 plugin type을 import하지 않게 한다.
- provider response 전송 전에 plugin processing을 기다리지 않는다.
- emission 실패는 log만 남기고 core flow에 영향 주지 않는다.
- 제거 후에는 `ActiveSession` snapshot을 복원할 수 없으므로 removal callback은 mutation 전에 만들어야 한다.

테스트:

- session update callback이 new/update/remove를 구분하는지
- remove callback이 제거 전 snapshot을 전달하는지
- pruned/superseded/dismissed session이 모두 `session.ended`로 이어지는지
- manual approval 완료 후 lifecycle-untracked session 제거도 `session.ended`로 이어지는지
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
- `AppDelegate.applicationDidFinishLaunching`의 delayed block에서 `AppState.shared` 초기화 이후 `pluginHost.startTicking()` 호출
- app start 시 `plugin.started`, `app.started` 발행
- app termination 시 tick cancel
- UI surface visible state 보고
- `needsTick(surfaceState:)`가 true인 플러그인이 있을 때만 `plugin.tick` 발행

테스트:

- tick 필요한 플러그인이 없으면 tick event 없음
- visible surface 변경이 `needsTick` 판단에 반영
- disable/safemode plugin은 tick 대상 제외
- 다른 DevIsland 인스턴스 종료 대기 후 delayed start 경로에서도 tick이 1회만 시작

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

변경 파일:

- `DevIsland/Plugins/PluginStorage.swift` (PR3의 stub `PluginStorageProvider`를 실제 SQLite 구현으로 대체)

주요 작업:

- `PluginStorage` protocol + SQLite wrapper 구현 (설계 §11 파일 레이아웃)
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

### Migration Track. 기존 기능 Built-in Plugin 전환

PR 0–11은 플러그인 플랫폼 자체를 안정화하는 범위다.
기존 기능 전환은 platform, settings, safemode가 동작한 뒤 별도 migration PR로 진행한다.

전환 원칙:

- core hook/approval response path를 건드리지 않는다.
- 기능 disable 또는 safemode가 기존 approval/session 동작을 바꾸지 않는다.
- raw payload, replay DB, PTY transcript, terminal focus 권한을 플러그인에 넘기지 않는다.
- 기존 host service를 plugin 내부로 옮기지 않고, 필요한 경우 host-owned effect/status API를 추가한다.

#### Migration PR M0. 후보 인벤토리와 feature guard

목표:

- 기존 기능별 plugin화 후보와 제외 대상을 코드 기준으로 확정한다.
- migration 대상마다 기존 설정과 plugin enable 상태의 관계를 정의한다.

주요 작업:

- `plugin-architecture.md` §12.9 기준으로 후보 목록 재검토
- OpenPeon, Caffeine, Replay/Session History, PTY Transcript, UpdateChecker, MenuBar command를 `전환`, `부분 전환`, `core 유지`로 분류
- 기존 기능을 plugin으로 옮기더라도 user setting migration이 필요 없는지 확인
- built-in plugin disable 시 기존 기능을 끌지, core fallback을 유지할지 기능별로 결정
- Caffeine은 기존 `SettingsStore`의 `caffeineEnabled`/`caffeineExcludedSSIDs` 설정을 core setting으로 유지하고, plugin enable/safemode는 assertion effect를 막는 추가 feature guard로만 정의

검증:

- 문서 및 feature guard 테스트
- 기존 설정 기본값이 바뀌지 않는지 확인
- `SettingsStore`의 Caffeine 사용자 기본값이 계속 off이며, plugin disabled/safemode 상태에서 sleep assertion이 release되는지 확인

#### Migration PR M1. OpenPeonSoundPlugin

선행 조건:

- PR 3의 `PluginEffectExecutor`가 built-in-only capability allowlist를 검증할 수 있어야 한다.
- `sound.playCESP` capability는 M1에서 추가하되 permission 기반 공개 capability가 아니라 built-in plugin ID allowlist로만 허용한다.

목표:

- OpenPeon sound playback 정책을 첫 기존 기능 migration 후보로 검증한다.
- 사운드 재생은 best-effort side effect로 유지한다.

주요 작업:

- built-in `OpenPeonSoundPlugin` 추가
- `sound.playCESP` 같은 built-in-only host effect capability 정의 (설계 문서 §8 capability↔permission 표에 "built-in allowlist only" 행 추가)
- `CESPEventMapper`는 host service에 유지하고, raw payload 기반 category 계산은 `PluginEventFactory` 또는 별도 host sound-hint factory에서 수행
- plugin은 `hook.received`, `session.started`, `session.updated`, `session.ended`, `notification.shown`에 포함된 sanitized sound hint를 관찰해 CESP category 요청만 반환
- `CESPPackStore`, `CESPPackValidator`, `CESPAudioPlayer`, OpenPeon settings persistence는 host service로 유지
- `AppState.playOpenPeonSound` 직접 호출부를 event/effect 경로로 단계적으로 대체

주의:

- plugin이 pack path, audio file path, raw hook payload, parsed provider payload를 직접 보지 않게 한다.
- `sound.playCESP`는 permission 기반 공개 capability가 아니라 compiled built-in plugin ID allowlist로만 허용한다.
- sound failure는 plugin failure/log로만 남기고 provider response에 영향 주지 않는다.
- OpenPeon settings UI는 custom plugin settings schema가 생기기 전까지 기존 Settings pane을 유지한다.

검증:

- 기존 OpenPeon settings 조합별 playback 동작 유지
- CESP category 산출 테스트는 host sound-hint factory/`CESPEventMapper`에 남고 plugin 테스트에는 raw payload fixture를 넘기지 않음
- invalid pack, missing sound, mute 상태에서 approval 동작 불변
- plugin disable/safemode 시 sound만 중지되고 hook/session UI는 정상 동작

#### Migration PR M2. CaffeinePlugin

선행 조건:

- built-in-only capability allowlist와 effect executor 경로가 M1 또는 M2 시작 시점에 준비되어 있어야 한다.
- `power.preventIdleSleep` capability는 M2에서 추가하되 permission 기반 공개 capability가 아니라 built-in plugin ID allowlist로만 허용한다.

목표:

- Caffeine을 built-in plugin migration 후보에 포함하되, 시스템 sleep side effect와 권한 처리는 host-owned service로 유지한다.
- 기존 Caffeine 설정값과 기본 동작을 바꾸지 않는다.

주요 작업:

- built-in `CaffeinePlugin` 추가
- `power.preventIdleSleep` 같은 built-in-only host effect capability 정의 (설계 문서 §8 capability↔permission 표에 "built-in allowlist only" 행 추가)
- `SleepAssertion`, `PowerSourceMonitor`, `WifiSSIDMonitor`, `LocationPermissionRequester`, Wi-Fi scan, SSID 입력/제외 설정 UI, `SettingsStore` persistence는 host service로 유지
- host가 power/SSID/settings 상태를 sanitized caffeine status DTO로 제공
- plugin은 host-provided status만 관찰해 assertion 보유/해제 의도를 `power.preventIdleSleep` effect로 반환
- `CaffeineMenuItem`의 상태 표시는 가능하면 `menubar.menu` contribution으로 단계적으로 대체하되, 자유 입력이 필요한 `CaffeineSettingsPane`은 custom plugin settings schema가 생기기 전까지 유지

주의:

- plugin이 `IOPMAssertion`, Location, CoreWLAN API를 직접 호출하지 않게 한다.
- `power.preventIdleSleep`는 permission 기반 공개 capability가 아니라 compiled built-in plugin ID allowlist로만 허용한다.
- `SettingsStore.caffeineEnabled`는 사용자 기능 토글이고, plugin enable/safemode는 상위 feature guard다. 둘 중 하나라도 off이면 host는 assertion을 release해야 한다.
- Caffeine settings UI는 SSID scan과 자유 텍스트 입력이 필요하므로 v1 contribution UI로 옮기지 않는다.

검증:

- 기존 `SettingsStore.caffeineEnabled == false` 사용자 기본값 유지
- AC/battery/low-battery/SSID 제외 조건별 assertion 판단 유지
- plugin disable/safemode 시 assertion release
- Location permission denied, Wi-Fi scan 실패, assertion acquire 실패가 provider response와 approval 동작에 영향 주지 않음
- 앱 종료 또는 coordinator shutdown 시 assertion release 유지

#### Migration PR M3. SessionStatsPlugin / ProviderStatsPlugin

목표:

- 기존 session/hook 관찰 데이터에서 통계성 UI를 built-in plugin으로 제공한다.

주요 작업:

- `readSessionEvents`, `readHookSummaries` 기반 metric contribution 추가
- `notch.expanded.activity`, `menubar.menu`에 짧은 통계 표시
- v1.1 `approval.decided`가 추가되기 전에는 approval 통계 제외
- replay DB 직접 조회 금지

검증:

- raw payload와 replay row가 plugin DTO에 포함되지 않는지
- 긴 provider/tool name truncation
- plugin disable 시 contribution 즉시 제거

#### Migration PR M4. Session accessory plugins

목표:

- 세션별 UI slot이 열린 뒤 message/row accessory를 plugin contribution으로 검증한다.

전제:

- `notch.session.row`
- `session.context-menu`
- `session.message`

주요 작업:

- 세션 행 badge, 세션 메시지 header accessory, 간단한 context action을 contribution으로 이동
- `session.dismiss` host-executed action은 idle/non-pending이면서 `hasMissedApproval == false`, `isUnread == false`인 세션에만 허용하고, pending/current approval/missed/unread 세션은 host validation에서 거부
- `targetSessionID` dedup/evict 검증
- SessionMessageWindow와 SessionHistoryWindow의 data loading은 core에 유지

검증:

- session ended 시 세션별 contribution evict
- idle/non-pending이고 missed/unread가 아닌 세션의 `session.dismiss` action은 세션 목록에서 제거되고 `session.ended` contribution evict로 이어지는지
- pending/current approval/missed/unread 세션의 `session.dismiss` action은 거부되고 provider response, pending queue, approval UI가 변하지 않는지
- 세션 팝아웃 창이 열려 있을 때 contribution 업데이트
- replay/session history query가 plugin storage로 새지 않는지

#### Migration PR M5. Update status contribution

선행 조건:

- 외부 network permission 또는 host-owned update status API의 경계가 정리되어 있어야 한다.
- network/runtime 설계 전에는 update 확인·다운로드·설치를 plugin capability로 열지 않는다.

목표:

- update 가능 여부를 부가 UI contribution으로 표시할 수 있는지 검토한다.

주의:

- update check, download, install은 core `UpdateChecker` 책임으로 유지한다.
- 외부 network permission이 생기기 전까지 plugin은 network를 직접 사용하지 않는다.
- 이 PR은 낮은 우선순위이며, v2 network/runtime 설계 후로 미룰 수 있다.

검증:

- update status 표시만 plugin contribution으로 분리
- install action은 host command로만 실행

## 6. 고도화 후보

v1 built-in platform과 migration track이 안정화된 뒤 다음 순서로 확장한다.
각 항목은 별도 PR 또는 작은 PR 묶음으로 진행한다.

### v1.1 Session Surfaces

- `approval.decided` 관찰 이벤트 — provider response 전송 이후 통계용으로만 발행
- `notch.session.row` — 세션 행 badge, 짧은 metric, status accessory
- `session.context-menu` — host-validated session action. `session.dismiss`는 idle/non-pending이고 missed/unread가 아닌 세션에만 허용
- `session.message` — 세션 메시지 창 header/toolbar accessory
- `session.dismiss`를 열기 전에 최소 Host Command Catalog 골격을 먼저 두고, 임시 특수 경로를 만들지 않는다.

검증:

- 세션별 contribution `targetSessionID` dedup/evict
- pending/current approval/missed/unread 세션에 destructive action이 적용되지 않는지
- approval decision이 plugin event로 변경되거나 지연되지 않는지

### v1.2 Host Command Catalog Expansion

v1.1에서 개별 session surface 구현과 함께 둔 최소 command path를 이 단계에서 catalog 구조로 확장한다.
따라서 `session.dismiss`는 v1.1에서 이미 공통 capability validation 경로를 타야 하며, v1.2에서는 logging, failure handling, audit metadata, 추가 command 등록 구조를 정리한다.

- `session.dismiss`: idle/non-pending only, excluding missed/unread sessions
- `session.focusTerminal`: 기존 `TerminalFocuser` 경유
- `session.copyResumeCommand`: host가 sanitized command 생성
- `session.openWorkspace`: workspace root가 있는 세션만 허용
- `sound.playCESP`, `power.preventIdleSleep`, `notification.show`를 같은 command/effect validation 경로로 정리

검증:

- command별 permission/capability 검증
- 실패한 command가 provider response, approval queue, session lifecycle ownership을 바꾸지 않는지
- pending/current approval/missed/unread 세션에 대한 destructive command가 거부되는지

### v1.3 Plugin Settings Schema

- boolean toggle, enum picker, number stepper/slider, short text input만 우선 허용
- `settings.changed` 이벤트 — 플러그인 자신의 설정 변경에만 반응
- path picker, Wi-Fi scan, Location permission, pack validation UI는 host-owned settings pane으로 유지
- Caffeine처럼 권한성 UI가 핵심인 built-in plugin은 schema가 생긴 뒤에도 host-owned settings pane을 유지할 수 있다.

검증:

- schema validation과 default fallback
- plugin setting 변경이 contribution/tick/action에 반영되는지
- core app settings, bridge settings, approval settings를 plugin이 직접 mutate하지 않는지

## 7. v2+ 후보

### v2 External Plugin Runtime

- worker process runtime 우선, JavaScriptCore는 차선
- manifest API version, permission consent UI, audit log
- crash/safemode 자동 격리
- network permission with allowlist
- `readRawPayload`, `networkAccess`, `runProcess`는 explicit user consent와 revocation UI를 갖춘 뒤 추가

### v2.1 Signed Plugin Distribution

- signed plugin package
- checksum과 API version compatibility 검사
- trusted local plugin과 signed third-party plugin 구분
- uninstall/storage cleanup
- plugin health diagnostics

### Deferred Session List Presentation

- `notch.session.list` 또는 equivalent list-level presentation surface는 built-in plugin에서 실제 필요 사례가 검증된 뒤 v2+에서 재검토
- summary row, filter chip, group label, sort hint만 contribution 후보로 둔다
- 실제 적용 여부는 host-owned `SessionListPresentationPolicy`가 결정

검증:

- pending/current approval, missed approval, unread 세션이 plugin hint로 숨겨지지 않는지
- `SessionStore.activeSessions` mutation은 core에만 남는지
- list hint가 세션별 `targetSessionID` contribution evict와 충돌하지 않는지

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
| Migration | 기존 기능 setting 유지, disable/safemode 영향 범위, host service와 plugin effect 경계 |
| Caffeine migration | 기본값 off 유지, host-owned assertion release, Location/CoreWLAN 권한 경계, low-battery hysteresis 유지 |

## 9. 수동 smoke check

각 runtime-facing PR 이후 최소 다음을 확인한다.

- Claude/Codex/Gemini hook response가 기존과 동일하게 반환되는지
- approval prompt 표시와 approve/deny 동작이 기존과 같은지
- notification hook이 기존처럼 session/unread 상태를 갱신하는지
- expanded notch에서 contribution이 approval UI를 가리지 않는지
- MenuBarExtra에서 plugin row가 기존 메뉴 동작을 방해하지 않는지
- plugin disable 시 UI contribution이 즉시 사라지는지
- migration PR에서는 기존 기능의 설정값과 기본 동작이 유지되는지
- migration 대상 plugin이 safemode에 들어가도 core hook/approval/session 동작이 유지되는지

## 10. 중단 기준

다음 상황이면 구현을 멈추고 설계를 재검토한다.

- bridge script나 `HookSocketServer`를 수정해야 plugin 기능이 동작하는 경우
- provider response 생성 전에 plugin result를 기다려야 하는 경우
- plugin이 `AppState` private approval state에 접근해야 하는 경우
- renderer에서 plugin method를 직접 호출해야 하는 경우
- plugin storage가 approval DB 또는 approval persistence queue를 공유해야 하는 경우

이 중 하나라도 필요해지면 v1 built-in API 범위를 넘은 것이다.
