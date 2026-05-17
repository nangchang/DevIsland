import Foundation
import Combine

// MARK: - Language

enum AppLanguage: String, CaseIterable, Identifiable {
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
}

// MARK: - L10n

final class L10n: ObservableObject {
    static let shared = L10n()

    private static let defaultsKey = "appLanguage"

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
        switch language {
        case .system:  return Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        case .english: return false
        case .korean:  return true
        }
    }

    func s(_ en: String, _ ko: String) -> String { isKorean ? ko : en }
}

// MARK: - String constants

extension L10n {

    // MARK: Menu Bar
    var menuNoPending:          String { s("No pending requests",        "대기 중인 요청 없음") }
    var menuPending:            String { s("Requests pending",           "요청 대기 중") }
    var menuFocusTerminal:      String { s("Focus Terminal",             "터미널 포커스") }
    var menuApprove:            String { s("Approve  ⌘⇧Y",              "승인  ⌘⇧Y") }
    var menuDeny:               String { s("Deny  ⌘⇧N",                 "거부  ⌘⇧N") }
    var menuSettings:           String { s("Settings…",                  "설정…") }
    var menuApprovalRules:      String { s("Approval Rules…",            "승인 규칙…") }
    var menuReplayLog:          String { s("Replay Log…",                "재실행 로그…") }
    var menuPTYTranscript:      String { s("PTY Transcript…",            "PTY 트랜스크립트…") }
    var menuInstallHooks:       String { s("Install / Repair Hooks",     "훅 설치 / 수리") }
    var menuInstallAll:         String { s("Install All (Claude · Codex · Gemini)",    "전부 설치 (Claude · Codex · Gemini)") }
    var menuInstallClaude:      String { s("Install Claude Code only…",  "Claude Code만 설치…") }
    var menuInstallCodex:       String { s("Install Codex CLI only…",    "Codex CLI만 설치…") }
    var menuInstallGemini:      String { s("Install Gemini CLI only…",   "Gemini CLI만 설치…") }
    var menuRemoveAll:          String { s("Remove All (Claude · Codex · Gemini)",     "전부 제거 (Claude · Codex · Gemini)") }
    var menuRemoveClaude:       String { s("Remove Claude Code only…",   "Claude Code만 제거…") }
    var menuRemoveCodex:        String { s("Remove Codex CLI only…",     "Codex CLI만 제거…") }
    var menuRemoveGemini:       String { s("Remove Gemini CLI only…",    "Gemini CLI만 제거…") }
    var menuAccessibility:      String { s("Request Accessibility Permission…", "접근성 권한 요청…") }
    var menuQuit:               String { s("Quit DevIsland",             "DevIsland 종료") }

    // MARK: Alerts — install
    var alertClaudeInstalled:      String { s("Claude Code Installed",          "Claude Code 설치 완료") }
    var alertClaudeInstallFailed:  String { s("Claude Code Installation Failed","Claude Code 설치 실패") }
    var alertCodexInstalled:       String { s("Codex CLI Installed",            "Codex CLI 설치 완료") }
    var alertCodexInstallFailed:   String { s("Codex CLI Installation Failed",  "Codex CLI 설치 실패") }
    var alertGeminiInstalled:      String { s("Gemini CLI Installed",           "Gemini CLI 설치 완료") }
    var alertGeminiInstallFailed:  String { s("Gemini CLI Installation Failed", "Gemini CLI 설치 실패") }
    var alertInstallFailed:        String { s("Installation Failed",            "설치 실패") }
    var alertBridgeInstalled:      String { s("Bridge installed.\nRestart your session.",
                                              "브리지가 설치되었습니다.\n세션을 재시작해주세요.") }
    var alertClaudeRestartMsg:     String { s("Bridge installed.\nRestart your Claude Code session.",
                                              "브리지가 설치되었습니다.\nClaude Code 세션을 재시작해주세요.") }
    var alertCodexRestartMsg:      String { s("Bridge installed.\nRestart your Codex CLI session.",
                                              "브리지가 설치되었습니다.\nCodex CLI 세션을 재시작해주세요.") }
    var alertGeminiRestartMsg:     String { s("Bridge installed.\nRestart your Gemini CLI session.",
                                              "브리지가 설치되었습니다.\nGemini CLI 세션을 재시작해주세요.") }
    var alertBundleNoScript:       String { s("Bridge script not found in app bundle.",
                                              "앱 번들에서 브리지 스크립트를 찾을 수 없습니다.") }
    var alertBundleNoHelper:       String { s("Bridge helper not found in app bundle.",
                                              "앱 번들에서 브리지 helper를 찾을 수 없습니다.") }
    var alertBadJSON:              String { s("Failed to parse settings.json: invalid JSON format.",
                                              "settings.json 파싱 실패: 유효하지 않은 JSON 형식입니다.") }
    func alertBadFile(_ name: String) -> String { s("Failed to parse \(name)", "\(name) 파싱 실패") }

