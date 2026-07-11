import AppKit
import Darwin

extension TerminalFocuser {
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

    static func wezTermPaneTargetByID(cli: URL, paneId: String) -> (tty: String, environment: [String: String]?)? {
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

    static func wezTermPaneTarget(cli: URL, tty: String) -> (paneId: String, environment: [String: String]?)? {
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

    static func wezTermActiveWindowTarget(cli: URL) -> (windowId: String, environment: [String: String]?)? {
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
}
