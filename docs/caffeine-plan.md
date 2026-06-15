# Caffeine 기능 구현 Plan

> 현재 상태(플러그인 마이그레이션 이후): 이 문서는 Caffeine 최초 구현 계획을 보존한다. 실제 코드는 `DevIsland/Plugins/BuiltIn/Caffeine/`에 있으며, `CaffeinePlugin`이 sleep prevention 정책(`decide`)의 단독 소유자다. `CaffeineCoordinator`는 전원/SSID/settings 신호를 generic `PluginPowerStatus`로 플러그인에 전달하고, 플러그인이 반환한 `power.preventIdleSleep` effect를 `SleepAssertion`에 적용하는 host-side signal/effect adapter로 축소됐다. `SettingsStore.caffeineEnabled` 기본값은 현재 `false`이며, plugin enable/disable·safemode는 기존 사용자 설정 위의 추가 feature guard로 작동한다.

## 1. 목표 및 범위

DevIsland 내부에 **자동 슬립 방지(Caffeine) 기능**을 추가한다.
기존 Caffeinated 앱(스크린샷 참고)의 광범위한 토글 메뉴 대신, **상황 인식 기반의 자동 활성화/비활성화**에 초점을 둔 미니멀한 구현을 한다.

### 핵심 요구사항
1. 기존 Caffeinated 앱의 다수 토글 기능(시작 시 활성화, 키보드 단축키, 알림 허용, 아이콘 색 변경 등)은 **구현하지 않는다**.
   - 제외 대상: 화면 보호기 허락, 좌측 클릭 활성화 등.
2. **전원 연결 상태 기반 자동 동작**
   - 충전기 연결 → Caffeine ON (슬립 차단)
   - 충전기 분리 → Caffeine OFF
3. **특정 Wi-Fi(SSID)에서는 항상 비활성화** (사내망 예외 처리)
   - 전원 연결 상태와 무관하게 SSID 일치 시 OFF 유지.
4. **배터리 잔량 20% 이하에서는 항상 비활성화** (저전력 보호)
   - AC 분리 상태에서 잔량 ≤ 20% → 강제 OFF.
   - 임계값은 상수로 시작, 추후 사용자 설정화 가능.
5. **설정 창에 "Caffeine" 탭 신설**하여 사용자 옵션 노출.

---

## 2. 비범위 (Out of Scope)

| 미구현 | 이유 |
| --- | --- |
| 메뉴바 별도 아이콘 / 컬러 변경 | DevIsland UI에 통합 |
| 기간(15/30/45분 등) 수동 타이머 | 자동 동작이 기본 정책 |
| 키보드 단축키 | 추후 별도 PR |
| 좌클릭 토글 / 화면보호기 허락 | 명시적 제외 |

---

## 3. 아키텍처 개요

```
┌──────────────────────┐    ┌──────────────────────┐
│  PowerSourceMonitor  │──▶│                      │
│ (IOKit PowerSource:  │    │                      │
│  AC상태 + 배터리%)    │    │                      │
└──────────────────────┘    │   CaffeineCoordinator│──▶ IOPMAssertion
                            │ (host signal/effect adapter) │ (PreventUserIdleDisplaySleep)
┌──────────────────────┐    │                      │
│   WifiSSIDMonitor    │──▶│                      │
│ (CoreWLAN + Notif)   │    │                      │
└──────────────────────┘    └──────────────────────┘
                                      ▲
                                      │ settings/observe
                                      │
                            ┌──────────────────────┐
                            │  CaffeineSettings    │
                            │ (SettingsStore 확장)  │
                            └──────────────────────┘
                                      ▲
                                      │
                            ┌──────────────────────┐
                            │ CaffeineSettingsPane │
                            │   (UI Tab)           │
                            └──────────────────────┘
```

### 상태 결정 규칙 (현재는 `CaffeinePlugin`)
입력:
- `caffeineEnabled: Bool` (마스터 스위치)
- `currentSSID: String?`
- `excludedSSIDs: [String]`
- `isOnACPower: Bool`
- `batteryLevel: Double?` (0.0–1.0, 배터리 없는 데스크톱은 `nil`)
- `lowBatteryThreshold: Double` (기본 0.20)

