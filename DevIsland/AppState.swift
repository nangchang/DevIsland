import SwiftUI
import Combine

class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isNotchExpanded = false
    @Published var currentMessage: String = ""
    @Published var currentSessionId: String = ""
    @Published var currentToolName: String = ""
    @Published var currentEventName: String = ""
    @Published var timeoutProgress: Double = 1.0

    private var server = HookSocketServer()
    private var currentResponseHandler: ((String) -> Void)?
    private var timeoutTimer: Timer?
    private let timeoutDuration: Double = 300

    private init() {
        server.onMessageReceived = { [weak self] message, responseHandler in
            self?.handleMessage(message, responseHandler: responseHandler)
        }
        server.start()
    }

    private func handleMessage(_ message: String, responseHandler: @escaping (String) -> Void) {
        guard let data = message.data(using: .utf8) else { return }

        self.currentResponseHandler = responseHandler

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Claude Code hook payload keys
                let event     = json["hook_event_name"] as? String ?? "Unknown"
                let toolName  = json["tool_name"] as? String ?? ""
                let toolInput = json["tool_input"] as? [String: Any]
                let sessionId = json["session_id"] as? String ?? ""

                // Extract most relevant display string from tool_input
                var displayMsg = ""
                if let command = toolInput?["command"] as? String {
                    displayMsg = command
                } else if let filePath = toolInput?["file_path"] as? String {
                    displayMsg = filePath
                } else if let url = toolInput?["url"] as? String {
                    displayMsg = url
                } else if let input = toolInput {
                    displayMsg = input.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                }

                DispatchQueue.main.async {
                    self.currentEventName = event
                    self.currentToolName  = toolName
                    self.currentMessage   = displayMsg
                    self.currentSessionId = String(sessionId.prefix(8))
                    self.isNotchExpanded  = true
                    self.startTimeout()
                }
            }
        } catch {
            print("JSON parse error: \(error)")
            DispatchQueue.main.async {
                self.currentMessage   = message
                self.currentToolName  = ""
                self.currentEventName = "Unknown"
                self.currentSessionId = ""
                self.isNotchExpanded  = true
                self.startTimeout()
            }
        }
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
                if self.isNotchExpanded {
                    self.sendDecision(approved: false, reason: "Timeout")
                }
            }
        }
    }

    private func sendDecision(approved: Bool, reason: String? = nil) {
        // Bridge script parses {"response": "approved/denied"}
        let payload = approved
            ? "{\"response\": \"approved\"}"
            : "{\"response\": \"denied\"}"
        currentResponseHandler?(payload)
        currentResponseHandler = nil
        timeoutTimer?.invalidate()

        DispatchQueue.main.async {
            self.isNotchExpanded  = false
            self.timeoutProgress  = 1.0
        }
    }

    func approve() {
        sendDecision(approved: true)
    }

    func deny() {
        sendDecision(approved: false)
    }
}
