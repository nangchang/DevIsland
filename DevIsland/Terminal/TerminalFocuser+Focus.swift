import AppKit
import Darwin
import os

extension TerminalFocuser {
    static func focusTerminal(
        _ terminal: TerminalContext = TerminalContext(),
        title: String? = nil,
        workspaceRoot: String? = nil,
        aoeSessionFocusMode: AoESessionFocusMode = AppSettings.defaults.aoeSessionFocusMode,
        completion: (() -> Void)? = nil
    ) {
        // TerminalContext는 빈 문자열을 "값 없음"으로 쓰므로 기존 옵셔널 기반 포커스 로직에 그대로 매핑한다.
        let appName: String? = terminal.app.isEmpty ? nil : terminal.app
        let tty: String? = terminal.tty.isEmpty ? nil : terminal.tty
        let windowId: String? = terminal.windowId.isEmpty ? nil : terminal.windowId
        let tabIndex: String? = terminal.tabIndex.isEmpty ? nil : terminal.tabIndex
        let tmuxPane: String? = terminal.tmuxPane.isEmpty ? nil : terminal.tmuxPane
        let tmuxSocket: String? = terminal.tmuxSocket.isEmpty ? nil : terminal.tmuxSocket
        let tmuxClient: String? = terminal.tmuxClient.isEmpty ? nil : terminal.tmuxClient
        let managerSessionTitle: String? = terminal.managerSessionTitle.isEmpty ? nil : terminal.managerSessionTitle

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
                    Log.terminal.error("open VS Code failed for path: \(path, privacy: .private)")
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
                            Log.terminal.debug("WezTerm tmux switch: client=\(client, privacy: .private) pane=\(tmuxPane, privacy: .private)")
                            if !switchTmuxClient(socket: tmuxSocket, client: client, pane: tmuxPane) {
                                Log.terminal.error("WezTerm tmux switch-client failed pane=\(tmuxPane, privacy: .private)")
                            }
                        } else {
                            // No client attached (e.g. AoE fully detached sessions).
                            // The windowId pane (WEZTERM_PANE) is the tool's own TUI pane which already
                            // shows the agent output — activating it is sufficient; no new pane needed.
                            Log.terminal.debug("WezTerm: no tmux client for pane=\(tmuxPane, privacy: .private), relying on windowId pane activation")
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
            } else if name == "Orca" {
                // Focus the specific terminal via the Orca CLI, then raise the app.
                // windowId carries ORCA_TERMINAL_HANDLE (set by detect_orca in the bridge).
                let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: match.bundleId)
                if let windowId, !windowId.isEmpty, let appUrl {
                    let cli = orcaCLIURL(for: appUrl)
                    if !runProcess(executable: cli, arguments: ["terminal", "switch", "--terminal", windowId]) {
                        Log.terminal.error("terminal focus Orca error: switch failed for \(windowId, privacy: .private)")
                    }
                }
                if let appUrl {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.openApplication(at: appUrl, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            } else {
                let (_, error) = executeAppleScript(focusScript(appName: name, title: title, tty: tty, windowId: windowId, tabIndex: tabIndex))
                if let error {
                    Log.terminal.error("terminal focus AppleScript error: \(error, privacy: .private)")
                }
            }
            // Manager TUI session navigation (e.g. AoE "/" search)
            if aoeSessionFocusMode == .managerSearch,
               let managerTitle = managerSessionTitle,
               !managerTitle.isEmpty {
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
                Log.terminal.debug("tmux pane detected: \(tmuxPane, privacy: .private), switching client=\(tmuxClient ?? "nil", privacy: .private) socket=\(tmuxSocket ?? "nil", privacy: .private)")
                if !switchTmuxClient(socket: tmuxSocket, client: tmuxClient, pane: tmuxPane) {
                    Log.terminal.error("tmux switch failed for pane=\(tmuxPane, privacy: .private)")
                }
            }
            if let completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
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
                Log.terminal.error("iTerm manager navigation AppleScript error: \(error, privacy: .private)")
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
                      set selected tab of aWindow to wantedTab
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

    /// 새 창/탭을 열고 command를 실행한다.
    /// appName: normalizedAppName() 결과 또는 nil (설치된 첫 번째 터미널 자동 선택)
    /// workspaceRoot: 세션의 워크트리 경로 (Orca는 새 터미널을 만들 워크트리를 지정하는 데 사용)
    static func openNewWindow(appName: String?, command: String, workspaceRoot: String? = nil) {
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
                if let err { Log.terminal.error("openNewWindow iTerm error: \(err, privacy: .private)") }

            case "Terminal":
                let script = """
                tell application "Terminal"
                  activate
                  do script \(cmdLiteral)
                end tell
                """
                let (_, err) = executeAppleScript(script)
                if let err { Log.terminal.error("openNewWindow Terminal error: \(err, privacy: .private)") }

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
                if let cmuxErr { Log.terminal.error("openNewWindow cmux error: \(cmuxErr, privacy: .private)") }

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
                        Log.terminal.error("openNewWindow WezTerm error: \(cli.path, privacy: .private)")
                    }
                }

            case "Orca":
                // `--worktree active` resolves against the caller's cwd, which for DevIsland
                // itself is not the session's worktree — target the path explicitly instead.
                // `--focus` is required or the tab is created without switching to it.
                if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleId) {
                    let cli = orcaCLIURL(for: appUrl)
                    var args = ["terminal", "create"]
                    if let root = workspaceRoot, !root.isEmpty {
                        args += ["--worktree", "path:\(root)"]
                    }
                    args += ["--command", command, "--focus"]
                    if !launchProcess(executable: cli, arguments: args) {
                        Log.terminal.error("openNewWindow Orca error: \(cli.path, privacy: .private)")
                    }
                }

            default:
                break
            }
        }
    }
}
