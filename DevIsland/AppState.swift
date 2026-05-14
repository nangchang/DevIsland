import SwiftUI
import Combine
import AppKit

// MARK: - Pending Request

struct PendingRequest: Identifiable {
    let id = UUID()
    let hookEventId: Int64?
    let sessionId: String
    let agentKind: BuddyKind
    let eventName: String
    let toolName: String
    let rawToolName: String
    let workspaceRoot: String?
    let isReplay: Bool
    let message: String
    let responseHandler: (String) -> Void
    let receivedAt: Date
}

struct PendingItem: Identifiable, Equatable {
    let id: UUID
    let toolName: String
    let message: String
    let sessionId: String
    let terminalTitle: String
    let terminalWindowId: String
    let terminalTabIndex: String
    let terminalTmuxPane: String
    let terminalTmuxSocket: String
    let terminalTmuxClient: String
    let receivedAt: Date
}

enum SessionStatus: Equatable {
    case idle
    case pending
    case timeoutBypassed(Date)
    case autoApproved(Date)
    case policyApproved(Date)

    var isTimeoutBypassed: Bool {
        if case .timeoutBypassed = self { return true }
        if case .autoApproved = self { return true }
        if case .policyApproved = self { return true }
        return false
    }
}

struct ActiveSession: Identifiable, Equatable {
    let id: String // full sessionId
    var terminalTitle: String
    var agentKind: BuddyKind
    var terminalApp: String
    var terminalTTY: String
    var terminalWindowId: String
    var terminalTabIndex: String
    var terminalTmuxPane: String
    var terminalTmuxSocket: String
    var terminalTmuxClient: String
    var lastToolName: String
    var lastEventName: String
    var lastMessage: String
    let startTime: Date
    var lastActiveAt: Date
    var isPending: Bool
    var isLifecycleTracked: Bool
    var isAutoEditActive: Bool
    var status: SessionStatus
}

enum RequestDisplayTarget: String, CaseIterable, Identifiable {
    case notch
    case focused
    case mouse

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .notch:   return l.reqNotch
        case .focused: return l.reqFocused
        case .mouse:   return l.reqMouse
        }
    }
}

enum NotchDisplayTarget: String, CaseIterable, Identifiable {
    case automatic
    case main
    case mouse
    case focused
    case specific

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .automatic: return l.notchAuto
        case .main:      return l.notchMain
        case .mouse:     return l.notchMouse
        case .focused:   return l.notchFocused
        case .specific:  return l.notchSpecific
        }
    }
}

// MARK: - App State

// AppState is the central hub: owns the IPC server, session list, pending approval queue,
// and decision dispatch. It also holds Gemini-specific UX state (auto-edit mode, emulation).
//
// TODO(gap-5): AppState (~93 KB) handles too many responsibilities. Planned decomposition:
//   - Hook parsing/normalization → ApprovalProxyController / HookEventNormalizer (partially done)
//   - AskUserQuestion / ExitPlanMode flow → QuestionBroker (new type)
//   - Gemini UX logic → GeminiSessionState or GeminiPromptPolicy
//   Splitting reduces test surface and makes each concern independently testable.
//   See AGENTS.md "Approval Proxy Architecture → Known Gaps" for the full gap list.
class AppState: ObservableObject {
    static let shared = AppState(
        startServer: ProcessInfo.processInfo.environment["XCODE_RUNNING_UNIT_TESTS"] != "1",
        approvalProxy: AppState.makeApprovalProxy()
    )

    private static func makeApprovalProxy() -> ApprovalProxyController? {
        do {
            return try ApprovalProxyController()
        } catch {
            print("[DevIsland] ApprovalProxyController init failed: \(error)")
            return nil
        }
    }

    private enum DefaultsKey {
        static let notchDisplayTarget = "notchDisplayTarget"
        static let selectedDisplayId = "selectedDisplayId"
        static let showInFullScreenApps = "showInFullScreenApps"
        static let requestDisplayTarget = "requestDisplayTarget"
        static let globalAutoApproveTypes = "globalAutoApproveTypes"
        static let autoApproveSafeTools = "autoApproveSafeTools"
        static let emulateGeminiInteractiveMode = "emulateGeminiInteractiveMode"
    }

    typealias FrontmostCheck = (
        _ appName: String?,
        _ tty: String?,
        _ windowId: String?,
        _ tabIndex: String?,
        _ tmuxPane: String?,
        _ tmuxSocket: String?,
        _ tmuxClient: String?
    ) -> Bool

    private let userDefaults: UserDefaults
    private let frontmostCheck: FrontmostCheck
    private let codexRuleSyncAdapter: CodexRuleSyncAdapter

    @Published var isNotchExpanded = false
    @Published var isExpandingFromRequest = false
    @Published var notchDisplayTarget: NotchDisplayTarget = .automatic {
        didSet {
            if notchDisplayTarget == .specific {
                ensureSelectedDisplay()
            }
            userDefaults.set(notchDisplayTarget.rawValue, forKey: DefaultsKey.notchDisplayTarget)
        }
    }
    @Published var selectedDisplayId: UInt32 = 0 {
        didSet {
            userDefaults.set(Int(selectedDisplayId), forKey: DefaultsKey.selectedDisplayId)
        }
    }
    @Published var showInFullScreenApps = true {
        didSet {
            userDefaults.set(showInFullScreenApps, forKey: DefaultsKey.showInFullScreenApps)
        }
    }
    @Published var requestDisplayTarget: RequestDisplayTarget = .focused {
        didSet {
            userDefaults.set(requestDisplayTarget.rawValue, forKey: DefaultsKey.requestDisplayTarget)
        }
    }
    @Published var selectedSessionId: String?
    @Published var currentMessage: String = ""
    @Published var currentSessionId: String = ""
    @Published var currentToolName: String = ""
    @Published var currentEventName: String = ""
    @Published var timeoutProgress: Double = 1.0
    @Published var pendingCount: Int = 0
    @Published var pendingItems: [PendingItem] = []
    @Published var activeSessions: [ActiveSession] = [] {
        didSet {
            // 선택된 세션이 더 이상 존재하지 않으면 초기화
            if let selected = selectedSessionId, !activeSessions.contains(where: { $0.id == selected }) {
                selectedSessionId = activeSessions.first?.id
            }
        }
    }
    
    @Published var autoApproveSafeTools = false {
        didSet {
            userDefaults.set(autoApproveSafeTools, forKey: DefaultsKey.autoApproveSafeTools)
        }
    }
    
    @Published var emulateGeminiInteractiveMode = false {
        didSet {
            userDefaults.set(emulateGeminiInteractiveMode, forKey: DefaultsKey.emulateGeminiInteractiveMode)
        }
    }
    
    // TODO(gap-3): globalAutoApproveTypes and sessionAutoApproveTypes are in-memory Sets
    //   (globalAutoApproveTypes persisted to UserDefaults only). Claude and Gemini approvals
    //   currently write here instead of SQLiteApprovalStore. Consequence: rules vanish on restart
    //   and are invisible to the Approval Rules UI.
    //   Target: route Claude/Gemini approve() through ApprovalProxyController.store.insertRule()
    //   so all providers share a single SQLite source of truth (rules + session_cache tables).
    //   See AGENTS.md "Approval Proxy Architecture → Known Gaps" for the full gap list.
    @Published var globalAutoApproveTypes: Set<String> = [] {
        didSet {
            userDefaults.set(Array(globalAutoApproveTypes), forKey: DefaultsKey.globalAutoApproveTypes)
        }
    }
    @Published var sessionAutoApproveTypes: [String: Set<String>] = [:]

    private static let genericTitles: Set<String> = ["Terminal", "iTerm", "Ghostty", "Warp", ""]
    private static let bypassTools: Set<String> = ["update_topic", "activate_skill"]

    private let approvalProxy: ApprovalProxyController?
    private var server = HookSocketServer()
    private var pendingQueue: [PendingRequest] = []
    private var currentResponseHandler: ((String) -> Void)?
    var hasResponseHandler: Bool { currentResponseHandler != nil }
    private var currentAgentKind: BuddyKind?
    private var currentRawToolName: String = ""
    private var currentWorkspaceRoot: String?
    private var currentHookEventId: Int64?
    private var isShowingRequest = false
    private var showingRequestId: UUID?
    private var timeoutTimer: Timer?
    private var notificationTimer: Timer?
    private var sessionPruningTimer: Timer?
    private let approvalPersistenceQueue = DispatchQueue(label: "DevIsland.ApprovalPersistence", qos: .utility)
    private var ptyOutputBuffers: [String: String] = [:]
    private let ptyBufferLock = NSLock()
    private let timeoutDuration: Double = 120
    private let lifecycleSessionTimeout: Double = 15 * 60
    private static let replayTerminalApp = "DevIsland Replay"
    private static let replayTimestampFormatter = ISO8601DateFormatter()

