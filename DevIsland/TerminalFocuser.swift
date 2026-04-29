import AppKit

class TerminalFocuser {
    private static let candidates: [(bundleId: String, name: String)] = [
        ("com.mitchellh.ghostty",   "Ghostty"),
        ("com.googlecode.iterm2",   "iTerm2"),
        ("dev.warp.Warp-Stable",    "Warp"),
        ("com.apple.Terminal",      "Terminal"),
    ]

    static func focusTerminal() {
        guard let match = candidates.first(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty
        }) else { return }

        let name = match.name
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(name)\" to activate")?
                .executeAndReturnError(&error)
        }
    }
}
