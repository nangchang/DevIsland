---
description: xcodebuild로 빌드 성공 여부를 확인한다
argument-hint: Optional scheme name (default: DevIsland)
---

# 빌드 검증

xcodebuild로 실제 빌드 성공 여부를 확인한다.
SourceKit 진단 오류와 실제 빌드 오류는 다르다 — 종료 코드가 유일한 기준이다.

## 실행

```bash
SCHEME=${ARGUMENTS:-DevIsland}
xcodebuild build -scheme "$SCHEME" -quiet 2>&1 | tail -10
echo "Exit: $?"
```

## 결과 해석

- `Exit: 0` → BUILD SUCCEEDED
- 그 외 → 실패, 에러 메시지 분석 후 수정

## 주의

- `-quiet` 플래그 사용 시 성공/실패 메시지가 출력되지 않으므로 `$?` 확인 필수
- `BUILD SUCCEEDED` / `BUILD FAILED` 문자열 grep은 `-quiet` 시 동작하지 않음
- DerivedData 초기화 후 첫 빌드는 시간이 오래 걸릴 수 있음
