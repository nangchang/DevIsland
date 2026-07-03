import Foundation

/// Notch-facing state and effects the approval flow drives but does not own.
/// `AppState` is the production implementation: presentation state stays
/// `@Published` there so SwiftUI observation is unchanged, and the coordinator
/// reaches it through this protocol (which also makes the flow unit-testable
/// with a fake context).
protocol ApprovalFlowContext: AnyObject {
    var displayState: ApprovalDisplayState { get set }
    var timeoutProgress: Double { get set }
    var isNotchExpanded: Bool { get set }
    var isExpandingFromRequest: Bool { get set }
    func syncDisplayToSelectedSession()
    func updateAlwaysAllowSuggestion(toolName: String)
    func clearAlwaysAllowSuggestion()
    func emitApprovalDecided(sessionID: String, approved: Bool, toolName: String, scope: String)
}

/// Owns the pending-approval flow extracted from `AppState` (R2-c):
/// queue entry (`enqueueManualRequest`), display selection (`showNextRequest`
/// and preemption), decision dispatch (`sendDecision`), and the approval
/// timeout. Pure selection/validation policy lives in `ApprovalQueuePolicy`;
/// this type is the stateful machinery around it.
final class ApprovalFlowCoordinator {
    typealias FrontmostCheck = (TerminalContext) -> Bool

    /// AppState. Weak because AppState owns this coordinator.
    weak var context: ApprovalFlowContext?

    private let sessionStore: SessionStore
    private let claudeQuestionState: ClaudeQuestionState
    private let replayRecorder: ReplayRecorder
    private let approvalProxy: ApprovalProxyController?
    private let persistenceQueue: DispatchQueue
    private let userDefaults: UserDefaults
    private let frontmostCheck: FrontmostCheck

    private let timeoutCountdown = CountdownTimer()
    /// Answers of a Claude question that was preempted by a priority request,
    /// keyed by the pending request id, restored when the question redisplays.
    private var suspendedClaudeQuestionAnswers: [UUID: [String: ClaudeQuestionAnswer]] = [:]

    private var _previousSessionId: String?
    /// Session to return to when the displayed request completes; validated
    /// against the live session list on read.
    var previousSessionId: String? {
        get {
            guard let id = _previousSessionId,
                  sessionStore.activeSessions.contains(where: { $0.id == id }) else { return nil }
            return id
        }
        set { _previousSessionId = newValue }
    }

    private var timeoutDuration: Double {
        let v = userDefaults.double(forKey: SettingsStore.DefaultsKey.permissionTimeoutSeconds)
        return v > 0 ? v : 120.0
    }

    init(
        sessionStore: SessionStore,
        claudeQuestionState: ClaudeQuestionState,
        replayRecorder: ReplayRecorder,
        approvalProxy: ApprovalProxyController?,
        persistenceQueue: DispatchQueue,
        userDefaults: UserDefaults,
        frontmostCheck: @escaping FrontmostCheck
    ) {
        self.sessionStore = sessionStore
        self.claudeQuestionState = claudeQuestionState
        self.replayRecorder = replayRecorder
        self.approvalProxy = approvalProxy
        self.persistenceQueue = persistenceQueue
        self.userDefaults = userDefaults
        self.frontmostCheck = frontmostCheck
    }

    // MARK: - Queue entry

