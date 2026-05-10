import SwiftUI
import Combine
import AppKit

// MARK: - Pending Request

struct PendingRequest: Identifiable {
    let id = UUID()
    let sessionId: String
    let agentKind: BuddyKind
    let eventName: String
    let toolName: String
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

    var isTimeoutBypassed: Bool {
        if case .timeoutBypassed = self { return true }
        if case .autoApproved = self { return true }
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
        switch self {
        case .notch: return "노치 화면"
        case .focused: return "포커스 화면"
        case .mouse: return "마우스 화면"
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
        switch self {
        case .automatic: return "자동"
        case .main: return "주 모니터"
        case .mouse: return "마우스가 있는 모니터"
        case .focused: return "포커스가 있는 모니터"
        case .specific: return "선택한 모니터"
        }
    }
}

// MARK: - App State

class AppState: ObservableObject {
    static let shared = AppState(startServer: ProcessInfo.processInfo.environment["XCODE_RUNNING_UNIT_TESTS"] != "1")

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
    
    @Published var globalAutoApproveTypes: Set<String> = [] {
        didSet {
            userDefaults.set(Array(globalAutoApproveTypes), forKey: DefaultsKey.globalAutoApproveTypes)
        }
    }
    @Published var sessionAutoApproveTypes: [String: Set<String>] = [:]

    private static let genericTitles: Set<String> = ["Terminal", "iTerm", "Ghostty", "Warp", ""]
    private static let bypassTools: Set<String> = ["update_topic", "activate_skill"]

    private var server = HookSocketServer()
    private var pendingQueue: [PendingRequest] = []
    private var currentResponseHandler: ((String) -> Void)?
    var hasResponseHandler: Bool { currentResponseHandler != nil }
    private var isShowingRequest = false
    private var showingRequestId: UUID?
    private var timeoutTimer: Timer?
    private var notificationTimer: Timer?
    private var sessionPruningTimer: Timer?
    private let timeoutDuration: Double = 120
    private let lifecycleSessionTimeout: Double = 15 * 60

