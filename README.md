# DevIsland

**DevIsland**는 macOS 노치 영역에 Claude Code, Codex CLI, Gemini CLI의 활동과 승인 요청을 실시간으로 띄워 주는 오픈소스 메뉴바 앱입니다. CLI 훅 이벤트를 받아 세션 상태를 추적하고, 필요한 승인/거부 결정을 Dynamic Island 스타일 패널에서 빠르게 처리할 수 있게 합니다.

## 주요 기능

- **노치 오버레이 UI**: 평상시에는 노치 뒤에 숨어 있다가 에이전트 활동이나 승인 요청이 들어오면 확장됩니다.
- **실시간 세션 모니터링**: Claude, Codex, Gemini 세션의 활동, 읽지 않은 이벤트, 승인 상태를 추적합니다.
- **승인 프록시**: 위험도가 있는 도구 실행은 앱에서 승인/거부하고, 허용 규칙은 SQLite에 저장해 재사용합니다.
- **에이전트 메시지 표시**: 훅으로 전달된 메시지와 Markdown, edit/replace diff를 앱 안에서 읽기 쉽게 보여줍니다.
- **하위 에이전트 그룹화**: sub-agent 세션을 부모 세션 아래에 묶어 흐름을 따라가기 쉽게 합니다.
- **터미널 포커스 복원**: 터미널 확인이 필요한 작업은 알림으로 안내하고, 선택 후 원래 터미널 흐름으로 돌아갑니다.
- **OpenPeon CESP 사운드팩**: 승인 요청, 작업 완료, 오류, 리소스 제한 같은 hook 이벤트에 오디오 피드백을 매핑할 수 있습니다.

## OpenAI Build Week 2026 작업 기준

- 구현 착수 시각: 2026-07-16 04:40 KST
- Fleet Radar 구현 전 기준: `1fc23ce` (`v0.14.1-dev`). 위의 기존 DevIsland 기능은 이 기준에 포함됩니다.
- Fleet Radar 구현 시작점: `ab847ba`. Fleet 탭, 로컬 Git worktree 상태, 변경 경로 중첩 분석,
  attention ranking과 관련 테스트·문서를 Build Week 신규 범위로 구분합니다. 상세 범위는
  [Fleet Radar 구현 계획](docs/agent/fleet-radar-implementation-plan.md)에 고정되어 있습니다.

## What was built during Build Week

DevIsland now includes **Fleet Radar**, a local-first dashboard for deciding which active coding
agent needs attention and spotting when parallel Git worktrees are modifying the same paths.
Choose **Session Center…** from the menu bar app and select the default **Fleet** tab; the existing
**Sessions** and **Insights** tabs remain available in the same standard macOS window.

| Before Build Week (`1fc23ce`) | Added during Build Week |
|---|---|
| Notch activity and approval UI | Attention-ranked cards for active parent sessions |
| Session tracking and sub-agent relationships | Sub-agents nested under their parent Fleet card |
| Session History and Insights | Session Center with Fleet, Sessions, and Insights tabs |
| Workspace paths attached to sessions | Read-only branch, detached HEAD, clean/dirty, and unmerged status |
| Explicit terminal focus and session detail actions | Separate Show Detail and Focus Terminal actions on each card |
| No cross-worktree Git analysis | Same-repository, different-worktree changed-path overlap warnings |

The overlap badge is an early warning, **not merge-conflict detection**. It compares changed paths
only when active worktrees share a repository identity and have different worktree roots. Scanning
uses bounded `/usr/bin/git` reads behind an actor cache. Fleet performs no Git writes, network
requests, automatic agent orchestration, or background polling; ahead/behind, pull request, and CI
status are intentionally outside this MVP.

### Codex workflow and submission evidence

Codex was used to turn the implementation plan into staged, testable work. Each stage was
implemented in a separate Codex sub-task, reviewed from correctness, concurrency, UX, localization,
regression, privacy, and packaging angles, then verified and committed before the next stage. The
parser, scanner/cache, overlap analyzer, view model, SwiftUI dashboard, Session Center lifecycle,
and English/Korean catalog all have automated coverage.

The following external submission values are not available in this checkout. They are explicit
Stage 10/submission blockers and must be completed before publishing the Build Week entry; the
placeholders remain so no false identifiers or broken media links are published:

