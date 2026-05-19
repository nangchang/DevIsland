---
name: block-pr-feedback-title
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: git\s+commit
  - field: command
    operator: regex_match
    pattern: (?i)(?:(?:PR|리뷰|피드백|코멘트).*(?:반영|적용)|(?:반영|적용).*(?:PR|리뷰|피드백|코멘트))
---

**커밋 제목에 "PR/리뷰/피드백 반영" 류 표현이 감지되었습니다.**

커밋 제목은 무엇을 반영했는지가 아니라, 변경의 이유와 목적을 담아야 합니다.

- ❌ `docs: PR #132 리뷰 반영`
- ❌ `fix: 피드백 적용`
- ✅ `docs: AI attribution 형식을 에이전트 간 일관되게 통일`
- ✅ `fix: nil 참조로 인한 크래시 방지`

커밋 제목을 다시 작성하세요.
