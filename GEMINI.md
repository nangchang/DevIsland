# 🏝️ DevIsland: Gemini CLI Instructions

This document is the primary entry point for the Gemini CLI when working on the DevIsland project.

## 🏗️ Project Overview

DevIsland is a macOS application providing a "Dynamic Island" style dashboard for real-time monitoring and control of AI agents (Claude, Gemini, Codex).

- **Architecture**: Swift (SwiftUI/AppKit) app with a TCP Socket server (port 9090).
- **Bridge**: A bash/python bridge forwards CLI hook events to the app.
- **Protocol**: JSON payloads over TCP or Unix domain sockets.

## 🛠️ Mandatory Standards (The 5 Commandments)

Gemini CLI는 이 저장소에서 작업할 때 다음 규칙을 **반드시** 준수해야 합니다.

1. **Propose & Confirm First**: 모든 파일 수정, 브랜치 생성, 커밋 전에 반드시 계획과 커밋 메시지를 제안하고 승인을 받으십시오.
2. **Korean Commit Body**: 커밋 메시지의 **Body(본문)는 반드시 한국어**로 작성하십시오. "무엇을" 했는지보다 **"왜(Rationale)"** 그렇게 했는지에 집중하십시오. (Title은 영어 Conventional Commits 준수)
3. **Atomic & Surgical**: 하나의 커밋에는 하나의 논리적 단위만 포함하십시오. 관련 없는 코드 정리나 스타일 수정은 금지하며, 요청된 작업에 꼭 필요한 부분만 수정하십시오.
4. **Pre-Commit Verification**: 커밋 승인을 요청하기 전에 반드시 테스트를 통과해야 합니다.
   - 실행: `./scripts/run-tests.sh`
5. **No Project File Commits**: `.xcodeproj` 파일은 절대 커밋하지 마십시오. `project.yml` 수정 후 `xcodegen generate`를 실행하십시오.

## 🚦 Documentation Reference

상세한 구현 사양이나 빌드 방법은 아래의 모듈화된 문서를 참조하십시오.

- **[AGENTS.md](AGENTS.md)**: 전체 에이전트 공통 가이드.
- **[docs/agent/build-and-test.md](docs/agent/build-and-test.md)**: 빌드 및 테스트 상세 가이드.
- **[docs/agent/hook-providers.md](docs/agent/hook-providers.md)**: Hook 이벤트 상세 (Gemini 전용 컨텍스트 포함).
- **[docs/agent/approval-proxy.md](docs/agent/approval-proxy.md)**: IPC 및 내부 로직 사양.
- **[docs/agent/stability-standards.md](docs/agent/stability-standards.md)**: 성능 및 안정성 규칙.

## 📝 Gemini-Specific Context

- **Approval Events**: Gemini는 `BeforeTool` 이벤트를 사용하여 승인을 요청합니다.
- **Auto-Edit Mode**: `exit_plan_mode` 도구 실행 시 앱에서 Auto-Edit 상태가 활성화됩니다.
- **Integration**: `scripts/install-bridge.sh`를 통해 `~/.gemini/settings.json` 설정이 관리됩니다.
