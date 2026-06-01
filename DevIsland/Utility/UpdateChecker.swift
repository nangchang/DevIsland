import Foundation
import AppKit
import SwiftUI

// MARK: - Data

struct ReleaseInfo {
    let version: String
    let downloadURL: URL
    let changeLog: String?
}

enum UpdateError: LocalizedError {
    case mountFailed(Int32)
    case appNotFound
    case invalidResponse
    case noAsset
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .mountFailed(let code): return "Failed to mount DMG (exit code \(code))"
        case .appNotFound:           return "DevIsland.app not found in DMG"
        case .invalidResponse:       return "Invalid response from GitHub"
        case .noAsset:               return "No DMG found in release assets"
        case .httpError(let code):   return "HTTP error \(code)"
        }
    }
}

// MARK: - UpdateChecker

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    private init() {}

    private let apiURL = URL(string: "https://api.github.com/repos/nangchang/DevIsland/releases/latest")!
    @Published var latestRelease: ReleaseInfo? = nil
    @Published var isChecking = false
    @Published var isUpdating = false
    @Published var updateStatusText: String = ""
    @Published var downloadProgress: Double = -1  // < 0 = indeterminate

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var hasUpdate: Bool {
        guard let release = latestRelease else { return false }
        return isNewer(release.version, than: currentVersion)
    }

    // MARK: Public entry points

    /// 앱 시작 시 호출 — 즉시 한 번 확인, 이후 매일 반복
    func schedulePeriodicCheck() {
        if SettingsStore.shared.settings.checkForUpdatesOnStartup {
            Task { await fetchLatestRelease(silent: true) }
        }
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard SettingsStore.shared.settings.checkForUpdatesOnStartup else { return }
            Task { await self.fetchLatestRelease(silent: true) }
        }
    }

    func checkManually() {
        Task { await fetchLatestRelease(silent: false) }
    }

    func installUpdate() {
        guard let release = latestRelease, hasUpdate else { return }
        promptInstall(version: release.version, downloadURL: release.downloadURL, changeLog: release.changeLog)
    }

    // MARK: Check

    private func fetchLatestRelease(silent: Bool) async {
        guard !isChecking && !isUpdating else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            var req = URLRequest(url: apiURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw UpdateError.httpError(code)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                if !silent { showAlert(title: L10n.shared.updateCheckFailedTitle, message: L10n.shared.updateInvalidResponseMsg) }
                return
            }

            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            guard let asset = assets.first(where: { ($0["name"] as? String ?? "").hasSuffix(".dmg") }),
                  let urlStr = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: urlStr) else {
                if !silent { showAlert(title: L10n.shared.updateCheckFailedTitle, message: L10n.shared.updateNoAssetMsg) }
                return
            }

            let changeLog = json["body"] as? String
            latestRelease = ReleaseInfo(version: version, downloadURL: downloadURL, changeLog: changeLog)

            if hasUpdate {
                promptInstall(version: version, downloadURL: downloadURL, changeLog: changeLog)
            } else if !silent {
                showAlert(title: L10n.shared.updateUpToDateTitle, message: L10n.shared.updateUpToDateMsg(currentVersion))
            }
        } catch {
            if !silent { showAlert(title: L10n.shared.updateCheckFailedTitle, message: error.localizedDescription) }
        }
    }

    // MARK: Install

    private func promptInstall(version: String, downloadURL: URL, changeLog: String?) {
        let l = L10n.shared
        let alert = NSAlert()
        alert.messageText = l.updateAvailableTitle
        alert.informativeText = l.updateAvailableMsg(version)
        alert.addButton(withTitle: l.updateInstallBtn)
        alert.addButton(withTitle: l.updateLaterBtn)

        if let changeLog = changeLog, !changeLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let changeLogView = UpdateChangeLogView(changeLog: changeLog)
            let hostingView = NSHostingView(rootView: changeLogView)
            hostingView.frame.size = hostingView.fittingSize
            alert.accessoryView = hostingView
        }

        guard runModal(alert) == .alertFirstButtonReturn else { return }
        Task { await doInstall(downloadURL: downloadURL) }
    }

    private func doInstall(downloadURL: URL) async {
        isUpdating = true
        showProgressWindow()

        do {
            updateStatusText = L10n.shared.updateDownloading
            downloadProgress = -1
            let (tempURL, downloadResponse) = try await URLSession.shared.download(from: downloadURL)
            guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else {
                let code = (downloadResponse as? HTTPURLResponse)?.statusCode ?? -1
                throw UpdateError.httpError(code)
            }

            updateStatusText = L10n.shared.updateInstalling
            downloadProgress = 0.5
            let destURL = try await Task.detached(priority: .userInitiated) {
                try UpdateChecker.installFromDMG(downloaded: tempURL)
            }.value

            updateStatusText = L10n.shared.updateRelaunching
            downloadProgress = 1.0

            // 구 앱이 포트를 점유한 채로 새 앱이 뜨면 "포트 충돌" 에러 발생.
            // 백그라운드 셸로 지연 실행을 등록한 뒤 구 앱을 먼저 종료한다.
            let path = destURL.path.replacingOccurrences(of: "'", with: "'\\''")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", "sleep 1.5 && open -n '\(path)'"]
            try? proc.run()

            NSApplication.shared.terminate(nil)
        } catch {
            closeProgressWindow()
            isUpdating = false
            showAlert(title: L10n.shared.updateFailedTitle, message: error.localizedDescription)
        }
    }

    // MARK: DMG install (runs off main actor)

    private nonisolated static func installFromDMG(downloaded tempURL: URL) throws -> URL {
        let fm = FileManager.default
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let dmgURL = tmpDir.appendingPathComponent("DevIsland-update-\(UUID().uuidString).dmg")
        let mountPoint = tmpDir.appendingPathComponent("DevIsland-mount-\(UUID().uuidString)")

        defer {
            _ = shell("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"])
            try? fm.removeItem(at: mountPoint)
            try? fm.removeItem(at: dmgURL)
        }

        try fm.moveItem(at: tempURL, to: dmgURL)
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let mountCode = shell("/usr/bin/hdiutil", [
            "attach", dmgURL.path,
            "-nobrowse", "-readonly", "-noverify",
            "-mountpoint", mountPoint.path,
            "-quiet"
        ])
        guard mountCode == 0 else { throw UpdateError.mountFailed(mountCode) }

        let contents = (try? fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let appSrc = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFound
        }

        let appsDir = fm.urls(for: .applicationDirectory, in: .localDomainMask).first!
        let bundleURL = Bundle.main.bundleURL.standardized
        let destURL: URL
        if bundleURL.path.hasPrefix(appsDir.standardized.path + "/") {
            destURL = bundleURL
        } else {
            destURL = appsDir.appendingPathComponent(appSrc.lastPathComponent)
        }

        // 스테이징 경로에 먼저 복사한 뒤 원자적으로 교체 → 복사 실패 시 기존 앱 보존
        let stagingURL = tmpDir.appendingPathComponent("DevIsland-staging-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: stagingURL) }
        try fm.copyItem(at: appSrc, to: stagingURL)
        shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagingURL.path])

        if fm.fileExists(atPath: destURL.path) {
            _ = try fm.replaceItemAt(destURL, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: destURL)
        }

        return destURL
    }

    @discardableResult
    private nonisolated static func shell(_ path: String, _ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    // MARK: Progress window

    private var progressPanel: NSPanel?

    private func showProgressWindow() {
        AppState.shared.isNotchExpanded = false
        let hostingVC = NSHostingController(rootView: UpdateProgressView())
        let panel = NSPanel(contentViewController: hostingVC)
        panel.styleMask = [.titled]  // closable 제외 → 닫기 버튼 없음
        panel.title = ""
        panel.isFloatingPanel = true
        panel.level = .init(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.orderFrontRegardless()
        progressPanel = panel
    }

    private func closeProgressWindow() {
        progressPanel?.close()
        progressPanel = nil
    }

    // MARK: Helpers

    private func isNewer(_ latest: String, than current: String) -> Bool {
        let clean: (String) -> String = {
            if let index = $0.firstIndex(of: "-") {
                return String($0[..<index])
            }
            return $0
        }
        let parse: (String) -> [Int] = { clean($0).split(separator: ".").compactMap { Int($0) } }
        let l = parse(latest), c = parse(current)
        for i in 0..<max(l.count, c.count) {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.shared.alertOK)
        runModal(alert)
    }

    @discardableResult
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        ModalPresenter.run(alert)
    }
}

