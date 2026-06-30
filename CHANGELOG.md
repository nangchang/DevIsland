# Changelog

## v0.13.0 - 2026-06-30

이번 릴리즈는 세션을 다시 찾고 이어가는 흐름을 강화하고, 승인 요청과 터미널 포커스 경험을 더 똑똑하게 다듬은 기능 업데이트입니다. Compact notch 영역을 플러그인으로 확장할 수 있게 되었고, 세션 히스토리/인사이트, macOS 알림, Always allow 제안, AoE 터미널 탐색과 bridge 성능 개선도 함께 담았습니다.

### Highlights

- Compact notch의 좌우 영역을 플러그인 contribution으로 확장할 수 있게 하고, 기존 compact 표시를 기본 플러그인으로 이전했습니다.
- 세션 히스토리 창에 live session 표시, 즐겨찾기, 설명 편집과 Insights 탭을 추가했습니다.
- Quick Launch로 작업 경로 컨텍스트 메뉴에서 새 세션을 바로 시작할 수 있게 했습니다.
- Advanced 설정에 Diagnostics pane을 추가해 provider별 bridge hook 설치 상태를 확인할 수 있게 했습니다.

### UI/UX

- 승인 요청을 macOS Notification Center로도 받을 수 있게 하고, 설정에서 알림 동작을 제어할 수 있게 했습니다.
- 같은 도구를 반복 승인한 뒤에는 `Always allow` 제안을 표시해 승인 규칙 생성 흐름을 줄였습니다.
- Claude `AskUserQuestion` 중에는 Always allow 제안을 숨겨 질문 응답 UI와 승인 제안이 섞이지 않도록 했습니다.
- 세션 설명 편집기와 세션 히스토리 행 표시를 다듬어 긴 텍스트와 live session 상태가 더 안정적으로 보입니다.

### Terminal & Hooks

- WezTerm, iTerm, Apple Terminal에서 AoE TUI의 올바른 세션으로 이동한 뒤 터미널을 포커스하도록 개선했습니다.
- tmux manager, detached session, stale metadata 상황에서도 실제 터미널 앱과 세션 제목을 더 정확히 복원합니다.
- 무시할 hook 이벤트는 터미널 감지 전에 빠르게 prefilter하고, Python bridge 이중 시작을 피하도록 bridge 경로를 최적화했습니다.
- Antigravity, Claude, Codex, Gemini provider handler 등록 구조를 정리하고 golden response 테스트를 확충했습니다.

### Stability & Performance

- invalid pending approval request는 승인으로 오해하지 않도록 provider 흐름에 맞는 pass 응답으로 처리합니다.
- 승인 결정 조회용 SQLite composite index를 추가하고 replay log 읽기와 diagnostics 조회를 메인 스레드 밖으로 옮겼습니다.
- 터미널 포커스 타이밍과 Apple Terminal tab 선택 경로를 안정화했습니다.
- bridge 로그 tail 읽기와 shell terminal detector 구조를 개선해 hook 응답 경로의 비용을 줄였습니다.

### Internal & CI

- Python bridge 테스트, shellcheck, main push CI trigger와 nightly golden response 안정화 테스트를 추가했습니다.
- ProviderAdapter, terminal detector, TerminalContext 구조를 정리해 provider/terminal별 확장을 더 작고 명확하게 만들었습니다.
- AI-friendly PR/issue template과 DevIsland issue triage skill을 추가했습니다.
- bridge 성능 감사, AoE 터미널 포커스, 플러그인 아키텍처와 로드맵 문서를 최신 상태로 갱신했습니다.

**Full Changelog**: https://github.com/nangchang/DevIsland/compare/v0.12.0...v0.13.0

## v0.12.0 - 2026-06-20

이번 릴리즈는 DevIsland의 기능 확장 기반을 플러그인 아키텍처로 전환하고, 세션 타이머·통계·Pomodoro·세션 액션을 기본 플러그인으로 제공하는 대규모 업데이트입니다. Codex Desktop과 Antigravity 연동, 승인 IPC와 로그 보안 강화, 질문 미리보기와 세션 목록 개선도 함께 담았습니다.

### Highlights