    init(
        startServer: Bool = true,
        userDefaults: UserDefaults = .standard,
        frontmostCheck: @escaping FrontmostCheck = TerminalFocuser.isSessionFrontmost,
        approvalProxy: ApprovalProxyController? = nil,
        codexRuleSyncAdapter: CodexRuleSyncAdapter = CodexJSONRuleSyncAdapter()
    ) {
        self.userDefaults = userDefaults
        self.frontmostCheck = frontmostCheck
        self.approvalProxy = approvalProxy
        self.codexRuleSyncAdapter = codexRuleSyncAdapter
        
        if let rawTarget = userDefaults.string(forKey: "displayTarget"), // Migration check
           let target = NotchDisplayTarget(rawValue: rawTarget) {
            notchDisplayTarget = target
        } else if let rawTarget = userDefaults.string(forKey: DefaultsKey.notchDisplayTarget),
                  let target = NotchDisplayTarget(rawValue: rawTarget) {
            notchDisplayTarget = target
        }
        
        selectedDisplayId = UInt32(userDefaults.integer(forKey: DefaultsKey.selectedDisplayId))
        if userDefaults.object(forKey: DefaultsKey.showInFullScreenApps) != nil {
            showInFullScreenApps = userDefaults.bool(forKey: DefaultsKey.showInFullScreenApps)
        }
        if let rawTarget = userDefaults.string(forKey: DefaultsKey.requestDisplayTarget),
           let target = RequestDisplayTarget(rawValue: rawTarget) {
            requestDisplayTarget = target
        }
        if let savedAutoApprove = userDefaults.array(forKey: DefaultsKey.globalAutoApproveTypes) as? [String] {
            globalAutoApproveTypes = Set(savedAutoApprove)
        }
        autoApproveSafeTools = userDefaults.bool(forKey: DefaultsKey.autoApproveSafeTools)
        emulateGeminiInteractiveMode = userDefaults.bool(forKey: DefaultsKey.emulateGeminiInteractiveMode)
        ensureSelectedDisplay()

        if startServer {
            BridgeTokenManager.shared.generateIfNeeded()

            server.onMessageReceived = { [weak self] message, requestId, responseHandler in
                // Wrap responseHandler to produce a rich response for framed (v1 envelope) requests.
                let effectiveHandler: (String) -> Void
                if let rid = requestId {
                    let providerContext = Self.providerContext(fromEnvelopeMessage: message)
                    effectiveHandler = { rawResponse in
                        responseHandler(Self.richResponseString(
                            fromLegacyResponse: rawResponse,
                            requestId: rid,
                            source: providerContext.source,
                            event: providerContext.event,
                            toolName: providerContext.toolName,
                            ruleContent: providerContext.ruleContent,
                            toolInput: providerContext.toolInput,
                            claudeSessionApprovalMode: Self.currentClaudeSessionApprovalMode(),
                            claudePersistentApprovalDestination: Self.currentClaudePersistentApprovalDestination()
                        ))
                    }
                } else {
                    effectiveHandler = responseHandler
                }
                self?.handleMessage(message, responseHandler: effectiveHandler)
            }
            server.onServerFailed = {
                print("[DevIsland] [ERROR] Socket server failed. Check if port 9090 is occupied.")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Server Error"
                    alert.informativeText = "Could not start the 9090 port server. Please ensure no other DevIsland instances are running."
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "Exit")
                    alert.runModal()
                    NSApplication.shared.terminate(nil)
                }
            }
            server.start(transport: Self.currentBridgeTransport())
            GlobalShortcutManager.shared.start()
            
