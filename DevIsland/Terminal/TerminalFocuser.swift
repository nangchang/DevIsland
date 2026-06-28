import AppKit
import Darwin

class TerminalFocuser {
    private static let tmuxCommandTimeout: TimeInterval = 1.0
    private static let appleScriptTimeout: TimeInterval = 1.5
    private static let cmuxFocusSettleDelay = "0.05"

    private static let candidates: [(bundleId: String, name: String)] = [
        ("com.cmuxterm.app",                "cmux"),
        ("com.mitchellh.ghostty",           "Ghostty"),
        ("com.googlecode.iterm2",           "iTerm"),
        ("dev.warp.Warp-Stable",            "Warp"),
        ("com.github.wez.wezterm",          "WezTerm"),
        ("com.apple.Terminal",              "Terminal"),
        ("com.microsoft.VSCode",            "VSCode"),
        ("com.anthropic.claudefordesktop",  "ClaudeDesktop"),
        ("com.openai.codex",               "CodexDesktop"),
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
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return (
                "nil",
                [
                    "NSLocalizedDescription": "Failed to run osascript: \(error.localizedDescription)"
                ] as NSDictionary
            )
        }

        let completed = waitForProcess(process, timeout: appleScriptTimeout)
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil"
        let errorOutput = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard completed else {
            print("[DevIsland] AppleScript timed out after \(appleScriptTimeout)s")
            return (
                "nil",
                [
                    "NSLocalizedDescription": "AppleScript timed out after \(appleScriptTimeout)s"
                ] as NSDictionary
            )
        }

        guard process.terminationStatus == 0 else {
            return (
                output.isEmpty ? "nil" : output,
                [
                    "NSLocalizedDescription": errorOutput.isEmpty ? "osascript exited with status \(process.terminationStatus)" : errorOutput,
                    "terminationStatus": process.terminationStatus
                ] as NSDictionary
            )
        }