- 플러그인 호스트, 권한, 이벤트, 저장소, 설정 스키마, UI contribution과 host command 기반을 추가했습니다.
- 세션 타이머, 세션 통계, Pomodoro, 세션 액션을 기본 플러그인으로 제공하고 Caffeine과 OpenPeon을 플러그인 구조로 이전했습니다.
- Codex Desktop과 Antigravity 세션을 감지하고 캐릭터, 터미널 포커스, hook 이벤트를 해당 환경에 맞게 처리합니다.
- Stable/Nightly 릴리즈 채널을 설정에서 선택할 수 있게 하고 채널별 업데이트 확인을 지원합니다.

### UI/UX

- 플러그인 활성화, safemode 복구와 플러그인별 옵션을 관리하는 설정 화면을 추가했습니다.
- Claude `AskUserQuestion` 선택지의 Markdown/HTML 미리보기를 스크롤 가능한 안전한 패널로 표시합니다.
- 세션 목록의 compact 행 레이아웃과 액션 배치를 다듬어 좁은 노치에서도 상태와 작업 경로를 더 안정적으로 확인할 수 있습니다.
- Caffeine 세션 유휴 타임아웃과 Session Timer 초 표시 옵션을 추가했습니다.

### Approval & Hooks

- TCP IPC를 loopback으로 제한하고 인증 envelope를 적용해 로컬 hook 요청의 출처 검증을 강화했습니다.
- 승인 규칙의 정규식 전체 일치와 deny 동작을 보강해 alternation 패턴에서도 의도한 정책 범위를 유지합니다.
- Antigravity의 Elicitation, UserPromptSubmit, PostToolUseFailure 등 provider 이벤트 처리를 보강했습니다.
- Gemini 통합이 비활성화된 경우 승인으로 간주하지 않고 provider 흐름에 맞는 pass 응답을 반환합니다.

### Stability & Security

- bridge 로그 권한을 소유자 전용으로 제한하고 민감한 payload 기록을 줄였으며 크기 기반 로그 순환을 추가했습니다.
- 세션 재개 명령과 작업 경로 인수를 안전하게 인용하고, 비어 있는 workspace root에는 복사 액션을 표시하지 않도록 했습니다.
- Caffeine 유휴 타이머의 오래된 callback을 무시하고 공통 RunLoop 모드와 실제 assertion 결과를 사용해 상태 표시를 안정화했습니다.
- 플러그인 dispatch, 저장소, scoped 파일 접근과 CESP pack scan에 권한·용량·경로 검증을 추가했습니다.

### Internal & CI

- hook 이벤트 분류, 승인 큐 정책과 countdown timer를 독립 컴포넌트로 분리하고 관련 회귀 테스트를 확충했습니다.
- 플러그인 아키텍처, Caffeine, hook provider와 보안 경계 문서를 현재 구현에 맞게 갱신했습니다.
- nightly 설정 기본값과 릴리즈 채널 판정을 실행 시점에 다시 읽도록 정리했습니다.

**Full Changelog**: https://github.com/nangchang/DevIsland/compare/v0.11.0...v0.12.0

## v0.11.0 - 2026-06-04

이번 릴리즈는 DevIsland가 작업 중 맥이 잠들지 않도록 돕는 Caffeine 기능을 추가하고, 설정 화면 구조와 애니메이션 제어를 정리한 기능 업데이트입니다. 릴리스/야간 빌드 안정성, 플러그인 아키텍처 문서, Claude Code용 에이전트 스킬도 함께 보강했습니다.

### Highlights

- Caffeine 자동 절전 방지 기능을 추가했습니다. 전원 연결 상태, 배터리 잔량, 특정 Wi-Fi(SSID) 예외 조건에 따라 절전 방지를 자동으로 켜고 끌 수 있습니다.
- 절전 방지가 실제로 활성화된 동안 메뉴바 아이콘이 파란색으로 표시되어 현재 상태를 더 쉽게 확인할 수 있습니다.
- 노치 펼침/접힘 애니메이션 속도를 설정에서 조절할 수 있게 했습니다.

### UI/UX

- 설정 창을 탭 기반 구조로 재구성하고 Extras 탭 기반을 추가해 새 보조 기능을 더 자연스럽게 배치할 수 있게 했습니다.
- Caffeine 설정 화면을 추가하고, 기능 기본값은 안전하게 꺼진 상태로 유지했습니다.
- Caffeine 활성화 안내 문구와 로컬라이즈된 설정 라벨을 다듬었습니다.

### Stability

