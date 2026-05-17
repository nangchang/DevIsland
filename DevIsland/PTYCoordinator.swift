import Foundation

/// Handles PTY hook events: pattern matching, auto-injection, and persistence.
///
/// AppState holds an instance and delegates all PTY event processing here.
final class PTYCoordinator {
    private let ptyBuffer: PTYSessionBuffer
    private let approvalProxy: ApprovalProxyController?
    private let persistenceQueue: DispatchQueue
    private let userDefaults: UserDefaults

    init(
        ptyBuffer: PTYSessionBuffer,
        approvalProxy: ApprovalProxyController?,
        persistenceQueue: DispatchQueue,
        userDefaults: UserDefaults
    ) {
        self.ptyBuffer = ptyBuffer
        self.approvalProxy = approvalProxy
        self.persistenceQueue = persistenceQueue
        self.userDefaults = userDefaults
    }

    func handleOutputEvent(
        sessionId: String,
        provider: ProviderKind,
        content: String,
        responseHandler: (String) -> Void
    ) {
        guard isEnabled(), !content.isEmpty else {
            responseHandler("{\"response\":\"approved\"}")
            return
        }
        let window = ptyBuffer.appendAndWindow(sessionId: sessionId, content: content)
        let patterns = autoInjectPatterns()
        let matched = patterns.first { window.lowercased().contains($0.pattern.lowercased()) }
        let injectionText = matched?.response

        if injectionText != nil {
            ptyBuffer.clearOnMatch(sessionId: sessionId)
        }

        persistenceQueue.async { [weak self] in
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

    func clearBuffer(sessionId: String) {
        ptyBuffer.remove(sessionId: sessionId)
    }

    private func isEnabled() -> Bool {
        userDefaults.bool(forKey: SettingsStore.DefaultsKey.ptyEnabled)
    }

    private func autoInjectPatterns() -> [PTYAutoInjectPattern] {
        guard let data = userDefaults.data(forKey: SettingsStore.DefaultsKey.ptyAutoInjectPatterns),
              let patterns = try? JSONDecoder().decode([PTYAutoInjectPattern].self, from: data) else {
            return []
        }
        return patterns
    }
}
