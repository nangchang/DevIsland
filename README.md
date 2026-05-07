# 🏝️ DevIsland

**DevIsland**는 macOS의 노치 영역(Dynamic Island 스타일)을 활용하여 Claude Code, Gemini CLI 등 AI 에이전트의 활동을 실시간으로 모니터링하고 제어할 수 있는 오픈소스 대시보드입니다.

![DevIsland Showcase](https://raw.githubusercontent.com/nangchang/DevIsland/main/Assets/showcase.png) *(이미지 준비 중)*

## ✨ 주요 기능

- **Dynamic Island 스타일 UI**: 평상시에는 노치 뒤에 숨어 있다가 에이전트 활동 시 우아하게 확장됩니다.
- **실시간 세션 모니터링**: 실행 중인 에이전트 세션을 확인하고, 세션별 권한 요청 상태를 실시간으로 추적합니다.
- **스마트 승인 시스템**:
  - **원클릭 승인/거부**: 대시보드에서 즉시 처리 (Command+Shift+Y/N 단축키 지원).
  - **자동 편집 모드 감지**: Gemini CLI의 계획(Plan) 승인 후 이어지는 반복적인 파일 수정은 자동으로 통과시킵니다.
  - **Safe 툴 자동 승인**: 파일 읽기 등 위험도가 낮은 조회성 작업은 승인 없이 통과하도록 설정 가능합니다.
- **인터랙티브 알림**: 터미널 입력이 필요한 작업(`ask_user`, 쉘 명령어 등)은 승인 대기 대신 "터미널 확인" 알림을 띄워 흐름을 끊지 않습니다.
- **자동 정리**: 종료된 세션이나 장시간 활동이 없는 세션을 자동으로 관리합니다.

## 🚀 시작하기

### 1. 앱 빌드 및 실행
본 프로젝트는 [XcodeGen](https://github.com/yonaskolb/XcodeGen)을 사용합니다.

```bash
# XcodeGen 설치 (없을 경우)
brew install xcodegen

# 프로젝트 파일 생성 (테스트 타겟 포함)
xcodegen generate

# Xcode에서 열기
open DevIsland.xcodeproj

# 유닛 테스트 실행 (권장: 격리된 환경에서 실행)
# 현재 실행 중인 앱에 영향을 주지 않고 백그라운드에서 테스트를 수행합니다.
bash scripts/run-tests.sh

# 유닛 테스트 실행 (Xcode CLI 표준 방식)
xcodebuild test -project DevIsland.xcodeproj -scheme DevIsland -destination 'platform=macOS'
```

### 2. 유닛 테스트
프로젝트의 안정성을 위해 주요 로직(에이전트 판별, 메시지 처리, 자동 승인 등)에 대한 유닛 테스트가 포함되어 있습니다. `scripts/run-tests.sh`를 사용하면 현재 앱을 종료하지 않고도 안전하게 테스트를 수행할 수 있습니다. 새로운 기능을 추가하거나 버그를 수정한 후에는 반드시 테스트를 통과해야 합니다.

### 3. CLI 빌드 및 비간섭 모드
Xcode 없이 터미널에서 빠르게 빌드하거나, 현재 실행 중인 앱 인스턴스를 유지하면서 빌드 성공 여부를 확인하고 싶을 때 다음 스크립트를 사용합니다.

```bash
# 기본 빌드 및 실행 (기존 앱 종료 후 실행)
bash scripts/build_and_run.sh

# 비간섭 빌드 (기존 앱을 종료하지 않고 빌드만 수행)
bash scripts/build_and_run.sh --no-kill --no-run
```

- `--no-kill`: 빌드 전 현재 실행 중인 DevIsland 프로세스를 종료하지 않습니다.
- `--no-run`: 빌드 완료 후 앱을 새로 실행하지 않습니다.

### 4. CLI 에이전트 연동 (브릿지 설치)

터미널에서 실행되는 AI 에이전트의 이벤트를 DevIsland 앱으로 전달하기 위한 브릿지 스크립트를 설치해야 합니다.

#### 자동 설치 (권장)

```bash
# 모든 지원되는 CLI에 대해 설치
bash scripts/install-bridge.sh --all

# 특정 CLI만 선택해서 설치
bash scripts/install-bridge.sh --claude
bash scripts/install-bridge.sh --gemini
bash scripts/install-bridge.sh --codex
```

#### 수동 설치

**1) 브릿지 스크립트 준비**

```bash
# 표준 경로 생성
mkdir -p ~/Library/Application\ Support/DevIsland

# 심볼릭 링크 생성 (DevIsland 소스 경로 기준)
ln -sf /path/to/DevIsland/scripts/devisland-bridge.sh ~/Library/Application\ Support/DevIsland/devisland-bridge.sh
ln -sf /path/to/DevIsland/scripts/devisland_bridge.py ~/Library/Application\ Support/DevIsland/devisland_bridge.py
chmod +x ~/Library/Application\ Support/DevIsland/devisland-bridge.sh
chmod +x ~/Library/Application\ Support/DevIsland/devisland_bridge.py
```

**2) CLI별 설정**