    /// 수동 승인 큐잉 — 매칭된 규칙이 없어 사용자 결정을 기다린다.
    /// isLifecycleTracked는 경로별 의미가 다르므로(승인: 비-Claude는 추적 승격,
    /// 질문: 기존 추적 상태 보존) 호출부에서 결정해 넘긴다.
    func enqueueManualRequest(
        _ request: PendingRequest,
        from h: ParsedHookEvent,
        isLifecycleTracked: Bool
    ) {
        guard let context else { return }
        let newItem = PendingItem(
            id: request.id,
            toolName: request.toolName,
            message: request.message,
            sessionId: request.sessionId,
            terminalTitle: h.terminalTitle,
            terminalWindowId: h.terminal.windowId,
            terminalTabIndex: h.terminal.tabIndex,
            terminalTmuxPane: h.terminal.tmuxPane,
            terminalTmuxSocket: h.terminal.tmuxSocket,
            terminalTmuxClient: h.terminal.tmuxClient,
            receivedAt: request.receivedAt
        )
        sessionStore.appendPending(request: request, item: newItem)

        if !request.sessionId.isEmpty {
            sessionStore.updateActiveSession(
                sessionId: h.sessionId,
                terminalTitle: h.terminalTitle,
                agentKind: h.agentKind,
                terminal: h.terminal,
                toolName: request.toolName,
                eventName: request.eventName,
                message: request.message,
                isPending: true,
                isLifecycleTracked: isLifecycleTracked,
                workspaceRoot: h.workspaceRoot
            )

            sessionStore.selectedSessionId = request.sessionId
        }

        if !context.displayState.hasResponseHandler {
            showNextRequest()
        } else if isShowingLowerPriorityPendingRequest(than: request) {
            preemptCurrentPendingDisplay()
            showNextRequest()
        } else {
            context.syncDisplayToSelectedSession()
        }
    }

    // MARK: - Display selection

