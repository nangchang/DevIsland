import SwiftUI
import Combine
import AppKit

// MARK: - App State

/**
 AppState is the central hub of the DevIsland application. It coordinates the lifecycle of
 agent sessions, manages the IPC socket server, handles the pending approval queue, and
 dispatches user or policy decisions back to the originating CLI bridge.
 
 Architectural separation:
 - `SessionStore`: Owns the list of active sessions and their metadata.
 - `GeminiSessionState`: Manages Gemini-specific preferences and interactive emulation state.
 - `PTYCoordinator`: Handles PTY I/O buffering and auto-injection pattern matching.
 - `ReplayRecorder`: Manages durable logging of hook events and decisions in SQLite.
 - `ApprovalProxyController`: Evaluates incoming requests against persistent and session-level rules.
 */
@MainActor
class AppState: ObservableObject {
    static let shared = AppState(
        startServer: ProcessInfo.processInfo.environment["XCODE_RUNNING_UNIT_TESTS"] != "1",
        approvalProxy: AppState.makeApprovalProxy()
    )
    private static let terminalFocusRecheckDelay: TimeInterval = 0.05

    private static func makeApprovalProxy() -> ApprovalProxyController? {
        do {
            return try ApprovalProxyController()
        } catch {
            print("[DevIsland] ApprovalProxyController init failed: \(error)")
            return nil
        }
    }

    private enum DefaultsKey {
        static let globalAutoApproveTypes = "globalAutoApproveTypes"
        static let autoApproveSafeTools = "autoApproveSafeTools"
        static let sessionLabels = "sessionLabels"
        static let sessionFavoriteIds = "sessionFavoriteIds"
        static let sessionDescriptions = "sessionDescriptions"
    }

    typealias FrontmostCheck = (TerminalContext) -> Bool

    private let userDefaults: UserDefaults
    private let frontmostCheck: FrontmostCheck

    @Published var isNotchExpanded = false
    @Published var isExpandingFromRequest = false
    /// The approval/notification currently displayed in the notch. Mutated only
    /// by AppState and ApprovalFlowCoordinator (the setter is internal for the
    /// ApprovalFlowContext conformance); UI reads it through the forwarding
    /// properties below.
    @Published var displayState = ApprovalDisplayState()
    var currentMessage: String { displayState.message }
    var currentSessionId: String { displayState.sessionId }
    var currentToolName: String { displayState.toolName }
    var currentEventName: String { displayState.eventName }
    var hasResponseHandler: Bool { displayState.hasResponseHandler }
    var currentClaudeQuestion: ClaudeQuestionRequest? { claudeQuestionState.currentClaudeQuestion }
    var currentClaudeQuestionAnswers: [String: ClaudeQuestionAnswer] { claudeQuestionState.currentClaudeQuestionAnswers }
    @Published var timeoutProgress: Double = 1.0
    @Published var notificationAutoCollapseProgress: Double = 1.0
    @Published var isNotificationAutoCollapseActive = false
    @Published var autoApproveSafeTools = false {
        didSet {
            userDefaults.set(autoApproveSafeTools, forKey: DefaultsKey.autoApproveSafeTools)
        }
    }
    
    // Durable Rule System:
    // New approvals are persisted to SQLiteApprovalStore via the ApprovalProxyController.
    // `globalAutoApproveTypes` serves as a fast-path in-memory cache for explicit
    // whole-tool approvals. Patterned SQLite rules stay in ApprovalPolicyEngine.
    @Published var globalAutoApproveTypes: Set<String> = []
    @Published var alwaysAllowSuggestion: String? = nil
    @Published var sessionLabels: [String: String] = [:] {
        didSet { userDefaults.set(sessionLabels, forKey: DefaultsKey.sessionLabels) }
    }
    @Published var sessionFavoriteIds: Set<String> = [] {
        didSet { userDefaults.set(Array(sessionFavoriteIds).sorted(), forKey: DefaultsKey.sessionFavoriteIds) }
    }
    @Published var sessionDescriptions: [String: String] = [:] {
        didSet { userDefaults.set(sessionDescriptions, forKey: DefaultsKey.sessionDescriptions) }
    }

    private static let bypassTools: Set<String> = ["update_topic", "activate_skill"]

    let sessionStore: SessionStore
    let geminiState: GeminiSessionState
    let displayPrefs: NotchDisplayPreferences
    let ruleService: ApprovalRuleService
    let claudeQuestionState: ClaudeQuestionState
    let caffeineCoordinator: CaffeineCoordinator
    let pluginHost: PluginHost
    /// Plugin/Caffeine post-construction wiring; owns the power and Wi-Fi
    /// monitors that feed the Caffeine coordinator (R2-d).
    private let wiring = AppWiring()

    // SQLite 기반 조회(리플레이/세션 인사이트)는 백그라운드 스레드(Task.detached)에서
    // 호출되므로 MainActor 격리 대상에서 제외한다. init 이후 재할당 없는 불변 참조.
    private nonisolated(unsafe) let approvalProxy: ApprovalProxyController?
    private var server = HookSocketServer()
    private var claudeQuestionCancellable: AnyCancellable?
    /// Pending-approval queue entry, display selection, decision dispatch, and
    /// timeout machinery (R2-c). Reaches back into AppState's presentation
    /// state via ApprovalFlowContext.
    private let approvalFlow: ApprovalFlowCoordinator
    private let notificationCountdown = CountdownTimer()
    private var sessionPruningTimer: Timer?
    private let approvalPersistenceQueue = DispatchQueue(label: "DevIsland.ApprovalPersistence", qos: .utility)
    private let ptyCoordinator: PTYCoordinator
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
    /// Internal (not private) so AppWiring's plugin/Caffeine closures can build events.
    let pluginEventFactory = PluginEventFactory()
    private let pluginScopedFileBroker: PluginScopedFileBroker

