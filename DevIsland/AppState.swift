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
            syncDisplayToSelectedSession()
        }
    }

    private var server = HookSocketServer()
    private var pendingQueue: [PendingRequest] = []
    private var currentResponseHandler: ((String) -> Void)?
    private var timeoutTimer: Timer?
    private var sessionPruningTimer: Timer?
    private let timeoutDuration: Double = 120

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

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                event     = (json["hook_event_name"] as? String) ?? (json["event"] as? String) ?? "Unknown"
                toolName  = json["tool_name"] as? String ?? ""
                sessionId = (json["session_id"] as? String) ?? (json["sessionId"] as? String) ?? "Default"
                terminalTitle = json["terminal_title"] as? String ?? "Terminal"
                let toolInput = json["tool_input"] as? [String: Any]
                
                print("Parsed Hook: event=\(event), session=\(sessionId), title=\(terminalTitle)")

                if let command = toolInput?["command"] as? String {
                    displayMsg = command
                } else if let filePath = toolInput?["file_path"] as? String {
                    displayMsg = filePath
                } else if let url = toolInput?["url"] as? String {
                    displayMsg = url
                } else if let input = toolInput {
                    displayMsg = input.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                }
            }
        } catch {
            print("JSON parse error: \(error)")
            displayMsg = message
        }

        let normalizedEvent = event
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        let stopEvents = ["stop", "subagentstop", "exit", "shutdown", "sessionend"]
        let notificationEvents = ["sessionstart", "notification", "posttooluse", "precompact", "permissionrequest"]
        let isStop = stopEvents.contains(normalizedEvent)
        let isNotification = notificationEvents.contains(normalizedEvent)

        if isStop {
            let fullSessionId = sessionId.isEmpty ? "Default" : sessionId
            DispatchQueue.main.async {
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
            let fullSessionId = sessionId.isEmpty ? "Default" : sessionId
            self.updateActiveSession(
                sessionId: fullSessionId,
                terminalTitle: terminalTitle,
                toolName: toolName,
                eventName: event,
                message: event.lowercased().contains("start") ? "Session Started" : displayMsg,
                isPending: false
            )

            DispatchQueue.main.async {
                self.selectedSessionId = fullSessionId
                self.syncDisplayToSelectedSession()
            }

            responseHandler("{\"response\": \"approved\"}")
            return
        }

        let request = PendingRequest(
            sessionId: sessionId.isEmpty ? "Default" : sessionId,
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
            
            self.updateActiveSession(
                sessionId: request.sessionId,
                terminalTitle: terminalTitle,
                toolName: request.toolName,
                eventName: request.eventName,
                message: request.message,
                isPending: true
            )
            
            self.selectedSessionId = request.sessionId
            
            if !self.isNotchExpanded {
                self.showNextRequest()
            } else {
                self.syncDisplayToSelectedSession()
            }
        }
    }

    private func updateActiveSession(sessionId: String, terminalTitle: String, toolName: String, eventName: String, message: String, isPending: Bool) {
        if let index = activeSessions.firstIndex(where: { $0.id == sessionId }) {
            activeSessions[index].terminalTitle = terminalTitle
            activeSessions[index].lastToolName = toolName
            activeSessions[index].lastEventName = eventName
            activeSessions[index].lastMessage = message
            activeSessions[index].lastActiveAt = Date()
            activeSessions[index].isPending = isPending
        } else {
            let session = ActiveSession(
                id: sessionId,
                terminalTitle: terminalTitle,
                lastToolName: toolName,
                lastEventName: eventName,
                lastMessage: message,
                startTime: Date(),
                lastActiveAt: Date(),
                isPending: isPending
            )
            activeSessions.insert(session, at: 0)
        }
    }

    private func pruneInactiveSessions() {
        let now = Date()
        let threshold: TimeInterval = self.timeoutDuration
        
        DispatchQueue.main.async {
            self.activeSessions.removeAll { session in
                !session.isPending && now.timeIntervalSince(session.lastActiveAt) > threshold
            }
        }
    }

    private func showNextRequest() {
        guard let next = pendingQueue.first else {
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
                if let index = self.activeSessions.firstIndex(where: { $0.id == removed.sessionId }) {
                    // Check if there are other pending items for this session
                    let stillPending = self.pendingQueue.contains { $0.sessionId == removed.sessionId }
                    self.activeSessions[index].isPending = stillPending
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
