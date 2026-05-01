import AppKit

class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()
    private var monitor: Any?

    private init() {}

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func start() {
        guard monitor == nil, hasAccessibilityPermission else {
            return
        }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in
            self?.handle($0)
        }
    }

    func requestAccessibilityPermission() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
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
