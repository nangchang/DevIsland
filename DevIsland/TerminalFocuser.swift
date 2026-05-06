import AppKit

class TerminalFocuser {
    private static let candidates: [(bundleId: String, name: String)] = [
        ("com.mitchellh.ghostty",   "Ghostty"),
        ("com.googlecode.iterm2",   "iTerm"),
        ("dev.warp.Warp-Stable",    "Warp"),
        ("com.apple.Terminal",      "Terminal"),
    ]

    static func isSessionFrontmost(
        appName: String?,
        tty: String?,
        windowId: String?,
        tabIndex: String?
    ) -> Bool {
        let targetName = normalizedAppName(appName)
        let match = targetName.flatMap { name in
            candidates.first { $0.name == name }
        } ?? candidates.first(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty
        })
        print("[DevIsland] isSessionFrontmost: appName=\(appName ?? "nil") → targetName=\(targetName ?? "nil") → match=\(match?.name ?? "none")")
        guard let match else { return false }

        let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isActive = frontBundleId == match.bundleId
        print("[DevIsland] isSessionFrontmost: \(match.name) frontmost=\(frontBundleId ?? "nil") expected=\(match.bundleId) isActive=\(isActive)")
        guard isActive else { return false }

        let script = frontmostCheckScript(appName: match.name, tty: tty, windowId: windowId, tabIndex: tabIndex)
        var error: NSDictionary?
        
        // Execute AppleScript with a safeguard
        guard let scriptObject = NSAppleScript(source: script) else {
            print("[DevIsland] isSessionFrontmost: Failed to create NSAppleScript object")
            return false
        }
        
        let result = scriptObject.executeAndReturnError(&error)
        let resultStr = result.stringValue ?? "nil"
        let passed = resultStr == "true" || resultStr.hasPrefix("true|")
        
        if let error = error {
            print("[DevIsland] isSessionFrontmost: AppleScript error for \(match.name): \(error)")
        }
        
        print("[DevIsland] isSessionFrontmost: app=\(match.name) tty=\(tty ?? "nil") → \(passed ? "YES" : "NO") (\(resultStr))")
        return passed
    }

    private static func frontmostCheckScript(appName: String, tty: String?, windowId: String?, tabIndex: String?) -> String {
        let ttyLiteral = appleScriptLiteral(tty ?? "")
        let ttyNameLiteral = appleScriptLiteral((tty ?? "").split(separator: "/").last.map(String.init) ?? "")

        switch appName {
        case "iTerm":
            return """
            tell application "iTerm"
              try
                set ttyPath to \(ttyLiteral)
                set ttyName to \(ttyNameLiteral)
                set sess to current session of current window
                if (ttyPath is not "" and (tty of sess is ttyPath or tty of sess is ttyName)) then return "true"
              end try
              return "false"
            end tell
            """
        case "Terminal":
            return """
            tell application "Terminal"
              set ttyPath to \(ttyLiteral)
              set ttyName to \(ttyNameLiteral)
              try
                set fw to front window
                set fwId to (id of fw as text)
                set selTab to selected tab of fw
                set tabTTY to tty of selTab
                set diag to "|fwId=" & fwId & " tabTTY=" & tabTTY
                if ttyPath is not "" then
                  if tabTTY is ttyPath or tabTTY is ttyName then return "true" & diag
                end if
                return "false" & diag
              on error e
                return "false|err:" & e
              end try
            end tell
            """
        default:
            // Ghostty, Warp 등 탭 특정이 불가능한 앱 — 앱 레벨 포커스는 호출 전에 이미 확인됨
            return "return \"true\""
        }
    }

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

    static func normalizedAppName(_ appName: String?) -> String? {
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
                    return
                  end if
                end repeat
              end repeat
              activate
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
