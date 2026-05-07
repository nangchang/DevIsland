import AppKit

class TerminalFocuser {
    private static let tmuxCommandTimeout: TimeInterval = 1.0

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
        tabIndex: String?,
        tmuxPane: String?,
        tmuxSocket: String?,
        tmuxClient: String?
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

        let (resultStr, error) = executeAppleScript(frontmostCheckScript(
            appName: match.name,
            tty: tty,
            windowId: windowId,
            tabIndex: tabIndex
        ))
        let passed = resultStr == "true" || resultStr.hasPrefix("true|")
        
        if let error = error {
            print("[DevIsland] isSessionFrontmost: AppleScript error for \(match.name): \(error)")
        }
        
        print("[DevIsland] isSessionFrontmost: app=\(match.name) tty=\(tty ?? "nil") → \(passed ? "YES" : "NO") (\(resultStr))")
        guard passed else { return false }

        if let tmuxPane = tmuxPane, !tmuxPane.isEmpty {
            // tmux pane identity only makes sense after the terminal tab's outer TTY is frontmost.
            // Otherwise another tab attached to the same tmux server could make the pane check look valid.
            guard isValidTmuxPane(tmuxPane) else {
                print("[DevIsland] isSessionFrontmost: invalid tmux pane format: \(tmuxPane)")
                return false
            }

            let currentPane = currentTmuxPane(socket: tmuxSocket, client: tmuxClient)
            guard !currentPane.isEmpty else {
                print("[DevIsland] isSessionFrontmost: tmux pane unavailable for client=\(tmuxClient ?? "nil") socket=\(tmuxSocket ?? "nil")")
                return false
            }

            if currentPane == tmuxPane {
                return true
            } else {
                print("[DevIsland] isSessionFrontmost: tmux pane mismatch (current=\(currentPane) expected=\(tmuxPane))")
                return false
            }
        }

