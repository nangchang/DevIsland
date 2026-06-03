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
        case .system:  return Locale.preferredLanguages.first.map { $0 == "ko" || $0.hasPrefix("ko-") } ?? false
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
    var menuSessionHistory:     String { s("Session History…",           "세션 기록…") }
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
    var menuCheckForUpdates:    String { s("Check for Updates…",         "업데이트 확인…") }
    func menuUpdateAvailable(_ v: String) -> String { s("Update Available (\(v))…", "업데이트 있음 (\(v))…") }
    var menuQuit:               String { s("Quit DevIsland",             "DevIsland 종료") }

    // MARK: Alerts — install
    var alertAllInstalled:         String { s("All Hooks Installed",          "전체 훅 설치 완료") }
    var alertClaudeInstalled:      String { s("Claude Code Installed",          "Claude Code 설치 완료") }
    var alertClaudeInstallFailed:  String { s("Claude Code Installation Failed","Claude Code 설치 실패") }
    var alertCodexInstalled:       String { s("Codex CLI Installed",            "Codex CLI 설치 완료") }
    var alertCodexInstallFailed:   String { s("Codex CLI Installation Failed",  "Codex CLI 설치 실패") }
    var alertGeminiInstalled:      String { s("Gemini CLI Installed",           "Gemini CLI 설치 완료") }
    var alertGeminiInstallFailed:  String { s("Gemini CLI Installation Failed", "Gemini CLI 설치 실패") }
    var alertInstallFailed:        String { s("Installation Failed",            "설치 실패") }
    var alertAllInstalledMsg:      String { s("All bridge hooks installed.\nRestart each CLI session.",
                                              "모든 브리지 훅이 설치되었습니다.\n각 CLI 세션을 재시작해주세요.") }
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

    // MARK: Alerts — UpdateChecker
    var updateAvailableTitle:     String { s("Update Available",       "업데이트 가능") }
    var updateChangeLogTitle:     String { s("Release Notes / Change Log", "릴리즈 노트 / 변경 로그") }
    func updateAvailableMsg(_ v: String) -> String {
        s("DevIsland \(v) is available.\nInstall and relaunch?",
          "DevIsland \(v)이(가) 출시되었습니다.\n설치 후 재실행하시겠습니까?")
    }
    var updateInstallBtn:         String { s("Install and Relaunch",   "설치 후 재실행") }
    var updateLaterBtn:           String { s("Later",                  "나중에") }
    var updateUpToDateTitle:      String { s("Up to Date",             "최신 버전") }
    func updateUpToDateMsg(_ v: String) -> String {
        s("DevIsland \(v) is the latest version.", "DevIsland \(v)이 최신 버전입니다.")
    }
    var updateDownloading:        String { s("Downloading…",            "다운로드 중…") }
    var updateInstalling:         String { s("Installing…",             "설치 중…") }
    var updateRelaunching:        String { s("Relaunching…",            "재실행 중…") }
    var updateFailedTitle:        String { s("Update Failed",          "업데이트 실패") }
    var updateCheckFailedTitle:   String { s("Update Check Failed",    "업데이트 확인 실패") }
    var updateInvalidResponseMsg: String { s("Invalid response from GitHub.",
                                             "GitHub에서 잘못된 응답을 받았습니다.") }
    var updateNoAssetMsg:         String { s("No DMG found in the latest release.",
                                             "최신 릴리즈에서 DMG를 찾을 수 없습니다.") }

    // MARK: Settings Window
    var winSettings:         String { s("DevIsland Settings",  "DevIsland 설정") }
    var winApprovalRules:    String { s("Approval Rules",       "승인 규칙") }
    var winReplayLog:        String { s("Replay Log",           "재실행 로그") }
    var winPTYTranscript:    String { s("PTY Transcript",       "PTY 트랜스크립트") }
    var winSessionHistory:   String { s("Session History",      "세션 기록") }

    // Tab labels
    var tabGeneral:          String { s("General",      "일반") }
    var tabIsland:           String { s("Island",       "아일랜드") }
    var tabApproval:         String { s("Approval",     "승인") }
    var tabProviders:        String { s("Providers",    "공급자") }
    var tabBridge:           String { s("Bridge / IPC", "브리지 / IPC") }
    var tabSound:            String { s("Sound",        "사운드") }
    var tabExperimental:     String { s("Experimental", "실험적") }
    var tabIntegrations:     String { s("Integrations", "통합") }
    var tabExtras:           String { s("Extras",       "부가기능") }
    var tabAdvanced:         String { s("Advanced",     "고급") }

    // Extras tab
    var lblExtrasEmpty:          String { s("No extras available.",                                               "등록된 부가기능이 없습니다.") }
    var descExtrasEmpty:         String { s("Additional features will appear here as they are added.",            "추가 기능이 생기면 여기에 표시됩니다.") }

    // Integrations tab
    var secAppIntegrations:           String { s("App Integrations",                                               "앱 통합") }
    var lblProcessVSCode:             String { s("Enable VS Code integration",                                     "VS Code 통합 활성화") }
    var descProcessVSCode:            String { s("Process hook events from sessions running in VS Code.",          "VS Code에서 실행 중인 세션의 hook 이벤트를 처리합니다.") }
    var lblProcessClaudeDesktop:      String { s("Enable Claude Desktop integration",                              "Claude 데스크탑 통합 활성화") }
    var descProcessClaudeDesktop:     String { s("Process hook events from sessions running in Claude Desktop.",   "Claude 데스크탑에서 실행 중인 세션의 hook 이벤트를 처리합니다.") }

    // General tab
    var btnResetAllSettings:          String { s("Reset All Settings to Defaults",          "모든 설정 초기화") }
    var secLanguage:                  String { s("Language",                                "언어") }
    var lblLanguage:                  String { s("Language",                                "언어") }
    var secPreferredTerminal:         String { s("Default Terminal",                        "기본 터미널") }
    var lblPreferredTerminal:         String { s("Open sessions in",                        "세션 열기") }
    var optTerminalSessionDefault:    String { s("Session's terminal (automatic)",           "세션 터미널 자동 선택") }
    var hintPreferredTerminal:        String { s("Used when opening a session in a new terminal window. Falls back to the session's original terminal app if not set.", "새 터미널 창에서 세션을 열 때 사용합니다. 설정하지 않으면 세션이 실행된 터미널 앱을 사용합니다.") }
    var secStartup:                   String { s("Startup",                                 "시작") }
    var lblLaunchAtLogin:             String { s("Launch at Login",                         "로그인 시 자동 시작") }
    var lblLaunchAtLoginApproval:     String { s("Approval required in System Settings",    "시스템 설정에서 승인 필요") }
    var btnOpenLoginSettings:         String { s("Open Login Items Settings…",              "로그인 항목 설정 열기…") }
    var alertLaunchAtLoginFailed:     String { s("Failed to change Launch at Login",        "자동 시작 설정 변경 실패") }
    var secUpdates:                   String { s("Updates",                                 "업데이트") }
    var lblCheckForUpdatesOnStartup:  String { s("Check for updates on startup",            "시작 시 업데이트 확인") }

    // Island tab
    var secNotch:            String { s("Island",                        "아일랜드") }
    var lblDisplay:          String { s("Display",                       "표시") }
    var lblMonitor:          String { s("Monitor",                       "모니터") }
    var lblShowFullScreen:   String { s("Show above full-screen apps",   "전체화면 앱 위에 표시") }
    func lblPanelOpacity(_ percent: Int) -> String { s("Panel opacity: \(percent)%", "패널 불투명도: \(percent)%") }
    var lblNotchShadow:      String { s("Backdrop shadow",               "백드롭 그림자") }
    var lblNotchAnimation:   String { s("Expand/collapse animation",     "펼침/접힘 애니메이션") }
    func lblAnimationSpeed(_ value: Double) -> String { s("Animation speed: \(String(format: "%.2f", value))×", "애니메이션 속도: \(String(format: "%.2f", value))×") }
    var lblNotchShapeStyle:  String { s("Shape style",                  "모양 스타일") }
    var notchShapeClassic:   String { s("Classic Island",               "기본 아일랜드") }
    var notchShapeDynamicIsland: String { s("Dynamic Island",           "다이나믹 아일랜드") }
    func lblCollapsedNotchWidth(_ px: Int) -> String { s("Compact Island width: \(px) px", "컴팩트 아일랜드 너비: \(px) px") }
    func lblCollapsedNotchHeight(_ px: Int) -> String { s("Compact Island height: \(px) px", "컴팩트 아일랜드 높이: \(px) px") }
    func lblExpandedNotchWidth(_ px: Int) -> String { s("Expanded Island width: \(px) px", "확장 아일랜드 너비: \(px) px") }
    func lblExpandedNotchHeight(_ px: Int) -> String { s("Expanded Island height: \(px) px", "확장 아일랜드 높이: \(px) px") }
    var lblNotchAutoExpand:   String { s("Auto-expand on events",        "이벤트 시 자동 펼침") }
    var lblUnreadDotPosition: String { s("Unread dot position",          "알림 dot 위치") }
    var posLeft:   String { s("Left",   "왼쪽") }
    var posCenter: String { s("Center", "가운데") }
    var posRight:  String { s("Right",  "오른쪽") }
    var lblNotchAutoCollapse: String { s("Auto-collapse",                "자동 닫힘") }
    var secNotchAutoExpand:      String { s("Auto-expand",               "자동 펼침") }
    var secNotchExpandTriggers: String { s("When to expand",              "자동 펼침 조건") }
    var lblExpandOnNotification: String { s("On notification",                    "알림 수신 시") }
    var lblExpandOnTaskCompletion: String { s("On task completion",               "작업 완료 시") }
    var lblExpandOnIdlePrompt: String { s("On idle / waiting for input",          "대기 중 (입력 필요 시)") }
    var lblExpandOnNotificationMessage: String { s("On notification message",     "알림 메시지 수신 시") }
    var lblExpandOnInteractiveTool: String { s("On interactive input (Gemini only)", "Gemini 인터랙티브 입력 시") }
    var lblExpandOnApprovalRequest: String { s("On approval request",            "승인 요청 시") }
    var lblExpandOnQuestionResponse: String { s("On question response",           "질문 응답 대기 시") }
    var hintExpandOnNotification: String { s("Expand when a notification event occurs. Use the sub-options to choose which kinds.",
                                             "알림 이벤트 발생 시 펼칩니다. 하위 항목으로 종류를 선택하세요.") }
    var hintExpandOnTaskCompletion: String { s("When an agent finishes its task.",
                                               "에이전트가 작업을 완료했을 때") }
    var hintExpandOnIdlePrompt: String { s("When the agent is done and waiting for the next prompt.",
                                           "에이전트가 완료 후 다음 프롬프트를 기다릴 때") }
    var hintExpandOnNotificationMessage: String { s("When a notification includes a question or message from the agent.",
                                                    "에이전트가 질문이나 메시지를 알림으로 보낼 때") }
    var hintExpandOnInteractiveTool: String { s("Gemini only — when an interactive tool (e.g. bash) is waiting for terminal input.",
                                                "Gemini 전용 — 터미널 입력을 기다리는 인터랙티브 툴이 실행될 때") }
    var hintExpandOnApprovalRequest: String { s("When a tool approval request is received.",
                                                "도구 사용 승인 요청이 수신될 때") }
    var hintExpandOnQuestionResponse: String { s("When the agent sends a question and waits for a response.",
                                               "에이전트가 사용자에게 질문을 보내고 응답을 기다릴 때") }
    var secNotchCharacters:  String { s("Buddies",                       "버디") }
    var lblLeftCharacter:    String { s("Left Buddy",                    "왼쪽 버디") }
    var lblRightCharacter:   String { s("Right Buddy",                   "오른쪽 버디") }
    var lblCharacter:        String { s("Buddy",                         "버디") }
    var lblRandomIncludes:   String { s("Random Buddies",                "랜덤 버디") }
    func lblCharacterHorizontalInset(_ px: Int) -> String { s("Buddy horizontal position: \(px) px", "버디 가로 위치: \(px) px") }
    func lblCharacterVerticalOffset(_ px: Int) -> String { s("Buddy vertical position: \(px) px", "버디 세로 위치: \(px) px") }
    var lblNotchCenterText:  String { s("Center text",                   "가운데 텍스트") }
    var secRequests:         String { s("Requests",                      "요청") }
    var lblRequestDisplay:   String { s("Request display",               "요청 표시") }

    // Approval tab
    var secAutoApprovals:    String { s("Automatic approvals",           "자동 승인") }
    var lblAutoSafe:         String { s("Auto-approve safe/read-only tools", "안전/읽기 전용 도구 자동 승인") }
    var lblGeminiEmulate:    String { s("Show approval for risky tools",  "위험 도구 승인 창 표시") }
    var secPermissionTimeout: String { s("Permission timeout",             "권한 요청 타임아웃") }
    func lblPermissionTimeout(_ n: Int) -> String { s("Auto-pass after \(n) seconds", "\(n)초 후 자동 패스") }
    var secReplayRetention:  String { s("Replay log retention",          "리플레이 로그 보관") }
    func lblReplayRetention(_ n: Int) -> String { s("Replay log: \(n) days", "리플레이 로그: \(n)일") }
    var secFallback:         String { s("Transport failure fallback",    "전송 실패 폴백") }
    var lblFallbackPolicy:   String { s("Fallback policy",               "폴백 정책") }

    // Providers tab
    var lblSessionApproval:  String { s("Session approval",               "세션 승인 방식") }
    var lblPersistentDest:   String { s("Persistent approval scope",       "영구 승인 적용 범위") }
    var warnProjectSettings: String { s("Project settings can be committed to the repository. Review changes before committing.",
                                        "프로젝트 설정은 저장소에 커밋될 수 있습니다. 커밋 전에 변경 사항을 검토하세요.") }
    var descCodex:           String { s("Codex session approval will use DevIsland-managed cache and persistent SQLite rules in later phases.",
                                        "Codex 세션 승인은 이후 단계에서 DevIsland 관리 캐시와 영구 SQLite 규칙을 사용합니다.") }
    var descGemini:          String { s("Prompts for approval on risky tools even when running with --auto-approve or --yolo.",
                                        "--auto-approve 또는 --yolo로 실행 중일 때도 위험한 도구는 승인을 요청합니다.") }

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

    // Sound tab
    var secOpenPeonSoundPacks:       String { s("Sound packs",                   "사운드팩") }
    var lblOpenPeonEnable:           String { s("Enable sounds",                 "사운드 활성화") }
    var lblOpenPeonMuteAll:          String { s("Mute all sounds",               "모든 사운드 음소거") }
    var phOpenPeonPacksFolder:       String { s("Packs folder",                  "팩 폴더") }
    var btnReload:                   String { s("Reload",                        "다시 불러오기") }
    var btnOpen:                     String { s("Open",                          "열기") }
    var btnPlayPreview:              String { s("Play preview",                  "미리듣기 재생") }
    var lblOpenPeonActivePack:       String { s("Active pack",                   "활성 팩") }
    var lblOpenPeonFirstValidPack:   String { s("First valid pack",              "첫 번째 유효한 팩") }
    var lblOpenPeonNoPacks:          String { s("No sound packs found.",         "사운드팩을 찾을 수 없습니다.") }
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
    var alertAddGlobalToolTitle: String { s("Add Global Auto-Approval Tool",   "글로벌 자동 승인 툴 추가") }
    var alertAddGlobalToolMsg:   String { s("Enter the tool name (e.g. read_file) to auto-approve in all sessions.",
                                            "모든 세션에서 자동 승인할 툴 이름(예: read_file)을 입력하세요.") }
    var alertAddSessionToolTitle: String { s("Add Session Auto-Approval Tool", "세션 자동 승인 툴 추가") }
    func alertAddSessionToolMsg(_ id: String) -> String {
        s("Enter the tool name to auto-approve in session \(id).",
          "현재 세션(\(id))에서 자동 승인할 툴 이름을 입력하세요.")
    }
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

    // IslandSettingsPane — monitor name
    func monitorMain() -> String { s("Main monitor", "주 모니터") }
    func monitorN(_ n: Int) -> String { s("Monitor \(n)", "모니터 \(n)") }

    // Enum labels — NotchDisplayTarget
    var notchAuto:     String { s("Automatic",               "자동") }
    var notchMain:     String { s("Main monitor",            "주 모니터") }
    var notchMouse:    String { s("Monitor with mouse",      "마우스가 있는 모니터") }
    var notchFocused:  String { s("Monitor with focus",      "포커스가 있는 모니터") }
    var notchSpecific: String { s("Selected monitor",        "선택한 모니터") }
    var notchCharacterHidden:   String { s("Hidden",         "숨김") }
    var notchCharacterRandom:   String { s("Random",         "랜덤") }
    var notchCharacterSpecific: String { s("Specific",       "지정") }
    var notchAutoCollapseOff:   String { s("Off",            "끔") }

    // Enum labels — RequestDisplayTarget
    var reqNotch:   String { s("Island display", "아일랜드 화면") }
    var reqFocused: String { s("Focus display",  "포커스 화면") }
    var reqMouse:   String { s("Mouse display",  "마우스 화면") }

    // Enum labels — ClaudeSessionApprovalMode
    var modeNative:   String { s("Native Claude permissions",            "Claude 기본 권한") }
    var modeCache:    String { s("DevIsland-managed session cache",      "DevIsland 관리 세션 캐시") }
    var modeHybrid:   String { s("Hybrid",                               "하이브리드") }
    var detailNative: String { s("Recommended. Claude manages approvals. Most compatible.",
                                  "권장. 승인 내역을 Claude가 관리합니다. 가장 안정적입니다.") }
    var detailCache:  String { s("DevIsland remembers approved tools for the session. Won't ask again.",
                                  "DevIsland가 세션 중 승인한 도구를 기억해 다시 묻지 않습니다.") }
    var detailHybrid: String { s("Uses Claude permissions when available, falls back to DevIsland.",
                                  "Claude 방식을 우선 사용하고, 지원되지 않으면 DevIsland가 처리합니다.") }

    // Enum labels — ClaudePersistentApprovalDestination
    var destLocal:        String { s("Project local",  "프로젝트 로컬") }
    var destProject:      String { s("Project shared", "프로젝트 공유") }
    var destUser:         String { s("User-wide",      "사용자 전체") }
    var detailDestLocal:  String { s("Applies to this project only. Not committed to git. (.claude/settings.local.json)",
                                     "이 프로젝트에만 적용됩니다. git에 커밋되지 않습니다. (.claude/settings.local.json)") }
    var detailDestProject: String { s("Shared with your team. Can be committed to git. (.claude/settings.json)",
                                      "팀원과 공유됩니다. git에 커밋될 수 있습니다. (.claude/settings.json)") }
    var detailDestUser:   String { s("Applies across all projects. (~/.claude/settings.json)",
                                     "모든 프로젝트에 적용됩니다. (~/.claude/settings.json)") }

    // Enum labels — BridgeTransportKind
    var transportTCP:  String { s("TCP loopback",         "TCP 루프백") }
    var transportUnix: String { s("Unix domain socket",   "Unix 도메인 소켓") }

    // Enum labels — ApprovalFallbackPolicy
    var fallbackPass: String { s("Pass (let CLI decide)",     "통과 (CLI에 위임)") }
    var fallbackDeny: String { s("Deny",                      "거부") }

    // Pop-out window
    var popOutWindow:          String { s("Pop out message window",       "메시지 창 분리") }
    var sessionEnded:          String { s("Session ended",                "세션이 종료되었습니다") }
    var msgWaiting:            String { s("Waiting for message…",         "메시지 대기 중…") }
    var approvingOtherSession: String { s("Approving another session…",   "다른 세션 승인 처리 중…") }

    // Notch UI
    var notchApprovalRequired: String { s("Approval Required", "승인 필요") }
    var notchNotification:     String { s("Notification",      "알림") }
    var notchMonitoring:       String { s("Monitoring",        "모니터링") }
    var notchActiveAction:     String { s("ACTIVE ACTION",     "활성 작업") }
    var notchAgentSessions:    String { s("AGENT SESSIONS",    "에이전트 세션") }
    var notchListening:        String { s("Listening for AI Agents…", "AI 에이전트 대기 중…") }
    var terminalWaiting:       String { s("Waiting for terminal confirmation…", "터미널 확인 대기 중...") }
    func terminalCheckMsg(_ tool: String) -> String { s("Check terminal window (\(tool))", "터미널 창을 확인해 주세요 (\(tool))") }
    var notchSessions:         String { s("Sessions",          "세션") }
    var notchFocus:            String { s("Focus",             "포커스") }
    var notchDenyRequest:      String { s("Deny Request",      "요청 거부") }
    var notchApprove:          String { s("Approve",           "승인") }
    var notchAutoApproveSession: String { s("Auto-Approve for this Session", "이 세션에서 자동 승인") }
    var notchAlwaysAutoApprove:  String { s("Always Auto-Approve (Global)",  "항상 자동 승인 (전역)") }
    var notchFocusTerminal:    String { s("Focus Terminal",    "터미널 포커스") }
    var notchDismiss:          String { s("Dismiss",           "닫기") }
    var notchUnknown:          String { s("Unknown",           "알 수 없음") }
    var helpOpenSettings:       String { s("Open settings",     "설정 열기") }
    var helpFocusTerminal:     String { s("Focus terminal",    "터미널 포커스") }
    var helpDismissSession:    String { s("Dismiss session",   "세션 닫기") }
    var menuOpenInFinder:      String { s("Open in Finder",    "Finder에서 열기") }
    var menuCopyPath:          String { s("Copy Path",         "경로 복사") }
    var menuCopyResumeCommand: String { s("Copy Resume Command", "재시작 명령 복사") }
    var menuRenameSession:     String { s("Rename…",             "이름 변경…") }
    var renameSessionTitle:    String { s("Rename Session",      "세션 이름 변경") }
    var renameSessionConfirm:  String { s("Rename",              "변경") }
    var renameSessionPlaceholder: String { s("Session name",     "세션 이름") }
    var btnCancel:             String { s("Cancel",              "취소") }
    func renameSessionHint(_ id: String) -> String {
        s("Enter a name for session \(id). Leave empty to reset.", "세션 \(id)의 이름을 입력하세요. 비워두면 초기화됩니다.")
    }
    var menuOpenInTerminal:    String { s("Open in Terminal",  "터미널에서 열기") }
    func menuTerminalAuto(_ name: String) -> String { s("Auto (\(name))", "자동 (\(name))") }
    var helpDismissPending:    String { s("Dismiss session and pass pending request to terminal",
                                          "세션을 닫고 대기 중인 요청을 터미널로 전달") }
    func tasksQueued(_ n: Int) -> String { s("\(n) tasks queued", "\(n)개 대기 중") }
    func timeJustNow() -> String  { s("Just now",     "방금") }
    func timeSecsAgo(_ n: Int) -> String  { s("\(n)s ago",  "\(n)초 전") }
    func timeMinsAgo(_ n: Int) -> String  { s("\(n)m ago",  "\(n)분 전") }

    // Session History Window
    var historySearch:      String { s("Search sessions…",    "세션 검색…") }
    var historyEmpty:       String { s("No closed sessions",  "종료된 세션 없음") }
    var historyRefresh:     String { s("Refresh",             "새로 고침") }
    var historyColAgent:    String { s("Agent",               "에이전트") }
    var historyColPath:     String { s("Path",                "경로") }
    var historyColLabel:    String { s("Name",                "이름") }
    var historyColTitle:    String { s("Terminal",            "터미널") }
    var historyColEnded:    String { s("Ended",               "종료") }
    var historyColSession:  String { s("Session ID",          "세션 ID") }
    func historyCount(_ n: Int) -> String { s("\(n) sessions", "\(n)개 세션") }

    // Session status labels
    var statusPending:       String { s("Pending",        "대기 중") }
    var statusBypassed:      String { s("Bypassed",       "우회됨") }
    var statusAutoApproved:  String { s("Auto-Approved",  "자동 승인됨") }
    var statusPolicyApproved:String { s("Policy-Approved","정책 승인됨") }
    var statusAutoEdit:      String { s("Auto-Edit",      "자동 편집") }
}
