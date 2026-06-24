import Foundation

enum BridgeHookProvider: CaseIterable {
    case claude, codex, gemini

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    func settingsURL(homeDirectory: URL) -> URL {
        switch self {
        case .claude: return homeDirectory.appendingPathComponent(".claude/settings.json")
        case .codex: return homeDirectory.appendingPathComponent(".codex/hooks.json")
        case .gemini: return homeDirectory.appendingPathComponent(".gemini/settings.json")
        }
    }
}

struct BridgeHookStatus {
    let provider: BridgeHookProvider
    let settingsFileExists: Bool
    let isInstalled: Bool
}

/// Read-only diagnostic checks for the DevIsland bridge installation.
/// All filesystem access is synchronous and must be called off the main thread.
enum BridgeHealthDetector {
    static let bridgeScriptURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DevIsland/devisland-bridge.sh")

    static var isBridgeScriptInstalled: Bool {
        FileManager.default.fileExists(atPath: bridgeScriptURL.path)
    }

    /// Returns the installation status for a single provider.
    /// Detection mirrors install-bridge.sh: the settings file must contain "devisland-bridge.sh".
    static func hookStatus(
        for provider: BridgeHookProvider,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> BridgeHookStatus {
        let url = provider.settingsURL(homeDirectory: homeDirectory)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let installed: Bool
        if exists, let contents = try? String(contentsOf: url, encoding: .utf8) {
            installed = contents.contains("devisland-bridge.sh")
        } else {
            installed = false
        }
        return BridgeHookStatus(provider: provider, settingsFileExists: exists, isInstalled: installed)
    }

    static func allHookStatuses(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [BridgeHookStatus] {
        BridgeHookProvider.allCases.map { hookStatus(for: $0, homeDirectory: homeDirectory) }
    }

    /// Returns the last N lines of the Python bridge log. Empty when the log is absent.
    static func logTail(maxLines: Int = 20) -> [String] {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DevIsland/bridge.log")
        guard let fh = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        let readSize: UInt64 = 32_768
        let offset = fileSize > readSize ? fileSize - readSize : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(),
              let tail = String(data: data, encoding: .utf8) else { return [] }
        let lines = tail.components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(lines.suffix(maxLines))
    }
}
