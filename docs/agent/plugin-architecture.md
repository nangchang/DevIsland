# DevIsland Plugin Architecture (Refined & Polished)

## 1. 개요 (Overview)

DevIsland 플러그인 시스템은 Swift 앱의 핵심 안정성을 유지하면서 기능을 확장하고, 사용자 정의 유틸리티를 제공하기 위한 샌드박스 구조다. 플러그인은 앱의 핵심 승인 흐름(Approval Flow)을 변경하지 않고, 정제된 이벤트를 관찰하거나 선언형 UI 기여분(Contribution)을 제공한다.

초기 버전(v1)은 앱 바이너리에 포함된 **Built-in Plugin API**를 안정화하고 실제 흐름에서 검증하는 것을 목표로 한다.

## 2. 설계 원칙 (Design Principles)

- **Isolation (격리)**: 플러그인은 승인 요청을 가로채거나 결정에 개입하지 않는다.
- **Read-Only Core**: `AppState` 등 코어 상태를 직접 수정할 수 없다.
- **Sanitized Events**: Raw 페이로드 대신 정제된 DTO(`PluginEvent`)만 수신한다.
- **Declarative UI**: SwiftUI View를 직접 주입하지 않고, 선언형 데이터 모델을 반환하여 DevIsland가 렌더링하도록 한다.
- **Fail-Safe**: v1 built-in plugin의 timeout과 logic error는 core flow와 분리한다. 앱 프로세스 안에서 실행되는 built-in plugin의 crash isolation은 제공하지 않으며, crash isolation은 v2 worker runtime에서 제공한다.
- **Cached Rendering**: UI 렌더링 시점에 플러그인을 호출하지 않고, 사전에 계산된 캐시된 기여분(Contribution Cache)을 사용한다.
- **Surface Host**: 플러그인은 window, panel, menu item을 임의로 생성하지 않는다. DevIsland가 소유한 surface에만 기여분을 제공한다.
- **Contractual Permissions**: Built-in 단계에서는 매니페스트 선언에 따른 계약적 권한 모델을 따른다.

## 3. 플러그인 분류 (Plugin Kind)

```swift
enum PluginKind: String, Codable {
    case coreAware    // DevIsland session·hook 상태를 관찰
    case utility      // DevIsland와 무관한 독립 기능 (v1 built-in only)
    case integration  // 외부 서비스·파일 시스템 연동 (v2 이후)
    case runtime      // 외부 코드 실행 (v2 이후 검토)
}
```

| Kind | 목적 | 예시 | v1 지원 |
| :--- | :--- | :--- | :--- |
| `coreAware` | session·hook·provider 상태를 관찰하고 UI를 보탠다. | SessionTimer, ProviderStats | ✓ |
| `utility` | DevIsland와 무관한 작은 독립 기능을 notch/menubar에 올린다. | Pomodoro, Counter | ✓ (built-in only) |
| `integration` | 외부 서비스나 파일 시스템을 활용한다. | GitHub Issue, Calendar | v2 이후 |
| `runtime` | 외부 코드 실행으로 자유도를 높인다. | JS worker, native bundle | v2 이후 검토 |

v1 `utility` 플러그인은 사용자가 코드를 작성하는 방식이 아니라 앱에 컴파일된 built-in Swift 구현으로 제공한다.

## 4. 아키텍처 구조 (Architecture)

### 4.1. 이벤트 및 데이터 흐름

```text
[External Hook Event] -> [HookSocketServer] -> [AppState]
                                                  |
                                                  v (Async Dispatch)
[PluginHost] <--------------------------------- [PluginEventFactory]
     |
     +-- [MainActor FIFO pendingEvents] 이벤트 도착 순서 보존
             |
             +-- [PluginEventProcessor] 한 이벤트의 runner를 fan-out
                     |
                     +-- (withTaskGroup) --> [PluginRunner A] -> [onEvent] -> [makeUIContribution]
                     |                   --> [PluginRunner B] -> [onEvent] -> [makeUIContribution]
     |
     +-- (MainActor) --> [Contribution Cache 일괄 교체] -> [SwiftUI 단일 업데이트]
                                   |
                                   v (Reactive)
                           [Notch / MenuBar UI]
```

`plugin.tick`은 `PluginHost`가 중앙에서 발행한다. 개별 플러그인이 자체 타이머를 갖지 않는다.
tick loop는 `PluginHost` activation 시 1회 시작하고, 앱 종료 또는 plugin platform shutdown 시 취소한다.
plugin enable/disable, safemode 전환, visible surface 변경은 tick loop를 새로 만들지 않고 `needsTick(surfaceState:)` 판단에만 반영한다.

### 4.2. 핵심 컴포넌트 책임

| 컴포넌트 | 책임 |
| :--- | :--- |
| **PluginHost** | 생명주기 관리, `@MainActor` FIFO `pendingEvents`로 이벤트 도착 순서 보존, Contribution Cache 소유, `@MainActor ObservableObject` |
| **PluginEventProcessor** | 한 이벤트에 해당하는 runner들을 `withTaskGroup`으로 fan-out 실행. 자체적으로 큐잉·순서 보존은 하지 않는다 |
| **PluginRunner** | 플러그인 하나를 `actor`로 감싸 가변 상태 보호(플러그인은 plain class로 작성), 이벤트 처리 순서 보장, timeout 측정 |
| **PluginEventFactory** | `ActiveSession` 등 내부 모델 → sanitized DTO 변환, 민감 정보 및 permission 기반 필드 redaction (§6.3). **Sendable value type(struct)으로 구현**하여 runner fan-out task에서 안전하게 공유될 수 있도록 한다. |
| **PluginContributionRenderer** | `PluginUIComponentDTO` → SwiftUI 컴포넌트 변환 및 렌더링 |

### 4.3. 현재 소스코드 기준 연결점

현재 DevIsland에는 아직 `Plugins/` 계층이 없다. 첫 구현은 기존 hook/approval/UI 구조를 재배치하지 않고, 다음 파일에 얇은 연결점을 추가하는 방식으로 진행한다.

| 현재 파일 | 현재 책임 | 플러그인 연결 원칙 |
| :--- | :--- | :--- |
| `Bridge/HookSocketServer.swift` | TCP/Unix socket 수신, framed/raw 응답 전달 | 변경하지 않는다. socket·IPC 경로는 플러그인을 모른다. |
| `Bridge/HookEventHandler.swift` | raw/envelope payload를 `ParsedHookEvent`로 파싱 | `PluginEventFactory` 입력으로만 사용한다. raw payload는 플러그인에 직접 전달하지 않는다. |
| `Bridge/HookEventNormalizer.swift` | provider별 event 이름과 approval event 정규화 | session/hook event kind 매핑에 재사용한다. |
| `Core/AppState.swift` | hook 분류, session/pending queue 업데이트, approval 응답 | 분류와 core 상태 업데이트가 끝난 뒤 `PluginHost.enqueue`만 호출한다. 플러그인 결과를 기다리지 않는다. |
| `Session/SessionStore.swift`, `Session/SessionTypes.swift` | `ActiveSession`, `PendingRequest`, pending queue 소유 | `PluginSessionSnapshot`의 원천이다. 플러그인이 직접 접근하지 않는다. |
| `Core/DevIslandApp.swift` | `MenuBarExtra`와 `MenuBarMenu` 구성 | `menubar.menu` contribution을 기존 menu 안에 끼워 넣는다. 새 `MenuBarExtra`를 만들지 않는다. |
| `UI/NotchView.swift` | expanded notch header, approval/session content 렌더링 | `notch.expanded.*` contribution renderer를 기존 content 사이에 삽입한다. |
| `UI/NotchComponents.swift` | `SessionRowView`, 세션 context menu | `notch.session.row`, `session.context-menu` slot의 장기 연결점이다. |
| `UI/SessionMessageWindow.swift` | 세션별 팝아웃 메시지 창 | `session.message` slot의 장기 연결점이다. |
| `Settings/SettingsWindow.swift` | `TabView` 기반 설정 창 | v1은 host-owned `PluginSettingsView`를 별도 탭 또는 `IntegrationsSettingsPane` 하단에 붙인다. |
| `Approval/SQLiteApprovalStore.swift` | approval rules, replay, PTY transcript DB | 플러그인 저장소와 공유하지 않는다. 플러그인은 별도 namespace/db를 사용한다. |

`AppState`는 현재 타입 전체가 `@MainActor`로 선언되어 있지는 않지만, socket 수신은 main queue로 전달되고 `SessionStore`·노치 UI 상태는 main thread에서 갱신된다. 따라서 플러그인 연결은 `AppState`를 대규모로 actor화하지 않고, main-thread core 상태 갱신이 끝난 뒤 `@MainActor PluginHost`에 DTO를 넘기는 방식이 가장 작다.

`PluginHost` 소유권은 `AppState`에 둔다. `AppState.shared.pluginHost`를 SwiftUI view가 관찰하고, `AppState`만 `PluginHost.enqueue(_:)`를 호출한다. 플러그인 시스템을 전역 singleton으로 따로 두면 `SessionStore`·Settings·Notch UI와 생명주기 순서가 흐려지므로 피한다.

### 4.4. AppState 이벤트 발행 위치

플러그인 이벤트는 기존 provider response를 바꾸면 안 된다. 아래 위치에서 **best-effort 관찰 이벤트**로만 발행한다.

| PluginEventKind | 현재 코드 기준 발행 위치 | 주의점 |
| :--- | :--- | :--- |
| `hook.received` | `handleParsedEvent`에서 `HookEventNormalizer`와 `recordReplayHookEvent` 이후 | raw payload 대신 `PluginHookSummary`만 전달한다. 이 이벤트 처리 결과는 response에 영향을 주지 않는다. |
| `session.started` | `handleNotificationEvent`의 `isStartEvent` 처리 후 `SessionStore.updateActiveSession`이 끝난 뒤 | Codex superseded session 제거 후 새 세션 기준으로 발행한다. |
| `session.updated` | notification, auto-approval, policy approval, manual request enqueue 등으로 `ActiveSession`이 갱신된 뒤 | `PendingRequest.responseHandler`나 approval decision에는 접근하지 않는다. |
| `session.ended` | `handleStopEvent`, `dismissSession`, inactive pruning, Codex superseded session removal 직후 | 해당 session의 `session.*` contribution을 즉시 evict한다. |
| `notification.shown` | `handleNotificationEvent`에서 실제 노치 확장 또는 unread 표시가 발생한 뒤 | 모든 notification hook이 아니라 사용자에게 표시된 상태 변화만 대상으로 한다. |
| `approval.decided` | `sendDecision` 또는 approval 요청에 대한 automatic/policy response가 이미 전송되고 replay decision 기록 요청이 enqueue된 뒤 | v1 첫 구현에서는 후순위다. 발행하더라도 관찰 전용이며 approval 결과를 바꾸지 못한다. SQLite 기록 완료를 기다리지 않는다. |

