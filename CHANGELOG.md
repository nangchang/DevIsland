# Changelog

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
