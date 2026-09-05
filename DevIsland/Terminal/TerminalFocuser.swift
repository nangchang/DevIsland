import AppKit
import Darwin
import os

// 인스턴스 상태 없이 static 메서드만 제공하는 네임스페이스 — isSessionFrontmost가
// AppState의 @Sendable FrontmostCheck 기본값으로 쓰이므로 Sendable을 명시한다.
final class TerminalFocuser: Sendable {
    private static let tmuxCommandTimeout: TimeInterval = 1.0
    private static let appleScriptTimeout: TimeInterval = 1.5
    static let cmuxFocusSettleDelay = "0.05"

    static let candidates: [(bundleId: String, name: String)] = [
        ("com.cmuxterm.app",                "cmux"),
        ("com.mitchellh.ghostty",           "Ghostty"),
        ("com.googlecode.iterm2",           "iTerm"),
        ("dev.warp.Warp-Stable",            "Warp"),
        ("com.github.wez.wezterm",          "WezTerm"),
        ("com.apple.Terminal",              "Terminal"),
        ("com.microsoft.VSCode",            "VSCode"),
        ("com.anthropic.claudefordesktop",  "ClaudeDesktop"),
        ("com.openai.codex",               "CodexDesktop"),
        ("com.stablyai.orca",              "Orca"),
    ]

    @Sendable
    static func isSessionFrontmost(_ terminal: TerminalContext) -> Bool {
        // TerminalContext는 빈 문자열을 "값 없음"으로 쓰므로 기존 옵셔널 기반 판정 로직에 그대로 매핑한다.
        let appName: String? = terminal.app.isEmpty ? nil : terminal.app
        let tty: String? = terminal.tty.isEmpty ? nil : terminal.tty
        let windowId: String? = terminal.windowId.isEmpty ? nil : terminal.windowId
        let tabIndex: String? = terminal.tabIndex.isEmpty ? nil : terminal.tabIndex
        let tmuxPane: String? = terminal.tmuxPane.isEmpty ? nil : terminal.tmuxPane
        let tmuxSocket: String? = terminal.tmuxSocket.isEmpty ? nil : terminal.tmuxSocket
        let tmuxClient: String? = terminal.tmuxClient.isEmpty ? nil : terminal.tmuxClient

        let targetName = normalizedAppName(appName)
        let match = targetName.flatMap { name in
            candidates.first { $0.name == name }
        } ?? candidates.first(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty
        })
        Log.terminal.debug("isSessionFrontmost: appName=\(appName ?? "nil", privacy: .private) → targetName=\(targetName ?? "nil", privacy: .private) → match=\(match?.name ?? "none", privacy: .private)")
        guard let match else { return false }

        let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isActive = frontBundleId == match.bundleId
        Log.terminal.debug("isSessionFrontmost: \(match.name, privacy: .private) frontmost=\(frontBundleId ?? "nil", privacy: .public) expected=\(match.bundleId, privacy: .public) isActive=\(isActive, privacy: .public)")
        guard isActive else { return false }

        let (resultStr, error) = executeAppleScript(frontmostCheckScript(
            appName: match.name,
            tty: tty,
            windowId: windowId,
            tabIndex: tabIndex
        ))
        let passed = resultStr == "true" || resultStr.hasPrefix("true|")
        
        if let error = error {
            Log.terminal.error("isSessionFrontmost: AppleScript error for \(match.name, privacy: .private): \(error, privacy: .private)")
        }
        
        Log.terminal.debug("isSessionFrontmost: app=\(match.name, privacy: .private) tty=\(tty ?? "nil", privacy: .private) → \(passed ? "YES" : "NO", privacy: .public) (\(resultStr, privacy: .private))")
        guard passed else { return false }

        if let tmuxPane = tmuxPane, !tmuxPane.isEmpty {
            // tmux pane identity only makes sense after the terminal tab's outer TTY is frontmost.
            // Otherwise another tab attached to the same tmux server could make the pane check look valid.
            guard isValidTmuxPane(tmuxPane) else {
                Log.terminal.error("isSessionFrontmost: invalid tmux pane format: \(tmuxPane, privacy: .private)")
                return false
            }

            let currentPane = currentTmuxPane(socket: tmuxSocket, client: tmuxClient)
            guard !currentPane.isEmpty else {
                Log.terminal.debug("isSessionFrontmost: tmux pane unavailable for client=\(tmuxClient ?? "nil", privacy: .private) socket=\(tmuxSocket ?? "nil", privacy: .private)")
                return false
            }

            if currentPane == tmuxPane {
                return true
            } else {
                Log.terminal.debug("isSessionFrontmost: tmux pane mismatch (current=\(currentPane, privacy: .private) expected=\(tmuxPane, privacy: .private))")
                return false
            }
        }

        return true
    }

    static func executeAppleScript(_ source: String) -> (String, NSDictionary?) {
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
            Log.terminal.error("AppleScript timed out after \(appleScriptTimeout, privacy: .public)s")
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

    static func getProcessOutput(
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
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            terminateProcess(process, after: tmuxCommandTimeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            Log.terminal.error("Failed to run process: \(executable.path, privacy: .private) \(arguments.joined(separator: " "), privacy: .private), error: \(error, privacy: .private)")
            return ""
        }
    }

    static func runProcess(
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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            terminateProcess(process, after: tmuxCommandTimeout)
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            Log.terminal.error("Failed to run process: \(executable.path, privacy: .private) \(arguments.joined(separator: " "), privacy: .private), error: \(error, privacy: .private)")
            return false
        }
    }

    static func launchProcess(
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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return true
        } catch {
            Log.terminal.error("Failed to launch process: \(executable.path, privacy: .private) \(arguments.joined(separator: " "), privacy: .private), error: \(error, privacy: .private)")
            return false
        }
    }

    private static func terminateProcess(_ process: Process, after timeout: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                Log.terminal.error("tmux command timed out, terminating pid=\(process.processIdentifier, privacy: .public)")
                process.terminate()
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
        case "orca":
            return "Orca"
        default:
            return nil
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

    static func appleScriptLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
