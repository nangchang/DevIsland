# CLAUDE.md

This file provides Claude Code–specific guidance for this repository.
For general project documentation (architecture, build, key files), see [AGENTS.md](AGENTS.md).

## AI Attribution

커밋, GitHub 코멘트, 이슈 등 AI가 작성한 내용에는 반드시 출처를 표시한다.

**커밋 트레일러** (커밋 메시지 마지막 줄):
```
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

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

## Bridge Path

브리지 스크립트 설치 위치: `~/Library/Application Support/DevIsland/devisland-bridge.sh`
경로에 공백이 있으므로 hook command 문자열 생성 시 경로를 따옴표로 감싸야 함: `"<path>" --source claude`

## ProviderAdapter ↔ Python 브리지 계약

Swift `ProviderAdapter`가 빈 dict `[:]`를 반환하면 IPC 응답에 `providerOutput: {}`로 인코딩된다.
Python 브리지에서 `obj.get("providerOutput") or None` 처리 시 빈 dict는 falsy → `None`이 되어
`final_output`의 fallback 로직이 실행된다. Swift 응답 형식을 바꿀 때 `devisland_bridge.py`의
`final_output` 함수도 같이 확인할 것.

## Swift SourceKit 진단 오류

`xcode-build-server`를 설정하면 cross-file 참조 오류가 사라진다 (AGENTS.md "One-Time Local Setup" 참고). 설정 전이거나 DerivedData 초기화 후에는 "Cannot find 'AppState' in scope" 류의 오류가 표시될 수 있으나 빌드 오류가 아님 — `xcodebuild build`로 실제 오류 여부 확인.
