# CLAUDE.md

This file provides Claude Code–specific guidance for this repository.
For general project documentation (architecture, build, key files), see [AGENTS.md](AGENTS.md).

## 커밋 메시지 및 AI Attribution

커밋 바디는 한국어로 작성하고 변경 이유(Why)에 집중할 것.
제목(첫 줄)은 영어 conventional commit 형식 유지.

커밋, GitHub 코멘트, 이슈 등 AI가 작성한 내용에는 반드시 출처를 표시한다.

**커밋 트레일러** (커밋 메시지 마지막 줄, 실제 사용 모델 버전 기입):
```
Co-Authored-By: Claude <모델-버전> <noreply@anthropic.com>
```
예: `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`

**GitHub 코멘트·이슈 푸터** (본문 마지막 줄):
```
> 🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## Bridge Installation

The bridge connects Claude Code hooks to the app:

```bash
# Install bridge + patch ~/.claude/settings.json
bash scripts/install-bridge.sh

# Optional: register as LaunchAgent (auto-start on login)
bash scripts/install-launch-agent.sh
```

`install-bridge.sh` hard-codes `/Volumes/data/Github/DevIsland/scripts` as the source path — update this if working from a different clone location.

Bridge logs are written to `/tmp/DevIsland.bridge.log`. The app logs to `/tmp/DevIsland.log` and `/tmp/DevIsland.error.log` when running as a LaunchAgent.

```bash
# 브리지 로그 실시간 확인
tail -f /tmp/DevIsland.bridge.log
```

## PR Review

인라인 리뷰 코멘트는 `gh api repos/nangchang/DevIsland/pulls/<PR_NUMBER>/reviews` POST로 작성.
`position`은 diff 파일 내 1-indexed 줄 번호 (헝크 헤더 포함). `REQUEST_CHANGES`는 본인 PR에 불가 — `COMMENT` 사용.

```bash
# 인라인 코멘트 reply (PR 번호 포함 필수 — 없으면 404)
gh api "repos/nangchang/DevIsland/pulls/<PR_NUMBER>/comments/<COMMENT_ID>/replies" \
  --method POST --field body="..."

# PR 브랜치 체크아웃
gh pr view <PR_NUMBER> --repo nangchang/DevIsland --json headRefName -q .headRefName
git fetch origin pull/<PR_NUMBER>/head:<local-branch> && git checkout <local-branch>

# diff position 번호 확인
gh api "repos/nangchang/DevIsland/pulls/<PR_NUMBER>/files" --jq '.[] | select(.filename=="path/to/file") | .patch'