    init(
        startServer: Bool = true,
        userDefaults: UserDefaults = .standard,
        frontmostCheck: @escaping FrontmostCheck = TerminalFocuser.isSessionFrontmost,
        approvalProxy: ApprovalProxyController? = nil,
        codexRuleSyncAdapter: CodexRuleSyncAdapter = CodexJSONRuleSyncAdapter(),
        enablePlugins: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.frontmostCheck = frontmostCheck
        self.approvalProxy = approvalProxy
        self.sessionStore = SessionStore()
        self.geminiState = GeminiSessionState(userDefaults: userDefaults)
        self.displayPrefs = NotchDisplayPreferences(userDefaults: userDefaults)
        self.ruleService = ApprovalRuleService(
            approvalProxy: approvalProxy,
            codexRuleSyncAdapter: codexRuleSyncAdapter
        )
        self.claudeQuestionState = ClaudeQuestionState()
        let coordinator = CaffeineCoordinator()
        self.caffeineCoordinator = coordinator
        let scopedFileBroker = PluginScopedFileBroker(scopesByPluginID: Self.builtInPluginScopedFileScopes(
            userDefaults: userDefaults
        ))
        self.pluginScopedFileBroker = scopedFileBroker
        self.pluginHost = PluginHost(
            enablePlugins: enablePlugins,
            scopedFileBroker: scopedFileBroker,
            powerSleepHandler: { prevent, reason in
                await MainActor.run {
                    coordinator.applyPreventIdleSleep(prevent: prevent, reasonString: reason)
                }
            },
            powerToggleHandler: {
                Task { @MainActor in
                    let store = SettingsStore.shared
                    store.settings.caffeineEnabled.toggle()
                }
            }
        )
        self.ptyCoordinator = PTYCoordinator(
            ptyBuffer: PTYSessionBuffer(),
            approvalProxy: approvalProxy,
            persistenceQueue: approvalPersistenceQueue,
            userDefaults: userDefaults
        )
        self.replayRecorder = ReplayRecorder(proxy: approvalProxy, queue: approvalPersistenceQueue)
        self.approvalFlow = ApprovalFlowCoordinator(
            sessionStore: sessionStore,
            claudeQuestionState: claudeQuestionState,
            replayRecorder: replayRecorder,
            approvalProxy: approvalProxy,
            persistenceQueue: approvalPersistenceQueue,
            userDefaults: userDefaults,
            frontmostCheck: frontmostCheck
        )
        approvalFlow.context = self

        // Forward ClaudeQuestionState changes to AppState.objectWillChange so that
        // views observing AppState re-render when question/answer state changes.
        claudeQuestionCancellable = claudeQuestionState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }

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
        }
        autoApproveSafeTools = userDefaults.bool(forKey: DefaultsKey.autoApproveSafeTools)
        sessionLabels = userDefaults.dictionary(forKey: DefaultsKey.sessionLabels) as? [String: String] ?? [:]
        sessionFavoriteIds = Set(userDefaults.array(forKey: DefaultsKey.sessionFavoriteIds) as? [String] ?? [])
        sessionDescriptions = userDefaults.dictionary(forKey: DefaultsKey.sessionDescriptions) as? [String: String] ?? [:]

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

        // Wire plugins after restoreOpenSessions so restored sessions don't emit
        // spurious events. AppWiring registers plugins before the session callback
        // so they observe every subsequent session/hook event.
        wiring.wirePlugins(appState: self)
        wiring.wireCaffeine(appState: self)

        if startServer {
            BridgeTokenManager.shared.generateIfNeeded()

            server.onMessageReceived = { [weak self] message, requestId, authentication, responseHandler in
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
                self?.handleMessage(message, authentication: authentication, responseHandler: effectiveHandler)
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
                    if ModalPresenter.run(alert) == .alertFirstButtonReturn {
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
                    Task { @MainActor in SessionMessageWindowManager.shared.closeWindow(for: id) }
                }
            }
        }
    }

    nonisolated static func richResponseString(
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
        let responseToolInput = (parsed?["tool_input"] as? [String: Any])
            .flatMap { AnyJSON.object(from: $0) }
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
                toolInput: responseToolInput ?? toolInput,
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

    nonisolated static func providerContext(fromEnvelopeMessage message: String) -> (
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

    private nonisolated static func claudePermissionRuleContent(from payload: [String: AnyJSON]) -> String? {
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

    /// 현재 표시 중인 요청의 터미널이 포커스되었는지 확인하고, 그렇다면 자동으로 'pass' 또는 'dismiss' 처리
    func passIfTerminalFocused() {
        // 승인 대기 중이거나 정보성 알림이 표시 중일 때만 동작
        guard displayState.hasResponseHandler || (isNotchExpanded && isExpandingFromRequest) else { return }

        let session = sessionStore.activeSessions.first { $0.id == currentSessionId }

        isTerminalFrontmostAsync(for: session) { [weak self] isFrontmost in
            guard isFrontmost else { return }
            if self?.displayState.hasResponseHandler == true {
                print("[DevIsland] [AUTO] User moved focus to terminal, auto-passing request for \(self?.currentSessionId.prefix(8) ?? "")")
                self?.approvalFlow.sendDecision(approved: false, reason: "ManualFocus", status: .timeoutBypassed(Date()), passToTerminal: true)
            } else {
                print("[DevIsland] [AUTO] User moved focus to terminal, auto-dismissing notification for \(self?.currentSessionId.prefix(8) ?? "")")
                self?.stopNotificationAutoCollapseTimer()
                self?.isNotchExpanded = false
                self?.isExpandingFromRequest = false
            }
        }
    }

    /// 현재 화면에 표시할 데이터를 선택된 세션 정보로 업데이트
    func syncDisplayToSelectedSession() {
        guard !displayState.hasResponseHandler else { return }
        let sessionId = sessionStore.selectedSessionId ?? currentSessionId

        if let session = sessionStore.activeSessions.first(where: { $0.id == sessionId }) {
            DispatchQueue.main.async {
                guard !self.displayState.hasResponseHandler else { return }
                self.displayState.toolName = session.lastToolName
                self.displayState.eventName = session.lastEventName
                self.displayState.message = session.lastMessage
            }
        }
    }

    private static let builtInScopedFileScopeProviders: [any PluginScopedFileScopeProvider.Type] = [
        OpenPeonPlugin.self
    ]

    @MainActor
    func refreshPluginScopedFileScopes() {
        refreshPluginScopedFileScopes(settings: SettingsStore.shared.settings)
    }

    @MainActor
    func refreshPluginScopedFileScopes(settings: AppSettings) {
        let scopesByPluginID = Self.builtInPluginScopedFileScopes(settings: settings)
        Task { [pluginScopedFileBroker] in
            for (pluginID, scopes) in scopesByPluginID {
                await pluginScopedFileBroker.setScopes(scopes, forPluginID: pluginID)
            }
        }
    }

    private static func builtInPluginScopedFileScopes(userDefaults: UserDefaults) -> [String: [PluginScopedFileScope]] {
        Dictionary(uniqueKeysWithValues: builtInScopedFileScopeProviders.map {
            ($0.scopedFilePluginID, $0.scopedFileScopes(userDefaults: userDefaults))
        })
    }

    private static func builtInPluginScopedFileScopes(settings: AppSettings) -> [String: [PluginScopedFileScope]] {
        Dictionary(uniqueKeysWithValues: builtInScopedFileScopeProviders.map {
            ($0.scopedFilePluginID, $0.scopedFileScopes(settings: settings))
        })
    }

    /// Starts the plugin platform once the app has finished launching: emits the
    /// `plugin.started`/`app.started` lifecycle events and starts the central tick loop.
    /// Order matters: `plugin.started` first lets a plugin restore its own state before
    /// `app.started` triggers app-level side effects against that restored state.
    /// Called from the main thread (AppDelegate launch block).
    func startPluginPlatform() {
        pluginHost.enqueue(pluginEventFactory.makeLifecycleEvent(kind: .pluginStarted))
        pluginHost.enqueue(pluginEventFactory.makeLifecycleEvent(kind: .appStarted))
        // Sessions restored before the event seam was wired emitted no session.started,
        // so session-scoped plugins never observed them. Replay a controlled started
        // batch here (once, at platform start) so per-session surfaces — row badges and
        // context actions — cover restored sessions too. (PR #276 Gemini review)
        for session in sessionStore.activeSessions {
            pluginHost.enqueue(pluginEventFactory.makeSessionEvent(kind: .sessionStarted, from: session))
        }
        pluginHost.startTicking()
    }

    /// Stops the plugin platform tick loop on app termination.
    /// Called from the main thread (AppDelegate termination).
    func stopPluginPlatform() {
        pluginHost.stopTicking()
    }

    func handleMessage(
        _ message: String,
        authentication: HookMessageAuthentication = .legacyAllowed,
        responseHandler: @escaping (String) -> Void
    ) {
        switch HookEventHandler.parse(message, authentication: authentication) {
        case .invalid:
            responseHandler(HookResponse(.approved).jsonString())
            return
        case .denied:
            responseHandler(HookResponse(.denied).jsonString())
            return
        case .parsed(let h):
            handleParsedEvent(h, responseHandler: responseHandler)
        }
    }

    private func handleParsedEvent(_ h: ParsedHookEvent, responseHandler: @escaping (String) -> Void) {
        let ud = self.userDefaults
        let routingSettings = HookRoutingSettings(
            processVSCode: ud.bool(forKey: "processVSCodeEnabled"),
            processClaudeDesktop: ud.bool(forKey: "processClaudeDesktopEnabled"),
            processCodexDesktop: ud.bool(forKey: "processCodexDesktopEnabled"),
            emulateGeminiInteractiveMode: geminiState.emulateInteractiveMode
        )
        let routed = HookEventRouter.route(h, settings: routingSettings)

        // MARK: Phase 1–2a: routes resolved before replay recording
        switch routed.route {
        case .integrationDisabledPass:
            responseHandler(HookResponse(.pass).jsonString())
            return
        case .subAgent:
            handleSubAgentEvent(h, displayToolName: h.displayToolName, responseHandler: responseHandler)
            return
        case .ptyOutput:
            // Processed separately to avoid replay log pollution.
            ptyCoordinator.handleOutputEvent(
                sessionId: h.sessionId,
                provider: providerKind(for: h.agentKind),
                content: (h.parsedJSON["content"] as? String) ?? "",
                responseHandler: responseHandler
            )
            return
        case .stop, .promptPolicyDenied, .userQuestionPassthrough, .notification,
             .nonApprovalAutoApprove, .emptyApprovalAutoApprove, .claudeQuestion, .approval:
            break
        }

        // MARK: Phase 2b: Replay Recording + Plugin Observation
        let hookEventId = recordReplayHookEvent(
            requestId: h.requestId,
            provider: providerKind(for: h.agentKind),
            sessionId: h.sessionId,
            eventName: h.event,
            toolName: h.toolName,
            payload: h.parsedJSON
        )
        // Enqueue on main queue so it serializes before the session mutation dispatched
        // from handleNotificationEvent's DispatchQueue.main.async block.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let session = self.sessionStore.activeSessions.first { $0.id == h.sessionId }
            self.pluginHost.enqueue(self.pluginEventFactory.makeHookReceivedEvent(from: h, session: session))
        }

        let classification = routed.classification
        let displayToolName = classification.displayToolName
        let replayToolName = classification.replayToolName

        switch routed.route {
        case .integrationDisabledPass, .subAgent, .ptyOutput:
            return  // resolved before replay recording above

        // MARK: Phase 2c: Stop
        case .stop:
            handleStopEvent(h, hookEventId: hookEventId, replayToolName: replayToolName, responseHandler: responseHandler)
            return

        // MARK: Phase 2d: UserPromptSubmit Policy
        case .promptPolicyDenied(let denialReason):
            print("[DevIsland] Claude UserPromptSubmit blocked by prompt policy")
            respondWithReplay(
                HookResponse(.denied, reason: denialReason).jsonString(),
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
            return

        // MARK: Phase 2e: Claude user-question follow-up passthrough
        case .userQuestionPassthrough:
            print("[DevIsland] passing Claude user-question \(h.event) without notification: \(h.toolName)")
            respondWithReplay(
                HookResponse(.pass).jsonString(),
                responseHandler: responseHandler,
                hookEventId: hookEventId,
                agentKind: h.agentKind,
                sessionId: h.sessionId,
                toolName: replayToolName,
                workspaceRoot: h.workspaceRoot,
                action: .prompt,
                source: .automatic,
                reason: "Claude user question follow-up passthrough"
            )
            return

        // MARK: Phase 2f: Notification
        case .notification:
            handleNotificationEvent(
                h,
                hookEventId: hookEventId,
                isCodexStatusOnlyLifecycleEvent: classification.isCodexStatusOnlyLifecycleEvent,
                isUserQuestionTool: classification.isUserQuestionTool,
                displayToolName: displayToolName,
                replayToolName: replayToolName,
                responseHandler: responseHandler
            )
            return

        // MARK: Phase 3: Decision Logic
        case .nonApprovalAutoApprove(let isGeminiNormalMode):
            print("[DevIsland] ignoring non-approval h.event (or Gemini normal mode): \(h.event)")
            if isGeminiNormalMode && h.toolName == "enter_plan_mode" {
                DispatchQueue.main.async {
                    if let index = self.sessionStore.activeSessions.firstIndex(where: { $0.id == h.sessionId }) {
                        self.sessionStore.activeSessions[index].isAutoEditActive = false
                    }
                }
            }
            respondWithReplay(
                HookResponse(.approved).jsonString(),
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

        case .emptyApprovalAutoApprove:
            print("[DevIsland] ignoring empty approval request")
            respondWithReplay(
                HookResponse(.approved).jsonString(),
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

        case .claudeQuestion, .approval:
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
                claudeQuestion: classification.claudeQuestion,
                responseHandler: responseHandler,
                receivedAt: Date()
            )
            if case .claudeQuestion = routed.route {
                handleClaudeQuestionRequest(
                    h,
                    request: request,
                    hookEventId: hookEventId,
                    replayToolName: replayToolName,
                    displayToolName: displayToolName
                )
            } else {
                handleApprovalRequest(
                    h,
                    request: request,
                    hookEventId: hookEventId,
                    settings: routingSettings,
                    replayToolName: replayToolName,
                    displayToolName: displayToolName
                )
            }
            return
        }
    }

    // MARK: - Phase 3 handler: Claude question

    /// Claude AskUserQuestion 구조화 응답 요청 — 터미널이 포커스면 pass, 아니면 수동 큐잉.
    private func handleClaudeQuestionRequest(
        _ h: ParsedHookEvent,
        request: PendingRequest,
        hookEventId: Int64?,
        replayToolName: String,
        displayToolName: String
    ) {
        isTerminalFrontmostAsync(terminal: h.terminal) { [weak self] isFrontmost in
            guard let self else { return }
            if !h.isReplayPayload && isFrontmost {
                print("[DevIsland] [PASS] Terminal is frontmost, passing Claude question for session \(h.sessionId.prefix(8))")
                self.passRequestToFocusedTerminal(
                    h,
                    request: request,
                    hookEventId: hookEventId,
                    replayToolName: replayToolName,
                    displayToolName: displayToolName
                )
                return
            }

            // 기존 세션의 lifecycle 추적 여부 보존 — 질문 요청이 추적 상태를 바꾸지 않도록
            let isLifecycleTracked = self.sessionStore.activeSessions
                .first { $0.id == request.sessionId }?.isLifecycleTracked
                ?? (request.agentKind != .claudeCode)
            self.approvalFlow.enqueueManualRequest(request, from: h, isLifecycleTracked: isLifecycleTracked)
        }
    }

    // MARK: - Phase 3–4 handler: Approval evaluation

    /// 승인 이벤트 — 휘발성 자동 승인 판정(HookEventRouter.approvalRouting)을 거쳐
    /// 평가 계층을 수행한다.
    private func handleApprovalRequest(
        _ h: ParsedHookEvent,
        request: PendingRequest,
        hookEventId: Int64?,
        settings: HookRoutingSettings,
        replayToolName: String,
        displayToolName: String
    ) {
        let approvalState = ApprovalStateSnapshot(
            globalAutoApproveTools: globalAutoApproveTypes,
            sessionAutoApproveTools: sessionStore.sessionAutoApproveTypes[h.sessionId] ?? [],
            isAutoEditActive: sessionStore.activeSessions.first(where: { $0.id == h.sessionId })?.isAutoEditActive ?? false,
            autoApproveSafeTools: autoApproveSafeTools
        )
        let routing = HookEventRouter.approvalRouting(h, settings: settings, state: approvalState)
        if routing.isEmulationForced {
            print("[DevIsland] [EMULATION] \(h.agentKind.accessibilityName) interactive emulation forced for tool: \(h.toolName)")
        }

        // MARK: Phase 4: Evaluation Hierarchy
        // 우선순위: 터미널 포커스 pass → 영속 정책 → 휘발성 자동 승인 → 수동 승인 큐잉.
        isTerminalFrontmostAsync(terminal: h.terminal) { [weak self] isFrontmost in
            guard let self = self else { return }

            // 1. 터미널 포커스 최우선 — 사용자가 이미 터미널에 있으면 CLI가 자체 처리하도록 pass
            if !h.isReplayPayload && isFrontmost {
                print("[DevIsland] [PASS] Terminal is frontmost, responding with 'pass' for session \(h.sessionId.prefix(8))")
                self.passRequestToFocusedTerminal(
                    h,
                    request: request,
                    hookEventId: hookEventId,
                    replayToolName: replayToolName,
                    displayToolName: displayToolName
                )
                return
            }

            // 2. Persistent Policy Check: Check SQLite for durable rules (Exact, Glob, Regex).
            if let policyDecision = self.policyDecision(
                provider: self.providerKind(for: h.agentKind),
                hookEventId: hookEventId,
                sessionId: h.sessionId,
                toolName: h.toolName,
                workspaceRoot: h.workspaceRoot,
                toolInput: h.toolInput
            ) {
                self.applyPolicyDecision(policyDecision, to: request, h: h, displayToolName: displayToolName)
                return
            }

            // 3. Volatile/Cache Approval: Check in-memory fast-path and mode-based auto-approvals.
            if routing.isAutoApproved {
                self.autoApproveRequest(
                    h,
                    request: request,
                    hookEventId: hookEventId,
                    replayToolName: replayToolName,
                    displayToolName: displayToolName,
                    isInteractive: routing.isInteractive,
                    isAutoEditActive: routing.isAutoEditActive,
                    isSafeAutoApprove: routing.isSafeAutoApprove
                )
                return
            }

            // 4. enter_plan_mode가 자동 승인 없이 UI로 넘어갈 때 Auto-Edit 해제
            if h.toolName == "enter_plan_mode",
               let index = self.sessionStore.activeSessions.firstIndex(where: { $0.id == h.sessionId }) {
                self.sessionStore.activeSessions[index].isAutoEditActive = false
                print("[DevIsland] [MODE] Session \(h.sessionId.prefix(8)) switched to Plan mode")
            }

            // 5. Manual Approval Fallback: No rules matched, enqueue for user decision in the Notch.
            self.approvalFlow.enqueueManualRequest(request, from: h, isLifecycleTracked: h.agentKind != .claudeCode)
        }
    }

    // MARK: - Phase 1 handler: Sub-Agent

    private func handleSubAgentEvent(
        _ h: ParsedHookEvent,
        displayToolName: String,
        responseHandler: @escaping (String) -> Void
    ) {
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
                    self.updateActiveSession(
                        from: h,
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
        responseHandler(HookResponse(.approved).jsonString())
    }

    // MARK: - Phase 2c handler: Stop

    private func handleStopEvent(
        _ h: ParsedHookEvent,
        hookEventId: Int64?,
        replayToolName: String,
        responseHandler: @escaping (String) -> Void
    ) {
        guard !h.sessionId.isEmpty else {
            respondWithReplay(
                HookResponse(.approved).jsonString(),
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
            self.approvalFlow.removeSuspendedAnswers(for: removedRequests)
            removedRequests.forEach {
                self.respondWithReplay(
                    HookResponse(.denied).jsonString(),
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
            SessionMessageWindowManager.shared.closeWindow(for: fullSessionId)

            if self.currentSessionId == fullSessionId || removedRequests.contains(where: { $0.id == self.displayState.showingRequestId }) {
                self.approvalFlow.clearCurrentRequestDisplay()
            }

            if self.sessionStore.pendingQueue.isEmpty {
                self.isNotchExpanded = false
                self.syncDisplayToSelectedSession()
            } else if !self.displayState.hasResponseHandler {
                self.approvalFlow.showNextRequest()
            }
        }
        respondWithReplay(
            HookResponse(.approved).jsonString(),
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
    }

    // MARK: - Phase 2f handler: Notification

    private func handleNotificationEvent(
        _ h: ParsedHookEvent,
        hookEventId: Int64?,
        isCodexStatusOnlyLifecycleEvent: Bool,
        isUserQuestionTool: Bool,
        displayToolName: String,
        replayToolName: String,
        responseHandler: @escaping (String) -> Void
    ) {
        let normalizedEvent = HookEventNormalizer.normalizedName(h.event)
        let passClaudeUserQuestion = h.agentKind == .claudeCode && isUserQuestionTool
        let notification = passClaudeUserQuestion
            ? (decision: HookDecision.pass, action: RuleAction.prompt, reason: "Claude user question passthrough")
            : (decision: HookDecision.approved, action: RuleAction.allow, reason: "notification")

        print("[DevIsland] notification event: \(h.event) for \(h.toolName) → \(notification.decision.rawValue)")
        guard !h.sessionId.isEmpty else {
            respondWithReplay(
                HookResponse(notification.decision).jsonString(),
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
                HookResponse(.approved).jsonString(),
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

        Task { @MainActor in
            // sessionStore 뮤테이션은 항상 메인 스레드에서 수행 (@Published → SwiftUI 업데이트)
            if isStartEvent &&
                h.agentKind == .codex &&
                HookEventRouter.shouldSupersedeCodexSessionsOnStart(source: h.sessionStartSource) {
                let removedSessionIds = self.sessionStore.removeSupersededCodexSessions(
                    newSessionId: fullSessionId,
                    terminal: h.terminal
                )

                var removedCurrentRequest = false
                for removedSessionId in removedSessionIds {
                    let removedRequests = self.sessionStore.removeAllPending(sessionId: removedSessionId)
                    self.approvalFlow.removeSuspendedAnswers(for: removedRequests)
                    if removedRequests.contains(where: { $0.id == self.displayState.showingRequestId }) {
                        removedCurrentRequest = true
                    }
                    removedRequests.forEach {
                        self.respondWithReplay(
                            HookResponse(.denied).jsonString(),
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
                    SessionMessageWindowManager.shared.closeWindow(for: removedSessionId)
                }

                if removedSessionIds.contains(self.currentSessionId) || removedCurrentRequest {
                    self.approvalFlow.clearCurrentRequestDisplay()
                    self.approvalFlow.showNextRequest()
                }
            }

            let hasPendingForSession = self.sessionStore.pendingQueue.contains { $0.sessionId == fullSessionId }
            self.updateActiveSession(
                from: h,
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

            // notification 이벤트 케이스 분류 (케이스별로 독립 제어 가능)
            let isTaskCompletion  = !isCodexStatusOnlyLifecycleEvent && normalizedEvent == "stop"
            let isIdleOrWaiting   = !isCodexStatusOnlyLifecycleEvent && isIdlePrompt
            let isNotificationMsg = !isCodexStatusOnlyLifecycleEvent &&
                (isUserQuestionTool || (h.displayMsg.contains("?") && (normalizedEvent == "notification" || h.agentKind != .claudeCode)))
            // isInformational = unread dot 표시 게이트 (확장 설정과 무관하게 유지)
            let isInformational = isTaskCompletion || isIdleOrWaiting || isNotificationMsg
                || (!isCodexStatusOnlyLifecycleEvent && isStartEvent)

            let isCurrentlyViewed = self.isExpandingFromRequest && self.currentSessionId == fullSessionId
            if isInformational && !isStartEvent && !sessionMessage.isEmpty && !isCurrentlyViewed {
                self.sessionStore.setUnread(true, sessionId: fullSessionId)
            }

            let expandEnabled: Bool = {
                let s = SettingsStore.shared.settings
                guard s.notchAutoExpandEnabled && s.expandOnNotification else { return false }
                if isTaskCompletion  { return s.expandOnTaskCompletion }
                if isIdleOrWaiting   { return s.expandOnIdlePrompt }
                if isNotificationMsg { return s.expandOnNotificationMessage }
                return false
            }()
            if isInformational && !isStartEvent && !hasPendingForSession && !self.displayState.hasResponseHandler {
                // expandEnabled 여부와 무관하게 포커스된 터미널의 unread 해제는 항상 수행
                let session = self.sessionStore.activeSessions.first { $0.id == fullSessionId }
                self.isTerminalFrontmostAsync(for: session) { [weak self] isFrontmost in
                    guard let self else { return }
                    if isFrontmost {
                        self.sessionStore.setUnread(false, sessionId: fullSessionId)
                        return  // frontmost: UI 변화 없음 → notification.shown 발행 안 함
                    }
                    // NOT frontmost: unread dot 유지 확정 → notification.shown 발행
                    if let s = self.sessionStore.activeSessions.first(where: { $0.id == fullSessionId }) {
                        self.pluginHost.enqueue(self.pluginEventFactory.makeSessionEvent(kind: .notificationShown, from: s))
                    }
                    if isTaskCompletion {
                        let enabled = SettingsStore.shared.settings.notificationsEnabled
                        if enabled {
                            let title = self.sessionStore.activeSessions.first { $0.id == fullSessionId }?.terminalTitle ?? ""
                            NotificationManager.shared.sendTaskCompletion(sessionTitle: title)
                        }
                    }
                    guard expandEnabled else { return }
                    guard !self.displayState.hasResponseHandler else { return }
                    // 세션의 팝아웃 창이 열려있으면 노치 확장 억제 — 창이 알림을 표시함
                    let hasDetachedWindow = SessionMessageWindowManager.shared.hasWindow(for: fullSessionId)
                    guard !hasDetachedWindow else { return }
                    if self.isExpandingFromRequest && !self.currentSessionId.isEmpty && self.currentSessionId != fullSessionId {
                        self.sessionStore.setUnread(false, sessionId: self.currentSessionId)
                        self.approvalFlow.previousSessionId = self.currentSessionId
                    }
                    self.displayState.toolName = displayToolName
                    self.displayState.eventName = h.event
                    self.displayState.message = sessionMessage
                    self.displayState.sessionId = fullSessionId
                    self.isNotchExpanded = true
                    self.isExpandingFromRequest = true

                    self.stopNotificationAutoCollapseTimer()
                    if let delay = self.notificationAutoCollapseDelay {
                        self.startNotificationAutoCollapseTimer(delay: delay)
                    }
                }
            } else if isInformational && !isStartEvent && !isCurrentlyViewed && !sessionMessage.isEmpty {
                // hasPendingForSession || hasResponseHandler: frontmost 체크 없이
                // setUnread(true)가 이미 됐으므로 notification.shown 발행
                if let s = self.sessionStore.activeSessions.first(where: { $0.id == fullSessionId }) {
                    self.pluginHost.enqueue(self.pluginEventFactory.makeSessionEvent(kind: .notificationShown, from: s))
                }
            }
        }

        respondWithReplay(
            HookResponse(notification.decision).jsonString(),
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
    }

    // MARK: - Phase 4 handlers: Evaluation Hierarchy

    /// ParsedHookEvent의 세션/터미널 메타데이터를 그대로 전달하는 updateActiveSession 축약.
    private func updateActiveSession(
        from h: ParsedHookEvent,
        toolName: String,
        eventName: String,
        message: String,
        isPending: Bool,
        preserveMessage: Bool = false,
        isLifecycleTracked: Bool = false,
        isSubAgentSession: Bool = false,
        parentSessionId: String? = nil,
        status: SessionStatus? = nil
    ) {
        sessionStore.updateActiveSession(
            sessionId: h.sessionId,
            terminalTitle: h.terminalTitle,
            agentKind: h.agentKind,
            terminal: h.terminal,
            toolName: toolName,
            eventName: eventName,
            message: message,
            isPending: isPending,
            preserveMessage: preserveMessage,
            isLifecycleTracked: isLifecycleTracked,
            isSubAgentSession: isSubAgentSession,
            parentSessionId: parentSessionId,
            status: status,
            workspaceRoot: h.workspaceRoot
        )
    }

    /// 4-1. 터미널이 포커스된 상태 — CLI 자체 프롬프트에 위임(pass)하고 세션을
    /// timeout-bypassed로 표시한다. Claude 질문 경로와 승인 경로가 공유한다.
    private func passRequestToFocusedTerminal(
        _ h: ParsedHookEvent,
        request: PendingRequest,
        hookEventId: Int64?,
        replayToolName: String,
        displayToolName: String
    ) {
        respondWithReplay(
            HookResponse(.pass).jsonString(),
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
        guard !h.sessionId.isEmpty else { return }
        updateActiveSession(
            from: h,
            toolName: displayToolName,
            eventName: h.event,
            message: h.displayMsg,
            isPending: false,
            status: SessionStatus.timeoutBypassed(Date())
        )
    }

    /// 4-2. 영속 정책(SQLite 규칙) 매칭 — 정책 결과로 즉시 응답하고 세션 상태를 갱신한다.
    /// 결정 기록은 policyDecision()이 이미 수행하므로 여기서는 응답만 보낸다.
    private func applyPolicyDecision(
        _ policyDecision: ApprovalPolicyDecision,
        to request: PendingRequest,
        h: ParsedHookEvent,
        displayToolName: String
    ) {
        let provider = providerKind(for: h.agentKind)
        print("[DevIsland] [POLICY] \(provider.rawValue) \(h.toolName) matched \(policyDecision.source.rawValue): \(policyDecision.action.rawValue)")
        request.responseHandler(responsePayload(approved: policyDecision.action == .allow))
        updateActiveSession(
            from: h,
            toolName: displayToolName,
            eventName: h.event,
            message: "Policy \(policyDecision.action.rawValue): \(displayToolName)",
            isPending: false,
            preserveMessage: true,
            isLifecycleTracked: true,
            status: policyDecision.action == .allow ? .policyApproved(Date()) : .policyDenied(Date())
        )
    }

    /// 4-3. 휘발성 자동 승인 — 즉시 승인 응답 후, interactive 툴이면 터미널 복귀 알림을
    /// 띄우고 plan 모드 전환 툴이면 세션의 Auto-Edit 상태를 갱신한다.
    private func autoApproveRequest(
        _ h: ParsedHookEvent,
        request: PendingRequest,
        hookEventId: Int64?,
        replayToolName: String,
        displayToolName: String,
        isInteractive: Bool,
        isAutoEditActive: Bool,
        isSafeAutoApprove: Bool
    ) {
        print("[DevIsland] [AUTO-APPROVE] Tool \(h.toolName) is auto-approved for session \(h.sessionId.prefix(8)) (AutoEdit: \(isAutoEditActive), SafeBypass: \(isSafeAutoApprove))")
        respondWithReplay(
            HookResponse(.approved).jsonString(),
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
        let interactiveExpandEnabled = SettingsStore.shared.settings.notchAutoExpandEnabled
            && SettingsStore.shared.settings.expandOnInteractiveTool
        if isInteractive && !h.isReplayPayload && interactiveExpandEnabled {
            isNotchExpanded = true
            isExpandingFromRequest = true
            displayState.sessionId = h.sessionId
            displayState.message = L10n.shared.terminalCheckMsg(displayToolName)
        }

        if h.toolName == "exit_plan_mode",
           let index = sessionStore.activeSessions.firstIndex(where: { $0.id == h.sessionId }) {
            sessionStore.activeSessions[index].isAutoEditActive = true
            print("[DevIsland] [MODE] Session \(h.sessionId.prefix(8)) switched to Auto-Edit mode")
        }
        if h.toolName == "enter_plan_mode",
           let index = sessionStore.activeSessions.firstIndex(where: { $0.id == h.sessionId }) {
            sessionStore.activeSessions[index].isAutoEditActive = false
            print("[DevIsland] [MODE] Session \(h.sessionId.prefix(8)) switched to Plan mode")
        }

        guard !h.sessionId.isEmpty else { return }
        updateActiveSession(
            from: h,
            toolName: displayToolName,
            eventName: h.event,
            message: isInteractive ? L10n.shared.terminalWaiting : "Auto-approved: \(displayToolName)",
            isPending: false,
            preserveMessage: true,
            isLifecycleTracked: true,
            status: .autoApproved(Date())
        )
    }

    static func agentKind(from json: [String: Any], terminalTitle: String) -> BuddyKind {
        HookEventNormalizer.agentKind(from: json, terminalTitle: terminalTitle)
    }

    private func recordDismissedSession(sessionId: String, agentKind: BuddyKind, completion: @escaping () -> Void) {
        guard let approvalProxy else {
            completion()
            return
        }
        let payloadJSON = ReplayRecorder.payloadString(from: ["session_id": sessionId, "source": "user_dismissed"])
        approvalPersistenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                try approvalProxy.recordHookEvent(
                    requestId: nil,
                    provider: self.providerKind(for: agentKind),
                    sessionId: sessionId,
                    eventName: "devisland_dismissed",
                    toolName: "",
                    payloadJSON: payloadJSON
                )
            } catch {
                print("[DevIsland] [REPLAY] Failed to record dismissed session: \(error)")
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// The session the user is currently viewing: the displayed request's session if one is
    /// shown, otherwise the user's selected session (`nil` when none). Mirrors the notch's
    /// displayed-session logic so plugin global slots track the same session the user sees.
    var displayedSessionID: String? {
        currentSessionId.isEmpty ? sessionStore.selectedSessionId : currentSessionId
    }

    /// Host Command Catalog entry for a plugin-requested `session.dismiss`. The plugin
    /// only proposes; the host authorizes here. Routed from `PluginHost.handleAction`
    /// via the AppWiring-installed callback (internal for that wiring).
    @MainActor
    func handlePluginSessionCommand(_ capability: String, sessionID: String) {
        switch capability {
        case "session.dismiss":
            dismissSessionFromPlugin(sessionID)
            return
        case "session.copyResumeCommand":
            copyResumeCommandFromPlugin(sessionID)
            return
        case "session.focusTerminal":
            focusTerminalFromPlugin(sessionID)
            return
        case "session.openWorkspace":
            openWorkspaceFromPlugin(sessionID)
            return
        default:
            return
        }
    }

    /// Opens a plugin-requested session's workspace root in Finder. Side-effect-free with
    /// respect to core state: it only activates Finder (never a terminal), so the window
    /// observers' `passIfTerminalFocused()` finds no terminal frontmost and the approval queue
    /// is untouched. No-op when the session has no workspace root. (architecture doc §8, v1.2)
    @MainActor
    private func openWorkspaceFromPlugin(_ sessionID: String) {
        guard let session = sessionStore.activeSessions.first(where: { $0.id == sessionID }) else {
            print("[DevIsland] [plugin-cmd] openWorkspace: no session \(sessionID.prefix(8))")
            return
        }
        guard let root = session.workspaceRoot, !root.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: root))
    }

    /// Whether a plugin may focus a session terminal right now without disturbing an approval.
    /// Bringing a terminal to the front fires NotchWindowController's activation/click observers,
    /// which call `passIfTerminalFocused()` — and that passes a shown request to the terminal. So
    /// a plugin-initiated focus must be refused in exactly the state that guard fires in, keeping
    /// the command approval-neutral. (PR #280 codex review, architecture doc §8)
    var canPluginFocusTerminal: Bool {
        !displayState.hasResponseHandler && !(isNotchExpanded && isExpandingFromRequest)
    }

    /// Brings a plugin-requested session's terminal to the front. Deliberately does NOT reuse
    /// `focusTerminal(for:)`: that path clears unread/missed flags and schedules
    /// `passIfTerminalFocused()`, which passes a pending approval to the terminal — a plugin
    /// action must never touch the approval queue or session state. This calls `TerminalFocuser`
    /// directly with the session's own terminal metadata, so it only moves window focus.
    /// (architecture doc §8, v1.2)
    @MainActor
    private func focusTerminalFromPlugin(_ sessionID: String) {
        // Even without the focusTerminal(for:) completion callback, making the terminal frontmost
        // would let the window observers auto-pass a shown approval. Refuse while one is on screen.
        guard canPluginFocusTerminal else {
            print("[DevIsland] [plugin-cmd] focusTerminal: refused while a request is shown")
            return
        }
        guard let session = sessionStore.activeSessions.first(where: { $0.id == sessionID }) else {
            print("[DevIsland] [plugin-cmd] focusTerminal: no session \(sessionID.prefix(8))")
            return
        }
        TerminalFocuser.focusTerminal(
            session.terminal,
            title: session.terminalTitle,
            workspaceRoot: session.workspaceRoot
        )
    }

    /// Copies the host-generated resume command for a plugin-requested session to the pasteboard.
    /// Side-effect-free with respect to core state: it never touches the approval queue, pending
    /// requests, provider responses, or session lifecycle — so the plugin path stays observation-
    /// adjacent and cannot influence an approval decision. (architecture doc §8, v1.2)
    @MainActor
    private func copyResumeCommandFromPlugin(_ sessionID: String) {
        guard let session = sessionStore.activeSessions.first(where: { $0.id == sessionID }) else {
            print("[DevIsland] [plugin-cmd] copyResumeCommand: no session \(sessionID.prefix(8))")
            return
        }
        let command = session.resumeCommand
        guard !command.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// A plugin may dismiss only sessions that need no user attention. Extracted as a pure
    /// predicate so the policy is unit-testable without a full AppState. Pending /
    /// current-approval / missed / unread sessions are excluded so a plugin action can
    /// never pass a provider response or drain the approval queue (which `dismissSession`
    /// does for a pending session). (architecture doc §7/§8, §8 capability↔permission table)
    static func isPluginDismissable(_ session: ActiveSession) -> Bool {
        session.status == .idle
            && !session.isPending
            && !session.hasMissedApproval
            && !session.isUnread
    }

    /// Host-validated dismissal of a plugin-requested `session.dismiss`.
    @MainActor
    private func dismissSessionFromPlugin(_ sessionID: String) {
        guard let session = sessionStore.activeSessions.first(where: { $0.id == sessionID }),
              Self.isPluginDismissable(session)
        else { return }
        dismissSession(sessionID, requirePluginDismissable: true)
    }

    /// `requirePluginDismissable` re-checks the dismissal policy inside the delayed removal
    /// completion. `dismissSession` records the dismissal on a background queue and only
    /// removes the session (draining pending requests with a `pass`) once that returns, so a
    /// new approval can arrive in between. The plugin path re-validates here to guarantee a
    /// plugin action never passes a freshly-arrived provider request. (PR #276 Codex review)
    func dismissSession(_ sessionId: String, requirePluginDismissable: Bool = false) {
        let agentKind = sessionStore.activeSessions.first(where: { $0.id == sessionId })?.agentKind ?? .claudeCode
        recordDismissedSession(sessionId: sessionId, agentKind: agentKind) {
            if requirePluginDismissable {
                guard let current = self.sessionStore.activeSessions.first(where: { $0.id == sessionId }),
                      Self.isPluginDismissable(current)
                else { return }
            }
            let removedRequests = self.sessionStore.removeAllPending(sessionId: sessionId)
            self.approvalFlow.removeSuspendedAnswers(for: removedRequests)
            removedRequests.forEach { $0.responseHandler(HookResponse(.pass).jsonString()) }
            self.sessionStore.removeSession(id: sessionId)
            self.ptyCoordinator.clearBuffer(sessionId: sessionId)
            SessionMessageWindowManager.shared.closeWindow(for: sessionId)

            if self.currentSessionId == sessionId || removedRequests.contains(where: { $0.id == self.displayState.showingRequestId }) {
                self.displayState.responseHandler?(HookResponse(.pass).jsonString())
                self.approvalFlow.clearCurrentRequestDisplay()
            }

            if self.sessionStore.pendingQueue.isEmpty {
                if self.sessionStore.activeSessions.isEmpty {
                    self.isNotchExpanded = false
                    self.sessionStore.selectedSessionId = nil
                }
                self.syncDisplayToSelectedSession()
            } else if !self.displayState.hasResponseHandler {
                self.approvalFlow.showNextRequest()
            }
        }
    }

    private func isTerminalFrontmostAsync(for session: ActiveSession?, completion: @escaping (Bool) -> Void) {
        isTerminalFrontmostAsync(terminal: session?.terminal ?? TerminalContext(), completion: completion)
    }

    private func isTerminalFrontmostAsync(
        terminal: TerminalContext,
        completion: @escaping (Bool) -> Void
    ) {
        let frontmostCheck = self.frontmostCheck

        Task.detached(priority: .userInitiated) {
            let isFrontmost = frontmostCheck(terminal)
            await MainActor.run {
                completion(isFrontmost)
            }
        }
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
        agentKind.providerKind
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
        HookResponse(approved ? .approved : .denied).jsonString()
    }

    // 아래 4개 조회 메서드는 Task.detached에서 호출되는 SQLite I/O이므로 nonisolated —
    // MainActor 전환 시에도 메인 스레드 블로킹 방지 의도를 그대로 유지한다.
    nonisolated func replayLogEntries(limit: Int = 200) throws -> [ReplayLogEntry] {
        guard let approvalProxy else { return [] }
        return try approvalProxy.replayLog(limit: limit)
    }

    nonisolated func sessionMessageHistory(sessionId: String, limit: Int = 100) throws -> [ReplayLogEntry] {
        guard let approvalProxy else { return [] }
        return try approvalProxy.replayLog(sessionId: sessionId, limit: limit)
    }

    nonisolated func sessionInsightsSummary(retentionDays: Int) throws -> SessionInsightsSummary {
        guard let approvalProxy else {
            let since = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
            return SessionInsightsSummary(
                since: since, totalClosedSessions: 0, todayClosedSessions: 0,
                manualApproved: 0, manualDenied: 0, autoApproved: 0, autoDenied: 0,
                topApprovedTools: [], averageDurationSeconds: nil
            )
        }
        let since = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        return try approvalProxy.sessionInsightsSummary(since: since)
    }

    nonisolated func closedSessionRecords(retentionDays: Int) throws -> [ClosedSessionRecord] {
        guard let approvalProxy else { return [] }
        let since = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        return try approvalProxy.closedSessions(since: since)
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

    func flushApprovalPersistenceForTesting() {
        approvalPersistenceQueue.sync {}
    }

    func ptyMessages(sessionId: String? = nil, limit: Int = 500) throws -> [PTYMessage] {
        guard let approvalProxy else { return [] }
        return try approvalProxy.ptyMessages(sessionId: sessionId, limit: limit)
    }

    private func startNotificationAutoCollapseTimer(delay: TimeInterval) {
        stopNotificationAutoCollapseTimer()
        notificationAutoCollapseProgress = 1.0
        isNotificationAutoCollapseActive = true

        notificationCountdown.start(
            duration: delay,
            onProgress: { [weak self] progress in
                self?.notificationAutoCollapseProgress = progress
            },
            onExpire: { [weak self] in
                guard let self else { return }
                self.isNotificationAutoCollapseActive = false
                self.notificationAutoCollapseProgress = 1.0
                if !self.displayState.hasResponseHandler && self.isNotchExpanded {
                    self.isNotchExpanded = false
                    self.isExpandingFromRequest = false
                }
            }
        )
    }

    private func stopNotificationAutoCollapseTimer() {
        notificationCountdown.cancel()
        isNotificationAutoCollapseActive = false
        notificationAutoCollapseProgress = 1.0
    }

    @MainActor
    private func presentPluginNotification(title: String, body: String?) {
        guard !displayState.hasResponseHandler, !displayState.isShowingRequest else { return }

        displayState.toolName = title
        displayState.eventName = PluginEventKind.notificationShown.rawValue
        displayState.message = body ?? title
        displayState.sessionId = ""
        isNotchExpanded = true
        isExpandingFromRequest = false

        stopNotificationAutoCollapseTimer()
        if let delay = notificationAutoCollapseDelay {
            startNotificationAutoCollapseTimer(delay: delay)
        }
    }

    nonisolated static func presentSharedPluginNotification(title: String, body: String?) async {
        await MainActor.run {
            AppState.shared.presentPluginNotification(title: title, body: body)
        }
    }

    func approve(globalAlways: Bool = false, sessionAlways: Bool = false) {
        let tool = displayState.rawToolName.isEmpty ? displayState.toolName : displayState.rawToolName
        let sId = displayState.sessionId

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

        print("[DevIsland] approve() called, handler=\(displayState.hasResponseHandler ? "SET" : "NIL")")

        // exit_plan_mode를 수동으로 승인했을 때도 Auto-Edit 모드 활성화
        if tool == "exit_plan_mode" {
            if let index = sessionStore.activeSessions.firstIndex(where: { $0.id == sId }) {
                sessionStore.activeSessions[index].isAutoEditActive = true
                print("[DevIsland] [MODE] Session \(sId.prefix(8)) switched to Auto-Edit mode via manual approval")
            }
        }
        
        let approvalScope: RuleScope? = sessionAlways ? .session : globalAlways ? .persistent : nil
        approvalFlow.sendDecision(approved: true, approvalScope: approvalScope)
    }

    func setClaudeQuestionOption(questionId: String, optionId: String) {
        claudeQuestionState.setOption(questionId: questionId, optionId: optionId)
    }

    func setClaudeQuestionCustomAnswerEnabled(questionId: String, isEnabled: Bool) {
        claudeQuestionState.setCustomAnswerEnabled(questionId: questionId, isEnabled: isEnabled)
    }

    func setClaudeQuestionText(questionId: String, text: String) {
        claudeQuestionState.setText(questionId: questionId, text: text)
    }

    func canSubmitClaudeQuestion() -> Bool {
        claudeQuestionState.canSubmit()
    }

    func submitClaudeQuestion() {
        guard let updatedInput = claudeQuestionState.buildSubmitInput() else { return }
        approvalFlow.sendDecision(approved: true, toolInput: updatedInput)
    }

    func deny() {
        print("[DevIsland] deny() called")
        approvalFlow.sendDecision(approved: false)
    }

    @MainActor func respondFromNotification(requestId: UUID, approved: Bool) {
        if displayState.showingRequestId == requestId {
            if approved { approve() } else { deny() }
            return
        }
        guard let request = sessionStore.removePending(id: requestId) else { return }
        request.responseHandler(HookResponse(approved ? .approved : .denied).jsonString())
    }

    private static let alwaysAllowThreshold = 3

    private func checkAlwaysAllowSuggestion(toolName: String) {
        guard !toolName.isEmpty, let proxy = approvalProxy else {
            alwaysAllowSuggestion = nil
            return
        }
        alwaysAllowSuggestion = nil
        approvalPersistenceQueue.async { [weak self] in
            guard let self else { return }
            let count = proxy.store.manualAllowCount(toolName: toolName)
            guard count >= Self.alwaysAllowThreshold else {
                Task { @MainActor in self.alwaysAllowSuggestion = nil }
                return
            }
            let hasRule = proxy.store.hasPersistentAllowRule(toolName: toolName)
            Task { @MainActor in
                self.alwaysAllowSuggestion = hasRule ? nil : toolName
            }
        }
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
            let l = L10n.shared
            let alert = NSAlert()
            alert.messageText = l.alertAddGlobalToolTitle
            alert.informativeText = l.alertAddGlobalToolMsg
            alert.addButton(withTitle: l.btnAdd)
            alert.addButton(withTitle: l.btnCancel)

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
            alert.accessoryView = input

            if ModalPresenter.run(alert) == .alertFirstButtonReturn {
                let toolName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !toolName.isEmpty {
                    self.insertGlobalPersistentRule(toolName)
                }
            }
        }
    }

    func promptRenameSession(_ sessionId: String, currentLabel: String?) {
        DispatchQueue.main.async {
            let l = L10n.shared
            let alert = NSAlert()
            alert.messageText = l.renameSessionTitle
            alert.informativeText = l.renameSessionHint(sessionId.prefix(8).description)
            alert.addButton(withTitle: l.renameSessionConfirm)
            alert.addButton(withTitle: l.btnCancel)

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            input.placeholderString = l.renameSessionPlaceholder
            input.stringValue = currentLabel ?? ""
            alert.accessoryView = input
            alert.window.initialFirstResponder = input

            if ModalPresenter.run(alert) == .alertFirstButtonReturn {
                let label = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if label.isEmpty {
                    self.sessionLabels.removeValue(forKey: sessionId)
                } else {
                    self.sessionLabels[sessionId] = label
                }
            }
        }
    }

    func isSessionFavorite(_ sessionId: String) -> Bool {
        sessionFavoriteIds.contains(sessionId)
    }

    func toggleSessionFavorite(_ sessionId: String) {
        if sessionFavoriteIds.contains(sessionId) {
            sessionFavoriteIds.remove(sessionId)
        } else {
            sessionFavoriteIds.insert(sessionId)
        }
    }

    func setSessionDescription(_ sessionId: String, description: String) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sessionDescriptions.removeValue(forKey: sessionId)
        } else {
            sessionDescriptions[sessionId] = trimmed
        }
    }

    func promptEditSessionDescription(_ sessionId: String, currentDescription: String?) {
        DispatchQueue.main.async {
            let l = L10n.shared
            let alert = NSAlert()
            alert.messageText = l.sessionDescriptionTitle
            alert.informativeText = l.sessionDescriptionHint(sessionId.prefix(8).description)
            alert.addButton(withTitle: l.sessionDescriptionConfirm)
            alert.addButton(withTitle: l.btnCancel)

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder

            let contentSize = scrollView.contentSize
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
            textView.string = currentDescription ?? ""
            textView.isRichText = false
            textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = .width
            textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            scrollView.documentView = textView

            alert.accessoryView = scrollView
            alert.window.initialFirstResponder = textView

            if ModalPresenter.run(alert) == .alertFirstButtonReturn {
                self.setSessionDescription(sessionId, description: textView.string)
            }
        }
    }

    func promptToAddSessionAutoApprove(for sessionId: String) {
        DispatchQueue.main.async {
            let l = L10n.shared
            let alert = NSAlert()
            alert.messageText = l.alertAddSessionToolTitle
            alert.informativeText = l.alertAddSessionToolMsg(sessionId.prefix(8).description)
            alert.addButton(withTitle: l.btnAdd)
            alert.addButton(withTitle: l.btnCancel)

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
            alert.accessoryView = input

            if ModalPresenter.run(alert) == .alertFirstButtonReturn {
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
            let terminalTitle = SessionStore.restoredTitle(fromPayload: json)
            let agentKind = Self.agentKind(from: json, terminalTitle: terminalTitle)
            sessionStore.updateActiveSession(
                sessionId: record.sessionId,
                terminalTitle: terminalTitle,
                agentKind: agentKind,
                terminal: TerminalContext(from: json),
                toolName: record.lastToolName,
                eventName: record.lastEventName,
                message: ToolMessageFormatter.displayMessage(
                    for: record.lastToolName,
                    toolInput: json["tool_input"] as? [String: Any],
                    json: json,
                    eventName: record.lastEventName
                ),
                isPending: false,
                isLifecycleTracked: true,
                workspaceRoot: json["cwd"] as? String,
                startTime: record.startAt,
                lastActiveAt: record.lastActiveAt
            )
        }
    }

    func showSessionDetail(_ sessionId: String) {
        guard !displayState.hasResponseHandler else { return }
        if isExpandingFromRequest && !currentSessionId.isEmpty && currentSessionId != sessionId {
            sessionStore.setUnread(false, sessionId: currentSessionId)
            approvalFlow.previousSessionId = currentSessionId
        }
        sessionStore.selectedSessionId = sessionId
        sessionStore.setUnread(false, sessionId: sessionId)
        sessionStore.setMissedApproval(false, sessionId: sessionId)
        displayState.sessionId = sessionId
        syncDisplayToSelectedSession()
        isExpandingFromRequest = true
    }

    func dismissCurrentRequest() {
        if displayState.hasResponseHandler {
            approvalFlow.sendDecision(approved: false, reason: "Dismissed", passToTerminal: true)
        } else if isExpandingFromRequest {
            if !currentSessionId.isEmpty {
                sessionStore.setUnread(false, sessionId: currentSessionId)
                sessionStore.setMissedApproval(false, sessionId: currentSessionId)
            }
            stopNotificationAutoCollapseTimer()
            if let prev = approvalFlow.previousSessionId {
                approvalFlow.previousSessionId = nil
                displayState.clearDisplayText()
                claudeQuestionState.reset()
                showSessionDetail(prev)
            } else {
                approvalFlow.showNextRequest()
            }
        } else {
            isNotchExpanded = false
            stopNotificationAutoCollapseTimer()
        }
    }

    func pauseAutoTimersForUserViewing() {
        if displayState.hasResponseHandler {
            approvalFlow.cancelTimeout()
        }

        if isExpandingFromRequest {
            stopNotificationAutoCollapseTimer()
        }
    }

    @MainActor func focusTerminal(for sessionId: String? = nil) {
        let targetId = sessionId ?? (currentSessionId.isEmpty ? sessionStore.selectedSessionId : currentSessionId)
        if let targetId {
            sessionStore.setUnread(false, sessionId: targetId)
            sessionStore.setMissedApproval(false, sessionId: targetId)
        }
        let session = targetId.flatMap { id in
            sessionStore.activeSessions.first { $0.id == id }
        }
        TerminalFocuser.focusTerminal(
            session?.terminal ?? TerminalContext(),
            title: session?.terminalTitle,
            workspaceRoot: session?.workspaceRoot
        ) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminalFocusRecheckDelay) {
                self?.passIfTerminalFocused()
            }
        }
    }
}

// MARK: - ApprovalFlowContext

extension AppState: ApprovalFlowContext {
    // displayState / timeoutProgress / isNotchExpanded / isExpandingFromRequest /
    // syncDisplayToSelectedSession() already satisfy the protocol requirements.

    func updateAlwaysAllowSuggestion(toolName: String) {
        checkAlwaysAllowSuggestion(toolName: toolName)
    }

    func clearAlwaysAllowSuggestion() {
        alwaysAllowSuggestion = nil
    }

    func emitApprovalDecided(sessionID: String, approved: Bool, toolName: String, scope: String) {
        // Dispatch to the main actor instead of asserting isolation: sendDecision is not
        // statically main-actor-isolated, so a future off-main caller would crash on
        // assumeIsolated. The event is best-effort, so a deferred main-actor hop is fine.
        Task { @MainActor [pluginHost, pluginEventFactory] in
            pluginHost.enqueue(pluginEventFactory.makeApprovalDecidedEvent(
                sessionID: sessionID,
                approved: approved,
                toolName: toolName,
                scope: scope
            ))
        }
    }
}
