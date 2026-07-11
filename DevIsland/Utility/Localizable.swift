import Foundation
import Combine

// MARK: - Language

enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case english
    case korean

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:  return "System / 시스템"
        case .english: return "English"
        case .korean:  return "한국어"
        }
    }

    var isKoreanResolved: Bool {
        switch self {
        case .system:  return Locale.preferredLanguages.first.map { $0 == "ko" || $0.hasPrefix("ko-") } ?? false
        case .english: return false
        case .korean:  return true
        }
    }

    func s(_ en: String, _ ko: String) -> String { isKoreanResolved ? ko : en }
}

// MARK: - L10n

final class L10n: ObservableObject {
    static let shared = L10n()

    static let defaultsKey = "appLanguage"

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey) }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let lang = AppLanguage(rawValue: raw) {
            language = lang
        } else {
            language = .system
        }
    }

    var isKorean: Bool {
        language.isKoreanResolved
    }

    func s(_ en: String, _ ko: String) -> String { isKorean ? ko : en }

    /// Per-language `.lproj` bundle, resolved once and cached. `static let` is
    /// lazily and thread-safely initialized. Falls back to `.main` if the bundle
    /// is somehow absent (never expected in a built app).
    private static let enBundle = lprojBundle("en")
    private static let koBundle = lprojBundle("ko")

    private static func lprojBundle(_ lproj: String) -> Bundle {
        if let path = Bundle.main.path(forResource: lproj, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }

    /// Looks up `key` in the compiled `Localizable.xcstrings` for the currently
    /// resolved language. Reads the per-language `.lproj` bundle directly instead
    /// of `String(localized:)` so live language switching keeps working without a
    /// relaunch (the OS resolves the main bundle's localization only at launch).
    func t(_ key: String) -> String {
        let bundle = isKorean ? Self.koBundle : Self.enBundle
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// `t(key)` with `String(format:)` arguments applied (for entries with
    /// interpolated values). The catalog value carries the format specifiers.
    /// Intentionally non-localized (no `locale:`) to match the pre-migration
    /// `\(interpolation)` byte-for-byte — passing a language `Locale` would inject
    /// thousands separators for numbers ≥ 1000 (e.g. pixel/count values).
    func tf(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}

// MARK: - String constants

extension L10n {

    // MARK: Menu Bar
    var menuNoPending: String { t("menuNoPending") }
    var menuPending: String { t("menuPending") }
    var menuFocusTerminal: String { t("menuFocusTerminal") }
    var menuApprove: String { t("menuApprove") }
    var menuDeny: String { t("menuDeny") }
    var menuSettings: String { t("menuSettings") }
    var menuApprovalRules: String { t("menuApprovalRules") }
    var menuReplayLog: String { t("menuReplayLog") }
    var menuPTYTranscript: String { t("menuPTYTranscript") }
    var menuSessionHistory: String { t("menuSessionHistory") }
    var menuInstallHooks: String { t("menuInstallHooks") }
    var menuInstallAll: String { t("menuInstallAll") }
    var menuInstallClaude: String { t("menuInstallClaude") }
    var menuInstallCodex: String { t("menuInstallCodex") }
    var menuInstallGemini: String { t("menuInstallGemini") }
    var menuInstallAntigravity: String { t("menuInstallAntigravity") }
    var menuRemoveAll: String { t("menuRemoveAll") }
    var menuRemoveClaude: String { t("menuRemoveClaude") }
    var menuRemoveCodex: String { t("menuRemoveCodex") }
    var menuRemoveGemini: String { t("menuRemoveGemini") }
    var menuRemoveAntigravity: String { t("menuRemoveAntigravity") }
    var menuAccessibility: String { t("menuAccessibility") }
    var menuCheckForUpdates: String { t("menuCheckForUpdates") }
    func menuUpdateAvailable(_ v: String) -> String { tf("menuUpdateAvailable", v) }
    var menuQuit: String { t("menuQuit") }

    // MARK: Alerts — install
    var alertAllInstalled: String { t("alertAllInstalled") }
    var alertClaudeInstalled: String { t("alertClaudeInstalled") }
    var alertClaudeInstallFailed: String { t("alertClaudeInstallFailed") }
    var alertCodexInstalled: String { t("alertCodexInstalled") }
    var alertCodexInstallFailed: String { t("alertCodexInstallFailed") }
    var alertGeminiInstalled: String { t("alertGeminiInstalled") }
    var alertGeminiInstallFailed: String { t("alertGeminiInstallFailed") }
    var alertAntigravityInstalled: String { t("alertAntigravityInstalled") }
    var alertAntigravityInstallFailed: String { t("alertAntigravityInstallFailed") }
    var alertInstallFailed: String { t("alertInstallFailed") }
    var alertAllInstalledMsg: String { t("alertAllInstalledMsg") }
    var alertBridgeInstalled: String { t("alertBridgeInstalled") }
    var alertClaudeRestartMsg: String { t("alertClaudeRestartMsg") }
    var alertCodexRestartMsg: String { t("alertCodexRestartMsg") }
    var alertGeminiRestartMsg: String { t("alertGeminiRestartMsg") }
    var alertAntigravityRestartMsg: String { t("alertAntigravityRestartMsg") }
    var alertBundleNoScript: String { t("alertBundleNoScript") }
    var alertBundleNoHelper: String { t("alertBundleNoHelper") }
    var alertBundleNoManifest: String { t("alertBundleNoManifest") }
    var alertBundleNoInstaller: String { t("alertBundleNoInstaller") }
    func alertInstallScriptFailed(_ detail: String) -> String { tf("alertInstallScriptFailed", detail) }
    var alertBadJSON: String { t("alertBadJSON") }
    func alertBadFile(_ name: String) -> String { tf("alertBadFile", name) }

    // MARK: Alerts — remove
    var alertAllRemoved: String { t("alertAllRemoved") }
    var alertAllRemovedMsg: String { t("alertAllRemovedMsg") }
    var alertSomeRemoveFailed: String { t("alertSomeRemoveFailed") }
    var alertClaudeRemoved: String { t("alertClaudeRemoved") }
    var alertClaudeRemoveFailed: String { t("alertClaudeRemoveFailed") }
    var alertCodexRemoved: String { t("alertCodexRemoved") }
    var alertCodexRemoveFailed: String { t("alertCodexRemoveFailed") }
    var alertGeminiRemoved: String { t("alertGeminiRemoved") }
    var alertGeminiRemoveFailed: String { t("alertGeminiRemoveFailed") }
    var alertAntigravityRemoved: String { t("alertAntigravityRemoved") }
    var alertAntigravityRemoveFailed: String { t("alertAntigravityRemoveFailed") }
    var alertHooksRemoved: String { t("alertHooksRemoved") }
    var alertClaudeHooksRemoved: String { t("alertClaudeHooksRemoved") }
    var alertCodexHooksRemoved: String { t("alertCodexHooksRemoved") }
    var alertGeminiHooksRemoved: String { t("alertGeminiHooksRemoved") }
    var alertAntigravityHooksRemoved: String { t("alertAntigravityHooksRemoved") }
    var alertOK: String { t("alertOK") }

    // MARK: Alerts — AppRelocator
    var relocateTitle: String { t("relocateTitle") }
    var relocateMessage: String { t("relocateMessage") }
    var relocateMoveBtn: String { t("relocateMoveBtn") }
    var relocateLaterBtn: String { t("relocateLaterBtn") }
    var relocateFailTitle: String { t("relocateFailTitle") }
    var relocateNoPermMsg: String { t("relocateNoPermMsg") }
    func relocateErrMsg(_ err: String) -> String { tf("relocateErrMsg", err) }
    var dmgCleanTitle: String { t("dmgCleanTitle") }
    var dmgCleanMessage: String { t("dmgCleanMessage") }
    var dmgCleanBtn: String { t("dmgCleanBtn") }
    var dmgNoBtn: String { t("dmgNoBtn") }
    var dmgEjectFailTitle: String { t("dmgEjectFailTitle") }
    var dmgEjectFailMsg: String { t("dmgEjectFailMsg") }

    // MARK: Alerts — UpdateChecker
    var updateAvailableTitle: String { t("updateAvailableTitle") }
    var updateChangeLogTitle: String { t("updateChangeLogTitle") }
    func updateAvailableMsg(_ v: String) -> String { tf("updateAvailableMsg", v) }
    var updateInstallBtn: String { t("updateInstallBtn") }
    var updateLaterBtn: String { t("updateLaterBtn") }
    var updateUpToDateTitle: String { t("updateUpToDateTitle") }
    func updateUpToDateMsg(_ v: String) -> String { tf("updateUpToDateMsg", v) }
    var updateDownloading: String { t("updateDownloading") }
    var updateInstalling: String { t("updateInstalling") }
    var updateRelaunching: String { t("updateRelaunching") }
    var updateFailedTitle: String { t("updateFailedTitle") }
    var updateCheckFailedTitle: String { t("updateCheckFailedTitle") }
    var updateInvalidResponseMsg: String { t("updateInvalidResponseMsg") }
    var updateNoAssetMsg: String { t("updateNoAssetMsg") }

    // MARK: Settings Window
    var winSettings: String { t("winSettings") }
    var winApprovalRules: String { t("winApprovalRules") }
    var winReplayLog: String { t("winReplayLog") }
    var winPTYTranscript: String { t("winPTYTranscript") }
    var winSessionHistory: String { t("winSessionHistory") }

    // Tab labels
    var tabGeneral: String { t("tabGeneral") }
    var tabIsland: String { t("tabIsland") }
    var tabApproval: String { t("tabApproval") }
    var tabProviders: String { t("tabProviders") }
    var tabBridge: String { t("tabBridge") }
    var tabExperimental: String { t("tabExperimental") }
    var tabDiagnostics: String { t("tabDiagnostics") }
    var tabIntegrations: String { t("tabIntegrations") }
    var tabExtras: String { t("tabExtras") }
    var tabAdvanced: String { t("tabAdvanced") }
    var tabPlugins: String { t("tabPlugins") }

    // Diagnostics pane
    var secBridgeScript: String { t("secBridgeScript") }
    var lblBridgeInstallPath: String { t("lblBridgeInstallPath") }
    var lblBridgeFileFound: String { t("lblBridgeFileFound") }
    var lblBridgeFileNotFound: String { t("lblBridgeFileNotFound") }
    var secHookStatus: String { t("secHookStatus") }
    var lblHookInstalled: String { t("lblHookInstalled") }
    var lblHookNotInstalled: String { t("lblHookNotInstalled") }
    var lblHookFileMissing: String { t("lblHookFileMissing") }
    var secLastEvent: String { t("secLastEvent") }
    var lblNoEventYet: String { t("lblNoEventYet") }
    var secBridgeLog: String { t("secBridgeLog") }
    var secBridgeLogEmpty: String { t("secBridgeLogEmpty") }
    var btnDiagRefresh: String { t("btnDiagRefresh") }

    // Plugins (settings tab)
    var pluginsEmpty: String { t("pluginsEmpty") }
    var pluginsListHeader: String { t("pluginsListHeader") }
    var lblPluginSafemode: String { t("lblPluginSafemode") }
    var btnPluginReset: String { t("btnPluginReset") }
    var btnPluginResetStorage: String { t("btnPluginResetStorage") }
    var msgPluginResetStorageConfirm: String { t("msgPluginResetStorageConfirm") }
    func pluginFailures(_ count: Int) -> String { tf("pluginFailures", count) }
    var lblPluginSettings: String { t("lblPluginSettings") }

    // Caffeine (Extras section)
    var secCaffeineStatus: String { t("secCaffeineStatus") }
    var secCaffeineBehavior: String { t("secCaffeineBehavior") }
    var secCaffeineExcludedSSIDs: String { t("secCaffeineExcludedSSIDs") }
    var lblCaffeineEnabled: String { t("lblCaffeineEnabled") }
    var lblCurrentSSID: String { t("lblCurrentSSID") }
    var lblOnAC: String { t("lblOnAC") }
    var lblBatteryLevel: String { t("lblBatteryLevel") }
    var lblHoldingAssertion: String { t("lblHoldingAssertion") }
    var btnAddSSID: String { t("btnAddSSID") }
    var lblScanNearbyWifi: String { t("lblScanNearbyWifi") }
    var lblConnectedSSID: String { t("lblConnectedSSID") }
    var lblManualSSIDEntry: String { t("lblManualSSIDEntry") }
    var lblScanFailed: String { t("lblScanFailed") }
    var lblScanErrorPermission: String { t("lblScanErrorPermission") }
    var lblScanErrorRadioOff: String { t("lblScanErrorRadioOff") }
    func lblScanErrorUnknown(_ detail: String) -> String { tf("lblScanErrorUnknown", detail) }
    var btnOpenLocationSettings: String { t("btnOpenLocationSettings") }
    var hintCaffeineRule: String { t("hintCaffeineRule") }
    var secCaffeineSessionTimeout: String { t("secCaffeineSessionTimeout") }
    var lblCaffeineSessionTimeoutEnabled: String { t("lblCaffeineSessionTimeoutEnabled") }
    func lblCaffeineSessionTimeoutMinutes(_ n: Int) -> String { tf("lblCaffeineSessionTimeoutMinutes", n) }
    var hintCaffeineSessionTimeout: String { t("hintCaffeineSessionTimeout") }
    var menuCaffeineToggle: String { t("menuCaffeineToggle") }
    var menuCaffeineOnAC: String { t("menuCaffeineOnAC") }
    var menuCaffeineOff: String { t("menuCaffeineOff") }
    var menuCaffeineOnBattery: String { t("menuCaffeineOnBattery") }
    var menuCaffeineLowBattery: String { t("menuCaffeineLowBattery") }
    func menuCaffeineExcludedSSID(_ ssid: String) -> String { tf("menuCaffeineExcludedSSID", ssid) }
    func menuCaffeineFailure(_ code: Int32) -> String { tf("menuCaffeineFailure", code) }

    // Integrations tab
    var secAppIntegrations: String { t("secAppIntegrations") }
    var lblProcessVSCode: String { t("lblProcessVSCode") }
    var descProcessVSCode: String { t("descProcessVSCode") }
    var lblProcessClaudeDesktop: String { t("lblProcessClaudeDesktop") }
    var descProcessClaudeDesktop: String { t("descProcessClaudeDesktop") }
    var lblProcessCodexDesktop: String { t("lblProcessCodexDesktop") }
    var descProcessCodexDesktop: String { t("descProcessCodexDesktop") }

    // General tab
    var btnResetAllSettings: String { t("btnResetAllSettings") }
    var secLanguage: String { t("secLanguage") }
    var lblLanguage: String { t("lblLanguage") }
    var secPreferredTerminal: String { t("secPreferredTerminal") }
    var lblPreferredTerminal: String { t("lblPreferredTerminal") }
    var optTerminalSessionDefault: String { t("optTerminalSessionDefault") }
    var hintPreferredTerminal: String { t("hintPreferredTerminal") }
    var secAoEFocus: String { t("secAoEFocus") }
    var lblAoEFocusMode: String { t("lblAoEFocusMode") }
    var hintAoEFocusMode: String { t("hintAoEFocusMode") }
    var aoeFocusTmuxClient: String { t("aoeFocusTmuxClient") }
    var aoeFocusManagerSearch: String { t("aoeFocusManagerSearch") }
    var detailAoEFocusTmuxClient: String { t("detailAoEFocusTmuxClient") }
    var detailAoEFocusManagerSearch: String { t("detailAoEFocusManagerSearch") }
    var secStartup: String { t("secStartup") }
    var lblLaunchAtLogin: String { t("lblLaunchAtLogin") }
    var lblLaunchAtLoginApproval: String { t("lblLaunchAtLoginApproval") }
    var btnOpenLoginSettings: String { t("btnOpenLoginSettings") }
    var alertLaunchAtLoginFailed: String { t("alertLaunchAtLoginFailed") }
    var secUpdates: String { t("secUpdates") }
    var lblCheckForUpdatesOnStartup: String { t("lblCheckForUpdatesOnStartup") }
    var lblReleaseChannel: String { t("lblReleaseChannel") }
    var releaseChannelStable: String { t("releaseChannelStable") }
    var releaseChannelNightly: String { t("releaseChannelNightly") }
    var secSounds: String { t("secSounds") }
    var lblMuteAllSounds: String { t("lblMuteAllSounds") }
    var secNotifications: String { t("secNotifications") }
    var lblNotificationsEnabled: String { t("lblNotificationsEnabled") }
    var descNotificationsEnabled: String { t("descNotificationsEnabled") }
    var notifActionApprove: String { t("notifActionApprove") }
    var notifActionDeny: String { t("notifActionDeny") }
    var notifApprovalBody: String { t("notifApprovalBody") }
    var notifTaskCompleteTitle: String { t("notifTaskCompleteTitle") }
    func notifTaskCompleteBody(_ title: String) -> String {
        title.isEmpty ? t("notifTaskCompleteBodyEmpty") : tf("notifTaskCompleteBody", title)
    }

    // Island tab
    var secNotch: String { t("secNotch") }
    var lblDisplay: String { t("lblDisplay") }
    var lblMonitor: String { t("lblMonitor") }
    var lblShowFullScreen: String { t("lblShowFullScreen") }
    func lblPanelOpacity(_ percent: Int) -> String { tf("lblPanelOpacity", percent) }
    var lblNotchShadow: String { t("lblNotchShadow") }
    var lblNotchAnimation: String { t("lblNotchAnimation") }
    func lblAnimationSpeed(_ value: Double) -> String { tf("lblAnimationSpeed", value) }
    var lblNotchShapeStyle: String { t("lblNotchShapeStyle") }
    var notchShapeClassic: String { t("notchShapeClassic") }
    var notchShapeDynamicIsland: String { t("notchShapeDynamicIsland") }
    func lblCollapsedNotchWidth(_ px: Int) -> String { tf("lblCollapsedNotchWidth", px) }
    func lblCollapsedNotchHeight(_ px: Int) -> String { tf("lblCollapsedNotchHeight", px) }
    func lblExpandedNotchWidth(_ px: Int) -> String { tf("lblExpandedNotchWidth", px) }
    func lblExpandedNotchHeight(_ px: Int) -> String { tf("lblExpandedNotchHeight", px) }
    var lblNotchAutoExpand: String { t("lblNotchAutoExpand") }
    var lblUnreadDotPosition: String { t("lblUnreadDotPosition") }
    var posLeft: String { t("posLeft") }
    var posCenter: String { t("posCenter") }
    var posRight: String { t("posRight") }
    var lblNotchAutoCollapse: String { t("lblNotchAutoCollapse") }
    var secNotchAutoExpand: String { t("secNotchAutoExpand") }
    var secNotchExpandTriggers: String { t("secNotchExpandTriggers") }
    var lblExpandOnNotification: String { t("lblExpandOnNotification") }
    var lblExpandOnTaskCompletion: String { t("lblExpandOnTaskCompletion") }
    var lblExpandOnIdlePrompt: String { t("lblExpandOnIdlePrompt") }
    var lblExpandOnNotificationMessage: String { t("lblExpandOnNotificationMessage") }
    var lblExpandOnInteractiveTool: String { t("lblExpandOnInteractiveTool") }
    var lblExpandOnApprovalRequest: String { t("lblExpandOnApprovalRequest") }
    var lblExpandOnQuestionResponse: String { t("lblExpandOnQuestionResponse") }
    var hintExpandOnNotification: String { t("hintExpandOnNotification") }
    var hintExpandOnTaskCompletion: String { t("hintExpandOnTaskCompletion") }
    var hintExpandOnIdlePrompt: String { t("hintExpandOnIdlePrompt") }
    var hintExpandOnNotificationMessage: String { t("hintExpandOnNotificationMessage") }
    var hintExpandOnInteractiveTool: String { t("hintExpandOnInteractiveTool") }
    var hintExpandOnApprovalRequest: String { t("hintExpandOnApprovalRequest") }
    var hintExpandOnQuestionResponse: String { t("hintExpandOnQuestionResponse") }
    var secNotchCharacters: String { t("secNotchCharacters") }
    var lblLeftCharacter: String { t("lblLeftCharacter") }
    var lblRightCharacter: String { t("lblRightCharacter") }
    var lblCharacter: String { t("lblCharacter") }
    var lblRandomIncludes: String { t("lblRandomIncludes") }
    func lblCharacterHorizontalInset(_ px: Int) -> String { tf("lblCharacterHorizontalInset", px) }
    func lblCharacterVerticalOffset(_ px: Int) -> String { tf("lblCharacterVerticalOffset", px) }
    var lblNotchCenterText: String { t("lblNotchCenterText") }
    var secRequests: String { t("secRequests") }
    var lblRequestDisplay: String { t("lblRequestDisplay") }

    // Approval tab
    var secAutoApprovals: String { t("secAutoApprovals") }
    var lblAutoSafe: String { t("lblAutoSafe") }
    var lblGeminiEmulate: String { t("lblGeminiEmulate") }
    var secPermissionTimeout: String { t("secPermissionTimeout") }
    func lblPermissionTimeout(_ n: Int) -> String { tf("lblPermissionTimeout", n) }
    var secReplayRetention: String { t("secReplayRetention") }
    func lblReplayRetention(_ n: Int) -> String { tf("lblReplayRetention", n) }
    var secFallback: String { t("secFallback") }
    var lblFallbackPolicy: String { t("lblFallbackPolicy") }

    // Providers tab
    var lblSessionApproval: String { t("lblSessionApproval") }
    var lblPersistentDest: String { t("lblPersistentDest") }
    var warnProjectSettings: String { t("warnProjectSettings") }
    var descCodex: String { t("descCodex") }
    var descGemini: String { t("descGemini") }

    // Bridge/IPC tab
    var secTransport: String { t("secTransport") }
    var lblTransport: String { t("lblTransport") }
    var descTransport: String { t("descTransport") }
    var secTCP: String { t("secTCP") }
    var lblPort: String { t("lblPort") }
    var secUnixSocket: String { t("secUnixSocket") }
    var lblSocketPath: String { t("lblSocketPath") }
    var lblFallbackTCP: String { t("lblFallbackTCP") }
    var secTimeouts: String { t("secTimeouts") }
    var lblConnectTimeout: String { t("lblConnectTimeout") }
    var lblResponseTimeout: String { t("lblResponseTimeout") }
    func labelSeconds(_ n: Int) -> String { tf("labelSeconds", n) }
    var secTokenSecurity: String { t("secTokenSecurity") }
    var warnGraceMode: String { t("warnGraceMode") }
    var hintGraceModeResolve: String { t("hintGraceModeResolve") }

    // Sound tab
    var secOpenPeonSoundPacks: String { t("secOpenPeonSoundPacks") }
    var lblOpenPeonEnable: String { t("lblOpenPeonEnable") }
    var phOpenPeonPacksFolder: String { t("phOpenPeonPacksFolder") }
    var btnReload: String { t("btnReload") }
    var btnOpen: String { t("btnOpen") }
    var btnPlayPreview: String { t("btnPlayPreview") }
    var lblOpenPeonActivePack: String { t("lblOpenPeonActivePack") }
    var lblOpenPeonFirstValidPack: String { t("lblOpenPeonFirstValidPack") }
    var lblOpenPeonNoPacks: String { t("lblOpenPeonNoPacks") }
    var lblOpenPeonNoSoundFile: String { t("lblOpenPeonNoSoundFile") }
    var secOpenPeonPlayback: String { t("secOpenPeonPlayback") }
    var lblOpenPeonMasterVolume: String { t("lblOpenPeonMasterVolume") }
    func lblOpenPeonDebounce(_ ms: Int) -> String { tf("lblOpenPeonDebounce", ms) }
    var secOpenPeonCategories: String { t("secOpenPeonCategories") }
    var secOpenPeonValidation: String { t("secOpenPeonValidation") }
    var lblOpenPeonValid: String { t("lblOpenPeonValid") }
    func errOpenPeonReadPacks(_ path: String) -> String { tf("errOpenPeonReadPacks", path) }

    // OpenPeon CESP category labels
    var cespSessionStart: String { t("cespSessionStart") }
    var cespTaskAcknowledge: String { t("cespTaskAcknowledge") }
    var cespTaskComplete: String { t("cespTaskComplete") }
    var cespTaskError: String { t("cespTaskError") }
    var cespInputRequired: String { t("cespInputRequired") }
    var cespResourceLimit: String { t("cespResourceLimit") }
    var cespUserSpam: String { t("cespUserSpam") }
    var cespSessionEnd: String { t("cespSessionEnd") }
    var cespTaskProgress: String { t("cespTaskProgress") }

    // Experimental tab
    var secPTYWrapper: String { t("secPTYWrapper") }
    var lblPTYEnable: String { t("lblPTYEnable") }
    func lblRetention(_ n: Int) -> String { tf("lblRetention", n) }
    var btnViewPTY: String { t("btnViewPTY") }
    var secAutoInject: String { t("secAutoInject") }
    var lblNoPatterns: String { t("lblNoPatterns") }
    var phPattern: String { t("phPattern") }
    var phResponse: String { t("phResponse") }
    var btnAdd: String { t("btnAdd") }
    var secUsage: String { t("secUsage") }
    var descPTYUsage: String { t("descPTYUsage") }
    var descPTYHooks: String { t("descPTYHooks") }

    // Approval Rules window
    var secCodexRules: String { t("secCodexRules") }
    var phToolName: String { t("phToolName") }
    var lblAction: String { t("lblAction") }
    var lblAllow: String { t("lblAllow") }
    var lblDeny: String { t("lblDeny") }
    var btnExportSnapshot: String { t("btnExportSnapshot") }
    var lblNoCodexRules: String { t("lblNoCodexRules") }
    var secGlobalRules: String { t("secGlobalRules") }
    var descGlobalRules: String { t("descGlobalRules") }
    var alertAddGlobalToolTitle: String { t("alertAddGlobalToolTitle") }
    var alertAddGlobalToolMsg: String { t("alertAddGlobalToolMsg") }
    var alertAddSessionToolTitle: String { t("alertAddSessionToolTitle") }
    func alertAddSessionToolMsg(_ id: String) -> String { tf("alertAddSessionToolMsg", id) }
    var btnAddManually: String { t("btnAddManually") }
    var btnAddFromList: String { t("btnAddFromList") }
    var lblNoGlobalTools: String { t("lblNoGlobalTools") }
    var btnRemoveAllGlobal: String { t("btnRemoveAllGlobal") }
    var secSessionRules: String { t("secSessionRules") }
    var descSessionRules: String { t("descSessionRules") }
    var lblNoSessions: String { t("lblNoSessions") }
    var lblNoSessionTools: String { t("lblNoSessionTools") }
    var btnRemoveAllSession: String { t("btnRemoveAllSession") }
    func lblSession(_ id: String, _ count: Int) -> String { tf("lblSession", id, count) }
    func errSaveCodexRule(_ err: String) -> String { tf("errSaveCodexRule", err) }
    func errDeleteCodexRule(_ err: String) -> String { tf("errDeleteCodexRule", err) }
    func errLoadCodexRules(_ err: String) -> String { tf("errLoadCodexRules", err) }
    func exportedCodexRules(_ count: Int, _ path: String) -> String { tf("exportedCodexRules", count, path) }
    func errExportCodexRules(_ err: String) -> String { tf("errExportCodexRules", err) }
    func addAllRisk(_ name: String) -> String { tf("addAllRisk", name) }

    // IslandSettingsPane — monitor name
    func monitorMain() -> String { t("monitorMain") }
    func monitorN(_ n: Int) -> String { tf("monitorN", n) }

    // Enum labels — NotchDisplayTarget
    var notchAuto: String { t("notchAuto") }
    var notchMain: String { t("notchMain") }
    var notchMouse: String { t("notchMouse") }
    var notchFocused: String { t("notchFocused") }
    var notchSpecific: String { t("notchSpecific") }
    var notchCharacterHidden: String { t("notchCharacterHidden") }
    var notchCharacterRandom: String { t("notchCharacterRandom") }
    var notchCharacterSpecific: String { t("notchCharacterSpecific") }
    var notchAutoCollapseOff: String { t("notchAutoCollapseOff") }

    // Enum labels — RequestDisplayTarget
    var reqNotch: String { t("reqNotch") }
    var reqFocused: String { t("reqFocused") }
    var reqMouse: String { t("reqMouse") }

    // Enum labels — ClaudeSessionApprovalMode
    var modeNative: String { t("modeNative") }
    var modeCache: String { t("modeCache") }
    var modeHybrid: String { t("modeHybrid") }
    var detailNative: String { t("detailNative") }
    var detailCache: String { t("detailCache") }
    var detailHybrid: String { t("detailHybrid") }

    // Enum labels — ClaudePersistentApprovalDestination
    var destLocal: String { t("destLocal") }
    var destProject: String { t("destProject") }
    var destUser: String { t("destUser") }
    var detailDestLocal: String { t("detailDestLocal") }
    var detailDestProject: String { t("detailDestProject") }
    var detailDestUser: String { t("detailDestUser") }

    // Enum labels — BridgeTransportKind
    var transportTCP: String { t("transportTCP") }
    var transportUnix: String { t("transportUnix") }

    // Enum labels — ApprovalFallbackPolicy
    var fallbackPass: String { t("fallbackPass") }
    var fallbackDeny: String { t("fallbackDeny") }

    // Pop-out window
    var popOutWindow: String { t("popOutWindow") }
    var sessionEnded: String { t("sessionEnded") }
    var msgWaiting: String { t("msgWaiting") }
    var approvingOtherSession: String { t("approvingOtherSession") }

    // Notch UI
    var notchApprovalRequired: String { t("notchApprovalRequired") }
    var notchNotification: String { t("notchNotification") }
    var notchMonitoring: String { t("notchMonitoring") }
    var notchActiveAction: String { t("notchActiveAction") }
    var notchAgentSessions: String { t("notchAgentSessions") }
    var notchListening: String { t("notchListening") }
    var terminalWaiting: String { t("terminalWaiting") }
    func terminalCheckMsg(_ tool: String) -> String { tf("terminalCheckMsg", tool) }
    var notchSessions: String { t("notchSessions") }
    var notchFocus: String { t("notchFocus") }
    var notchDenyRequest: String { t("notchDenyRequest") }
    var notchApprove: String { t("notchApprove") }
    var notchAutoApproveSession: String { t("notchAutoApproveSession") }
    var notchAlwaysAutoApprove: String { t("notchAlwaysAutoApprove") }
    var notchAlwaysAllowSuggestion: String { t("notchAlwaysAllowSuggestion") }
    func notchAlwaysAllowSuggestionHelp(_ tool: String) -> String { tf("notchAlwaysAllowSuggestionHelp", tool) }
    var notchFocusTerminal: String { t("notchFocusTerminal") }
    var notchDismiss: String { t("notchDismiss") }
    var notchUnknown: String { t("notchUnknown") }
    var helpOpenSettings: String { t("helpOpenSettings") }
    var helpFocusTerminal: String { t("helpFocusTerminal") }
    var helpDismissSession: String { t("helpDismissSession") }
    var menuOpenInFinder: String { t("menuOpenInFinder") }
    var menuCopyPath: String { t("menuCopyPath") }
    var menuCopyResumeCommand: String { t("menuCopyResumeCommand") }
    var menuRenameSession: String { t("menuRenameSession") }
    var menuEditSessionDescription: String { t("menuEditSessionDescription") }
    var menuAddFavorite: String { t("menuAddFavorite") }
    var menuRemoveFavorite: String { t("menuRemoveFavorite") }
    var renameSessionTitle: String { t("renameSessionTitle") }
    var renameSessionConfirm: String { t("renameSessionConfirm") }
    var renameSessionPlaceholder: String { t("renameSessionPlaceholder") }
    var sessionDescriptionTitle: String { t("sessionDescriptionTitle") }
    var sessionDescriptionConfirm: String { t("sessionDescriptionConfirm") }
    var btnCancel: String { t("btnCancel") }
    func renameSessionHint(_ id: String) -> String { tf("renameSessionHint", id) }
    func sessionDescriptionHint(_ id: String) -> String { tf("sessionDescriptionHint", id) }
    var menuOpenInTerminal: String { t("menuOpenInTerminal") }
    func menuTerminalAuto(_ name: String) -> String { tf("menuTerminalAuto", name) }
    var menuStartNewSession: String { t("menuStartNewSession") }
    var menuTerminalInfo: String { t("menuTerminalInfo") }
    var helpDismissPending: String { t("helpDismissPending") }
    func tasksQueued(_ n: Int) -> String { tf("tasksQueued", n) }
    func timeJustNow() -> String { t("timeJustNow") }
    func timeSecsAgo(_ n: Int) -> String { tf("timeSecsAgo", n) }
    func timeMinsAgo(_ n: Int) -> String { tf("timeMinsAgo", n) }

    // Session History Window tabs
    var historyTabSessions: String { t("historyTabSessions") }
    var historyTabInsights: String { t("historyTabInsights") }

    // Session Insights View
    var insightsTodaySessions: String { t("insightsTodaySessions") }
    var insightsTotalSessions: String { t("insightsTotalSessions") }
    var insightsAvgDuration: String { t("insightsAvgDuration") }
    var insightsApprovals: String { t("insightsApprovals") }
    var insightsManualApproved: String { t("insightsManualApproved") }
    var insightsManualDenied: String { t("insightsManualDenied") }
    var insightsAutoApproved: String { t("insightsAutoApproved") }
    var insightsAutoDenied: String { t("insightsAutoDenied") }
    var insightsTopTools: String { t("insightsTopTools") }
    var insightsNoData: String { t("insightsNoData") }
    var insightsRetentionNote: String { t("insightsRetentionNote") }
    func insightsDuration(_ s: String) -> String { tf("insightsDuration", s) }

    // Session History Window
    var historySearch: String { t("historySearch") }
    var historyEmpty: String { t("historyEmpty") }
    var historyFilterAll: String { t("historyFilterAll") }
    var historyFilterFavorites: String { t("historyFilterFavorites") }
    var historyRefresh: String { t("historyRefresh") }
    var historyColFavorite: String { t("historyColFavorite") }
    var historyColStatus: String { t("historyColStatus") }
    var historyColAgent: String { t("historyColAgent") }
    var historyColPath: String { t("historyColPath") }
    var historyColLabel: String { t("historyColLabel") }
    var historyColDescription: String { t("historyColDescription") }
    var historyColTitle: String { t("historyColTitle") }
    var historyColEnded: String { t("historyColEnded") }
    var historyColSession: String { t("historyColSession") }
    var historyStatusLive: String { t("historyStatusLive") }
    var historyStatusEnded: String { t("historyStatusEnded") }
    func historyCount(_ n: Int) -> String { tf("historyCount", n) }

    // Session status labels
    var statusPending: String { t("statusPending") }
    var statusBypassed: String { t("statusBypassed") }
    var statusAutoApproved: String { t("statusAutoApproved") }
    var statusPolicyApproved: String { t("statusPolicyApproved") }
    var statusPolicyDenied: String { t("statusPolicyDenied") }
    var statusAutoEdit: String { t("statusAutoEdit") }
}
