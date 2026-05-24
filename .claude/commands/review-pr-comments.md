---
description: PR 코멘트를 조회하고 수정사항을 반영한다
argument-hint: PR number (required)
---

# PR 코멘트 검토 워크플로우

PR의 모든 코멘트(inline, issue, review)를 조회하고 수정한다.

## PR 번호

`$ARGUMENTS` — 없으면 현재 브랜치 기준으로 조회:
```bash
gh pr view --json number -q .number
```

## 단계

### 1. 모든 코멘트 조회 (3개 엔드포인트)

```bash
PR=${ARGUMENTS:-$(gh pr view --json number -q .number)}

echo "=== Inline comments ==="
gh api "repos/nangchang/DevIsland/pulls/${PR}/comments" \
  --jq '.[] | "[inline] \(.user.login) \(.path):\(.line // "?") — \(.body)"'

echo "=== Issue comments ==="
gh api "repos/nangchang/DevIsland/issues/${PR}/comments" \
  --jq '.[] | "[comment] \(.user.login): \(.body)"'

echo "=== Reviews ==="
gh api "repos/nangchang/DevIsland/pulls/${PR}/reviews" \
  --jq '.[] | "[review] \(.user.login) (\(.state)): \(.body)"'
```

### 2. 분류

각 코멘트를:
- **수정 필요**: 명확한 버그, 오타, 규칙 위반
- **논의 필요**: 설계 판단이 필요한 것
- **무시 가능**: 이미 반영됨, 범위 밖

### 3. 수정 반영

수정 이유가 다른 항목은 별도 커밋으로 분리한다.

커밋 메시지는 "코멘트 반영"이 아니라 **수정 이유** 중심으로 작성:
- ❌ `fix: 리뷰 반영`
- ✅ `fix: nil 참조 가능성 제거`

### 4. Push

```bash
git push
```

### 5. 완료 보고

처리한 코멘트 목록과 무시한 코멘트(이유 포함)를 사용자에게 요약한다.
