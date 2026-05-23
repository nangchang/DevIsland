import SwiftUI
import Combine
import AppKit

// MARK: - App State

// AppState is the central hub: owns the IPC server, session list, pending approval queue,
// and decision dispatch.
//
// gap-5 (done): GeminiSessionState extracted (emulateInteractiveMode + UserDefaults persistence).
//   PTYSessionBuffer, ReplayRecorder, SessionStore were extracted in P4.
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
    typealias OpenPeonSoundPlayer = (_ category: CESPCategory) -> Void

    private let userDefaults: UserDefaults
    private let frontmostCheck: FrontmostCheck
    private let codexRuleSyncAdapter: CodexRuleSyncAdapter
    private let openPeonSoundPlayer: OpenPeonSoundPlayer

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
    @Published var currentMessage: String = ""
    @Published var currentSessionId: String = ""
    @Published var currentToolName: String = ""
    @Published var currentEventName: String = ""
    @Published var timeoutProgress: Double = 1.0
    @Published var autoApproveSafeTools = false {
        didSet {
            userDefaults.set(autoApproveSafeTools, forKey: DefaultsKey.autoApproveSafeTools)
        }
    }
    
    // gap-3 (done): All providers now write to SQLiteApprovalStore via persistApprovalScope.
    // These in-memory sets remain as a fast-path read cache for the current session only.
    // globalAutoApproveTypes is also persisted to UserDefaults for backward compatibility
    // with rules created before gap-3; new approvals are durable via SQLite.
    @Published var globalAutoApproveTypes: Set<String> = []

    private static let bypassTools: Set<String> = ["update_topic", "activate_skill"]

    let sessionStore: SessionStore
    let geminiState: GeminiSessionState

    private let approvalProxy: ApprovalProxyController?
    private var server = HookSocketServer()
    private var currentResponseHandler: ((String) -> Void)?
    var hasResponseHandler: Bool { currentResponseHandler != nil }
    private var currentAgentKind: BuddyKind?
    private var currentRawToolName: String = ""
    private var currentWorkspaceRoot: String?
    private var currentHookEventId: Int64?
    private var isShowingRequest = false
    private var showingRequestId: UUID?
    private var _previousSessionId: String?
    private var previousSessionId: String? {
        get {
            guard let id = _previousSessionId,
                  sessionStore.activeSessions.contains(where: { $0.id == id }) else { return nil }
            return id
        }
        set { _previousSessionId = newValue }
    }
    private var timeoutTimer: Timer?
    private var notificationTimer: Timer?
    private var sessionPruningTimer: Timer?
    private let approvalPersistenceQueue = DispatchQueue(label: "DevIsland.ApprovalPersistence", qos: .utility)
    private let ptyCoordinator: PTYCoordinator
    private var timeoutDuration: Double {
        let v = userDefaults.double(forKey: SettingsStore.DefaultsKey.permissionTimeoutSeconds)
        return v > 0 ? v : 120.0
    }
    private var notificationAutoCollapseDelay: TimeInterval? {
        guard let rawValue = userDefaults.string(forKey: SettingsStore.DefaultsKey.notchAutoCollapseDelay) else {
            return AppSettings.defaults.notchAutoCollapseDelay.seconds
        }
        return NotchAutoCollapseDelay(rawValue: rawValue)?.seconds
            ?? AppSettings.defaults.notchAutoCollapseDelay.seconds
    }
    private static let replayTerminalApp = "DevIsland Replay"
    private static let replayTimestampFormatter = ISO8601DateFormatter()
    private let replayRecorder: ReplayRecorder

    init(
        startServer: Bool = true,
        userDefaults: UserDefaults = .standard,
        frontmostCheck: @escaping FrontmostCheck = TerminalFocuser.isSessionFrontmost,
        approvalProxy: ApprovalProxyController? = nil,
        codexRuleSyncAdapter: CodexRuleSyncAdapter = CodexJSONRuleSyncAdapter(),
        openPeonSoundPlayer: @escaping OpenPeonSoundPlayer = { category in
            Task { @MainActor in
                CESPAudioPlayer.shared.play(category: category)
            }
        }
    ) {
        self.userDefaults = userDefaults
        self.frontmostCheck = frontmostCheck
        self.approvalProxy = approvalProxy
        self.codexRuleSyncAdapter = codexRuleSyncAdapter
        self.openPeonSoundPlayer = openPeonSoundPlayer
        self.sessionStore = SessionStore()
        self.geminiState = GeminiSessionState(userDefaults: userDefaults)
        self.ptyCoordinator = PTYCoordinator(
            ptyBuffer: PTYSessionBuffer(),
            approvalProxy: approvalProxy,
            persistenceQueue: approvalPersistenceQueue,
            userDefaults: userDefaults
        )
        self.replayRecorder = ReplayRecorder(proxy: approvalProxy, queue: approvalPersistenceQueue)
        
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
        if let savedAutoApprove = userDefaults.array(forKey: DefaultsKey.globalAutoApproveTypes) as? [String], !savedAutoApprove.isEmpty {
            globalAutoApproveTypes = Set(savedAutoApprove)
            // Migrate legacy UserDefaults rules into SQLite; only remove keys that succeeded.
            if let proxy = approvalProxy {
                var migratedTools: [String] = []
                for toolName in savedAutoApprove {
                    let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    do {
                        try proxy.store.insertRule(ApprovalRule(
                            id: SQLiteApprovalStore.deterministicRuleID(
                                provider: .any,
                                toolName: trimmed,
                                scope: .persistent,
                                workspaceRoot: nil
                            ),
                            provider: .any,
                            toolName: trimmed,
                            action: .allow,
                            scope: .persistent
                        ))
                        migratedTools.append(toolName)
                    } catch {
                        print("[DevIsland] [MIGRATE] Failed to migrate rule '\(trimmed)': \(error)")
                    }
                }
                if migratedTools.count == savedAutoApprove.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).count {
                    userDefaults.removeObject(forKey: DefaultsKey.globalAutoApproveTypes)
                } else {
                    let remaining = Set(savedAutoApprove).subtracting(migratedTools)
                    userDefaults.set(Array(remaining), forKey: DefaultsKey.globalAutoApproveTypes)
                }
            }
        } else if let proxy = approvalProxy,
                  let rules = try? proxy.store.rules(provider: .any, scope: .persistent) {
            // Warm the in-memory cache from SQLite on startup (no legacy UserDefaults key).
            globalAutoApproveTypes = Set(rules.map(\.toolName))
        }
        autoApproveSafeTools = userDefaults.bool(forKey: DefaultsKey.autoApproveSafeTools)
        ensureSelectedDisplay()

        if let proxy = approvalProxy {
            let rawReplay = userDefaults.integer(forKey: SettingsStore.DefaultsKey.replayRetentionDays)
            let replayDays = rawReplay > 0 ? rawReplay : AppSettings.defaults.replayRetentionDays
            let rawPty = userDefaults.integer(forKey: SettingsStore.DefaultsKey.ptyTranscriptRetentionDays)
            let ptyDays = rawPty > 0 ? rawPty : AppSettings.defaults.ptyTranscriptRetentionDays
            approvalPersistenceQueue.async {
                do {
                    try proxy.pruneOldLogs(replayRetentionDays: replayDays, ptyRetentionDays: ptyDays)
                } catch {
                    print("[DevIsland] [PRUNE] Failed to prune old logs: \(error)")
                }
            }
        }

        if let proxy = approvalProxy {
            restoreOpenSessions(from: proxy)
        }

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
            server.onServerFailed = { [weak self] error in
                print("[DevIsland] [ERROR] Socket server failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Server Error"
                    alert.informativeText = "Could not start the DevIsland server.\n\(error.localizedDescription)\n\nEnsure no other DevIsland instances are running, then retry."
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "Retry")
                    alert.addButton(withTitle: "Exit")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        self?.server.start(transport: Self.currentBridgeTransport())
                    } else {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            server.start(transport: Self.currentBridgeTransport())
            GlobalShortcutManager.shared.start()
            
            // Prune inactive sessions every 10 seconds
            sessionPruningTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self else { return }
                let prunedIds = self.sessionStore.pruneInactiveSessions()
                for id in prunedIds {
                    self.ptyCoordinator.clearBuffer(sessionId: id)
                }
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
        
        let session = sessionStore.activeSessions.first { $0.id == currentSessionId }

        isTerminalFrontmostAsync(for: session) { [weak self] isFrontmost in
            guard isFrontmost else { return }
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

    /// 현재 화면에 표시할 데이터를 선택된 세션 정보로 업데이트
    func syncDisplayToSelectedSession() {
        guard currentResponseHandler == nil else { return }
        let sessionId = sessionStore.selectedSessionId ?? currentSessionId

        if let session = sessionStore.activeSessions.first(where: { $0.id == sessionId }) {
            DispatchQueue.main.async {
                guard self.currentResponseHandler == nil else { return }
                self.currentToolName = session.lastToolName
                self.currentEventName = session.lastEventName
                self.currentMessage = session.lastMessage
            }
        }
    }

    func handleMessage(_ message: String, responseHandler: @escaping (String) -> Void) {
        switch HookEventHandler.parse(message) {
        case .invalid:
            responseHandler("{\"response\": \"approved\"}")
            return
        case .denied:
            responseHandler("{\"response\": \"denied\"}")
            return
        case .parsed(let h):
            handleParsedEvent(h, responseHandler: responseHandler)
        }
    }

    private func handleParsedEvent(_ h: ParsedHookEvent, responseHandler: @escaping (String) -> Void) {
        var displayToolName = h.displayToolName

        if h.isSubAgentSession {
            _ = recordReplayHookEvent(
                requestId: h.requestId,
                provider: providerKind(for: h.agentKind),
                sessionId: h.sessionId,
                eventName: h.event,
                toolName: h.toolName,
                payload: h.parsedJSON
            )
            if !h.sessionId.isEmpty {
                let fullSessionId = h.sessionId
                let pid = h.parentSessionId
                let subAgentStopEvents: Set<String> = ["stop", "exit", "shutdown", "sessionend"]
                let normalizedSubEvent = HookEventNormalizer.normalizedName(h.event)
                if subAgentStopEvents.contains(normalizedSubEvent) {
                    DispatchQueue.main.async {
                        self.sessionStore.removeSession(id: fullSessionId)
                        self.ptyCoordinator.clearBuffer(sessionId: fullSessionId)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.sessionStore.updateActiveSession(
                            sessionId: fullSessionId,
                            terminalTitle: h.terminalTitle,
                            agentKind: h.agentKind,
                            terminalApp: h.terminalApp,
                            terminalTTY: h.terminalTTY,
                            terminalWindowId: h.terminalWindowId,
                            terminalTabIndex: h.terminalTabIndex,
                            terminalTmuxPane: h.terminalTmuxPane,
                            terminalTmuxSocket: h.terminalTmuxSocket,
                            terminalTmuxClient: h.terminalTmuxClient,
                            toolName: displayToolName,
                            eventName: h.event,
                            message: h.displayMsg,
                            isPending: false,
                            isLifecycleTracked: true,
                            isSubAgentSession: true,
                            parentSessionId: pid
                        )
                    }
                }
            }
            responseHandler("{\"response\": \"approved\"}")
            return
        }

        // PTY output events are handled before hook_events recording to avoid polluting the replay log.
        if h.event == "PTYOutput" {
            ptyCoordinator.handleOutputEvent(
                sessionId: h.sessionId,
                provider: providerKind(for: h.agentKind),
                content: (h.parsedJSON["content"] as? String) ?? "",
                responseHandler: responseHandler
            )
            return
        }

        let normalizedEvent = HookEventNormalizer.normalizedName(h.event)
        let hookEventId = recordReplayHookEvent(
            requestId: h.requestId,
            provider: providerKind(for: h.agentKind),
            sessionId: h.sessionId,
            eventName: h.event,
            toolName: h.toolName,
            payload: h.parsedJSON
        )
        if displayToolName.isEmpty {
            if normalizedEvent == "elicitation" {
                if let serverName = h.parsedJSON["mcp_server_name"] as? String, !serverName.isEmpty {
                    displayToolName = "Elicitation (\(serverName))"
                } else {
                    displayToolName = "Elicitation"
                }
            } else if normalizedEvent == "userpromptsubmit" {
                displayToolName = "User Prompt"
            } else {
                displayToolName = h.toolName
            }
        }
        let stopEvents = ["exit", "shutdown", "sessionend"]
        let notificationEvents = [
            "sessionstart", "notification", "posttooluse", "precompact", "subagentstop",
            "startup", "init", "afteragent"
        ]
        let isUserQuestionTool = HookEventNormalizer.isUserQuestionTool(h.toolName)
        // approval:
        // - Claude/Codex: PermissionRequest only
        // - Gemini: BeforeTool only
        // User-question tools are shown as notifications even when delivered through an approval-capable hook.
        let isStop = stopEvents.contains(normalizedEvent)
        let isApproval = Self.isApprovalEvent(normalizedEvent, for: h.agentKind) && !isUserQuestionTool
        let isNotification = (!isStop && !isApproval) || notificationEvents.contains(normalizedEvent)
        let replayToolName = h.toolName.isEmpty ? displayToolName : h.toolName
        let cespCategory = CESPEventMapper.category(
            event: h.event,
            normalizedEvent: normalizedEvent,
            agentKind: h.agentKind,
            toolName: h.toolName,
            notificationType: h.notificationType,
            message: h.displayMsg,
            payload: h.parsedJSON
        )

        if isStop {
            playOpenPeonSound(cespCategory)
            guard !h.sessionId.isEmpty else {
                respondWithReplay(
                    "{\"response\": \"approved\"}",
                    responseHandler: responseHandler,
                    hookEventId: hookEventId,
                    agentKind: h.agentKind,
                    sessionId: h.sessionId,
                    toolName: replayToolName,
                    workspaceRoot: h.workspaceRoot,
                    action: .allow,
                    source: .automatic,
                    reason: "stop h.event"
                )
                return
            }
            let fullSessionId = h.sessionId
            DispatchQueue.main.async {
                let removedRequests = self.sessionStore.removeAllPending(sessionId: fullSessionId)
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
                self.sessionStore.removeSession(id: fullSessionId)
                self.ptyCoordinator.clearBuffer(sessionId: fullSessionId)

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

                if self.sessionStore.pendingQueue.isEmpty {
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
                agentKind: h.agentKind,
                sessionId: h.sessionId,
                toolName: replayToolName,
                workspaceRoot: h.workspaceRoot,
                action: .allow,
                source: .automatic,
                reason: "stop h.event"
            )
            return
        }

        if normalizedEvent == "userpromptsubmit", h.agentKind == .claudeCode,
           let prompt = h.parsedJSON["prompt"] as? String,
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
                    agentKind: h.agentKind,
                    sessionId: h.sessionId,
                    toolName: replayToolName,
                    workspaceRoot: h.workspaceRoot,
                    action: .deny,
                    source: .automatic,
                    reason: denialReason
                )
            } else {
                respondWithReplay(
                    "{\"response\":\"denied\"}",
                    responseHandler: responseHandler,
                    hookEventId: hookEventId,
                    agentKind: h.agentKind,
                    sessionId: h.sessionId,
                    toolName: replayToolName,
                    workspaceRoot: h.workspaceRoot,
                    action: .deny,
                    source: .automatic,
                    reason: denialReason
                )
            }
            return
        }

        if isNotification {
            let passClaudeUserQuestion = h.agentKind == .claudeCode && isUserQuestionTool
            let notification = passClaudeUserQuestion
                ? (response: "pass", action: RuleAction.prompt, reason: "Claude user question passthrough")
                : (response: "approved", action: RuleAction.allow, reason: "notification")

            print("[DevIsland] notification event: \(h.event) for \(h.toolName) → \(notification.response)")
            playOpenPeonSound(cespCategory)
            guard !h.sessionId.isEmpty else {
                respondWithReplay(
                    "{\"response\": \"\(notification.response)\"}",
                    responseHandler: responseHandler,
                    hookEventId: hookEventId,
                    agentKind: h.agentKind,
                    sessionId: h.sessionId,
                    toolName: replayToolName,
                    workspaceRoot: h.workspaceRoot,
                    action: notification.action,
                    source: .automatic,
                    reason: notification.reason
                )
                return
            }
            if normalizedEvent == "notification",
               h.notificationType == "permission_prompt" || h.displayMsg.lowercased().contains("needs your permission") {
                respondWithReplay(
                    "{\"response\": \"approved\"}",
                    responseHandler: responseHandler,
                    hookEventId: hookEventId,
                    agentKind: h.agentKind,
                    sessionId: h.sessionId,
                    toolName: replayToolName,
                    workspaceRoot: h.workspaceRoot,
                    action: .allow,
                    source: .automatic,
                    reason: "permission prompt notification"
                )
                return
            }
            let fullSessionId = h.sessionId
            let isStartEvent = (normalizedEvent == "sessionstart" || normalizedEvent == "startup" || normalizedEvent == "init")

            // [UX] 에이전트 작업 완료 대기 상태(Idle Prompt) 판별 로직
            // - Claude Code: notification 훅에 idle_prompt 또는 input_required 타입으로 전달됨
            // - Gemini CLI: afteragent, aftermodel 등 턴 종료 시 발생하는 훅을 대기 상태로 간주
            // - Codex CLI: posttooluse를 쓰면 툴 연속 자동 실행 시 스팸 알림이 생기므로 제외함. 대신 stop 이벤트를 통해 완료됨을 알림
            let isIdlePrompt = (normalizedEvent == "notification" && (h.notificationType == "idle_prompt" || h.notificationType == "input_required")) ||
                               normalizedEvent == "afteragent"

            let sessionMessage: String
            if isStartEvent {
                sessionMessage = "Session Started"
            } else if isIdlePrompt && h.displayMsg.isEmpty {
                sessionMessage = "Waiting for next prompt..."
            } else if (normalizedEvent == "stop" && h.displayMsg.isEmpty) {
                sessionMessage = "Task Completed"
            } else {
                sessionMessage = h.displayMsg
            }

            DispatchQueue.main.async {
                // sessionStore 뮤테이션은 항상 메인 스레드에서 수행 (@Published → SwiftUI 업데이트)
                if isStartEvent &&
                    h.agentKind == .codex &&
                    Self.shouldSupersedeCodexSessionsOnStart(source: h.sessionStartSource) {
                    let removedSessionIds = self.sessionStore.removeSupersededCodexSessions(
                        newSessionId: fullSessionId,
                        terminalApp: h.terminalApp,
                        terminalTTY: h.terminalTTY,
                        terminalWindowId: h.terminalWindowId,
                        terminalTabIndex: h.terminalTabIndex,
                        terminalTmuxPane: h.terminalTmuxPane,
                        terminalTmuxSocket: h.terminalTmuxSocket,
                        terminalTmuxClient: h.terminalTmuxClient
                    )

                    var removedCurrentRequest = false
                    for removedSessionId in removedSessionIds {
                        let removedRequests = self.sessionStore.removeAllPending(sessionId: removedSessionId)
                        if removedRequests.contains(where: { $0.id == self.showingRequestId }) {
                            removedCurrentRequest = true
                        }
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
                                reason: "session superseded"
                            )
                        }
                        self.ptyCoordinator.clearBuffer(sessionId: removedSessionId)
                    }

                    if removedSessionIds.contains(self.currentSessionId) || removedCurrentRequest {
                        self.currentResponseHandler = nil
                        self.isShowingRequest = false
                        self.showingRequestId = nil
                        self.timeoutTimer?.invalidate()
                        self.timeoutProgress = 1.0
                        self.currentSessionId = ""
                        self.currentToolName = ""
                        self.currentEventName = ""
                        self.currentMessage = ""
                        self.showNextRequest()
                    }
                }

                let hasPendingForSession = self.sessionStore.pendingQueue.contains { $0.sessionId == fullSessionId }
                self.sessionStore.updateActiveSession(
                    sessionId: fullSessionId,
                    terminalTitle: h.terminalTitle,
                    agentKind: h.agentKind,
                    terminalApp: h.terminalApp,
                    terminalTTY: h.terminalTTY,
                    terminalWindowId: h.terminalWindowId,
                    terminalTabIndex: h.terminalTabIndex,
                    terminalTmuxPane: h.terminalTmuxPane,
                    terminalTmuxSocket: h.terminalTmuxSocket,
                    terminalTmuxClient: h.terminalTmuxClient,
                    toolName: displayToolName,
                    eventName: h.event,
                    message: sessionMessage,
                    isPending: hasPendingForSession,
                    preserveMessage: normalizedEvent == "posttooluse" || sessionMessage.isEmpty,
                    isLifecycleTracked: isStartEvent || h.agentKind != .claudeCode, // Codex/Gemini는 기본적으로 추적 유지
                    isSubAgentSession: h.isSubAgentSession
                )

                if isStartEvent || (self.sessionStore.selectedSessionId == nil) {
                    self.sessionStore.selectedSessionId = fullSessionId
                }

                // 알림 확장 로직 (질문이나 작업 완료 시)
                let isCodexPostToolUse = h.agentKind == .codex && normalizedEvent == "posttooluse"
                let isInformational = !isCodexPostToolUse && ((normalizedEvent == "stop" || isStartEvent) || isIdlePrompt ||
                                     isUserQuestionTool ||
                                     (h.displayMsg.contains("?") && (normalizedEvent == "notification" || h.agentKind != .claudeCode)))

                let isCurrentlyViewed = self.isExpandingFromRequest && self.currentSessionId == fullSessionId
                if isInformational && !isStartEvent && !sessionMessage.isEmpty && !isCurrentlyViewed {
                    self.sessionStore.setUnread(true, sessionId: fullSessionId)
                }

                if isInformational && !hasPendingForSession && self.currentResponseHandler == nil {
                    // 터미널이 포커스되어 있지 않을 때만 확장
                    let session = self.sessionStore.activeSessions.first { $0.id == fullSessionId }
                    self.isTerminalFrontmostAsync(for: session) { [weak self] isFrontmost in
                        guard let self else { return }
                        if isFrontmost {
                            self.sessionStore.setUnread(false, sessionId: fullSessionId)
                            return
                        }
                        guard self.currentResponseHandler == nil else { return }
                        if self.isExpandingFromRequest && !self.currentSessionId.isEmpty && self.currentSessionId != fullSessionId {
                            self.sessionStore.setUnread(false, sessionId: self.currentSessionId)
                            self.previousSessionId = self.currentSessionId
                        }
                        self.currentToolName = displayToolName
                        self.currentEventName = h.event
                        self.currentMessage = sessionMessage
                        self.currentSessionId = fullSessionId
                        self.isNotchExpanded = true
                        self.isExpandingFromRequest = true
                        
                        self.notificationTimer?.invalidate()
                        if let delay = self.notificationAutoCollapseDelay {
                            self.notificationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                                if self?.currentResponseHandler == nil && self?.isNotchExpanded == true {
                                    self?.isNotchExpanded = false
                                    self?.isExpandingFromRequest = false
                                }
                            }
                        }
                    }
                }
            }

            respondWithReplay(
                "{\"response\": \"\(notification.response)\"}",
                responseHandler: responseHandler,
                hookEventId: hookEventId,
                agentKind: h.agentKind,
                sessionId: h.sessionId,
                toolName: replayToolName,
                workspaceRoot: h.workspaceRoot,
                action: notification.action,
                source: .automatic,
                reason: notification.reason
            )
            return
        }

        let isGeminiNormalMode = h.agentKind == .gemini && !geminiState.emulateInteractiveMode
        
        guard isApproval && !isGeminiNormalMode else {
            print("[DevIsland] ignoring non-approval h.event (or Gemini normal mode): \(h.event)")
            respondWithReplay(
                "{\"response\": \"approved\"}",
                responseHandler: responseHandler,
                hookEventId: hookEventId,
                agentKind: h.agentKind,
                sessionId: h.sessionId,
                toolName: replayToolName,
                workspaceRoot: h.workspaceRoot,
                action: .allow,
                source: .automatic,
                reason: isGeminiNormalMode ? "Gemini normal mode notification" : "non-approval h.event"
            )
            return
        }

        guard !h.toolName.isEmpty || !h.displayMsg.isEmpty else {
            print("[DevIsland] ignoring empty approval request")
            respondWithReplay(
                "{\"response\": \"approved\"}",
                responseHandler: responseHandler,
                hookEventId: hookEventId,
                agentKind: h.agentKind,
                sessionId: h.sessionId,
                toolName: replayToolName,
                workspaceRoot: h.workspaceRoot,
                action: .allow,
                source: .automatic,
                reason: "empty approval request"
            )
            return
        }

        let request = PendingRequest(
            hookEventId: hookEventId,
            sessionId: h.sessionId,
            agentKind: h.agentKind,
            eventName: h.event,
            toolName: displayToolName,
            rawToolName: h.toolName,
            workspaceRoot: h.workspaceRoot,
            isReplay: h.isReplayPayload,
            message: h.displayMsg,
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
        let isInteractive = GeminiPromptPolicy.isInteractiveTool(h.toolName, isPlanAction: h.isPlanAction)
        
        // 자동 승인 여부 판단 (전역 설정 + 세션별 툴 등록 + 현재가 자동 편집 모드인지 + Safe 등급 툴 자동 승인 옵션)
        var isAutoApprovedGlobal = globalAutoApproveTypes.contains(h.toolName) || bypassTools.contains(h.toolName) || isInteractive
        let isAutoApprovedSession = sessionStore.sessionAutoApproveTypes[h.sessionId]?.contains(h.toolName) == true

        var isAutoEditActive = false
        if let session = sessionStore.activeSessions.first(where: { $0.id == h.sessionId }) {
            isAutoEditActive = session.isAutoEditActive
        }

        // 사용자가 메뉴에서 설정한 "Safe 등급 툴 자동 승인" 옵션 적용
        let isSafeAutoApprove = autoApproveSafeTools && (ToolKnowledge.risk(for: h.toolName) == .safe)

        // [핵심] 제미나이 일반 모드 에뮬레이션 로직
        // 제미나이 CLI가 --auto-approve나 --yolo로 실행되어 터미널 프롬프트가 뜨지 않는 상황일 때,
        // DevIsland가 'Interactive 모드'처럼 위험한 툴을 선별해서 승인 창을 띄웁니다.
        if geminiState.emulateInteractiveMode && h.agentKind == .gemini {
            let isExplicitlyApproved = globalAutoApproveTypes.contains(h.toolName) || isAutoApprovedSession
            if GeminiPromptPolicy.emulationShouldForceApproval(toolName: h.toolName, isExplicitlyApproved: isExplicitlyApproved) {
                isAutoApprovedGlobal = false
                isAutoEditActive = false
                print("[DevIsland] [EMULATION] Gemini interactive emulation forced for tool: \(h.toolName)")
            }
        }

        isTerminalFrontmostAsync(
            appName: h.terminalApp,
            tty: h.terminalTTY,
            windowId: h.terminalWindowId,
            tabIndex: h.terminalTabIndex,
            tmuxPane: h.terminalTmuxPane,
            tmuxSocket: h.terminalTmuxSocket,
            tmuxClient: h.terminalTmuxClient
        ) { [weak self] isFrontmost in
            guard let self = self else { return }

            // 1. 터미널 포커스 최우선 — 사용자가 이미 터미널에 있으면 CLI가 자체 처리하도록 pass
            if !h.isReplayPayload && isFrontmost {
                print("[DevIsland] [PASS] Terminal is frontmost, responding with 'pass' for session \(h.sessionId.prefix(8))")
                self.respondWithReplay(
                    "{\"response\": \"pass\"}",
                    responseHandler: request.responseHandler,
                    hookEventId: hookEventId,
                    agentKind: h.agentKind,
                    sessionId: h.sessionId,
                    toolName: replayToolName,
                    workspaceRoot: h.workspaceRoot,
                    action: .prompt,
                    source: .automatic,
                    reason: "terminal focused"
                )
                if !h.sessionId.isEmpty {
                    self.sessionStore.updateActiveSession(
                        sessionId: h.sessionId,
                        terminalTitle: h.terminalTitle,
                        agentKind: h.agentKind,
                        terminalApp: h.terminalApp,
                        terminalTTY: h.terminalTTY,
                        terminalWindowId: h.terminalWindowId,
                        terminalTabIndex: h.terminalTabIndex,
                        terminalTmuxPane: h.terminalTmuxPane,
                        terminalTmuxSocket: h.terminalTmuxSocket,
                        terminalTmuxClient: h.terminalTmuxClient,
                        toolName: displayToolName,
                        eventName: h.event,
                        message: h.displayMsg,
                        isPending: false,
                        status: SessionStatus.timeoutBypassed(Date())
                    )
                }
                return
            }

            // 2. SQLite policy rules (all providers)
            let provider = self.providerKind(for: h.agentKind)
            if let policyDecision = self.policyDecision(
                provider: provider,
                hookEventId: hookEventId,
                sessionId: h.sessionId,
                toolName: h.toolName,
                workspaceRoot: h.workspaceRoot,
                toolInput: h.toolInput
            ) {
                print("[DevIsland] [POLICY] \(provider.rawValue) \(h.toolName) matched \(policyDecision.source.rawValue): \(policyDecision.action.rawValue)")
                request.responseHandler(self.responsePayload(approved: policyDecision.action == .allow))
                self.sessionStore.updateActiveSession(
                    sessionId: h.sessionId,
                    terminalTitle: h.terminalTitle,
                    agentKind: h.agentKind,
                    terminalApp: h.terminalApp,
                    terminalTTY: h.terminalTTY,
                    terminalWindowId: h.terminalWindowId,
                    terminalTabIndex: h.terminalTabIndex,
                    terminalTmuxPane: h.terminalTmuxPane,
                    terminalTmuxSocket: h.terminalTmuxSocket,
                    terminalTmuxClient: h.terminalTmuxClient,
                    toolName: displayToolName,
                    eventName: h.event,
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
                print("[DevIsland] [AUTO-APPROVE] Tool \(h.toolName) is auto-approved for session \(h.sessionId.prefix(8)) (AutoEdit: \(isAutoEditActive), SafeBypass: \(isSafeAutoApprove))")
                self.respondWithReplay(
                    "{\"response\": \"approved\"}",
                    responseHandler: request.responseHandler,
                    hookEventId: hookEventId,
                    agentKind: h.agentKind,
                    sessionId: h.sessionId,
                    toolName: replayToolName,
                    workspaceRoot: h.workspaceRoot,
                    action: .allow,
                    source: .automatic,
                    reason: "auto-approved"
                )

                // Interactive 툴: 이미 포커스 체크 후 여기 도달했으므로 터미널이 비포커스 상태 → 알림 표시
                if isInteractive && !h.isReplayPayload {
                    self.isNotchExpanded = true
                    self.isExpandingFromRequest = true
                    self.currentSessionId = h.sessionId
                    self.currentMessage = "터미널 창을 확인해 주세요 (\(displayToolName))"
                }

                if h.toolName == "exit_plan_mode",
                   let index = self.sessionStore.activeSessions.firstIndex(where: { $0.id == h.sessionId }) {
                    self.sessionStore.activeSessions[index].isAutoEditActive = true
                    print("[DevIsland] [MODE] Session \(h.sessionId.prefix(8)) switched to Auto-Edit mode")
                }
                if h.toolName == "enter_plan_mode",
                   let index = self.sessionStore.activeSessions.firstIndex(where: { $0.id == h.sessionId }) {
                    self.sessionStore.activeSessions[index].isAutoEditActive = false
                    print("[DevIsland] [MODE] Session \(h.sessionId.prefix(8)) switched to Plan mode")
                }

                if !h.sessionId.isEmpty {
                    self.sessionStore.updateActiveSession(
                        sessionId: h.sessionId,
                        terminalTitle: h.terminalTitle,
                        agentKind: h.agentKind,
                        terminalApp: h.terminalApp,
                        terminalTTY: h.terminalTTY,
                        terminalWindowId: h.terminalWindowId,
                        terminalTabIndex: h.terminalTabIndex,
                        terminalTmuxPane: h.terminalTmuxPane,
                        terminalTmuxSocket: h.terminalTmuxSocket,
                        terminalTmuxClient: h.terminalTmuxClient,
                        toolName: displayToolName,
                        eventName: h.event,
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
            if h.toolName == "enter_plan_mode",
               let index = self.sessionStore.activeSessions.firstIndex(where: { $0.id == h.sessionId }) {
                self.sessionStore.activeSessions[index].isAutoEditActive = false
                print("[DevIsland] [MODE] Session \(h.sessionId.prefix(8)) switched to Plan mode")
            }

            // 5. 승인 대기 큐에 추가
            let newItem = PendingItem(
                id: request.id,
                toolName: request.toolName,
                message: request.message,
                sessionId: request.sessionId,
                terminalTitle: h.terminalTitle,
                terminalWindowId: h.terminalWindowId,
                terminalTabIndex: h.terminalTabIndex,
                terminalTmuxPane: h.terminalTmuxPane,
                terminalTmuxSocket: h.terminalTmuxSocket,
                terminalTmuxClient: h.terminalTmuxClient,
                receivedAt: request.receivedAt
            )
            self.sessionStore.appendPending(request: request, item: newItem)
            self.playOpenPeonSound(cespCategory)

            if !request.sessionId.isEmpty {
                self.sessionStore.updateActiveSession(
                    sessionId: request.sessionId,
                    terminalTitle: h.terminalTitle,
                    agentKind: h.agentKind,
                    terminalApp: h.terminalApp,
                    terminalTTY: h.terminalTTY,
                    terminalWindowId: h.terminalWindowId,
                    terminalTabIndex: h.terminalTabIndex,
                    terminalTmuxPane: h.terminalTmuxPane,
                    terminalTmuxSocket: h.terminalTmuxSocket,
                    terminalTmuxClient: h.terminalTmuxClient,
                    toolName: request.toolName,
                    eventName: request.eventName,
                    message: request.message,
                    isPending: true,
                    isLifecycleTracked: h.agentKind != .claudeCode
                )

                self.sessionStore.selectedSessionId = request.sessionId
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

    private static func shouldSupersedeCodexSessionsOnStart(source: String) -> Bool {
        let normalized = HookEventNormalizer.normalizedName(source)
        return ["clear", "startup", "resume"].contains(normalized)
    }

    private func playOpenPeonSound(_ category: CESPCategory?) {
        guard let category else { return }
        openPeonSoundPlayer(category)
    }


    static func agentKind(from json: [String: Any], terminalTitle: String) -> BuddyKind {
        HookEventNormalizer.agentKind(from: json, terminalTitle: terminalTitle)
    }


    func dismissSession(_ sessionId: String) {
        let agentKind = sessionStore.activeSessions.first(where: { $0.id == sessionId })?.agentKind ?? .claudeCode
        replayRecorder.recordHookEvent(
            requestId: nil,
            provider: providerKind(for: agentKind),
            sessionId: sessionId,
            eventName: "devisland_dismissed",
            toolName: "",
            payload: ["session_id": sessionId, "source": "user_dismissed"]
        )
        DispatchQueue.main.async {
            let removedRequests = self.sessionStore.removeAllPending(sessionId: sessionId)
            removedRequests.forEach { $0.responseHandler("{\"response\": \"pass\"}") }
            self.sessionStore.removeSession(id: sessionId)
            self.ptyCoordinator.clearBuffer(sessionId: sessionId)

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

            if self.sessionStore.pendingQueue.isEmpty {
                if self.sessionStore.activeSessions.isEmpty {
                    self.isNotchExpanded = false
                    self.sessionStore.selectedSessionId = nil
                }
                self.syncDisplayToSelectedSession()
            } else if self.currentResponseHandler == nil {
                self.showNextRequest()
            }
        }
    }

    private func showNextRequest() {
        discardInvalidPendingRequests()

        guard let next = sessionStore.pendingQueue.first else {
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
            if let prev = previousSessionId {
                previousSessionId = nil
                sessionStore.selectedSessionId = prev
                sessionStore.setUnread(false, sessionId: prev)
                currentSessionId = prev
                syncDisplayToSelectedSession()
                isExpandingFromRequest = true
                isNotchExpanded = true
            } else {
                sessionStore.selectedSessionId = nil
                isNotchExpanded = false
            }
            return
        }

        if isShowingRequest { return }
        isShowingRequest = true
        showingRequestId = next.id

        let session = sessionStore.activeSessions.first { $0.id == next.sessionId }
        isTerminalFrontmostAsync(for: session) { [weak self] isFrontmost in
            guard let self else { return }
            guard self.showingRequestId == next.id else { return }

            if isFrontmost && !next.isReplay {
                print("[DevIsland] [AUTO] Terminal focused, bypassing pending request for \(next.sessionId.prefix(8))")
                self.currentResponseHandler = next.responseHandler
                self.currentSessionId = next.sessionId
                self.currentRawToolName = next.rawToolName
                self.currentAgentKind = next.agentKind
                self.currentWorkspaceRoot = next.workspaceRoot
                self.currentHookEventId = next.hookEventId
                self.sendDecision(approved: false, reason: "TerminalFocused", status: .timeoutBypassed(Date()), passToTerminal: true)
                return
            }

            print("[DevIsland] showNextRequest: showing \(next.eventName)/\(next.toolName) id=\(next.id)")
            if self.isExpandingFromRequest && !self.currentSessionId.isEmpty && self.currentSessionId != next.sessionId {
                self.sessionStore.setUnread(false, sessionId: self.currentSessionId)
                self.previousSessionId = self.currentSessionId
            }
            self.currentResponseHandler = next.responseHandler
            self.currentEventName  = next.eventName
            self.currentToolName   = next.toolName
            self.currentRawToolName = next.rawToolName
            self.currentAgentKind  = next.agentKind
            self.currentWorkspaceRoot = next.workspaceRoot
            self.currentHookEventId = next.hookEventId
            self.currentMessage    = next.message
            self.currentSessionId  = next.sessionId

            self.isExpandingFromRequest = true
            self.isNotchExpanded = true
            self.startTimeout()
        }
    }

    private func isTerminalFrontmostAsync(for session: ActiveSession?, completion: @escaping (Bool) -> Void) {
        isTerminalFrontmostAsync(
            appName: session?.terminalApp,
            tty: session?.terminalTTY,
            windowId: session?.terminalWindowId,
            tabIndex: session?.terminalTabIndex,
            tmuxPane: session?.terminalTmuxPane,
            tmuxSocket: session?.terminalTmuxSocket,
            tmuxClient: session?.terminalTmuxClient,
            completion: completion
        )
    }

    private func isTerminalFrontmostAsync(
        appName: String?,
        tty: String?,
        windowId: String?,
        tabIndex: String?,
        tmuxPane: String?,
        tmuxSocket: String?,
        tmuxClient: String?,
        completion: @escaping (Bool) -> Void
    ) {
        let frontmostCheck = self.frontmostCheck

        DispatchQueue.global(qos: .userInitiated).async {
            let isFrontmost = frontmostCheck(
                appName,
                tty,
                windowId,
                tabIndex,
                tmuxPane,
                tmuxSocket,
                tmuxClient
            )
            DispatchQueue.main.async {
                completion(isFrontmost)
            }
        }
    }

    private func discardInvalidPendingRequests() {
        while let next = sessionStore.pendingQueue.first, !isValidApprovalRequest(next) {
            if let removed = sessionStore.removeFirstPending() {
                removed.responseHandler("{\"response\": \"approved\"}")
            }
        }
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
        replayRecorder.recordHookEvent(
            requestId: requestId,
            provider: provider,
            sessionId: sessionId,
            eventName: eventName,
            toolName: toolName,
            payload: payload
        )
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
        guard let agentKind else { return }
        replayRecorder.recordDecision(
            hookEventId: hookEventId,
            provider: providerKind(for: agentKind),
            sessionId: sessionId,
            toolName: toolName,
            workspaceRoot: workspaceRoot,
            action: action,
            source: source,
            reason: reason
        )
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

    private func policyDecision(
        provider: ProviderKind,
        hookEventId: Int64?,
        sessionId: String,
        toolName: String,
        workspaceRoot: String?,
        toolInput: [String: Any]? = nil
    ) -> ApprovalPolicyDecision? {
        guard let approvalProxy, !sessionId.isEmpty, !toolName.isEmpty else { return nil }
        do {
            let request = ApprovalPolicyRequest(
                provider: provider,
                sessionId: sessionId,
                toolName: toolName,
                workspaceRoot: workspaceRoot,
                toolInput: toolInput
            )
            let decision = try approvalProxy.evaluate(request)
            guard decision.action != .prompt else { return nil }
            approvalPersistenceQueue.async {
                do {
                    try approvalProxy.recordDecision(
                        hookEventId: hookEventId,
                        request: request,
                        decision: decision,
                        reason: "matched \(decision.source.rawValue)"
                    )
                } catch {
                    print("[DevIsland] [REPLAY] Failed to record policy decision: \(error)")
                }
            }
            return decision
        } catch {
            print("[DevIsland] [POLICY] \(provider.rawValue) policy evaluation failed: \(error)")
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
        persistApprovalScope(approved: approved, approvalScope: approvalScope)
        currentResponseHandler = nil
        currentHookEventId = nil
        isShowingRequest = false
        showingRequestId = nil
        timeoutTimer?.invalidate()

        DispatchQueue.main.async {
            self.timeoutProgress = 1.0
            var completedSessionId: String?
            if let removed = self.sessionStore.removeFirstPending() {
                completedSessionId = removed.sessionId

                // Update session state to not pending
                if !removed.sessionId.isEmpty, let index = self.sessionStore.activeSessions.firstIndex(where: { $0.id == removed.sessionId }) {
                    let stillPending = self.sessionStore.pendingQueue.contains { $0.sessionId == removed.sessionId }
                    if stillPending {
                        self.sessionStore.activeSessions[index].isPending = true
                        self.sessionStore.activeSessions[index].status = .pending
                    } else if status?.isTimeoutBypassed == true {
                        self.sessionStore.activeSessions[index].isPending = false
                        self.sessionStore.activeSessions[index].status = status ?? .idle
                        self.sessionStore.activeSessions[index].lastActiveAt = Date()
                    } else if !self.sessionStore.activeSessions[index].isLifecycleTracked {
                        self.sessionStore.activeSessions.remove(at: index)
                    } else {
                        self.sessionStore.activeSessions[index].isPending = false
                        self.sessionStore.activeSessions[index].status = status ?? .idle
                        self.sessionStore.activeSessions[index].lastActiveAt = Date()
                    }
                }
            }
            self.showNextRequest()
            if status?.isTimeoutBypassed == true, self.sessionStore.pendingQueue.isEmpty, let completedSessionId {
                if !self.isExpandingFromRequest {
                    self.sessionStore.selectedSessionId = completedSessionId
                    self.isNotchExpanded = false
                }
            }
        }
    }

    private func persistApprovalScope(approved: Bool, approvalScope: RuleScope?) {
        guard approved,
              let agentKind = currentAgentKind,
              let approvalScope,
              let approvalProxy,
              !currentSessionId.isEmpty,
              !currentRawToolName.isEmpty else {
            return
        }

        let provider = providerKind(for: agentKind)
        let sessionId = currentSessionId
        let toolName = currentRawToolName
        let workspaceRoot = currentWorkspaceRoot
        approvalPersistenceQueue.async { [weak self] in
            self?.persistApprovalScopeOnPersistenceQueue(
                approvalProxy: approvalProxy,
                provider: provider,
                approvalScope: approvalScope,
                sessionId: sessionId,
                toolName: toolName,
                workspaceRoot: workspaceRoot
            )
        }
    }

    private func persistApprovalScopeOnPersistenceQueue(
        approvalProxy: ApprovalProxyController,
        provider: ProviderKind,
        approvalScope: RuleScope,
        sessionId: String,
        toolName: String,
        workspaceRoot: String?
    ) {
        do {
            switch approvalScope {
            case .session:
                try approvalProxy.store.upsertSessionApproval(
                    provider: provider,
                    sessionId: sessionId,
                    toolName: toolName,
                    action: .allow,
                    expiresAt: nil
                )
            case .persistent:
                try approvalProxy.store.insertRule(ApprovalRule(
                    id: SQLiteApprovalStore.deterministicRuleID(
                        provider: provider,
                        toolName: toolName,
                        scope: .persistent,
                        workspaceRoot: workspaceRoot
                    ),
                    provider: provider,
                    toolName: toolName,
                    action: .allow,
                    scope: .persistent,
                    workspaceRoot: workspaceRoot
                ))
            case .once:
                break
            }
        } catch {
            print("[DevIsland] [POLICY] Failed to persist approval scope for \(provider.rawValue): \(error)")
        }
    }

    func approve(globalAlways: Bool = false, sessionAlways: Bool = false) {
        let tool = currentRawToolName.isEmpty ? currentToolName : currentRawToolName
        let sId = currentSessionId

        // in-memory sets are kept as a fast-path read cache for the current session.
        // SQLite is the durable source of truth (written via persistApprovalScope → sendDecision).
        if globalAlways && !tool.isEmpty {
            globalAutoApproveTypes.insert(tool)
        }
        if sessionAlways && !tool.isEmpty && !sId.isEmpty {
            if sessionStore.sessionAutoApproveTypes[sId] == nil {
                sessionStore.sessionAutoApproveTypes[sId] = []
            }
            sessionStore.sessionAutoApproveTypes[sId]?.insert(tool)
        }

        print("[DevIsland] approve() called, handler=\(currentResponseHandler != nil ? "SET" : "NIL")")

        // exit_plan_mode를 수동으로 승인했을 때도 Auto-Edit 모드 활성화
        if tool == "exit_plan_mode" {
            if let index = sessionStore.activeSessions.firstIndex(where: { $0.id == sId }) {
                sessionStore.activeSessions[index].isAutoEditActive = true
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

    func insertGlobalPersistentRule(_ toolName: String) {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        globalAutoApproveTypes.insert(trimmed)
        guard let proxy = approvalProxy else { return }
        approvalPersistenceQueue.async { [weak self] in
            do {
                try proxy.store.insertRule(ApprovalRule(
                    id: SQLiteApprovalStore.deterministicRuleID(
                        provider: .any,
                        toolName: trimmed,
                        scope: .persistent,
                        workspaceRoot: nil
                    ),
                    provider: .any,
                    toolName: trimmed,
                    action: .allow,
                    scope: .persistent
                ))
            } catch {
                print("[DevIsland] [POLICY] Failed to insert global persistent rule '\(trimmed)': \(error)")
                DispatchQueue.main.async { self?.globalAutoApproveTypes.remove(trimmed) }
            }
        }
    }

    func removeGlobalPersistentRule(_ toolName: String) {
        globalAutoApproveTypes.remove(toolName)
        guard let proxy = approvalProxy else { return }
        let ruleID = SQLiteApprovalStore.deterministicRuleID(
            provider: .any,
            toolName: toolName,
            scope: .persistent,
            workspaceRoot: nil
        )
        approvalPersistenceQueue.async {
            try? proxy.store.deleteRule(id: ruleID)
        }
    }

    func removeAllGlobalPersistentRules() {
        let tools = globalAutoApproveTypes
        globalAutoApproveTypes.removeAll()
        guard let proxy = approvalProxy else { return }
        approvalPersistenceQueue.async {
            for toolName in tools {
                let ruleID = SQLiteApprovalStore.deterministicRuleID(
                    provider: .any,
                    toolName: toolName,
                    scope: .persistent,
                    workspaceRoot: nil
                )
                try? proxy.store.deleteRule(id: ruleID)
            }
        }
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
                    self.insertGlobalPersistentRule(toolName)
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
                    if self.sessionStore.sessionAutoApproveTypes[sessionId] == nil {
                        self.sessionStore.sessionAutoApproveTypes[sessionId] = []
                    }
                    self.sessionStore.sessionAutoApproveTypes[sessionId]?.insert(toolName)
                }
            }
        }
    }

    private func restoreOpenSessions(from proxy: ApprovalProxyController) {
        let since = Date().addingTimeInterval(-24 * 60 * 60)
        let records: [OpenSessionRecord]
        do {
            records = try proxy.openSessions(since: since)
        } catch {
            print("[DevIsland] [RESTORE] Failed to query open sessions: \(error)")
            return
        }
        guard !records.isEmpty else { return }
        print("[DevIsland] [RESTORE] Restoring \(records.count) open session(s)")
        for record in records {
            guard let data = record.lastPayloadJSON.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let terminalTitle: String
            if let title = json["terminal_title"] as? String, !SessionStore.genericTitles.contains(title) {
                terminalTitle = title
            } else if let cwd = json["cwd"] as? String {
                let label = URL(fileURLWithPath: cwd).lastPathComponent
                terminalTitle = (!label.isEmpty && label != "/") ? label : "Session"
            } else {
                terminalTitle = "Session"
            }
            let agentKind = Self.agentKind(from: json, terminalTitle: terminalTitle)
            sessionStore.updateActiveSession(
                sessionId: record.sessionId,
                terminalTitle: terminalTitle,
                agentKind: agentKind,
                terminalApp: json["terminal_app"] as? String ?? "",
                terminalTTY: json["terminal_tty"] as? String ?? "",
                terminalWindowId: json["terminal_window_id"] as? String ?? "",
                terminalTabIndex: json["terminal_tab_index"] as? String ?? "",
                terminalTmuxPane: json["terminal_tmux_pane"] as? String ?? "",
                terminalTmuxSocket: json["terminal_tmux_socket"] as? String ?? "",
                terminalTmuxClient: json["terminal_tmux_client"] as? String ?? "",
                toolName: record.lastToolName,
                eventName: record.lastEventName,
                message: ToolMessageFormatter.displayMessage(
                    for: record.lastToolName,
                    toolInput: json["tool_input"] as? [String: Any],
                    json: json,
                    eventName: record.lastEventName
                ),
                isPending: false,
                isLifecycleTracked: true
            )
            // Preserve the original start time and last active time from SQLite
            if let index = sessionStore.activeSessions.firstIndex(where: { $0.id == record.sessionId }) {
                sessionStore.activeSessions[index].lastActiveAt = record.lastActiveAt
            }
        }
    }

    func showSessionDetail(_ sessionId: String) {
        guard currentResponseHandler == nil else { return }
        if isExpandingFromRequest && !currentSessionId.isEmpty && currentSessionId != sessionId {
            sessionStore.setUnread(false, sessionId: currentSessionId)
            previousSessionId = currentSessionId
        }
        sessionStore.selectedSessionId = sessionId
        sessionStore.setUnread(false, sessionId: sessionId)
        currentSessionId = sessionId
        syncDisplayToSelectedSession()
        isExpandingFromRequest = true
    }

    func dismissCurrentRequest() {
        if currentResponseHandler != nil {
            sendDecision(approved: false, reason: "Dismissed", passToTerminal: true)
        } else if isExpandingFromRequest {
            if !currentSessionId.isEmpty {
                sessionStore.setUnread(false, sessionId: currentSessionId)
            }
            notificationTimer?.invalidate()
            if let prev = previousSessionId {
                previousSessionId = nil
                currentSessionId = ""
                currentMessage = ""
                currentToolName = ""
                currentEventName = ""
                showSessionDetail(prev)
            } else {
                showNextRequest()
            }
        } else {
            isNotchExpanded = false
            notificationTimer?.invalidate()
        }
    }

    func focusTerminal(for sessionId: String? = nil) {
        let targetId = sessionId ?? (currentSessionId.isEmpty ? sessionStore.selectedSessionId : currentSessionId)
        let session = targetId.flatMap { id in
            sessionStore.activeSessions.first { $0.id == id }
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
