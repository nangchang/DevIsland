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

        Picker("표시 위치", selection: $state.notchDisplayTarget) {
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

        Button("브리지 설치...") {
            BridgeInstaller.install()
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
    static func install() {
        guard let bridgeURL = Bundle.main.url(forResource: "devisland-bridge", withExtension: "sh") else {
            showAlert(title: "설치 실패", message: "앱 번들에서 브리지 스크립트를 찾을 수 없습니다.", isError: true)
            return
        }

        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let hooksDir = home.appendingPathComponent(".claude/hooks")
        let destURL = hooksDir.appendingPathComponent("devisland-bridge.sh")
        let settingsURL = home.appendingPathComponent(".claude/settings.json")

        do {
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
            try fm.copyItem(at: bridgeURL, to: destURL)
            try fm.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: destURL.path)
            try patchSettings(at: settingsURL, bridgePath: destURL.path)
            showAlert(title: "설치 완료",
                      message: "브리지가 설치되었습니다.\nClaude Code 세션을 재시작해주세요.",
                      isError: false)
        } catch {
            showAlert(title: "설치 실패", message: error.localizedDescription, isError: true)
        }
    }

    private static func patchSettings(at url: URL, bridgePath: String) throws {
        let fm = FileManager.default
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
            "hooks": [["type": "command", "command": bridgePath, "timeout": 86400]]
        ]
        let lifecycleConfig: [String: Any] = [
            "hooks": [["type": "command", "command": bridgePath]]
        ]
        let entries: [(String, [String: Any])] = [
            ("SessionStart", lifecycleConfig),
            ("SessionEnd", lifecycleConfig),
            ("PermissionRequest", approvalConfig),
        ]
        let retiredEntries = [
            "Stop", "SubagentStop", "PreToolUse", "PostToolUse", "Notification", "PreCompact", "StopFailure"
        ]

        func removingBridgeHooks(from list: [[String: Any]]) -> [[String: Any]] {
            list.compactMap { entry in
                let subHooks = (entry["hooks"] as? [[String: Any]] ?? [])
                    .filter { ($0["command"] as? String) != bridgePath }
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
            if list.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = list
            }
        }

        settings["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

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
        others.forEach { $0.terminate() }

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
