import AppKit

// 메인 스레드에서 NSAlert 모달을 안전하게 표시하는 공통 경로.
// LSUIElement 앱은 유저 이벤트 컨텍스트 없이 activate가 무시되므로
// .regular 정책으로 일시 전환하고, nonactivatingPanel인 notch 패널을
// 모달 기간 동안 완전히 숨긴다.
enum ModalPresenter {
    @discardableResult
    @MainActor
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        AppState.shared.isNotchExpanded = false
        let notch = NotchWindowController.current
        notch?.hideForModal()
        defer { notch?.restoreAfterModal() }

        alert.window.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

        let policy = NSApp.activationPolicy()
        if policy != .regular { NSApp.setActivationPolicy(.regular) }
        defer { if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) } }

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