출력:
```
isLowBattery =
    batteryLevel.map { $0 <= lowBatteryThreshold } ?? false

shouldHoldAssertion =
    caffeineEnabled
    && isOnACPower
    && !isLowBattery
    && !(currentSSID.map(excludedSSIDs.contains) ?? false)
```

→ `true`이면 IOPMAssertion 생성/유지, `false`이면 release.

배터리 규칙 메모:
- AC 연결 중에는 잔량이 20% 이하라도 충전되며 곧 회복되지만, 안전을 위해 동일 규칙 적용(`isLowBattery` AND-gate). 데스크톱(`batteryLevel == nil`)은 영향 없음.
- 히스테리시스: 20%에서 깜빡임 방지를 위해 OFF 전환은 ≤ 20%, ON 복귀는 ≥ 23% 로 둠(상수).

---

## 4. 신규 파일

신규 디렉토리: `DevIsland/Plugins/BuiltIn/Caffeine/`

| 파일 | 책임 |
| --- | --- |
| `CaffeineCoordinator.swift` | 입력 신호 결합 → IOPMAssertion 생성/해제. `@MainActor` ObservableObject. AppState에서 보유. |
| `PowerSourceMonitor.swift` | `IOPSNotificationCreateRunLoopSource` 기반 AC 전원 상태 + 배터리 잔량 감지. `@Published var isOnACPower: Bool`, `@Published var batteryLevel: Double?`. |
| `WifiSSIDMonitor.swift` | `CWWiFiClient.shared().interface()?.ssid()` 폴링 또는 `CWEventDelegate ssidDidChangeForWiFiInterface`로 변경 감지. `scanForNetworks()` 기반 주변 SSID 스캔 API 제공(설정 UI용). Location permission 처리(macOS 14+ SSID 노출 제한 대응). |
| `SleepAssertion.swift` | `IOPMAssertionCreateWithName`/`IOPMAssertionRelease` 박싱. 단일 assertion ID 보유. |

### Settings 확장
`DevIsland/Settings/SettingsStore.swift` — `AppSettings`에 다음 필드 추가:
```swift
var caffeineEnabled: Bool                 // 마스터 ON/OFF (기본 true)
var caffeineExcludedSSIDs: [String]       // 사내망 등 비활성화 SSID 목록
```
- 기본값/Codable/마이그레이션 처리.
- `resetToDefaults()` 반영.

### UI
신규 파일: `DevIsland/Settings/CaffeineSettings.swift`
- `CaffeineSettingsPane: View`
  - Section 1 — **상태**: 현재 AC 전원 / 배터리 잔량 / 현재 SSID / 현재 Assertion 보유 여부(라이브)
  - Section 2 — **동작**: 마스터 토글 (`caffeineEnabled`)
  - Section 3 — **제외 SSID 목록**: 등록된 SSID List + 삭제(swipe).
    - **"SSID 추가" 버튼** → sheet 표시: 주변 Wi-Fi 스캔 결과를 List로 보여주고 다중 선택 후 확정.
    - 현재 연결된 SSID는 sheet 상단에 별도 강조.
    - 스캔 실패/권한 없음 시 sheet 하단에 수동 텍스트 입력 fallback.
    - 중복/공백 trim 검증.
  - Section 4 — 도움말 텍스트(전원 연결 시 자동 활성화 / 제외 SSID는 항상 OFF / 배터리 20% 이하는 항상 OFF).

`SettingsWindow.swift` — TabView에 항목 추가:
```swift
CaffeineSettingsPane(store: store, coordinator: appState.caffeineCoordinator)
    .tabItem { Label(l10n.tabCaffeine, systemImage: "cup.and.saucer") }
```
(위치: Display 다음 또는 General 다음 — 추후 합의)

### Status Item 메뉴 통합
- DevIsland 본체 status item(`NSStatusItem`)의 메뉴 구성 지점에 **"Caffeine" 토글 항목** 추가.
  - `NSMenuItem` + `state` (on/off) 체크마크 또는 SwiftUI `Toggle`을 `NSHostingView`로 래핑.
  - 클릭 → `SettingsStore.shared.settings.caffeineEnabled.toggle()` → coordinator 즉시 반영.
