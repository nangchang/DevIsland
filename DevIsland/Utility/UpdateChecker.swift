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

    private let stableAPIURL = URL(string: "https://api.github.com/repos/nangchang/DevIsland/releases/latest")!
    private let nightlyAPIURL = URL(string: "https://api.github.com/repos/nangchang/DevIsland/releases?per_page=20")!
    private let lastCheckKey = "updateLastCheckDate"

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
        let channel = SettingsStore.shared.settings.releaseChannel
        if channel == .nightly {
            return hasNightlyUpdate(latestTag: release.version)
        }
        return isNewer(release.version, than: currentVersion)
    }

    /// nightly tag (nightly-0.11.1-20260614-16) 의 run number가 현재 빌드보다 크면 업데이트 있음.
    /// CFBundleVersion = github run number
    private func hasNightlyUpdate(latestTag: String) -> Bool {
        guard let latestRun = nightlyRunNumber(from: latestTag),
              let currentRun = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") else {
            return false
        }
        return latestRun > currentRun
    }

    /// "nightly-0.11.1-20260614-16" → 16
    private func nightlyRunNumber(from tag: String) -> Int? {
        guard tag.hasPrefix("nightly-") else { return nil }
        return tag.components(separatedBy: "-").last.flatMap { Int($0) }
    }

    // MARK: Public entry points

    /// 앱 시작 시 호출 — nightly 빌드면 채널 자동 설정, 1시간 이내 체크했으면 스킵, 이후 매일 반복
    func schedulePeriodicCheck() {
        autoDetectChannel()
        if SettingsStore.shared.settings.checkForUpdatesOnStartup {
            let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
            if Date().timeIntervalSince(last) > 3600 {
                Task { await fetchLatestRelease(silent: true) }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard SettingsStore.shared.settings.checkForUpdatesOnStartup else { return }
                await self.fetchLatestRelease(silent: true)
            }
        }
    }

    /// nightly 빌드를 처음 실행할 때 채널을 자동으로 nightly로 설정
    private func autoDetectChannel() {
        let store = SettingsStore.shared
        let channelKey = SettingsStore.DefaultsKey.releaseChannel
        guard UserDefaults.standard.object(forKey: channelKey) == nil else { return }
        if currentVersion.contains("nightly") {
            store.settings.releaseChannel = .nightly
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

        let channel = SettingsStore.shared.settings.releaseChannel
        do {
            if channel == .nightly {
                try await fetchLatestNightly(silent: silent)
            } else {
                try await fetchLatestStable(silent: silent)
            }
        } catch {
            if !silent { showAlert(title: L10n.shared.updateCheckFailedTitle, message: error.localizedDescription) }
        }
    }

    private func fetchLatestStable(silent: Bool) async throws {
        var req = URLRequest(url: stableAPIURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
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

        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        let changeLog = json["body"] as? String
        latestRelease = ReleaseInfo(version: version, downloadURL: downloadURL, changeLog: changeLog)

        if hasUpdate {
            promptInstall(version: version, downloadURL: downloadURL, changeLog: changeLog)
        } else if !silent {
            showAlert(title: L10n.shared.updateUpToDateTitle, message: L10n.shared.updateUpToDateMsg(currentVersion))
        }
    }

    private func fetchLatestNightly(silent: Bool) async throws {
        var req = URLRequest(url: nightlyAPIURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if !silent { showAlert(title: L10n.shared.updateCheckFailedTitle, message: L10n.shared.updateInvalidResponseMsg) }
            return
        }

        // prerelease: true이고 DMG 에셋이 있는 첫 번째 릴리스 = 최신 nightly
        guard let nightlyRelease = releases.first(where: { ($0["prerelease"] as? Bool) == true }),
              let tagName = nightlyRelease["tag_name"] as? String,
              let assets = nightlyRelease["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String ?? "").hasSuffix(".dmg") }),
              let urlStr = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: urlStr) else {
            if !silent { showAlert(title: L10n.shared.updateCheckFailedTitle, message: L10n.shared.updateNoAssetMsg) }
            return
        }

        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        let changeLog = nightlyRelease["body"] as? String
        // tag_name 형식: nightly-0.11.1-20260614-16 → run number = 마지막 컴포넌트
        let version = tagName
        latestRelease = ReleaseInfo(version: version, downloadURL: downloadURL, changeLog: changeLog)

        if hasNightlyUpdate(latestTag: tagName) {
            promptInstall(version: tagName, downloadURL: downloadURL, changeLog: changeLog)
        } else if !silent {
            showAlert(title: L10n.shared.updateUpToDateTitle, message: L10n.shared.updateUpToDateMsg(currentVersion))
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
                MarkdownView(text: changeLog, foregroundColor: .primary, font: .system(size: 11))
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
}