- Caffeine 조건 판정과 절전 assertion 처리를 테스트로 보강하고, 실패 시 조용히 잘못된 상태로 남지 않도록 오류 분류와 상태 갱신을 정리했습니다.
- 애니메이션 속도가 0 이하로 설정될 때 발생할 수 있는 나눗셈 문제를 방지했습니다.
- SettingsStore의 새 설정값 저장과 기본값 동작을 검증했습니다.

### Internal & CI

- nightly DMG 빌드에서 테스트 실패가 가려지지 않도록 수정하고, 아키텍처 불일치 문제와 Homebrew 도구 캐시 복원 흐름을 안정화했습니다.
- 플러그인 아키텍처와 단계별 구현 계획 문서를 추가했습니다.
- DevIsland Codex 스킬을 Claude Code에서도 사용할 수 있도록 `.claude/skills`에 이식했습니다.

**Full Changelog**: https://github.com/nangchang/DevIsland/compare/v0.10.2...v0.11.0

## v0.10.2 - 2026-06-02

업데이트 알림 창의 릴리스 노트 표시를 개선하고, 시작 시 업데이트 확인 동작을 수정한 패치 업데이트입니다.

### UI/UX

- 업데이트 알림 창에서 GitHub 릴리스 노트의 줄 바꿈과 마크다운 포맷(굵게, 기울임, 코드 블록 등)이 올바르게 표시됩니다. 기존에는 단락이 한 줄로 붙어 보이는 문제가 있었습니다.

### 안정성

- 앱 시작 시 업데이트 확인이 `checkForUpdatesOnStartup` 설정을 올바르게 따르도록 수정했습니다.
- GitHub API rate limit 보호를 위해 시작 시 체크는 1시간 이내 중복 확인을 건너뜁니다.

**Full Changelog**: https://github.com/nangchang/DevIsland/compare/v0.10.1...v0.10.2

## v0.10.1 - 2026-06-02

이번 릴리즈는 노치 애니메이션 토글을 추가하고, `AppState`의 책임을 여러 서비스 레이어로 분리하는 리팩토링을 적용한 안정화 업데이트입니다.

### UI/UX

- 노치 펼침/접힘 애니메이션을 켜고 끌 수 있는 토글을 설정에 추가했습니다.
- 애니메이션이 꺼진 상태에서 윈도우 순서가 동기적으로 실행되도록 수정했습니다.

### 안정성

- `SessionMessageWindow`에서 빈 문자열일 때 `appState` 폴백 처리를 가드로 보호했습니다.
- `SessionMessageWindow`가 항상 세션 스토어에서 표시 데이터를 읽도록 수정했습니다.
- `ensureSelectedDisplay()`가 항상 메인 스레드에서 실행되도록 가드를 추가했습니다.

### 내부/CI

- `AppState`에서 `NotchDisplayPreferences`, `ApprovalRuleService`, `ClaudeQuestionState`, Phase 핸들러, `handleNotificationEvent`를 각각 독립 컴포넌트로 분리했습니다.
- `ApprovalRuleService`에서 사용되지 않는 `persistenceQueue`를 제거했습니다.
- `SettingsStore`의 `notchAnimationEnabled` 설정을 검증하는 테스트를 추가했습니다.
- DevIsland Codex 스킬과 release-packaging Claude 커맨드를 레포지토리에 추가했습니다.

**Full Changelog**: https://github.com/nangchang/DevIsland/compare/v0.10.0...v0.10.1

## v0.10.0 - 2026-05-31

이번 릴리즈는 세션을 앱 안팎에서 더 오래 이어갈 수 있도록 세션 기록과 팝아웃 메시지 창을 강화하고, 런치/업데이트 설정, VS Code/Claude Desktop 세션 감지, 노치 리사이즈와 포커스 안정성을 함께 다듬은 기능 확장 업데이트입니다.

### Highlights

- 종료된 세션 기록 창을 추가하고, 세션 경로 표시, Finder/터미널 열기, 재시작 명령 복사, 커스텀 세션 이름을 지원합니다.
- 세션별 팝아웃 메시지 창을 추가해 노치 밖에서도 메시지를 이어서 볼 수 있게 했습니다.
- 팝아웃 메시지 창 크기와 위치를 세션별로 저장하고, 메시지 기록 탐색을 지원합니다.
- VS Code와 Claude Desktop 세션 감지 및 표시를 추가하고, 기본 통합 설정은 꺼진 상태로 제공합니다.

### UI/UX