`respondWithReplay`는 notification에도 decision log를 남기므로, `approval.decided`를 단순히 모든 `respondWithReplay` 호출에 붙이면 noise가 커진다. 이 이벤트는 `isApproval == true`였던 요청, `PendingRequest`, 또는 `ApprovalPolicyDecision`에서 나온 결정으로 제한한다.

## 5. 권한 모델 (Permission Model)

```swift
enum PluginPermission: String, Codable, Hashable {
    case readSessionEvents
    case readHookSummaries
    case readTerminalMetadata
    case showNotchCard
    case showSessionSurface
    case showMenubarMenu
    case showNotification
    case writePluginStorage
}
```

| Permission | 설명 |
| :--- | :--- |
| `readSessionEvents` | 세션 시작·갱신·종료 이벤트를 수신한다. |
| `readHookSummaries` | raw payload가 아닌 hook 요약 DTO를 수신한다. |
| `readTerminalMetadata` | 터미널 앱 이름, cwd 등 제한된 메타데이터를 수신한다. |
| `showNotchCard` | notch expanded 영역에 선언형 card를 제공한다. |
| `showSessionSurface` | v1.1 이후 세션 행·세션 메시지·세션 context menu에 선언형 accessory를 제공한다. |
| `showMenubarMenu` | menubar 메뉴(`menubar.menu`)에 선언형 menu item을 제공한다. |
| `showNotification` | DevIsland가 렌더링하는 제한된 알림을 요청한다. |
| `writePluginStorage` | 플러그인 전용 격리 저장소에만 읽기·쓰기를 수행한다. |

surface permission 매핑:

| Surface | 필요 permission |
| :--- | :--- |
| `notch.*` | `showNotchCard` |
| `menubar.menu` | `showMenubarMenu` |
| `session.*`, `notch.session.row` | `showSessionSurface` |

`PluginHost`는 플러그인 등록 시 manifest의 `surfaces`와 `permissions`를 검증한다. 권한 없는 surface는 등록 실패 또는 surface drop으로 처리하며, 렌더링 단계에서 다시 판단하지 않는다.

v1 제외 권한:

| Permission | 제외 이유 |
| :--- | :--- |
| `readRawPayload` | provider별 민감 정보가 포함될 수 있다. |
| `readPtyTranscript` | 명령 출력과 사용자 입력이 포함될 수 있다. |
| `networkAccess` | 데이터 유출 위험. 별도 동의와 감사 로그가 필요하다. |
| `runProcess` | 앱 안정성과 시스템 안전성에 직접 영향을 준다. |

## 6. 데이터 모델 (Data Models)

### 6.1. PluginManifest

```swift
struct PluginManifest: Codable {
    let id: String                         // reverse-DNS, e.g. "com.devisland.timer"
    let name: String
    let version: String
    let apiVersion: Int                    // 현재 1
    let kind: PluginKind
    let permissions: Set<PluginPermission>
    let surfaces: [PluginUISlot]           // 기여할 슬롯 목록 — PluginRunner가 필터링에 사용
    let activationEvents: [String]         // PluginEventKind.rawValue 문자열
}
```

v1 manifest는 built-in plugin 검증을 위한 최소 필드만 가진다.
VS Code식 `contribution point`와 세분화된 `capabilities` 필드는 v2 external runtime 또는 declarative preset에서 추가한다.
v1에서는 `surfaces`가 정적 contribution point 역할을 하고, `permissions`가 사용할 수 있는 capability의 상한을 표현한다.

manifest 예시 (`coreAware`):

```json
{
  "id": "com.devisland.timer",
  "name": "Session Timer",
  "version": "1.0.0",
  "apiVersion": 1,
  "kind": "coreAware",
  "permissions": ["readSessionEvents", "showNotchCard", "writePluginStorage"],
  "surfaces": ["notch.expanded.activity"],
  "activationEvents": ["session.started", "session.updated", "session.ended", "plugin.tick"]
}
```

manifest 예시 (`utility`):

```json
{
  "id": "com.devisland.pomodoro",
  "name": "Pomodoro",
  "version": "1.0.0",
  "apiVersion": 1,
  "kind": "utility",
  "permissions": ["showNotchCard", "showMenubarMenu", "writePluginStorage", "showNotification"],
  "surfaces": ["notch.expanded.activity", "menubar.menu"],
  "activationEvents": ["plugin.started", "plugin.tick", "plugin.action.invoked"]
}
```

### 6.2. PluginEventKind

```swift
enum PluginEventKind: String, Codable {
    case appStarted            = "app.started"
    case sessionStarted        = "session.started"
    case sessionUpdated        = "session.updated"
    case sessionEnded          = "session.ended"
    case hookReceived          = "hook.received"
    case approvalDecided       = "approval.decided"      // optional, response 이후 관찰 전용
    case notificationShown     = "notification.shown"
    case settingsChanged       = "settings.changed"
    case pluginStarted         = "plugin.started"
    case pluginTick            = "plugin.tick"
    case pluginActionInvoked   = "plugin.action.invoked"
}
```

`activationEvents`는 `PluginEventKind.rawValue`와 동일한 문자열을 사용한다. manifest와 enum이 어긋나지 않도록 raw value를 명시한다.

`plugin.tick`은 `needsTick(surfaceState:) == true`인 플러그인이 하나라도 있을 때만 발행한다. `PluginHost`가 중앙에서 1Hz로 예약하고 개별 플러그인은 자체 타이머를 갖지 않는다.

`plugin.action.invoked`는 플러그인이 반환한 declarative UI의 button·toggle 등에서 사용자 액션이 발생하고, 해당 action의 `routing == .pluginEvent`일 때만 DevIsland가 permission과 capability를 검증한 뒤 대상 플러그인 하나에 되돌려 보낸다. `routing == .hostExecuted`인 action은 DevIsland가 즉시 처리한다.

`approval.decided`는 사용자가 승인/거부를 확정한 뒤 발행되는 **관찰 전용** 이벤트다. `AppState`가 provider response를 이미 보낸 후 sanitized `PluginApprovalSummary`만 전달하며, 플러그인은 결과를 집계·기록할 수 있을 뿐 결정을 바꾸거나 되돌릴 수 없다(Isolation 원칙). 승인 메트릭·통계 같은 `coreAware` 플러그인을 위한 것이며, `readHookSummaries` 권한이 있어야 수신한다. v1 첫 구현에서는 필수가 아니며, session/UI 확장이 안정화된 뒤 추가한다.

### 6.3. PluginEvent

```swift
struct PluginEvent: Codable {
    let id: UUID
    let kind: PluginEventKind
    let timestamp: Date
    let session: PluginSessionSnapshot?
    let hook: PluginHookSummary?
    let action: PluginActionEvent?
    let approval: PluginApprovalSummary?
}

/// ActiveSession의 sanitized subset.
/// terminalTTY, tmux socket·client 등 내부 상태는 노출하지 않는다.
struct PluginSessionSnapshot: Codable {
    let id: String
    let agentKind: String        // "claude", "gemini", "codex"
    let startTime: Date
    let lastActiveAt: Date
    let lastToolName: String
    let lastEventName: String
    let workspaceRoot: String?
}

struct PluginHookSummary: Codable {
    let provider: String         // "claude", "gemini", "codex"
    let eventType: String        // "pretooluse", "notification", etc.
    let commandSummary: String?  // 전체 CLI가 아닌 DevIsland가 redact한 요약
    let cwd: String?
    let terminalApp: String?
}

/// plugin.action.invoked 이벤트에만 포함된다.
struct PluginActionEvent: Codable {
    let pluginID: String         // action 대상 pluginID. 다른 플러그인에는 dispatch하지 않는다.
    let actionID: String         // PluginUIActionDTO.id
    let componentID: String      // PluginUIComponentDTO.id
    let value: String?
}

/// approval.decided 이벤트에만 포함된다. 승인 결과를 관찰만 한다 — 결정을 바꿀 수 없다.
struct PluginApprovalSummary: Codable {
    let sessionID: String
    let approved: Bool
    let toolName: String
    let scope: String            // 적용 범위: "once", "session", "global"
}
```

`commandSummary` redaction 대상: secret-looking token, absolute home path, 긴 heredoc body.

**permission 기반 필드 redaction**: `isEventAllowed`는 이벤트 종류만 게이팅하므로, 필드 단위 권한은 `PluginEventFactory`가 DTO를 만들 때 적용한다.
- `readTerminalMetadata`가 없으면 `PluginHookSummary.terminalApp`·`cwd`를 `nil`로 redact한다.
- `readSessionEvents`가 없는 플러그인에 hook 이벤트를 보낼 때는 `PluginEvent.session` 스냅샷을 첨부하지 않는다(session 데이터는 `readSessionEvents` 전용).

### 6.4. DevIslandPlugin 프로토콜

```swift
protocol DevIslandPlugin: AnyObject {
    var manifest: PluginManifest { get }

    /// PluginRunner(actor)가 이벤트를 순차 전달한다.
    /// v1 built-in plugin API는 actor reentrancy를 피하기 위해 동기 함수로 둔다.
    /// 외부 I/O나 긴 작업은 직접 수행하지 않고 PluginEffect로 Host에 요청한다.
    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect]

    /// onEvent 직후 PluginRunner가 manifest.surfaces에 해당하는 슬롯만 호출한다.
    /// 렌더링 경로에서는 호출되지 않는다.
    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution?

    /// PluginHost가 plugin.tick 발행 여부를 판단하는 데 사용한다.
    /// 플러그인은 실행 중인 timer, visible surface 등으로 tick 필요 여부를 결정한다.
    func needsTick(surfaceState: PluginSurfaceState) -> Bool
}
```

