import SwiftUI
import AppKit

@MainActor
final class HostedWindowController: NSWindowController, NSWindowDelegate {
    private let onWindowWillClose: (() -> Void)?

    init(
        title: String,
        size: NSSize,
        rootView: AnyView,
        onWindowWillClose: (() -> Void)? = nil
    ) {
        self.onWindowWillClose = onWindowWillClose
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.setContentSize(size)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.centerIfNotVisible()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onWindowWillClose?()
    }
}

private extension NSWindow {
    func centerIfNotVisible() {
        guard !isVisible else { return }
        center()
    }
}
