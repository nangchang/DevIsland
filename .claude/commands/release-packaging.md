---
description: DevIsland 릴리스 패키징 — 버전 범프, CHANGELOG 작성, DMG 빌드, GitHub 릴리스 노트 준비
argument-hint: Optional target version e.g. v1.2.3
---

# 릴리스 패키징

DevIsland 릴리스를 준비할 때 사용한다. 변경 검증이 필요하면 `/verify-build`와 함께 사용.

## 시작 — 필수 파일 읽기

```
AGENTS.md
CHANGELOG.md
CONTRIBUTING.md
docs/agent/build-and-test.md
.github/workflows/release.yml
.github/workflows/bump.yml
scripts/create-dmg.sh
```

현재 버전 및 태그 확인:

```bash
rg -n "CFBundleShortVersionString|CFBundleVersion" project.yml
git tag --list 'v*' --sort=-version:refname | head
```

## CHANGELOG 작성

태그·릴리스 전에 `CHANGELOG.md`에 해당 버전 섹션을 추가한다.

형식:
```
## vX.Y.Z - YYYY-MM-DD

<한국어 짧은 요약 단락>

### 주요 변경
- ...

### 승인/Hooks
- ...

### UI/UX
- ...

### 안정성
- ...

### 내부/CI
- ...

**Full Changelog**: https://github.com/nangchang/DevIsland/compare/vPREV...vX.Y.Z
```

자동 생성 GitHub release notes만 쓰지 말 것 — 사용자 관점의 요약이 필요함.

## GitHub 릴리스 노트

GitHub Release body는 `CHANGELOG.md`의 해당 버전 섹션을 원본으로 쓴다.
자동화 변경 시 `release.yml`이 해당 섹션을 읽어 `body_path`로 전달하도록 연결.

## 패키징

릴리스 워크플로는 macOS에서 실행하며 DMG를 만든다:

```bash
./scripts/create-dmg.sh
```

DMG 이름은 `project.yml`의 버전에서 온다 → `DevIsland-VERSION-arm64.dmg`.
`scripts/create-dmg.sh` 흐름: `xcodegen generate` → `xcodebuild` archive → 앱 추출 → xattr 제거 → `create-dmg`.

`.xcodeproj`는 직접 편집 금지 — `project.yml` 수정 후 `xcodegen generate`.

## 버전·태그 흐름

`bump.yml`은 `vX.Y.Z` 태그에 반응해 `project.yml`을 업데이트하고 커밋·리태그 후 릴리스를 트리거한다.
버전 자동화 변경 전에 이 흐름을 먼저 확인할 것.

태그 전 체크리스트:
- `CHANGELOG.md`에 대상 버전 섹션이 있는가
- `project.yml` 버전 흐름을 파악했는가
- 테스트를 통과했는가 (릴리스 전용 변경이면 이유 명시)

## 최종 검증

```bash
./scripts/run-tests.sh
./scripts/build_and_run.sh --no-kill --no-run
```

패키징 변경 시 로컬 DMG 생성을 실행하거나, 미실행 이유를 문서에 명시.
로컬 패키징에는 Xcode.app, `xcodegen`, `create-dmg`가 필요하다.