// MARK: - Progress View

struct UpdateProgressView: View {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 20) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
            }

            Text(checker.updateStatusText)
                .font(.headline)

            if checker.downloadProgress < 0 {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 240)
            } else {
                ProgressView(value: checker.downloadProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 240)
            }
        }
        .padding(32)
        .frame(width: 320)
    }
}

// MARK: - Change Log View

struct UpdateChangeLogView: View {
    let changeLog: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.shared.updateChangeLogTitle)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(markdownAttributedString(from: changeLog))
                        .font(.system(size: 11))
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
            }
            .frame(width: 440, height: 180)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
    }

    private func markdownAttributedString(from text: String) -> AttributedString {
        // GitHub 릴리스 노트는 단일 \n을 줄 바꿈으로 사용하지만
        // Apple AttributedString 파서는 CommonMark 기준으로 단일 \n을 공백 처리함.
        // 코드 블록(```) 외부에서만 \n을 Markdown hard break (trailing 2 spaces)로 변환한다.
        let parts = text.components(separatedBy: "```")
        let processed = parts.enumerated().map { index, part in
            guard index % 2 == 0 else { return part }  // 코드 블록 내부는 그대로
            return part
                .components(separatedBy: "\n\n")
                .map { $0.replacingOccurrences(of: "\n", with: "  \n") }
                .joined(separator: "\n\n")
        }.joined(separator: "```")
        if let attrStr = try? AttributedString(markdown: processed) {
            return attrStr
        }
        return AttributedString(text)
    }
}
