import Foundation

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
    let terminalApp: String
    let terminalTTY: String
    let terminalWindowId: String
    let terminalTabIndex: String
    let terminalTmuxPane: String
    let terminalTmuxSocket: String
    let terminalTmuxClient: String
    let workspaceRoot: String?
    let toolInput: [String: Any]?
    let isSubAgentSession: Bool
    let parentSessionId: String?
    let isReplayPayload: Bool
    let isPlanAction: Bool
    let sessionStartSource: String
    let notificationType: String
}

enum HookParseResult {
    case parsed(ParsedHookEvent)
    case denied    // IPC envelope with invalid token
    case invalid   // unreadable bytes or JSON
}

enum HookEventHandler {
    static func parse(_ message: String) -> HookParseResult {
        guard let rawData = message.data(using: .utf8) else { return .invalid }

        let parsedJSON: [String: Any]
        let requestId: String?
        if let envelope = try? JSONDecoder().decode(IPCEnvelope.self, from: rawData),
           envelope.protocol == IPCEnvelope.protocolName {
            guard BridgeTokenManager.shared.validate(envelope.token) else {
                print("[DevIsland] IPC token validation failed – denying request")
                return .denied
            }
            parsedJSON = envelope.payload.mapValues { $0.rawValue } as [String: Any]
            requestId = envelope.requestId
        } else {
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

        print("[DevIsland] [MSG] Parsed JSON from \(sessionId.prefix(8))")

        var terminalTitle = parsedJSON["terminal_title"] as? String ?? "Terminal"
        let terminalApp     = parsedJSON["terminal_app"] as? String ?? ""
        let terminalTTY     = parsedJSON["terminal_tty"] as? String ?? ""
        let terminalWindowId  = parsedJSON["terminal_window_id"] as? String ?? ""
        let terminalTabIndex  = parsedJSON["terminal_tab_index"] as? String ?? ""
        let terminalTmuxPane  = parsedJSON["terminal_tmux_pane"] as? String ?? ""
        let terminalTmuxSocket = parsedJSON["terminal_tmux_socket"] as? String ?? ""
        let terminalTmuxClient = parsedJSON["terminal_tmux_client"] as? String ?? ""
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

        print("Parsed Hook: event=\(event), session=\(sessionId), title=\(terminalTitle)")

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
            terminalApp: terminalApp,
            terminalTTY: terminalTTY,
            terminalWindowId: terminalWindowId,
            terminalTabIndex: terminalTabIndex,
            terminalTmuxPane: terminalTmuxPane,
            terminalTmuxSocket: terminalTmuxSocket,
            terminalTmuxClient: terminalTmuxClient,
            workspaceRoot: workspaceRoot,
            toolInput: toolInput,
            isSubAgentSession: isSubAgentSession,
            parentSessionId: parentSessionId,
            isReplayPayload: isReplayPayload,
            isPlanAction: isPlanAction,
            sessionStartSource: sessionStartSource,
            notificationType: notificationType
        ))
    }
}