**플러그인은 plain `final class`로 작성한다.** 가변 상태 보호는 플러그인을 감싸는 `PluginRunner`(actor)가 담당하므로 플러그인 작성자가 직접 actor를 다룰 필요가 없다. 플러그인 인스턴스는 `PluginRunner` 외부로 노출되지 않으며, 모든 호출이 runner의 actor executor를 통과한다. v1 API를 동기 함수로 제한하므로 `await` 지점에서 actor가 재진입해 같은 플러그인 상태를 동시에 만지는 위험을 피한다.

v1 built-in plugin은 앱 프로세스 안에서 실행되므로 완전한 crash isolation을 제공하지 않는다. 플러그인 호출은 `PluginRunner` 내부에서 동기적으로 실행되며, `PluginHost`가 전체 dispatch를 background task로 예약해 hook response path를 기다리지 않게 한다. 강제 종료 수준의 isolation이 필요하면 v2 worker process에서 처리한다.

### 6.5. 실행 컨텍스트와 Effect

```swift
/// onEvent에 전달되어 플러그인이 자신의 권한 범위를 확인할 수 있다.
struct PluginContext {
    let pluginID: String
    let permissions: Set<PluginPermission>
    let storageSnapshot: [String: String]
}

/// 플러그인이 직접 수행하지 않고 Host에 위임하는 side effect.
/// capability는 §8 capability↔permission 매핑으로 Host가 검증한다.
struct PluginEffect: Codable {
    let capability: String
    let payload: [String: String]
}
```

`PluginContext.storageSnapshot`은 `PluginEventProcessor`가 runner 호출 직전에 플러그인 전용 storage에서 읽어온 작은 read-only snapshot이다.
v1 플러그인 API가 동기 함수이므로 플러그인은 storage를 직접 비동기로 읽지 않는다.
초기 상태 복원이 필요한 built-in plugin은 `plugin.started` 또는 첫 event에서 snapshot을 읽어 내부 상태를 복원한다.
storage write effect는 event 처리 이후 비동기로 커밋되므로, 플러그인은 방금 반환한 storage effect를 같은 event 안에서 다시 읽을 수 있다고 가정하지 않는다. v1 built-in plugin의 화면 상태는 플러그인 내부 메모리 상태가 기준이고, storage는 재시작 후 복원을 위한 durable cache로 취급한다.

### 6.6. UI Contribution

```swift
struct PluginUIContext {
    let slot: PluginUISlot
    let timestamp: Date
    let session: PluginSessionSnapshot?   // session.* 슬롯에서만 채워진다 (대상 세션)
}

struct PluginSurfaceState: Codable {
    let visibleSurfaces: Set<PluginUISlot>
}

struct PluginUIContribution: Codable {
    let pluginID: String
    let slot: PluginUISlot
    let targetSessionID: String?  // session.* 슬롯이면 대상 sessionID, 전역 슬롯이면 nil
    let priority: Int             // 낮을수록 앞에 표시, 동일 priority는 pluginID 알파벳 순
    let expiresAt: Date?          // nil이면 다음 갱신까지 유지; 만료 시 해당 슬롯에서 제거
    let components: [PluginUIComponentDTO]
}

struct PluginUIComponentDTO: Codable {
    let id: String?                    // action 라운드트립에 사용. action이 있으면 필수
    let type: PluginUIComponentType    // .metric, .badge, .button, .text
    let label: String?
    let value: String?
    let tone: PluginUITone?            // .default, .success, .warning, .error
    let iconName: String?              // SF Symbol name; 유효하지 않으면 drop
    let action: PluginUIActionDTO?
}

struct PluginUIActionDTO: Codable {
    let id: String           // plugin.action.invoked 이벤트의 actionID와 매핑
    let capability: String   // "timer.startStop", "storage.increment" 등
    let routing: PluginActionRouting
    let payload: [String: String]
}

enum PluginActionRouting: String, Codable {
    case hostExecuted
    case pluginEvent
}

enum PluginUIComponentType: String, Codable {
    case metric   // label + value (예: "Elapsed" / "12:34")
    case badge    // 짧은 상태 텍스트 + tone
    case button   // action을 가진 누를 수 있는 컴포넌트
    case text     // 단일 라인 텍스트
}

enum PluginUITone: String, Codable {
    case `default`
    case success
    case warning
    case error
}
```

DevIsland는 지원하지 않는 component type, 너무 긴 text, 잘못된 iconName은 drop하거나 fallback rendering한다.

### 6.7. Action Routing

플러그인 UI action은 DevIsland가 검증한 뒤 두 방식 중 하나로 처리한다.

| Routing | 처리 주체 | 예시 | 용도 |
| :--- | :--- | :--- | :--- |
| `hostExecuted` | DevIsland host가 즉시 실행 | `storage.increment`, `notification.show` | declarative preset처럼 코드가 없는 기능 |
| `pluginEvent` | DevIsland가 `plugin.action.invoked` 이벤트로 되돌려 보냄 | `timer.startStop`, `plugin.customAction` | built-in plugin 내부 상태 변경 |

`hostExecuted` 액션 탭은 Host가 `PluginEffect(capability:payload:)`로 변환해 `onEvent`가 반환하는 effect와 **동일한 effect processor**를 탄다. 즉 effect 실행 경로는 하나이며, 진입점만 (버튼 탭 / onEvent 반환) 둘이다.

v1 built-in plugin은 `pluginEvent` routing을 사용할 수 있다.
v2 declarative preset은 임의 로직이 없으므로 기본적으로 `hostExecuted` capability만 허용한다.

### 6.8. PluginContributionSnapshot

`PluginRunner`가 `onEvent` → `makeUIContribution` 처리 후 `PluginHost`에 반환하는 결과 묶음이다.

```swift
struct PluginContributionSnapshot {
    let pluginID: String
    let contributions: [PluginUISlot: PluginUIContribution]  // surfaces 필터 통과한 슬롯만 포함
    let effects: [PluginEffect]
    let failure: PluginFailure?
    let timestamp: Date
}

struct PluginFailure {
    let pluginID: String
    let message: String
    let occurredAt: Date
    let clearsContribution: Bool
}
```

## 7. UI 확장 슬롯 (Target Slots)

```swift
enum PluginUISlot: String, Codable, CaseIterable {
    case notchCompactLeading   = "notch.compact.leading"
    case notchCompactTrailing  = "notch.compact.trailing"
    case notchExpandedActivity = "notch.expanded.activity"
    case notchExpandedDetails  = "notch.expanded.details"
    case notchSessionRow       = "notch.session.row"
    case menubarMenu           = "menubar.menu"
    case sessionDetailTimeline = "session.detail.timeline"
    case sessionDetailSummary  = "session.detail.summary"
    case sessionContextMenu    = "session.context-menu"
    case sessionMessage        = "session.message"
}
```

| Slot rawValue | 위치 | 용도 | scope | 도입 |
| :--- | :--- | :--- | :--- | :--- |
| `notch.expanded.activity` | Expanded Notch 상단 | 현재 세션 메트릭 (예: 소요 시간) | 전역 | v1 |
| `menubar.menu` | MenuBarExtra 드롭다운(`MenuBarMenu`) | 메인 메뉴에 끼워넣는 menu item·소형 패널 | 전역 | v1 |
| `notch.session.row` | Expanded Notch 세션 행(`SessionRowView`) | 세션 행별 배지·상태 accessory | 세션 | v1.1 |
| `notch.expanded.details` | Expanded Notch 하단 | 추가 메타데이터 (예: PR 번호, 브랜치) | 전역 | v1.1 |
| `session.context-menu` | 세션 우클릭 메뉴 (노치·세션 히스토리) | 세션 대상 액션 menu item | 세션 | v1.1 |
| `session.message` | 세션 메시지 창(`SessionMessageView`) 헤더/툴바 | 세션별 부가 정보 accessory | 세션 | v1.1 |
| `session.detail.timeline` | 세션 히스토리 타임라인 | 특정 시점의 주석 (Annotation) | 세션 | v2 |
| `session.detail.summary` | 세션 상세 상단 | 세션별 요약 카드 | 세션 | v2 |
| `notch.compact.leading` | Collapsed Notch 왼쪽 | 에이전트 상태 배지 옆 부가 정보 | 전역 | v2 |
| `notch.compact.trailing` | Collapsed Notch 오른쪽 | 알림 개수나 작은 아이콘 | 전역 | v2 |

`menubar.menu`는 메뉴 스타일 `MenuBarExtra`의 top-level `MenuBarMenu`에 직접 렌더링한다. 별도 window popover(`.menuBarExtraStyle(.window)`)는 현재 구현과 다르므로 v2로 미룬다.

첫 구현은 `notch.expanded.activity`, `menubar.menu` 두 슬롯만 연다. 설정 화면은 플러그인 contribution slot이 아니라 DevIsland host가 manifest·enable 상태·safemode·storage 삭제 기능을 렌더링하는 `PluginSettingsView`다. 플러그인별 custom settings schema는 v1.1 이후 별도로 검토한다.
`SessionRowView`, `SessionMessageView`, `SessionHistoryWindow`에 닿는 세션별 슬롯은 UI 접점이 여러 곳이라 v1.1로 분리한다. collapsed notch 슬롯은 현재 mascot/unread dot 레이아웃과 충돌 가능성이 높으므로 v2에서 별도 compact renderer를 설계한다.

슬롯별 제약: 최대 contribution 수, 텍스트 최대 길이, 우선순위 정렬 기준은 각 슬롯 렌더러가 정의한다. 동일 priority는 pluginID 알파벳 순으로 deterministic ordering을 적용한다.