- **Claude Code**: `~/.claude/settings.json`에 `PermissionRequest`, `SessionStart`, `SessionEnd`, `Notification`, `Stop` 훅을 등록합니다.
- **Gemini CLI**: `~/.gemini/settings.json`에 `BeforeTool`, `SessionStart`, `SessionEnd`, `AfterAgent`, `Notification` 훅을 등록합니다.
- **Codex CLI**: `~/.codex/hooks.json`의 `PermissionRequest` 항목을 승인용으로, `PreToolUse`/`PostToolUse`/`Stop` 항목을 상태 추적용으로 등록하고, `config.toml`에서 `codex_hooks = true`를 활성화합니다.

### 5. 로그인 시 자동 시작 (선택)

앱을 `/Applications/DevIsland.app`에 복사한 뒤 LaunchAgent로 등록하면 로그인할 때마다 자동으로 실행됩니다.

```bash
bash scripts/install-launch-agent.sh

# 제거할 경우
PLIST=~/Library/LaunchAgents/kr.or.nes.DevIsland.plist
launchctl unload "$PLIST" && rm "$PLIST"
```

### 6. Gemini CLI 최적화 팁

Gemini CLI 사용자라면 다음 설정을 통해 가장 쾌적한 환경을 구축할 수 있습니다.

1.  **일반 모드 에뮬레이션**: Gemini CLI를 `--yolo` 또는 `--auto-approve` 모드로 실행하여 터미널 프롬프트를 끄고, DevIsland 메뉴에서 **"Gemini 일반 모드 에뮬레이션"**을 켜세요. 통제권이 DevIsland GUI로 넘어옵니다.
2.  **Safe 툴 자동 승인**: 메뉴에서 이 옵션을 켜면 파일 읽기 등 단순 조회 작업 시 노치가 방해하지 않습니다.

### 7. 문제 해결 (Troubleshooting)

**Claude Code의 `auto` 모드에서 요청이 거부되는 경우**
- **현상**: `auto` 모드 사용 시 LaunchAgent 등록이나 특정 파일 생성이 "Denied by auto-mode classifier"와 함께 즉시 거부되며, DevIsland 노치에 승인 창이 뜨지 않습니다.
- **원인**: 이는 Claude Code 자체의 보안 정책(Classifier)이 브릿지 호출 전 단계에서 위험한 작업(시스템  상주 등)을 사전에 차단하기 때문입니다.
- **해결**: 해당 작업은 `auto` 모드가 아닌 인터랙티브(interactive) 모드에서 진행하세요. 인터랙티브 모드에서는 DevIsland를 통해 사용자가 직접 승인할 수 있습니다.

## 🛠️ 개발 환경

- **SwiftUI**: 현대적이고 선언적인 UI 프레임워크
- **Combine**: 실시간 이벤트 데이터 스트리밍
- **AppKit (NSPanel)**: 투명하고 항상 위에 떠 있는 특수 윈도우
- **Network.framework**: CLI 브릿지와 앱 간의 저지연 TCP 통신

## 🤝 기여하기

버그 보고, 기능 제안, 그리고 Pull Request는 언제나 환영합니다! 

1. 프로젝트를 Fork합니다.
2. 새로운 브랜치를 생성합니다 (`git checkout -b feature/amazing-feature`).
3. 변경 사항을 Commit합니다 (`git commit -m 'Add amazing feature'`).
4. 브랜치에 Push합니다 (`git push origin feature/amazing-feature`).
5. Pull Request를 생성합니다.

## 📄 라이선스

이 프로젝트는 MIT 라이선스 하에 배포됩니다.

---
Created with ❤️ by [nangchang](https://github.com/nangchang)
