import SwiftUI
import Combine
import AppKit

// MARK: - Pending Request

struct PendingRequest: Identifiable {
    let id = UUID()
    let sessionId: String
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
    let receivedAt: Date
}

struct ActiveSession: Identifiable, Equatable {
    let id: String // full sessionId
    var terminalTitle: String
    var lastToolName: String
    var lastEventName: String
    var lastMessage: String
    let startTime: Date
    var lastActiveAt: Date
    var isPending: Bool
    var isLifecycleTracked: Bool
}

// MARK: - App State

class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isNotchExpanded = false
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

    private static let genericTitles: Set<String> = ["Terminal", "iTerm", "Ghostty", "Warp", ""]

    private var server = HookSocketServer()
    private var pendingQueue: [PendingRequest] = []
    private var currentResponseHandler: ((String) -> Void)?
    private var timeoutTimer: Timer?
    private var sessionPruningTimer: Timer?
    private let timeoutDuration: Double = 120
    private let lifecycleSessionTimeout: Double = 15 * 60

    private init() {
        server.onMessageReceived = { [weak self] message, responseHandler in
            self?.handleMessage(message, responseHandler: responseHandler)
        }
        server.onServerFailed = {
            let alert = NSAlert()
            alert.messageText = "포트 사용 중"
            alert.informativeText = "9090 포트가 이미 사용 중입니다.\n다른 DevIsland 인스턴스를 종료 후 다시 실행해주세요."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "종료")
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
        server.start()
        GlobalShortcutManager.shared.start()
        
        // Prune inactive sessions every 10 seconds
        sessionPruningTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.pruneInactiveSessions()
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

    private func handleMessage(_ message: String, responseHandler: @escaping (String) -> Void) {
        guard let data = message.data(using: .utf8) else { return }

        var event     = "Unknown"
        var toolName  = ""
        var sessionId = ""
        var terminalTitle = "Terminal"
        var displayMsg = ""
        var notificationType = ""

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                event     = (json["hook_event_name"] as? String) ?? (json["event"] as? String) ?? "Unknown"
                toolName  = json["tool_name"] as? String ?? ""
                sessionId = (json["session_id"] as? String) ?? (json["sessionId"] as? String) ?? ""
                terminalTitle = json["terminal_title"] as? String ?? "Terminal"
                notificationType = json["notification_type"] as? String ?? ""
                // osascript가 기본값을 반환하면 cwd 마지막 경로로 대체
                if Self.genericTitles.contains(terminalTitle), let cwd = json["cwd"] as? String {
                    let label = URL(fileURLWithPath: cwd).lastPathComponent
                    if !label.isEmpty && label != "/" { terminalTitle = label }
                }
                let toolInput = json["tool_input"] as? [String: Any]
                
                print("Parsed Hook: event=\(event), session=\(sessionId), title=\(terminalTitle)")

                displayMsg = displayMessage(
                    for: toolName,
                    toolInput: toolInput,
                    json: json,
                    eventName: event
                )
            }
        } catch {
            print("JSON parse error: \(error)")
            displayMsg = message
        }

        let normalizedEvent = normalizedHookEventName(event)
        let stopEvents = ["stop", "subagentstop", "exit", "shutdown", "sessionend"]
        let notificationEvents = ["sessionstart", "notification", "pretooluse", "posttooluse", "precompact"]
        let isStop = stopEvents.contains(normalizedEvent)
        let isNotification = notificationEvents.contains(normalizedEvent)

        if isStop {
            guard !sessionId.isEmpty else {
                responseHandler("{\"response\": \"approved\"}")
                return
            }
            let fullSessionId = sessionId
            DispatchQueue.main.async {
                self.pendingQueue
                    .filter { $0.sessionId == fullSessionId }
                    .forEach { $0.responseHandler("{\"response\": \"denied\"}") }
                self.pendingQueue.removeAll { $0.sessionId == fullSessionId }
                self.pendingItems.removeAll { $0.sessionId == fullSessionId }
                self.pendingCount = self.pendingQueue.count
                self.activeSessions.removeAll { $0.id == fullSessionId }

                if self.currentSessionId == fullSessionId {
                    self.currentResponseHandler = nil
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
            let sessionMessage = normalizedEvent == "sessionstart"
                ? "Session Started"
                : displayMsg
            self.updateActiveSession(
                sessionId: fullSessionId,
                terminalTitle: terminalTitle,
                toolName: toolName,
                eventName: event,
                message: sessionMessage,
                isPending: hasPendingForSession,
                preserveMessage: normalizedEvent == "pretooluse" || sessionMessage.isEmpty,
                isLifecycleTracked: normalizedEvent == "sessionstart"
            )

            DispatchQueue.main.async {
                if normalizedEvent == "sessionstart" {
                    self.selectedSessionId = fullSessionId
                }
            }

            responseHandler("{\"response\": \"approved\"}")
            return
        }

        guard normalizedEvent == "permissionrequest" else {
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
            eventName: event,
            toolName: toolName,
            message: displayMsg,
            responseHandler: responseHandler,
            receivedAt: Date()
        )

        DispatchQueue.main.async {
            self.pendingQueue.append(request)
            
            let newItem = PendingItem(
                id: request.id,
                toolName: request.toolName,
                message: request.message,
                sessionId: request.sessionId,
                terminalTitle: terminalTitle,
                receivedAt: request.receivedAt
            )
            self.pendingItems.append(newItem)
            self.pendingCount = self.pendingQueue.count

            if !request.sessionId.isEmpty {
                self.updateActiveSession(
                    sessionId: request.sessionId,
                    terminalTitle: terminalTitle,
                    toolName: request.toolName,
                    eventName: request.eventName,
                    message: request.message,
                    isPending: true
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

    private func normalizedHookEventName(_ event: String) -> String {
        event
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func displayMessage(for toolName: String, toolInput: [String: Any]?, json: [String: Any], eventName: String) -> String {
        if normalizedHookEventName(eventName) == "posttooluse" {
            return postToolMessage(from: json["tool_response"] as? [String: Any])
        }

        if let input = toolInput {
            let lowerToolName = toolName.lowercased()
            switch lowerToolName {
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

    private func updateActiveSession(sessionId: String, terminalTitle: String, toolName: String, eventName: String, message: String, isPending: Bool, preserveMessage: Bool = false, isLifecycleTracked: Bool = false) {
        if let index = activeSessions.firstIndex(where: { $0.id == sessionId }) {
            let shouldUpdateTitle = !Self.genericTitles.contains(terminalTitle)
                || Self.genericTitles.contains(activeSessions[index].terminalTitle)
            if shouldUpdateTitle {
                activeSessions[index].terminalTitle = terminalTitle
            }
            activeSessions[index].lastToolName = toolName
            activeSessions[index].lastEventName = eventName
            if !preserveMessage {
                activeSessions[index].lastMessage = message
            }
            activeSessions[index].lastActiveAt = Date()
            activeSessions[index].isPending = isPending
            if isLifecycleTracked {
                activeSessions[index].isLifecycleTracked = true
            }
        } else {
            let session = ActiveSession(
                id: sessionId,
                terminalTitle: terminalTitle,
                lastToolName: toolName,
                lastEventName: eventName,
                lastMessage: message,
                startTime: Date(),
                lastActiveAt: Date(),
                isPending: isPending,
                isLifecycleTracked: isLifecycleTracked
            )
            activeSessions.insert(session, at: 0)
        }
    }

    private func pruneInactiveSessions() {
        let now = Date()
        let threshold: TimeInterval = self.timeoutDuration
        
        DispatchQueue.main.async {
            self.activeSessions.removeAll { session in
                let inactiveFor = now.timeIntervalSince(session.lastActiveAt)
                let maxInactiveDuration = session.isLifecycleTracked ? self.lifecycleSessionTimeout : threshold
                return !session.isPending && inactiveFor > maxInactiveDuration
            }
        }
    }

    private func showNextRequest() {
        discardInvalidPendingRequests()

        guard let next = pendingQueue.first else {
            currentResponseHandler = nil
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

        print("[DevIsland] showNextRequest: showing \(next.eventName)/\(next.toolName) id=\(next.id)")
        currentResponseHandler = next.responseHandler
        currentEventName  = next.eventName
        currentToolName   = next.toolName
        currentMessage    = next.message
        currentSessionId  = next.sessionId

        DispatchQueue.main.async {
            self.isNotchExpanded = true
        }
        startTimeout()
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
        normalizedHookEventName(request.eventName) == "permissionrequest"
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
                    self.sendDecision(approved: false, reason: "Timeout")
                }
            }
        }
    }

    private func sendDecision(approved: Bool, reason: String? = nil) {
        let payload = approved
            ? "{\"response\": \"approved\"}"
            : "{\"response\": \"denied\"}"
        print("[DevIsland] sendDecision approved=\(approved), handler=\(currentResponseHandler != nil ? "SET" : "NIL"), reason=\(reason ?? "none")")
        currentResponseHandler?(payload)
        print("[DevIsland] sendDecision: response payload sent")
        currentResponseHandler = nil
        timeoutTimer?.invalidate()

        DispatchQueue.main.async {
            self.timeoutProgress = 1.0
            if !self.pendingQueue.isEmpty {
                let removed = self.pendingQueue.removeFirst()
                
                if !self.pendingItems.isEmpty { self.pendingItems.removeFirst() }
                self.pendingCount = self.pendingQueue.count
                
                // Update session state to not pending
                if !removed.sessionId.isEmpty, let index = self.activeSessions.firstIndex(where: { $0.id == removed.sessionId }) {
                    // Check if there are other pending items for this session
                    let stillPending = self.pendingQueue.contains { $0.sessionId == removed.sessionId }
                    if stillPending {
                        self.activeSessions[index].isPending = true
                    } else if !self.activeSessions[index].isLifecycleTracked {
                        self.activeSessions.remove(at: index)
                        if self.selectedSessionId == removed.sessionId {
                            self.selectedSessionId = nil
                        }
                    } else {
                        self.activeSessions[index].isPending = false
                    }
                }
            }
            self.showNextRequest()
        }
        TerminalFocuser.focusTerminal()
    }

    func approve() {
        print("[DevIsland] approve() called, handler=\(currentResponseHandler != nil ? "SET" : "NIL")")
        sendDecision(approved: true)
    }

    func deny() {
        print("[DevIsland] deny() called")
        sendDecision(approved: false)
    }

    func dismissCurrentRequest() {
        if currentResponseHandler != nil {
            sendDecision(approved: false, reason: "Dismissed")
        } else {
            isNotchExpanded = false
        }
    }
}