**slot scope (전역 vs 세션)**: `session.*` 슬롯은 특정 세션에 종속된다. 해당 contribution은 `targetSessionID`를 채우고, `PluginUIContext.session`으로 대상 세션 스냅샷을 받는다. 렌더러는 우클릭/상세 대상 세션의 `targetSessionID`로 필터링한다. 캐시 dedup도 `(pluginID, targetSessionID)` 기준이며, `session.ended` 이벤트 수신 시 Host가 해당 `targetSessionID` contribution을 evict한다. 전역 슬롯은 `targetSessionID == nil`로 둔다.

## 8. Utility Plugin 모델

`utility` 플러그인은 DevIsland hook·session과 무관하게 동작하는 독립 기능이다. v1에서는 앱에 컴파일된 built-in Swift 구현만 허용한다.

`utility` 플러그인이 DevIsland core 상태에 접근하지 않는 대신, DevIsland가 제공하는 제한된 capability를 통해 동작한다.

v1 허용 capability와 이를 허가하는 permission 매핑은 다음과 같다. `PluginHost`는 effect/action을 실행하기 전 이 표로 권한을 검증하고, 매핑되지 않은 capability나 permission 없는 호출은 거부한다.

| Capability | 필요 permission | 설명 |
| :--- | :--- | :--- |
| `timer.tick` | (없음) | PluginHost 중앙 tick 구독. 민감 자원에 접근하지 않아 permission 불필요 |
| `timer.startStop` | (없음) | 플러그인 내부 타이머 on/off (`plugin.action.invoked`로 트리거). 내부 상태만 변경 |
| `storage.keyValue` | `writePluginStorage` | effect processor가 격리 저장소 read/write 수행 |
| `storage.increment` | `writePluginStorage` | effect processor가 카운터 atomic 증가 수행 |
| `notification.show` | `showNotification` | DevIsland 알림 렌더링 요청 |

`timer.*`처럼 민감 자원에 접근하지 않고 플러그인 내부 상태만 다루는 capability는 permission 없이 허용한다. 외부 자원(저장소, 알림 등)에 닿는 capability는 반드시 대응 permission을 manifest에 선언해야 한다.

`PomodoroPlugin` built-in 구현 예시:

```swift
final class PomodoroPlugin: DevIslandPlugin {
    let manifest = PluginManifest(
        id: "com.devisland.pomodoro",
        name: "Pomodoro",
        version: "1.0.0",
        apiVersion: 1,
        kind: .utility,
        permissions: [.showNotchCard, .showMenubarMenu, .writePluginStorage, .showNotification],
        surfaces: [.notchExpandedActivity, .menubarMenu],
        activationEvents: [
            PluginEventKind.pluginStarted.rawValue,
            PluginEventKind.pluginTick.rawValue,
            PluginEventKind.pluginActionInvoked.rawValue
        ]
    )

    private enum Mode { case idle, running, paused }
    private var mode: Mode = .idle
    private var remainingSeconds: Int = 25 * 60
    private var completedCount: Int = 0

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        mode == .running
            || surfaceState.visibleSurfaces.contains(.notchExpandedActivity)
            || surfaceState.visibleSurfaces.contains(.menubarMenu)
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        switch event.kind {
        case .pluginTick:
            if mode == .running {
                remainingSeconds = max(0, remainingSeconds - 1)
                if remainingSeconds == 0 {
                    completedCount += 1
                    mode = .idle
                    return [
                        PluginEffect(
                            capability: "notification.show",
                            payload: [
                                "title": "Pomodoro",
                                "body": "Focus session complete"
                            ]
                        )
                    ]
                }
            }
        case .pluginActionInvoked:
            guard event.action?.actionID == "pomodoro.toggle" else { break }
            switch mode {
            case .idle, .paused: mode = .running
            case .running: mode = .paused
            }
        default:
            break
        }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        let mm = remainingSeconds / 60
        let ss = remainingSeconds % 60
        let label = mode == .running ? "Focus" : (mode == .paused ? "Paused" : "Idle")
        let components: [PluginUIComponentDTO]
        switch slot {
        case .notchExpandedActivity:
            components = [
                PluginUIComponentDTO(id: "timer", type: .metric,
                    label: label, value: String(format: "%02d:%02d", mm, ss),
                    tone: mode == .running ? .success : nil, iconName: nil, action: nil),
                PluginUIComponentDTO(id: "toggle", type: .button,
                    label: mode == .running ? "Pause" : "Start", value: nil, tone: nil, iconName: nil,
                    action: PluginUIActionDTO(id: "pomodoro.toggle",
                                             capability: "timer.startStop",
                                             routing: .pluginEvent,
                                             payload: [:]))
            ]
        case .menubarMenu:
            components = [
                PluginUIComponentDTO(id: "timer", type: .metric,
                    label: "Pomodoro", value: String(format: "%02d:%02d", mm, ss),
                    tone: mode == .running ? .success : nil, iconName: "timer", action: nil),
                PluginUIComponentDTO(id: "count", type: .text,
                    label: "Completed", value: "\(completedCount)", tone: nil, iconName: nil, action: nil),
                PluginUIComponentDTO(id: "toggle", type: .button,
                    label: mode == .running ? "Pause" : "Start", value: nil, tone: nil, iconName: nil,
                    action: PluginUIActionDTO(id: "pomodoro.toggle",
                                             capability: "timer.startStop",
                                             routing: .pluginEvent,
                                             payload: [:]))
            ]
        default:
            return nil
        }
        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: nil,   // utility = 전역 슬롯
            priority: 20,
            expiresAt: context.timestamp.addingTimeInterval(2),
            components: components
        )
    }
}
```

## 9. 저장소 경계 (Storage)

플러그인 저장소는 plugin ID별로 격리한다.

```text
~/Library/Application Support/DevIsland/PluginData/
  com.devisland.timer/
    storage.sqlite
  com.devisland.pomodoro/
    storage.sqlite
```

```swift
protocol PluginStorage {
    func snapshot(limit: Int) async throws -> [String: String]
    func get(_ key: String) async throws -> String?
    func set(_ key: String, value: String) async throws
    func delete(_ key: String) async throws
    func increment(_ key: String, by delta: Int) async throws -> Int
}
```

플러그인은 다른 플러그인의 저장소나 DevIsland core SQLite에 접근하지 않는다. 저장소 quota 초과 시 `writePluginStorage` 작업은 오류를 반환하고 core flow에는 영향을 주지 않는다.
v1 플러그인 API는 동기 함수이므로 built-in plugin이 `PluginStorage`를 직접 호출하지 않는다. 저장소 변경은 `PluginEffect(capability: "storage.*")`로 요청하고, `PluginHost`의 effect processor가 비동기 storage 작업을 수행한다.
`snapshot(limit:)`은 context 주입용으로만 사용한다. Host는 plugin별 quota와 key/value 길이 제한을 적용한 뒤 작은 dictionary만 전달하며, snapshot이 필요한 runner에 대해서만 호출한다.

현재 `Approval/SQLiteApprovalStore.swift`의 `approval-proxy.sqlite3`는 rules, replay log, PTY transcript의 durable store다. 플러그인 저장소는 이 DB나 `AppState.approvalPersistenceQueue`를 공유하지 않는다. `PluginStorageProvider`는 별도 actor 또는 전용 serial queue를 사용해 plugin storage I/O가 approval persistence와 hook response path를 막지 않게 한다.

## 10. 구현 가이드라인 (Implementation Guidelines)

### 10.1. 스레드 안전성 및 성능

- **PluginRunner는 `actor`로 구현**: 플러그인 가변 상태를 actor isolation으로 보호하고 이벤트 처리 순서를 보장한다.
- **Event ordering 보장**: `PluginHost`가 MainActor에서 FIFO `pendingEvents`에 event를 넣어 enqueue 순서를 확정한다. 한 event 안에서는 여러 `PluginRunner`를 병렬 실행할 수 있지만, 다음 event는 이전 event 처리가 끝난 뒤 처리한다.
- **AppState handoff 순서**: `AppState`는 `SessionStore`나 노치 표시 상태를 실제로 변경한 지점에서 곧바로 `PluginHost.enqueue(_:)`를 호출한다. 터미널 포커스 확인처럼 비동기 callback을 거치는 흐름은 raw hook 도착 순서가 아니라 실제 UI/session 상태 변경 순서가 플러그인 이벤트 순서가 된다.
- **Contribution Cache는 일괄 교체**: 루프 안에서 `@Published` 프로퍼티를 반복 수정하지 않고, 모든 runner가 완료된 뒤 한 번만 교체하여 SwiftUI 업데이트를 단일화한다.
- **Non-Blocking Dispatch**: `enqueue`는 이벤트를 FIFO에 넣고 즉시 반환한다. `AppState`는 `drainEvents`나 runner 실행을 기다리지 않는다. `AppState`가 MainActor 밖에서 동작해야 한다면 전용 serial dispatcher를 통해 MainActor `enqueue`로 넘겨 순서를 보존한다.
- **Hook/approval path 분리**: `HookSocketServer`, bridge script, `ProviderAdapter`, `ApprovalProxyController`는 플러그인 의존성을 갖지 않는다. 플러그인 실패·storage 오류·UI contribution 오류는 provider response JSON을 바꾸지 않는다.
- **Built-in 구현 제한**: 긴 계산, blocking 파일 I/O, force unwrap은 v1 built-in plugin에서 피한다.
- **Timeout**: built-in plugin의 `onEvent` + `makeUIContribution` 합산 목표 50ms. v1 built-in 호출은 강제 중단할 수 없으므로 실행 시간을 측정해 초과 시 safemode 카운터를 증가시키고, blocking 작업은 코드 리뷰와 테스트로 금지한다.

### 10.2. PluginHost 핵심 구현

