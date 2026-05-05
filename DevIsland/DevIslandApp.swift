import SwiftUI

@main
struct DevIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            HStack(spacing: 3) {
                Image("StatusBarIcon")
                if state.pendingCount > 0 {
                    Text("\(state.pendingCount)")
                        .font(.system(size: 10, weight: .bold))
                }
            }
        }
    }
}

// MARK: - Menu Bar Menu

struct MenuBarMenu: View {
    @ObservedObject var state = AppState.shared
    
    static let versionString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "DevIsland v\(version) (\(build))"
    }()

    var body: some View {
        if state.pendingItems.isEmpty {
            Text("대기 중인 요청 없음")
                .foregroundStyle(.secondary)
        } else {
            ForEach(state.pendingItems) { item in
                HStack(spacing: 6) {
                    Image(systemName: toolInfo(for: item.toolName).icon)
                        .foregroundStyle(toolInfo(for: item.toolName).color)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.toolName.isEmpty ? "Unknown" : item.toolName)
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

        if state.isNotchExpanded {
            Button("Focus Terminal") { state.focusTerminal() }
            Divider()
            Button("Approve  ⌘⇧Y") { state.approve() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Button("Deny  ⌘⇧N") { state.deny() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
        }

        Divider()

        Picker("노치 표시 위치", selection: $state.notchDisplayTarget) {
            ForEach(NotchDisplayTarget.allCases) { target in
                Text(target.label).tag(target)
            }
        }

        if state.notchDisplayTarget == .specific {
            Picker("모니터 선택", selection: $state.selectedDisplayId) {
                ForEach(NSScreen.screens, id: \.displayId) { screen in
                    Text(Self.displayName(for: screen)).tag(screen.displayId)
                }
            }
        }

        Toggle("전체 화면 앱 위에 표시", isOn: $state.showInFullScreenApps)
        Picker("요청 표시 위치", selection: $state.requestDisplayTarget) {
            ForEach(RequestDisplayTarget.allCases) { target in
                Text(target.label).tag(target)
            }
        }

        Divider()

        Menu("자동 승인(Global) 툴 관리") {
            Toggle("Safe 등급 툴 자동 승인 (조회성 작업)", isOn: $state.autoApproveSafeTools)
            Toggle("Gemini 일반 모드 에뮬레이션 (DevIsland가 통제)", isOn: $state.emulateGeminiInteractiveMode)
            Divider()
            Button("직접 텍스트로 추가하기...") {
                state.promptToAddGlobalAutoApprove()
            }
            Menu("목록에서 추가하기") {
                ForEach([ToolRiskLevel.safe, .low, .medium, .high, .critical], id: \.self) { risk in
                    let tools = ToolKnowledge.predefined.filter { $0.risk == risk }
                    if !tools.isEmpty {
                        Menu("\(risk.emoji) \(risk.rawValue)") {
                            Button("이 위험도의 모든 툴 추가") {
                                for t in tools { state.globalAutoApproveTypes.insert(t.id) }
                            }
                            Divider()
                            ForEach(tools) { tool in
                                Button("\(tool.name) (\(tool.id)) \(risk.emoji)") {
                                    state.globalAutoApproveTypes.insert(tool.id)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Menu("등록된 툴 관리 (\(state.globalAutoApproveTypes.count)개)") {
                if state.globalAutoApproveTypes.isEmpty {
                    Text("설정된 자동 승인 툴이 없습니다.").disabled(true)
                } else {
                    Button(role: .destructive) {
                        state.globalAutoApproveTypes.removeAll()
                    } label: {
                        Label("모두 지우기", systemImage: "trash.fill")
                    }
                    Divider()
                    ForEach(Array(state.globalAutoApproveTypes.sorted()), id: \.self) { tool in
                        let risk = ToolKnowledge.risk(for: tool)
                        Button(role: .destructive) {
                            state.globalAutoApproveTypes.remove(tool)
                        } label: {
                            Label("\(tool) \(risk.emoji)", systemImage: "minus.circle")
                        }
                    }
                }
            }
        }

        Menu("자동 승인(Session) 툴 관리") {
            if state.activeSessions.isEmpty {
                Text("활성화된 세션이 없습니다.").disabled(true)
            } else {
                ForEach(state.activeSessions) { session in
                    let tools = state.sessionAutoApproveTypes[session.id] ?? []
                    Menu("Session \(session.id.prefix(8)) (\(tools.count)개)") {
                        Button("직접 텍스트로 추가하기...") {
                            state.promptToAddSessionAutoApprove(for: session.id)
                        }
                        Menu("목록에서 추가하기") {
                            ForEach([ToolRiskLevel.safe, .low, .medium, .high, .critical], id: \.self) { risk in
                                let pTools = ToolKnowledge.predefined.filter { $0.risk == risk }
                                if !pTools.isEmpty {
                                    Menu("\(risk.emoji) \(risk.rawValue)") {
                                        Button("이 위험도의 모든 툴 추가") {
                                            for t in pTools {
                                                if state.sessionAutoApproveTypes[session.id] == nil {
                                                    state.sessionAutoApproveTypes[session.id] = []
                                                }
                                                state.sessionAutoApproveTypes[session.id]?.insert(t.id)
                                            }
                                        }
                                        Divider()
                                        ForEach(pTools) { tool in
                                            Button("\(tool.name) (\(tool.id)) \(risk.emoji)") {
                                                if state.sessionAutoApproveTypes[session.id] == nil {
                                                    state.sessionAutoApproveTypes[session.id] = []
                                                }
                                                state.sessionAutoApproveTypes[session.id]?.insert(tool.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                        Menu("등록된 툴 관리 (\(tools.count)개)") {
                            if tools.isEmpty {
                                Text("설정된 툴 없음").disabled(true)
                            } else {
                                Button(role: .destructive) {
                                    state.sessionAutoApproveTypes[session.id]?.removeAll()
                                } label: {
                                    Label("모두 지우기", systemImage: "trash.fill")
                                }
                                Divider()
                                ForEach(Array(tools.sorted()), id: \.self) { tool in
                                    let risk = ToolKnowledge.risk(for: tool)
                                    Button(role: .destructive) {
                                        state.sessionAutoApproveTypes[session.id]?.remove(tool)
                                    } label: {
                                        Label("\(tool) \(risk.emoji)", systemImage: "minus.circle")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Divider()

        Menu("브리지 설치") {
            Button("전부 설치 (Claude · Codex · Gemini)") {
                BridgeInstaller.installAll()
            }
            Divider()
            Button("Claude Code만 설치...") {
                BridgeInstaller.install()
            }
            Button("Codex CLI만 설치...") {
                BridgeInstaller.installCodex()
            }
            Button("Gemini CLI만 설치...") {
                BridgeInstaller.installGemini()
            }
        }

        if !GlobalShortcutManager.shared.hasAccessibilityPermission {
            Button("접근성 권한 요청...") {
                GlobalShortcutManager.shared.requestAccessibilityPermission()
            }
        }

        Divider()

        Text(MenuBarMenu.versionString)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)

        Button("Quit DevIsland") {
            NSApplication.shared.terminate(nil)
        }
    }

    private static func displayName(for screen: NSScreen) -> String {
        let index = NSScreen.screens.firstIndex(of: screen).map { $0 + 1 } ?? 1
        let role = screen == NSScreen.main ? "주 모니터" : "모니터 \(index)"
        return "\(role) · \(Int(screen.frame.width))×\(Int(screen.frame.height))"
    }
}

// MARK: - Bridge Installer

enum BridgeInstaller {
    private static let sharedBridgePath = "Library/Application Support/DevIsland"
    private static let bridgeFileName = "devisland-bridge.sh"
    private static let bridgeHelperFileName = "devisland_bridge.py"

    // MARK: Public entry points

    /// Claude Code, Codex CLI, Gemini CLI 모두 설치
    static func installAll() {
        install()
        installCodex()
        installGemini()
    }

    /// Claude Code (~/.claude/settings.json)
    static func install() {
        guard let bridgeURL = bridgeScriptURL() else { return }
        guard let helperURL = bridgeHelperURL() else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let bridgeDir = home.appendingPathComponent(sharedBridgePath)
        let destURL  = bridgeDir.appendingPathComponent(bridgeFileName)
        let settingsURL = home.appendingPathComponent(".claude/settings.json")

        do {
            try prepare(bridgeURL: bridgeURL, helperURL: helperURL, destURL: destURL, hooksDir: bridgeDir)
            try patchClaudeSettings(at: settingsURL, bridgePath: destURL.path)
            showAlert(title: "Claude Code 설치 완료",
                      message: "브리지가 설치되었습니다.\nClaude Code 세션을 재시작해주세요.",
                      isError: false)
        } catch {
            showAlert(title: "Claude Code 설치 실패", message: error.localizedDescription, isError: true)
        }
    }

    /// Codex CLI (~/.codex/hooks.json + config.toml)
    static func installCodex() {
        guard let bridgeURL = bridgeScriptURL() else { return }
        guard let helperURL = bridgeHelperURL() else { return }
        let home    = URL(fileURLWithPath: NSHomeDirectory())
        let bridgeDir = home.appendingPathComponent(sharedBridgePath)
        let destURL  = bridgeDir.appendingPathComponent(bridgeFileName)
        let codexHooksURL  = home.appendingPathComponent(".codex/hooks.json")
        let codexConfigURL = home.appendingPathComponent(".codex/config.toml")

        do {
            try prepare(bridgeURL: bridgeURL, helperURL: helperURL, destURL: destURL, hooksDir: bridgeDir)
            try patchCodexHooks(at: codexHooksURL, bridgePath: destURL.path)
            ensureCodexFeatureFlag(at: codexConfigURL)
            showAlert(title: "Codex CLI 설치 완료",
                      message: "브리지가 설치되었습니다.\nCodex CLI 세션을 재시작해주세요.",
                      isError: false)
        } catch {
            showAlert(title: "Codex CLI 설치 실패", message: error.localizedDescription, isError: true)
        }
    }

    /// Gemini CLI (~/.gemini/settings.json)
    static func installGemini() {
        guard let bridgeURL = bridgeScriptURL() else { return }
        guard let helperURL = bridgeHelperURL() else { return }
        let home    = URL(fileURLWithPath: NSHomeDirectory())
        let bridgeDir = home.appendingPathComponent(sharedBridgePath)
        let destURL  = bridgeDir.appendingPathComponent(bridgeFileName)
        let geminiSettingsURL = home.appendingPathComponent(".gemini/settings.json")

        do {
            try prepare(bridgeURL: bridgeURL, helperURL: helperURL, destURL: destURL, hooksDir: bridgeDir)
            try patchGeminiSettings(at: geminiSettingsURL, bridgePath: destURL.path)
            showAlert(title: "Gemini CLI 설치 완료",
                      message: "브리지가 설치되었습니다.\nGemini CLI 세션을 재시작해주세요.",
                      isError: false)
        } catch {
            showAlert(title: "Gemini CLI 설치 실패", message: error.localizedDescription, isError: true)
        }
    }

    // MARK: Shared helpers

    private static func bridgeScriptURL() -> URL? {
        guard let url = Bundle.main.url(forResource: "devisland-bridge", withExtension: "sh") else {
            showAlert(title: "설치 실패", message: "앱 번들에서 브리지 스크립트를 찾을 수 없습니다.", isError: true)
            return nil
        }
        return url
    }

    private static func bridgeHelperURL() -> URL? {
        guard let url = Bundle.main.url(forResource: "devisland_bridge", withExtension: "py") else {
            showAlert(title: "설치 실패", message: "앱 번들에서 브리지 helper를 찾을 수 없습니다.", isError: true)
            return nil
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
                              userInfo: [NSLocalizedDescriptionKey: "settings.json 파싱 실패: 유효하지 않은 JSON 형식입니다."])
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
            ("PermissionRequest", approvalConfig),
        ]
        let retiredEntries = [
            "SubagentStop", "PreToolUse", "PostToolUse", "PreCompact", "StopFailure"
        ]

        func removingBridgeHooks(from list: [[String: Any]]) -> [[String: Any]] {
            list.compactMap { entry in
                let subHooks = (entry["hooks"] as? [[String: Any]] ?? [])
                    .filter { !($0["command"] as? String ?? "").contains(bridgeFileName) }
                guard !subHooks.isEmpty else { return nil }
                var updatedEntry = entry
                updatedEntry["hooks"] = subHooks
                return updatedEntry
            }
        }

        for (key, config) in entries {
            var list = removingBridgeHooks(from: (hooks[key] as? [[String: Any]]) ?? [])
            list.append(config)
            hooks[key] = list
        }
        for key in retiredEntries {
            let list = removingBridgeHooks(from: (hooks[key] as? [[String: Any]]) ?? [])
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
        let events = ["SessionStart", "SessionEnd", "PreToolUse", "PostToolUse", "Stop"]
        for event in events {
            var eventConfigs = (hooks[event] as? [[String: Any]]) ?? []
            
            var found = false
            for i in 0..<eventConfigs.count {
                var config = eventConfigs[i]
                if (config["matcher"] as? String) == "*" {
                    var subHooks = (config["hooks"] as? [[String: Any]]) ?? []
                    subHooks.removeAll { ($0["command"] as? String ?? "").contains(bridgeFileName) }
                    subHooks.append(["type": "command", "command": bridgeCommand])
                    config["hooks"] = subHooks
                    eventConfigs[i] = config
                    found = true
                    break
                }
            }
            
            if !found {
                eventConfigs.append([
                    "matcher": "*",
                    "hooks": [["type": "command", "command": bridgeCommand]]
                ])
            }
            hooks[event] = eventConfigs
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

        // 기존 [hooks] 또는 [[hooks.]] 관련 설정 제거 및 features 활성화 (hooks.json으로 일원화)
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

        if let index = newLines.firstIndex(where: { $0.contains("codex_hooks") }) {
            if newLines[index].contains("false") {
                newLines[index] = newLines[index].replacingOccurrences(of: "false", with: "true")
            }
        } else {
            newLines.append("\n[features]\ncodex_hooks = true\n")
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

        for event in ["BeforeTool", "SessionStart", "SessionEnd", "AfterAgent"] {
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

        data["hooks"] = hooks

        let out = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    // MARK: Alert helper

    private static func showAlert(title: String, message: String, isError: Bool) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = isError ? .critical : .informational
            alert.addButton(withTitle: "확인")
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
    }
}
