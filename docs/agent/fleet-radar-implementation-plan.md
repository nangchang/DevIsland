# Fleet Radar 구현 계획

- 상태: 프로덕션 구현 완료; 수동 GUI·클린 Mac 검증 및 공개 제출 절차는 별도 진행
- 작성일: 2026-07-16
- 대상: OpenAI Build Week 2026 — Developer Tools
- 공식 페이지: [OpenAI Build Week](https://openai.devpost.com/)
- 제출 마감: 2026-07-21 17:00 PDT / 2026-07-22 09:00 KST
- 기준 코드: `1fc23ce` (`v0.14.1-dev`)
- 상위 제품 계획: [product-vision-and-roadmap.md](../product-vision-and-roadmap.md) H2-1 Fleet 보드, H2-2 Git 컨텍스트
- 관련 구조 문서:
  - [ui-customization.md](ui-customization.md)
  - [stability-standards.md](stability-standards.md)
  - [terminal-focus-aoe.md](terminal-focus-aoe.md)
  - [build-and-test.md](build-and-test.md)

이 문서는 Fleet Radar를 구현하는 사람이 별도의 제품 결정을 다시 내리지 않아도 되도록
기능 범위, 데이터 모델, Git 명령과 파싱 규칙, 동시성 경계, UI 동작, 파일별 변경 범위,
테스트와 해커톤 데모 인수 기준을 고정한다.

공식 요구사항은 2026-07-16에 확인했다. 규정/마감이 바뀔 수 있으므로 제출 직전에 공식
페이지와 [Official Rules](https://openai.devpost.com/rules)를 다시 확인한다.

---

## 1. 한 문장 정의

> Fleet Radar는 여러 AI 코딩 세션과 Git worktree를 한 화면에 보여 주고, 사용자의 결정이
> 필요한 세션과 서로 같은 파일을 수정 중인 worktree를 우선 표시하는 로컬 전용 관제 화면이다.

Fleet Radar는 에이전트를 지시하거나 자동 병합하지 않는다. 관찰 가능한 로컬 사실을 요약하고,
사람이 어느 세션을 먼저 확인할지 결정할 수 있게 하는 것이 전부다.

---

## 2. 해커톤 범위와 제품 결정

### 2.1 제출 트랙

- **Developer Tools**
- 해결하려는 문제: 병렬 Codex/Claude/Gemini 세션이 늘어나면 사용자는 다음 두 가지를 놓친다.
  1. 지금 어느 세션에 사람의 결정이 필요한가.
  2. 서로 다른 worktree의 에이전트가 같은 파일을 수정하고 있는가.

공식 심사 기준인 기술 구현, 완결된 제품 경험, 잠재 영향, 아이디어 품질에 맞춰 데모와
README를 구성한다. 제출물에는 작동 프로젝트, 카테고리, 설명, 3분 미만 공개 YouTube 영상,
심사용 저장소 URL, 핵심 Codex task의 `/feedback` Session ID가 필요하다.

### 2.2 기존 프로젝트와 신규 기능의 경계

DevIsland 자체는 해커톤 이전부터 존재한다. 제출물에서 신규 작업으로 설명할 범위는 아래로
한정한다.

- Fleet 탭과 카드 UI
- Git worktree/branch/dirty 파일 스냅샷
- 동일 저장소 worktree 사이의 변경 경로 중첩 분석
- attention ranking
- Fleet 전용 테스트, 문서, 데모 시나리오

기존 승인 프록시, 훅 브리지, 터미널 포커스, 세션 히스토리, 플러그인 시스템은 기반으로만
설명한다. 신규 구현과 기존 기능을 README와 커밋 기록에서 명확히 분리한다.

공식 규정상 기존 프로젝트는 2026-07-13 09:00 PT 이후 Codex/GPT-5.6으로 의미 있게 확장된
부분만 평가된다. 따라서 기준 SHA, 날짜가 남는 커밋, 핵심 Codex task 기록을 보존한다.

### 2.3 런타임 모델 호출 여부

Fleet Radar 런타임은 GPT API를 호출하지 않는다.

- 대회에서 요구하는 Codex/GPT-5.6 사용은 구현 과정과 제출 증빙으로 충족한다.
- Git 경로 중첩은 결정론적으로 계산할 수 있으므로 모델 호출이 정확도나 제품 원칙에 도움이
  되지 않는다.
- 코드, 명령, 경로를 외부로 전송하지 않아 DevIsland의 로컬 우선 원칙을 지킨다.

### 2.4 마감 역산 일정

모든 시각은 KST 기준이다. 공식 마감은 2026-07-22 09:00이지만 목표 제출 시각은
2026-07-21 23:00으로 잡아 10시간의 업로드/권한/Devpost 입력 버퍼를 둔다.

| 날짜 | 구현 범위 | 종료 조건 |
|---|---|---|
| 7/16 | 등록/크레딧 확인, 기준 SHA, 설계 확정 | 이 문서 승인, 핵심 Codex task 유지 |
| 7/17 | 단계 1–4: 모델, parser, runner, scanner | Git 계층 테스트와 전체 테스트 통과 |
| 7/18 | 단계 5–6: overlap, view model | 그룹/정렬/debounce 테스트 통과 |
| 7/19 | 단계 7–8: Fleet UI, Session Center | 주요 수동 시나리오 화면 동작 |
| 7/20 | 단계 9: 다국어, README, CHANGELOG, packaging | DMG/ZIP을 깨끗한 환경에서 실행 |
| 7/21 | 전체 회귀, 영상, 제출 폼 | 23:00까지 제출 완료 및 링크 재확인 |

무료 크레딧이 필요하면 공식 신청 마감인 2026-07-17 12:00 PT
(2026-07-18 04:00 KST) 전에 별도로 신청한다. 크레딧 신청은 구현 완료 조건에는 포함하지 않는다.

---

## 3. 성공 기준

구현 완료는 아래 항목을 모두 만족하는 상태다.

1. Session Center를 열면 Fleet 탭이 기본으로 선택된다.
2. 활성 최상위 세션은 카드 하나로 표시되고, sub-agent는 부모 카드 안에 중첩된다.
3. Git 저장소 세션은 branch, worktree 경로, dirty 파일 수를 표시한다.
4. 같은 저장소의 서로 다른 worktree가 하나 이상의 동일 경로를 수정하면 양쪽 카드에
   **Overlap risk**가 표시된다.
5. 겹침 상세에서 상대 worktree/branch와 겹친 파일 목록을 확인할 수 있다.
6. 정렬은 사람의 개입 필요도를 우선하고 동일 우선순위에서는 최근 활동 순서를 유지한다.
7. Git 명령은 메인 스레드, 훅 응답 경로, 승인 결정 경로에서 실행되지 않는다.
8. Git 조회 실패는 승인/세션 동작을 바꾸지 않고 해당 카드에서만 상태로 표시된다.
9. 카드 본문 클릭은 세션 선택만 수행한다. 터미널 포커스는 명시적인 Focus 버튼만 수행한다.
10. 기존 승인 큐 순서, provider response JSON, 노치 auto-collapse 동작은 변하지 않는다.
11. 파서, 중첩 분석, 정렬, 캐시/오래된 결과 처리에 단위 테스트가 있다.
12. `./scripts/run-tests.sh`와 `./scripts/build_and_run.sh --no-kill --no-run`이 통과한다.

---

## 4. 비목표

해커톤 구현에서 다음은 만들지 않는다.

- 실제 merge conflict 예측 또는 자동 해결
- diff 내용의 의미 분석
- 에이전트 간 메시지 전달, 중지, 재시도, 작업 재분배
- 원격 승인, 모바일/웹 컴패니언
- GitHub PR/CI 조회와 `gh` 네트워크 호출
- ahead/behind 계산
- 파일 watcher 또는 저장소 전체 감시 daemon
- 커밋 생성, checkout, reset, stash 등 Git 쓰기
- 플러그인 v2 또는 외부 플러그인 API
- 새로운 설정 토글
- expanded notch의 기존 세션 리스트 교체
- provider별 문자열을 추측해서 “working/error/idle” 상태를 만드는 로직

`Overlap risk`는 “두 worktree의 현재 변경 경로 집합에 교집합이 있다”는 뜻이다.
실제 병합 충돌이 발생한다고 단정하지 않는다.

---

## 5. 현재 코드에서 재사용할 기반

| 기반 | 현재 위치 | Fleet에서의 사용 |
|---|---|---|
| 활성 세션과 상태 | `SessionStore.activeSessions` | 카드 입력 |
| 부모/sub-agent 관계 | `ActiveSession.parentSessionId` | 카드 중첩 |
| 로컬 작업 경로 | `ActiveSession.workspaceRoot` | Git 조회 시작점 |
| 승인/미확인 신호 | `isPending`, `hasMissedApproval`, `isUnread`, `status` | attention ranking |
| 세션 선택 | `AppState.showSessionDetail` | 카드 선택 |
| 터미널 이동 | `AppState.focusTerminal(for:)` | 명시적 Focus 액션 |
| Finder/복사 동작 | 기존 Session History/SessionRow 패턴 | 카드 보조 액션 |
| 표준 분리 창 | `HostedWindowController` | Fleet 탭 호스트 |
| 세션/인사이트 탭 | `SessionHistoryWindowView` | Fleet 탭 삽입 |
| 다국어 | `L10n` + `Localizable.xcstrings` | 영문/한글 문자열 |

Fleet Radar는 `SessionStore`나 `ActiveSession`에 Git 상태를 저장하지 않는다.
세션 상태는 provider/hook 사실이고, Git 상태는 별도 수명과 실패 모드를 가지므로 분리한다.

---

## 6. 사용자 경험 명세

### 6.1 진입점

기존 메뉴의 “Session History” 표면을 **Session Center / 세션 센터**로 확장한다.

- 기존 `AppWindowRouter.showSessionHistory()` 함수 이름과 controller 캐시는 유지한다.
- 메뉴와 윈도우 제목의 번역값만 “Session Center / 세션 센터”로 바꾼다.
- `SessionHistoryWindowView`의 탭 순서는 Fleet → Sessions → Insights다.
- 새 창을 처음 만들 때 Fleet 탭을 기본 선택한다.
- 기존 세션 목록과 Insights의 동작은 바꾸지 않는다.
- 초기 창 크기는 `960 x 640`, SwiftUI 최소 크기는 `900 x 560`으로 올린다.

Fleet를 expanded notch에 직접 넣지 않는 이유:

- 승인 요청이 표시되는 NSPanel과 Git I/O 상태를 결합하지 않는다.
- 기존 노치 크기, hit testing, auto-collapse, context menu 안정성을 건드리지 않는다.
- 여러 카드를 읽을 수 있는 충분한 면적을 확보한다.
- 표준 NSWindow에서 키보드 탐색과 상세 popover를 안정적으로 제공한다.

### 6.2 Fleet 상단 도구막대

왼쪽에서 오른쪽 순서:

1. 제목: `Fleet Radar`
2. 활성 최상위 세션 카드 수
3. Git worktree 수
4. overlap pair 수
5. Spacer
6. 마지막 완료 시각
7. Refresh 버튼

Refresh 버튼은 캐시 TTL을 무시한 강제 갱신이다. 갱신 중에는 progress indicator를 표시하되
기존 카드 결과를 지우지 않는다. 새 결과가 모두 준비되면 한 번에 교체한다.

### 6.3 카드 그리드

`LazyVGrid`와 adaptive column을 사용한다.

- 최소 카드 너비: 280pt
- 권장 최대 너비: 420pt
- 카드 간격: 12pt
- 창 가로 여백: 16pt
- 카드 높이는 내용에 따라 달라도 되지만 헤더/상태 영역의 수직 위치는 맞춘다.

카드 한 개는 최상위 세션 한 개를 나타낸다. 부모가 목록에서 사라진 orphan sub-agent는
독립 카드로 표시하고 “Orphan sub-agent” 보조 라벨을 붙인다.

### 6.4 카드 정보 계층

위에서 아래 순서:

1. **헤더**
   - provider 아이콘/색상
   - 사용자 지정 label 또는 terminal title
   - 가장 중요한 attention badge
   - 마지막 활동 상대 시간
2. **Git 요약**
   - branch 또는 `detached@<8-char OID>`
   - worktree 폴더명
   - dirty 파일 수
   - unmerged 상태가 있으면 별도 빨간 badge
3. **Overlap 요약**
   - 상대 branch/worktree 이름
   - 겹친 파일 수
   - 상세 popover 버튼
4. **최근 활동**
   - `lastEventName`
   - `lastToolName`
   - `lastMessage` 한 줄
5. **Sub-agents**
   - provider icon, title, attention dot, 마지막 활동
   - 부모 카드 안에서 최대 3개 표시
   - 4개 이상이면 “+N more”로 접고 사용자가 펼칠 수 있게 한다.
6. **액션**
   - Show Detail
   - Focus Terminal
   - Open in Finder
   - Copy Path

색상만으로 상태를 전달하지 않는다. 모든 상태는 SF Symbol과 텍스트를 함께 사용한다.

### 6.5 카드 상호작용

#### 카드 본문 또는 Show Detail

- `AppState.showSessionDetail(sessionID)`를 호출한다.
- 세션을 선택하고 expanded notch가 해당 세션 상세를 표시하게 한다.
- 터미널을 활성화하지 않는다.
- 승인 결정을 보내지 않는다.

#### Focus Terminal

- 기존 `AppState.focusTerminal(for:)`를 명시적 버튼에서만 호출한다.
- 이 경로는 기존 SessionRow의 Focus 버튼과 동일하게 unread/missed 표시를 지우고,
  사용자가 터미널로 돌아가면 표시 중인 요청을 native prompt로 pass할 수 있다.
- 버튼 도움말에 “Focus the terminal; a displayed approval may return to the terminal” 의미를
  명시한다.
- 카드 전체 클릭에 이 동작을 연결하지 않는다.

#### Open in Finder / Copy Path

- `workspaceRoot`가 없으면 숨긴다.
- Finder 열기는 `NSWorkspace.shared.open`을 사용한다.
- 복사는 `NSPasteboard`를 사용한다.
- shell command를 만들거나 실행하지 않는다.

### 6.6 Overlap 상세

Overlap badge를 누르면 popover를 연다.

- 상대 카드의 label, branch, worktree 폴더명
- 겹친 파일 경로를 저장소 상대 경로로 표시
- 경로는 사전식으로 정렬
- 처음 20개를 표시하고 나머지는 “+N more files”로 요약
- 경로 클릭 동작은 제공하지 않는다.
- “This is path overlap, not a guaranteed merge conflict.” 안내를 항상 표시한다.

한 카드가 여러 worktree와 겹치면 상대별 section으로 나눈다.

### 6.7 빈 상태와 실패 상태

| 상태 | 표시 |
|---|---|
| 활성 세션 없음 | “Start a supported agent session to see it here.” |
| workspaceRoot 없음 | 카드 유지, “Workspace unavailable” |
| Git 저장소가 아님 | 카드 유지, “Not a Git repository” |
| Git 실행 실패/timeout | 마지막 정상 스냅샷이 있으면 stale badge와 함께 유지 |
| 첫 스캔부터 실패 | “Git context unavailable”와 Retry |
| 변경 파일 없음 | branch + “Clean” |
| overlap 없음 | overlap 영역 자체를 숨김 |

Git 실패는 Fleet 화면 바깥으로 알림을 발행하지 않는다. 승인 알림과 혼동시키지 않기 위해
카드 내부 상태와 privacy-safe 로그만 사용한다.

---

## 7. 상태 우선순위와 정렬

### 7.1 Attention 종류

`FleetAttentionKind`를 아래 순서로 정의한다.

| raw priority | 종류 | 조건 |
|---:|---|---|
| 0 | `needsDecision` | 자신 또는 child가 `isPending` 또는 `hasMissedApproval` |
| 1 | `blocked` | `policyDenied`, `timeoutBypassed`, 또는 Git unmerged entry |
| 2 | `overlapRisk` | 하나 이상의 다른 worktree와 changed path 교집합 존재 |
| 3 | `unread` | 자신 또는 child가 `isUnread` |
| 4 | `live` | 위 조건 없음 |

한 카드가 여러 상태를 가지면 가장 작은 priority를 primary badge로 사용하고, 나머지는
secondary badge로 유지한다. 예를 들어 pending 카드에도 overlap badge는 계속 보인다.

### 7.2 정렬 키

정렬은 아래 tuple을 오름차순/내림차순으로 비교한다.

```text
(
  primaryAttention.priority ascending,
  newestActivityAt descending,
  displayTitle localizedStandardCompare ascending,
  sessionID ascending
)
```

Git 스캔 완료로 overlap이 바뀌면 정렬이 바뀔 수 있다. 결과 배열을 한 번에 교체해 카드가
여러 차례 튀지 않게 한다.

### 7.3 만들지 않는 상태 추론

`lastEventName`이나 `lastMessage` 문자열에서 “working”, “failed”, “done”을 추측하지 않는다.
provider별 의미가 다르며 false positive가 생긴다. 향후 `SessionStatus`가 구조화된
working/error 상태를 제공하면 별도 계획으로 추가한다.

---

## 8. 데이터 모델

신규 타입은 `DevIsland/Fleet/FleetRadarModels.swift`에 둔다.

```swift
struct GitRepositoryID: Hashable, Sendable {
    let commonGitDirectory: String
}

struct GitWorktreeID: Hashable, Sendable {
    let topLevelPath: String
}

struct GitWorktreeSnapshot: Equatable, Sendable {
    let repositoryID: GitRepositoryID
    let worktreeID: GitWorktreeID
    let branchHead: String
    let headOID: String?
    let changedPaths: Set<String>
    let changedEntryCount: Int
    let hasUnmergedEntries: Bool
    let capturedAt: Date
}

enum GitSnapshotFailure: Equatable, Sendable {
    case missingWorkspace
    case notRepository
    case timedOut
    case outputTooLarge
    case launchFailed
    case commandFailed
    case malformedOutput
}

enum GitSnapshotState: Equatable, Sendable {
    case ready(GitWorktreeSnapshot)
    case stale(GitWorktreeSnapshot, GitSnapshotFailure)
    case unavailable(GitSnapshotFailure)
}

struct FleetOverlapID: Hashable, Sendable {
    let repositoryID: GitRepositoryID
    let localWorktreeID: GitWorktreeID
    let peerWorktreeID: GitWorktreeID
}

struct FleetOverlapPeer: Equatable, Identifiable, Sendable {
    let repositoryID: GitRepositoryID
    let localWorktreeID: GitWorktreeID
    let peerWorktreeID: GitWorktreeID
    let peerBranch: String
    let paths: [String]

    var id: FleetOverlapID {
        FleetOverlapID(
            repositoryID: repositoryID,
            localWorktreeID: localWorktreeID,
            peerWorktreeID: peerWorktreeID
        )
    }
}

enum FleetAttentionKind: Int, Hashable, Sendable {
    case needsDecision = 0
    case blocked = 1
    case overlapRisk = 2
    case unread = 3
    case live = 4
}
```

### 8.1 UI 입력 DTO

`ActiveSession` 전체를 background task로 보내지 않는다. MainActor에서 카드 입력 DTO를 만든다.

```swift
struct FleetSessionDescriptor: Equatable {
    let id: String
    let parentSessionID: String?
    let provider: BuddyKind
    let displayTitle: String
    let terminalTitle: String
    let workspaceRoot: String?
    let lastEventName: String
    let lastToolName: String
    let lastMessage: String
    let lastActiveAt: Date
    let isPending: Bool
    let hasMissedApproval: Bool
    let isUnread: Bool
    let status: SessionStatus
}

struct FleetSessionGroup: Identifiable, Equatable {
    let root: FleetSessionDescriptor
    let children: [FleetSessionDescriptor]
    let isOrphan: Bool

    var id: String { root.id }
}

struct FleetCardModel: Identifiable, Equatable {
    let group: FleetSessionGroup
    let gitStates: [String: GitSnapshotState]
    let primaryGitState: GitSnapshotState?
    let overlaps: [FleetOverlapPeer]
    let primaryAttention: FleetAttentionKind
    let secondaryAttention: Set<FleetAttentionKind>

    var id: String { group.id }
}
```

`gitStates`의 key는 입력 `workspaceRoot`를 표준화한 문자열이다. 한 그룹에 child가 다른
worktree를 사용하는 경우도 잃지 않도록 그룹의 모든 고유 workspace root를 포함한다.

---

## 9. Git 명령 실행 계층

### 9.1 파일과 프로토콜

`DevIsland/Fleet/GitContextScanner.swift`에 다음을 둔다.

- `GitCommandRunning` 프로토콜
- `FoundationGitCommandRunner`
- `GitCommandResult`
- `GitContextScanning` 프로토콜
- `GitContextService` actor
- blocking Foundation `Process`를 감싸는 private helper

```swift
protocol GitCommandRunning: Sendable {
    func run(
        arguments: [String],
        currentDirectory: URL,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async -> GitCommandResult
}

enum GitCommandResult: Equatable, Sendable {
    case success(Data)
    case nonZeroExit(status: Int32, stderr: Data)
    case timedOut
    case outputTooLarge
    case launchFailed
}

protocol GitContextScanning: Sendable {
    func states(
        for workspaceRoots: Set<String>,
        forceRefresh: Bool
    ) async -> [String: GitSnapshotState]
}
```

테스트는 fake runner/scanner를 주입한다. production 코드에서 global shell helper나
`TerminalFocuser.getProcessOutput`을 재사용하지 않는다. TerminalFocuser helper는 출력 실패를
빈 문자열로 합쳐 원인을 구분할 수 없고 Git 파서 테스트 주입 seam도 제공하지 않는다.

### 9.2 실행 제한

| 항목 | 값 |
|---|---:|
| executable | `/usr/bin/git` |
| 명령별 timeout | 1.0초 |
| 명령별 stdout 상한 | 1 MiB |
| 동시 worktree scan | 최대 4 |
| 정상 snapshot TTL | 2초 |
| root identity alias | 활성 중 유지, 10분 미참조 시 제거 |
| UI debounce | 350ms |

환경 변수:

```text
LC_ALL=C
LANG=C
GIT_OPTIONAL_LOCKS=0
```

- `/bin/sh`을 사용하지 않는다.
- workspace path는 shell 문자열로 조합하지 않고 `Process.currentDirectoryURL`에 전달한다.
- stdout은 process 실행 중 계속 drain해 pipe buffer deadlock을 피한다.
- stderr도 process 실행 중 계속 drain하되 처음 8 KiB만 임시 보관하고 나머지는 버린다. 성공 시
  즉시 버리고, 실패 시 `.notRepository` 분류에만 사용한다. UI나 로그에는 원문을 노출하지 않는다.
- timeout, Task cancellation, output 상한 초과 시 process가 실행 중이면 terminate한다.
- 모든 blocking wait/read는 `Task.detached(priority: .utility)` 안에서 수행한다.

### 9.3 저장소/워크트리 식별 명령

scanner는 명령 실행 전에 입력 workspace root를 다음처럼 정규화한다.

1. 빈 문자열, NUL 포함, `/`로 시작하지 않는 상대 경로는 `.missingWorkspace`
2. `URL(fileURLWithPath:).standardizedFileURL.resolvingSymlinksInPath()` 적용
3. `FileManager.fileExists(atPath:isDirectory:)`로 존재하는 디렉터리인지 확인
4. 정규화 결과가 같은 입력은 deduplicate
5. process 시작 순서와 테스트 결정성을 위해 정규화된 root를 String 오름차순 정렬

이 검증과 filesystem 접근도 MainActor가 아닌 `GitContextService`/utility 실행 경계에서 한다.
각 고유 정규화 workspace root에서 먼저 다음 명령을 실행한다.

```bash
/usr/bin/git rev-parse --path-format=absolute --show-toplevel --git-common-dir
```

출력:

1. worktree top-level 절대 경로
2. common Git directory 절대 경로

rev-parse 출력은 UTF-8로 엄격하게 디코딩하고 마지막 LF 하나를 제거한 뒤 정확히 두 줄인지
검사한다. 빈 줄, 두 줄이 아닌 출력, CR/NUL 포함은 `.malformedOutput`으로 처리한다. rev-parse는
이 조합에서 NUL framing을 제공하지 않으므로 LF가 포함된 저장소 경로는 추측해서 파싱하지 않고
Git context unavailable로 안전하게 실패시킨다. 일반 파일 변경 경로는 아래 status 명령의 `-z`
출력을 사용하므로 LF를 포함해도 안전하다.

rev-parse가 non-zero로 끝나면 `LC_ALL=C` stderr에 Git의 고정 문구
`not a git repository`가 포함된 경우만 `.notRepository`로 분류한다. 그 외 non-zero는
`.commandFailed`다. stderr 디코딩 실패도 `.commandFailed`로 처리하고 원문은 폐기한다.

두 경로에 다음 정규화를 적용한다.

1. `URL(fileURLWithPath:).standardizedFileURL`
2. `resolvingSymlinksInPath()`
3. root가 아닌 경우 trailing slash 제거

common Git directory가 같은 snapshot만 비교 대상이다. 서로 다른 clone은 remote URL이 같아도
다른 저장소로 취급한다.

입력 workspace가 저장소 하위 폴더여도 `--show-toplevel` 결과를 worktree identity로 사용한다.
actor는 `input root → canonical top-level` alias map을 캐시해 다음 갱신부터 중복 스캔을 줄인다.

### 9.4 상태 명령

식별 성공 후 canonical top-level에서 실행한다.

```bash
/usr/bin/git -c core.fsmonitor=false status --porcelain=v2 --branch -z --untracked-files=all --no-ahead-behind
```

선택 이유:

- `--porcelain=v2`: 기계 파싱용 안정 형식
- `--branch`: branch head와 OID 확보
- `-z`: 공백, 따옴표, 줄바꿈 escape에 의존하지 않는 NUL 구분
- `--untracked-files=all`: untracked 디렉터리 아래 실제 파일 경로까지 비교
- `--no-ahead-behind`: 해커톤 MVP에서 필요 없는 graph walk 제거
- `-c core.fsmonitor=false`: 저장소별 fsmonitor hook/daemon을 실행하지 않고 읽기 전용 경계를 유지

ignored 파일은 비교하지 않는다. submodule 내부 파일은 재귀 스캔하지 않고 상위 저장소가
보고한 submodule path 하나만 변경 경로로 취급한다.

---

## 10. Porcelain v2 파서

파서는 `DevIsland/Fleet/GitStatusPorcelainV2Parser.swift`의 상태 없는 순수 타입으로 만든다.

```swift
struct GitStatusParseResult: Equatable, Sendable {
    let branchHead: String
    let headOID: String?
    let changedPaths: Set<String>
    let changedEntryCount: Int
    let hasUnmergedEntries: Bool
}

enum GitStatusPorcelainV2Parser {
    static func parse(_ data: Data) throws -> GitStatusParseResult
}
```

### 10.1 NUL token 처리

`-z` 출력은 header와 record 모두 NUL로 끝난다. Data를 NUL byte로 나누고 빈 마지막 token을
버린다. 각 token은 UTF-8로 엄격하게 변환한다. 변환 실패 시 replacement character를 넣지 말고
`malformedOutput`으로 전체 snapshot을 실패시킨다. 잘못 디코딩한 경로로 false negative
overlap을 만들지 않기 위해서다.

### 10.2 Header

다음 header만 읽고 나머지는 무시한다.

- `# branch.oid <oid>`
- `# branch.head <name>`

처리 규칙:

- `branch.oid (initial)`이면 `headOID = nil`
- `branch.head (detached)`이면 표시 branch는 `detached@<OID 앞 8자>`
- unborn branch는 `branch.head` 이름을 그대로 표시
- head header가 없으면 `malformedOutput`

### 10.3 변경 record

| prefix | 의미 | path 추출 |
|---|---|---|
| `1 ` | ordinary changed entry | 고정 필드 8개 뒤 나머지 |
| `2 ` | rename/copy | 고정 필드 9개 뒤 새 path + 다음 NUL token의 원 path |
| `u ` | unmerged | 고정 필드 10개 뒤 path, `hasUnmergedEntries = true` |
| `? ` | untracked | prefix 뒤 전체 |
| `! ` | ignored | 입력하지 않지만 들어오면 무시 |

공백을 포함한 path를 보존하기 위해 무제한 `split(separator: " ")`을 사용하지 않는다.
record 종류별 `maxSplits`로 고정 메타 필드까지만 나눈 뒤 마지막 field 전체를 path로 쓴다.

rename/copy는 새 path와 원 path를 모두 `changedPaths`에 넣는다. 한 worktree가 rename하고
다른 worktree가 원래 파일을 수정하는 경우도 overlap으로 잡기 위해서다.

`changedEntryCount`는 `1`, `2`, `u`, `?` record마다 하나씩 증가시킨다. rename은 overlap용
path가 두 개여도 dirty entry 한 개로 센다. UI의 dirty file count에는 `changedPaths.count`가
아니라 이 값을 사용한다.

빈 path, 예상보다 적은 필드, rename의 원 path token 누락은 전체 parse 실패다. 모르는 record
prefix도 조용히 무시하지 않고 parse 실패로 처리한다. Git 형식 변화가 false “Clean”으로
보이는 것을 막는다.

---

## 11. Snapshot 캐시와 동시성

### 11.1 `GitContextService` actor 상태

```swift
actor GitContextService: GitContextScanning {
    static let shared = GitContextService()

    private var snapshotCache: [GitWorktreeID: CachedSnapshot] = [:]
    private var rootCache: [String: CachedRootIdentification] = [:]
    private var identificationInFlight:
        [String: Task<RootIdentificationResult, Never>] = [:]
    private var snapshotInFlight:
        [GitWorktreeID: Task<GitSnapshotState, Never>] = [:]
}
```

`CachedSnapshot`과 `CachedRootIdentification`은 `capturedAt`과 `lastAccessedAt`을 함께 가진
private struct로 구현한다. `RootIdentificationResult`는 성공 시 repository/worktree identity를,
실패 시 `.missingWorkspace`, `.notRepository`, 명령 실패를 담는다. 성공 결과가 곧
`input root → canonical worktree` alias다. worktree ID를 만들기 전의 non-repository/failure
결과도 같은 cache에 입력 root 기준으로 둔다. 외부에서 mutable cache를 볼 수 없어야 한다.

### 11.2 갱신 트리거

Fleet는 파일 watcher나 영구 timer를 만들지 않는다.

갱신은 다음 경우에만 일어난다.

1. Fleet 탭 최초 표시
2. `SessionStore.activeSessions` 배열 변경
3. 사용자가 Refresh 버튼 클릭

hook event가 세션의 `lastActiveAt`과 최근 이벤트를 갱신하므로 agent가 파일 작업을 마친 뒤
자연스럽게 새 Git snapshot을 얻는다. 외부 편집기로만 변경한 경우 사용자가 Refresh를 누른다.

### 11.3 debounce와 오래된 결과 방지

`FleetRadarViewModel`은 MainActor에서 다음 순서를 지킨다.

1. 최신 세션 descriptor/group을 즉시 저장
2. 기존 debounce task 취소
3. 350ms 대기
4. 현재 고유 workspace root 집합을 service에 요청
5. 결과 수신 시 generation token과 현재 root 집합을 재검증
6. 일치할 때만 snapshot/overlap/card 배열을 한 번에 교체

세션이 scan 중 종료되면 결과가 돌아와도 generation mismatch로 버린다.

### 11.4 캐시 정책

- 정상 snapshot이 2초 이내면 재사용한다.
- 성공한 root identity는 활성 세션이 같은 입력 root를 계속 참조하는 동안 재사용한다.
- 실패한 root identity는 2초 동안만 재사용한다.
- `forceRefresh == true`면 root identity와 snapshot cache를 모두 무시하고 다시 식별한다.
- refresh 실패 전에 정상 snapshot이 있으면 `.stale(previous, failure)`를 반환한다.
- 정상 snapshot이 없으면 `.unavailable(failure)`.
- 종료된 세션의 alias/cache는 즉시 삭제할 필요가 없다. actor가 10분 이상 참조되지 않은 entry를
  `lastAccessedAt` 기준으로 다음 요청 시 lazy prune한다.
- 캐시 수명 관리를 위한 별도 timer는 만들지 않는다.

### 11.5 병렬 처리

갱신은 두 단계로 나눈다.

1. alias가 없거나 실패 cache가 만료된 각 고유 입력 root에서 rev-parse를 실행한다.
2. 식별에 성공한 결과를 canonical worktree로 그룹화하고, 각 worktree에서 status를 한 번만
   실행한다.

식별 root와 canonical worktree status 작업을 각각 최대 4개씩 chunk로 나누고 각 chunk를
`TaskGroup`으로 스캔한다. 두 단계는 순차이므로 동시에 실행되는 Git process는 전체에서 최대
4개다. 일반 갱신에서 이미 alias를 아는 입력 root는 rev-parse를 생략한다. 강제 갱신은 모든
입력 root를 다시 식별한다. 서로 다른 하위 경로가 첫 갱신에서 같은 worktree로 식별되더라도
status process는 하나만 실행한다.

같은 worktree의 in-flight task가 있으면 새 process를 시작하지 않고 그 task를 await한다.
UI task cancellation이 공유 in-flight task를 무조건 취소하지 않게 하고, 결과 적용만 generation
검사로 중단한다.

---

## 12. Overlap 분석

파일: `DevIsland/Fleet/FleetOverlapAnalyzer.swift`

```swift
enum FleetOverlapAnalyzer {
    static func analyze(
        snapshots: [GitWorktreeSnapshot]
    ) -> [GitWorktreeID: [FleetOverlapPeer]]
}
```

### 12.1 알고리즘

1. `repositoryID`로 snapshot을 그룹화한다.
2. 같은 `worktreeID`는 하나로 deduplicate한다.
3. 각 저장소 그룹에서 worktree pair를 한 번씩만 비교한다.
4. `lhs.changedPaths.intersection(rhs.changedPaths)`를 계산한다.
5. 교집합이 비어 있으면 결과를 만들지 않는다.
6. 비어 있지 않으면 양쪽 방향의 `FleetOverlapPeer`를 만든다.
7. paths는 byte/Unicode 변환 이후 Swift String의 `<` 기준으로 정렬한다.
8. peer 목록은 peer branch, peer worktree path 순으로 안정 정렬한다.

복잡도는 저장소별 `O(W² × min(Pa, Pb))`다. Fleet의 대상 worktree 수는 보통 한 자릿수이고
`Set.intersection`을 사용하므로 MVP에 충분하다.

### 12.2 비교하지 않는 경우

- 서로 다른 `repositoryID`
- 동일 `worktreeID`
- `.unavailable` snapshot
- `.stale` snapshot은 비교하되 UI에 stale임을 표시
- changed path가 빈 snapshot

같은 worktree를 가리키는 여러 세션은 서로 overlap으로 표시하지 않는다. 동일 snapshot을 각
세션 카드가 공유할 뿐이다.

### 12.3 안전한 표현

UI/로그/문서에서 다음 용어만 사용한다.

- 허용: `Overlap risk`, `Overlapping changed files`
- 금지: `Merge conflict detected`, `These branches will conflict`

---

## 13. ViewModel과 카드 조립

파일: `DevIsland/Fleet/FleetRadarViewModel.swift`

```swift
@MainActor
final class FleetRadarViewModel: ObservableObject {
    @Published private(set) var cards: [FleetCardModel] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastCompletedAt: Date?

    private let scanner: any GitContextScanning
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
}
```

### 13.1 세션 그룹 생성

1. `parentSessionId == nil`인 세션을 root로 만든다.
2. parent가 active list에 있으면 child를 해당 root에 붙인다.
3. parent가 없으면 orphan 자신을 root로 하는 그룹을 만든다.
4. child는 `lastActiveAt descending, id ascending`으로 정렬한다.
5. group의 `newestActivityAt`은 root/children의 최대값이다.
6. group의 workspace root 집합은 root/children의 non-empty 값을 모두 포함한다.
7. `displayTitle`은 `AppState.sessionLabels[id] ?? terminalTitle`로 만든다.

### 13.2 카드 Git 표시

- root workspace snapshot을 primary로 표시한다.
- root에 workspace가 없으면 첫 child workspace snapshot을 primary로 사용한다.
- `primaryGitState`는 ViewModel이 표준화한 root key로 미리 계산해 View에서 파일 I/O 없이 읽는다.
- 그룹에 canonical worktree가 두 개 이상이면 “N worktrees” badge를 표시한다.
- overlap은 그룹이 참조하는 모든 worktree의 peer 결과를 합치고 중복 ID를 제거한다.

### 13.3 Attention 집계

root와 child 전체에서 attention condition을 평가한다.

- 하나라도 pending/missed면 `needsDecision`
- 하나라도 policy denied/timeout bypass 또는 snapshot unmerged면 `blocked`
- 그룹 worktree 중 하나라도 overlap이면 `overlapRisk`
- 하나라도 unread면 `unread`
- 위 조건이 하나도 없을 때만 `live`를 fallback으로 포함

primary는 raw priority 최솟값이다.

### 13.4 View 생명주기

- `deinit`에서 `refreshTask?.cancel()`
- `SessionHistoryWindowView`가 `@StateObject`로 `FleetRadarViewModel`을 소유한다. 탭 전환으로
  view model/cache가 재생성되지 않게 한다.
- `FleetRadarView`는 그 인스턴스를 `@ObservedObject`로 받는다.
- Fleet view `onAppear`에서 현재 sessions/labels로 즉시 refresh
- `activeSessions` 또는 `AppState.sessionLabels` 변경은
  `update(sessions:labels:forceRefresh: false)`
- Refresh 버튼은 `forceRefresh: true`
- view model은 `SessionStore`를 직접 소유하지 않는다. View가 현재 배열을 전달한다.
- 테스트에서 fake scanner를 주입할 수 있어야 한다.

`SessionHistoryWindowView.init(appState:scanner:)`는 `appState ?? .shared`를 한 번만 resolve하고
기존 `SessionHistoryViewModel`, 관찰할 `AppState`/`SessionStore`, 새 Fleet view model 모두에 같은
인스턴스를 전달한다. production 기본 scanner는 `GitContextService.shared`다. 탭 selection은
`@State private var selectedTab: SessionCenterTab = .fleet`로 둔다.

---

## 14. SwiftUI 구성

파일: `DevIsland/Fleet/FleetRadarView.swift`

권장 private child view:

- `FleetToolbar`
- `FleetCardView`
- `FleetGitSummaryView`
- `FleetAttentionBadge`
- `FleetOverlapPopover`
- `FleetSubagentRow`
- `FleetRelativeTimeView`

### 14.1 렌더링 규칙

- SwiftUI `body`에서 Git process, scanner method, 파일 I/O를 호출하지 않는다.
- View는 `viewModel.cards` cache만 읽는다.
- 상대 시간 갱신은 `FleetRelativeTimeView` child의 `TimelineView`에 격리한다.
- 상대 시간 갱신이 card model 재정렬이나 열린 popover 재생성을 일으키지 않게 한다.
- overlap paths가 많아도 popover에서 `LazyVStack`을 사용한다.
- card identity는 root session ID로 고정한다.
- refresh 중 기존 card identity/model을 유지한다.

### 14.2 접근성

각 카드에 다음을 합친 accessibility label을 제공한다.

```text
<title>, <provider>, <primary attention>,
branch <branch>, <dirty file count>, <overlap count>
```

- badge는 텍스트를 숨기지 않는다.
- Focus/Detail/Finder/Copy 버튼에 독립 label/help를 제공한다.
- 키보드 Tab 순서는 카드 → Detail → Focus → Finder → Copy → overlap detail이다.
- orange/red/blue만으로 상태를 구분하지 않는다.
- Reduce Motion에서는 카드 재정렬에 별도 transition animation을 붙이지 않는다.

### 14.3 다국어

영문과 한글을 동시에 추가한다.

수정 대상:

- `DevIsland/Utility/Localizable.swift`
- `DevIsland/Localizable.xcstrings`
- `DevIslandTests/LocalizableCatalogGoldenTests.swift`

`scripts/gen_l10n.py`는 one-shot migration 도구이므로 다시 실행하지 않는다. 새 key는 위 세 파일에
기존 형식대로 수동 추가하고 golden test에서 영문/한글 값을 검증한다.

필수 key 범주:

- Session Center 메뉴/윈도우 제목
- Fleet/Sessions/Insights tab
- toolbar count와 refresh
- attention 종류 5개
- clean/dirty/unmerged/stale/unavailable/not-repository
- overlap 안내와 file count
- empty state
- 4개 액션과 Focus 주의 help
- sub-agent/orphan/more 표시

---

## 15. 승인·포커스·플러그인 경계

### 15.1 절대 바꾸지 않는 파일/경로

Fleet 구현을 위해 다음을 수정하지 않는다.

- `HookSocketServer.swift`
- bridge scripts
- `ApprovalProxyController.swift`
- `ApprovalPolicyEngine.swift`
- `ApprovalFlowCoordinator.swift`
- `ProviderAdapter.swift`
- `SQLiteApprovalStore.swift`
- 플러그인 event/effect/permission 모델

### 15.2 상태 소유권

- `SessionStore`: provider/hook 기반 live session 사실
- `GitContextService`: Git snapshot/cache
- `FleetRadarViewModel`: UI용 결합/정렬 상태
- `FleetRadarView`: 표시와 명시적 user action

Fleet가 `ActiveSession.status`를 갱신하거나 `pendingQueue`를 읽고 쓰지 않는다.

### 15.3 포커스 주의

`AppState.focusTerminal(for:)`는 기존 의도대로 terminal focus 후 표시 중인 요청을 native
terminal prompt로 pass할 수 있다. Fleet는 이 함수를 재정의하거나 우회하지 않는다.

- 카드 선택에는 `showSessionDetail`만 사용
- Focus 버튼에만 `focusTerminal(for:)`
- 자동 focus 금지
- overlap 발견 시 notification/auto-expand 금지

---

## 16. 파일별 변경 계획

### 16.1 신규 production 파일

| 파일 | 책임 |
|---|---|
| `DevIsland/Fleet/FleetRadarModels.swift` | Git/Fleet value types와 attention enum |
| `DevIsland/Fleet/GitStatusPorcelainV2Parser.swift` | porcelain v2 Data 순수 파서 |
| `DevIsland/Fleet/GitContextScanner.swift` | Process runner, scan protocol, actor cache |
| `DevIsland/Fleet/FleetOverlapAnalyzer.swift` | repository/worktree별 path 교집합 |
| `DevIsland/Fleet/FleetRadarViewModel.swift` | debounce, stale result guard, card 조립/정렬 |
| `DevIsland/Fleet/FleetRadarView.swift` | toolbar, grid, card, popover, actions |

`project.yml`은 `DevIsland` 디렉터리를 재귀 source로 포함하므로 수정하지 않는다.

### 16.2 수정 production 파일

| 파일 | 변경 |
|---|---|
| `DevIsland/Session/SessionHistoryWindow.swift` | Fleet tab을 첫 탭으로 추가, selection과 scanner 주입 |
| `DevIsland/Settings/SettingsWindow.swift` | Session Center 초기 창 크기 변경 |
| `DevIsland/Utility/Log.swift` | privacy-safe `Log.fleet` category 추가 |
| `DevIsland/Utility/Localizable.swift` | typed Fleet 문자열 |
| `DevIsland/Localizable.xcstrings` | 영문/한글 Fleet 번역 |

### 16.3 신규 테스트 파일

| 파일 | 책임 |
|---|---|
| `DevIslandTests/GitStatusPorcelainV2ParserTests.swift` | NUL/header/record/rename/unmerged 파싱 |
| `DevIslandTests/GitContextScannerTests.swift` | fake runner, timeout/error/stale/cache/alias |
| `DevIslandTests/FleetOverlapAnalyzerTests.swift` | 저장소/worktree/path 교집합 |
| `DevIslandTests/FleetRadarViewModelTests.swift` | 그룹, attention, 정렬, debounce, stale generation |

### 16.4 수정 테스트/문서

| 파일 | 변경 |
|---|---|
| `DevIslandTests/LocalizableCatalogGoldenTests.swift` | Fleet 영문/한글 golden |
| `docs/agent/ui-customization.md` | Session Center/Fleet 표면과 Git I/O 경계 |
| `docs/product-vision-and-roadmap.md` | H2-1/H2-2 구현 상태/링크 갱신 |
| `CHANGELOG.md` | 실제 기능 완료 시 사용자 가치 중심 항목 |
| `README.md` | 해커톤 신규 범위, 실행/테스트, Codex 협업 기록 |

---

## 17. 단계별 구현 순서

각 단계는 독립적으로 컴파일/테스트 가능한 최소 단위다.

### 단계 0. 작업 시작점 고정

목표:

- feature branch와 해커톤 기준점을 만든다.
- 기존 코드와 신규 기능의 경계를 기록한다.

작업:

1. `codex/build-week-fleet-radar` branch 생성
2. 기준 commit SHA와 시작 시각을 README 초안에 기록
3. 핵심 구현을 진행할 Codex task를 하나로 유지
4. 제품 결정 변경은 이 문서 Decision Log에 먼저 반영

검증:

- `git status --short`가 clean
- branch가 `main`이 아님

### 단계 1. Fleet/Git value type

목표:

- UI와 I/O 없이 데이터 계약을 먼저 고정한다.

작업:

1. `FleetRadarModels.swift` 추가
2. 모든 background 왕복 타입에 `Sendable` 추가
3. failure/stale/unavailable 상태를 분리
4. overlap peer ID가 양쪽 worktree를 안정적으로 식별하도록 구현

테스트:

- value equality
- overlap peer ID가 repository/worktree pair마다 다름
- attention raw priority 고정

검증:

- focused test
- 전체 테스트

### 단계 2. Porcelain v2 순수 파서

목표:

- 실제 Process 없이 모든 Git 상태 형식을 파싱한다.

작업:

1. NUL tokenizer
2. branch header 파싱
3. ordinary/untracked/unmerged record
4. rename/copy의 추가 origin token
5. 엄격한 오류 처리

필수 fixture:

- clean branch
- detached HEAD
- unborn branch
- staged/unstaged/deleted
- untracked path
- 공백/한글/따옴표를 포함한 path
- rename old/new path
- unmerged entry
- truncated rename
- unknown prefix
- invalid UTF-8

rename fixture는 `changedPaths`가 old/new 두 경로이고 `changedEntryCount == 1`인지 함께 검증한다.

검증:

- `GitStatusPorcelainV2ParserTests`
- `./scripts/run-tests.sh`

### 단계 3. Git command runner

목표:

- shell 없이 cancellable/timeout-bound Git 실행 계층을 만든다.

작업:

1. `GitCommandRunning` 프로토콜
2. `FoundationGitCommandRunner`
3. stdout drain와 1 MiB 상한
4. timeout/cancellation terminate
5. stable environment

테스트:

- production Process 자체를 sleep 명령으로 테스트하지 않는다.
- runner 결과 분기 로직은 fake low-level executor 또는 injectable closure로 검증한다.
- 실제 `/usr/bin/git` smoke test는 통합/수동 검증에 둔다.

검증:

- 메인 스레드에서 호출되지 않는지 코드 리뷰
- 전체 테스트

### 단계 4. GitContextService actor

목표:

- 저장소 식별, status 파싱, cache/alias/stale fallback을 결합한다.

작업:

1. rev-parse 결과 파싱/정규화
2. status 명령과 parser 연결
3. input root alias
4. 2초 TTL
5. in-flight dedupe
6. 최대 4개 병렬 scan
7. 10분 lazy prune

테스트:

- non-repository
- rev-parse non-zero가 not-repository 문구가 아니면 command failure
- rev-parse 성공 후 status 실패
- 이전 정상 결과가 있을 때 stale
- TTL hit는 runner 미호출
- force refresh는 runner 재호출
- force refresh는 root identity도 다시 식별
- 같은 canonical worktree alias dedupe
- 오래된 alias/cache prune

검증:

- `GitContextScannerTests`
- 전체 테스트

### 단계 5. Overlap analyzer

목표:

- snapshot에서 UI 독립적인 양방향 overlap 결과를 만든다.

테스트 우선 케이스:

1. 같은 repo + 다른 worktree + 같은 path → 양쪽 결과
2. 같은 repo + 다른 path → 없음
3. 다른 repo + 같은 path → 없음
4. 같은 worktree가 중복 입력 → 자기 overlap 없음
5. rename old path와 상대 수정 → overlap
6. stale snapshot → 분석에는 포함
7. empty changed paths → 없음
8. peer/path 정렬 결정성

검증:

- `FleetOverlapAnalyzerTests`
- 전체 테스트

### 단계 6. FleetRadarViewModel

목표:

- session grouping, refresh generation, attention/card 정렬을 UI에서 분리한다.

작업:

1. `ActiveSession → FleetSessionDescriptor` MainActor 변환
2. parent/child/orphan 그룹
3. 350ms debounce
4. root 집합 scan 요청
5. stale generation discard
6. overlap/card model 결합
7. attention/tie-break sort

테스트:

- child가 부모 카드에 붙음
- orphan 독립 카드
- child pending이 부모 primary attention을 올림
- blocked/overlap/unread 우선순위
- 같은 우선순위 최근 활동 정렬
- scan 중 새 session update가 오면 이전 결과 무시
- force refresh 전달
- empty sessions에서 cards/reset

검증:

- `FleetRadarViewModelTests`
- 전체 테스트

### 단계 7. Fleet UI

목표:

- cached model만 렌더하는 완결된 Fleet 화면을 만든다.

작업:

1. toolbar/empty state
2. adaptive grid
3. card header/Git/activity
4. attention badges
5. overlap popover
6. sub-agent list
7. Detail/Focus/Finder/Copy 액션
8. accessibility

검증:

- build-only
- 최소 900x560과 큰 창에서 layout 확인
- light/dark appearance 확인
- Reduce Motion/VoiceOver 수동 확인

### 단계 8. Session Center 통합

목표:

- Fleet를 기존 표준 창에 연결하고 기존 탭 회귀를 막는다.

작업:

1. `SessionHistoryWindowView`에 tab selection enum 추가
2. `@StateObject` Fleet view model과 scanner 주입 initializer 추가
3. Fleet를 첫/default tab으로 삽입
4. sessions와 labels 변경을 Fleet update에 연결
5. 기존 Sessions/Insights 유지
6. 초기/최소 크기 변경
7. 메뉴/윈도우 제목을 Session Center로 번역 변경

검증:

- 메뉴에서 창을 여러 번 열어 controller cache 재사용
- 창을 닫았다 다시 열 때 refresh
- Sessions 검색/즐겨찾기/Quick Launch 회귀 없음
- Insights 데이터 조회 회귀 없음

### 단계 9. 다국어와 문서

목표:

- 해커톤 제출과 유지보수에 필요한 텍스트/문서를 완성한다.

작업:

1. `L10n`, catalog, golden test 동기화
2. `ui-customization.md` 갱신
3. 제품 로드맵 상태 갱신
4. CHANGELOG 추가
5. 영문 README에 “What was built during Build Week” section
6. 설치 가능한 DMG/ZIP과 테스트 절차 기록

검증:

- Localizable golden test
- 영문/한글 live language switch
- Markdown link check

### 단계 10. 최종 검증과 데모 고정

명령:

```bash
./scripts/run-tests.sh
./scripts/build_and_run.sh --no-kill --no-run
```

수동 acceptance 시나리오를 모두 통과한 뒤 demo용 worktree/세션 이름과 파일을 고정한다.

---

## 18. 테스트 매트릭스

### 18.1 자동 테스트

| 영역 | 정상 | 경계 | 실패 |
|---|---|---|---|
| status parser | branch + changed files | detached/unborn/rename/unicode | malformed/unknown/invalid UTF-8 |
| scanner | repo snapshot | subdir root/alias/cache | non-repo/timeout/nonzero/too large |
| overlap | same repo pair | rename/stale/multiple peers | other repo/same worktree/empty |
| grouping | parent + children | orphan/different workspaces | empty input |
| attention | pending/blocked/overlap/unread/live | child aggregation/tie | deterministic fallback |
| refresh | initial/session change/force | debounce/in-flight | stale generation ignored |
| l10n | English | Korean | key/golden mismatch |

### 18.2 수동 기능 시나리오

1. **Clean worktree**
   - branch와 Clean 표시
   - overlap 없음
2. **서로 다른 파일 수정**
   - 같은 repo의 worktree 두 개
   - 각 카드 dirty
   - overlap 없음
3. **같은 파일 수정**
   - 양쪽 카드 Overlap risk
   - popover path/peer 정확
4. **rename 대 수정**
   - 한쪽 rename, 다른 쪽 원 파일 수정
   - overlap 표시
5. **세 번째 worktree**
   - 한 카드가 두 peer와 겹침
   - section/정렬 정확
6. **pending approval**
   - 해당 카드가 최상단
   - 승인 큐/노치 표시 불변
7. **sub-agent pending**
   - 부모 카드가 최상단
   - child에 attention dot
8. **non-Git workspace**
   - 카드 유지, Not a Git repository
9. **detached HEAD**
   - `detached@<OID>`
10. **Git timeout/failure**
    - UI 멈춤 없음
    - 이전 snapshot stale 또는 unavailable
11. **창 닫기/다시 열기**
    - 최신 세션과 Git 상태로 refresh
12. **Focus**
    - 카드 클릭은 터미널 focus 안 함
    - Focus 버튼만 정확한 terminal/tab/tmux pane 이동

### 18.3 성능 수동 검사

- 활성 worktree 1, 4, 8개에서 refresh 시간 기록
- refresh 중 notch 승인 응답 지연이 없는지 확인
- 빠른 hook burst에서 debounce가 process 폭증을 막는지 로그로 확인
- Activity Monitor에서 닫힌 Session Center가 지속 CPU를 사용하지 않는지 확인

---

## 19. 성능·안전 예산

| 지표 | 인수 기준 |
|---|---:|
| 메인 스레드 Git I/O | 0회 |
| hook/approval response path Git I/O | 0회 |
| cache 없는 고유 입력 root 식별 process | root당 최대 1개 |
| canonical worktree status process | worktree당 최대 1개 |
| alias가 알려진 worktree refresh process | worktree당 최대 1개 |
| 강제 refresh | 입력 root당 식별 1개 + worktree당 status 1개 |
| 동시 Git process | 최대 4개 |
| process timeout | 1.0초 |
| process stdout | 최대 1 MiB |
| process stderr 임시 보관 | 최대 8 KiB, 분류 후 폐기 |
| hook burst debounce | 350ms |
| 정상 cache TTL | 2초 |
| background polling | 없음 |
| 네트워크 | 없음 |
| Git 쓰기 | 없음 |

Git status가 1 MiB를 넘으면 일부 경로만 사용하지 않고 전체 snapshot을
`.outputTooLarge`로 실패시킨다. 일부 결과로 overlap 없음이라고 판단하는 것보다 명시적
unavailable이 안전하다.

---

## 20. 로깅과 개인정보

`DevIsland/Utility/Log.swift`에 subsystem을 공유하는 `Log.fleet` category를 추가하고 Fleet의
scanner/cache/view model 진단은 이 category만 사용한다.

로그 원칙:

- repository/worktree 절대 경로는 `.private`
- changed path와 file name은 기본 로그에 기록하지 않음
- session ID는 prefix만 `.private`
- timeout, failure 종류, scan 수, elapsed time은 `.public`
- 정상 refresh마다 info log를 남기지 않고 debug 사용
- overlap 경로 내용은 UI cache에만 있고 SQLite/replay log에 저장하지 않음

---

## 21. 문서 및 릴리스 동기화

실제 구현 PR에서 다음 문서를 같은 논리 변경으로 갱신한다.

### `docs/agent/ui-customization.md`

- Session Center 탭 구성
- Fleet는 standard NSWindow이며 notch panel이 아님
- Git I/O는 view model/service cache 경유
- auto-collapse/approval UI에 영향 없음

### `docs/product-vision-and-roadmap.md`

- H2-1 Fleet 보드: MVP 완료 범위 기록
- H2-2 Git 컨텍스트: branch/dirty/overlap 완료, PR/CI/ahead-behind 미완 기록
- “merge conflict detection”이 아니라 path overlap임을 명시

### `README.md`

- 영어 설치/테스트 경로
- 지원 플랫폼 macOS 15+
- Fleet Radar 데모 GIF/스크린샷
- Build Week 이전/이후 기능 구분
- Codex와 GPT-5.6을 사용한 설계/구현/검증 과정
- `/feedback` Codex Session ID

### `CHANGELOG.md`

구현 세부보다 사용자 가치를 쓴다.

> Added Fleet Radar to prioritize sessions that need attention and warn when active Git
> worktrees modify the same paths.

---

## 22. 3분 데모 시나리오

### 0:00–0:20 — 문제

- 서로 다른 worktree에서 Codex 세션 3개가 실행 중인 화면
- “여러 agent가 동시에 일할 때 어디에 개입해야 하고 작업이 겹치는지 알기 어렵다.”

### 0:20–0:50 — Fleet 개요

- Session Center → Fleet
- provider, branch, dirty count, sub-agent를 한 화면에서 보여 줌
- 모든 분석이 로컬임을 한 문장으로 설명

### 0:50–1:25 — Overlap

- 두 worktree에서 같은 파일을 수정
- Refresh 또는 hook event 뒤 Overlap risk 표시
- popover에서 상대 branch와 겹친 경로 확인
- “실제 conflict 단정이 아니라 조기 경고” 설명

### 1:25–1:55 — Attention ranking

- 세 번째 세션에서 approval request 발생
- 해당 카드가 최상단으로 이동
- sub-agent pending이면 부모 카드가 올라오는 모습

### 1:55–2:20 — Context restore

- 카드 Show Detail
- 명시적 Focus Terminal로 정확한 terminal/worktree 복귀

### 2:20–2:45 — 기술

- porcelain v2 parser, actor cache, no-network, no-Git-write
- Codex/GPT-5.6로 테스트 우선 구현한 commit/session 기록

### 2:45–3:00 — 결과

- “One glance: where do I need to act, and where are agents overlapping?”
- 설치/test build URL

영상은 2분 45초 정도로 편집해 3분 제한에 여유를 둔다.

---

## 23. 해커톤 제출 체크리스트

- [ ] Devpost 등록과 Official Rules/참가 자격 재확인
- [ ] Developer Tools category 선택
- [ ] 신규 기능 commit이 2026-07-13 이후임을 확인
- [ ] Build Week 이전/이후 범위가 README에 분리됨
- [ ] 핵심 구현 Codex task의 `/feedback` Session ID 확보
- [ ] 3분 미만 공개 YouTube 영상과 음성 설명
- [ ] 영상에서 실제 동작, Codex 사용, GPT-5.6 사용을 모두 설명
- [ ] 허가 없는 저작권 음악/제3자 상표 소재 없음
- [ ] 영어 narration 또는 영어 자막
- [ ] 공개 저장소면 관련 license 포함
- [ ] private 저장소면 `testing@devpost.com`, `build-week-event@openai.com`에 access 부여
- [ ] Project description과 설치/실행/테스트 방법
- [ ] macOS 15+ 지원과 설치 방법
- [ ] 심사위원이 rebuild 없이 실행할 DMG/ZIP
- [ ] unsigned build라면 최초 실행 절차를 정확히 검증/기재
- [ ] sample/demo worktree 생성 방법
- [ ] `./scripts/run-tests.sh` 결과
- [ ] build-only 결과
- [ ] 라이선스와 third-party attribution

---

## 24. 권장 커밋 분할

### Commit 1

```text
feat: add local Git fleet analysis
```

- models
- porcelain parser
- scanner/cache
- overlap analyzer
- 관련 테스트

### Commit 2

```text
feat: add Fleet Radar session dashboard
```

- view model
- Fleet UI
- Session Center 통합
- localization/accessibility
- 관련 테스트

### Commit 3

```text
docs: document Fleet Radar and Build Week demo
```

- UI/제품 문서
- README/CHANGELOG
- 제출/데모 증빙

각 커밋 body는 AGENTS.md 규칙에 따라 변경 이유를 한국어로 쓰고
`Co-Authored-By: Codex <noreply@openai.com>` trailer를 포함한다.

---

## 25. 최종 인수 체크리스트

### 기능

- [ ] 최상위 세션 카드와 sub-agent 중첩
- [ ] branch/detached/clean/dirty/unmerged 표시
- [ ] 같은 repo, 다른 worktree만 비교
- [ ] 양방향 overlap 표시
- [ ] attention 정렬
- [ ] Detail과 Focus 동작 분리
- [ ] non-Git/failure/stale UI

### 경계

- [ ] approval queue와 provider response 변경 없음
- [ ] Git I/O main thread 없음
- [ ] hook response path Git I/O 없음
- [ ] shell 실행 없음
- [ ] Git 쓰기 없음
- [ ] network 없음
- [ ] polling timer 없음

### 품질

- [ ] parser/analyzer/scanner/view model 테스트
- [ ] 영문/한글 golden
- [ ] 전체 테스트
- [ ] build-only
- [ ] 수동 12개 시나리오
- [ ] 문서 동기화
- [ ] 3분 데모 리허설

---

## 26. 후속 확장 경계

Fleet Radar MVP가 안정화된 뒤 별도 계획으로 검토한다.

1. **Trust Window**
   - 세션/워크스페이스/시간/위험도 한정 자동 승인
   - Fleet 카드에 남은 시간 표시
2. **PR/CI context**
   - `gh` opt-in, network permission과 timeout 필요
3. **ahead/behind**
   - Git graph 비용과 refresh budget 재평가
4. **구조화된 working/error 상태**
   - provider 문자열 추측 없이 SessionStatus 확장
5. **semantic overlap explanation**
   - 명시적 opt-in과 최소 diff 전송 설계가 선행될 때만 검토

이 후속 기능은 해커톤 MVP에 섞지 않는다.

---

## 27. Decision Log

| 날짜 | 결정 | 이유 |
|---|---|---|
| 2026-07-16 | Fleet를 expanded notch가 아닌 Session Center 탭에 배치 | 승인 NSPanel과 Git I/O/대형 grid를 분리 |
| 2026-07-16 | path overlap만 판정 | 결정론적이고 오해 가능성이 낮으며 5일 범위에 맞음 |
| 2026-07-16 | runtime GPT 호출 없음 | 로컬 우선, 개인정보, 정확성 유지 |
| 2026-07-16 | background polling 없음 | hook/session 변화 + manual refresh로 충분, idle CPU 방지 |
| 2026-07-16 | 카드 클릭과 terminal focus 분리 | 의도치 않은 approval pass/focus 전환 방지 |
| 2026-07-16 | porcelain v2 `-z` 엄격 파서 | path 안전성과 false clean/overlap 방지 |