```swift
@MainActor
final class PluginHost: ObservableObject {
    @Published private(set) var contributions: [PluginUISlot: [PluginUIContribution]] = [:]

    private var runners: [String: PluginRunner] = [:]  // keyed by pluginID
    private let storageProvider = PluginStorageProvider()
    private let eventFactory = PluginEventFactory()
    private lazy var eventProcessor = PluginEventProcessor(
        storageProvider: storageProvider,
        eventFactory: eventFactory
    )
    private lazy var effectExecutor = PluginEffectExecutor(storageProvider: storageProvider)
    private var pendingEvents: [QueuedPluginEvent] = []
    private var isDraining = false
    private var visibleSurfaces: Set<PluginUISlot> = []  // UI 레이어가 보고 (10.5 참고)
    private var tickTask: Task<Void, Never>?             // 1Hz tick 루프

    /// AppState가 이벤트를 전달하면 MainActor에서 FIFO 순서를 먼저 확정한다.
    /// AppState는 hook/session 흐름의 serial context에서 이 메서드를 호출해야 한다.
    func enqueue(_ baseEvent: PluginEvent) {
        let eligible = runners.values.filter { shouldDispatch(baseEvent, to: $0) }
        pendingEvents.append(QueuedPluginEvent(baseEvent: baseEvent, runners: eligible))
        guard !isDraining else { return }
        isDraining = true

        Task {
            await drainEvents()
        }
    }

    private func shouldDispatch(_ event: PluginEvent, to runner: PluginRunner) -> Bool {
        guard !isInSafemode(runner.manifest.id) else { return false }
        if let targetPluginID = event.action?.pluginID,
           targetPluginID != runner.manifest.id {
            return false
        }
        guard isEventAllowed(event, for: runner.manifest.permissions) else { return false }
        return runner.manifest.activationEvents.contains(event.kind.rawValue)
    }

    private func isEventAllowed(_ event: PluginEvent, for permissions: Set<PluginPermission>) -> Bool {
        switch event.kind {
        case .sessionStarted, .sessionUpdated, .sessionEnded:
            return permissions.contains(.readSessionEvents)
        case .hookReceived, .approvalDecided:
            return permissions.contains(.readHookSummaries)
        default:
            return true
        }
    }

    private func nextEvent() -> QueuedPluginEvent? {
        guard !pendingEvents.isEmpty else { return nil }
        return pendingEvents.removeFirst()
    }

    // PluginHost가 @MainActor이므로 이 메서드도 MainActor 격리 상태다.
    // nextEvent()·applySnapshots()·isDraining 접근은 별도 MainActor.run 래핑이 필요 없다.
    // eventProcessor.process(_:) await 지점에서만 MainActor가 풀려 다른 enqueue가 끼어들 수 있다.
    private func drainEvents() async {
        while let queued = nextEvent() {
            let snapshots = await eventProcessor.process(queued)
            applySnapshots(snapshots)
            // 세션 종료 시 해당 세션에 묶인 session.* contribution을 정리한다.
            if queued.baseEvent.kind == .sessionEnded, let sid = queued.baseEvent.session?.id {
                evictSessionContributions(sessionID: sid)
            }
        }
        isDraining = false
    }

    private func evictSessionContributions(sessionID: String) {
        var updated = contributions
        for slot in updated.keys {
            updated[slot]?.removeAll { $0.targetSessionID == sessionID }
        }
        contributions = updated
    }

    private func applySnapshots(_ snapshots: [PluginContributionSnapshot]) {
        var updated = contributions
        for snapshot in snapshots {
            if let failure = snapshot.failure {
                recordFailure(failure)
                if failure.clearsContribution {
                    updated = removeContributions(pluginID: snapshot.pluginID, from: updated)
                    continue
                }
            }
            processEffects(snapshot.effects, pluginID: snapshot.pluginID)
            for (slot, contribution) in snapshot.contributions {
                // 전역 슬롯은 (pluginID), 세션 슬롯은 (pluginID, targetSessionID)로 dedup.
                updated[slot, default: []].removeAll {
                    $0.pluginID == snapshot.pluginID && $0.targetSessionID == contribution.targetSessionID
                }
                updated[slot, default: []].append(contribution)
                updated[slot]?.sort { $0.priority == $1.priority
                    ? $0.pluginID < $1.pluginID
                    : $0.priority < $1.priority }
            }
        }
        contributions = updated  // @Published 단일 대입 → objectWillChange 1회
    }

    private func processEffects(_ effects: [PluginEffect], pluginID: String) {
        // Validate capability + permission on MainActor, then hand execution off.
        let allowed = effects.filter { isCapabilityAllowed($0.capability, forPluginID: pluginID) }
        Task {
            await effectExecutor.enqueue(allowed, pluginID: pluginID)
        }
    }

    private func recordFailure(_ failure: PluginFailure) {
        // Increment failure counters and enter safemode when threshold is reached.
    }
}
```

`PluginHost`는 `AppState`에서 생성하지만, `AppState`의 approval 관련 private 상태(`currentResponseHandler`, `PendingRequest.responseHandler`, `currentHookEventId`)를 넘겨받지 않는다. Host에 들어가는 입력은 `PluginEventFactory`가 만든 DTO뿐이다.

```swift
struct QueuedPluginEvent {
    let baseEvent: PluginEvent
    let runners: [PluginRunner]
}

/// 한 event 안에서 runner를 병렬(fan-out) 실행한다.
/// 자체적으로 큐잉하지 않으며, event 간 순서는 PluginHost의 MainActor FIFO pendingEvents가 보장한다.
actor PluginEventProcessor {
    private let storageProvider: PluginStorageProvider
    private let eventFactory: PluginEventFactory

    init(storageProvider: PluginStorageProvider,
         eventFactory: PluginEventFactory) {
        self.storageProvider = storageProvider
        self.eventFactory = eventFactory
    }

    func process(_ queued: QueuedPluginEvent) async -> [PluginContributionSnapshot] {
        var snapshots: [PluginContributionSnapshot] = []
        let storageProvider = self.storageProvider
        let eventFactory = self.eventFactory
        await withTaskGroup(of: PluginContributionSnapshot.self) { group in
            for runner in queued.runners {
                group.addTask {
                    let event = eventFactory.redactedEvent(
                        from: queued.baseEvent,
                        permissions: runner.manifest.permissions
                    )
                    let snapshot = runner.manifest.permissions.contains(.writePluginStorage)
                        ? await storageProvider.snapshot(forPluginID: runner.manifest.id)
                        : [:]
                    return await runner.handle(event, storageSnapshot: snapshot)
                }
            }
            for await snapshot in group {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }
}
```

`QueuedPluginEvent.baseEvent`는 AppState가 만든 sanitized base DTO다. 하지만 field-level redaction은 runner별 permission을 알아야 하므로, `PluginEventProcessor`가 각 runner 호출 직전에 `PluginEventFactory.redactedEvent(from:permissions:)`를 적용한다. 이 구조가 있어야 `readTerminalMetadata`가 없는 플러그인과 있는 플러그인이 같은 hook 이벤트를 구독해도 서로 다른 DTO를 받는다.
`PluginEventFactory`는 mutable 상태를 갖지 않는 `Sendable` value type으로 둔다. runner fan-out task 안에서 공유되므로, 내부 cache나 mutable formatter를 보관하지 않는다.

```swift
/// MainActor 밖에서 host-owned side effect를 실행한다.
/// storage I/O, notification scheduling 등은 여기서 처리한다.
actor PluginEffectExecutor {
    private let storageProvider: PluginStorageProvider

    init(storageProvider: PluginStorageProvider) {
        self.storageProvider = storageProvider
    }

    func enqueue(_ effects: [PluginEffect], pluginID: String) async {
        for effect in effects {
            await execute(effect, pluginID: pluginID)
        }
    }

    private func execute(_ effect: PluginEffect, pluginID: String) async {
        if effect.capability.hasPrefix("storage.") {
            await storageProvider.applyStorageEffect(effect, pluginID: pluginID)
            return
        }
        // notification.show -> notification presenter
        // unmapped capability -> ignore + log
    }
}
```

```swift
/// pluginID별 storage namespace를 관리한다.
/// snapshot은 읽기 전용 context 주입에, storage effect는 비동기 durable write에 사용한다.
actor PluginStorageProvider {
    func snapshot(forPluginID pluginID: String) async -> [String: String] {
        // storage(for: pluginID).snapshot(limit: 64), errors -> [:] + log
        [:]
    }

    func applyStorageEffect(_ effect: PluginEffect, pluginID: String) async {
        // "storage.keyValue" / "storage.increment" 등을 plugin namespace 안에서만 처리한다.
    }
}
```

### 10.3. PluginRunner 핵심 구현

```swift
actor PluginRunner {
    nonisolated let manifest: PluginManifest
    private let plugin: any DevIslandPlugin

    init(plugin: any DevIslandPlugin) {
        self.plugin = plugin
        self.manifest = plugin.manifest
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        plugin.needsTick(surfaceState: surfaceState)
    }

    func handle(_ event: PluginEvent,
                storageSnapshot: [String: String]) async -> PluginContributionSnapshot {
        var effects: [PluginEffect] = []
        var result: [PluginUISlot: PluginUIContribution] = [:]
        let startedAt = ContinuousClock.now
        do {
            let context = PluginContext(pluginID: manifest.id,
                                        permissions: manifest.permissions,
                                        storageSnapshot: storageSnapshot)
            effects = try plugin.onEvent(event, context: context)
            for slot in manifest.surfaces {
                let ctx = PluginUIContext(slot: slot, timestamp: event.timestamp, session: event.session)
                if let c = try plugin.makeUIContribution(for: slot, context: ctx) {
                    result[slot] = c
                }
            }
            let elapsed = startedAt.duration(to: ContinuousClock.now)
            return PluginContributionSnapshot(
                pluginID: manifest.id,
                contributions: result,
                effects: effects,
                failure: elapsed > .milliseconds(50)
                    ? PluginFailure(pluginID: manifest.id,
                                    message: "Plugin exceeded 50ms budget",
                                    occurredAt: event.timestamp,
                                    clearsContribution: false)
                    : nil,
                timestamp: event.timestamp
            )
        } catch {
            return PluginContributionSnapshot(
                pluginID: manifest.id,
                contributions: [:],
                effects: [],
                failure: PluginFailure(pluginID: manifest.id,
                                       message: String(describing: error),
                                       occurredAt: event.timestamp,
                                       clearsContribution: true),
                timestamp: event.timestamp
            )
        }
    }
}
```

`PluginRunner`가 `actor`이고 플러그인 API가 동기 함수이므로 `plugin.onEvent` 안에서 발생하는 플러그인 상태 변경은 자동으로 직렬화된다.
`manifest.surfaces`만 순회하므로 선언하지 않은 슬롯에는 `makeUIContribution`을 호출하지 않는다.

