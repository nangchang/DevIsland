import SwiftUI
import AppKit
import Combine

@MainActor
final class HostedWindowController: NSWindowController, NSWindowDelegate {
    private let onWindowWillClose: (() -> Void)?
    private var localizedTitleCancellable: AnyCancellable?

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

    convenience init(
        localizedTitleKey: String,
        size: NSSize,
        rootView: AnyView,
        onWindowWillClose: (() -> Void)? = nil
    ) {
        self.init(
            title: L10n.shared.t(localizedTitleKey),
            size: size,
            rootView: rootView,
            onWindowWillClose: onWindowWillClose
        )
        localizedTitleCancellable = L10n.shared.$language.sink { [weak window] language in
            window?.title = L10n.shared.t(localizedTitleKey, language: language)
        }
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
