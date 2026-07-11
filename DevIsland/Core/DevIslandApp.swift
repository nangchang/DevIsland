import SwiftUI
import os

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
        AppState.shared.refreshPluginScopedFileScopes(settings: SettingsStore.shared.settings)
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
        let result = NSImage(size: source.size, flipped: false) { rect in
            color.set()
            rect.fill()
            source.draw(in: rect,
                        from: NSRect(origin: .zero, size: source.size),
                        operation: .destinationIn,
                        fraction: 1.0)
            return true
        }
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
    @ObservedObject private var pluginHost = AppState.shared.pluginHost

    static let versionString: String = {
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "DevIsland"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(appName) v\(version) (\(build))"
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

        PluginMenuItemsView(
            contributions: pluginHost.contributions[.menubarMenu] ?? [],
            pluginDisplayNames: pluginHost.pluginDisplayNames
        )

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
            Button(l.menuInstallAntigravity) {
                BridgeInstaller.installAntigravity()
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
            Button(l.menuRemoveAntigravity) {
                BridgeInstaller.uninstallAntigravity()
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
                updateChecker.checkManually(channel: SettingsStore.shared.settings.releaseChannel)
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var notchWindowController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_UNIT_TESTS"] != "1" else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let managedBundleIds: Set<String> = [
            "kr.or.nes.DevIsland",
            "kr.or.nes.DevIsland.dev"
        ]
        let others = NSWorkspace.shared.runningApplications
            .filter { app in
                guard let bundleID = app.bundleIdentifier else { return false }
                return app.processIdentifier != myPID && managedBundleIds.contains(bundleID)
            }
        if !others.isEmpty {
            Log.core.info("Found \(others.count, privacy: .public) other instances. Terminating them.")
            others.forEach { 
                Log.core.info("Terminating other instance: pid=\($0.processIdentifier, privacy: .public)")
                $0.terminate() 
            }
        }

        // 다른 인스턴스 종료 요청 후 이동 체크 — 복사 대상 번들이 사용 중일 경우를 방지
        AppRelocator.checkAndPrompt()

        NotificationManager.shared.setup()

        let delay: TimeInterval = others.isEmpty ? 0 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            _ = AppState.shared
            AppState.shared.startPluginPlatform()
            self.notchWindowController = NotchWindowController()
            self.notchWindowController?.showWindow(nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateChecker.shared.schedulePeriodicCheck {
                let s = SettingsStore.shared.settings
                return (checkOnStartup: s.checkForUpdatesOnStartup, channel: s.releaseChannel)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stopPluginPlatform()
    }
}