### 10.4. 오류 및 세이프모드 (Safemode)

- `PluginRunner`가 `onEvent` 또는 `makeUIContribution` 실행 중 thrown error나 timeout을 포착하면 `PluginHost`에 실패를 보고한다.
- **Safemode 임계값**: 60초 이내에 3회 이상 실패하면 해당 플러그인의 contribution cache를 비우고 Safemode로 전환한다.
- safemode 진입 시각, 마지막 오류 메시지, 마지막 성공 시각은 Settings UI에서 확인 가능하다.
- safemode 해제: 사용자가 명시적으로 Reset하거나 앱 재시작 후 1회 제한 재시도한다.
- `PluginHost`는 플러그인별 safemode 상태를 추적하고 `isInSafemode(_ pluginID: String) -> Bool`로 노출한다. safemode 플러그인은 이벤트 분배와 tick 대상에서 제외된다.
- v1 built-in plugin crash는 앱 crash로 이어질 수 있으므로, crash isolation은 v2 외부 worker runtime의 책임으로 둔다.

### 10.5. Tick 스케줄링

`PluginHost`가 1Hz 타이머를 소유하고, 매 tick마다 활성 runner에게 `needsTick(surfaceState:)`을 물어 하나라도 `true`이면 `plugin.tick` 이벤트를 `enqueue`한다. 아무도 tick이 필요 없으면 이벤트를 발행하지 않아 idle 비용을 낮춘다.

`PluginSurfaceState.visibleSurfaces`는 UI 레이어(Notch/MenuBar)가 표시 상태가 바뀔 때 `PluginHost`에 보고한다. 플러그인은 이 정보로 "보이는 동안만 갱신" 같은 판단을 한다.

```swift
@MainActor
extension PluginHost {
    /// UI 레이어가 surface 표시 상태 변경 시 호출한다.
    func setVisibleSurfaces(_ surfaces: Set<PluginUISlot>) {
        self.visibleSurfaces = surfaces
    }

    /// 앱 시작 시 1회 시작. Timer는 MainActor에서 동작한다.
    func startTicking() {
        guard tickTask == nil else { return }   // 중복 시작 방지
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tickIfNeeded()
            }
        }
    }

    /// 앱 종료 또는 plugin platform shutdown 시 호출한다.
    func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tickIfNeeded() async {
        let state = PluginSurfaceState(visibleSurfaces: visibleSurfaces)
        var anyNeedsTick = false
        for runner in runners.values where !isInSafemode(runner.manifest.id) {
            if await runner.needsTick(surfaceState: state) {
                anyNeedsTick = true
                break
            }
        }
        guard anyNeedsTick else { return }
        enqueue(PluginEvent(id: UUID(), kind: .pluginTick, timestamp: Date(),
                            session: nil, hook: nil, action: nil, approval: nil))
    }
}
```

`shouldDispatch`가 `activationEvents`로 한 번 더 필터링하므로, `plugin.tick`을 구독하지 않은 플러그인에는 tick 이벤트가 전달되지 않는다.

### 10.6. UI 액션 처리

`PluginContributionRenderer`가 그린 button·toggle을 사용자가 탭하면, 렌더러는 해당 component의 ID와 `PluginUIActionDTO`를 들고 `PluginHost.handleAction(pluginID:componentID:action:)`을 호출한다. Host는 capability·permission을 검증한 뒤 `routing`에 따라 분기한다.

- `hostExecuted`: action을 `PluginEffect`로 변환해 effect processor에 즉시 넘긴다. 플러그인 코드를 거치지 않는다.
- `pluginEvent`: `plugin.action.invoked` 이벤트를 만들어 `enqueue`한다. 플러그인 `onEvent`가 상태를 바꾸고 필요한 effect를 반환한다.

```swift
@MainActor
extension PluginHost {
    func handleAction(pluginID: String, componentID: String, action: PluginUIActionDTO) {
        guard !isInSafemode(pluginID),
              let runner = runners[pluginID],
              isCapabilityAllowed(action.capability, for: runner.manifest.permissions)
        else { return }

        switch action.routing {
        case .hostExecuted:
            // hostExecuted 액션도 동일한 effect processor를 탄다 (§6.7 참고).
            processEffects([PluginEffect(capability: action.capability, payload: action.payload)],
                           pluginID: pluginID)
        case .pluginEvent:
            let event = PluginEvent(
                id: UUID(), kind: .pluginActionInvoked, timestamp: Date(),
                session: nil, hook: nil,
                action: PluginActionEvent(pluginID: pluginID,
                                          actionID: action.id,
                                          componentID: componentID,
                                          value: nil),
                approval: nil
            )
            enqueue(event)
        }
    }

    /// §8 capability↔permission 매핑을 적용한다.
    private func isCapabilityAllowed(_ capability: String, for permissions: Set<PluginPermission>) -> Bool {
        // 예: "storage.*" → .writePluginStorage, "notification.show" → .showNotification,
        //     "timer.*" → permission 불필요(true).
        ...
    }

    /// pluginID로 runner의 permission을 찾아 위 매핑을 적용한다.
    /// 등록되지 않은 plugin이나 매핑되지 않은 capability는 거부한다.
    private func isCapabilityAllowed(_ capability: String, forPluginID pluginID: String) -> Bool {
        guard let runner = runners[pluginID] else { return false }
        return isCapabilityAllowed(capability, for: runner.manifest.permissions)
    }
}
```

`isCapabilityAllowed`와 `processEffects`는 동일한 매핑을 공유한다. 매핑되지 않은 capability는 거부한다.

### 10.7. Contribution 만료 처리

`expiresAt`이 설정된 contribution은 DevIsland가 렌더링 전 만료 여부를 확인하고, 만료된 경우 해당 슬롯에서 제거한다. `plugin.tick`이 발행 중인 플러그인은 매 tick마다 contribution을 갱신하므로 일반적으로 2초 이내 만료로 설정하면 충분하다.

## 11. 파일 레이아웃 (File Layout)

```text
DevIsland/
  Core/
    AppState.swift              — PluginHost 소유/주입, 분류 완료 후 PluginEvent 발행
    DevIslandApp.swift          — MenuBarMenu 안에 menubar.menu contribution 렌더러 삽입

  Bridge/
    HookEventHandler.swift      — ParsedHookEvent 입력 모델 유지 (plugin dependency 없음)
    HookEventNormalizer.swift   — PluginEventKind 매핑에 normalizedName 재사용

  Session/
    SessionTypes.swift          — ActiveSession → PluginSessionSnapshot 원천
    SessionStore.swift          — 직접 변경 최소화; session 변경 후 AppState가 event 발행

  Plugins/
    PluginHost.swift            — @MainActor ObservableObject, enqueue, cache 관리
    PluginEventProcessor.swift  — 한 이벤트의 runner를 fan-out 병렬 실행 (큐잉·순서 보존은 PluginHost가 담당)
    PluginEffectExecutor.swift  — storage/notification 등 host-owned side effect 비동기 실행
    PluginRunner.swift          — actor, handle(_:), timeout 측정, PluginFailure 생성
    PluginProtocol.swift        — DevIslandPlugin, PluginManifest, PluginKind,
                                  PluginContext, PluginEffect
    PluginEvent.swift           — PluginEvent, PluginEventKind, PluginSessionSnapshot,
                                  PluginHookSummary, PluginActionEvent, PluginApprovalSummary
    PluginUIContribution.swift  — PluginUIContribution, PluginUISlot, PluginUIComponentDTO,
                                  PluginUIActionDTO, PluginActionRouting, PluginUIComponentType,
                                  PluginUITone, PluginUIContext, PluginSurfaceState,
                                  PluginContributionSnapshot, PluginFailure
    PluginPermission.swift      — PluginPermission enum, capability↔permission 매핑
    PluginStorage.swift         — PluginStorage protocol, PluginStorageProvider, SQLite wrapper
    PluginEventFactory.swift    — ActiveSession → PluginSessionSnapshot, redaction logic
    BuiltIn/
      SessionTimerPlugin.swift
      PomodoroPlugin.swift

  UI/
    PluginContributionRenderer.swift — PluginUIContribution을 DevIsland-owned SwiftUI component로 렌더링
    NotchView.swift                  — notch.expanded.activity renderer 삽입
    NotchComponents.swift            — v1.1: notch.session.row, session.context-menu 연결
    SessionMessageWindow.swift       — v1.1: session.message 연결

  Settings/
    SettingsStore.swift        — core settings만 유지; plugin enable/disable persistence는 PluginSettingsStore로 분리
    SettingsWindow.swift       — PluginSettingsView 탭 또는 Integrations pane 하단 연결
    PluginSettingsView.swift    — 목록, enable/disable, safemode 상태, storage 삭제
    PluginSettingsStore.swift   — 신규: 플러그인 전용 활성화 상태 및 설정 persistence
```

현재 소스 기준 첫 PR에서 `HookSocketServer.swift`, bridge scripts, `ApprovalProxyController.swift`, `ProviderAdapter.swift`, `SQLiteApprovalStore.swift`는 수정하지 않는 것을 성공 조건으로 둔다. 이 파일을 건드려야 한다면 플러그인이 approval/IPC 경로에 침투하고 있다는 신호이므로 설계를 다시 확인한다.

## 12. 기존 코드 통합 및 리팩토링 (Integration & Refactoring)

플러그인 아키텍처는 기존 `AppState` 중심 구조를 **재설계하지 않고** 좁은 seam에 끼워넣는다.
현재 코드(`AppState`, `SessionStore`, `HookSocketServer`)에 대한 변경을 최소화하는 것이 통합의 제1원칙이다.

### 12.1. 통합 원칙 (Surgical)

- `AppState`는 god object이지만 **분해하지 않는다.** 추가되는 것은 ① `pluginHost` 프로퍼티 1개, ② seam 약 5곳의 event emission, ③ `PluginEventFactory` 한 개뿐이다.
- approval/hook **response path의 로직은 한 줄도 바꾸지 않는다.** emission은 항상 응답 전송 *이후*의 side-effect다.
- 기존 `@Published` 상태(`AppState`, `SessionStore`)와 UI 바인딩은 그대로 두고, plugin contribution은 별도 `PluginHost.contributions`로만 흐른다.

