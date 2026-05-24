---
description: 현재 브랜치의 변경사항을 커밋하고 PR을 생성한다
argument-hint: Optional PR base branch (default: main)
---

# PR 생성 워크플로우

변경사항을 의미 단위로 커밋한 뒤 PR을 만든다.

## 기본 규칙

- 커밋 제목: 영어 conventional commit (`feat:`, `fix:`, `docs:` 등)
- 커밋 바디: 한국어, **변경 이유(Why)** 중심
- PR 본문: 한국어, 변경 이유와 영향 범위 요약
- AI attribution 트레일러 필수

## 단계

### 1. 상태 확인

```bash
git status
git diff --stat
```

### 2. 커밋

변경 이유가 다른 파일은 별도 커밋으로 분리한다.

```bash
git add <관련 파일들>
git commit -m "$(cat <<'EOF'
<type>: <what changed>

<왜 변경했는지 한국어로>

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

**금지 패턴:** "PR 리뷰 반영", "피드백 적용", "address review comments" → Why를 써야 함

### 3. Push

```bash
git push -u origin HEAD
```

### 4. PR 생성

베이스 브랜치: `$ARGUMENTS` 또는 `main`

```bash
gh pr create --base ${ARGUMENTS:-main} --title "<영어 conventional commit 형식 제목>" --body "$(cat <<'EOF'
## 변경 내용

- 항목 1
- 항목 2

## 변경 이유

<왜 이 변경이 필요했는지>

## 영향 범위

<어떤 부분에 영향을 미치는지>

> 🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### 5. 확인

생성된 PR URL을 사용자에게 알린다.
