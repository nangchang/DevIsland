import AppKit
import os

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
        case missingInstaller

        var errorDescription: String? {
            switch self {
            case .missingBridgeScript:
                return L10n.shared.alertBundleNoScript
            case .missingBridgeHelper:
                return L10n.shared.alertBundleNoHelper
            case .missingBridgeManifest:
                return L10n.shared.alertBundleNoManifest
            case .missingInstaller:
                return L10n.shared.alertBundleNoInstaller
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
        let paths = try prepareBridge()
        let settingsURL = paths.home.appendingPathComponent(".claude/settings.json")
        // install_hooks.py claude는 파일이 존재해야 하므로(json.load) 셸 설치와 동일하게 빈 {}로 시딩.
        try seedIfMissing(settingsURL, contents: "{}")
        try runInstaller("claude", [settingsURL.path, paths.destURL.path])
    }

    private static func installCodexHooks() throws {
        let paths = try prepareBridge()
        let codexHooksURL  = paths.home.appendingPathComponent(".codex/hooks.json")
        let codexConfigURL = paths.home.appendingPathComponent(".codex/config.toml")
        try ensureParentDir(codexHooksURL)
        try runInstaller("codex-hooks", [codexHooksURL.path, paths.destURL.path])
        try runInstaller("codex-config", [codexConfigURL.path, paths.destURL.path])
    }

    private static func installGeminiHooks() throws {
        let paths = try prepareBridge()
        let geminiSettingsURL = paths.home.appendingPathComponent(".gemini/settings.json")
        try ensureParentDir(geminiSettingsURL)
        try runInstaller("gemini", [geminiSettingsURL.path, paths.destURL.path])
    }

    private static func installAntigravityHooks() throws {
        let paths = try prepareBridge()
        let antigravityHooksURL = paths.home.appendingPathComponent(".gemini/config/hooks.json")
        let legacyAntigravityHooksURL = paths.home.appendingPathComponent(".gemini/antigravity-cli/hooks.json")
        let legacyAntigravityDir = paths.home.appendingPathComponent(".gemini/antigravity-cli")
        try ensureParentDir(antigravityHooksURL)
        // install_hooks.py antigravity가 레거시 파일 정리(devisland 키 제거 + stray 파일 삭제)까지 내부 수행.
        try runInstaller("antigravity", [
            antigravityHooksURL.path, paths.destURL.path,
            legacyAntigravityHooksURL.path, legacyAntigravityDir.path,
        ])
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

    /// 번들 브리지 리소스를 bridgeDir에 배치하고 설치 경로를 돌려준다.
    /// 모든 provider 설치가 공통으로 먼저 호출한다.
    private static func prepareBridge() throws -> InstallPaths {
        let bridgeURL = try bridgeScriptURL()
        let helperURL = try bridgeHelperURL()
        let manifestURL = try bridgeManifestURL()
        let paths = installPaths()
        try prepare(bridgeURL: bridgeURL, helperURL: helperURL, manifestURL: manifestURL, destURL: paths.destURL, hooksDir: paths.bridgeDir)
        return paths
    }

    private static func ensureParentDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// 대상 파일이 없으면 부모 디렉토리 생성 후 초기 내용으로 시딩한다.
    private static func seedIfMissing(_ url: URL, contents: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        try ensureParentDir(url)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: install_hooks.py subprocess

    private static func installerScriptURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "install_hooks", withExtension: "py") else {
            throw BridgeInstallerError.missingInstaller
        }
        return url
    }

    /// python3 인터프리터를 찾는다. Finder에서 실행된 GUI 앱은 셸 PATH를 상속하지 않아
    /// 후보 경로를 직접 탐색한다. 런타임 브리지(devisland-bridge.sh)는 PATH의 python3를
    /// 쓰므로 homebrew 설치를 먼저 보고, 마지막에 시스템/CLT 경로로 폴백한다
    /// (`/usr/bin/python3`는 CLT 미설치 시 stub이라 후순위).
    private static func pythonInterpreterURL() -> URL {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    /// 번들 install_hooks.py를 python3로 실행한다. install_hooks.py는 hook_events.json
    /// 매니페스트를 자기 위치(앱 Resources) 기준으로 읽는다.
    private static func runInstaller(_ subcommand: String, _ arguments: [String]) throws {
        let script = try installerScriptURL()
        let process = Process()
        process.executableURL = pythonInterpreterURL()
        process.arguments = [script.path, subcommand] + arguments
        let errPipe = Pipe()
        // stdout은 쓰지 않지만 파이프로 두면 버퍼가 차 교착될 수 있어 폐기한다.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw NSError(domain: "BridgeInstaller", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L10n.shared.alertInstallScriptFailed(error.localizedDescription)])
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr
            throw NSError(domain: "BridgeInstaller", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L10n.shared.alertInstallScriptFailed(detail)])
        }
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
            Log.bridge.error("Failed to remove legacy Antigravity hooks: \(error, privacy: .private)")
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

    // MARK: Alert helper

    /// title/message는 @autoclosure로 받아 메인 스레드에서 평가한다.
    /// 설치/제거 작업이 백그라운드 큐에서 실행되므로, L10n.shared(@Published
    /// language 보유) 문자열을 백그라운드에서 읽으면 언어 변경 쓰기와 레이스가
    /// 날 수 있다. 평가를 main.async 내부로 미뤄 이를 방지한다.
    private static func showAlert(title: @escaping @autoclosure () -> String, message: @escaping @autoclosure () -> String, isError: Bool) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title()
            alert.informativeText = message()
            alert.alertStyle = isError ? .critical : .informational
            alert.addButton(withTitle: L10n.shared.alertOK)
            alert.runModal()
        }
    }
}