### 12.2. PluginHost 소유와 생성

`AppState`가 `sessionStore`를 소유하듯 `pluginHost`를 소유한다.

```swift
class AppState: ObservableObject {
    let sessionStore: SessionStore
    let pluginHost: PluginHost          // 신규
    // ...
}
```

`AppState.shared`의 `startServer` 플래그(테스트에서 서버 비활성화)와 같은 패턴으로 `enablePlugins` 플래그를 둔다.
**Phase 0**은 "host를 소유하되 플러그인 0개·emission 0개" 상태로, 빌드만 되고 런타임 동작은 완전히 동일하다. 이 단계에서 기존 테스트가 모두 통과해야 한다.

### 12.3. 스레딩: 이미 MainActor 경계 안이다

`HookSocketServer`는 `onMessageReceived`를 main queue에서 호출하도록 설계되어 있다.
따라서 `handleMessage` → `handleParsedEvent` → `sendDecision` 전 경로가 **main serial queue에서 도착 순서(FIFO)대로 실행**된다.

- 별도 dispatcher나 per-event `Task`를 만들지 **않는다.** §10.1이 금지한 "독립 Task로 인한 순서 뒤섞임"이 애초에 발생하지 않는다.
- `AppState`는 `@MainActor`로 표기돼 있지 않으므로, `@MainActor`인 `PluginHost.enqueue(_:)`를 호출하는 seam은 main-thread callsite임을 테스트로 보장한다.

```swift
@MainActor
private func emitPluginEvent(_ event: PluginEvent) {
    pluginHost.enqueue(event)
}
```

향후 `AppState`를 `@MainActor`로 표기하면 이 helper 없이 직접 호출로 단순화된다(별도 작업, v1 범위 밖).

### 12.4. 이벤트 발행 seam 매핑

| PluginEvent | 발행 위치 (현재 symbol) | 비고 |
| :--- | :--- | :--- |
| `app.started` | `AppDelegate.applicationDidFinishLaunching`의 delayed block에서 `AppState.shared` 초기화 이후 | 여기서 `pluginHost.startTicking()`도 호출 |
| `session.started` / `session.updated` | `SessionStore.updateActiveSession(...)` 이후의 neutral callback | `SessionStore`는 PluginHost를 모르고, AppState가 callback을 받아 PluginEvent로 변환한다. |
| `session.ended` | `SessionStore`의 세션 제거 callback | `removeSession`·`pruneInactiveSessions`·`removeSupersededCodexSessions`가 제거 전 `ActiveSession` snapshot을 callback에 포함하고, AppState가 이를 PluginEvent로 변환한다. |
| `hook.received` | `handleParsedEvent`, `recordReplayHookEvent(...)` 직후 | factory가 `ParsedHookEvent` → `PluginHookSummary` 변환 |
| `approval.decided` | `sendDecision`에서 `currentResponseHandler?(payload)` 호출과 `recordReplayDecision` enqueue 이후 | 응답이 이미 전송된 뒤라 Fail-Safe 보장. SQLite 기록 완료는 기다리지 않는다. |
| `notification.shown` | `handleNotificationEvent` | |
| `settings.changed` | `SettingsStore` mutation | |

**핵심 설계 결정 — SessionStore는 PluginHost를 모른다.**
세션 종료 경로는 `handleStopEvent`, `dismissSession`, `pruneInactiveSessions`, `removeSupersededCodexSessions` 등 여러 군데로 흩어져 있다. `AppState` 호출부마다 emission을 박으면 한 경로만 빠져도 `session.ended`가 누락된다.
따라서 `SessionStore`는 plugin 전용 타입이 아니라 neutral event callback, 예를 들어 `onSessionChanged: (SessionStoreChange) -> Void`, 만 제공한다. 제거 이벤트는 `SessionStoreChange.removed(ActiveSession)`처럼 제거 전 snapshot을 포함해야 하며, `AppState`가 이 callback을 받아 `PluginEventFactory`로 DTO를 만들고 `PluginHost.enqueue(_:)`를 호출한다. 이러면 제거 경로 누락과 제거 후 snapshot 손실을 막으면서도 `SessionStore`가 plugin platform에 의존하지 않는다. `AppState`가 `activeSessions`를 직접 remove하는 경로는 이 callback을 우회하므로, 구현 PR에서 `SessionStore` 메서드로 중앙화한다.

### 12.5. PluginEventFactory의 위치와 역할

`ParsedHookEvent`·`ActiveSession` → sanitized DTO 변환을 `AppState`에서 분리해 `PluginEventFactory`에 둔다(AppState 비대화 방지).

- §6.3의 redaction을 **여기서 실현**한다: `commandSummary` 정제, `readTerminalMetadata` 없으면 `cwd`/`terminalApp`을 `nil`로, `readSessionEvents` 없는 플러그인엔 `session` 스냅샷 미첨부.
- factory는 순수 변환 함수에 가까워 단위 테스트가 쉽다(redaction 규칙 검증).
- `PluginSessionSnapshot`은 `ActiveSession`의 부분집합만 복사하므로 내부 필드(`terminalTTY`, tmux socket 등) 노출 위험이 구조적으로 차단된다.

### 12.6. UI 렌더링 통합

`NotchView`·`MenuBarMenu`는 이미 `@ObservedObject`로 `AppState.shared`·`sessionStore`를 구독한다. 여기에 `pluginHost`를 같은 방식으로 추가하고, 각 슬롯 위치에 렌더러를 끼운다.

```swift
// 슬롯 하나를 그리는 얇은 뷰. 렌더 경로에서 플러그인을 호출하지 않고 cache만 읽는다.
struct PluginSlotView: View {
    @ObservedObject var host = AppState.shared.pluginHost
    let slot: PluginUISlot
    var sessionID: String? = nil          // session scope 슬롯이면 대상 세션

    var body: some View {
        let items = (host.contributions[slot] ?? [])
            .filter { sessionID == nil || $0.targetSessionID == sessionID }
        ForEach(items, id: \.pluginID) { PluginContributionRenderer.view(for: $0) }
    }
}
```

구체 삽입 지점:

| 슬롯 | 삽입 뷰 (현재 symbol) |
| :--- | :--- |
| `notch.compact.*` | `NotchCollapsedView` |
| `notch.expanded.*` | `NotchView` 확장 영역 |
| `notch.session.row` | `SessionRowView` (sessionID 전달) |
| `menubar.menu` | `MenuBarMenu` |
| `session.message` | `SessionMessageView` (sessionID 전달) |
| `session.context-menu` | `SessionRowView`/`SessionHistoryWindow`의 `.contextMenu` |

기존 뷰는 `PluginSlotView(...)` 한 줄을 추가하는 수준으로만 바뀐다. contribution이 없으면 `PluginSlotView`는 빈 뷰라 레이아웃 영향이 없다.

### 12.7. 테스트 seam

- `PluginHost`는 `enablePlugins: false`로 주입 가능하므로 기존 `AppStateTests`·`SessionStoreTests`에 영향이 없다.
- `PluginEventFactory`는 base event 생성과 runner별 `redactedEvent(from:permissions:)`를 각각 테스트한다.
- `PluginRunner`/`PluginHost`는 fake plugin(고정 contribution·의도적 throw)으로 dispatch 순서·safemode 전환·cache dedup을 검증한다.

### 12.8. 단계적 적용 (롤아웃과의 매핑)

| 통합 단계 | 변경 범위 | 회귀 안전성 |
| :--- | :--- | :--- |
| Phase 0 | `PluginHost` 소유만 추가 (플러그인·emission 0) | 런타임 동작 동일 |
| Phase 1 | `PluginEventFactory` + seam emission (관찰만, 플러그인 미등록) | emission은 응답 후 side-effect라 무영향 |
| Phase 2 | `PluginContributionRenderer` + `PluginSlotView` 삽입 | contribution 없으면 빈 뷰 |
| Phase 3+ | built-in 플러그인 등록 (§13 롤아웃 3단계 이후) | 플러그인 실패는 safemode로 격리 |

각 단계는 이전 단계의 동작을 바꾸지 않으며, `enablePlugins` 플래그로 전체를 끌 수 있다.

### 12.9. 기존 기능의 Built-in Plugin 전환 후보

플러그인 플랫폼을 도입한다고 해서 기존 기능을 모두 플러그인으로 옮기지는 않는다.
전환 대상은 "없어져도 core hook/approval 동작이 변하지 않는 부가 기능"으로 제한한다.

전환 기준:

- sanitized `PluginEvent` 관찰만으로 동작할 수 있다.
- UI는 `PluginUIContribution` 또는 host-owned settings UI로 표현할 수 있다.
- 실패·disable·safemode가 provider response, approval decision, session lifecycle을 바꾸지 않는다.
- storage는 plugin storage나 기존 host service의 read-only/status API로 충분하다.
- bridge script, `HookSocketServer`, `ProviderAdapter`, `ApprovalProxyController`, `SQLiteApprovalStore` 수정을 요구하지 않는다.

전환 후보:

| 현재 기능 | 현재 위치 | Built-in plugin 형태 | 우선순위 | 전환 조건 |
| :--- | :--- | :--- | :--- | :--- |
| OpenPeon CESP sound playback | `OpenPeon/*`, `AppState.playOpenPeonSound`, `OpenPeonSettingsPane` | `OpenPeonSoundPlugin`이 hook/session/notification event를 관찰하고 host-owned `sound.playCESP` effect를 요청 | 높음 | sound pack scan, validation, `AVAudioPlayer` 재생은 host service에 남긴다. 플러그인은 pack file path나 raw payload를 직접 다루지 않는다. |
| 세션 경과 시간/현재 상태 표시 | 신규 `SessionTimerPlugin` | `notch.expanded.activity` metric contribution | 높음 | core 상태를 바꾸지 않고 `readSessionEvents`만 사용한다. |
| provider/session 통계 | 신규 `ProviderStatsPlugin` 또는 `SessionStatsPlugin` | `notch.expanded.activity`, `menubar.menu` 요약 metric | 중간 | `readHookSummaries`, `readSessionEvents`, v1.1 `approval.decided`만 사용한다. replay DB를 직접 조회하지 않는다. |
| 세션 메시지/행 accessory | `SessionMessageWindow`, `SessionRowView`, `SessionHistoryWindow` 일부 표시 | `session.message`, `notch.session.row`, `session.context-menu` contribution | 중간 | v1.1 세션별 slot이 열린 뒤 진행한다. 메시지 창과 replay loading 자체는 core에 남긴다. |
| update 상태 표시 | `UpdateChecker`, `MenuBarMenu` | update 가능 여부 badge/menu row | 낮음 | update 확인·다운로드·설치는 core에 남긴다. 외부 network permission이 생기기 전까지 플러그인은 host-owned update status만 표시한다. |
| 메뉴의 보조 command | `MenuBarMenu` 일부 부가 row | `menubar.menu` contribution | 낮음 | settings, approval rules, replay, quit처럼 core command는 유지한다. 플러그인 command는 부가 기능에만 사용한다. |