    // MARK: Alerts — remove
    var alertAllRemoved:          String { s("All Removed",               "전체 제거 완료") }
    var alertAllRemovedMsg:       String { s("All bridge hooks removed.\nRestart each CLI session.",
                                             "모든 브리지 훅이 제거되었습니다.\n각 CLI 세션을 재시작해주세요.") }
    var alertSomeRemoveFailed:    String { s("Some Removals Failed",       "일부 제거 실패") }
    var alertClaudeRemoved:       String { s("Claude Code Removed",        "Claude Code 제거 완료") }
    var alertClaudeRemoveFailed:  String { s("Claude Code Removal Failed", "Claude Code 제거 실패") }
    var alertCodexRemoved:        String { s("Codex CLI Removed",          "Codex CLI 제거 완료") }
    var alertCodexRemoveFailed:   String { s("Codex CLI Removal Failed",   "Codex CLI 제거 실패") }
    var alertGeminiRemoved:       String { s("Gemini CLI Removed",         "Gemini CLI 제거 완료") }
    var alertGeminiRemoveFailed:  String { s("Gemini CLI Removal Failed",  "Gemini CLI 제거 실패") }
    var alertHooksRemoved:        String { s("Hooks removed.\nRestart your session.",
                                             "훅이 제거되었습니다.\n세션을 재시작해주세요.") }
    var alertClaudeHooksRemoved:  String { s("Hooks removed.\nRestart your Claude Code session.",
                                             "훅이 제거되었습니다.\nClaude Code 세션을 재시작해주세요.") }
    var alertCodexHooksRemoved:   String { s("Hooks removed.\nRestart your Codex CLI session.",
                                             "훅이 제거되었습니다.\nCodex CLI 세션을 재시작해주세요.") }
    var alertGeminiHooksRemoved:  String { s("Hooks removed.\nRestart your Gemini CLI session.",
                                             "훅이 제거되었습니다.\nGemini CLI 세션을 재시작해주세요.") }
    var alertOK:                  String { s("OK", "확인") }