- 항목 sub-label에 현재 동작 사유 요약 표시 (예: "ON — AC 연결", "OFF — 사내망 제외", "OFF — 배터리 19%").
- **노치/Island UI에는 Caffeine 상태 노출하지 않음.**

### L10n
`L10n` 새 키 (ko/en):
- `tabCaffeine`
- `secCaffeineStatus`, `secCaffeineBehavior`, `secCaffeineExcludedSSIDs`
- `lblCaffeineEnabled`, `lblCurrentSSID`, `lblOnAC`, `lblBatteryLevel`, `lblHoldingAssertion`
- `btnAddSSID`, `lblScanNearbyWifi`, `lblConnectedSSID`, `lblManualSSIDEntry`, `hintCaffeineRule`
- `menuCaffeineToggle`, `menuCaffeineReason*` (상태 요약 문자열들)

---

## 5. AppState 통합

`DevIsland/Core/AppState.swift`:
- `@Published var caffeineCoordinator: CaffeineCoordinator`
- 앱 시작 시 coordinator.start() — monitor 구독 시작.
- 앱 종료 시 assertion release 보장 (`deinit`/`applicationWillTerminate`).

설정 변경 → coordinator에 publish(`SettingsStore.shared.$settings.map(\.caffeineEnabled)` 등 Combine 바인딩).

---

## 6. 기술적 고려사항

### SSID 권한 (macOS 14+)
- `CWInterface.ssid()`는 **Location Services 권한**이 있어야 실제 SSID 반환, 없으면 `nil`.
- `Info.plist`에 `NSLocationUsageDescription` / `NSLocationWhenInUseUsageDescription` 추가.
- 권한 미허용 상태 → UI에서 "위치 권한 필요" 안내 + 시스템 설정 열기 버튼.
- 권한 없을 때의 fallback 정책: SSID 매칭 불가 → **제외 규칙 미적용**(즉 전원 규칙만 따름). 사용자에게 명시적으로 표시.

### IOPMAssertion
- 사용 assertion type: **`kIOPMAssertionTypePreventUserIdleDisplaySleep`**
  - 디스플레이 슬립을 막으면 시스템 슬립도 함께 차단됨(상위 assertion).
  - 일반적인 "카페인" 사용자 기대치와 일치.
- assertion name: `"DevIsland.Caffeine"` (식별 가능하도록).

### 전원 / 배터리 상태
- `IOPSCopyPowerSourcesInfo` + `IOPSCopyPowerSourcesList` → `kIOPSPowerSourceStateKey == kIOPSACPowerValue` 판정.
- 배터리 잔량: 같은 dict에서 `kIOPSCurrentCapacityKey` / `kIOPSMaxCapacityKey` → `current / max` (0.0–1.0).
- 데스크톱 Mac(배터리 없음) → `batteryLevel = nil` → 배터리 규칙은 무시되고 제외 SSID 규칙만 동작.
- 변경 통지는 `IOPSNotificationCreateRunLoopSource` 단일 콜백에서 AC 상태와 잔량을 동시에 갱신.

### 워크트리/XcodeGen
- 신규 Swift 파일 추가 후 `xcodegen generate` 1회 실행. `project.yml`의 `sources: path: DevIsland`가 재귀 포함하므로 별도 편집 불필요.

---

## 7. 테스트 계획

### 단위 테스트 (`DevIslandTests/`)
- `CaffeineCoordinatorTests.swift`
  - 마스터 OFF → 항상 release
  - AC 연결 + 제외 SSID 아님 + 배터리 정상 → assertion held
  - AC 연결 + 제외 SSID 매칭 → release
  - AC 분리 → release
  - AC 연결 + 배터리 20% 이하 → release (저전력 보호)
  - 배터리 19% → 22% (히스테리시스 영역) → release 유지, 23% 도달 시 ON 복귀
  - `batteryLevel == nil`(데스크톱) → 배터리 규칙 무시
  - SSID `nil`(권한 없음) → 제외 규칙 무시, AC/배터리만으로 판정