        return (output.isEmpty ? "nil" : output, nil)
    }

    private static func waitForProcess(_ process: Process, timeout: TimeInterval) -> Bool {
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }

        guard group.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning {
                process.terminate()
            }
            if group.wait(timeout: .now() + 0.5) != .success, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 1.0)
            }
            return false
        }

        return true
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
        case "cmux":
            return """
            tell application "cmux"
              try
                set wantedTabId to \(windowIdLiteral)
                set wantedTermId to \(tabIndexLiteral)
                set fw to front window
                set selTab to selected tab of fw
                if wantedTabId is "" or (id of selTab as text) is wantedTabId then
                  if wantedTermId is "" then return "true"
                  set focTerm to focused terminal of selTab
                  if (id of focTerm as text) is wantedTermId then return "true"
                end if
              end try
              return "false"
            end tell
            """
        default:
            // Ghostty, Warp 등 탭 특정이 불가능한 앱 — 앱 레벨 포커스는 호출 전에 이미 확인됨
            return "return \"true\""
        }
    }

    private static func getProcessOutput(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
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

    private static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
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

    private static func launchProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            return true
        } catch {
            print("[DevIsland] Failed to launch process: \(executable.path) \(arguments.joined(separator: " ")), error: \(error)")
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

    static func wezTermCLIURL(for appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/MacOS/wezterm")
    }

    static func wezTermActivatePaneArguments(paneId: Any) -> [String] {
        ["cli", "activate-pane", "--pane-id", "\(paneId)"]
    }

    static func wezTermStartNewTabArguments(command: String) -> [String] {
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ["start", "--new-tab", "--", "/bin/zsh", "-l"]
        }
        return ["start", "--new-tab", "--", "/bin/zsh", "-lic", "\(command); exec /bin/zsh -l"]
    }

    static func wezTermSpawnTabArguments(command: String, windowId: Any) -> [String] {
        let shellArguments = command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ["/bin/zsh", "-l"]
            : ["/bin/zsh", "-lic", "\(command); exec /bin/zsh -l"]
        return ["cli", "spawn", "--window-id", "\(windowId)", "--"] + shellArguments
    }

    static func wezTermSocketEnvironment(socketURL: URL) -> [String: String] {
        ["WEZTERM_UNIX_SOCKET": socketURL.path]
    }

    static func wezTermPreferredSocketEnvironment(in directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/wezterm")) -> [String: String]? {
        wezTermSocketCandidates(in: directory).first.map(wezTermSocketEnvironment)
    }

    static func wezTermSocketCandidates(in directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/wezterm")) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.lastPathComponent.hasPrefix("gui-sock-") }
            .sorted { lhs, rhs in
                let lhsRunning = wezTermSocketPIDIsRunning(lhs)
                let rhsRunning = wezTermSocketPIDIsRunning(rhs)
                if lhsRunning != rhsRunning { return lhsRunning }

                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }

                return lhs.path < rhs.path
            }
    }

    private static func wezTermSocketPIDIsRunning(_ socketURL: URL) -> Bool {
        let prefix = "gui-sock-"
        let name = socketURL.lastPathComponent
        guard name.hasPrefix(prefix),
              let pid = Int32(name.dropFirst(prefix.count)) else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func wezTermPaneID(in panesJSON: String, matchingTTY tty: String) -> String? {
        let ttyName = String(tty.split(separator: "/").last ?? Substring(tty))
        guard let data = panesJSON.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        for pane in panes {
            guard let paneTty = pane["tty_name"] as? String else { continue }
            let paneTtyName = String(paneTty.split(separator: "/").last ?? Substring(paneTty))
            if paneTtyName == ttyName || paneTty == tty {
                return pane["pane_id"].map { "\($0)" }
            }
        }

        return nil
    }

    static func wezTermPaneTTY(in panesJSON: String, matchingPaneId paneId: String) -> String? {
        guard let data = panesJSON.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        for pane in panes {
            if let id = pane["pane_id"], "\(id)" == paneId {
                return pane["tty_name"] as? String
            }
        }
        return nil
    }

    private static func wezTermPaneTargetByID(cli: URL, paneId: String) -> (tty: String, environment: [String: String]?)? {
        let socketEnvironments = wezTermSocketCandidates().map(wezTermSocketEnvironment)
        let environments: [[String: String]?] = socketEnvironments.isEmpty ? [nil] : socketEnvironments.map(Optional.some)

        for environment in environments {
            let json = getProcessOutput(
                executable: cli,
                arguments: ["cli", "list", "--format", "json"],
                environment: environment
            )
            if let tty = wezTermPaneTTY(in: json, matchingPaneId: paneId) {
                return (tty, environment)
            }
        }
        return nil
    }

    private static func tmuxClientForTTY(socket: String?, tty: String) -> String? {
        let output = getProcessOutput(
            executable: tmuxExecutableURL(),
            arguments: tmuxArguments(socket: socket, command: ["list-clients", "-F", "#{client_name}|#{client_tty}"])
        )
        let ttyBasename = String(tty.split(separator: "/").last ?? Substring(tty))
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "|")
            guard parts.count == 2 else { continue }
            let clientName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let clientTTY = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clientName.isEmpty else { continue }
            let clientBasename = String(clientTTY.split(separator: "/").last ?? Substring(clientTTY))
            if clientTTY == tty || clientBasename == ttyBasename {
                return clientName
            }
        }
        return nil
    }

    static func wezTermActiveWindowID(in panesJSON: String) -> String? {
        guard let data = panesJSON.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        let activePane = panes.first { ($0["is_active"] as? Bool) == true } ?? panes.first
        return activePane?["window_id"].map { "\($0)" }
    }

    static func wezTermWindowIDForPaneID(in panesJSON: String, paneId: String) -> String? {
        guard let data = panesJSON.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        for pane in panes {
            if pane["pane_id"].map({ "\($0)" }) == paneId {
                return pane["window_id"].map { "\($0)" }
            }
        }
        return nil
    }

    private static func wezTermWindowTarget(cli: URL, paneId: String) -> (windowId: String, environment: [String: String]?)? {
        let socketEnvironments = wezTermSocketCandidates().map(wezTermSocketEnvironment)
        let environments: [[String: String]?] = socketEnvironments.isEmpty ? [nil] : socketEnvironments.map(Optional.some)

        for environment in environments {
            let json = getProcessOutput(
                executable: cli,
                arguments: ["cli", "list", "--format", "json"],
                environment: environment
            )
            if let wid = wezTermWindowIDForPaneID(in: json, paneId: paneId) {
                return (wid, environment)
            }
            // Fallback: any active window
            if let wid = wezTermActiveWindowID(in: json) {
                return (wid, environment)
            }
        }
        return nil
    }

    private static func wezTermPaneTarget(cli: URL, tty: String) -> (paneId: String, environment: [String: String]?)? {
        let socketEnvironments = wezTermSocketCandidates().map(wezTermSocketEnvironment)
        let environments: [[String: String]?] = socketEnvironments.isEmpty ? [nil] : socketEnvironments.map(Optional.some)

        for environment in environments {
            let json = getProcessOutput(
                executable: cli,
                arguments: ["cli", "list", "--format", "json"],
                environment: environment
            )
            if let paneId = wezTermPaneID(in: json, matchingTTY: tty) {
                return (paneId, environment)
            }
        }

        return nil
    }

    private static func wezTermActiveWindowTarget(cli: URL) -> (windowId: String, environment: [String: String]?)? {
        let socketEnvironments = wezTermSocketCandidates().map(wezTermSocketEnvironment)
        let environments: [[String: String]?] = socketEnvironments.isEmpty ? [nil] : socketEnvironments.map(Optional.some)

        for environment in environments {
            let json = getProcessOutput(
                executable: cli,
                arguments: ["cli", "list", "--format", "json"],
                environment: environment
            )
            if let windowId = wezTermActiveWindowID(in: json) {
                return (windowId, environment)
            }
        }

        return nil
    }

    static func focusTerminal(
        appName: String? = nil,
        title: String? = nil,
        tty: String? = nil,
        windowId: String? = nil,
        tabIndex: String? = nil,
        tmuxPane: String? = nil,
        tmuxSocket: String? = nil,
        tmuxClient: String? = nil,
        managerSessionTitle: String? = nil,
        workspaceRoot: String? = nil,
        completion: (() -> Void)? = nil
    ) {
        let targetName = normalizedAppName(appName)
        let match = targetName.flatMap { name in
            candidates.first { $0.name == name }
        } ?? candidates.first(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty
        })

        guard let match else {
            if let completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
            return
        }

        let name = match.name
        DispatchQueue.global(qos: .userInitiated).async {
            // This launches /usr/bin/osascript as a child process, so keep it off the main thread.
            var tmuxHandled = false
            var resolvedTTY: String? = tty
            var wezTermNavCli: URL? = nil
            var wezTermNavPaneId: String? = nil
            var wezTermNavEnv: [String: String]? = nil
            var wezTermAppUrl: URL? = nil
            if name == "VSCode", let path = workspaceRoot, !path.isEmpty {
                let ok = runProcess(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Visual Studio Code", path])
                if !ok {
                    print("[DevIsland] open VS Code failed for path: \(path)")
                }
            } else if name == "WezTerm" {
                // WezTerm doesn't support AppleScript — use the CLI to focus the exact pane by TTY.
                let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: match.bundleId)
                let cli = appUrl.map(wezTermCLIURL)
                var outerTTY: String? = nil

                if let cli {
                    // 1. Find and activate the WezTerm pane
                    var paneActivated = false
                    if let tty, !tty.isEmpty, let target = wezTermPaneTarget(cli: cli, tty: tty) {
                        _ = runProcess(executable: cli,
                                       arguments: wezTermActivatePaneArguments(paneId: target.paneId),
                                       environment: target.environment)
                        outerTTY = tty
                        paneActivated = true
                    }
                    // Fallback: windowId = inherited WEZTERM_PANE (e.g. Agent of Empires detached sessions)
                    // Only activate if the pane actually exists — stale WEZTERM_PANE (e.g. =0) must be skipped.
                    if !paneActivated, let windowId, !windowId.isEmpty,
                       let lookup = wezTermPaneTargetByID(cli: cli, paneId: windowId) {
                        _ = runProcess(executable: cli,
                                       arguments: wezTermActivatePaneArguments(paneId: windowId),
                                       environment: lookup.environment)
                        outerTTY = lookup.tty
                        paneActivated = true
                    }

                    // 2. Navigate to the tmux session
                    if let tmuxPane, !tmuxPane.isEmpty {
                        tmuxHandled = true
                        var client = tmuxClient

                        // 2a. Find client from outer TTY (standard WezTerm+tmux case)
                        if client == nil || client!.isEmpty, let tty = outerTTY, !tty.isEmpty {
                            client = tmuxClientForTTY(socket: tmuxSocket, tty: tty)
                        }

                        if let client, !client.isEmpty {
                            // Client found: switch it to the target session
                            print("[DevIsland] WezTerm tmux switch: client=\(client) pane=\(tmuxPane)")
                            if !switchTmuxClient(socket: tmuxSocket, client: client, pane: tmuxPane) {
                                print("[DevIsland] WezTerm tmux switch-client failed pane=\(tmuxPane)")
                            }
                        } else {
                            // No client attached (e.g. AoE fully detached sessions).
                            // The windowId pane (WEZTERM_PANE) is the tool's own TUI pane which already
                            // shows the agent output — activating it is sufficient; no new pane needed.
                            print("[DevIsland] WezTerm: no tmux client for pane=\(tmuxPane), relying on windowId pane activation")
                        }
                    }

                    // Prepare AoE navigation (used in common block after if/else chain)
                    wezTermNavCli = cli
                    if let activeTTY = outerTTY, !activeTTY.isEmpty,
                       let found = wezTermPaneTarget(cli: cli, tty: activeTTY) {
                        wezTermNavPaneId = found.paneId
                        wezTermNavEnv = found.environment
                    } else if let wid = windowId, !wid.isEmpty {
                        wezTermNavPaneId = wid
                        wezTermNavEnv = wezTermPreferredSocketEnvironment()
                    }

                }

                resolvedTTY = outerTTY ?? resolvedTTY
                wezTermAppUrl = appUrl
            } else {
                let (_, error) = executeAppleScript(focusScript(appName: name, title: title, tty: tty, windowId: windowId, tabIndex: tabIndex))
                if let error {
                    print("[DevIsland] terminal focus AppleScript error: \(error)")
                }
            }
            // Manager TUI session navigation (e.g. AoE "/" search)
            if let managerTitle = managerSessionTitle, !managerTitle.isEmpty {
                if let cli = wezTermNavCli, let paneId = wezTermNavPaneId {
                    // WezTerm: use send-text to avoid triggering WezTerm's activity-focus behavior
                    let navEnv = wezTermNavEnv
                    let sendText = { (text: String) in
                        _ = runProcess(executable: cli,
                                       arguments: ["cli", "send-text", "--no-paste",
                                                   "--pane-id", paneId, text],
                                       environment: navEnv)
                    }
                    Thread.sleep(forTimeInterval: 0.15)
                    sendText("\u{11}")          // Ctrl+Q: exit LIVE mode if active
                    Thread.sleep(forTimeInterval: 0.3)
                    sendText("/")
                    Thread.sleep(forTimeInterval: 0.1)
                    sendText(managerTitle)
                    Thread.sleep(forTimeInterval: 0.15)
                    sendText("\r")
                } else if name == "iTerm" {
                    runITermManagerNavigation(managerTitle: managerTitle)
                } else if name == "Terminal" || name == "cmux" {
                    tmuxHandled = true
                }
            }
            if let appUrl = wezTermAppUrl {
                DispatchQueue.main.async {
                    NSWorkspace.shared.openApplication(at: appUrl, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            if !tmuxHandled, let tmuxPane = tmuxPane, !tmuxPane.isEmpty {
                print("[DevIsland] tmux pane detected: \(tmuxPane), switching client=\(tmuxClient ?? "nil") socket=\(tmuxSocket ?? "nil")")
                if !switchTmuxClient(socket: tmuxSocket, client: tmuxClient, pane: tmuxPane) {
                    print("[DevIsland] tmux switch failed for pane=\(tmuxPane)")
                }
            }
            if let completion {
                DispatchQueue.main.async {
                    completion()
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
        case "cmux":
            return "cmux"
        case "wezterm", "wez term", "wezterm.app":
            return "WezTerm"
        case "vscode", "code", "visual studio code":
            return "VSCode"
        case "claudedesktop", "claude desktop":
            return "ClaudeDesktop"
        case "codexdesktop", "codex desktop":
            return "CodexDesktop"
        default:
            return nil
        }
    }

    static func iTermManagerNavigationInputs(managerTitle: String) -> [String] {
        [
            "(ASCII character 17)",
            "\"/\"",
            appleScriptLiteral(managerTitle),
            "(ASCII character 13)"
        ]
    }

    private static func runITermManagerNavigation(managerTitle: String) {
        let inputs = iTermManagerNavigationInputs(managerTitle: managerTitle)
        let delays: [TimeInterval] = [0.2, 0.3, 0.1, 0.2]

        for (index, input) in inputs.enumerated() {
            let delay = index < delays.count ? delays[index] : 0.2
            Thread.sleep(forTimeInterval: delay)
            let (_, error) = executeAppleScript("""
            tell application "iTerm"
                tell current session of current window
                    write text \(input) newline false
                end tell
            end tell
            """)
            if let error {
                print("[DevIsland] iTerm manager navigation AppleScript error: \(error)")
                return
            }
        }
    }

    private static func sendToTTY(_ text: String, tty: String) {
        let path = tty.hasPrefix("/") ? tty : "/dev/\(tty)"
        guard let data = text.data(using: .utf8) else { return }
        let fd = Darwin.open(path, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(fd, ptr.baseAddress, ptr.count)
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
                  repeat with aWindow in windows
                    if (id of aWindow as text) is wantedWindowIdText then
                      set wantedTab to tab (wantedTabIndexText as integer) of aWindow
                      set selected of wantedTab to true
                      set index of aWindow to 1
                      activate
                      return
                    end if
                  end repeat
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
        case "cmux":
            if (windowId ?? "").isEmpty {
                return "tell application \"cmux\" to activate"
            }
            return """
            tell application "cmux"
              activate
              set wantedTabId to \(windowIdLiteral)
              set wantedTermId to \(tabIndexLiteral)
              repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                  if (id of aTab as text) is wantedTabId then
                    activate window aWindow
                    select tab aTab
                    if wantedTermId is not "" then
                      repeat with aTerm in terminals of aTab
                        if (id of aTerm as text) is wantedTermId then
                          focus aTerm
                          -- cmux can report the tab selected before the terminal panel accepts key focus.
                          delay \(cmuxFocusSettleDelay)
                          activate window aWindow
                          activate
                          return
                        end if
                      end repeat
                    end if
                    return
                  end if
                end repeat
              end repeat
            end tell
            """
        case "VSCode":
            return "tell application id \"com.microsoft.VSCode\" to activate"
        case "ClaudeDesktop":
            return "tell application id \"com.anthropic.claudefordesktop\" to activate"
        case "CodexDesktop":
            return "tell application id \"com.openai.codex\" to activate"
        default:
            return "tell application \"\(appName)\" to activate"
        }
    }

    /// 세션을 새로 열 수 있는 터미널 앱 목록 (Launch Services는 느리므로 최초 1회만 계산)
    /// VSCode·ClaudeDesktop·CodexDesktop은 세션 포커스용으로만 쓰이므로 제외
    private static let nonTerminalBundleIds: Set<String> = [
        "com.microsoft.VSCode",
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
    ]
    static let installedTerminals: [(name: String, bundleId: String)] = {
        candidates.filter {
            !nonTerminalBundleIds.contains($0.bundleId) &&
            (!NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty
                || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil)
        }.map { (name: $0.name, bundleId: $0.bundleId) }
    }()

    private static func isOpenableTerminal(_ name: String) -> Bool {
        guard let bundleId = candidates.first(where: { $0.name == name })?.bundleId else { return true }
        return !nonTerminalBundleIds.contains(bundleId)
    }

    /// preferred → sessionTerminal → 설치된 첫 번째 순으로 자동 선택한 터미널 이름 반환
    /// 비터미널 앱(VSCode·ClaudeDesktop)으로 저장된 preference는 무시
    static func resolvedTerminalName(preferred: String?, sessionTerminal: String?) -> String? {
        if let p = normalizedAppName(preferred), isOpenableTerminal(p) { return p }
        if let s = normalizedAppName(sessionTerminal), isOpenableTerminal(s) { return s }
        return installedTerminals.first?.name
    }

    /// 새 창/탭을 열고 command를 실행한다.
    /// appName: normalizedAppName() 결과 또는 nil (설치된 첫 번째 터미널 자동 선택)
    static func openNewWindow(appName: String?, command: String) {
        let target = appName.flatMap { name in
            candidates.first { $0.name == name }
        } ?? candidates.first(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.1).isEmpty
                || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) != nil
        })

        guard let target else { return }

        let name = target.name
        let cmdLiteral = appleScriptLiteral(command)

        DispatchQueue.global(qos: .userInitiated).async {
            switch name {
            case "iTerm":
                let script = """
                tell application "iTerm"
                  activate
                  set newWindow to (create window with default profile)
                  tell current session of newWindow
                    write text \(cmdLiteral)
                  end tell
                end tell
                """
                let (_, err) = executeAppleScript(script)
                if let err { print("[DevIsland] openNewWindow iTerm error: \(err)") }

            case "Terminal":
                let script = """
                tell application "Terminal"
                  activate
                  do script \(cmdLiteral)
                end tell
                """
                let (_, err) = executeAppleScript(script)
                if let err { print("[DevIsland] openNewWindow Terminal error: \(err)") }

            case "Ghostty":
                // --initial-command: 새 창 셸에 명령을 타이핑한 것처럼 전달 (&&도 그대로 동작).
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleId) {
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.arguments = ["--initial-command=\(command)"]
                    NSWorkspace.shared.openApplication(at: url, configuration: cfg)
                }

            case "Warp":
                // Warp URL scheme: warp://action/new_tab?command=<encoded>
                if let encoded = command.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: "warp://action/new_tab?command=\(encoded)") {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }

            case "cmux":
                let cmuxScript = """
                tell application "cmux"
                  activate
                  set newTab to new tab in front window
                  set newTerm to first terminal of newTab
                  input text \(cmdLiteral) to newTerm
                  input text (ASCII character 13) to newTerm
                end tell
                """
                let (_, cmuxErr) = executeAppleScript(cmuxScript)
                if let cmuxErr { print("[DevIsland] openNewWindow cmux error: \(cmuxErr)") }

            case "WezTerm":
                // NSWorkspace.openApplication ignores arguments when WezTerm is already running.
                // Resolve the CLI from the app bundle and run it directly.
                if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleId) {
                    let cli = wezTermCLIURL(for: appUrl)
                    let target = wezTermActiveWindowTarget(cli: cli)
                    let ok: Bool
                    if let target {
                        ok = launchProcess(
                            executable: cli,
                            arguments: wezTermSpawnTabArguments(command: command, windowId: target.windowId),
                            environment: target.environment
                        )
                    } else {
                        ok = launchProcess(
                            executable: cli,
                            arguments: wezTermStartNewTabArguments(command: command),
                            environment: wezTermPreferredSocketEnvironment()
                        )
                    }
                    if !ok {
                        print("[DevIsland] openNewWindow WezTerm error: \(cli.path)")
                    }
                }

            default:
                break
            }
        }
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