    // MARK: Alerts — AppRelocator
    var relocateTitle:       String { s("Move to Applications Folder?",          "응용 프로그램 폴더로 이동하시겠습니까?") }
    var relocateMessage:     String { s("Move DevIsland to the Applications folder to continue using it.",
                                        "DevIsland를 응용 프로그램 폴더로 이동하여 계속 사용하시겠습니까?") }
    var relocateMoveBtn:     String { s("Move and Relaunch",                     "이동 및 다시 실행") }
    var relocateLaterBtn:    String { s("Later",                                 "나중에") }
    var relocateFailTitle:   String { s("Move Failed",                           "이동 실패") }
    var relocateNoPermMsg:   String { s("No write permission for the Applications folder. Please move manually using Finder.",
                                        "응용 프로그램 폴더에 쓰기 권한이 없습니다. Finder에서 직접 이동해주세요.") }
    func relocateErrMsg(_ err: String) -> String {
        s("An error occurred while moving the app: \(err)", "앱을 이동하는 중 오류가 발생했습니다: \(err)")
    }
    var dmgCleanTitle:       String { s("Clean Up Installer?",                   "설치 파일을 정리하시겠습니까?") }
    var dmgCleanMessage:     String { s("Installation is complete. Would you like to eject and clean up the installer (DMG)?",
                                        "설치가 완료되었습니다. 사용 중인 설치 파일(DMG)을 꺼내고 정리하시겠습니까?") }
    var dmgCleanBtn:         String { s("Clean Up",                              "정리") }
    var dmgNoBtn:            String { s("No",                                    "아니요") }
    var dmgEjectFailTitle:   String { s("Eject Failed",                          "꺼내기 실패") }
    var dmgEjectFailMsg:     String { s("Failed to eject the installer. Please eject manually from Finder.",
                                        "설치 파일을 꺼내는 중 오류가 발생했습니다. Finder에서 직접 꺼내주세요.") }

    // MARK: Settings Window
    var winSettings:         String { s("DevIsland Settings",  "DevIsland 설정") }
    var winApprovalRules:    String { s("Approval Rules",       "승인 규칙") }
    var winReplayLog:        String { s("Replay Log",           "재실행 로그") }
    var winPTYTranscript:    String { s("PTY Transcript",       "PTY 트랜스크립트") }

    // Tab labels
    var tabGeneral:          String { s("General",      "일반") }
    var tabDisplay:          String { s("Display",      "디스플레이") }
    var tabApproval:         String { s("Approval",     "승인") }
    var tabProviders:        String { s("Providers",    "공급자") }
    var tabBridge:           String { s("Bridge / IPC", "브리지 / IPC") }
    var tabOpenPeon:         String { s("OpenPeon",     "OpenPeon") }
    var tabExperimental:     String { s("Experimental", "실험적") }

    // General tab
    var secApprovalProxy:    String { s("Approval Proxy",               "승인 프록시") }
    var descApprovalProxy:   String { s("DevIsland intercepts AI agent tool requests and applies your approval rules before allowing or blocking each action.",
                                        "DevIsland가 AI 에이전트의 도구 요청을 가로채 승인 규칙을 적용한 후 각 작업을 허용하거나 차단합니다.") }
    var btnResetProxy:       String { s("Reset All Settings to Defaults", "모든 설정 초기화") }
    var secLanguage:         String { s("Language",                      "언어") }
    var lblLanguage:         String { s("Language",                      "언어") }

    // Display tab
    var secNotch:            String { s("Notch",                         "노치") }
    var lblDisplay:          String { s("Display",                       "표시") }
    var lblMonitor:          String { s("Monitor",                       "모니터") }
    var lblShowFullScreen:   String { s("Show above full-screen apps",   "전체화면 앱 위에 표시") }
    var secNotchCharacters:  String { s("Notch characters",              "노치 캐릭터") }
    var lblLeftCharacter:    String { s("Left character",                "왼쪽 캐릭터") }
    var lblRightCharacter:   String { s("Right character",               "오른쪽 캐릭터") }
    var lblCharacter:        String { s("Character",                     "캐릭터") }
    var lblRandomIncludes:   String { s("Random includes",               "랜덤 포함 캐릭터") }
    var secRequests:         String { s("Requests",                      "요청") }
    var lblRequestDisplay:   String { s("Request display",               "요청 표시") }