부분 전환 후보:

| 현재 기능 | 플러그인으로 옮길 수 있는 부분 | core에 남길 부분 |
| :--- | :--- | :--- |
| OpenPeon | event-to-sound 정책, mute 상태 표시, preview button contribution | pack scanning/validation, audio playback, settings persistence |
| Replay Log / Session History | session별 annotation, 요약 badge, menubar quick action | `SQLiteApprovalStore`, replay query, replay execution |
| PTY Transcript | transcript 존재 여부 badge, session accessory | PTY capture, transcript storage, raw transcript viewer |
| Settings | plugin enable/disable, safemode, storage reset | core app settings, bridge config, approval settings |

전환 제외:

| 기능 | 제외 이유 |
| :--- | :--- |
| approval decision / approval prompt response | 플러그인은 결정을 바꾸거나 provider response를 지연하면 안 된다. |
| bridge scripts / `HookSocketServer` / IPC framing | hook response path의 안정성 경계다. |
| `ProviderAdapter` response JSON | provider별 의미론 보존이 core 책임이다. |
| `SessionStore` lifecycle ownership | 플러그인은 session snapshot을 관찰만 한다. |
| `SQLiteApprovalStore`, `ReplayRecorder`, PTY transcript persistence | durable core DB와 raw transcript는 plugin storage와 분리한다. |
| terminal focus / AppleScript / Accessibility shortcut | 사용자 환경 권한과 시스템 side effect가 크므로 core command로 유지한다. |
| app relocation, launch at login, update install | 앱 배포·시스템 설정 영역이며 plugin failure와 분리되어야 한다. |

기존 기능 전환은 PR 0–11의 플러그인 플랫폼이 안정화된 뒤 별도 migration track으로 진행한다.
첫 migration 후보는 OpenPeon sound가 가장 적합하다. 이미 best-effort side effect이고, 실패해도 approval/deny 동작을 바꾸면 안 된다는 기존 원칙과 플러그인 Fail-Safe 원칙이 잘 맞기 때문이다.
다만 OpenPeon을 옮기더라도 CESP pack store와 audio player는 host-owned service로 남겨야 한다.

## 13. 단계별 롤아웃 계획 (Rollout Plan)

아래 단계는 구현 범위를 논리적으로 묶은 것이며, 단계와 PR은 1:1로 대응하지 않는다.
세부 PR 분할과 각 PR의 신규 파일·테스트 항목은 `plugin-architecture-implementation-plan.md` §5 참고.

| 단계 | 내용 | 검증 기준 | 해당 PR |
| :--- | :--- | :--- | :--- |
| 0 | 소스 기준 준비: `AppState` event emission 위치와 renderer 삽입 위치 확정 | `HookSocketServer`/approval/provider 파일 수정 없음 | PR 0 |
| 1 | 타입 정의 + `PluginEventFactory` + `PluginHost` skeleton + 빈 registry | 빌드 성공, 기존 hook/approval 동작 유지 | PR 1–2 |
| 2 | `PluginRunner` actor + contribution cache + no-op `PluginContributionRenderer` | 빈 contribution으로 Notch/MenuBar UI 크래시 없음 | PR 3–4 |
| 3 | `notch.expanded.activity` 슬롯만 연결 + `SessionTimerPlugin` built-in | expanded notch에 경과 시간 표시, approval UI와 레이아웃 충돌 없음 | PR 5–7 |
| 4 | `menubar.menu` 슬롯 연결 + `PomodoroPlugin` built-in | hook·session 없이 menu에서 pomodoro 독립 동작 | PR 8 |
| 5 | `PluginStorageProvider` 구현 및 quota 적용 | 플러그인이 앱 재시작 후에도 상태 유지, approval DB와 큐 공유 없음 | PR 9 |
| 6 | Settings UI — `PluginSettingsView` 목록, 활성화 토글, safemode 상태, storage 삭제 | enable/disable이 contribution cache와 tick 대상에 반영 | PR 10 |
| 7 | Safemode 임계값·timeout 적용 | 의도적 오류 유발 → safemode 전환, core UI/approval 계속 동작 | PR 11 |
| M | 기존 기능 migration track: OpenPeon sound 등 부가 기능을 built-in plugin 후보로 전환 | 기능 disable/safemode가 core hook/approval/session 동작을 바꾸지 않음 | Migration PR M0+ |
| 8 | v1.1 세션별 슬롯: `notch.session.row`, `session.context-menu`, `session.message` | 세션별 contribution target/dedup/evict 검증 | v1.1 |
| 9 | v1.1 optional `approval.decided` 관찰 이벤트 | response 이후 통계용 event만 발행, 결정 변경 불가 | v1.1 |
| 10 | (v2) declarative utility preset 검토 | 코드 없는 JSON preset이 capability를 조합 | v2 |
| 11 | (v2) 외부 plugin runtime — worker process or JavaScriptCore | — | v2 |

## 14. 향후 확장 (Future Extensions)

1. **Declarative Utility Presets**: JSON으로 작성하는 코드 없는 소형 utility. DevIsland가 이미 아는 component·action만 조합하므로 JS engine 없이 구현 가능.
2. **External Plugin Runtime**: crash isolation이 필요하면 worker process를 우선, JavaScriptCore는 차선으로 검토.
3. **Plugin Settings Schema**: manifest 선언 기반 입력 UI 자동 생성.
4. **Signed Plugin Packages**: 외부 배포 지원 시 checksum·서명·API version compatibility 검사 추가.
5. **Higher-Risk Permissions**: `readRawPayload`, `networkAccess`, `runProcess`는 사용자 동의·감사 로그·revocation UI를 갖춘 뒤 별도로 추가.

Cross-Plugin IPC는 v1 목표와 맞지 않아 우선순위를 낮춘다. 필요성이 검증되기 전까지는 플러그인 간 직접 통신 대신 DevIsland core가 제공하는 제한된 shared context를 사용한다.

## 15. 참고 아키텍처 (Reference Architectures)

### Raycast

Raycast는 DevIsland의 `utility` plugin 방향에 가장 가까운 참고 사례다.
React로 UI를 선언하지만 Raycast가 native UI component로 렌더링하고, ActionPanel로 사용자 action을 표준화하며, extension별 storage/preferences를 제공한다.

DevIsland 적용 포인트:

- utility plugin을 작은 command/panel 단위로 취급한다.
- custom view 자유도를 낮추고 DevIsland-owned component만 렌더링한다.
- action은 host가 routing하고, storage/preferences reset UI를 Settings에 제공한다.

참고:

- [Raycast User Interface](https://developers.raycast.com/api-reference/user-interface)
- [Raycast Action Panel](https://developers.raycast.com/api-reference/user-interface/action-panel)
- [Raycast Storage](https://developers.raycast.com/api-reference/storage)
- [Raycast Preferences](https://developers.raycast.com/api-reference/preferences)

### Visual Studio Code

VS Code는 구조적 안정성의 참고 사례다.
Extension Host가 extension 실행을 UI와 분리하고, activation events와 contribution points로 lazy activation과 정적 확장 지점을 관리한다.

DevIsland 적용 포인트:

- `activationEvents`, `surface`, `capability`, `contribution point`를 manifest에서 분리한다.
- AppState/hook response path는 plugin dispatch를 기다리지 않는다.
- v2 external runtime은 extension host처럼 별도 worker/process 격리를 우선 검토한다.

참고:

- [VS Code Extension Host](https://code.visualstudio.com/api/advanced-topics/extension-host)
- [VS Code Activation Events](https://code.visualstudio.com/api/references/activation-events)
- [VS Code Contribution Points](https://code.visualstudio.com/api/references/contribution-points)
- [VS Code Extension Capabilities](https://code.visualstudio.com/api/extension-capabilities/overview)

### Figma

Figma는 manifest permission과 host/plugin UI bridge 모델을 참고하기 좋다.
플러그인은 manifest에서 API version, entry, permission, network access를 선언하고, UI와 main plugin code 사이의 메시지 경계를 둔다.

DevIsland 적용 포인트:

- v2 external plugin은 manifest에 `apiVersion`, permission, network/domain access를 명시한다.
- host-owned UI와 plugin runtime 사이의 DTO/message boundary를 명확히 둔다.
- network access는 기본 `none`으로 두고 허용 도메인과 이유를 manifest에 요구한다.

참고:

- [Figma Plugin Manifest](https://developers.figma.com/docs/plugins/manifest/)
- [Figma Creating a User Interface](https://developers.figma.com/docs/plugins/creating-ui/)
- [Figma How Plugins Run](https://developers.figma.com/docs/plugins/how-plugins-run/)

## 16. 결론 (Conclusion)

이 설계는 DevIsland의 핵심 안정성을 저해하지 않으면서 기능 확장을 가능하게 한다. **Cached Rendering**과 **Sanitized Event** 모델로 플러그인이 성능·보안에 미치는 영향을 최소화하며, v1 Built-in 경험을 바탕으로 v2 declarative preset과 external runtime 검토를 준비한다.

첫 구현은 approval path와 provider response를 전혀 건드리지 않는 `PluginEventFactory` → `PluginRunner` → contribution cache 경로부터 시작하는 것이 가장 안전하다.