- 확장 노치 패널의 오른쪽/모서리 드래그 리사이즈 핸들을 추가했습니다.
- Dynamic Island shape 스타일 옵션과 업데이트 알림 안의 변경 로그 표시를 추가했습니다.
- 시작 시 업데이트 확인 토글과 로그인 시 자동 시작 토글을 설정에 추가했습니다.
- 세션 행의 앱 배지 위치와 캐릭터 정렬을 조정해 제목/메타 정보가 더 안정적으로 보이도록 했습니다.

### Stability

- 아일랜드 펼침과 접힌 패널 표시 중 다른 앱의 입력 포커스를 빼앗는 문제를 추가로 수정했습니다.
- 스페이스 전환이나 모달 표시 중 확장 패널이 사라지거나 다시 표시되는 흐름을 안정화했습니다.
- 종료 이벤트에 현재 작업 디렉터리가 없을 때 이전 이벤트 메타데이터를 사용하도록 보강했습니다.
- VS Code/Claude Desktop을 터미널 선택 후보에서 제외하고, 오래된 비터미널 선호값을 무시하도록 했습니다.

### Approval & Hooks

- 승인 거부 메시지 처리를 스레드 안전하게 정리했습니다.
- hook provider 문서에 VS Code/Claude Desktop 통합 구조를 보강했습니다.

### Internal & CI

- nightly build/pre-release workflow를 추가하고, tag protection ruleset을 우회하는 `nightly-*` 태그 패턴을 적용했습니다.
- 릴리즈 후 `main`을 다음 개발 버전으로 전환하는 bump workflow를 추가했습니다.
- PR에서 CodeQL 실행을 줄이고 main push와 스케줄 실행 중심으로 조정했습니다.
- 누락된 VS Code/Claude Desktop 설정과 Gemini auto-edit 관련 테스트를 보강했습니다.

**Full Changelog**: https://github.com/nangchang/DevIsland/compare/v0.9.3...v0.10.0

## v0.9.3 - 2026-05-28

이번 릴리즈는 알림과 세션 이벤트가 들어올 때 노치가 어떻게 펼쳐질지 더 세밀하게 제어할 수 있게 하고, 펼침 중 터미널 입력 포커스를 빼앗지 않도록 다듬은 UI/UX 안정화 업데이트입니다.

### UI/UX

- 이벤트 발생 시 노치를 자동으로 펼칠지 켜고 끌 수 있는 설정을 추가했습니다.
- 자동 펼침을 끈 상태에서도 접힌 아일랜드에 알림 dot을 표시해 새 활동을 놓치지 않도록 했습니다.
- 알림 dot 위치를 왼쪽, 가운데, 오른쪽 중에서 선택할 수 있게 했습니다.
- 알림 자동 펼침과 트리거별 자동 펼침 설정을 분리해 상황별로 더 세밀하게 조정할 수 있게 했습니다.

### Stability

- 아일랜드가 펼쳐질 때 `NSApp.activate`로 인해 터미널 입력 포커스를 빼앗는 문제를 수정했습니다.
- 알림 자동 펼침을 끈 상태에서 포커스된 터미널 세션의 unread 상태가 해제되지 않던 문제를 수정했습니다.

### Internal

- 알림 설정 접근 경로를 `MainActor.assumeIsolated` 기반으로 정리했습니다.
- 자동 펼침 설정의 기본값과 저장 동작을 검증하는 설정 저장소 테스트를 보강했습니다.

**Full Changelog**: https://github.com/nangchang/DevIsland/compare/v0.9.2...v0.9.3

## v0.9.2 - 2026-05-27

이번 릴리즈는 확장 노치의 최소 너비를 안정적인 값으로 조정하고, 설정 슬라이더 값을 더 정밀하게 입력할 수 있게 한 UI/UX 패치입니다.

### UI/UX

- 확장 윈도우 너비 최소값을 610px로 올려 좁은 설정에서 확장 영역 UI가 패널 밖으로 벗어날 수 있는 문제를 막았습니다.
- 노치 표시 설정 슬라이더 옆에 숫자 직접 입력 필드를 추가해 픽셀 단위 값을 더 쉽게 맞출 수 있게 했습니다.
- 숫자 입력 필드가 설정 범위와 step을 동일하게 따르도록 정규화하고, 접근성 레이블을 추가했습니다.

### Internal

