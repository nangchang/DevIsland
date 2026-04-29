import AppKit

class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()
    private var monitor: Any?

    private init() {}

    func start() {
        guard AXIsProcessTrusted() else {
            // Accessibility 권한 없으면 시스템 다이얼로그 표시
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            return
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in
            self?.handle($0)
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.command, .shift], AppState.shared.isNotchExpanded else { return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "y": DispatchQueue.main.async { AppState.shared.approve() }
        case "n": DispatchQueue.main.async { AppState.shared.deny() }
        default: break
        }
    }
}