    // Approval tab
    var secAutoApprovals:    String { s("Automatic approvals",           "자동 승인") }
    var lblAutoSafe:         String { s("Auto-approve safe/read-only tools", "안전/읽기 전용 도구 자동 승인") }
    var lblGeminiEmulate:    String { s("Gemini interactive emulation",  "Gemini 대화형 에뮬레이션") }
    var secPermissionTimeout: String { s("Permission timeout",             "권한 요청 타임아웃") }
    func lblPermissionTimeout(_ n: Int) -> String { s("Auto-pass after \(n) seconds", "\(n)초 후 자동 패스") }
    var secReplayRetention:  String { s("Replay log retention",          "리플레이 로그 보관") }
    func lblReplayRetention(_ n: Int) -> String { s("Replay log: \(n) days", "리플레이 로그: \(n)일") }
    var secFallback:         String { s("Transport failure fallback",    "전송 실패 폴백") }
    var lblFallbackPolicy:   String { s("Fallback policy",               "폴백 정책") }

    // Providers tab
    var lblSessionApproval:  String { s("Session approval mode",         "세션 승인 모드") }
    var lblPersistentDest:   String { s("Persistent approval destination","영구 승인 대상") }
    var warnProjectSettings: String { s("Project settings can be committed to the repository. Review changes before committing.",
                                        "프로젝트 설정은 저장소에 커밋될 수 있습니다. 커밋 전에 변경 사항을 검토하세요.") }
    var descCodex:           String { s("Codex session approval will use DevIsland-managed cache and persistent SQLite rules in later phases.",
                                        "Codex 세션 승인은 이후 단계에서 DevIsland 관리 캐시와 영구 SQLite 규칙을 사용합니다.") }
    var descGemini:          String { s("Existing Gemini auto-edit, interactive notification, and safe-tool behavior remain compatible with Approval Proxy settings.",
                                        "기존 Gemini 자동 편집, 대화형 알림, 안전 도구 동작은 승인 프록시 설정과 호환됩니다.") }

    // Bridge/IPC tab
    var secTransport:        String { s("Transport",                     "전송") }
    var lblTransport:        String { s("Transport",                     "전송") }
    var descTransport:       String { s("Transport changes are written to the bridge runtime config. Restart DevIsland after switching listener transports.",
                                        "전송 변경 사항은 브리지 런타임 설정에 기록됩니다. 리스너 전송 방식 변경 후 DevIsland를 재시작하세요.") }
    var secTCP:              String { s("TCP",                           "TCP") }
    var lblPort:             String { s("Port",                          "포트") }
    var secUnixSocket:       String { s("Unix domain socket",            "Unix 도메인 소켓") }
    var lblSocketPath:       String { s("Socket path",                   "소켓 경로") }
    var lblFallbackTCP:      String { s("Fallback to TCP loopback",      "TCP 루프백으로 폴백") }
    var secTimeouts:         String { s("Timeouts",                      "타임아웃") }
    var lblConnectTimeout:   String { s("Connect timeout",               "연결 타임아웃") }
    var lblResponseTimeout:  String { s("Response timeout",              "응답 타임아웃") }
    func labelSeconds(_ n: Int) -> String { s("\(n) seconds", "\(n)초") }

