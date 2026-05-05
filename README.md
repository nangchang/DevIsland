# 🏝️ DevIsland

**DevIsland**는 macOS의 노치 영역(Dynamic Island 스타일)을 활용하여 Claude Code와 같은 AI 에이전트의 활동을 실시간으로 모니터링하고 제어할 수 있는 오픈소스 대시보드입니다.

![DevIsland Showcase](https://raw.githubusercontent.com/nangchang/DevIsland/main/Assets/showcase.png) *(이미지 준비 중)*

## ✨ 주요 기능

- **Dynamic Island 스타일 UI**: 평상시에는 노치 뒤에 숨어 있다가 에이전트 활동 시 우아하게 확장됩니다.
- **세션 모니터링**: 실행 중인 Claude Code 세션을 확인하고, 세션별 권한 요청 상태를 추적할 수 있습니다.
- **스마트 세션 관리**: 여러 터미널에서 실행 중인 에이전트 세션을 개별적으로 추적하고 관리합니다.
- **원클릭 승인/거부**: 에이전트의 권한 요청을 대시보드에서 즉시 처리할 수 있습니다. (Command+Shift+Y/N 단축키 지원)
- **자동 정리**: 종료된 세션이나 장시간 활동이 없는 세션을 자동으로 감지하여 목록을 청결하게 유지합니다.

## 🚀 시작하기

### 1. 앱 빌드 및 실행
본 프로젝트는 [XcodeGen](https://github.com/yonaskolb/XcodeGen)을 사용합니다.

```bash
# XcodeGen 설치 (없을 경우)
brew install xcodegen

# 프로젝트 파일 생성
xcodegen generate

# Xcode에서 열기
open DevIsland.xcodeproj
```

### 2. CLI 에이전트 연동 (브릿지 설치)

터미널에서 실행되는 AI 에이전트의 이벤트를 DevIsland 앱으로 전달하기 위한 브릿지 스크립트를 설치해야 합니다. Claude Code, Gemini CLI, Codex CLI를 모두 지원합니다.

#### 자동 설치

```bash
# 모든 지원되는 CLI에 대해 설치
bash scripts/install-bridge.sh --all

# 특정 CLI만 선택해서 설치
bash scripts/install-bridge.sh --claude
bash scripts/install-bridge.sh --gemini
bash scripts/install-bridge.sh --codex
```

#### 수동 설치

스크립트를 실행하기 어려운 경우 아래 단계를 직접 수행하세요.

**1) 브릿지 스크립트 준비**

```bash
mkdir -p ~/Library/Application\ Support/DevIsland
# 심볼릭 링크 생성
ln -sf /path/to/DevIsland/scripts/devisland-bridge.sh ~/Library/Application\ Support/DevIsland/devisland-bridge.sh
chmod +x ~/Library/Application\ Support/DevIsland/devisland-bridge.sh
```

**2) CLI별 설정**

- **Claude Code**: `~/.claude/settings.json`에 `PermissionRequest`, `SessionStart`, `SessionEnd` 훅을 등록합니다.
- **Gemini CLI**: `~/.gemini/settings.json`의 `hooks` 배열에 `BeforeTool`, `SessionStart`, `SessionEnd` 이벤트를 추가합니다.
- **Codex CLI**: `~/.codex/hooks.json`의 `PreToolUse` 항목에 등록하고, `~/.codex/config.toml`에서 `codex_hooks = true`를 활성화합니다.

상세한 설정 예시는 `scripts/install-bridge.sh` 파일 내의 Python 로직을 참조하세요.

설치가 완료되면 각 CLI 실행 시 자동으로 DevIsland와 연결됩니다.

### 3. 로그인 시 자동 시작 (선택)

앱을 `/Applications/DevIsland.app`에 복사한 뒤 LaunchAgent로 등록하면 로그인할 때마다 자동으로 실행됩니다.

```bash
bash scripts/install-launch-agent.sh

# 제거할 경우
PLIST=~/Library/LaunchAgents/kr.or.nes.DevIsland.plist
launchctl unload "$PLIST" && rm "$PLIST"
```

## 🛠️ 개발 환경

- **SwiftUI**: 현대적이고 선언적인 UI 프레임워크 사용
- **Combine**: 실시간 이벤트 데이터 스트리밍 처리
- **AppKit (NSPanel)**: 투명하고 항상 위에 떠 있는 특수 윈도우 구현
- **TCP Socket**: CLI 브릿지와 앱 간의 저지연 통신

## 🤝 기여하기

버그 보고, 기능 제안, 그리고 Pull Request는 언제나 환영합니다! 

1. 프로젝트를 Fork합니다.
2. 새로운 브랜치를 생성합니다 (`git checkout -b feature/amazing-feature`).
3. 변경 사항을 Commit합니다 (`git commit -m 'Add amazing feature'`).
4. 브랜치에 Push합니다 (`git push origin feature/amazing-feature`).
5. Pull Request를 생성합니다.

## 📄 라이선스

이 프로젝트는 MIT 라이선스 하에 배포됩니다. 자세한 내용은 [LICENSE](LICENSE) 파일을 참조하세요.

---
Created with ❤️ by [nangchang](https://github.com/nangchang)
