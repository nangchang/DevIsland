import AppKit
import SwiftUI

struct MessageMouseDownMonitor: NSViewRepresentable {
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> MouseDownMonitorView {
        let view = MouseDownMonitorView()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ nsView: MouseDownMonitorView, context: Context) {
        nsView.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ nsView: MouseDownMonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }
}

final class MouseDownMonitorView: NSView {
    var onMouseDown: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitorIfNeeded()
        }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) {
                self.onMouseDown?()
            }
            return event
        }
    }

    deinit {
        removeMonitor()
    }
}