    func showNextRequest() {
        guard let context else { return }
        discardInvalidPendingRequests()

        guard let next = nextPendingRequestToDisplay() else {
            context.displayState.clear()
            timeoutCountdown.cancel()
            context.timeoutProgress = 1.0
            context.clearAlwaysAllowSuggestion()
            claudeQuestionState.reset()
            if let prev = previousSessionId {
                previousSessionId = nil
                sessionStore.selectedSessionId = prev
                sessionStore.setUnread(false, sessionId: prev)
                context.displayState.sessionId = prev
                context.syncDisplayToSelectedSession()
                context.isExpandingFromRequest = true
                let autoExpandEnabled = MainActor.assumeIsolated { SettingsStore.shared.settings.notchAutoExpandEnabled }
                if autoExpandEnabled {
                    context.isNotchExpanded = true
                }
            } else {
                sessionStore.selectedSessionId = nil
                context.isNotchExpanded = false
            }
            return
        }

        if context.displayState.isShowingRequest { return }
        context.displayState.isShowingRequest = true
        context.displayState.showingRequestId = next.id

        let session = sessionStore.activeSessions.first { $0.id == next.sessionId }
        isTerminalFrontmostAsync(for: session) { [weak self] isFrontmost in
            guard let self, let context = self.context else { return }
            guard context.displayState.showingRequestId == next.id else { return }

            if isFrontmost && !next.isReplay {
                print("[DevIsland] [AUTO] Terminal focused, bypassing pending request for \(next.sessionId.prefix(8))")
                if next.claudeQuestion != nil {
                    next.responseHandler(HookResponse(.pass).jsonString())
                    self.recordReplayDecision(
                        hookEventId: next.hookEventId,
                        agentKind: next.agentKind,
                        sessionId: next.sessionId,
                        toolName: next.rawToolName.isEmpty ? next.toolName : next.rawToolName,
                        workspaceRoot: next.workspaceRoot,
                        action: .prompt,
                        source: .automatic,
                        reason: "terminal focused"
                    )
                    _ = self.sessionStore.removePending(id: next.id)
                    if !next.sessionId.isEmpty {
                        self.sessionStore.updateActiveSession(
                            sessionId: next.sessionId,
                            terminalTitle: session?.terminalTitle ?? "",
                            agentKind: next.agentKind,
                            terminal: session?.terminal ?? TerminalContext(),
                            toolName: next.toolName,
                            eventName: next.eventName,
                            message: next.message,
                            isPending: false,
                            status: SessionStatus.timeoutBypassed(Date()),
                            workspaceRoot: next.workspaceRoot
                        )
                    }
                    self.claudeQuestionState.reset()
                    context.displayState.clearResponseState()
                    self.timeoutCountdown.cancel()
                    context.timeoutProgress = 1.0
                    self.showNextRequest()
                    return
                }
                context.displayState.responseHandler = next.responseHandler
                context.displayState.sessionId = next.sessionId
                context.displayState.rawToolName = next.rawToolName
                context.displayState.agentKind = next.agentKind
                context.displayState.workspaceRoot = next.workspaceRoot
                context.displayState.hookEventId = next.hookEventId
                self.sendDecision(approved: false, reason: "TerminalFocused", status: .timeoutBypassed(Date()), passToTerminal: true)
                return
            }

            print("[DevIsland] showNextRequest: showing \(next.eventName)/\(next.toolName) id=\(next.id)")
            if context.isExpandingFromRequest && !context.displayState.sessionId.isEmpty && context.displayState.sessionId != next.sessionId {
                self.sessionStore.setUnread(false, sessionId: context.displayState.sessionId)
                self.previousSessionId = context.displayState.sessionId
            }
            context.displayState.responseHandler = next.responseHandler
            context.displayState.eventName = next.eventName
            context.displayState.toolName = next.toolName
            context.displayState.rawToolName = next.rawToolName
            context.displayState.agentKind = next.agentKind
            context.displayState.workspaceRoot = next.workspaceRoot
            context.displayState.hookEventId = next.hookEventId
            context.displayState.message = next.message
            if let claudeQuestion = next.claudeQuestion {
                let answers = self.suspendedClaudeQuestionAnswers.removeValue(forKey: next.id)
                    ?? ClaudeQuestionState.defaultAnswers(for: claudeQuestion)
                self.claudeQuestionState.setQuestion(claudeQuestion, answers: answers)
            } else {
                self.claudeQuestionState.reset()
            }
            context.displayState.sessionId = next.sessionId
            let notifEnabled = MainActor.assumeIsolated { SettingsStore.shared.settings.notificationsEnabled }
            if notifEnabled && next.claudeQuestion == nil {
                NotificationManager.shared.sendApprovalRequest(next)
            }
            context.updateAlwaysAllowSuggestion(toolName: next.rawToolName.isEmpty ? next.toolName : next.rawToolName)

            context.isExpandingFromRequest = true
            let isQuestion = next.claudeQuestion != nil
            let expandEnabled = MainActor.assumeIsolated {
                let s = SettingsStore.shared.settings
                guard s.notchAutoExpandEnabled else { return false }
                return isQuestion ? s.expandOnQuestionResponse : s.expandOnApprovalRequest
            }
            // 팝아웃 창이 열린 세션은 노치 확장 억제 — 창이 승인 UI를 표시함
            let suppressNotch = MainActor.assumeIsolated {
                SessionMessageWindowManager.shared.hasWindow(for: next.sessionId)
            }
            if (expandEnabled || context.isNotchExpanded) && !suppressNotch {
                context.isNotchExpanded = true
            }
            if expandEnabled || context.isNotchExpanded || suppressNotch {
                self.startTimeout()
            }
        }
    }

    /// Clears the notch's currently-displayed approval/question. Called when the
    /// session owning the on-screen request is torn down (stopped, dismissed, or
    /// superseded) so no stale request is left showing. Callers handle their own
    /// pre-clear response (e.g. pass-to-terminal) and post-clear `showNextRequest`.
    func clearCurrentRequestDisplay() {
        guard let context else { return }
        if let showingRequestId = context.displayState.showingRequestId {
            NotificationManager.shared.cancelNotification(id: showingRequestId)
        }
        context.displayState.clear()
        timeoutCountdown.cancel()
        context.timeoutProgress = 1.0
        claudeQuestionState.reset()
    }

    /// Drops suspended question answers for requests already removed from the
    /// queue (session stop/supersede/dismiss paths in AppState).
    func removeSuspendedAnswers(for requests: [PendingRequest]) {
        for request in requests {
            suspendedClaudeQuestionAnswers.removeValue(forKey: request.id)
        }
    }

