# CLAUDE.md

This file provides Claude Code–specific guidance for this repository.
For general project documentation (architecture, build, key files), see [AGENTS.md](AGENTS.md).

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

## PR Review

인라인 리뷰 코멘트는 `gh api repos/nangchang/DevIsland/pulls/{n}/reviews` POST로 작성.
`position`은 diff 파일 내 1-indexed 줄 번호 (헝크 헤더 포함). `REQUEST_CHANGES`는 본인 PR에 불가 — `COMMENT` 사용.

```bash
# PR 브랜치 체크아웃
gh pr view {n} --repo nangchang/DevIsland --json headRefName -q .headRefName
git fetch origin pull/{n}/head:{local-branch} && git checkout {local-branch}

# diff position 번호 확인
gh api "repos/nangchang/DevIsland/pulls/{n}/files" --jq '.[] | select(.filename=="path/to/file") | .patch'
```

## Bridge Path

브리지 스크립트 설치 위치: `~/Library/Application Support/DevIsland/devisland-bridge.sh`
경로에 공백이 있으므로 hook command 문자열 생성 시 경로를 따옴표로 감싸야 함: `"<path>" --source claude`

## Swift SourceKit 진단 오류

단일 파일 편집 시 "Cannot find 'AppState' in scope" 류의 오류는 cross-file 참조로 인한 것 — 빌드 오류 아님, 무시해도 됨.