# PR 코멘트 전체 조회 (인라인 + 일반 + 리뷰 요약 모두 확인 필요)
gh api "repos/nangchang/DevIsland/pulls/<PR_NUMBER>/comments" --jq '.[] | "[inline] \(.user.login) \(.path):\(.line // "?") — \(.body)"'
gh api "repos/nangchang/DevIsland/issues/<PR_NUMBER>/comments" --jq '.[] | "[comment] \(.user.login): \(.body)"'
gh api "repos/nangchang/DevIsland/pulls/<PR_NUMBER>/reviews" --jq '.[] | "[review] \(.user.login) (\(.state)): \(.body)"'
```

리뷰 스레드 resolve는 REST API 미지원 — GraphQL 사용:
```bash
# 스레드 ID 조회
gh api graphql -f query='{ repository(owner:"nangchang",name:"DevIsland") { pullRequest(number:N) { reviewThreads(first:20) { nodes { id isResolved comments(first:1) { nodes { databaseId } } } } } } }'
# resolve
gh api graphql -f query='mutation { resolveReviewThread(input:{threadId:"PRRT_..."}) { thread { isResolved } } }'
```

## Bridge Path

브리지 스크립트 설치 위치: `~/Library/Application Support/DevIsland/devisland-bridge.sh`
경로에 공백이 있으므로 hook command 문자열 생성 시 경로를 따옴표로 감싸야 함: `"<path>" --source claude`

## ProviderAdapter ↔ Python 브리지 계약

Swift `ProviderAdapter`가 빈 dict `[:]`를 반환하면 IPC 응답에 `providerOutput: {}`로 인코딩된다.
Python 브리지에서 `obj.get("providerOutput") or None` 처리 시 빈 dict는 falsy → `None`이 되어
`final_output`의 fallback 로직이 실행된다. Swift 응답 형식을 바꿀 때 `devisland_bridge.py`의
`final_output` 함수도 같이 확인할 것.

## 브랜치 규칙

모든 작업(기능, 버그 수정, 문서, 설정 변경 포함)은 반드시 별도 브랜치를 만들어 PR로 작업한다.
main에 직접 커밋하지 말 것 — 예외 없음.

## Xcode Project

`*.xcodeproj`는 gitignore 대상 — CI와 로컬 모두 XcodeGen으로 생성함.
빌드 설정 변경은 `project.yml`에서 하고 `xcodegen generate`로 재생성.

새 Swift 파일 추가 시 `project.pbxproj` 수동 편집 금지. `project.yml`의
`sources: path: DevIsland`가 하위 디렉토리를 재귀 포함하므로
파일 생성 후 `xcodegen generate`만 실행하면 됨.

빌드 결과 확인: 종료 코드(`$?`)가 가장 정확함. grep 사용 시 `BUILD SUCCEEDED` / `BUILD FAILED` (대문자, `-quiet` 시 출력 없음).

## 워크트리 빌드

git worktree에는 `*.xcodeproj`가 없으므로 빌드 전 `xcodegen generate`로 생성 필요.
메인 프로젝트의 xcodeproj로 빌드하면 워크트리 변경이 반영되지 않음.

```bash
xcodegen generate  # 워크트리 루트에서
xcodebuild build -scheme DevIsland -quiet -project "$(pwd)/DevIsland.xcodeproj"
```

앱 실행 시에도 이 워크트리 DerivedData 경로의 .app을 사용할 것.

`./scripts/run-tests.sh`는 별도 DerivedData(`/tmp/DevIsland-Test-DerivedData`)를 쓴다.
"Could not resolve package dependencies"가 나면 `rm -rf /tmp/DevIsland-Test-DerivedData/SourcePackages`
후 재실행. `-quiet`라 테스트 수는 안 보이고 성공 시 마지막 줄에 "✅ All tests passed!" —
`grep -c`로 확인(exit 0이어도 "Could not resolve"면 테스트 미실행).

## Swift SourceKit 진단 오류

`xcode-build-server`를 설정하면 cross-file 참조 오류가 사라진다 (AGENTS.md "One-Time Local Setup" 참고). 설정 전이거나 DerivedData 초기화 후에는 "Cannot find 'AppState' in scope" 류의 오류가 표시될 수 있으나 빌드 오류가 아님 — `xcodebuild build`로 실제 오류 여부 확인.

## 노치 윈도우 UI 패턴

노치 윈도우는 포커스를 잃으면 자동으로 닫힌다. 노치 컨텍스트 메뉴에서 NSAlert를
띄우면 윈도우가 즉시 사라진다 — 항상 인라인 SwiftUI TextField를 사용할 것.
`@FocusState` + `onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }`
패턴으로 컨텍스트 메뉴 닫힌 뒤 포커스를 강제 설정한다.

## 커밋 원자성

각 커밋은 하나의 논리적 변경만 담을 것. 여러 파일에 걸쳐 있어도
같은 목적이면 한 커밋 — 다른 목적이면 반드시 분리.
여러 변경을 묶어 커밋했다가 분리 요청 받으면:
`git reset --soft HEAD~1 && git restore --staged .` — 워킹 트리는 그대로이므로
파일 단위로 스테이징해 순서대로 재커밋. 같은 파일에 여러 변경이 섞인 경우도
soft reset 후 Edit으로 하나씩 적용하고 커밋하면 된다.

## git commit 멀티라인 메시지

`git commit -m "$(cat <<'EOF' ... EOF)"` 형식은 hook에 막힐 수 있다.
`/tmp/commit_msg.txt` 생성 후 `git commit -F /tmp/commit_msg.txt` 사용.
`Write` 툴은 새 파일도 Read 선행이 필요하므로 임시 파일엔 Bash `cat > /tmp/commit_msg.txt << 'EOF' ... EOF` 방식 사용.

`git add ... && git commit`, `git commit ... && git push` 같은 `&&` git 명령 체인도
PreToolUse hook에 막힐 수 있다 — git 명령은 단독으로 실행할 것.

## 플러그인 작업 주의점 (host command·UI 기여)

플러그인이 보는 session/hook 데이터는 `PluginEventFactory.redactedSession`을 거친다:
`.readTerminalMetadata`가 없으면 `workspaceRoot`(와 cwd/terminalApp)가 `nil`이 된다.
`session.workspaceRoot`를 쓰는 plugin은 `.readTerminalMetadata`를 선언해야 한다.

host command의 부수효과는 observer로 우회될 수 있다. 터미널을 frontmost로 만들면
`NotchWindowController`의 앱 활성화/클릭 observer가 `passIfTerminalFocused()`를 호출해
표시 중인 approval을 terminal로 pass시킨다. 직접 호출하지 않아도 영향을 주므로,
approval/notification 표시 중엔 동작을 거부할 것(`AppState.canPluginFocusTerminal` 참고).
