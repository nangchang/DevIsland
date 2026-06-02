import SwiftUI

@main
struct DevIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var sessionStore = AppState.shared.sessionStore
    @ObservedObject private var caffeine = AppState.shared.caffeineCoordinator

    @MainActor
    init() {
        _ = SettingsStore.shared
        CESPPackStore.shared.reload(settings: SettingsStore.shared.settings)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: Self.statusBarIcon(active: caffeine.isHoldingAssertion))
                if sessionStore.pendingCount > 0 {
                    Text("\(sessionStore.pendingCount)")
                        .font(.system(size: 10, weight: .bold))
                }
            }
        }
    }

    /// caffeine 활성 시 파란색(Red Bull) 틴트, 비활성 시 시스템 기본 template.
    private static func statusBarIcon(active: Bool) -> NSImage {
        let base = NSImage(named: "StatusBarIcon") ?? NSImage()
        guard active else { return base }
        return tinted(base, with: NSColor(red: 0.0, green: 0.38, blue: 0.93, alpha: 1.0))
    }

    private static func tinted(_ source: NSImage, with color: NSColor) -> NSImage {
        let size = source.size
        let result = NSImage(size: size)
        result.lockFocus()
        color.set()
        NSRect(origin: .zero, size: size).fill()
        source.draw(at: .zero, from: NSRect(origin: .zero, size: size),
                    operation: .destinationIn, fraction: 1.0)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
}

// MARK: - Menu Bar Menu

struct MenuBarMenu: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject private var sessionStore = AppState.shared.sessionStore
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updateChecker = UpdateChecker.shared

    static let versionString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "DevIsland v\(version) (\(build))"
    }()

    var body: some View {
        let l = l10n
        if sessionStore.pendingItems.isEmpty {
            Text(l.menuNoPending)
                .foregroundStyle(.secondary)
        } else {
            Text("\(l.menuPending): \(sessionStore.pendingItems.count)")
                .font(.headline)
            ForEach(sessionStore.pendingItems) { item in
                HStack(spacing: 6) {
                    Image(systemName: toolInfo(for: item.toolName).icon)
                        .foregroundStyle(toolInfo(for: item.toolName).color)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.toolName.isEmpty ? l.notchUnknown : item.toolName)
                            .font(.system(size: 12, weight: .medium))
                        Text(item.message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Divider()
        }

        Button(l.menuFocusTerminal) { state.focusTerminal() }
            .disabled(sessionStore.pendingItems.isEmpty && sessionStore.activeSessions.isEmpty)

        Button(l.menuApprove) { state.approve() }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(!state.hasResponseHandler)
        Button(l.menuDeny) { state.deny() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!state.hasResponseHandler)

        Divider()

        CaffeineMenuItem()

        Divider()

        Button(l.menuSettings) {
            AppWindowRouter.showSettings()
        }
        Button(l.menuApprovalRules) {
            AppWindowRouter.showApprovalRules()
        }
        Button(l.menuReplayLog) {
            AppWindowRouter.showReplayLog()
        }
        Button(l.menuSessionHistory) {
            AppWindowRouter.showSessionHistory()
        }
        Button(l.menuPTYTranscript) {
            AppWindowRouter.showPTYTranscript()
        }

        Divider()

        Menu(l.menuInstallHooks) {
            Button(l.menuInstallAll) {
                BridgeInstaller.installAll()
            }
            Divider()
            Button(l.menuInstallClaude) {
                BridgeInstaller.install()
            }
            Button(l.menuInstallCodex) {
                BridgeInstaller.installCodex()
            }
            Button(l.menuInstallGemini) {
                BridgeInstaller.installGemini()
            }
            Divider()
            Button(l.menuRemoveAll) {
                BridgeInstaller.uninstallAll()
            }
            Button(l.menuRemoveClaude) {
                BridgeInstaller.uninstall()
            }
            Button(l.menuRemoveCodex) {
                BridgeInstaller.uninstallCodex()
            }
            Button(l.menuRemoveGemini) {
                BridgeInstaller.uninstallGemini()
            }
        }

        if !GlobalShortcutManager.shared.hasAccessibilityPermission {
            Button(l.menuAccessibility) {
                GlobalShortcutManager.shared.requestAccessibilityPermission()
            }
        }

        Divider()

        if updateChecker.hasUpdate, let release = updateChecker.latestRelease {
            Button(l.menuUpdateAvailable(release.version)) {
                updateChecker.installUpdate()
            }
        } else {
            Button(updateChecker.isChecking ? "…" : l.menuCheckForUpdates) {
                updateChecker.checkManually()
            }
            .disabled(updateChecker.isChecking || updateChecker.isUpdating)
        }

        Text(MenuBarMenu.versionString)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)

        Button(l.menuQuit) {
            NSApplication.shared.terminate(nil)
        }
    }

}

