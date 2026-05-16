# OpenPeon CESP Integration Design

## 1. 목적

이 문서는 DevIsland에 [OpenPeon CESP v1.0](https://openpeon.com/spec) 사운드팩 규격을 적용하기 위한 설계안이다.

DevIsland는 이미 Claude Code, Codex CLI, Gemini CLI의 hook 이벤트를 받아 승인 요청, 진행 상태, 세션 종료 등을 UI로 표시한다. OpenPeon CESP를 적용하면 동일 이벤트 흐름에 표준 사운드팩 기반 오디오 피드백을 추가할 수 있다.

목표는 다음과 같다.

- DevIsland를 CESP 사운드팩 플레이어로 동작하게 한다.
- 기존 bridge script는 얇게 유지하고, 이벤트 매핑/사운드 재생은 macOS 앱 내부에서 처리한다.
- 승인 요청, 작업 완료, 오류, 리소스 제한 등 사용자가 놓치면 안 되는 이벤트를 소리로 알려준다.
- CESP 규격의 `openpeon.json` manifest와 pack validation을 점진적으로 지원한다.

## 2. OpenPeon CESP 요약

CESP(Coding Event Sound Pack Specification)는 agentic coding tool에서 발생하는 이벤트를 표준 카테고리로 정리하고, 각 카테고리에 재생할 사운드를 `openpeon.json` manifest로 정의하는 규격이다.

### 2.1 핵심 이벤트 카테고리

| Category | 의미 | DevIsland 대응 예시 |
|---|---|---|
| `session.start` | 세션 또는 워크스페이스 시작 | `SessionStart`, `startup`, `init` |
| `task.acknowledge` | 작업 수락/처리 시작 | `PreToolUse` |
| `task.complete` | 작업 완료 | `Stop`, `AfterAgent`, 성공 `PostToolUse` |
| `task.error` | 작업 실패 | 실패 `PostToolUse`, `StopFailure` |
| `input.required` | 사용자 입력 또는 승인 필요 | `PermissionRequest`, `BeforeTool`, `Elicitation` |
| `resource.limit` | 토큰/쿼터/레이트 리밋 | `PreCompact`, rate/token limit notification |

확장 카테고리로 `user.spam`, `session.end`, `task.progress`도 고려한다.

### 2.2 Pack 구조

기본 pack 경로는 `~/.openpeon/packs/<pack-name>/`를 권장한다.

```text
~/.openpeon/packs/
  sample-pack/
    openpeon.json
    sounds/
      approval.mp3
      done.wav
```

예시 manifest:

```json
{
  "cesp_version": "1.0",
  "name": "sample-pack",
  "display_name": "Sample Pack",
  "version": "1.0.0",
  "categories": {
    "input.required": {
      "sounds": [
        {
          "file": "sounds/approval.mp3",
          "label": "Approval needed"
        }
      ]
    },
    "task.complete": {
      "sounds": [
        {
          "file": "sounds/done.wav",
          "label": "Done"
        }
      ]
    }
  }
}
```

## 3. DevIsland 적용 방향

### 3.1 기본 원칙

- Bridge script는 변경하지 않는다.
  - Bridge는 stdin payload 수신, terminal metadata 추가, IPC forwarding, provider-specific response 출력만 담당한다.
  - Pack loading, validation, audio playback, settings는 앱 내부에서 처리한다.
- 이벤트 매핑은 `AppState.handleMessage()`의 기존 분류 흐름을 재사용한다.
- 사운드 재생 실패는 hook response에 영향을 주지 않는다.
- 승인 요청에 대한 response latency를 줄이기 위해 pack scan과 validation은 settings 변경 시 또는 앱 시작 시 미리 수행한다.
- 빠르게 반복되는 progress성 이벤트는 debounce 또는 category 기본 비활성화로 사운드 스팸을 방지한다.

### 3.2 추천 모듈 구조

```text
DevIsland/
  OpenPeon/
    CESPManifest.swift
    CESPCategory.swift
    CESPPack.swift
    CESPPackStore.swift
    CESPPackValidator.swift
    CESPEventMapper.swift
    CESPAudioPlayer.swift
```

| 모듈 | 책임 |
|---|---|
| `CESPManifest` | `openpeon.json` Codable 모델 |
| `CESPCategory` | CESP category enum과 metadata |
| `CESPPack` | manifest, root URL, validation result를 묶은 runtime model |
| `CESPPackStore` | pack directory scan, active pack 관리, reload |
| `CESPPackValidator` | manifest/file/path/audio validation |
| `CESPEventMapper` | DevIsland hook event를 CESP category로 변환 |
| `CESPAudioPlayer` | sound selection, debounce, volume, playback |

## 4. 이벤트 매핑 설계

### 4.1 매핑 테이블

| DevIsland event | Normalized event | 조건 | CESP category |
|---|---|---|---|
| `SessionStart` | `sessionstart` | always | `session.start` |
| `startup` | `startup` | always | `session.start` |
| `init` | `init` | always | `session.start` |
| `PermissionRequest` | `permissionrequest` | approval event | `input.required` |
| `BeforeTool` | `beforetool` | Gemini approval/emulation target | `input.required` |
| `Elicitation` | `elicitation` | Claude MCP input request | `input.required` |
| `PreToolUse` | `pretooluse` | non-approval progress | `task.acknowledge` |
| `PostToolUse` | `posttooluse` | success-like payload | `task.complete` |
| `PostToolUse` | `posttooluse` | failure-like payload | `task.error` |
| `Stop` | `stop` | turn/task complete | `task.complete` |
| `AfterAgent` | `afteragent` | Gemini turn complete | `task.complete` |
| `SessionEnd` | `sessionend` | session closed | `session.end` |
| `exit` | `exit` | session closed | `session.end` |
| `shutdown` | `shutdown` | session closed | `session.end` |
| `PreCompact` | `precompact` | context/resource pressure | `resource.limit` |
| `Notification` | `notification` | `notification_type == input_required` | `input.required` |
| `Notification` | `notification` | `notification_type == permission_prompt` | `input.required` |
| `Notification` | `notification` | message contains rate/token/quota/limit | `resource.limit` |

### 4.2 `Stop` 주의사항

현재 DevIsland 문서상 stop event는 세션 제거/완료 계열로 설명되지만, 앱 코드의 stop event 배열에는 `stop` 문자열이 별도로 포함되어 있지 않을 수 있다. OpenPeon 적용 초기는 기존 lifecycle 동작을 바꾸지 않기 위해 다음 전략을 권장한다.

- `AppState`의 stop/session pruning semantics는 변경하지 않는다.
- `CESPEventMapper`에서만 `stop`을 `task.complete`로 매핑한다.
- 이후 별도 PR에서 `stop` lifecycle 처리 정합성을 검토한다.

### 4.3 Failure detection heuristic

`PostToolUse` 또는 notification에서 오류 사운드를 내기 위한 초기 heuristic:

- payload에 `error`, `errors`, `exception`, `failed`, `failure`, `status: "failed"`, `success: false`가 있으면 `task.error`
- message 또는 response 문자열에 `error`, `failed`, `exception`, `denied`, `timeout` 등 명확한 실패 키워드가 있으면 `task.error`
- 단, user-denied approval은 사용자의 의도적 deny이므로 별도 category를 만들기 전까지 `task.error`로 재생하지 않는다.

## 5. Settings 설계

`AppSettings`에 다음 필드를 추가한다.

```swift
var openPeonEnabled: Bool
var openPeonPacksDirectory: String
var openPeonActivePackName: String?
var openPeonMasterVolume: Double
var openPeonGlobalMuted: Bool
var openPeonMutedCategories: Set<String>
var openPeonDebounceMilliseconds: Int
```

기본값:

| Setting | Default |
|---|---|
| `openPeonEnabled` | `false` |
| `openPeonPacksDirectory` | `~/.openpeon/packs` |
| `openPeonActivePackName` | `nil` |
| `openPeonMasterVolume` | `0.7` |
| `openPeonGlobalMuted` | `false` |
| `openPeonMutedCategories` | `task.acknowledge`, `task.progress`, `session.end`, `user.spam` |
| `openPeonDebounceMilliseconds` | `1500` |

Settings UI 추천 항목:

- Enable OpenPeon sounds
- Active Sound Pack picker
- Reload Packs
- Open Packs Folder
- Master Volume slider
- Global mute
- Category toggles
- Preview selected category
- Validation errors/warnings display

## 6. Pack validation 설계

### 6.1 Mandatory validation

MVP에서도 반드시 검증할 항목:

- `openpeon.json` 존재
- `cesp_version == "1.0"`
- `name`은 `^[a-z0-9][a-z0-9_-]*$` 형태
- `version`은 semver-compatible string
- `categories`는 비어 있지 않아야 함
- 각 sound의 `file`은 relative path
- `file`에 `..` path component 금지
- resolved URL이 pack root 내부인지 확인
- audio file 존재
- file extension은 `.wav`, `.mp3`, `.ogg` 중 하나
- 개별 audio file 크기 1MB 이하
- pack 전체 크기 50MB 이하

### 6.2 Recommended validation

후속 단계에서 추가할 항목:

- SHA-256 검증
- magic bytes 검증
  - WAV: `RIFF`
  - MP3: `ID3` 또는 MP3 sync frame
  - OGG: `OggS`
- unknown category warning
- duplicate sound label warning
- `min_player_version` compatibility check
- icon/preview asset validation

## 7. Audio playback 설계

### 7.1 Playback engine

macOS 앱 내부에서는 `AVFoundation`의 `AVAudioPlayer` 사용을 우선 검토한다.

요구사항:

- active pack이 없으면 no-op
- category가 pack에 없으면 no-op
- category가 muted이면 no-op
- global mute이면 no-op
- category별 debounce 적용
- category 내 sound random selection
- 가능하면 직전 sound 반복 회피
- master volume 적용
- playback error는 log만 남기고 hook response에 영향 없음

### 7.2 OGG 지원 전략

CESP는 OGG Vorbis를 지원 포맷에 포함하지만, `AVAudioPlayer`의 OGG 지원은 macOS 기본 환경에서 보장하기 어렵다. 구현 전략은 두 단계로 나눈다.

- MVP: manifest validation에서는 `.ogg`를 인식하되, playback은 WAV/MP3부터 지원하고 OGG는 warning 처리한다.
- Full support: 별도 decoder 또는 conversion 전략을 검토한다.

## 8. AppState integration point

### 8.1 Category 계산 위치

`AppState.handleMessage()`에서 다음 값이 준비된 직후 category를 계산한다.

- `event`
- `normalizedEvent`
- `agentKind`
- `toolName`
- `notificationType`
- `displayMsg`
- `parsedJSON`

Pseudo-code:

```swift
let cespCategory = CESPEventMapper.category(
    event: event,
    normalizedEvent: normalizedEvent,
    agentKind: agentKind,
    toolName: toolName,
    notificationType: notificationType,
    message: displayMsg,
    payload: parsedJSON
)
```

### 8.2 Playback 호출 위치

권장 호출 정책:

- `input.required`: pending approval request가 실제 큐에 들어가는 시점에 재생
- `task.complete`, `session.start`, `resource.limit`: notification/stop handling branch에서 response와 독립적으로 재생
- `task.error`: failure heuristic 확정 직후 재생
- `task.acknowledge`, `task.progress`: 기본 muted 상태이며, 사용자가 활성화했을 때만 재생

Pseudo-code:

```swift
if let category = cespCategory {
    CESPAudioPlayer.shared.play(category)
}
```

단, 이 호출은 hook response를 막지 않도록 내부에서 main queue blocking 작업을 피해야 한다.

## 9. UX 정책

### 9.1 기본 활성 category

| Category | Default | 이유 |
|---|---:|---|
| `input.required` | ON | 승인/입력 필요는 즉시 알아야 함 |
| `task.complete` | ON | agent turn 완료 인지 |
| `task.error` | ON | 실패 인지 |
| `resource.limit` | ON | token/quota/context 문제 인지 |
| `session.start` | Optional ON | 사용자가 선호에 따라 선택 |
| `task.acknowledge` | OFF | 툴 호출마다 스팸 가능 |
| `task.progress` | OFF | 진행 이벤트가 잦음 |
| `session.end` | OFF | `task.complete`와 중복 가능 |
| `user.spam` | OFF | 아직 DevIsland 매핑이 명확하지 않음 |

### 9.2 Approval sound 중복 방지

- pending queue가 비어 있다가 첫 request가 들어올 때 `input.required` 재생
- 같은 session에 이미 pending request가 있으면 추가 사운드는 debounce
- category-level debounce 기본 1.5초 적용

### 9.3 Frontmost terminal 고려

DevIsland는 notification notch 확장 시 terminal frontmost 여부를 고려한다. 사운드는 시각 알림과 다르게 frontmost 여부와 무관하게 재생하되, 사용자가 category를 끌 수 있어야 한다.

## 10. 테스트 계획

### 10.1 Unit tests

추가 테스트 파일 예시:

```text
DevIslandTests/OpenPeonManifestTests.swift
DevIslandTests/OpenPeonPackValidatorTests.swift
DevIslandTests/OpenPeonEventMapperTests.swift
DevIslandTests/OpenPeonAudioSelectionTests.swift
```

테스트 항목:

- valid manifest decode
- invalid `cesp_version` reject
- path traversal reject
- missing audio file reject
- oversized audio reject
- unsupported extension reject
- `PermissionRequest` -> `input.required`
- `BeforeTool` -> `input.required`
- `Stop` -> `task.complete`
- `PreCompact` -> `resource.limit`
- failure `PostToolUse` -> `task.error`
- muted category no-op
- debounce suppresses rapid repeat
- random selection avoids immediate repeat when possible

### 10.2 Integration/manual tests

- sample pack을 `~/.openpeon/packs/sample-pack`에 설치
- DevIsland settings에서 OpenPeon enable
- `scripts/test-hook.sh`로 Claude/Codex/Gemini approval event 전송
- approval prompt 표시와 동시에 `input.required` 사운드 확인
- stop/afteragent event에서 `task.complete` 사운드 확인
- malformed pack이 settings UI에 validation error로 표시되는지 확인

## 11. 단계별 구현 계획

### Phase 1: CESP model and pack loader

- `CESPManifest`, `CESPCategory`, `CESPPack` 추가
- `CESPPackStore`로 `~/.openpeon/packs` scan
- `CESPPackValidator` MVP validation 구현
- `SettingsStore`에 OpenPeon 설정 추가
- manifest/validator unit test 추가

### Phase 2: Event mapping and playback

- `CESPEventMapper` 추가
- `CESPAudioPlayer` 추가
- `AppState.handleMessage()` integration
- event mapper/audio selection unit test 추가

### Phase 3: Settings UI

- Settings에 OpenPeon section 추가
- pack picker/reload/open folder/volume/category toggle 추가
- validation warning UI 추가
- preview sound button 추가

### Phase 4: Full CESP polish

- SHA-256 validation
- magic bytes validation
- OGG support strategy 확정
- icon/preview 지원
- project-local pack search 지원
- registry/install flow 검토

## 12. 리스크와 대응

| 리스크 | 영향 | 대응 |
|---|---|---|
| 사운드 스팸 | UX 저하 | 기본 muted category, debounce, pending 중복 방지 |
| audio load가 hook response 지연 | CLI blocking 증가 | pack preload, playback no-op fast path, response path와 독립 처리 |
| OGG playback 미지원 | 일부 pack 재생 실패 | MVP에서 warning 처리, WAV/MP3 우선 지원 |
| malformed pack 보안 문제 | path traversal/file access 위험 | root containment/path validation 필수 |
| `Stop` lifecycle semantics 변경 위험 | 세션 제거/큐 처리 부작용 | 초기에는 mapper에서만 `stop -> task.complete` 처리 |
| macOS sandbox/permission 이슈 | pack folder 접근 실패 | 기본 user home 경로 사용, 오류 UI 표시 |

## 13. MVP 수용 기준

MVP는 다음 조건을 만족하면 완료로 본다.

- `~/.openpeon/packs`에서 valid pack을 하나 이상 탐색할 수 있다.
- Settings에서 OpenPeon enable/disable, active pack, volume을 설정할 수 있다.
- `PermissionRequest`, `BeforeTool`, `Elicitation`에서 `input.required` 사운드가 재생된다.
- `Stop`, `AfterAgent`에서 `task.complete` 사운드가 재생된다.
- 명확한 failure payload에서 `task.error` 사운드가 재생된다.
- invalid path traversal pack은 reject된다.
- 사운드 재생 실패가 hook approval/deny response를 방해하지 않는다.
- 기존 `./scripts/run-tests.sh`가 통과한다.