    private func nextPendingRequestToDisplay() -> PendingRequest? {
        // 팝아웃 창이 열린 세션의 요청을 우선 처리하여 창에서 즉시 승인/거부 가능하게 함
        ApprovalQueuePolicy.nextToDisplay(in: sessionStore.pendingQueue) { sid in
            MainActor.assumeIsolated { SessionMessageWindowManager.shared.hasWindow(for: sid) }
        }
    }

    private func isShowingLowerPriorityPendingRequest(than request: PendingRequest) -> Bool {
        ApprovalQueuePolicy.showingIsLowerPriority(
            than: request,
            showingRequestId: context?.displayState.showingRequestId,
            queue: sessionStore.pendingQueue
        )
    }

    private func preemptCurrentPendingDisplay() {
        guard let context else { return }
        if let showingRequestId = context.displayState.showingRequestId, claudeQuestionState.currentClaudeQuestion != nil {
            suspendedClaudeQuestionAnswers[showingRequestId] = claudeQuestionState.currentClaudeQuestionAnswers
        }
        context.displayState.clearResponseState()
        claudeQuestionState.reset()
        timeoutCountdown.cancel()
        context.timeoutProgress = 1.0
    }

    private func discardInvalidPendingRequests() {
        let invalid = sessionStore.pendingQueue.filter { $0.claudeQuestion == nil && !ApprovalQueuePolicy.isValidApprovalRequest($0) }
        for request in invalid {
            if let removed = sessionStore.removePending(id: request.id) {
                removed.responseHandler(HookResponse(.pass).jsonString())
            }
        }
    }

    private func isTerminalFrontmostAsync(for session: ActiveSession?, completion: @escaping (Bool) -> Void) {
        let frontmostCheck = self.frontmostCheck
        let terminal = session?.terminal ?? TerminalContext()

        DispatchQueue.global(qos: .userInitiated).async {
            let isFrontmost = frontmostCheck(terminal)
            DispatchQueue.main.async {
                completion(isFrontmost)
            }
        }
    }

    // MARK: - Timeout

    private func startTimeout() {
        context?.timeoutProgress = 1.0
        timeoutCountdown.start(
            duration: timeoutDuration,
            onProgress: { [weak self] progress in
                self?.context?.timeoutProgress = progress
            },
            onExpire: { [weak self] in
                guard let self, self.context?.displayState.hasResponseHandler == true else { return }
                self.sendDecision(approved: false, reason: "Timeout", status: .timeoutBypassed(Date()), passToTerminal: true)
            }
        )
    }

    /// Stops the approval countdown without sending a decision — the user is
    /// actively viewing the request, so it must not auto-expire under them.
    func cancelTimeout() {
        timeoutCountdown.cancel()
        context?.timeoutProgress = 1.0
    }

    // MARK: - Decision dispatch

