import AppKit

enum BridgeInstaller {
    private static let sharedBridgePath = "Library/Application Support/DevIsland"
    private static let bridgeFileName = "devisland-bridge.sh"
    private static let bridgeHelperFileName = "devisland_bridge.py"
    private static let bridgeManifestFileName = "hook_events.json"

    /// 설치/제거 작업을 백그라운드에서 직렬로 실행한다. 동시 큐를 쓰면 여러
    /// 메뉴 액션이 같은 브리지 디렉토리·config 파일을 병렬로 변경해
    /// 파일이 서로의 존재 확인·복사·chmod 사이에 삭제/재생성될 수 있다.
    private static let installerQueue = DispatchQueue(label: "com.devisland.bridge-installer")

    private struct InstallPaths {
        let home: URL
        let bridgeDir: URL
        let destURL: URL
    }

    private enum BridgeInstallerError: LocalizedError {
        case missingBridgeScript
        case missingBridgeHelper
        case missingBridgeManifest

        var errorDescription: String? {
            switch self {
            case .missingBridgeScript:
                return L10n.shared.alertBundleNoScript
            case .missingBridgeHelper:
                return L10n.shared.alertBundleNoHelper
            case .missingBridgeManifest:
                return L10n.shared.alertBundleNoManifest
            }
        }
    }

    // MARK: Public entry points

    /// Claude Code, Codex CLI, Gemini CLI, Antigravity CLI 모두 설치
    static func installAll() {
        installerQueue.async {
            do {
                try installClaudeHooks()
                try installCodexHooks()
                try installGeminiHooks()
                try installAntigravityHooks()
                let l = L10n.shared
                showAlert(title: l.alertAllInstalled, message: l.alertAllInstalledMsg, isError: false)
            } catch {
                showAlert(title: L10n.shared.alertInstallFailed, message: error.localizedDescription, isError: true)
            }
        }
    }

    /// Claude Code (~/.claude/settings.json)
    static func install() {
        installerQueue.async {
            do {
                try installClaudeHooks()
                let l = L10n.shared
                showAlert(title: l.alertClaudeInstalled, message: l.alertClaudeRestartMsg, isError: false)
            } catch {
                showAlert(title: L10n.shared.alertClaudeInstallFailed, message: error.localizedDescription, isError: true)
            }
        }
    }

    /// Codex CLI (~/.codex/hooks.json + config.toml)
    static func installCodex() {
        installerQueue.async {
            do {
                try installCodexHooks()
                let l = L10n.shared
                showAlert(title: l.alertCodexInstalled, message: l.alertCodexRestartMsg, isError: false)
            } catch {
                showAlert(title: L10n.shared.alertCodexInstallFailed, message: error.localizedDescription, isError: true)
            }
        }
    }

    /// Gemini CLI (~/.gemini/settings.json)
    static func installGemini() {
        installerQueue.async {
            do {
                try installGeminiHooks()
                let l = L10n.shared
                showAlert(title: l.alertGeminiInstalled, message: l.alertGeminiRestartMsg, isError: false)
            } catch {
                showAlert(title: L10n.shared.alertGeminiInstallFailed, message: error.localizedDescription, isError: true)
            }
        }
    }

    /// Antigravity CLI (~/.gemini/config/hooks.json)
    static func installAntigravity() {
        installerQueue.async {
            do {
                try installAntigravityHooks()
                let l = L10n.shared
                showAlert(title: l.alertAntigravityInstalled, message: l.alertAntigravityRestartMsg, isError: false)
            } catch {
                showAlert(title: L10n.shared.alertAntigravityInstallFailed, message: error.localizedDescription, isError: true)
            }
        }
    }

    private static func installClaudeHooks() throws {
        let bridgeURL = try bridgeScriptURL()
        let helperURL = try bridgeHelperURL()
        let manifestURL = try bridgeManifestURL()
        let paths = installPaths()
        let settingsURL = paths.home.appendingPathComponent(".claude/settings.json")

        try prepare(bridgeURL: bridgeURL, helperURL: helperURL, manifestURL: manifestURL, destURL: paths.destURL, hooksDir: paths.bridgeDir)
        try patchClaudeSettings(at: settingsURL, bridgePath: paths.destURL.path)
    }