    // OpenPeon tab
    var secOpenPeonSoundPacks:       String { s("Sound packs",                   "사운드팩") }
    var lblOpenPeonEnable:           String { s("Enable OpenPeon sounds",        "OpenPeon 사운드 활성화") }
    var lblOpenPeonMuteAll:          String { s("Mute all OpenPeon sounds",      "모든 OpenPeon 사운드 음소거") }
    var phOpenPeonPacksFolder:       String { s("Packs folder",                  "팩 폴더") }
    var btnReload:                   String { s("Reload",                        "다시 불러오기") }
    var btnOpen:                     String { s("Open",                          "열기") }
    var btnPlayPreview:              String { s("Play preview",                  "미리듣기 재생") }
    var lblOpenPeonActivePack:       String { s("Active pack",                   "활성 팩") }
    var lblOpenPeonFirstValidPack:   String { s("First valid pack",              "첫 번째 유효한 팩") }
    var lblOpenPeonNoPacks:          String { s("No OpenPeon packs found.",      "OpenPeon 팩을 찾을 수 없습니다.") }
    var lblOpenPeonNoSoundFile:      String { s("No sound file for this event",  "이 이벤트에 대한 사운드 파일이 없습니다") }
    var secOpenPeonPlayback:         String { s("Playback",                      "재생") }
    var lblOpenPeonMasterVolume:     String { s("Master volume",                 "마스터 볼륨") }
    func lblOpenPeonDebounce(_ ms: Int) -> String { s("Debounce: \(ms) ms", "디바운스: \(ms)ms") }
    var secOpenPeonCategories:       String { s("Categories",                    "카테고리") }
    var secOpenPeonValidation:       String { s("Validation",                    "검증") }
    var lblOpenPeonValid:            String { s("Valid",                         "유효함") }
    func errOpenPeonReadPacks(_ path: String) -> String {
        s("Could not read \(path)", "\(path)를 읽을 수 없습니다.")
    }

    // OpenPeon CESP category labels
    var cespSessionStart:     String { s("Session start",      "세션 시작") }
    var cespTaskAcknowledge:  String { s("Task acknowledge",   "작업 인지") }
    var cespTaskComplete:     String { s("Task complete",      "작업 완료") }
    var cespTaskError:        String { s("Task error",         "작업 오류") }
    var cespInputRequired:    String { s("Input required",     "입력 필요") }
    var cespResourceLimit:    String { s("Resource limit",     "리소스 제한") }
    var cespUserSpam:         String { s("User spam",          "사용자 반복 입력") }
    var cespSessionEnd:       String { s("Session end",        "세션 종료") }
    var cespTaskProgress:     String { s("Task progress",      "작업 진행") }

    // Experimental tab
    var secPTYWrapper:       String { s("PTY Wrapper",                   "PTY 래퍼") }
    var lblPTYEnable:        String { s("Enable PTY logging and auto-inject", "PTY 로깅 및 자동 주입 활성화") }
    func lblRetention(_ n: Int) -> String { s("Transcript retention: \(n) days", "트랜스크립트 보관: \(n)일") }
    var btnViewPTY:          String { s("View PTY Transcript…",          "PTY 트랜스크립트 보기…") }
    var secAutoInject:       String { s("Auto-inject patterns",          "자동 주입 패턴") }
    var lblNoPatterns:       String { s("No patterns. Add one below.",   "패턴 없음. 아래에서 추가하세요.") }
    var phPattern:           String { s("Pattern (substring)",           "패턴 (부분 문자열)") }
    var phResponse:          String { s("Response text",                 "응답 텍스트") }
    var btnAdd:              String { s("Add",                           "추가") }
    var secUsage:            String { s("Usage",                         "사용법") }
    var descPTYUsage:        String { s("Run a CLI agent through the PTY wrapper:", "CLI 에이전트를 PTY 래퍼를 통해 실행:") }
    var descPTYHooks:        String { s("The script forwards PTYOutput hook events to the app.",
                                        "스크립트가 PTYOutput 훅 이벤트를 앱으로 전달합니다.") }