    func sendDecision(
        approved: Bool,
        reason: String? = nil,
        status: SessionStatus? = nil,
        passToTerminal: Bool = false,
        approvalScope: RuleScope? = nil,
        toolInput: [String: AnyJSON]? = nil
    ) {
        guard let context else { return }
        let decision: HookDecision = passToTerminal ? .pass : approved ? .approved : .denied
        let payload = HookResponse(
            decision,
            reason: reason,
            approvalScope: approvalScope,
            toolInput: toolInput
        ).jsonString()
        let hadResponseHandler = context.displayState.hasResponseHandler
        print("[DevIsland] sendDecision approved=\(approved), handler=\(context.displayState.hasResponseHandler ? "SET" : "NIL"), reason=\(reason ?? "none")")
        context.displayState.responseHandler?(payload)
        print("[DevIsland] sendDecision: response payload sent")
        recordReplayDecision(
            hookEventId: context.displayState.hookEventId,
            agentKind: context.displayState.agentKind,
            sessionId: context.displayState.sessionId,
            toolName: context.displayState.rawToolName.isEmpty ? context.displayState.toolName : context.displayState.rawToolName,
            workspaceRoot: context.displayState.workspaceRoot,
            action: passToTerminal ? .prompt : approved ? .allow : .deny,
            source: reason == nil ? .user : .automatic,
            reason: reason
        )
        // Observation-only `approval.decided`, emitted after the response is already sent
        // so plugin work cannot change or delay it. Pass-through outcomes (timeout, dismiss,
        // terminal-focus) are deferrals, not approve/deny decisions, so they are excluded.
        // A non-nil `toolInput` is an AskUserQuestion structured reply (submitClaudeQuestion):
        // a question answer, not a tool approval, so it must not count as an approve decision.
        if hadResponseHandler, !passToTerminal, toolInput == nil, !context.displayState.sessionId.isEmpty {
            context.emitApprovalDecided(
                sessionID: context.displayState.sessionId,
                approved: approved,
                toolName: context.displayState.rawToolName.isEmpty ? context.displayState.toolName : context.displayState.rawToolName,
                scope: approvalScope?.rawValue ?? RuleScope.once.rawValue
            )
        }
        persistApprovalScope(approved: approved, approvalScope: approvalScope)
        let completedRequestId = context.displayState.showingRequestId
        context.displayState.clearResponseState()
        claudeQuestionState.reset()
        timeoutCountdown.cancel()

        DispatchQueue.main.async {
            guard let context = self.context else { return }
            context.timeoutProgress = 1.0
            var completedSessionId: String?
            let removedRequest: PendingRequest?
            if let completedRequestId {
                removedRequest = self.sessionStore.removePending(id: completedRequestId)
                self.suspendedClaudeQuestionAnswers.removeValue(forKey: completedRequestId)
            } else {
                removedRequest = self.sessionStore.removeFirstPending()
                if let removedRequest {
                    self.suspendedClaudeQuestionAnswers.removeValue(forKey: removedRequest.id)
                }
            }
            if let removed = removedRequest {
                completedSessionId = removed.sessionId

                // Update session state to not pending
                if !removed.sessionId.isEmpty, let index = self.sessionStore.activeSessions.firstIndex(where: { $0.id == removed.sessionId }) {
                    let stillPending = self.sessionStore.pendingQueue.contains { $0.sessionId == removed.sessionId }
                    if stillPending {
                        self.sessionStore.activeSessions[index].isPending = true
                        self.sessionStore.activeSessions[index].status = .pending
                    } else if case .timeoutBypassed? = status {
                        self.sessionStore.activeSessions[index].isPending = false
                        self.sessionStore.activeSessions[index].hasMissedApproval = true
                        self.sessionStore.activeSessions[index].status = status ?? .idle
                        self.sessionStore.activeSessions[index].lastActiveAt = Date()
                    } else if !self.sessionStore.activeSessions[index].isLifecycleTracked {
                        self.sessionStore.removeSession(id: removed.sessionId)
                    } else {
                        self.sessionStore.activeSessions[index].isPending = false
                        self.sessionStore.activeSessions[index].status = status ?? .idle
                        self.sessionStore.activeSessions[index].lastActiveAt = Date()
                    }
                }
            }
            self.showNextRequest()
            if status?.isTimeoutBypassed == true, self.sessionStore.pendingQueue.isEmpty, let completedSessionId {
                if !context.isExpandingFromRequest {
                    self.sessionStore.selectedSessionId = completedSessionId
                    context.isNotchExpanded = false
                }
            }
        }
    }

    private func persistApprovalScope(approved: Bool, approvalScope: RuleScope?) {
        guard approved,
              let context,
              let agentKind = context.displayState.agentKind,
              let approvalScope,
              let approvalProxy,
              !context.displayState.sessionId.isEmpty,
              !context.displayState.rawToolName.isEmpty else {
            return
        }

        let provider = agentKind.providerKind
        let sessionId = context.displayState.sessionId
        let toolName = context.displayState.rawToolName
        let workspaceRoot = context.displayState.workspaceRoot
        persistenceQueue.async { [weak self] in
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
            provider: agentKind.providerKind,
            sessionId: sessionId,
            toolName: toolName,
            workspaceRoot: workspaceRoot,
            action: action,
            source: source,
            reason: reason
        )
    }
}