- [ ] Use `/feedback` to capture the core Codex task's Session ID and independently confirm its model
  provenance. Only then add the submission statement that GPT-5.6 was used for design,
  implementation, and verification; this checkout does not expose enough provenance to assert it.
- [ ] Insert the final public demo GIF or screenshot here after the asset is captured and committed.
- [ ] Add the public video and downloadable-build URLs after upload; do not replace these items with
  private or temporary links.

### Install the Build Week DMG (macOS 15+)

The locally generated, checksum-verified handoff artifact is
`DevIsland-0.14.1-dev-arm64.dmg`. It is an arm64 development build with an ad-hoc signature but no
Developer ID signature or notarization, and is intentionally ignored by Git. Launch on a separate
clean Mac has not yet been verified.

1. Open the DMG and drag `DevIsland.app` to `/Applications`.
2. Try to open `/Applications/DevIsland.app` once and let macOS block the unnotarized app.
3. Choose **Apple menu > System Settings > Privacy & Security**. In the **Security** section, select
   **Open Anyway** for DevIsland. This option is available for about one hour after the blocked
   launch attempt.
4. Authenticate when prompted, then confirm **Open**. See
   [Apple's official external guide to overriding app security settings](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac).
5. Open **Settings** to choose the language and other preferences, install the desired provider
   bridge from the menu bar app's hook-install actions, then choose **Session Center…**.

To reproduce the DMG from source (requires Xcode 16+, XcodeGen, and `create-dmg`):

```bash
brew install xcodegen create-dmg
./scripts/create-dmg.sh
```

On the Build Week verification Mac, repeated official packaging attempts—including a run with GUI
automation privileges—completed the Release archive, but Finder automation was unavailable while
`create-dmg` applied its window layout:

```text
execution error: Finder에 오류 발생: AppleEvent 시간이 초과되었습니다. (-1712)
Failed running AppleScript
```

If that environment-specific error recurs, `scripts/create-dmg.sh` now cleans the partial output and
automatically retries the same official `create-dmg` flow with `--skip-jenkins`, then requires
`hdiutil verify` to pass. The fallback skips Finder's custom icon positions and window layout, but
the resulting read-only DMG remains installable and contains both `DevIsland.app` and the
Applications link.

To build and test without launching or terminating a running DevIsland instance:

```bash
./scripts/run-tests.sh
./scripts/build_and_run.sh --no-kill --no-run
```

### Reproduce the worktree-overlap demo

Use the fixed English [Fleet Radar Build Week demo runbook](docs/agent/fleet-radar-demo.md). It
defines three exact branch, worktree, file, and session-label fixtures; the pending-approval cue;
the Detail-versus-Focus sequence; and complete cleanup commands. The overlap analysis stays local
and does not modify any repository.

## 작동 방식

DevIsland는 별도 백그라운드 daemon 없이 macOS 앱 안에서 승인 프록시와 UI를 함께 실행합니다.

```text
CLI Hook
  -> devisland-bridge.sh
    -> HookSocketServer
      -> ApprovalProxyController
        -> ApprovalPolicyEngine
        -> ProviderAdapter
        -> UI decision when needed
      -> bridge response
```

- 브릿지는 stdin payload를 보강하고 앱으로 전달하는 얇은 레이어입니다.
- 앱은 정책 평가, 세션 캐시, UI 결정, provider별 응답 JSON 생성을 담당합니다.
- 규칙, 세션 캐시, 이벤트 로그, 승인 결정, PTY 메시지는 `~/Library/Application Support/DevIsland/approval-proxy.sqlite3`에 저장됩니다.

더 자세한 구조는 [docs/agent/approval-proxy.md](docs/agent/approval-proxy.md)를 참고하세요.

## 시작하기

### 1. 프로젝트 생성 및 실행

DevIsland는 [XcodeGen](https://github.com/yonaskolb/XcodeGen)으로 Xcode 프로젝트를 생성합니다.

```bash
brew install xcodegen
xcodegen generate
open DevIsland.xcodeproj
```

Xcode 없이 빠르게 빌드만 확인하려면 다음 스크립트를 사용할 수 있습니다.

```bash
./scripts/build_and_run.sh --no-kill --no-run
```

### 2. 브릿지 설치

터미널에서 실행되는 AI 에이전트의 훅 이벤트를 DevIsland 앱으로 전달하려면 브릿지를 설치해야 합니다.

```bash
# 지원되는 모든 CLI에 설치
./scripts/install-bridge.sh --all

# 필요한 CLI만 선택 설치
./scripts/install-bridge.sh --claude
./scripts/install-bridge.sh --codex
./scripts/install-bridge.sh --gemini
```

브릿지 설치와 provider별 응답 형식은 [docs/agent/hook-providers.md](docs/agent/hook-providers.md)에 정리되어 있습니다.

Codex Auto-review가 승인을 담당하도록 실행하면서 DevIsland의 세션/상태 추적을 유지하려면
설치된 래퍼에 Auto-review 프로필을 전달합니다.

```bash
"$HOME/Library/Application Support/DevIsland/codex-devisland-auto" --profile auto-review
```

이 실행 경로에서는 Codex `PermissionRequest`만 Codex에 pass-through하며, lifecycle 훅은
계속 DevIsland로 전달됩니다. 자주 사용한다면 위 명령을 셸 alias로 등록할 수 있습니다.

### 3. 테스트

기존 앱 인스턴스를 방해하지 않는 격리 모드 테스트 스크립트를 사용하세요.

```bash
./scripts/run-tests.sh
```

빌드와 테스트 흐름은 [docs/agent/build-and-test.md](docs/agent/build-and-test.md)를 참고하세요.

## 설정

### Claude 승인 모드

Settings > Providers > Claude Code에서 Claude 승인 처리를 선택할 수 있습니다.

- **Native**: Claude 내부 rule을 사용합니다.
- **App cache**: DevIsland SQLite 승인 캐시를 사용합니다.
- **Hybrid**: Claude 내부 rule과 DevIsland 캐시를 함께 사용합니다.

### Gemini CLI

Gemini CLI를 `--yolo` 또는 `--auto-approve` 모드로 실행한 뒤 DevIsland에서 일반 모드 에뮬레이션을 켜면 터미널 프롬프트 대신 DevIsland 승인 UI를 사용할 수 있습니다. 파일 읽기 같은 조회성 작업은 safe tool 자동 승인으로 노치 방해를 줄일 수 있습니다.

### 로그인 시 자동 시작

앱을 `/Applications/DevIsland.app`에 복사한 뒤 LaunchAgent를 설치하면 로그인할 때 자동으로 실행됩니다.

```bash
./scripts/install-launch-agent.sh
```

제거하려면 다음 명령을 사용합니다.

```bash
PLIST=~/Library/LaunchAgents/kr.or.nes.DevIsland.plist
launchctl unload "$PLIST" 2>/dev/null; rm -f "$PLIST"
```

### OpenPeon CESP 사운드팩

DevIsland는 [OpenPeon CESP](https://openpeon.com/spec) v1.0 형식의 사운드팩을 읽어 hook 이벤트에 오디오 피드백을 추가할 수 있습니다. 기본 pack 경로는 `~/.openpeon/packs`입니다.

```text
~/.openpeon/packs/
  sample-pack/
    openpeon.json
    sounds/
      approval.mp3
      done.wav
```

지원되는 주요 카테고리는 `session.start`, `task.acknowledge`, `task.complete`, `task.error`, `input.required`, `resource.limit`, `session.end`, `task.progress`, `user.spam`입니다. 자세한 내용은 [docs/agent/openpeon-cesp.md](docs/agent/openpeon-cesp.md)를 참고하세요.

## 문제 해결

### Claude Code의 `auto` 모드에서 요청이 거부되는 경우

Claude Code의 `auto` 모드는 DevIsland 브릿지 호출 전에 일부 작업을 Claude 자체 보안 정책으로 차단할 수 있습니다. 이 경우 노치 승인 UI가 뜨지 않고 `Denied by auto-mode classifier` 메시지가 표시됩니다.

해당 작업은 `auto` 모드가 아닌 interactive 모드에서 실행하세요. interactive 모드에서는 DevIsland를 통해 직접 승인할 수 있습니다.

## 개발과 기여

- 변경 내역은 [CHANGELOG.md](CHANGELOG.md)를 참고하세요.
- 기여 절차와 개발 규칙은 [CONTRIBUTING.md](CONTRIBUTING.md)에 정리되어 있습니다.
- 에이전트 작업 지침은 [AGENTS.md](AGENTS.md)를 참고하세요.

## 라이선스

DevIsland는 MIT 라이선스로 배포됩니다.

---

Created by [nangchang](https://github.com/nangchang)
