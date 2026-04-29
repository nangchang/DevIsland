import SwiftUI
import Combine

class AppState: ObservableObject {
    static let shared = AppState()
    
    @Published var isNotchExpanded = false
    @Published var currentMessage: String = "Waiting for Claude..."
    
    private var server = HookSocketServer()
    
    private var currentResponseHandler: ((String) -> Void)?
    
    private init() {
        server.onMessageReceived = { [weak self] message, responseHandler in
            self?.handleMessage(message, responseHandler: responseHandler)
        }
        server.start()
    }
    
    private func handleMessage(_ message: String, responseHandler: @escaping (String) -> Void) {
        guard let data = message.data(using: .utf8) else { return }
        
        // Save the handler
        self.currentResponseHandler = responseHandler
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Claude Code hook payload keys: hook_event_name, tool_name, tool_input
                let event    = json["hook_event_name"] as? String ?? "Unknown Event"
                let toolName = json["tool_name"] as? String ?? ""
                let toolInput = json["tool_input"] as? [String: Any]
                
                var displayMsg = "[\(event)]"
                if !toolName.isEmpty {
                    displayMsg += " \(toolName)"
                }
                // Bash: command, Write/Edit: file_path
                if let command = toolInput?["command"] as? String {
                    displayMsg += ": \(command)"
                } else if let filePath = toolInput?["file_path"] as? String {
                    displayMsg += ": \(filePath)"
                }
                
                self.currentMessage = displayMsg
                self.isNotchExpanded = true
                
                // We shouldn't auto-collapse if it requires an answer, but for now we do
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    if self.isNotchExpanded {
                        self.isNotchExpanded = false
                        self.currentResponseHandler?("{\"response\": \"timeout\"}")
                        self.currentResponseHandler = nil
                    }
                }
            }
        } catch {
            print("JSON parse error: \(error)")
            self.currentMessage = message
            self.isNotchExpanded = true
        }
    }
    
    func approve() {
        print("Approved")
        currentResponseHandler?("{\"response\": \"approved\"}")
        currentResponseHandler = nil
        isNotchExpanded = false
        currentMessage = "Approved"
    }
    
    func deny() {
        print("Denied")
        currentResponseHandler?("{\"response\": \"denied\"}")
        currentResponseHandler = nil
        isNotchExpanded = false
        currentMessage = "Denied"
    }
}