    private static func installCodexHooks() throws {
        let bridgeURL = try bridgeScriptURL()
        let helperURL = try bridgeHelperURL()
        let manifestURL = try bridgeManifestURL()
        let paths = installPaths()
        let codexHooksURL  = paths.home.appendingPathComponent(".codex/hooks.json")
        let codexConfigURL = paths.home.appendingPathComponent(".codex/config.toml")

        try prepare(bridgeURL: bridgeURL, helperURL: helperURL, manifestURL: manifestURL, destURL: paths.destURL, hooksDir: paths.bridgeDir)
        try patchCodexHooks(at: codexHooksURL, bridgePath: paths.destURL.path)
        try ensureCodexFeatureFlag(at: codexConfigURL)
    }

    private static func installGeminiHooks() throws {
        let bridgeURL = try bridgeScriptURL()
        let helperURL = try bridgeHelperURL()
        let manifestURL = try bridgeManifestURL()
        let paths = installPaths()
        let geminiSettingsURL = paths.home.appendingPathComponent(".gemini/settings.json")

        try prepare(bridgeURL: bridgeURL, helperURL: helperURL, manifestURL: manifestURL, destURL: paths.destURL, hooksDir: paths.bridgeDir)
        try patchGeminiSettings(at: geminiSettingsURL, bridgePath: paths.destURL.path)
    }

    private static func installAntigravityHooks() throws {
        let bridgeURL = try bridgeScriptURL()
        let helperURL = try bridgeHelperURL()
        let manifestURL = try bridgeManifestURL()
        let paths = installPaths()
        let antigravityHooksURL = paths.home.appendingPathComponent(".gemini/config/hooks.json")
        let legacyAntigravityHooksURL = paths.home.appendingPathComponent(".gemini/antigravity-cli/hooks.json")

        try prepare(bridgeURL: bridgeURL, helperURL: helperURL, manifestURL: manifestURL, destURL: paths.destURL, hooksDir: paths.bridgeDir)
        try patchAntigravityHooks(at: antigravityHooksURL, bridgePath: paths.destURL.path)
        if !sameHookFile(antigravityHooksURL, legacyAntigravityHooksURL) {
            try removeLegacyAntigravityHooks(at: legacyAntigravityHooksURL)
        }
    }

    // MARK: Shared helpers