- 확장 윈도우 너비 최소값의 아래/경계/초과 케이스를 검증하는 설정 저장소 테스트를 보강했습니다.

**Full Changelog**: https://github.com/nangchang/DevIsland/compare/v0.9.1...v0.9.2

## v0.9.1 - 2026-05-26

이번 릴리즈는 Claude 질문과 승인 요청이 겹칠 때의 표시 우선순위를 정리하고, 릴리스 노트 자동화와 개발 워크플로 문서를 보강한 안정화 업데이트입니다.

### Approval & Hook Improvements

- 승인 요청이 알림/Claude 질문보다 먼저 표시되도록 했습니다.
- 승인 요청끼리, 알림/Claude 질문끼리는 각각 수신 순서대로 처리되도록 했습니다.
- Claude 질문이 승인 요청에 의해 잠시 밀려나도 작성 중인 답변이 유지되도록 했습니다.
- 터미널이 이미 포커스된 상태의 Claude 질문은 터미널 흐름을 방해하지 않도록 pass 상태와 큐 상태를 정리했습니다.

### Documentation & Workflow

- DevIsland 개발용 Claude slash command 문서를 추가했습니다.
- README와 CONTRIBUTING 문서를 최신 개발 흐름에 맞게 정리했습니다.
- AI attribution 가이드와 릴리스 문서 내용을 보강했습니다.

### Internal & CI

- GitHub Release 본문이 `CHANGELOG.md`의 해당 버전 섹션을 사용하도록 자동화했습니다.
- 릴리스 노트 추출 스크립트의 실패 처리를 강화했습니다.
- 빌드 검증 스크립트가 `xcodebuild` 실패를 놓치지 않도록 `pipefail`을 적용했습니다.

**Full Changelog**: https://github.com/nangchang/DevIsland/compare/v0.9.0...v0.9.1

## v0.9.0 - 2026-05-24

이번 릴리즈는 세션 흐름을 더 잘 따라갈 수 있도록 활동 목록과 에이전트 메시지 표시를 강화하고, 승인 규칙과 노치 UI의 안정성을 크게 다듬은 업데이트입니다.

### Highlights

- 세션 목록에 읽지 않은 활동 표시, 상세 보기, 뒤로 가기, SQLite 기반 복원을 추가했습니다.
- Claude/Codex/Gemini 훅으로 전달되는 에이전트 메시지를 앱 안에서 더 자연스럽게 표시합니다.
- 하위 에이전트 세션을 부모 세션과 연결해 그룹으로 추적하고 표시합니다.
- Claude 질문 응답 UI를 추가했습니다.
- 에이전트 메시지의 Markdown 렌더링과 edit/replace 도구 diff 표시를 개선했습니다.
- 접힌 노치 중앙 텍스트를 설정할 수 있게 했습니다.

### Approval & Hook Improvements

- ApprovalPolicyEngine에 엄격한 우선순위와 깊은 `toolInput` 매칭을 추가했습니다.
- 기본 허용 규칙을 스키마 마이그레이션으로 시드합니다.
- 패턴 기반 승인 규칙이 전역 도구 캐시에 잘못 들어가지 않도록 수정했습니다.
- Codex 승인/중지 훅 메시지 포맷을 정리했습니다.
- 놓친 승인 요청을 세션 목록에서 확인할 수 있게 했습니다.

### Stability & UX Fixes

- private KVC 기반 노치 감지를 public `NSScreen` API로 교체했습니다.
- 시작 실패 시 서버 오류를 전달하고 Retry 대화상자를 표시합니다.
- 최종 인앱 알림을 닫은 뒤 노치가 정상적으로 접히도록 수정했습니다.
- 모달 알림이 노치 패널에 가려지지 않도록 했습니다.
- 사용자가 상호작용 중일 때 노치 타이머를 일시 중지합니다.
- 터미널 선택 후 cmux 포커스를 복원합니다.

### Internal & CI

- `AppState`에서 `HookEventHandler`를 분리해 이벤트 처리 구조를 정리했습니다.
- Swift CodeQL 워크플로 속도와 빌드 안정성을 개선했습니다.
- `project.yml`에 `SWIFT_VERSION`을 추가해 CodeQL 빌드 실패를 수정했습니다.
- 아키텍처 문서와 Known Gaps 문서를 현재 구현 상태에 맞게 정리했습니다.

**Full Changelog**: https://github.com/nangchang/DevIsland/compare/v0.8.3...v0.9.0
