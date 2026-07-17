import Foundation
import os

// Parsed fields extracted from a raw hook message string.
struct ParsedHookEvent {
    let requestId: String?
    let parsedJSON: [String: Any]
    let sessionId: String
    let event: String
    let toolName: String
    let displayToolName: String
    let displayMsg: String
    let agentKind: BuddyKind
    let terminalTitle: String
    let terminal: TerminalContext
    let workspaceRoot: String?
    let toolInput: [String: Any]?
    let isSubAgentSession: Bool
    let parentSessionId: String?
    /// Codex sub-agent identity. Codex signals a sub-agent-originated hook via
    /// `agent_id`/`agent_type` (optional in its schema) and never sends Claude's
    /// `parent_session_id`; the child reuses the parent `session_id`. Presence of
    /// `agent_id` marks the event as a sub-agent session; `handleSubAgentEvent`
    /// uses `agent_id` as the distinct child row id (parent = `sessionId`).
    let subAgentId: String?
    let subAgentType: String?
    let isReplayPayload: Bool
    let isPlanAction: Bool
    let sessionStartSource: String
    let notificationType: String

    var delegatesApprovalToCodex: Bool {
        agentKind == .codex && parsedJSON["devisland_approval_owner"] as? String == "codex"
    }
}

enum HookParseResult {
    case parsed(ParsedHookEvent)
    case denied    // IPC envelope with invalid token
    case invalid   // unreadable bytes or JSON
}

enum HookMessageAuthentication: Equatable {
    case legacyAllowed
    case authenticatedEnvelopeRequired
}

enum HookEventHandler {
    static func parse(
        _ message: String,
        authentication: HookMessageAuthentication = .legacyAllowed,
        validateToken: (String?) -> Bool = { BridgeTokenManager.shared.validate($0) }
    ) -> HookParseResult {
        guard let rawData = message.data(using: .utf8) else { return .invalid }

        let parsedJSON: [String: Any]
        let requestId: String?
        if let envelope = try? JSONDecoder().decode(IPCEnvelope.self, from: rawData) {
            guard envelope.protocol == IPCEnvelope.protocolName,
                  envelope.version == IPCEnvelope.currentVersion else {
                Log.bridge.error("Invalid IPC envelope protocol or version – denying request")
                return .denied
            }
            guard validateToken(envelope.token) else {
                Log.bridge.error("IPC token validation failed – denying request")
                return .denied
            }
            parsedJSON = envelope.payload.mapValues { $0.rawValue } as [String: Any]
            requestId = envelope.requestId
        } else {
            guard authentication == .legacyAllowed else {
                Log.bridge.error("Authenticated IPC envelope required – denying request")
                return .denied
            }
            guard let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
                return .invalid
            }
            parsedJSON = json
            requestId = nil
        }

        let event     = (parsedJSON["hook_event_name"] as? String) ?? (parsedJSON["event"] as? String) ?? "Unknown"
        let toolName  = parsedJSON["tool_name"] as? String ?? ""
        let sessionId = (parsedJSON["session_id"] as? String) ?? (parsedJSON["sessionId"] as? String) ?? ""

        var isSubAgentSession = false
        var parentSessionId: String?
        if let pid = parsedJSON["parent_session_id"] as? String, !pid.isEmpty {
            isSubAgentSession = true
            parentSessionId = pid
        }

        // Codex sub-agent identity (see `ParsedHookEvent.subAgentId`). Codex
        // reuses the parent `session_id` and identifies the child via `agent_id`,
        // so we treat it as a sub-agent session but resolve the distinct child
        // row id from `agent_id` in `handleSubAgentEvent` — `sessionId` here stays
        // the real Codex session so no other consumer sees a synthesized id.
        let subAgentId = (parsedJSON["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let subAgentType = (parsedJSON["agent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if subAgentId != nil {
            isSubAgentSession = true
        }

        Log.bridge.debug("Parsed JSON from \(sessionId.prefix(8), privacy: .private)")

        var terminalTitle = parsedJSON["terminal_title"] as? String ?? "Terminal"
        let terminal = TerminalContext(from: parsedJSON)
        let workspaceRoot   = parsedJSON["cwd"] as? String
        let sessionStartSource = parsedJSON["source"] as? String ?? ""
        let notificationType   = parsedJSON["notification_type"] as? String ?? ""
        let isReplayPayload    = parsedJSON["replay_origin_event_id"] != nil

        // osascript가 기본값을 반환하면 cwd 마지막 경로로 대체
        // 빈 cwd를 URL(fileURLWithPath:)에 넘기면 프로세스의 현재 디렉토리로 해석돼
        // 엉뚱한 이름이 잡히므로 비어 있지 않을 때만 경로 컴포넌트를 사용한다.
        if SessionStore.genericTitles.contains(terminalTitle), let cwd = parsedJSON["cwd"] as? String, !cwd.isEmpty {
            let label = URL(fileURLWithPath: cwd).lastPathComponent
            if !label.isEmpty && label != "/" { terminalTitle = label }
        }

        let agentKind = HookEventNormalizer.agentKind(from: parsedJSON, terminalTitle: terminalTitle)
        let toolInput = parsedJSON["tool_input"] as? [String: Any]

        // 제미나이의 계획(Plan) 작성인지 일반 코드 수정인지 구분하여 UI에 표시
        let filePath = toolInput?["file_path"] as? String ?? ""
        let isPlanAction = filePath.contains(".gemini/tmp/")
        // UI 표시 전용 이름 — 로직 체크(auto-approve, ToolKnowledge 등)에는 toolName 원본 사용
        let displayToolName = isPlanAction && (toolName == "write_file" || toolName == "replace")
            ? toolName + " (Plan)"
            : toolName

        Log.bridge.debug("Parsed Hook: event=\(event, privacy: .public), session=\(sessionId, privacy: .private), title=\(terminalTitle, privacy: .private)")

        let displayMsg = ToolMessageFormatter.displayMessage(
            for: toolName,
            toolInput: toolInput,
            json: parsedJSON,
            eventName: event
        )

        return .parsed(ParsedHookEvent(
            requestId: requestId,
            parsedJSON: parsedJSON,
            sessionId: sessionId,
            event: event,
            toolName: toolName,
            displayToolName: displayToolName,
            displayMsg: displayMsg,
            agentKind: agentKind,
            terminalTitle: terminalTitle,
            terminal: terminal,
            workspaceRoot: workspaceRoot,
            toolInput: toolInput,
            isSubAgentSession: isSubAgentSession,
            parentSessionId: parentSessionId,
            subAgentId: subAgentId,
            subAgentType: subAgentType,
            isReplayPayload: isReplayPayload,
            isPlanAction: isPlanAction,
            sessionStartSource: sessionStartSource,
            notificationType: notificationType
        ))
    }
}
