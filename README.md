# DevIsland

**DevIsland**는 macOS 노치 영역에 Claude Code, Codex CLI, Gemini CLI의 활동과 승인 요청을 실시간으로 띄워 주는 오픈소스 메뉴바 앱입니다. CLI 훅 이벤트를 받아 세션 상태를 추적하고, 필요한 승인/거부 결정을 Dynamic Island 스타일 패널에서 빠르게 처리할 수 있게 합니다.

![DevIsland Showcase](https://raw.githubusercontent.com/nangchang/DevIsland/main/Assets/showcase.png)

## 주요 기능

- **노치 오버레이 UI**: 평상시에는 노치 뒤에 숨어 있다가 에이전트 활동이나 승인 요청이 들어오면 확장됩니다.
- **실시간 세션 모니터링**: Claude, Codex, Gemini 세션의 활동, 읽지 않은 이벤트, 승인 상태를 추적합니다.
- **승인 프록시**: 위험도가 있는 도구 실행은 앱에서 승인/거부하고, 허용 규칙은 SQLite에 저장해 재사용합니다.
- **에이전트 메시지 표시**: 훅으로 전달된 메시지와 Markdown, edit/replace diff를 앱 안에서 읽기 쉽게 보여줍니다.
- **하위 에이전트 그룹화**: sub-agent 세션을 부모 세션 아래에 묶어 흐름을 따라가기 쉽게 합니다.
- **터미널 포커스 복원**: 터미널 확인이 필요한 작업은 알림으로 안내하고, 선택 후 원래 터미널 흐름으로 돌아갑니다.
- **OpenPeon CESP 사운드팩**: 승인 요청, 작업 완료, 오류, 리소스 제한 같은 hook 이벤트에 오디오 피드백을 매핑할 수 있습니다.

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
launchctl unload "$PLIST" && rm "$PLIST"
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