            // Prune inactive sessions every 10 seconds
            sessionPruningTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.pruneInactiveSessions()
            }
        }
    }

    static func richResponseString(
        fromLegacyResponse rawResponse: String,
        requestId: String,
        source: String? = nil,
        event: String? = nil,
        toolName: String? = nil,
        ruleContent: String? = nil,
        toolInput: [String: AnyJSON]? = nil,
        claudeSessionApprovalMode: ClaudeSessionApprovalMode = .nativePermissions,
        claudePersistentApprovalDestination: ClaudePersistentApprovalDestination = .userSettings
    ) -> String {
        let parsed = try? JSONSerialization.jsonObject(with: Data(rawResponse.utf8)) as? [String: Any]
        let decision = parsed?["response"] as? String
        let approvalScope = (parsed?["approval_scope"] as? String).flatMap(RuleScope.init(rawValue:))
        let providerOutput: [String: AnyJSON]?
        if let source, let event {
            let denialMessage = parsed?["reason"] as? String ?? ProviderAdapter.denialMessage
            providerOutput = ProviderAdapter.providerOutput(
                decision: decision,
                event: event,
                source: source,
                approvalScope: approvalScope,
                toolName: (parsed?["tool_name"] as? String) ?? toolName,
                ruleContent: (parsed?["rule_content"] as? String) ?? ruleContent,
                toolInput: toolInput,
                claudeSessionApprovalMode: claudeSessionApprovalMode,
                claudePersistentApprovalDestination: claudePersistentApprovalDestination,
                denialMessage: denialMessage
            )
        } else {
            providerOutput = nil
        }
        let injection = parsed?["injection"] as? String
        let rich = IPCRichResponse(requestId: requestId, decision: decision, injection: injection, providerOutput: providerOutput)
        if let richData = try? JSONEncoder().encode(rich),
           let richString = String(data: richData, encoding: .utf8) {
            return richString
        }
        return rawResponse
    }

    static func providerContext(fromEnvelopeMessage message: String) -> (
        source: String?,
        event: String?,
        toolName: String?,
        ruleContent: String?,
        toolInput: [String: AnyJSON]?
    ) {
        guard let data = message.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(IPCEnvelope.self, from: data),
              envelope.protocol == IPCEnvelope.protocolName else {
            return (nil, nil, nil, nil, nil)
        }
        let event: String?
        if case .string(let hookEvent)? = envelope.payload["hook_event_name"] {
            event = hookEvent
        } else if case .string(let fallbackEvent)? = envelope.payload["event"] {
            event = fallbackEvent
        } else {
            event = nil
        }
        let toolName: String?
        if case .string(let payloadToolName)? = envelope.payload["tool_name"] {
            toolName = payloadToolName
        } else {
            toolName = nil
        }
        let ruleContent = Self.claudePermissionRuleContent(from: envelope.payload)
        let toolInput: [String: AnyJSON]?
        if case .object(let input)? = envelope.payload["tool_input"] {
            toolInput = input
        } else {
            toolInput = nil
        }
        return (envelope.source, event, toolName, ruleContent, toolInput)
    }

    private static func claudePermissionRuleContent(from payload: [String: AnyJSON]) -> String? {
        guard case .object(let toolInput)? = payload["tool_input"] else { return nil }
        if case .string(let command)? = toolInput["command"], !command.isEmpty {
            return command
        }
        if case .string(let filePath)? = toolInput["file_path"], !filePath.isEmpty {
            return filePath
        }
        if case .string(let pattern)? = toolInput["pattern"], !pattern.isEmpty {
            return pattern
        }
        return nil
    }

    private static func currentClaudeSessionApprovalMode() -> ClaudeSessionApprovalMode {
        let raw = UserDefaults.standard.string(forKey: "claudeSessionApprovalMode")
        return raw.flatMap(ClaudeSessionApprovalMode.init(rawValue:)) ?? AppSettings.defaults.claudeSessionApprovalMode
    }

    private static func currentClaudePersistentApprovalDestination() -> ClaudePersistentApprovalDestination {
        let raw = UserDefaults.standard.string(forKey: "claudePersistentApprovalDestination")
        return raw.flatMap(ClaudePersistentApprovalDestination.init(rawValue:)) ?? AppSettings.defaults.claudePersistentApprovalDestination
    }

    private static func currentBridgeTransport() -> HookIPCTransport {
        let transportRaw = UserDefaults.standard.string(forKey: SettingsStore.DefaultsKey.bridgeTransportKind)
        let transport = transportRaw.flatMap(BridgeTransportKind.init(rawValue:)) ?? AppSettings.defaults.bridgeTransportKind
        switch transport {
        case .tcpLoopback:
            let port = UserDefaults.standard.integer(forKey: SettingsStore.DefaultsKey.bridgeTcpPort)
            return .tcp(port: UInt16(port > 0 ? port : AppSettings.defaults.bridgeTcpPort))
        case .unixDomainSocket:
            let socketPath = UserDefaults.standard.string(forKey: SettingsStore.DefaultsKey.bridgeSocketPath)
            let path = socketPath.flatMap { $0.isEmpty ? nil : $0 } ?? AppSettings.defaults.bridgeSocketPath
            return .unix(path: path)
        }
    }

    private func ensureSelectedDisplay() {
        guard !NSScreen.screens.isEmpty,
              !NSScreen.screens.contains(where: { $0.displayId == selectedDisplayId }) else {
            return
        }
        selectedDisplayId = NSScreen.main?.displayId ?? NSScreen.screens[0].displayId
    }

    /// 현재 표시 중인 요청의 터미널이 포커스되었는지 확인하고, 그렇다면 자동으로 'pass' 또는 'dismiss' 처리
    func passIfTerminalFocused() {
        // 승인 대기 중이거나 정보성 알림이 표시 중일 때만 동작
        guard currentResponseHandler != nil || (isNotchExpanded && isExpandingFromRequest) else { return }
        
        let session = activeSessions.first { $0.id == currentSessionId }
        
        // 백그라운드에서 포커스 여부 확인 (UI 지연 방지)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isFrontmost = self?.isTerminalFrontmost(for: session) ?? false
            if isFrontmost {
                DispatchQueue.main.async {
                    if self?.currentResponseHandler != nil {
                        print("[DevIsland] [AUTO] User moved focus to terminal, auto-passing request for \(self?.currentSessionId.prefix(8) ?? "")")
                        self?.sendDecision(approved: false, reason: "ManualFocus", status: .timeoutBypassed(Date()), passToTerminal: true)
                    } else {
                        print("[DevIsland] [AUTO] User moved focus to terminal, auto-dismissing notification for \(self?.currentSessionId.prefix(8) ?? "")")
                        self?.isNotchExpanded = false
                        self?.isExpandingFromRequest = false
                    }
                }
            }
        }
    }

    /// 현재 화면에 표시할 데이터를 선택된 세션 정보로 업데이트
    func syncDisplayToSelectedSession() {
        guard currentResponseHandler == nil else { return }
        let sessionId = selectedSessionId ?? currentSessionId
        
        if let session = activeSessions.first(where: { $0.id == sessionId }) {
            DispatchQueue.main.async {
                guard self.currentResponseHandler == nil else { return }
                self.currentToolName = session.lastToolName
                self.currentEventName = session.lastEventName
                self.currentMessage = session.lastMessage
            }
        }
    }

    func handleMessage(_ message: String, responseHandler: @escaping (String) -> Void) {
        guard let rawData = message.data(using: .utf8) else { return }

        // Detect IPC protocol v1 envelope vs raw JSON.
        // Raw JSON always starts with '{' (0x7B); the HookSocketServer strips the
        // length-prefix before delivering framed payloads here as plain JSON strings.
        let parsedJSON: [String: Any]?
        let requestId: String?
        if let envelope = try? JSONDecoder().decode(IPCEnvelope.self, from: rawData),
           envelope.protocol == IPCEnvelope.protocolName {
            guard BridgeTokenManager.shared.validate(envelope.token) else {
                print("[DevIsland] IPC token validation failed – denying request")
                responseHandler("{\"response\": \"denied\"}")
                return
            }
            // Convert AnyJSON payload to [String: Any] directly — avoids encode+decode roundtrip.
            parsedJSON = envelope.payload.mapValues { $0.rawValue } as [String: Any]
            requestId = envelope.requestId
        } else {
            parsedJSON = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
            requestId = nil
        }

        var event     = "Unknown"
        var toolName  = ""
        var sessionId = ""
        var terminalTitle = "Terminal"
        var agentKind = BuddyKind.claudeCode
        var terminalApp = ""
        var terminalTTY = ""
        var terminalWindowId = ""
        var terminalTabIndex = ""
        var terminalTmuxPane = ""
        var terminalTmuxSocket = ""
        var terminalTmuxClient = ""
        var displayMsg = ""
        var notificationType = ""
        var isPlanAction = false
        var displayToolName = ""
        var workspaceRoot: String?
        var isReplayPayload = false

        if let json = parsedJSON {
                event     = (json["hook_event_name"] as? String) ?? (json["event"] as? String) ?? "Unknown"
                toolName  = json["tool_name"] as? String ?? ""
                sessionId = (json["session_id"] as? String) ?? (json["sessionId"] as? String) ?? ""
                print("[DevIsland] [MSG] Parsed JSON from \(sessionId.prefix(8))")
                terminalTitle = json["terminal_title"] as? String ?? "Terminal"
                terminalApp = json["terminal_app"] as? String ?? ""
                terminalTTY = json["terminal_tty"] as? String ?? ""
                terminalWindowId = json["terminal_window_id"] as? String ?? ""
                terminalTabIndex = json["terminal_tab_index"] as? String ?? ""
                terminalTmuxPane = json["terminal_tmux_pane"] as? String ?? ""
                terminalTmuxSocket = json["terminal_tmux_socket"] as? String ?? ""
                terminalTmuxClient = json["terminal_tmux_client"] as? String ?? ""
                workspaceRoot = json["cwd"] as? String
                notificationType = json["notification_type"] as? String ?? ""
                isReplayPayload = json["replay_origin_event_id"] != nil
                // osascript가 기본값을 반환하면 cwd 마지막 경로로 대체
                if Self.genericTitles.contains(terminalTitle), let cwd = json["cwd"] as? String {
                    let label = URL(fileURLWithPath: cwd).lastPathComponent
                    if !label.isEmpty && label != "/" { terminalTitle = label }
                }
                agentKind = Self.agentKind(from: json, terminalTitle: terminalTitle)
                let toolInput = json["tool_input"] as? [String: Any]
                
                // 제미나이의 계획(Plan) 작성인지 일반 코드 수정인지 구분하여 UI에 표시
                let filePath = toolInput?["file_path"] as? String ?? ""
                isPlanAction = filePath.contains(".gemini/tmp/")
                // UI 표시 전용 이름 — 로직 체크(auto-approve, ToolKnowledge 등)에는 toolName 원본 사용
                displayToolName = isPlanAction && (toolName == "write_file" || toolName == "replace")
                    ? toolName + " (Plan)"
                    : toolName

                print("Parsed Hook: event=\(event), session=\(sessionId), title=\(terminalTitle)")

                displayMsg = displayMessage(
                    for: toolName,
                    toolInput: toolInput,
                    json: json,
                    eventName: event
                )
        }

        // PTY output events are handled before hook_events recording to avoid polluting the replay log.
        if event == "PTYOutput" {
            handlePTYOutputEvent(
                sessionId: sessionId,
                provider: providerKind(for: agentKind),
                content: (parsedJSON?["content"] as? String) ?? "",
                responseHandler: responseHandler
            )
            return
        }

        let normalizedEvent = HookEventNormalizer.normalizedName(event)
        let hookEventId = recordReplayHookEvent(
            requestId: requestId,
            provider: providerKind(for: agentKind),
            sessionId: sessionId,
            eventName: event,
            toolName: toolName,
            payload: parsedJSON
        )
        if displayToolName.isEmpty {
            if normalizedEvent == "elicitation" {
                if let serverName = parsedJSON?["mcp_server_name"] as? String, !serverName.isEmpty {
                    displayToolName = "Elicitation (\(serverName))"
                } else {
                    displayToolName = "Elicitation"
                }
            } else if normalizedEvent == "userpromptsubmit" {
                displayToolName = "User Prompt"
            } else {
                displayToolName = toolName
            }
        }
        let stopEvents = ["exit", "shutdown", "sessionend"]
        let notificationEvents = [
            "sessionstart", "notification", "posttooluse", "precompact", "subagentstop",
            "startup", "init", "afteragent"
        ]
        let isUserQuestionTool = HookEventNormalizer.isUserQuestionTool(toolName)
        // approval:
        // - Claude/Codex: PermissionRequest only
        // - Gemini: BeforeTool only
        // User-question tools are shown as notifications even when delivered through an approval-capable hook.
        let isStop = stopEvents.contains(normalizedEvent)
        let isApproval = Self.isApprovalEvent(normalizedEvent, for: agentKind) && !isUserQuestionTool
        let isNotification = (!isStop && !isApproval) || notificationEvents.contains(normalizedEvent)
        let replayToolName = toolName.isEmpty ? displayToolName : toolName

        if isStop {
            guard !sessionId.isEmpty else {
                respondWithReplay(
                    "{\"response\": \"approved\"}",
                    responseHandler: responseHandler,
                    hookEventId: hookEventId,
                    agentKind: agentKind,
                    sessionId: sessionId,
                    toolName: replayToolName,
                    workspaceRoot: workspaceRoot,
                    action: .allow,
                    source: .automatic,
                    reason: "stop event"
                )
                return
            }
            let fullSessionId = sessionId
            DispatchQueue.main.async {
                let removedRequests = self.pendingQueue.filter { $0.sessionId == fullSessionId }
                removedRequests.forEach {
                    self.respondWithReplay(
                        "{\"response\": \"denied\"}",
                        responseHandler: $0.responseHandler,
                        hookEventId: $0.hookEventId,
                        agentKind: $0.agentKind,
                        sessionId: $0.sessionId,
                        toolName: $0.rawToolName.isEmpty ? $0.toolName : $0.rawToolName,
                        workspaceRoot: $0.workspaceRoot,
                        action: .deny,
                        source: .automatic,
                        reason: "session stopped"
                    )
                }
                self.pendingQueue.removeAll { $0.sessionId == fullSessionId }
                self.pendingItems.removeAll { $0.sessionId == fullSessionId }
                self.pendingCount = self.pendingQueue.count
                self.activeSessions.removeAll { $0.id == fullSessionId }
                self.sessionAutoApproveTypes.removeValue(forKey: fullSessionId)

                if self.currentSessionId == fullSessionId || removedRequests.contains(where: { $0.id == self.showingRequestId }) {
                    self.currentResponseHandler = nil
                    self.isShowingRequest = false
                    self.showingRequestId = nil
                    self.timeoutTimer?.invalidate()
                    self.timeoutProgress = 1.0
                    self.currentSessionId = ""
                    self.currentToolName = ""
                    self.currentEventName = ""
                    self.currentMessage = ""
                }

                if self.selectedSessionId == fullSessionId {
                    self.selectedSessionId = self.activeSessions.first?.id
                }

                if self.pendingQueue.isEmpty {
                    self.isNotchExpanded = false
                    self.syncDisplayToSelectedSession()
                } else if self.currentResponseHandler == nil {
                    self.showNextRequest()
                }
            }
            respondWithReplay(
                "{\"response\": \"approved\"}",
                responseHandler: responseHandler,
                hookEventId: hookEventId,
                agentKind: agentKind,
                sessionId: sessionId,
                toolName: replayToolName,
                workspaceRoot: workspaceRoot,
                action: .allow,
                source: .automatic,
                reason: "stop event"
            )
            return
        }

        if normalizedEvent == "userpromptsubmit", agentKind == .claudeCode,
           let prompt = parsedJSON?["prompt"] as? String,
           let denialReason = ClaudePromptPolicy.denialReason(for: prompt) {
            print("[DevIsland] Claude UserPromptSubmit blocked by prompt policy")
            let responsePayload: [String: Any] = [
                "response": "denied",
                "reason": denialReason
            ]
            if let data = try? JSONSerialization.data(withJSONObject: responsePayload),
               let payload = String(data: data, encoding: .utf8) {
                respondWithReplay(
                    payload,
                    responseHandler: responseHandler,
                    hookEventId: hookEventId,
                    agentKind: agentKind,
                    sessionId: sessionId,
                    toolName: replayToolName,
                    workspaceRoot: workspaceRoot,
                    action: .deny,
                    source: .automatic,
                    reason: denialReason
                )
            } else {
                respondWithReplay(
                    "{\"response\":\"denied\"}",
                    responseHandler: responseHandler,
                    hookEventId: hookEventId,
                    agentKind: agentKind,
                    sessionId: sessionId,
                    toolName: replayToolName,
                    workspaceRoot: workspaceRoot,
                    action: .deny,
                    source: .automatic,
                    reason: denialReason
                )
            }
            return
        }

        if isNotification {
            print("[DevIsland] notification event: \(event) for \(toolName) → auto-approved")
            guard !sessionId.isEmpty else {
                respondWithReplay(
                    "{\"response\": \"approved\"}",
                    responseHandler: responseHandler,
                    hookEventId: hookEventId,
                    agentKind: agentKind,
                    sessionId: sessionId,
                    toolName: replayToolName,
                    workspaceRoot: workspaceRoot,
                    action: .allow,
                    source: .automatic,
                    reason: "notification"
                )
                return
            }
            if normalizedEvent == "notification",
               notificationType == "permission_prompt" || displayMsg.lowercased().contains("needs your permission") {
                respondWithReplay(
                    "{\"response\": \"approved\"}",
                    responseHandler: responseHandler,
                    hookEventId: hookEventId,
                    agentKind: agentKind,
                    sessionId: sessionId,
                    toolName: replayToolName,
                    workspaceRoot: workspaceRoot,
                    action: .allow,
                    source: .automatic,
                    reason: "permission prompt notification"
                )
                return
            }
            let fullSessionId = sessionId
            let hasPendingForSession = self.pendingQueue.contains { $0.sessionId == fullSessionId }
            let isStartEvent = (normalizedEvent == "sessionstart" || normalizedEvent == "startup" || normalizedEvent == "init")
            
            // [UX] 에이전트 작업 완료 대기 상태(Idle Prompt) 판별 로직
            // - Claude Code: notification 훅에 idle_prompt 또는 input_required 타입으로 전달됨
            // - Gemini CLI: afteragent, aftermodel 등 턴 종료 시 발생하는 훅을 대기 상태로 간주
            // - Codex CLI: posttooluse를 쓰면 툴 연속 자동 실행 시 스팸 알림이 생기므로 제외함. 대신 stop 이벤트를 통해 완료됨을 알림
            let isIdlePrompt = (normalizedEvent == "notification" && (notificationType == "idle_prompt" || notificationType == "input_required")) ||
                               normalizedEvent == "afteragent"
            
            let sessionMessage: String
            if isStartEvent {
                sessionMessage = "Session Started"
            } else if isIdlePrompt && displayMsg.isEmpty {
                sessionMessage = "Waiting for next prompt..."
            } else if (normalizedEvent == "stop" && displayMsg.isEmpty) {
                sessionMessage = "Task Completed"
            } else {
                sessionMessage = displayMsg
            }
            
            self.updateActiveSession(
                sessionId: fullSessionId,
                terminalTitle: terminalTitle,
                agentKind: agentKind,
                terminalApp: terminalApp,
                terminalTTY: terminalTTY,
                terminalWindowId: terminalWindowId,
                terminalTabIndex: terminalTabIndex,
                terminalTmuxPane: terminalTmuxPane,
                terminalTmuxSocket: terminalTmuxSocket,
                terminalTmuxClient: terminalTmuxClient,
                toolName: displayToolName,
                eventName: event,
                message: sessionMessage,
                isPending: hasPendingForSession,
                preserveMessage: (normalizedEvent == "pretooluse" || normalizedEvent == "posttooluse") || sessionMessage.isEmpty,
                isLifecycleTracked: isStartEvent || agentKind != .claudeCode // Codex/Gemini는 기본적으로 추적 유지
            )

            DispatchQueue.main.async {
                if isStartEvent || (self.selectedSessionId == nil) {
                    self.selectedSessionId = fullSessionId
                }
                
                // 알림 확장 로직 (질문이나 작업 완료 시)
                let isInformational = (normalizedEvent == "stop" || isStartEvent) || isIdlePrompt ||
                                     isUserQuestionTool ||
                                     (displayMsg.contains("?") && (normalizedEvent == "notification" || agentKind != .claudeCode))
                
                if isInformational && !hasPendingForSession && self.currentResponseHandler == nil {
                    // 터미널이 포커스되어 있지 않을 때만 확장
                    let session = self.activeSessions.first { $0.id == fullSessionId }
                    let isFrontmost = self.isTerminalFrontmost(for: session)
                    
                    if !isFrontmost {
                        self.currentToolName = displayToolName
                        self.currentEventName = event
                        self.currentMessage = sessionMessage
                        self.currentSessionId = fullSessionId
                        self.isNotchExpanded = true
                        self.isExpandingFromRequest = true
                        
                        // 알림 유지 시간 확보 (최소 5초)
                        self.notificationTimer?.invalidate()
                        self.notificationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                            if self?.currentResponseHandler == nil && self?.isNotchExpanded == true {
                                self?.isNotchExpanded = false
                                self?.isExpandingFromRequest = false
                            }
                        }
                    }
                }
            }

            respondWithReplay(
                "{\"response\": \"approved\"}",
                responseHandler: responseHandler,
                hookEventId: hookEventId,
                agentKind: agentKind,
                sessionId: sessionId,
                toolName: replayToolName,
                workspaceRoot: workspaceRoot,
                action: .allow,
                source: .automatic,
                reason: "notification"
            )
            return
        }

        let isGeminiNormalMode = agentKind == .gemini && !emulateGeminiInteractiveMode
        
        guard isApproval && !isGeminiNormalMode else {
            print("[DevIsland] ignoring non-approval event (or Gemini normal mode): \(event)")
            respondWithReplay(
                "{\"response\": \"approved\"}",
                responseHandler: responseHandler,
                hookEventId: hookEventId,
                agentKind: agentKind,
                sessionId: sessionId,
                toolName: replayToolName,
                workspaceRoot: workspaceRoot,
                action: .allow,
                source: .automatic,
                reason: isGeminiNormalMode ? "Gemini normal mode notification" : "non-approval event"
            )
            return
        }

        guard !toolName.isEmpty || !displayMsg.isEmpty else {
            print("[DevIsland] ignoring empty approval request")
            respondWithReplay(
                "{\"response\": \"approved\"}",
                responseHandler: responseHandler,
                hookEventId: hookEventId,
                agentKind: agentKind,
                sessionId: sessionId,
                toolName: replayToolName,
                workspaceRoot: workspaceRoot,
                action: .allow,
                source: .automatic,
                reason: "empty approval request"
            )
            return
        }

        let request = PendingRequest(
            hookEventId: hookEventId,
            sessionId: sessionId,
            agentKind: agentKind,
            eventName: event,
            toolName: displayToolName,
            rawToolName: toolName,
            workspaceRoot: workspaceRoot,
            isReplay: isReplayPayload,
            message: displayMsg,
            responseHandler: responseHandler,
            receivedAt: Date()
        )

        // [디자인 결정] 툴 필터링 및 자동 승인 전략
        // -------------------------------------------------------------------
        // 1. 완전 무시 (Bypass): 시스템에 영향이 없는 순수 내부 상태/UI 업데이트 툴들.
        //    - 브릿지가 아닌 앱 단계에서 처리하는 이유: 앱이 에이전트의 현재 진행 상태를 계속 추적하여
        //      UI를 동기화하고 세션 상태(예: Auto-Edit 모드 여부)를 관리해야 하기 때문입니다.
        let bypassTools: Set<String> = ["update_topic", "activate_skill"]

        // 2. 터미널 유도 알림 (Interactive): 사용자가 터미널에서 직접 키보드 입력을 해야 하는 툴들.
        //    - 목적: "DevIsland에서 승인 클릭" + "터미널에서 Y/Enter 입력" 이라는 '이중 승인'의 번거로움을 해결합니다.
        //    - 동작: 앱에서는 즉시 승인(approved)을 보내어 터미널에 프롬프트가 즉시 뜨게 하되, 
        //           노치 UI를 펼쳐 사용자에게 터미널로 돌아가야 함을 알립니다.
        //    - 대상: 직접 입력(ask_user), 계획 승인(exit_plan_mode), 자체 보안 정책상 터미널 확인이 강제되는 툴(run_shell_command),
        //           그리고 계획 단계에서 발생하는 임시 파일 작업들(.gemini/tmp/).
        let isInteractive = ["ask_user", "exit_plan_mode", "run_shell_command"].contains(toolName) || isPlanAction
        
        // 자동 승인 여부 판단 (전역 설정 + 세션별 툴 등록 + 현재가 자동 편집 모드인지 + Safe 등급 툴 자동 승인 옵션)
        var isAutoApprovedGlobal = globalAutoApproveTypes.contains(toolName) || bypassTools.contains(toolName) || isInteractive
        let isAutoApprovedSession = sessionAutoApproveTypes[sessionId]?.contains(toolName) == true
        
        var isAutoEditActive = false
        if let session = activeSessions.first(where: { $0.id == sessionId }) {
            isAutoEditActive = session.isAutoEditActive
        }

        // 사용자가 메뉴에서 설정한 "Safe 등급 툴 자동 승인" 옵션 적용
        let isSafeAutoApprove = autoApproveSafeTools && (ToolKnowledge.risk(for: toolName) == .safe)

        // [핵심] 제미나이 일반 모드 에뮬레이션 로직
        // 제미나이 CLI가 --auto-approve나 --yolo로 실행되어 터미널 프롬프트가 뜨지 않는 상황일 때,
        // DevIsland가 'Interactive 모드'처럼 위험한 툴을 선별해서 승인 창을 띄웁니다.
        if emulateGeminiInteractiveMode && agentKind == .gemini {
            // 사용자가 명시적으로 추가한 글로벌/세션 자동 승인 툴은 에뮬레이션 모드라도 존중하여 패스시킵니다.
            let isExplicitlyApproved = globalAutoApproveTypes.contains(toolName) || isAutoApprovedSession
            
            // 위험한 툴이면서 사용자가 명시적으로 승인하지 않은 경우에만 자동 통과를 막고 승인을 강제합니다.
            if ToolKnowledge.risk(for: toolName) != .safe && !isExplicitlyApproved {
                isAutoApprovedGlobal = false
                isAutoEditActive = false
                print("[DevIsland] [EMULATION] Gemini interactive emulation forced for tool: \(toolName)")
            }
        }

        // Pass through check, policy, and auto-approve all run on main thread so that
        // frontmostCheck (NSAppleScript) executes safely and terminal focus always wins.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 1. 터미널 포커스 최우선 — 사용자가 이미 터미널에 있으면 CLI가 자체 처리하도록 pass
            let isFrontmost = !isReplayPayload && self.frontmostCheck(
                    terminalApp,
                    terminalTTY,
                    terminalWindowId,
                    terminalTabIndex,
                    terminalTmuxPane,
                    terminalTmuxSocket,
                    terminalTmuxClient
                )

            if isFrontmost {
                print("[DevIsland] [PASS] Terminal is frontmost, responding with 'pass' for session \(sessionId.prefix(8))")
                self.respondWithReplay(
                    "{\"response\": \"pass\"}",
                    responseHandler: request.responseHandler,
                    hookEventId: hookEventId,
                    agentKind: agentKind,
                    sessionId: sessionId,
                    toolName: replayToolName,
                    workspaceRoot: workspaceRoot,
                    action: .prompt,
                    source: .automatic,
                    reason: "terminal focused"
                )
                if !sessionId.isEmpty {
                    self.updateActiveSession(
                        sessionId: sessionId,
                        terminalTitle: terminalTitle,
                        agentKind: agentKind,
                        terminalApp: terminalApp,
                        terminalTTY: terminalTTY,
                        terminalWindowId: terminalWindowId,
                        terminalTabIndex: terminalTabIndex,
                        terminalTmuxPane: terminalTmuxPane,
                        terminalTmuxSocket: terminalTmuxSocket,
                        terminalTmuxClient: terminalTmuxClient,
                        toolName: displayToolName,
                        eventName: event,
                        message: displayMsg,
                        isPending: false,
                        status: SessionStatus.timeoutBypassed(Date())
                    )
                }
                return
            }

            // 2. SQLite policy rules (Codex only; other providers via in-memory sets below)
            if agentKind == .codex,
               let policyDecision = self.codexPolicyDecision(
                   hookEventId: hookEventId,
                   sessionId: sessionId,
                   toolName: toolName,
                   workspaceRoot: workspaceRoot
               ) {
                print("[DevIsland] [POLICY] Codex \(toolName) matched \(policyDecision.source.rawValue): \(policyDecision.action.rawValue)")
                request.responseHandler(self.responsePayload(approved: policyDecision.action == .allow))
                self.updateActiveSession(
                    sessionId: sessionId,
                    terminalTitle: terminalTitle,
                    agentKind: agentKind,
                    terminalApp: terminalApp,
                    terminalTTY: terminalTTY,
                    terminalWindowId: terminalWindowId,
                    terminalTabIndex: terminalTabIndex,
                    terminalTmuxPane: terminalTmuxPane,
                    terminalTmuxSocket: terminalTmuxSocket,
                    terminalTmuxClient: terminalTmuxClient,
                    toolName: displayToolName,
                    eventName: event,
                    message: "Policy \(policyDecision.action.rawValue): \(displayToolName)",
                    isPending: false,
                    preserveMessage: true,
                    isLifecycleTracked: true,
                    status: .policyApproved(Date())
                )
                return
            }

            // 3. In-memory auto-approve (global settings + session cache + auto-edit + safe-tool bypass)
            if isAutoApprovedGlobal || isAutoApprovedSession || isAutoEditActive || isSafeAutoApprove {
                print("[DevIsland] [AUTO-APPROVE] Tool \(toolName) is auto-approved for session \(sessionId.prefix(8)) (AutoEdit: \(isAutoEditActive), SafeBypass: \(isSafeAutoApprove))")
                self.respondWithReplay(
                    "{\"response\": \"approved\"}",
                    responseHandler: request.responseHandler,
                    hookEventId: hookEventId,
                    agentKind: agentKind,
                    sessionId: sessionId,
                    toolName: replayToolName,
                    workspaceRoot: workspaceRoot,
                    action: .allow,
                    source: .automatic,
                    reason: "auto-approved"
                )

                // Interactive 툴: 이미 포커스 체크 후 여기 도달했으므로 터미널이 비포커스 상태 → 알림 표시
                if isInteractive && !isReplayPayload {
                    self.isNotchExpanded = true
                    self.isExpandingFromRequest = true
                    self.currentSessionId = sessionId
                    self.currentMessage = "터미널 창을 확인해 주세요 (\(displayToolName))"
                }

                if toolName == "exit_plan_mode",
                   let index = self.activeSessions.firstIndex(where: { $0.id == sessionId }) {
                    self.activeSessions[index].isAutoEditActive = true
                    print("[DevIsland] [MODE] Session \(sessionId.prefix(8)) switched to Auto-Edit mode")
                }
                if toolName == "enter_plan_mode",
                   let index = self.activeSessions.firstIndex(where: { $0.id == sessionId }) {
                    self.activeSessions[index].isAutoEditActive = false
                    print("[DevIsland] [MODE] Session \(sessionId.prefix(8)) switched to Plan mode")
                }

                if !sessionId.isEmpty {
                    self.updateActiveSession(
                        sessionId: sessionId,
                        terminalTitle: terminalTitle,
                        agentKind: agentKind,
                        terminalApp: terminalApp,
                        terminalTTY: terminalTTY,
                        terminalWindowId: terminalWindowId,
                        terminalTabIndex: terminalTabIndex,
                        terminalTmuxPane: terminalTmuxPane,
                        terminalTmuxSocket: terminalTmuxSocket,
                        terminalTmuxClient: terminalTmuxClient,
                        toolName: displayToolName,
                        eventName: event,
                        message: isInteractive ? "터미널 확인 대기 중..." : "Auto-approved: \(displayToolName)",
                        isPending: false,
                        preserveMessage: true,
                        isLifecycleTracked: true,
                        status: .autoApproved(Date())
                    )
                }
                return
            }

            // 4. enter_plan_mode가 자동 승인 없이 UI로 넘어갈 때 Auto-Edit 해제
            if toolName == "enter_plan_mode",
               let index = self.activeSessions.firstIndex(where: { $0.id == sessionId }) {
                self.activeSessions[index].isAutoEditActive = false
                print("[DevIsland] [MODE] Session \(sessionId.prefix(8)) switched to Plan mode")
            }

            // 5. 승인 대기 큐에 추가
            self.pendingQueue.append(request)

            let newItem = PendingItem(
                id: request.id,
                toolName: request.toolName,
                message: request.message,
                sessionId: request.sessionId,
                terminalTitle: terminalTitle,
                terminalWindowId: terminalWindowId,
                terminalTabIndex: terminalTabIndex,
                terminalTmuxPane: terminalTmuxPane,
                terminalTmuxSocket: terminalTmuxSocket,
                terminalTmuxClient: terminalTmuxClient,
                receivedAt: request.receivedAt
            )
            self.pendingItems.append(newItem)
            self.pendingCount = self.pendingQueue.count

            if !request.sessionId.isEmpty {
                self.updateActiveSession(
                    sessionId: request.sessionId,
                    terminalTitle: terminalTitle,
                    agentKind: agentKind,
                    terminalApp: terminalApp,
                    terminalTTY: terminalTTY,
                    terminalWindowId: terminalWindowId,
                    terminalTabIndex: terminalTabIndex,
                    terminalTmuxPane: terminalTmuxPane,
                    terminalTmuxSocket: terminalTmuxSocket,
                    terminalTmuxClient: terminalTmuxClient,
                    toolName: request.toolName,
                    eventName: request.eventName,
                    message: request.message,
                    isPending: true,
                    isLifecycleTracked: agentKind != .claudeCode
                )

                self.selectedSessionId = request.sessionId
            }

            if self.currentResponseHandler == nil {
                self.showNextRequest()
            } else {
                self.syncDisplayToSelectedSession()
            }
        }
    }

    private static func isApprovalEvent(_ normalizedEvent: String, for agentKind: BuddyKind) -> Bool {
        HookEventNormalizer.isApprovalEvent(normalizedEvent, for: agentKind)
    }

    private func displayMessage(for toolName: String, toolInput: [String: Any]?, json: [String: Any], eventName: String) -> String {
        if HookEventNormalizer.normalizedName(eventName) == "userpromptsubmit",
           let prompt = json["prompt"] as? String {
            return prompt
        }

        if HookEventNormalizer.normalizedName(eventName) == "posttooluse" {
            return postToolMessage(from: json["tool_response"] as? [String: Any])
        }

        if let input = toolInput {
            let lowerToolName = toolName.lowercased()
            switch lowerToolName {
            // Claude Code
            case "bash":
                return joinedMessageLines([
                    input["description"] as? String,
                    input["command"] as? String
                ])
            case "write":
                return joinedMessageLines([
                    input["file_path"] as? String,
                    input["content"] as? String
                ])
            case "edit":
                return joinedMessageLines([
                    input["file_path"] as? String,
                    prefixedBlock("old", input["old_string"] as? String),
                    prefixedBlock("new", input["new_string"] as? String)
                ])
            case "multiedit":
                return multiEditMessage(from: input)
            case "read":
                return readMessage(from: input)
            case "webfetch":
                return joinedMessageLines([
                    input["url"] as? String,
                    input["prompt"] as? String
                ])
            
            // Gemini CLI
            case "run_shell_command":
                return joinedMessageLines([
                    input["description"] as? String,
                    input["command"] as? String
                ])
            case "write_file":
                return joinedMessageLines([
                    input["file_path"] as? String,
                    input["content"] as? String
                ])
            case "read_file":
                return joinedMessageLines([
                    input["file_path"] as? String,
                    "lines: \(input["start_line"] ?? 1) - \(input["end_line"] ?? "")"
                ])
            case "replace":
                return joinedMessageLines([
                    input["file_path"] as? String,
                    input["instruction"] as? String,
                    prefixedBlock("old", input["old_string"] as? String),
                    prefixedBlock("new", input["new_string"] as? String)
                ])
            case "grep_search":
                return joinedMessageLines([
                    "pattern: \(input["pattern"] ?? "")",
                    "include: \(input["include_pattern"] ?? "")"
                ])
            case "glob":
                return "pattern: \(input["pattern"] ?? "")"
            case "web_fetch":
                return "prompt: \(input["prompt"] ?? "")"
                
            // Codex CLI
            case "shell":
                return input["command"] as? String ?? ""
            case "apply_patch":
                return joinedMessageLines([
                    input["path"] as? String,
                    input["patch"] as? String
                ])
                
            default:
                return input.keys.sorted().map { key in
                    "\(key): \(input[key] ?? "")"
                }.joined(separator: "\n")
            }
        }

        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }

        if let suggestions = json["permission_suggestions"] as? [[String: Any]] {
            return suggestions.compactMap { suggestion in
                suggestion["behavior"] as? String
            }.map { "Suggested: \($0)" }.joined(separator: "\n")
        }

        return ""
    }

    private func postToolMessage(from response: [String: Any]?) -> String {
        guard let response = response else { return "Completed" }
        if let stdout = response["stdout"] as? String, !stdout.isEmpty {
            return stdout
        }
        if let stderr = response["stderr"] as? String, !stderr.isEmpty {
            return stderr
        }
        return "Completed"
    }

    private func multiEditMessage(from input: [String: Any]) -> String {
        var lines: [String] = []
        if let filePath = input["file_path"] as? String {
            lines.append(filePath)
        }
        if let edits = input["edits"] as? [[String: Any]] {
            for (index, edit) in edits.enumerated() {
                lines.append("edit \(index + 1)")
                if let oldBlock = prefixedBlock("old", edit["old_string"] as? String) {
                    lines.append(oldBlock)
                }
                if let newBlock = prefixedBlock("new", edit["new_string"] as? String) {
                    lines.append(newBlock)
                }
            }
        }
        return joinedMessageLines(lines)
    }

    private func readMessage(from input: [String: Any]) -> String {
        var lines: [String] = []
        if let filePath = input["file_path"] as? String {
            lines.append(filePath)
        }
        let details = ["offset", "limit"].compactMap { key -> String? in
            guard let value = input[key] else { return nil }
            return "\(key): \(value)"
        }.joined(separator: ", ")
        if !details.isEmpty {
            lines.append(details)
        }
        return joinedMessageLines(lines)
    }

    private func prefixedBlock(_ label: String, _ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return "\(label):\n\(value)"
    }

    private func joinedMessageLines(_ lines: [String?]) -> String {
        lines.compactMap { line in
            guard let line = line?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
                return nil
            }
            return line
        }.joined(separator: "\n\n")
    }

    static func agentKind(from json: [String: Any], terminalTitle: String) -> BuddyKind {
        HookEventNormalizer.agentKind(from: json, terminalTitle: terminalTitle)
    }

    private func updateActiveSession(
        sessionId: String,
        terminalTitle: String,
        agentKind: BuddyKind,
        terminalApp: String,
        terminalTTY: String,
        terminalWindowId: String,
        terminalTabIndex: String,
        terminalTmuxPane: String,
        terminalTmuxSocket: String,
        terminalTmuxClient: String,
        toolName: String,
        eventName: String,
        message: String,
        isPending: Bool,
        preserveMessage: Bool = false,
        isLifecycleTracked: Bool = false,
        status: SessionStatus? = nil
    ) {
        if let index = activeSessions.firstIndex(where: { $0.id == sessionId }) {
            let shouldUpdateTitle = !Self.genericTitles.contains(terminalTitle)
                || Self.genericTitles.contains(activeSessions[index].terminalTitle)
            if shouldUpdateTitle {
                activeSessions[index].terminalTitle = terminalTitle
            }
            activeSessions[index].agentKind = agentKind
            if !terminalApp.isEmpty {
                activeSessions[index].terminalApp = terminalApp
            }
            if !terminalTTY.isEmpty {
                activeSessions[index].terminalTTY = terminalTTY
            }
            if !terminalWindowId.isEmpty {
                activeSessions[index].terminalWindowId = terminalWindowId
            }
            if !terminalTabIndex.isEmpty {
                activeSessions[index].terminalTabIndex = terminalTabIndex
            }
            if !terminalTmuxPane.isEmpty {
                activeSessions[index].terminalTmuxPane = terminalTmuxPane
            }
            if !terminalTmuxSocket.isEmpty {
                activeSessions[index].terminalTmuxSocket = terminalTmuxSocket
            }
            if !terminalTmuxClient.isEmpty {
                activeSessions[index].terminalTmuxClient = terminalTmuxClient
            }
            activeSessions[index].lastToolName = toolName
            activeSessions[index].lastEventName = eventName
            if !preserveMessage {
                activeSessions[index].lastMessage = message
            }
            activeSessions[index].lastActiveAt = Date()
            activeSessions[index].isPending = isPending
            activeSessions[index].status = status ?? (isPending ? .pending : .idle)
            if isLifecycleTracked {
                activeSessions[index].isLifecycleTracked = true
            }
        } else {
            let session = ActiveSession(
                id: sessionId,
                terminalTitle: terminalTitle,
                agentKind: agentKind,
                terminalApp: terminalApp,
                terminalTTY: terminalTTY,
                terminalWindowId: terminalWindowId,
                terminalTabIndex: terminalTabIndex,
                terminalTmuxPane: terminalTmuxPane,
                terminalTmuxSocket: terminalTmuxSocket,
                terminalTmuxClient: terminalTmuxClient,
                lastToolName: toolName,
                lastEventName: eventName,
                lastMessage: message,
                startTime: Date(),
                lastActiveAt: Date(),
                isPending: isPending,
                isLifecycleTracked: isLifecycleTracked,
                isAutoEditActive: false,
                status: status ?? (isPending ? .pending : .idle)
            )
            activeSessions.insert(session, at: 0)
        }
    }

    private func pruneInactiveSessions() {
        let now = Date()
        let threshold: TimeInterval = self.timeoutDuration
        
        DispatchQueue.main.async {
            let sessionsToPrune = self.activeSessions.filter { session in
                let inactiveFor = now.timeIntervalSince(session.lastActiveAt)
                let maxInactiveDuration = session.isLifecycleTracked ? self.lifecycleSessionTimeout : threshold
                return !session.isPending && inactiveFor > maxInactiveDuration
            }
            
            for session in sessionsToPrune {
                self.sessionAutoApproveTypes.removeValue(forKey: session.id)
            }
            
            self.activeSessions.removeAll { session in
                sessionsToPrune.contains(where: { $0.id == session.id })
            }
        }
    }

    func dismissSession(_ sessionId: String) {
        DispatchQueue.main.async {
            let removedRequests = self.pendingQueue.filter { $0.sessionId == sessionId }
            removedRequests.forEach { $0.responseHandler("{\"response\": \"pass\"}") }
            self.pendingQueue.removeAll { $0.sessionId == sessionId }
            self.pendingItems.removeAll { $0.sessionId == sessionId }
            self.pendingCount = self.pendingQueue.count
            self.sessionAutoApproveTypes.removeValue(forKey: sessionId)
            self.activeSessions.removeAll { $0.id == sessionId }

            if self.currentSessionId == sessionId || removedRequests.contains(where: { $0.id == self.showingRequestId }) {
                self.currentResponseHandler?("{\"response\": \"pass\"}")
                self.currentResponseHandler = nil
                self.isShowingRequest = false
                self.showingRequestId = nil
                self.timeoutTimer?.invalidate()
                self.timeoutProgress = 1.0
                self.currentSessionId = ""
                self.currentToolName = ""
                self.currentEventName = ""
                self.currentMessage = ""
            }

            if self.selectedSessionId == sessionId {
                self.selectedSessionId = self.activeSessions.first?.id
            }

            if self.pendingQueue.isEmpty {
                if self.activeSessions.isEmpty {
                    self.isNotchExpanded = false
                    self.selectedSessionId = nil
                }
                self.syncDisplayToSelectedSession()
            } else if self.currentResponseHandler == nil {
                self.showNextRequest()
            }
        }
    }

    private func showNextRequest() {
        discardInvalidPendingRequests()

        guard let next = pendingQueue.first else {
            currentResponseHandler = nil
            isShowingRequest = false
            showingRequestId = nil
            timeoutTimer?.invalidate()
            timeoutProgress = 1.0
            currentEventName = ""
            currentToolName = ""
            currentRawToolName = ""
            currentAgentKind = nil
            currentWorkspaceRoot = nil
            currentHookEventId = nil
            currentMessage = ""
            currentSessionId = ""
            selectedSessionId = nil
            isNotchExpanded = false
            return
        }

        if isShowingRequest { return }
        isShowingRequest = true
        showingRequestId = next.id

        let session = activeSessions.first { $0.id == next.sessionId }

        // NSAppleScript는 메인 스레드에서만 안전하게 실행 가능 (Apple 문서)
        // showNextRequest()는 항상 메인 스레드에서 호출되므로 동기 호출로 충분
        let isFrontmost = isTerminalFrontmost(for: session)

        if isFrontmost && !next.isReplay {
            print("[DevIsland] [AUTO] Terminal focused, bypassing pending request for \(next.sessionId.prefix(8))")
            currentResponseHandler = next.responseHandler
            currentSessionId = next.sessionId
            currentRawToolName = next.rawToolName
            currentAgentKind = next.agentKind
            currentWorkspaceRoot = next.workspaceRoot
            currentHookEventId = next.hookEventId
            sendDecision(approved: false, reason: "TerminalFocused", status: .timeoutBypassed(Date()), passToTerminal: true)
            return
        }

        print("[DevIsland] showNextRequest: showing \(next.eventName)/\(next.toolName) id=\(next.id)")
        currentResponseHandler = next.responseHandler
        currentEventName  = next.eventName
        currentToolName   = next.toolName
        currentRawToolName = next.rawToolName
        currentAgentKind  = next.agentKind
        currentWorkspaceRoot = next.workspaceRoot
        currentHookEventId = next.hookEventId
        currentMessage    = next.message
        currentSessionId  = next.sessionId

        isExpandingFromRequest = true
        isNotchExpanded = true
        startTimeout()
    }

    private func isTerminalFrontmost(for session: ActiveSession?) -> Bool {
        self.frontmostCheck(
            session?.terminalApp,
            session?.terminalTTY,
            session?.terminalWindowId,
            session?.terminalTabIndex,
            session?.terminalTmuxPane,
            session?.terminalTmuxSocket,
            session?.terminalTmuxClient
        )
    }

    private func discardInvalidPendingRequests() {
        while let next = pendingQueue.first, !isValidApprovalRequest(next) {
            let removed = pendingQueue.removeFirst()
            pendingItems.removeAll { $0.id == removed.id }
            removed.responseHandler("{\"response\": \"approved\"}")
        }
        pendingCount = pendingQueue.count
    }

    private func isValidApprovalRequest(_ request: PendingRequest) -> Bool {
        return Self.isApprovalEvent(HookEventNormalizer.normalizedName(request.eventName), for: request.agentKind)
            && (!request.toolName.isEmpty || !request.message.isEmpty)
    }

    private func recordReplayHookEvent(
        requestId: String?,
        provider: ProviderKind,
        sessionId: String,
        eventName: String,
        toolName: String,
        payload: [String: Any]?
    ) -> Int64? {
        guard let approvalProxy else { return nil }
        let payloadJSON = payload.map { Self.replayPayloadString(from: $0) } ?? "{}"
        var eventId: Int64?
        approvalPersistenceQueue.sync {
            do {
                eventId = try approvalProxy.recordHookEvent(
                    requestId: requestId,
                    provider: provider,
                    sessionId: sessionId,
                    eventName: eventName,
                    toolName: toolName,
                    payloadJSON: payloadJSON
                )
            } catch {
                print("[DevIsland] [REPLAY] Failed to record hook event: \(error)")
            }
        }
        return eventId
    }

    private func recordReplayDecision(
        hookEventId: Int64?,
        agentKind: BuddyKind?,
        sessionId: String,
        toolName: String,
        workspaceRoot: String?,
        action: RuleAction,
        source: ApprovalPolicyDecision.Source,
        reason: String?
    ) {
        guard let approvalProxy,
              let agentKind,
              !sessionId.isEmpty,
              !toolName.isEmpty else {
            return
        }
        let request = ApprovalPolicyRequest(
            provider: providerKind(for: agentKind),
            sessionId: sessionId,
            toolName: toolName,
            workspaceRoot: workspaceRoot
        )
        let decision = ApprovalPolicyDecision(action: action, source: source, ruleId: nil)
        approvalPersistenceQueue.sync {
            do {
                try approvalProxy.recordDecision(
                    hookEventId: hookEventId,
                    request: request,
                    decision: decision,
                    reason: reason
                )
            } catch {
                print("[DevIsland] [REPLAY] Failed to record decision: \(error)")
            }
        }
    }

    private func respondWithReplay(
        _ payload: String,
        responseHandler: (String) -> Void,
        hookEventId: Int64?,
        agentKind: BuddyKind,
        sessionId: String,
        toolName: String,
        workspaceRoot: String?,
        action: RuleAction,
        source: ApprovalPolicyDecision.Source,
        reason: String? = nil
    ) {
        responseHandler(payload)
        recordReplayDecision(
            hookEventId: hookEventId,
            agentKind: agentKind,
            sessionId: sessionId,
            toolName: toolName,
            workspaceRoot: workspaceRoot,
            action: action,
            source: source,
            reason: reason
        )
    }

    private static func replayPayloadString(from payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func providerKind(for agentKind: BuddyKind) -> ProviderKind {
        switch agentKind {
        case .claudeCode:
            return .claude
        case .codex:
            return .codex
        case .gemini:
            return .gemini
        case .island:
            return .any
        }
    }

    private func codexPolicyDecision(
        hookEventId: Int64?,
        sessionId: String,
        toolName: String,
        workspaceRoot: String?
    ) -> ApprovalPolicyDecision? {
        guard let approvalProxy, !sessionId.isEmpty, !toolName.isEmpty else { return nil }
        do {
            let request = ApprovalPolicyRequest(
                provider: .codex,
                sessionId: sessionId,
                toolName: toolName,
                workspaceRoot: workspaceRoot
            )
            let decision = try approvalProxy.evaluate(request)
            guard decision.action != .prompt else { return nil }
            try approvalProxy.recordDecision(
                hookEventId: hookEventId,
                request: request,
                decision: decision,
                reason: "matched \(decision.source.rawValue)"
            )
            return decision
        } catch {
            print("[DevIsland] [POLICY] Codex policy evaluation failed: \(error)")
            return nil
        }
    }

    private func responsePayload(approved: Bool) -> String {
        approved ? "{\"response\":\"approved\"}" : "{\"response\":\"denied\"}"
    }

    func codexPersistentRules() throws -> [ApprovalRule] {
        guard let approvalProxy else { return [] }
        return try approvalProxy.store.rules(provider: .codex, scope: .persistent)
    }

    func replayLogEntries(limit: Int = 200) throws -> [ReplayLogEntry] {
        guard let approvalProxy else { return [] }
        return try approvalProxy.replayLog(limit: limit)
    }

    func addPersistentRule(from entry: ReplayLogEntry, action: RuleAction) throws {
        guard let approvalProxy else { return }
        let toolName = entry.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else { return }
        try approvalProxy.store.insertRule(ApprovalRule(
            id: SQLiteApprovalStore.deterministicRuleID(
                provider: entry.provider,
                toolName: toolName,
                scope: .persistent,
                workspaceRoot: nil
            ),
            provider: entry.provider,
            toolName: toolName,
            action: action,
            scope: .persistent
        ))
    }

    func replayHookEvent(_ entry: ReplayLogEntry) throws {
        guard let data = entry.payloadJSON.data(using: .utf8),
              var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "ReplayLog",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Replay payload is not valid JSON."]
            )
        }

        let hasHookEventName = (payload["hook_event_name"] as? String).map { !$0.isEmpty } ?? false
        let hasEventName = (payload["event"] as? String).map { !$0.isEmpty } ?? false
        let hasToolName = (payload["tool_name"] as? String).map { !$0.isEmpty } ?? false
        let hasSessionId = (payload["session_id"] as? String).map { !$0.isEmpty } ?? false
        let hasSessionIdAlias = (payload["sessionId"] as? String).map { !$0.isEmpty } ?? false
        let hasCLISource = (payload["cli_source"] as? String).map { !$0.isEmpty } ?? false

        if !hasHookEventName && !hasEventName {
            payload["hook_event_name"] = entry.eventName
        }
        if !hasToolName {
            payload["tool_name"] = entry.toolName
        }
        if !hasSessionId && !hasSessionIdAlias {
            payload["session_id"] = entry.sessionId
        }
        if !hasCLISource {
            payload["cli_source"] = entry.provider.rawValue
        }
        payload["terminal_title"] = "Replay Log"
        payload["terminal_app"] = Self.replayTerminalApp
        payload["terminal_tty"] = ""
        payload["terminal_window_id"] = ""
        payload["terminal_tab_index"] = ""
        payload["terminal_tmux_pane"] = ""
        payload["terminal_tmux_socket"] = ""
        payload["terminal_tmux_client"] = ""
        payload["replay_origin_event_id"] = entry.id
        payload["replay_origin_received_at"] = Self.replayTimestampFormatter.string(from: entry.receivedAt)

        guard JSONSerialization.isValidJSONObject(payload),
              let replayData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let replayMessage = String(data: replayData, encoding: .utf8) else {
            throw NSError(
                domain: "ReplayLog",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Replay payload could not be serialized."]
            )
        }

        handleMessage(replayMessage) { response in
            print("[DevIsland] [REPLAY] Replayed event \(entry.id) completed with response: \(response)")
        }
    }

    func addCodexPersistentRule(toolName: String, action: RuleAction) throws {
        guard let approvalProxy else { return }
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try approvalProxy.store.insertRule(ApprovalRule(
            id: SQLiteApprovalStore.deterministicRuleID(
                provider: .codex,
                toolName: trimmed,
                scope: .persistent,
                workspaceRoot: nil
            ),
            provider: .codex,
            toolName: trimmed,
            action: action,
            scope: .persistent
        ))
    }

    func deleteCodexPersistentRule(_ rule: ApprovalRule) throws {
        guard let approvalProxy else { return }
        try approvalProxy.store.deleteRule(id: rule.id)
    }

    func syncCodexPersistentRules() throws -> CodexRuleSyncResult {
        try codexRuleSyncAdapter.sync(rules: codexPersistentRules(), generatedAt: Date())
    }

    func flushApprovalPersistenceForTesting() {
        approvalPersistenceQueue.sync {}
    }

    func ptyMessages(sessionId: String? = nil, limit: Int = 500) throws -> [PTYMessage] {
        guard let approvalProxy else { return [] }
        return try approvalProxy.ptyMessages(sessionId: sessionId, limit: limit)
    }

    private func handlePTYOutputEvent(
        sessionId: String,
        provider: ProviderKind,
        content: String,
        responseHandler: (String) -> Void
    ) {
        guard Self.currentPTYEnabled(), !content.isEmpty else {
            responseHandler("{\"response\":\"approved\"}")
            return
        }
        // Sliding window buffer: keep the last 1 KB per session so patterns that
        // span multiple os.read chunks (e.g. "Password:" split across two reads)
        // are still matched correctly.
        ptyBufferLock.lock()
        let combined = (ptyOutputBuffers[sessionId] ?? "") + content
        let window = combined.count > 1024 ? String(combined.suffix(1024)) : combined
        ptyOutputBuffers[sessionId] = window
        ptyBufferLock.unlock()

        let patterns = Self.currentPTYAutoInjectPatterns()
        let lowerWindow = window.lowercased()
        let matched = patterns.first { lowerWindow.contains($0.pattern.lowercased()) }
        let injectionText = matched?.response

        // Clear the buffer on match to prevent the same pattern from re-firing.
        if injectionText != nil {
            ptyBufferLock.lock()
            ptyOutputBuffers[sessionId] = ""
            ptyBufferLock.unlock()
        }

        approvalPersistenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.approvalProxy?.recordPTYMessage(
                    sessionId: sessionId,
                    provider: provider,
                    direction: .output,
                    content: content
                )
                if let injection = injectionText {
                    try self.approvalProxy?.recordPTYMessage(
                        sessionId: sessionId,
                        provider: provider,
                        direction: .input,
                        content: injection
                    )
                }
            } catch {
                print("[DevIsland] [PTY] Failed to record PTY message: \(error)")
            }
        }

        if let injection = injectionText {
            let resp: [String: Any] = ["response": "approved", "injection": injection]
            if let data = try? JSONSerialization.data(withJSONObject: resp),
               let str = String(data: data, encoding: .utf8) {
                responseHandler(str)
                return
            }
        }
        responseHandler("{\"response\":\"approved\"}")
    }

    private static func currentPTYEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: SettingsStore.DefaultsKey.ptyEnabled)
    }

    private static func currentPTYAutoInjectPatterns() -> [PTYAutoInjectPattern] {
        guard let data = UserDefaults.standard.data(forKey: SettingsStore.DefaultsKey.ptyAutoInjectPatterns),
              let patterns = try? JSONDecoder().decode([PTYAutoInjectPattern].self, from: data) else {
            return []
        }
        return patterns
    }

    private func startTimeout() {
        timeoutTimer?.invalidate()
        timeoutProgress = 1.0

        let interval: Double = 0.1
        var elapsed: Double = 0

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            elapsed += interval
            self.timeoutProgress = max(0, 1.0 - (elapsed / self.timeoutDuration))

            if elapsed >= self.timeoutDuration {
                timer.invalidate()
                if self.currentResponseHandler != nil {
                    self.sendDecision(approved: false, reason: "Timeout", status: .timeoutBypassed(Date()), passToTerminal: true)
                }
            }
        }
    }

    // TODO(gap-2): When claudeSessionApprovalMode is .appSessionCache or .hybrid,
    //   Claude approvals must also be written to SQLiteApprovalStore.session_cache.
    //   Currently only Codex approvals are persisted to the DB; Claude relies solely on
    //   updatedPermissions in the hook response (native mode) and has no DB record.
    //   Fix: after building providerOutput for Claude, insert into session_cache here
    //   so replay log and policy engine see a consistent history across providers.
    //   See AGENTS.md "Approval Proxy Architecture → Known Gaps" for the full gap list.
    private func sendDecision(
        approved: Bool,
        reason: String? = nil,
        status: SessionStatus? = nil,
        passToTerminal: Bool = false,
        approvalScope: RuleScope? = nil
    ) {
        let response = passToTerminal ? "pass" : approved ? "approved" : "denied"
        var responsePayload: [String: Any] = ["response": response]
        if let reason {
            responsePayload["reason"] = reason
        }
        if let approvalScope {
            responsePayload["approval_scope"] = approvalScope.rawValue
        }
        let data = try? JSONSerialization.data(withJSONObject: responsePayload)
        let payload = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"response\":\"\(response)\"}"
        print("[DevIsland] sendDecision approved=\(approved), handler=\(currentResponseHandler != nil ? "SET" : "NIL"), reason=\(reason ?? "none")")
        currentResponseHandler?(payload)
        print("[DevIsland] sendDecision: response payload sent")
        recordReplayDecision(
            hookEventId: currentHookEventId,
            agentKind: currentAgentKind,
            sessionId: currentSessionId,
            toolName: currentRawToolName.isEmpty ? currentToolName : currentRawToolName,
            workspaceRoot: currentWorkspaceRoot,
            action: passToTerminal ? .prompt : approved ? .allow : .deny,
            source: reason == nil ? .user : .automatic,
            reason: reason
        )
        persistCodexApprovalScope(approved: approved, approvalScope: approvalScope)
        currentResponseHandler = nil
        currentHookEventId = nil
        isShowingRequest = false
        showingRequestId = nil
        timeoutTimer?.invalidate()

        DispatchQueue.main.async {
            self.timeoutProgress = 1.0
            var completedSessionId: String?
            if !self.pendingQueue.isEmpty {
                let removed = self.pendingQueue.removeFirst()
                completedSessionId = removed.sessionId
                
                if !self.pendingItems.isEmpty { self.pendingItems.removeFirst() }
                self.pendingCount = self.pendingQueue.count
                
                // Update session state to not pending
                if !removed.sessionId.isEmpty, let index = self.activeSessions.firstIndex(where: { $0.id == removed.sessionId }) {
                    // Check if there are other pending items for this session
                    let stillPending = self.pendingQueue.contains { $0.sessionId == removed.sessionId }
                    if stillPending {
                        self.activeSessions[index].isPending = true
                        self.activeSessions[index].status = .pending
                    } else if status?.isTimeoutBypassed == true {
                        self.activeSessions[index].isPending = false
                        self.activeSessions[index].status = status ?? .idle
                        self.activeSessions[index].lastActiveAt = Date()
                    } else if !self.activeSessions[index].isLifecycleTracked {
                        self.activeSessions.remove(at: index)
                        if self.selectedSessionId == removed.sessionId {
                            self.selectedSessionId = nil
                        }
                    } else {
                        self.activeSessions[index].isPending = false
                        self.activeSessions[index].status = status ?? .idle
                        self.activeSessions[index].lastActiveAt = Date()
                    }
                }
            }
            self.showNextRequest()
            if status?.isTimeoutBypassed == true, self.pendingQueue.isEmpty, let completedSessionId {
                self.selectedSessionId = completedSessionId
                self.isNotchExpanded = false
            }
        }
    }

    private func persistCodexApprovalScope(approved: Bool, approvalScope: RuleScope?) {
        guard approved,
              currentAgentKind == .codex,
              let approvalScope,
              let approvalProxy,
              !currentSessionId.isEmpty,
              !currentRawToolName.isEmpty else {
            return
        }

        let sessionId = currentSessionId
        let toolName = currentRawToolName
        let workspaceRoot = currentWorkspaceRoot
        approvalPersistenceQueue.sync {
            persistCodexApprovalScopeOnPersistenceQueue(
                approvalProxy: approvalProxy,
                approvalScope: approvalScope,
                sessionId: sessionId,
                toolName: toolName,
                workspaceRoot: workspaceRoot
            )
        }
    }

    private func persistCodexApprovalScopeOnPersistenceQueue(
        approvalProxy: ApprovalProxyController,
        approvalScope: RuleScope,
        sessionId: String,
        toolName: String,
        workspaceRoot: String?
    ) {
        do {
            switch approvalScope {
            case .session:
                try approvalProxy.store.upsertSessionApproval(
                    provider: .codex,
                    sessionId: sessionId,
                    toolName: toolName,
                    action: .allow,
                    expiresAt: nil
                )
            case .persistent:
                try approvalProxy.store.insertRule(ApprovalRule(
                    id: SQLiteApprovalStore.deterministicRuleID(
                        provider: .codex,
                        toolName: toolName,
                        scope: .persistent,
                        workspaceRoot: workspaceRoot
                    ),
                    provider: .codex,
                    toolName: toolName,
                    action: .allow,
                    scope: .persistent,
                    workspaceRoot: workspaceRoot
                ))
            case .once:
                break
            }
        } catch {
            print("[DevIsland] [POLICY] Failed to persist Codex approval scope: \(error)")
        }
    }

    func approve(globalAlways: Bool = false, sessionAlways: Bool = false) {
        let tool = currentRawToolName.isEmpty ? currentToolName : currentRawToolName
        let sId = currentSessionId
        
        if globalAlways && !tool.isEmpty && currentAgentKind != .codex {
            globalAutoApproveTypes.insert(tool)
        }
        if sessionAlways && !tool.isEmpty && !sId.isEmpty && currentAgentKind != .codex {
            if sessionAutoApproveTypes[sId] == nil {
                sessionAutoApproveTypes[sId] = []
            }
            sessionAutoApproveTypes[sId]?.insert(tool)
        }

        print("[DevIsland] approve() called, handler=\(currentResponseHandler != nil ? "SET" : "NIL")")
        
        // exit_plan_mode를 수동으로 승인했을 때도 Auto-Edit 모드 활성화
        if tool == "exit_plan_mode" {
            if let index = activeSessions.firstIndex(where: { $0.id == sId }) {
                activeSessions[index].isAutoEditActive = true
                print("[DevIsland] [MODE] Session \(sId.prefix(8)) switched to Auto-Edit mode via manual approval")
            }
        }
        
        let approvalScope: RuleScope? = sessionAlways ? .session : globalAlways ? .persistent : nil
        sendDecision(approved: true, approvalScope: approvalScope)
    }

    func deny() {
        print("[DevIsland] deny() called")
        sendDecision(approved: false)
    }

    func promptToAddGlobalAutoApprove() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "글로벌 자동 승인 툴 추가"
            alert.informativeText = "모든 세션에서 자동 승인할 툴 이름(예: read_file)을 입력하세요."
            alert.addButton(withTitle: "추가")
            alert.addButton(withTitle: "취소")
            
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
            alert.accessoryView = input
            NSApp.activate(ignoringOtherApps: true)
            
            if alert.runModal() == .alertFirstButtonReturn {
                let toolName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !toolName.isEmpty {
                    self.globalAutoApproveTypes.insert(toolName)
                }
            }
        }
    }

    func promptToAddSessionAutoApprove(for sessionId: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "세션 자동 승인 툴 추가"
            alert.informativeText = "현재 세션(\(sessionId.prefix(8)))에서 자동 승인할 툴 이름을 입력하세요."
            alert.addButton(withTitle: "추가")
            alert.addButton(withTitle: "취소")
            
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
            alert.accessoryView = input
            NSApp.activate(ignoringOtherApps: true)
            
            if alert.runModal() == .alertFirstButtonReturn {
                let toolName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !toolName.isEmpty {
                    if self.sessionAutoApproveTypes[sessionId] == nil {
                        self.sessionAutoApproveTypes[sessionId] = []
                    }
                    self.sessionAutoApproveTypes[sessionId]?.insert(toolName)
                }
            }
        }
    }

    func dismissCurrentRequest() {
        if currentResponseHandler != nil {
            sendDecision(approved: false, reason: "Dismissed")
        } else {
            isNotchExpanded = false
            isExpandingFromRequest = false
            notificationTimer?.invalidate()
        }
    }

    func focusTerminal(for sessionId: String? = nil) {
        let targetId = sessionId ?? (currentSessionId.isEmpty ? selectedSessionId : currentSessionId)
        let session = targetId.flatMap { id in
            activeSessions.first { $0.id == id }
        }
        TerminalFocuser.focusTerminal(
            appName: session?.terminalApp,
            title: session?.terminalTitle,
            tty: session?.terminalTTY,
            windowId: session?.terminalWindowId,
            tabIndex: session?.terminalTabIndex,
            tmuxPane: session?.terminalTmuxPane,
            tmuxSocket: session?.terminalTmuxSocket,
            tmuxClient: session?.terminalTmuxClient
        )
    }
}
