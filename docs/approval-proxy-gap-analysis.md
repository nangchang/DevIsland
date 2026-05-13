# Approval Proxy 구현 현황 및 격차 분석 (Gap Analysis)

> 작성일: 2026-05-13  
> 대상 문서: `docs/approval-proxy.md` (v1.0)  
> 분석 결과: 설계상 Phase 7 완료로 표시되어 있으나, 핵심 로직의 고도화 및 아키텍처 통합이 누락됨.

## 1. 개요

`docs/approval-proxy.md`에 정의된 설계와 현재 실제 구현된 코드베이스를 대조한 결과, 통신 프로토콜(IPC v1, UDS)과 기본 DB 스키마는 잘 갖춰져 있으나 **정책 결정 엔진(Policy Engine)의 지능적 처리**와 **에이전트별 정책 저장소의 단일화**가 미흡한 상태임.

## 2. 주요 격차 (Gaps)

### 2.1 정책 결정 엔진 (Policy Engine)
*   **설계 (Phase 3/6)**: Exact, Glob, Regex, CommandPrefix 등 다양한 매칭 모드 지원 및 8단계 우선순위 적용.
*   **현황**: `ApprovalPolicyEngine.swift`에서 `exact` 매칭만 수행. Glob이나 Regex 매칭 로직이 전혀 구현되지 않음.
*   **위험**: 복잡한 명령어나 패턴 기반의 자동 승인이 불가능함.

### 2.2 Claude 세션 승인 및 하이브리드 모드 (Phase 4)
*   **설계**: `claudeSessionApprovalMode`가 `hybrid` 또는 `appSessionCache`일 때 DevIsland 로컬 DB에도 승인 정보를 저장.
*   **현황**: `AppState.sendDecision` 로직이 Codex에 대해서만 DB 저장을 수행하며, Claude의 승인 내역은 `updatedPermissions` 응답 생성에만 사용되고 로컬 DB(`session_cache`)에는 기록되지 않음.
*   **위험**: Claude 세션 모드 설정에 따른 일관된 동작 보증이 어려움.

### 2.3 정책 저장소의 분절화 (Unified Policy Management)
*   **설계**: 모든 에이전트의 승인 정책을 SQLite(`rules`, `session_cache`)로 통합 관리.
*   **현황**: 
    *   **Codex**: SQLite 사용.
    *   **Claude/Gemini**: 여전히 `AppState`의 인메모리 `Set`(`globalAutoApproveTypes`, `sessionAutoApproveTypes`)에 의존.
*   **위험**: 앱 재시작 시 Claude/Gemini의 승인 내역이 소멸되며, `Approval Rules` UI에서 이들의 규칙을 관리하기 어려움.

### 2.4 Gemini 전용 정책 모듈 누락
*   **설계**: Claude(`ClaudePromptPolicy`)와 유사한 Gemini 전용 정책 모듈 필요.
*   **현황**: `GeminiPromptPolicy.swift`가 존재하지 않으며, `ProviderAdapter` 내에 최소한의 하드코딩된 로직만 존재.

### 2.5 아키텍처 결합도 (Fat AppState)
*   **설계**: `QuestionBroker`, `EventReplayLog`, `ProviderAdapter` 등으로 책임 분산.
*   **현황**: `AppState.swift` (93KB)가 여전히 대부분의 Hook 메시지 파싱, UI 상태 변경, 결정 전송 로직을 직접 처리함. 특히 `AskUserQuestion` 등을 관리하는 별도 객체가 없음.

## 3. 개선 로드맵 (Proposed Actions)

| 순위 | 작업 항목 | 설명 |
|:---:|---|---|
| **1** | **정책 저장소 통합** | Claude/Gemini의 `global/session` 승인 시 인메모리 Set 대신 SQLite에 기록하도록 수정. |
| **2** | **고급 매칭 지원** | `SQLiteApprovalStore` 및 `PolicyEngine`에 Glob/Prefix 매칭 로직 구현. |
| **3** | **Claude Hybrid 로직 보완** | Claude 승인 시 `updatedPermissions` 생성과 동시에 로컬 DB 저장을 연동. |
| **4** | **Gemini 전용 모듈 추가** | `GeminiPromptPolicy.swift` 신규 작성 및 프롬프트 제어 로직 강화. |
| **5** | **AppState 리팩토링** | Hook 처리 로직을 `ApprovalProxyController` 및 신설될 `QuestionBroker`로 이관. |

## 4. 결론

현재 DevIsland는 "승인 프록시"로서의 뼈대는 갖추었으나, 실질적인 자동화와 지능적 정책 관리를 위한 근육(Engine)이 부족한 상태임. 1순위 작업인 **정책 저장소 통합**을 통해 데이터 영속성과 관리 효율성을 먼저 확보할 것을 권장함.