// MARK: - Bridge Installer

enum BridgeInstaller {
    private static let sharedBridgePath = "Library/Application Support/DevIsland"
    private static let bridgeFileName = "devisland-bridge.sh"
    private static let bridgeHelperFileName = "devisland_bridge.py"

    private struct InstallPaths {
        let home: URL
        let bridgeDir: URL
        let destURL: URL
    }

    private enum BridgeInstallerError: LocalizedError {
        case missingBridgeScript
        case missingBridgeHelper

        var errorDescription: String? {
            switch self {
            case .missingBridgeScript:
                return L10n.shared.alertBundleNoScript
            case .missingBridgeHelper:
                return L10n.shared.alertBundleNoHelper
            }
        }
    }

    // MARK: Public entry points

    /// Claude Code, Codex CLI, Gemini CLI 모두 설치
    static func installAll() {
        do {
            try installClaudeHooks()
            try installCodexHooks()
            try installGeminiHooks()
            let l = L10n.shared
            showAlert(title: l.alertAllInstalled, message: l.alertAllInstalledMsg, isError: false)
        } catch {
            showAlert(title: L10n.shared.alertInstallFailed, message: error.localizedDescription, isError: true)
        }
    }

    /// Claude Code (~/.claude/settings.json)
    static func install() {
        do {
            try installClaudeHooks()
            let l = L10n.shared
            showAlert(title: l.alertClaudeInstalled, message: l.alertClaudeRestartMsg, isError: false)
        } catch {
            showAlert(title: L10n.shared.alertClaudeInstallFailed, message: error.localizedDescription, isError: true)
        }
    }

    /// Codex CLI (~/.codex/hooks.json + config.toml)
    static func installCodex() {
        do {
            try installCodexHooks()
            let l = L10n.shared
            showAlert(title: l.alertCodexInstalled, message: l.alertCodexRestartMsg, isError: false)
        } catch {
            showAlert(title: L10n.shared.alertCodexInstallFailed, message: error.localizedDescription, isError: true)
        }
    }

    /// Gemini CLI (~/.gemini/settings.json)
    static func installGemini() {
        do {
            try installGeminiHooks()
            let l = L10n.shared
            showAlert(title: l.alertGeminiInstalled, message: l.alertGeminiRestartMsg, isError: false)
        } catch {
            showAlert(title: L10n.shared.alertGeminiInstallFailed, message: error.localizedDescription, isError: true)
        }
    }

    private static func installClaudeHooks() throws {
        let bridgeURL = try bridgeScriptURL()
        let helperURL = try bridgeHelperURL()
        let paths = installPaths()
        let settingsURL = paths.home.appendingPathComponent(".claude/settings.json")

        try prepare(bridgeURL: bridgeURL, helperURL: helperURL, destURL: paths.destURL, hooksDir: paths.bridgeDir)
        try patchClaudeSettings(at: settingsURL, bridgePath: paths.destURL.path)
    }

    private static func installCodexHooks() throws {
        let bridgeURL = try bridgeScriptURL()
        let helperURL = try bridgeHelperURL()
        let paths = installPaths()
        let codexHooksURL  = paths.home.appendingPathComponent(".codex/hooks.json")
        let codexConfigURL = paths.home.appendingPathComponent(".codex/config.toml")

        try prepare(bridgeURL: bridgeURL, helperURL: helperURL, destURL: paths.destURL, hooksDir: paths.bridgeDir)
        try patchCodexHooks(at: codexHooksURL, bridgePath: paths.destURL.path)
        ensureCodexFeatureFlag(at: codexConfigURL)
    }

