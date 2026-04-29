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

struct PendingItem: Identifiable {
    let id: UUID
    let toolName: String
    let message: String
    let sessionId: String
}

// MARK: - App State

class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isNotchExpanded = false
    @Published var currentMessage: String = ""
    @Published var currentSessionId: String = ""
    @Published var currentToolName: String = ""
    @Published var currentEventName: String = ""
    @Published var timeoutProgress: Double = 1.0
    @Published var pendingCount: Int = 0
    @Published var pendingItems: [PendingItem] = []

    private var server = HookSocketServer()
    private var pendingQueue: [PendingRequest] = []
    private var currentResponseHandler: ((String) -> Void)?
    private var timeoutTimer: Timer?
    private let timeoutDuration: Double = 300

    private init() {
        server.onMessageReceived = { [weak self] message, responseHandler in
            self?.handleMessage(message, responseHandler: responseHandler)
        }
        server.start()
        GlobalShortcutManager.shared.start()
    }

    private func handleMessage(_ message: String, responseHandler: @escaping (String) -> Void) {
        guard let data = message.data(using: .utf8) else { return }

        var event     = "Unknown"
        var toolName  = ""
        var sessionId = ""
        var displayMsg = ""

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                event     = json["hook_event_name"] as? String ?? "Unknown"
                toolName  = json["tool_name"] as? String ?? ""
                sessionId = json["session_id"] as? String ?? ""
                let toolInput = json["tool_input"] as? [String: Any]

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
            self.pendingItems.append(PendingItem(
                id: request.id,
                toolName: request.toolName,
                message: request.message,
                sessionId: String(request.sessionId.prefix(8))
            ))
            self.pendingCount = self.pendingQueue.count
            if !self.isNotchExpanded {
                self.showNextRequest()
            }
        }
    }

    private func showNextRequest() {
        guard let next = pendingQueue.first else {
            isNotchExpanded = false
            return
        }
        currentResponseHandler = next.responseHandler
        currentEventName  = next.eventName
        currentToolName   = next.toolName
        currentMessage    = next.message
        currentSessionId  = String(next.sessionId.prefix(8))
        isNotchExpanded   = true
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
            self.timeoutProgress = 1.0
            if !self.pendingQueue.isEmpty {
                self.pendingQueue.removeFirst()
                if !self.pendingItems.isEmpty { self.pendingItems.removeFirst() }
                self.pendingCount = self.pendingQueue.count
            }
            self.showNextRequest()
        }
        TerminalFocuser.focusTerminal()
    }

    func approve() {
        sendDecision(approved: true)
    }

    func deny() {
        sendDecision(approved: false)
    }
}

class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()
    private var monitor: Any?

    private init() {}

    func start() {
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return
        }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.command, .shift], AppState.shared.isNotchExpanded else { return }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "y":
            DispatchQueue.main.async { AppState.shared.approve() }
        case "n":
            DispatchQueue.main.async { AppState.shared.deny() }
        default:
            break
        }
    }
}

class TerminalFocuser {
    private static let candidates: [(bundleId: String, name: String)] = [
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.apple.Terminal", "Terminal")
    ]

    static func focusTerminal() {
        guard let match = candidates.first(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty
        }) else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(match.name)\" to activate")?
                .executeAndReturnError(&error)
        }
    }
}
