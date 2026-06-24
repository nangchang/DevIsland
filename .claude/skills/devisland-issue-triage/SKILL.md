---
name: devisland-issue-triage
description: DevIsland 오픈 이슈를 스캔하고, 트리아지 댓글을 남긴 뒤 중요도가 충분한 이슈만 워크트리 Agent로 구현합니다.
---

Review open issues, leave a triage comment on each, and only implement those that clear the importance threshold.

## Step 1: Scan issues and existing PRs

Run both commands:

```bash
gh issue list --repo nangchang/DevIsland --state open --json number,title,body,labels,comments
gh pr list --repo nangchang/DevIsland --state open --json number,title,headRefName,body
```

Build a set of **issue numbers already covered by an open PR** by scanning each PR's title, headRefName (e.g. `feat/123-slug`), and body for patterns like `#123`, `Closes #123`, `Fixes #123`. Use this set in Step 2.

## Step 2: Triage each issue (do NOT spawn agents yet)

For every open issue, evaluate it against these criteria.

**Before scoring, read the existing comments** (`comments` field from Step 1). They may:
- Clarify requirements or confirm design direction → can raise the score
- Show a linked PR or say the issue is already handled → trigger a skip
- Contain a previous triage comment from this bot → see Step 3 for dedup rules

### Importance score (implement if score ≥ 2)

| Criterion | +1 |
|-----------|-----|
| Bug with clear reproduction steps | ✓ |
| Regression (previously worked) | ✓ |
| Scope is narrow — change is isolated to 1–3 files | ✓ |
| Requirements are fully specified, no design decisions needed | ✓ |
| Low risk (no data migration, no breaking API change, no UI layout rework) | ✓ |

### Always skip (regardless of score)

- Needs design discussion or open-ended UX decisions
- Touches core data models or storage schema
- Requires input from the issue author to proceed
- Already has an open PR — either detected in Step 1's PR scan (issue number found in PR title/branch/body), or a PR URL appears in the issue's comments

### Triage decision

- **Score ≥ 2 and no skip conditions** → `implement`
- Otherwise → `comment-only`

## Step 3: Post a triage comment — only when needed

**Check for an existing triage comment before posting.** Look through the `comments` field for any comment that:
- Was authored by `nangchang` (the bot account), AND
- Contains `🤖 Generated with [Claude Code]`, AND
- Has a **triage 결정** that still matches the current decision (same outcome: 보류 vs 구현 예정)

If such a comment already exists and the situation hasn't changed (same decision, same reason), **skip posting** — do not add a duplicate comment.

Only post a new triage comment if:
- No prior triage comment exists, OR
- The decision has changed (e.g., was 보류 but now qualifies for `implement`), OR
- The prior comment's reason is now outdated (e.g., a PR it referenced was merged/closed)

When posting, include:
1. **평가 요약** — 이슈 내용을 한두 문장으로 요약
2. **중요도 점수** — 위 기준에 따라 체크된 항목 나열 (예: `점수: 3/5`)
3. **결정** — `구현 예정` 또는 `보류 (이유)`
4. **보류 이유** (skip인 경우) — 구체적으로 어떤 조건에 해당하는지

Comment footer (always include):
```
> 🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Post comments **before** spawning any agents.

```bash
gh issue comment <NUMBER> --repo nangchang/DevIsland --body "..."
```

## Step 4: Spawn one Agent per `implement` issue (in parallel)

For each issue marked `implement`, call the Agent tool with:
- `isolation: "worktree"`
- A self-contained prompt that includes:
  - The issue number, title, and full body
  - The repo path: `/Volumes/data/Github/DevIsland`
  - Instructions to: create a branch `feat/<issue-number>-<slug>` from `main`, implement the fix, run `xcodegen generate` then `xcodebuild build -scheme DevIsland -configuration Debug -quiet` and verify exit code 0, commit (Korean body, Why-focused, trailing `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`), push, open a PR linking the issue
  - Branch rule: never commit directly to main

Launch all implement-agents in a **single message** so they run in parallel.

## Step 5: Collect results

Summarize:
- Issues that got PRs (with PR URLs)
- Issues that were comment-only (with triage reason)
- Any agent that failed (with error)