    init(
        startServer: Bool = true,
        userDefaults: UserDefaults = .standard,
        frontmostCheck: @escaping FrontmostCheck = TerminalFocuser.isSessionFrontmost
    ) {
        self.userDefaults = userDefaults
        self.frontmostCheck = frontmostCheck
        
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
            server.start()
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
        claudeSessionApprovalMode: ClaudeSessionApprovalMode = .nativePermissions,
        claudePersistentApprovalDestination: ClaudePersistentApprovalDestination = .userSettings
    ) -> String {
        let parsed = try? JSONSerialization.jsonObject(with: Data(rawResponse.utf8)) as? [String: Any]
        let decision = parsed?["response"] as? String
        let approvalScope = (parsed?["approval_scope"] as? String).flatMap(RuleScope.init(rawValue:))
        let providerOutput: [String: AnyJSON]?
        if let source, let event {
            providerOutput = ProviderAdapter.providerOutput(
                decision: decision,
                event: event,
                source: source,
                approvalScope: approvalScope,
                toolName: (parsed?["tool_name"] as? String) ?? toolName,
                ruleContent: (parsed?["rule_content"] as? String) ?? ruleContent,
                claudeSessionApprovalMode: claudeSessionApprovalMode,
                claudePersistentApprovalDestination: claudePersistentApprovalDestination
            )
        } else {
            providerOutput = nil
        }
        let rich = IPCRichResponse(requestId: requestId, decision: decision, providerOutput: providerOutput)
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
        ruleContent: String?
    ) {
        guard let data = message.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(IPCEnvelope.self, from: data),
              envelope.protocol == IPCEnvelope.protocolName else {
            return (nil, nil, nil, nil)
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
        return (envelope.source, event, toolName, ruleContent)
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
        if let envelope = try? JSONDecoder().decode(IPCEnvelope.self, from: rawData),
           envelope.protocol == IPCEnvelope.protocolName {
            guard BridgeTokenManager.shared.validate(envelope.token) else {
                print("[DevIsland] IPC token validation failed – denying request")
                responseHandler("{\"response\": \"denied\"}")
                return
            }
            // Convert AnyJSON payload to [String: Any] directly — avoids encode+decode roundtrip.
            parsedJSON = envelope.payload.mapValues { $0.rawValue } as [String: Any]
        } else {
            parsedJSON = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
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
                notificationType = json["notification_type"] as? String ?? ""
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

        if displayToolName.isEmpty { displayToolName = toolName }
        let normalizedEvent = HookEventNormalizer.normalizedName(event)
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

        if isStop {
            guard !sessionId.isEmpty else {
                responseHandler("{\"response\": \"approved\"}")
                return
            }
            let fullSessionId = sessionId
            DispatchQueue.main.async {
                let removedRequests = self.pendingQueue.filter { $0.sessionId == fullSessionId }
                removedRequests.forEach { $0.responseHandler("{\"response\": \"denied\"}") }
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
            responseHandler("{\"response\": \"approved\"}")
            return
        }

        if isNotification {
            print("[DevIsland] notification event: \(event) for \(toolName) → auto-approved")
            guard !sessionId.isEmpty else {
                responseHandler("{\"response\": \"approved\"}")
                return
            }
            if normalizedEvent == "notification",
               notificationType == "permission_prompt" || displayMsg.lowercased().contains("needs your permission") {
                responseHandler("{\"response\": \"approved\"}")
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

            responseHandler("{\"response\": \"approved\"}")
            return
        }

        guard isApproval else {
            print("[DevIsland] ignoring non-approval event: \(event)")
            responseHandler("{\"response\": \"approved\"}")
            return
        }

        guard !toolName.isEmpty || !displayMsg.isEmpty else {
            print("[DevIsland] ignoring empty approval request")
            responseHandler("{\"response\": \"approved\"}")
            return
        }

        let request = PendingRequest(
            sessionId: sessionId,
            agentKind: agentKind,
            eventName: event,
            toolName: displayToolName,
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

        if isAutoApprovedGlobal || isAutoApprovedSession || isAutoEditActive || isSafeAutoApprove {
            print("[DevIsland] [AUTO-APPROVE] Tool \(toolName) is auto-approved for session \(sessionId.prefix(8)) (AutoEdit: \(isAutoEditActive), SafeBypass: \(isSafeAutoApprove))")
            request.responseHandler("{\"response\": \"approved\"}")
            
            // 터미널 입력이 필요한 Interactive 툴인 경우 노치를 펼쳐 사용자에게 알림(Notification) 표시
            // 단, 터미널이 이미 포커스 상태라면 알림 불필요
            if isInteractive {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard !self.frontmostCheck(
                        terminalApp,
                        terminalTTY,
                        terminalWindowId,
                        terminalTabIndex,
                        terminalTmuxPane,
                        terminalTmuxSocket,
                        terminalTmuxClient
                    ) else { return }
                    self.isNotchExpanded = true
                    self.isExpandingFromRequest = true
                    self.currentSessionId = sessionId
                    self.currentMessage = "터미널 창을 확인해 주세요 (\(displayToolName))"
                }
            }
            
            // [상태 추적] exit_plan_mode가 호출되면, 사용자가 터미널에서 계획을 승인할 것으로 간주하고
            // 이후의 편집 작업들을 자동화하기 위해 Auto-Edit 모드 활성화를 준비합니다.
            if toolName == "exit_plan_mode" {
                DispatchQueue.main.async { [weak self] in
                    if let index = self?.activeSessions.firstIndex(where: { $0.id == sessionId }) {
                        self?.activeSessions[index].isAutoEditActive = true
                        print("[DevIsland] [MODE] Session \(sessionId.prefix(8)) switched to Auto-Edit mode")
                    }
                }
            }

            // Auto-Edit 중에 enter_plan_mode가 자동 승인되면 아래 리셋 블록에 도달하지 못하므로 여기서 처리
            if toolName == "enter_plan_mode" {
                DispatchQueue.main.async { [weak self] in
                    if let index = self?.activeSessions.firstIndex(where: { $0.id == sessionId }) {
                        self?.activeSessions[index].isAutoEditActive = false
                        print("[DevIsland] [MODE] Session \(sessionId.prefix(8)) switched to Plan mode")
                    }
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                if !sessionId.isEmpty {
                    self?.updateActiveSession(
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
                        // Interactive 툴인 경우 사용자에게 다음 행동 가이드를 제공
                        message: isInteractive ? "터미널 확인 대기 중..." : "Auto-approved: \(displayToolName)",
                        isPending: false,
                        preserveMessage: true,
                        isLifecycleTracked: true,
                        status: .autoApproved(Date())
                    )
                }
            }
            return
        }
        
        // [상태 추적] enter_plan_mode가 호출되면 다시 신중한 계획 수립 단계로 돌아간 것이므로
        // 실행 단계의 자동 승인(Auto-Edit) 모드를 해제하여 다시 모든 작업을 사용자에게 확인받습니다.
        if toolName == "enter_plan_mode" {
            DispatchQueue.main.async { [weak self] in
                if let index = self?.activeSessions.firstIndex(where: { $0.id == sessionId }) {
                    self?.activeSessions[index].isAutoEditActive = false
                    print("[DevIsland] [MODE] Session \(sessionId.prefix(8)) switched to Plan mode")
                }
            }
        }

        // Pass through check: 터미널이 이미 활성 상태라면 'pass' 응답으로 즉시 통과
        // NSAppleScript는 메인 스레드에서만 안전하게 실행 가능 (Apple 문서)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let isFrontmost = self.frontmostCheck(
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
                request.responseHandler("{\"response\": \"pass\"}")
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

        if isFrontmost {
            print("[DevIsland] [AUTO] Terminal focused, bypassing pending request for \(next.sessionId.prefix(8))")
            currentResponseHandler = next.responseHandler
            currentSessionId = next.sessionId
            sendDecision(approved: false, reason: "TerminalFocused", status: .timeoutBypassed(Date()), passToTerminal: true)
            return
        }

        print("[DevIsland] showNextRequest: showing \(next.eventName)/\(next.toolName) id=\(next.id)")
        currentResponseHandler = next.responseHandler
        currentEventName  = next.eventName
        currentToolName   = next.toolName
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

    private func sendDecision(
        approved: Bool,
        reason: String? = nil,
        status: SessionStatus? = nil,
        passToTerminal: Bool = false,
        approvalScope: RuleScope? = nil
    ) {
        let response = passToTerminal ? "pass" : approved ? "approved" : "denied"
        var responsePayload: [String: Any] = ["response": response]
        if let approvalScope {
            responsePayload["approval_scope"] = approvalScope.rawValue
            responsePayload["tool_name"] = currentToolName
            responsePayload["rule_content"] = currentMessage
        }
        let data = try? JSONSerialization.data(withJSONObject: responsePayload)
        let payload = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"response\":\"\(response)\"}"
        print("[DevIsland] sendDecision approved=\(approved), handler=\(currentResponseHandler != nil ? "SET" : "NIL"), reason=\(reason ?? "none")")
        currentResponseHandler?(payload)
        print("[DevIsland] sendDecision: response payload sent")
        currentResponseHandler = nil
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

    func approve(globalAlways: Bool = false, sessionAlways: Bool = false) {
        let tool = currentToolName
        let sId = currentSessionId
        
        if globalAlways && !tool.isEmpty {
            globalAutoApproveTypes.insert(tool)
        }
        if sessionAlways && !tool.isEmpty && !sId.isEmpty {
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