    private static func installPaths() -> InstallPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bridgeDir = home.appendingPathComponent(sharedBridgePath)
        return InstallPaths(
            home: home,
            bridgeDir: bridgeDir,
            destURL: bridgeDir.appendingPathComponent(bridgeFileName)
        )
    }

    private static func bridgeScriptURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "devisland-bridge", withExtension: "sh") else {
            throw BridgeInstallerError.missingBridgeScript
        }
        return url
    }

    private static func bridgeHelperURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "devisland_bridge", withExtension: "py") else {
            throw BridgeInstallerError.missingBridgeHelper
        }
        return url
    }

    private static func bridgeManifestURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "hook_events", withExtension: "json") else {
            throw BridgeInstallerError.missingBridgeManifest
        }
        return url
    }

    /// 브리지 스크립트와 Python helper를 bridgeDir에 복사하고 실행 권한을 부여한다.
    /// helper가 import 시점에 읽는 hook_events.json manifest도 함께 복사한다.
    private static func prepare(bridgeURL: URL, helperURL: URL, manifestURL: URL, destURL: URL, hooksDir bridgeDir: URL) throws {
        let fm = FileManager.default
        let helperDestURL = bridgeDir.appendingPathComponent(bridgeHelperFileName)
        let manifestDestURL = bridgeDir.appendingPathComponent(bridgeManifestFileName)
        try fm.createDirectory(at: bridgeDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
        if fm.fileExists(atPath: helperDestURL.path) { try fm.removeItem(at: helperDestURL) }
        if fm.fileExists(atPath: manifestDestURL.path) { try fm.removeItem(at: manifestDestURL) }
        try fm.copyItem(at: bridgeURL, to: destURL)
        try fm.copyItem(at: helperURL, to: helperDestURL)
        try fm.copyItem(at: manifestURL, to: manifestDestURL)
        try fm.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: destURL.path)
        try fm.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: helperDestURL.path)
    }

    // MARK: Claude Code settings patch

    private static func patchClaudeSettings(at url: URL, bridgePath: String) throws {
        let fm = FileManager.default
        let bridgeCommand = "\"\(bridgePath)\" --source claude"
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "BridgeInstaller", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: L10n.shared.alertBadJSON])
            }
            settings = parsed
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        let approvalConfig: [String: Any] = [
            "hooks": [["type": "command", "command": bridgeCommand, "timeout": 86400]]
        ]
        let lifecycleConfig: [String: Any] = [
            "hooks": [["type": "command", "command": bridgeCommand]]
        ]
        let entries: [(String, [String: Any])] = [
            ("SessionStart",      lifecycleConfig),
            ("SessionEnd",        lifecycleConfig),
            ("Notification",      lifecycleConfig),
            ("Stop",              lifecycleConfig),
            ("PreToolUse",        lifecycleConfig),
            ("PostToolUse",       lifecycleConfig),
            ("PostToolUseFailure", lifecycleConfig),
            ("UserPromptSubmit",  lifecycleConfig),
            ("Elicitation",       lifecycleConfig),
            ("PermissionRequest", approvalConfig),
        ]
        let retiredEntries = [
            "SubagentStop", "PreCompact", "StopFailure"
        ]

        for (key, config) in entries {
            var list = removingBridgeHooksFrom(list: (hooks[key] as? [[String: Any]]) ?? [])
            list.append(config)
            hooks[key] = list
        }
        for key in retiredEntries {
            let list = removingBridgeHooksFrom(list: (hooks[key] as? [[String: Any]]) ?? [])
            if list.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = list }
        }

        settings["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    // MARK: Codex CLI hooks patch

    private static func patchCodexHooks(at url: URL, bridgePath: String) throws {
        let fm = FileManager.default
        let bridgeCommand = "\"\(bridgePath)\" --source codex"
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var data: [String: Any] = [:]
        if fm.fileExists(atPath: url.path),
           let raw = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            data = parsed
        }

        var hooks = (data["hooks"] as? [String: Any]) ?? [:]
        
        // 공식 JSON 규격: {"EventName": [{"matcher": "*", "hooks": [{"type": "command", "command": "..."}]}]}
        let events = ["SessionStart", "PreToolUse", "PostToolUse", "Stop", "PermissionRequest"]
        for event in events {
            var eventConfigs = (hooks[event] as? [[String: Any]]) ?? []
            
            // PermissionRequest만 실제 승인 대기 이벤트이므로 타임아웃을 길게 설정함 (86400초 = 24시간)
            var hCmd: [String: Any] = ["type": "command", "command": bridgeCommand]
            if event == "PermissionRequest" {
                hCmd["timeout"] = 86400
            }

            var found = false
            for i in 0..<eventConfigs.count {
                var config = eventConfigs[i]
                if (config["matcher"] as? String) == "*" {
                    var subHooks = (config["hooks"] as? [[String: Any]]) ?? []
                    subHooks.removeAll { ($0["command"] as? String ?? "").contains(bridgeFileName) }
                    subHooks.append(hCmd)
                    config["hooks"] = subHooks
                    eventConfigs[i] = config
                    found = true
                    break
                }
            }

            if !found {
                eventConfigs.append([
                    "matcher": "*",
                    "hooks": [hCmd]
                ])
            }
            hooks[event] = eventConfigs
        }
        for event in ["SessionEnd"] {
            let cleaned = removingBridgeHooksFrom(list: (hooks[event] as? [[String: Any]]) ?? [])
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }
        
        data["hooks"] = hooks

        let out = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    private static func ensureCodexFeatureFlag(at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var lines: [String] = []
        if fm.fileExists(atPath: url.path) {
            let content = try String(contentsOf: url, encoding: .utf8)
            lines = content.components(separatedBy: .newlines)
        }

        // 기존 [hooks] 또는 [[hooks.]] 관련 설정 제거 및 hooks feature 활성화 (hooks.json으로 일원화)
        var newLines: [String] = []
        var skip = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[hooks]") || trimmed.hasPrefix("[[hooks.") {
                skip = true
                continue
            }
            if skip && trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[hooks.") {
                skip = false
            }
            if !skip {
                newLines.append(line)
            }
        }

        if let featuresIndex = newLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            var featuresEnd = featuresIndex + 1
            while featuresEnd < newLines.count {
                if newLines[featuresEnd].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                    break
                }
                featuresEnd += 1
            }

            var foundHooks = false
            var featureLines: [String] = []
            for line in newLines[(featuresIndex + 1)..<featuresEnd] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let key = trimmed.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
                switch key {
                case "hooks":
                    featureLines.append("hooks = true")
                    foundHooks = true
                case "codex_hooks":
                    continue
                default:
                    featureLines.append(line)
                }
            }
            if !foundHooks {
                featureLines.append("hooks = true")
            }
            newLines.replaceSubrange((featuresIndex + 1)..<featuresEnd, with: featureLines)
        } else {
            newLines.append("\n[features]\nhooks = true\n")
        }

        let out = newLines.joined(separator: "\n")
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Gemini CLI settings patch

    private static func patchGeminiSettings(at url: URL, bridgePath: String) throws {
        let fm = FileManager.default
        let bridgeCommand = "\"\(bridgePath)\" --source gemini"
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var data: [String: Any] = [:]
        if fm.fileExists(atPath: url.path),
           let raw = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            data = parsed
        }

        // Gemini CLI: hooks는 { "EventName": [ { "matcher": "*", "hooks": [...] } ] } 형태
        var hooks = (data["hooks"] as? [String: Any]) ?? [:]

        for event in ["BeforeTool", "SessionStart", "SessionEnd", "AfterAgent", "Notification"] {
            var eventConfigs = (hooks[event] as? [[String: Any]]) ?? []
            
            var found = false
            for i in 0..<eventConfigs.count {
                var config = eventConfigs[i]
                if (config["matcher"] as? String) == "*" {
                    var subHooks = (config["hooks"] as? [[String: Any]]) ?? []
                    subHooks.removeAll { ($0["command"] as? String ?? "").contains(bridgeFileName) }
                    var hookEntry: [String: Any] = ["type": "command", "command": bridgeCommand]
                    if event == "BeforeTool" {
                        hookEntry["timeout"] = 86400000
                    }
                    subHooks.append(hookEntry)
                    config["hooks"] = subHooks
                    eventConfigs[i] = config
                    found = true
                    break
                }
            }
            
            if !found {
                var hookEntry: [String: Any] = ["type": "command", "command": bridgeCommand]
                if event == "BeforeTool" {
                    hookEntry["timeout"] = 86400000
                }
                eventConfigs.append([
                    "matcher": "*",
                    "hooks": [hookEntry]
                ])
            }
            hooks[event] = eventConfigs
        }
        for event in ["AfterTool", "BeforeAgent", "BeforeModel", "BeforeToolSelection", "AfterModel", "PreCompress"] {
            let cleaned = removingBridgeHooksFrom(list: (hooks[event] as? [[String: Any]]) ?? [])
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }

        data["hooks"] = hooks

        let out = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    // MARK: Uninstall entry points

    static func uninstallAll() {
        installerQueue.async {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var errors: [String] = []
            let targets: [(URL, String)] = [
                (home.appendingPathComponent(".claude/settings.json"), "Claude Code"),
                (home.appendingPathComponent(".codex/hooks.json"),     "Codex CLI"),
                (home.appendingPathComponent(".gemini/settings.json"), "Gemini CLI"),
            ]
            for (url, name) in targets {
                do {
                    try removeHooks(at: url, fileName: url.lastPathComponent)
                } catch {
                    errors.append("\(name): \(error.localizedDescription)")
                }
            }
            do {
                try removeAntigravityHooks(at: home.appendingPathComponent(".gemini/config/hooks.json"))
                try removeLegacyAntigravityHooks(at: home.appendingPathComponent(".gemini/antigravity-cli/hooks.json"))
            } catch {
                errors.append("Antigravity CLI: \(error.localizedDescription)")
            }
            if errors.isEmpty {
                let l = L10n.shared
                showAlert(title: l.alertAllRemoved, message: l.alertAllRemovedMsg, isError: false)
            } else {
                showAlert(title: L10n.shared.alertSomeRemoveFailed, message: errors.joined(separator: "\n"), isError: true)
            }
        }
    }

    static func uninstall() {
        installerQueue.async {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
            do {
                try removeHooks(at: url, fileName: url.lastPathComponent)
                let l = L10n.shared
                showAlert(title: l.alertClaudeRemoved, message: l.alertClaudeHooksRemoved, isError: false)
            } catch {
                showAlert(title: L10n.shared.alertClaudeRemoveFailed, message: error.localizedDescription, isError: true)
            }
        }
    }

    static func uninstallCodex() {
        installerQueue.async {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
            do {
                try removeHooks(at: url, fileName: url.lastPathComponent)
                let l = L10n.shared
                showAlert(title: l.alertCodexRemoved, message: l.alertCodexHooksRemoved, isError: false)
            } catch {
                showAlert(title: L10n.shared.alertCodexRemoveFailed, message: error.localizedDescription, isError: true)
            }
        }
    }

    static func uninstallGemini() {
        installerQueue.async {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/settings.json")
            do {
                try removeHooks(at: url, fileName: url.lastPathComponent)
                let l = L10n.shared
                showAlert(title: l.alertGeminiRemoved, message: l.alertGeminiHooksRemoved, isError: false)
            } catch {
                showAlert(title: L10n.shared.alertGeminiRemoveFailed, message: error.localizedDescription, isError: true)
            }
        }
    }

    static func uninstallAntigravity() {
        installerQueue.async {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let url = home.appendingPathComponent(".gemini/config/hooks.json")
            let legacyURL = home.appendingPathComponent(".gemini/antigravity-cli/hooks.json")
            do {
                try removeAntigravityHooks(at: url)
                try removeLegacyAntigravityHooks(at: legacyURL)
                let l = L10n.shared
                showAlert(title: l.alertAntigravityRemoved, message: l.alertAntigravityHooksRemoved, isError: false)
            } catch {
                showAlert(title: L10n.shared.alertAntigravityRemoveFailed, message: error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: Uninstall helpers

    private static func removeHooks(at url: URL, fileName: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let raw = try Data(contentsOf: url)
        guard var json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw NSError(domain: "BridgeInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.shared.alertBadFile(fileName)])
        }
        var hooks = (json["hooks"] as? [String: Any]) ?? [:]
        for key in Array(hooks.keys) {
            let cleaned = removingBridgeHooksFrom(list: (hooks[key] as? [[String: Any]]) ?? [])
            if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
        }
        json["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    private static func removingBridgeHooksFrom(list: [[String: Any]]) -> [[String: Any]] {
        list.compactMap { entry in
            let subHooks = (entry["hooks"] as? [[String: Any]] ?? [])
                .filter { !($0["command"] as? String ?? "").contains(bridgeFileName) }
            guard !subHooks.isEmpty else { return nil }
            var updated = entry
            updated["hooks"] = subHooks
            return updated
        }
    }

    private static func patchAntigravityHooks(at url: URL, bridgePath: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var data: [String: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            let raw = try Data(contentsOf: url)
            guard let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw NSError(domain: "BridgeInstaller", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: L10n.shared.alertBadFile("hooks.json")])
            }
            data = parsed
        }

        var devisland = (data["devisland"] as? [String: Any]) ?? [:]
        devisland["enabled"] = true

        // 1. Matcher-based events
        for event in ["PreToolUse", "PostToolUse"] {
            let bridgeCommand = "\"\(bridgePath)\" --source antigravity --event \(event)"
            var eventConfigs = (devisland[event] as? [[String: Any]]) ?? []
            var found = false
            for i in 0..<eventConfigs.count {
                var config = eventConfigs[i]
                if (config["matcher"] as? String) == "*" {
                    var subHooks = (config["hooks"] as? [[String: Any]]) ?? []
                    subHooks.removeAll { isBridgeCommand($0["command"] as? String ?? "") }
                    var hookEntry: [String: Any] = ["type": "command", "command": bridgeCommand]
                    if event == "PreToolUse" {
                        hookEntry["timeout"] = 86400
                    }
                    subHooks.append(hookEntry)
                    config["hooks"] = subHooks
                    eventConfigs[i] = config
                    found = true
                    break
                }
            }
            if !found {
                var hookEntry: [String: Any] = ["type": "command", "command": bridgeCommand]
                if event == "PreToolUse" {
                    hookEntry["timeout"] = 86400
                }
                eventConfigs.append([
                    "matcher": "*",
                    "hooks": [hookEntry]
                ])
            }
            devisland[event] = eventConfigs
        }

        // 2. Direct list events
        for event in ["PreInvocation", "PostInvocation", "Stop"] {
            let bridgeCommand = "\"\(bridgePath)\" --source antigravity --event \(event)"
            var eventConfigs = (devisland[event] as? [[String: Any]]) ?? []
            eventConfigs.removeAll { isBridgeCommand($0["command"] as? String ?? "") }
            eventConfigs.append(["type": "command", "command": bridgeCommand])
            devisland[event] = eventConfigs
        }

        data["devisland"] = devisland

        let out = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    private static func removeAntigravityHooks(at url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let raw = try Data(contentsOf: url)
        guard var json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw NSError(domain: "BridgeInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.shared.alertBadFile("hooks.json")])
        }
        json.removeValue(forKey: "devisland")
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    private static func removeLegacyAntigravityHooks(at url: URL) throws {
        do {
            try removeAntigravityHooks(at: url)
        } catch {
            print("[DevIsland] Failed to remove legacy Antigravity hooks: \(error)")
        }
        let fm = FileManager.default
        let antigravityDir = url.deletingLastPathComponent()
        let spaceFreeBridgeURL = antigravityDir.appendingPathComponent("devisland-bridge-antigravity.sh")
        let spaceFreeHelperURL = antigravityDir.appendingPathComponent(bridgeHelperFileName)
        let spaceFreeManifestURL = antigravityDir.appendingPathComponent(bridgeManifestFileName)

        if fm.fileExists(atPath: spaceFreeBridgeURL.path) { try fm.removeItem(at: spaceFreeBridgeURL) }
        if fm.fileExists(atPath: spaceFreeHelperURL.path) { try fm.removeItem(at: spaceFreeHelperURL) }
        if fm.fileExists(atPath: spaceFreeManifestURL.path) { try fm.removeItem(at: spaceFreeManifestURL) }
    }

    private static func isBridgeCommand(_ command: String) -> Bool {
        command.contains(bridgeFileName) || command.contains("devisland-bridge-antigravity.sh")
    }

    private static func sameHookFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: lhs.path), fm.fileExists(atPath: rhs.path) else { return false }
        return lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
    }

    // MARK: Alert helper

    private static func showAlert(title: String, message: String, isError: Bool) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = isError ? .critical : .informational
            alert.addButton(withTitle: L10n.shared.alertOK)
            alert.runModal()
        }
    }
}