- `SettingsStore` 마이그레이션 테스트 (기존 설정 파일에서 신규 필드 default 채우기)

### 수동 QA 체크리스트
- [ ] 노트북에서 충전기 분리 → 슬립 발생 확인
- [ ] 충전기 연결 → 슬립 차단 확인 (`pmset -g assertions | grep DevIsland`)
- [ ] 사내 SSID 연결 상태에서 충전기 연결 → 슬립 발생(차단 안 됨) 확인
- [ ] 배터리 20% 이하에서 충전기 연결 → 슬립 발생(차단 안 됨), 충전 후 23% 회복 시 차단 재개 확인
- [ ] 사내 SSID 목록 추가/삭제 후 즉시 반영
- [ ] 앱 종료 시 assertion 정리 (`pmset -g assertions` 비어 있음)
- [ ] Location 권한 거부 → UI 경고 표시 + 전원 규칙만 동작
- [ ] 디스플레이 슬립 차단 확인 (Energy Saver 화면 끄기 시간 도달 후에도 화면 유지)
- [ ] Status item 메뉴에서 Caffeine 토글 → 즉시 assertion 반영, 메뉴 라벨에 상태 사유 표시
- [ ] SSID 추가 sheet에서 주변 Wi-Fi 스캔 결과 다중 선택 → 목록 반영
- [ ] Location 권한 없을 때 SSID sheet → 수동 입력 fallback 노출

---

## 8. 구현 순서 (제안)

1. 브랜치 생성: `feature/caffeine`
2. `SleepAssertion.swift` + 단위 테스트 (가장 독립적)
3. `PowerSourceMonitor.swift`
4. `WifiSSIDMonitor.swift` + `Info.plist` 권한
5. `AppSettings` 필드 추가 + 마이그레이션 테스트
6. `CaffeineCoordinator.swift` + 단위 테스트
7. `CaffeineSettingsPane` UI + SSID 스캔 sheet + L10n 키
8. `SettingsWindowView` TabView에 통합
9. `AppState` 통합 + lifecycle 정리
10. **Status item 메뉴에 Caffeine 토글 항목 추가 + 상태 요약 라벨**
11. `xcodegen generate` → 빌드 → 수동 QA
12. PR 작성

각 단계마다 별도 커밋(원자성 규칙 준수).

---

## 9. 결정사항 (확정)

1. **디스플레이 슬립까지 차단**
   - IOPMAssertion type: `kIOPMAssertionTypePreventUserIdleDisplaySleep` 사용 (시스템 슬립도 자동 차단됨).
   - `kIOPMAssertionTypePreventUserIdleSystemSleep`은 사용하지 않음.
2. **SSID 선택 UI — 스캔 목록에서 고르기**
   - 수동 텍스트 입력 대신 **현재 주변 Wi-Fi 스캔 결과**에서 다중 선택.
   - `CWInterface.scanForNetworks(withName: nil)` 호출 → SSID 정렬/중복제거 → SwiftUI sheet에 List로 표시.
   - 현재 연결된 SSID는 상단에 별도 강조.
   - 스캔에는 Location 권한 필요 — 미허용 시 안내 + 수동 입력 fallback 제공.
   - 매칭 방식은 **완전일치**. 와일드카드 미지원.
3. **상태 메뉴바(Status Icon)에 토글 노출**
   - DevIsland 본체의 status item 메뉴에 "Caffeine" 항목 추가 (스위치/체크마크).
   - 클릭 시 `caffeineEnabled` 마스터 스위치 토글.
   - 메뉴 항목 라벨에 현재 상태 요약(예: "Caffeine — AC, 사내망 제외 중") 동적 표시.
   - 별도 menubar 아이콘 신설하지 않고 기존 status item에 편입.
4. **노치/Island UI에는 Caffeine 상태 미노출** — 메뉴바만으로 충분.

### Status item 메뉴 추가 위치
- 기존 status item 메뉴 구성 코드(추정: `DevIslandApp.swift` 또는 `AppState`에서 `NSMenu` 구성하는 지점)에 신규 항목 삽입.
- 구현 시 정확한 위치는 코드 확인 후 결정 — 별도 단계로 분리.
