import AppKit

class TerminalFocuser {
    private static let candidates: [(bundleId: String, name: String)] = [
        ("com.mitchellh.ghostty",   "Ghostty"),
        ("com.googlecode.iterm2",   "iTerm"),
        ("dev.warp.Warp-Stable",    "Warp"),
        ("com.apple.Terminal",      "Terminal"),
    ]

    static func focusTerminal(
        appName: String? = nil,
        title: String? = nil,
        tty: String? = nil,
        windowId: String? = nil,
        tabIndex: String? = nil
    ) {
        let targetName = normalizedAppName(appName)
        let match = targetName.flatMap { name in
            candidates.first { $0.name == name }
        } ?? candidates.first(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty
        })

        guard let match else { return }

        let name = match.name
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: focusScript(appName: name, title: title, tty: tty, windowId: windowId, tabIndex: tabIndex))?
                .executeAndReturnError(&error)
            if let error {
                print("[DevIsland] terminal focus AppleScript error: \(error)")
            }
        }
    }

    private static func normalizedAppName(_ appName: String?) -> String? {
        switch appName?.lowercased() {
        case "iterm", "iterm.app", "iterm2":
            return "iTerm"
        case "apple_terminal", "apple terminal", "terminal":
            return "Terminal"
        case "ghostty":
            return "Ghostty"
        case "warp", "warpterminal":
            return "Warp"
        default:
            return nil
        }
    }

    private static func focusScript(appName: String, title: String?, tty: String?, windowId: String?, tabIndex: String?) -> String {
        let titleLiteral = appleScriptLiteral(title ?? "")
        let ttyLiteral = appleScriptLiteral(tty ?? "")
        let ttyNameLiteral = appleScriptLiteral((tty ?? "").split(separator: "/").last.map(String.init) ?? "")
        let windowIdLiteral = appleScriptLiteral(windowId ?? "")
        let tabIndexLiteral = appleScriptLiteral(tabIndex ?? "")

        switch appName {
        case "iTerm":
            return """
            tell application "iTerm"
              activate
              set ttyPath to \(ttyLiteral)
              set ttyName to \(ttyNameLiteral)
              set wantedTitle to \(titleLiteral)
              repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                  repeat with aSession in sessions of aTab
                    set sessionTTY to tty of aSession
                    if (ttyPath is not "" and (sessionTTY is ttyPath or sessionTTY is ttyName)) or (wantedTitle is not "" and name of aSession is wantedTitle) then
                      set index of aWindow to 1
                      select aTab
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        case "Terminal":
            return """
            tell application "Terminal"
              set ttyPath to \(ttyLiteral)
              set ttyName to \(ttyNameLiteral)
              set wantedTitle to \(titleLiteral)
              set wantedWindowIdText to \(windowIdLiteral)
              set wantedTabIndexText to \(tabIndexLiteral)
              if wantedWindowIdText is not "" and wantedTabIndexText is not "" then
                try
                  set wantedWindow to window id (wantedWindowIdText as integer)
                  set wantedTab to tab (wantedTabIndexText as integer) of wantedWindow
                  set selected tab of wantedWindow to wantedTab
                  set selected of wantedTab to true
                  set frontmost of wantedWindow to true
                  set index of wantedWindow to 1
                  activate
                  return
                end try
              end if
              repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                  set tabTTY to tty of aTab
                  set tabTitle to ""
                  try
                    set tabTitle to custom title of aTab
                  end try
                  if (ttyPath is not "" and (tabTTY is ttyPath or tabTTY is ttyName)) or (wantedTitle is not "" and tabTitle is wantedTitle) then
                    set selected tab of aWindow to aTab
                    set selected of aTab to true
                    set frontmost of aWindow to true
                    set index of aWindow to 1
                    activate
                    delay 0.05
                    set selected tab of aWindow to aTab
                    set selected of aTab to true
                    set frontmost of aWindow to true
                    set index of aWindow to 1
                    return
                  end if
                end repeat
              end repeat
            end tell
            """
        default:
            return "tell application \"\(appName)\" to activate"
        }
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
