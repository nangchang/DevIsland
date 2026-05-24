---
description: 현재 변경사항을 검토하고 커밋 여부를 판단한다
argument-hint: Optional base branch or commit (default: main)
---

# Diff 검토

현재 변경사항을 검토하고 커밋 준비가 됐는지 확인한다.

## 단계

### 1. 현재 상태 파악

```bash
BASE=${ARGUMENTS:-main}
git status
git diff $BASE --stat
```

### 2. 변경 내용 상세 확인

```bash
git diff $BASE
```

### 3. 검토 항목

각 변경에 대해:
- **의도한 변경인가?** 요청 범위를 벗어난 수정이 없는지
- **부수 효과가 있는가?** 다른 기능에 영향을 주는지
- **커밋 단위가 적절한가?** 이유가 다른 변경이 섞여있지 않은지
- **빌드가 통과하는가?** Swift 파일 변경 시 xcodebuild 확인

### 4. 커밋 제안

변경 이유별로 분리된 커밋 계획을 사용자에게 제안한다.
사용자 승인 후 `/create-pr`로 PR 생성.