    private static func installGeminiHooks() throws {
        let bridgeURL = try bridgeScriptURL()
        let helperURL = try bridgeHelperURL()
        let paths = installPaths()
        let geminiSettingsURL = paths.home.appendingPathComponent(".gemini/settings.json")

        try prepare(bridgeURL: bridgeURL, helperURL: helperURL, destURL: paths.destURL, hooksDir: paths.bridgeDir)
        try patchGeminiSettings(at: geminiSettingsURL, bridgePath: paths.destURL.path)
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

    /// 브리지 스크립트와 Python helper를 bridgeDir에 복사하고 실행 권한을 부여한다.
    private static func prepare(bridgeURL: URL, helperURL: URL, destURL: URL, hooksDir bridgeDir: URL) throws {
        let fm = FileManager.default
        let helperDestURL = bridgeDir.appendingPathComponent(bridgeHelperFileName)
        try fm.createDirectory(at: bridgeDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
        if fm.fileExists(atPath: helperDestURL.path) { try fm.removeItem(at: helperDestURL) }
        try fm.copyItem(at: bridgeURL, to: destURL)
        try fm.copyItem(at: helperURL, to: helperDestURL)
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

    private static func ensureCodexFeatureFlag(at url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        var lines: [String] = []
        if fm.fileExists(atPath: url.path),
           let content = try? String(contentsOf: url, encoding: .utf8) {
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
        try? out.write(to: url, atomically: true, encoding: .utf8)
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
        let home = URL(fileURLWithPath: NSHomeDirectory())
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
        if errors.isEmpty {
            let l = L10n.shared
            showAlert(title: l.alertAllRemoved, message: l.alertAllRemovedMsg, isError: false)
        } else {
            showAlert(title: L10n.shared.alertSomeRemoveFailed, message: errors.joined(separator: "\n"), isError: true)
        }
    }

    static func uninstall() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        do {
            try removeHooks(at: url, fileName: url.lastPathComponent)
            let l = L10n.shared
            showAlert(title: l.alertClaudeRemoved, message: l.alertClaudeHooksRemoved, isError: false)
        } catch {
            showAlert(title: L10n.shared.alertClaudeRemoveFailed, message: error.localizedDescription, isError: true)
        }
    }

    static func uninstallCodex() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/hooks.json")
        do {
            try removeHooks(at: url, fileName: url.lastPathComponent)
            let l = L10n.shared
            showAlert(title: l.alertCodexRemoved, message: l.alertCodexHooksRemoved, isError: false)
        } catch {
            showAlert(title: L10n.shared.alertCodexRemoveFailed, message: error.localizedDescription, isError: true)
        }
    }

    static func uninstallGemini() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/settings.json")
        do {
            try removeHooks(at: url, fileName: url.lastPathComponent)
            let l = L10n.shared
            showAlert(title: l.alertGeminiRemoved, message: l.alertGeminiHooksRemoved, isError: false)
        } catch {
            showAlert(title: L10n.shared.alertGeminiRemoveFailed, message: error.localizedDescription, isError: true)
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var notchWindowController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications
            .filter { $0.localizedName == "DevIsland" && $0.processIdentifier != myPID }
        if !others.isEmpty {
            print("[DevIsland] Found \(others.count) other instances. Terminating them.")
            others.forEach { 
                print("[DevIsland] Terminating other instance: pid=\($0.processIdentifier)")
                $0.terminate() 
            }
        }

        // 다른 인스턴스 종료 요청 후 이동 체크 — 복사 대상 번들이 사용 중일 경우를 방지
        AppRelocator.checkAndPrompt()

        let delay: TimeInterval = others.isEmpty ? 0 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            _ = AppState.shared
            self.notchWindowController = NotchWindowController()
            self.notchWindowController?.showWindow(nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if SettingsStore.shared.settings.checkForUpdatesOnStartup {
                UpdateChecker.shared.schedulePeriodicCheck()
            }
        }
    }
}
