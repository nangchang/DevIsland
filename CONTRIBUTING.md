# Contributing

DevIsland에 관심을 가져 주셔서 감사합니다. 이 문서는 버그 제보, 기능 제안, Pull Request를 준비할 때 필요한 기본 흐름을 정리합니다.

## 개발 환경 준비

DevIsland는 macOS 앱이며 Xcode 프로젝트는 XcodeGen으로 생성합니다.

```bash
brew install xcodegen
xcodegen generate
open DevIsland.xcodeproj
```

SourceKit-LSP가 전체 프로젝트 컨텍스트를 읽도록 하려면 선택적으로 `xcode-build-server`를 설정할 수 있습니다.

```bash
brew install xcode-build-server
xcode-build-server config -scheme DevIsland -project DevIsland.xcodeproj
```

## 작업 흐름

1. 이슈나 변경 목적을 명확히 합니다.
2. `main`이 아닌 별도 브랜치에서 작업합니다.
3. 변경 범위를 작게 유지합니다.
4. 코드, 설정, 명령, 사용자 흐름이 바뀌면 관련 문서를 함께 업데이트합니다.
5. Pull Request에는 무엇을 바꿨는지보다 왜 바꿨는지를 분명히 적습니다.

## 테스트

코드 변경 전후로 기존 테스트를 통과시키는 것을 기본 원칙으로 합니다.

```bash
./scripts/run-tests.sh
```

현재 실행 중인 DevIsland 앱을 종료하지 않고 빌드만 확인하려면 다음 명령을 사용할 수 있습니다.

```bash
./scripts/build_and_run.sh --no-kill --no-run
```

`project.yml`을 수정했다면 Xcode 프로젝트를 다시 생성하세요.

```bash
xcodegen generate
```

## 코드 변경 원칙

- 브릿지 스크립트는 얇게 유지합니다. stdin payload 수신, 메타데이터 보강, IPC 전달, provider별 응답 출력만 담당해야 합니다.
- DB 접근, 정책 평가, UI 렌더링, pack 로딩, 오디오 재생 같은 작업은 앱 쪽에 둡니다.
- UI와 hook 응답 경로에서 무거운 작업을 동기적으로 실행하지 않습니다.
- Claude, Codex, Gemini의 provider별 hook 의미와 응답 형식을 보존합니다.
- 생성된 `.xcodeproj`는 직접 수정하지 말고 `project.yml`을 수정한 뒤 재생성합니다.

## 커밋 메시지

커밋 제목은 영어 Conventional Commits 형식을 사용합니다.

```text
feat: add session unread indicators
fix: prevent patterned rules from entering global cache
docs: refresh README
```

커밋 본문에는 변경 이유와 의사결정 배경을 한국어로 적어 주세요. 한 커밋에는 하나의 논리적 변경만 담는 것을 권장합니다. AI 도구를 사용해 커밋을 작성했다면 커밋 메시지 마지막에 `Co-Authored-By:` 트레일러를 추가하고, GitHub PR, 이슈, 코멘트 작성에 AI 도구를 사용했다면 본문 마지막에 어떤 도구 또는 모델로 생성했는지 알 수 있는 footer를 포함해 주세요.

## Pull Request 체크리스트

- 변경 범위가 요청한 문제에 직접 연결되어 있나요?
- `./scripts/run-tests.sh`를 실행했나요?
- `project.yml` 변경 후 `xcodegen generate`를 실행했나요?
- 사용자-facing 동작, 설정, 명령이 바뀌었다면 README 또는 `docs/agent/*`를 업데이트했나요?
- 릴리즈에 포함될 사용자-visible 변경이라면 `CHANGELOG.md`를 업데이트했나요? 릴리즈 워크플로우는 해당 버전 섹션을 GitHub Release 본문으로 사용합니다.

## 참고 문서

- [Build and test](docs/agent/build-and-test.md)
- [Hook providers](docs/agent/hook-providers.md)
- [Approval proxy](docs/agent/approval-proxy.md)
- [UI customization](docs/agent/ui-customization.md)
- [OpenPeon CESP](docs/agent/openpeon-cesp.md)
- [Stability standards](docs/agent/stability-standards.md)