        return true
    }

    private static func executeAppleScript(_ source: String) -> (String, NSDictionary?) {
        if Thread.isMainThread {
            return executeAppleScriptOnCurrentThread(source)
        }

        var output = ""
        var scriptError: NSDictionary?
        DispatchQueue.main.sync {
            let result = executeAppleScriptOnCurrentThread(source)
            output = result.0
            scriptError = result.1
        }
        return (output, scriptError)
    }

    private static func executeAppleScriptOnCurrentThread(_ source: String) -> (String, NSDictionary?) {
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: source) else {
            print("[DevIsland] Failed to create NSAppleScript object")
            return ("nil", nil)
        }

        let result = scriptObject.executeAndReturnError(&error)
        return (result.stringValue ?? "nil", error)
    }

    private static func frontmostCheckScript(appName: String, tty: String?, windowId: String?, tabIndex: String?) -> String {
        let ttyLiteral = appleScriptLiteral(tty ?? "")
        let ttyNameLiteral = appleScriptLiteral((tty ?? "").split(separator: "/").last.map(String.init) ?? "")
        let windowIdLiteral = appleScriptLiteral(windowId ?? "")
        let tabIndexLiteral = appleScriptLiteral(tabIndex ?? "")

        switch appName {
        case "iTerm":
            return """
            tell application "iTerm"
              try
                set ttyPath to \(ttyLiteral)
                set ttyName to \(ttyNameLiteral)
                set wantedWindowIdText to \(windowIdLiteral)
                set wantedTabIndexText to \(tabIndexLiteral)
                set sess to current session of current window
                if wantedWindowIdText is not "" and wantedTabIndexText is not "" then
                  set fwId to (id of current window as text)
                  set selectedTabNumber to 0
                  repeat with aTab in tabs of current window
                    set selectedTabNumber to selectedTabNumber + 1
                    if aTab is current tab of current window then exit repeat
                  end repeat
                  if fwId is wantedWindowIdText and (selectedTabNumber as text) is wantedTabIndexText then
                    if ttyPath is "" or tty of sess is ttyPath or tty of sess is ttyName then return "true"
                  end if
                end if
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

    private static func getProcessOutput(executable: URL, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            terminateProcess(process, after: tmuxCommandTimeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            print("[DevIsland] Failed to run process: \(executable.path) \(arguments.joined(separator: " ")), error: \(error)")
            return ""
        }
    }

    private static func runProcess(executable: URL, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            terminateProcess(process, after: tmuxCommandTimeout)
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            print("[DevIsland] Failed to run process: \(executable.path) \(arguments.joined(separator: " ")), error: \(error)")
            return false
        }
    }

    private static func terminateProcess(_ process: Process, after timeout: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                print("[DevIsland] tmux command timed out, terminating pid=\(process.processIdentifier)")
                process.terminate()
            }
        }
    }

    private static func tmuxExecutableURL() -> URL {
        let paths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private static func tmuxArguments(socket: String?, command: [String]) -> [String] {
        let executable = tmuxExecutableURL().path
        var arguments = executable == "/usr/bin/env" ? ["tmux"] : []
        if let socket, isValidTmuxSocket(socket) {
            arguments += ["-S", socket]
        }
        arguments += command
        return arguments
    }

    private static func isValidTmuxPane(_ pane: String) -> Bool {
        pane.range(of: #"^%\d+$"#, options: .regularExpression) != nil
    }

    private static func isValidTmuxSocket(_ socket: String) -> Bool {
        socket.hasPrefix("/") && !socket.contains("\u{0}")
    }

    private static func isValidTmuxClient(_ client: String) -> Bool {
        !client.isEmpty && !client.contains("\u{0}")
    }

    private static func currentTmuxPane(socket: String?, client: String?) -> String {
        let executable = tmuxExecutableURL()
        var command = ["display-message", "-p"]
        if let client, isValidTmuxClient(client) {
            command += ["-c", client]
        }
        command.append("#{pane_id}")
        return getProcessOutput(
            executable: executable,
            arguments: tmuxArguments(socket: socket, command: command)
        )
    }

    private static func tmuxFormat(socket: String?, target: String, format: String) -> String {
        getProcessOutput(
            executable: tmuxExecutableURL(),
            arguments: tmuxArguments(socket: socket, command: ["display-message", "-p", "-t", target, format])
        )
    }

    @discardableResult
    private static func switchTmuxClient(socket: String?, client: String?, pane: String) -> Bool {
        guard isValidTmuxPane(pane) else {
            print("[DevIsland] focusTerminal: invalid tmux pane format: \(pane)")
            return false
        }

        let executable = tmuxExecutableURL()
        let targetSession = tmuxFormat(socket: socket, target: pane, format: "#{session_id}")
        let selectWindowSucceeded = runProcess(
            executable: executable,
            arguments: tmuxArguments(socket: socket, command: ["select-window", "-t", pane])
        )
        if !selectWindowSucceeded {
            print("[DevIsland] tmux select-window failed for pane=\(pane) socket=\(socket ?? "nil")")
        }

        let selectPaneSucceeded = runProcess(
            executable: executable,
            arguments: tmuxArguments(socket: socket, command: ["select-pane", "-t", pane])
        )
        if !selectPaneSucceeded {
            print("[DevIsland] tmux select-pane failed for pane=\(pane) socket=\(socket ?? "nil")")
        }

        var switchCommand = ["switch-client"]
        if let client, isValidTmuxClient(client) {
            switchCommand += ["-c", client]
        }
        switchCommand += ["-t", targetSession.isEmpty ? pane : targetSession]

        let switchSucceeded = runProcess(
            executable: executable,
            arguments: tmuxArguments(socket: socket, command: switchCommand)
        )
        if !switchSucceeded {
            print("[DevIsland] tmux switch-client failed for pane=\(pane) client=\(client ?? "nil") target=\(targetSession.isEmpty ? pane : targetSession) socket=\(socket ?? "nil")")
        }

        return selectWindowSucceeded && selectPaneSucceeded && switchSucceeded
    }

    static func focusTerminal(
        appName: String? = nil,
        title: String? = nil,
        tty: String? = nil,
        windowId: String? = nil,
        tabIndex: String? = nil,
        tmuxPane: String? = nil,
        tmuxSocket: String? = nil,
        tmuxClient: String? = nil
    ) {
        let targetName = normalizedAppName(appName)
        let match = targetName.flatMap { name in
            candidates.first { $0.name == name }
        } ?? candidates.first(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty
        })

        guard let match else { return }

        let name = match.name
        DispatchQueue.main.async {
            let (_, error) = executeAppleScript(focusScript(appName: name, title: title, tty: tty, windowId: windowId, tabIndex: tabIndex))
            if let error {
                print("[DevIsland] terminal focus AppleScript error: \(error)")
            }
            if let tmuxPane = tmuxPane, !tmuxPane.isEmpty {
                DispatchQueue.global(qos: .userInitiated).async {
                    print("[DevIsland] tmux pane detected: \(tmuxPane), switching client=\(tmuxClient ?? "nil") socket=\(tmuxSocket ?? "nil")")
                    if !switchTmuxClient(socket: tmuxSocket, client: tmuxClient, pane: tmuxPane) {
                        print("[DevIsland] tmux switch failed for pane=\(tmuxPane)")
                    }
                }
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
              set wantedWindowIdText to \(windowIdLiteral)
              set wantedTabIndexText to \(tabIndexLiteral)
              if wantedWindowIdText is not "" and wantedTabIndexText is not "" then
                try
                  repeat with aWindow in windows
                    if (id of aWindow as text) is wantedWindowIdText then
                      set aTab to tab (wantedTabIndexText as integer) of aWindow
                      repeat with aSession in sessions of aTab
                        set sessionTTY to tty of aSession
                        if ttyPath is not "" and (sessionTTY is ttyPath or sessionTTY is ttyName) then
                          select aWindow
                          select aTab
                          select aSession
                          activate
                          return
                        end if
                      end repeat
                    end if
                  end repeat
                end try
              end if
              repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                  repeat with aSession in sessions of aTab
                    set sessionTTY to tty of aSession
                    if (ttyPath is not "" and (sessionTTY is ttyPath or sessionTTY is ttyName)) or (wantedTitle is not "" and name of aSession is wantedTitle) then
                      select aWindow
                      select aTab
                      select aSession
                      activate
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