    // Approval Rules window
    var secCodexRules:       String { s("Codex persistent SQLite rules",     "Codex 영구 SQLite 규칙") }
    var phToolName:          String { s("Tool name",                         "도구 이름") }
    var lblAction:           String { s("Action",                            "동작") }
    var lblAllow:            String { s("Allow",                             "허용") }
    var lblDeny:             String { s("Deny",                              "거부") }
    var btnExportSnapshot:   String { s("Export Snapshot",                   "스냅샷 내보내기") }
    var lblNoCodexRules:     String { s("No Codex persistent SQLite rules are configured.", "구성된 Codex 영구 SQLite 규칙이 없습니다.") }
    var secGlobalRules:      String { s("Global auto-approval tools",        "전역 자동 승인 도구") }
    var descGlobalRules:     String { s("These existing DevIsland rules are checked for every session before showing an approval prompt.",
                                        "이 DevIsland 규칙은 승인 프롬프트 표시 전 모든 세션에서 확인됩니다.") }
    var btnAddManually:      String { s("Add manually…",                     "직접 추가…") }
    var btnAddFromList:      String { s("Add from list",                     "목록에서 추가") }
    var lblNoGlobalTools:    String { s("No global auto-approval tools are configured.", "구성된 전역 자동 승인 도구가 없습니다.") }
    var btnRemoveAllGlobal:  String { s("Remove all global tools",           "전역 도구 모두 제거") }
    var secSessionRules:     String { s("Session auto-approval tools",       "세션 자동 승인 도구") }
    var descSessionRules:    String { s("Session rules remain available until the corresponding active session is removed.",
                                        "세션 규칙은 해당 활성 세션이 제거될 때까지 유지됩니다.") }
    var lblNoSessions:       String { s("No active sessions.",               "활성 세션 없음.") }
    var lblNoSessionTools:   String { s("No session auto-approval tools are configured.", "구성된 세션 자동 승인 도구가 없습니다.") }
    var btnRemoveAllSession: String { s("Remove all session tools",          "세션 도구 모두 제거") }
    func lblSession(_ id: String, _ count: Int) -> String {
        s("Session \(id) (\(count) tools)", "세션 \(id) (\(count)개 도구)")
    }
    func errSaveCodexRule(_ err: String) -> String { s("Failed to save Codex rule: \(err)", "Codex 규칙 저장 실패: \(err)") }
    func errDeleteCodexRule(_ err: String) -> String { s("Failed to delete Codex rule: \(err)", "Codex 규칙 삭제 실패: \(err)") }
    func errLoadCodexRules(_ err: String) -> String { s("Failed to load Codex rules: \(err)", "Codex 규칙 로드 실패: \(err)") }
    func exportedCodexRules(_ count: Int, _ path: String) -> String {
        s("Exported \(count) Codex rules to \(path)", "\(path)에 Codex 규칙 \(count)개 내보냄")
    }
    func errExportCodexRules(_ err: String) -> String { s("Failed to export Codex rules: \(err)", "Codex 규칙 내보내기 실패: \(err)") }
    func addAllRisk(_ name: String) -> String { s("Add all \(name) tools", "\(name) 도구 모두 추가") }

    // DisplaySettingsPane — monitor name
    func monitorMain() -> String { s("Main monitor", "주 모니터") }
    func monitorN(_ n: Int) -> String { s("Monitor \(n)", "모니터 \(n)") }

    // Enum labels — NotchDisplayTarget
    var notchAuto:     String { s("Automatic",               "자동") }
    var notchMain:     String { s("Main monitor",            "주 모니터") }
    var notchMouse:    String { s("Monitor with mouse",      "마우스가 있는 모니터") }
    var notchFocused:  String { s("Monitor with focus",      "포커스가 있는 모니터") }
    var notchSpecific: String { s("Selected monitor",        "선택한 모니터") }
    var notchCharacterRandom:   String { s("Random",         "랜덤") }
    var notchCharacterSpecific: String { s("Specific",       "지정") }

    // Enum labels — RequestDisplayTarget
    var reqNotch:   String { s("Notch display",  "노치 화면") }
    var reqFocused: String { s("Focus display",  "포커스 화면") }
    var reqMouse:   String { s("Mouse display",  "마우스 화면") }

