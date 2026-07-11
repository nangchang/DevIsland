import AppKit
import os

extension TerminalFocuser {
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

    static func isValidTmuxPane(_ pane: String) -> Bool {
        pane.range(of: #"^%\d+$"#, options: .regularExpression) != nil
    }

    private static func isValidTmuxSocket(_ socket: String) -> Bool {
        socket.hasPrefix("/") && !socket.contains("\u{0}")
    }

    private static func isValidTmuxClient(_ client: String) -> Bool {
        !client.isEmpty && !client.contains("\u{0}")
    }

    static func currentTmuxPane(socket: String?, client: String?) -> String {
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
    static func switchTmuxClient(socket: String?, client: String?, pane: String) -> Bool {
        guard isValidTmuxPane(pane) else {
            Log.terminal.error("focusTerminal: invalid tmux pane format: \(pane, privacy: .private)")
            return false
        }

        let executable = tmuxExecutableURL()
        let targetSession = tmuxFormat(socket: socket, target: pane, format: "#{session_id}")
        let selectWindowSucceeded = runProcess(
            executable: executable,
            arguments: tmuxArguments(socket: socket, command: ["select-window", "-t", pane])
        )
        if !selectWindowSucceeded {
            Log.terminal.error("tmux select-window failed for pane=\(pane, privacy: .private) socket=\(socket ?? "nil", privacy: .private)")
        }

        let selectPaneSucceeded = runProcess(
            executable: executable,
            arguments: tmuxArguments(socket: socket, command: ["select-pane", "-t", pane])
        )
        if !selectPaneSucceeded {
            Log.terminal.error("tmux select-pane failed for pane=\(pane, privacy: .private) socket=\(socket ?? "nil", privacy: .private)")
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
            Log.terminal.error("tmux switch-client failed for pane=\(pane, privacy: .private) client=\(client ?? "nil", privacy: .private) target=\(targetSession.isEmpty ? pane : targetSession, privacy: .private) socket=\(socket ?? "nil", privacy: .private)")
        }

        return selectWindowSucceeded && selectPaneSucceeded && switchSucceeded
    }

    static func tmuxClientForTTY(socket: String?, tty: String) -> String? {
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
}