    // Enum labels — ClaudeSessionApprovalMode
    var modeNative:   String { s("Native Claude permissions",            "Claude 기본 권한") }
    var modeCache:    String { s("DevIsland-managed session cache",      "DevIsland 관리 세션 캐시") }
    var modeHybrid:   String { s("Hybrid",                               "하이브리드") }
    var detailNative: String { s("Recommended. DevIsland returns updatedPermissions with destination=session.",
                                  "권장. DevIsland가 destination=session으로 updatedPermissions를 반환합니다.") }
    var detailCache:  String { s("DevIsland stores session-scoped approvals and returns simple allow responses.",
                                  "DevIsland가 세션 범위 승인을 저장하고 단순 허용 응답을 반환합니다.") }
    var detailHybrid: String { s("Use native Claude permissions first and keep DevIsland cache as fallback.",
                                  "Claude 기본 권한을 먼저 사용하고 DevIsland 캐시를 폴백으로 유지합니다.") }

    // Enum labels — ClaudePersistentApprovalDestination
    var destLocal:   String { s("localSettings (.claude/settings.local.json)",  "localSettings (.claude/settings.local.json)") }
    var destProject: String { s("projectSettings (.claude/settings.json)",       "projectSettings (.claude/settings.json)") }
    var destUser:    String { s("userSettings (~/.claude/settings.json)",         "userSettings (~/.claude/settings.json)") }

    // Enum labels — BridgeTransportKind
    var transportTCP:  String { s("TCP loopback",         "TCP 루프백") }
    var transportUnix: String { s("Unix domain socket",   "Unix 도메인 소켓") }

    // Enum labels — ApprovalFallbackPolicy
    var fallbackPass: String { s("Pass (let CLI decide)",     "통과 (CLI에 위임)") }
    var fallbackDeny: String { s("Deny",                      "거부") }

    // Notch UI
    var notchApprovalRequired: String { s("Approval Required", "승인 필요") }
    var notchNotification:     String { s("Notification",      "알림") }
    var notchMonitoring:       String { s("Monitoring",        "모니터링") }
    var notchActiveAction:     String { s("ACTIVE ACTION",     "활성 작업") }
    var notchAgentSessions:    String { s("AGENT SESSIONS",    "에이전트 세션") }
    var notchListening:        String { s("Listening for AI Agents…", "AI 에이전트 대기 중…") }
    var notchSessions:         String { s("Sessions",          "세션") }
    var notchFocus:            String { s("Focus",             "포커스") }
    var notchDenyRequest:      String { s("Deny Request",      "요청 거부") }
    var notchApprove:          String { s("Approve",           "승인") }
    var notchAutoApproveSession: String { s("Auto-Approve for this Session", "이 세션에서 자동 승인") }
    var notchAlwaysAutoApprove:  String { s("Always Auto-Approve (Global)",  "항상 자동 승인 (전역)") }
    var notchFocusTerminal:    String { s("Focus Terminal",    "터미널 포커스") }
    var notchDismiss:          String { s("Dismiss",           "닫기") }
    var notchUnknown:          String { s("Unknown",           "알 수 없음") }
    var helpFocusTerminal:     String { s("Focus terminal",    "터미널 포커스") }
    var helpDismissSession:    String { s("Dismiss session",   "세션 닫기") }
    var helpDismissPending:    String { s("Dismiss session and pass pending request to terminal",
                                          "세션을 닫고 대기 중인 요청을 터미널로 전달") }
    func tasksQueued(_ n: Int) -> String { s("\(n) tasks queued", "\(n)개 대기 중") }
    func timeJustNow() -> String  { s("Just now",     "방금") }
    func timeSecsAgo(_ n: Int) -> String  { s("\(n)s ago",  "\(n)초 전") }
    func timeMinsAgo(_ n: Int) -> String  { s("\(n)m ago",  "\(n)분 전") }

    // Session status labels
    var statusPending:       String { s("Pending",        "대기 중") }
    var statusBypassed:      String { s("Bypassed",       "우회됨") }
    var statusAutoApproved:  String { s("Auto-Approved",  "자동 승인됨") }
    var statusPolicyApproved:String { s("Policy-Approved","정책 승인됨") }
    var statusAutoEdit:      String { s("Auto-Edit",      "자동 편집") }
}
