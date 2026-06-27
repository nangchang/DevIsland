import Foundation

struct TerminalContext: Equatable {
    var app: String
    var tty: String
    var windowId: String
    var tabIndex: String
    var tmuxPane: String
    var tmuxSocket: String
    var tmuxClient: String
    var managerSessionTitle: String

    init(
        app: String = "",
        tty: String = "",
        windowId: String = "",
        tabIndex: String = "",
        tmuxPane: String = "",
        tmuxSocket: String = "",
        tmuxClient: String = "",
        managerSessionTitle: String = ""
    ) {
        self.app = app
        self.tty = tty
        self.windowId = windowId
        self.tabIndex = tabIndex
        self.tmuxPane = tmuxPane
        self.tmuxSocket = tmuxSocket
        self.tmuxClient = tmuxClient
        self.managerSessionTitle = managerSessionTitle
    }

    init(from json: [String: Any]) {
        app       = json["terminal_app"] as? String ?? ""
        tty       = json["terminal_tty"] as? String ?? ""
        windowId  = json["terminal_window_id"] as? String ?? ""
        tabIndex  = json["terminal_tab_index"] as? String ?? ""
        tmuxPane  = json["terminal_tmux_pane"] as? String ?? ""
        tmuxSocket = json["terminal_tmux_socket"] as? String ?? ""
        tmuxClient = json["terminal_tmux_client"] as? String ?? ""
        managerSessionTitle = json["terminal_manager_session_title"] as? String ?? ""
    }

    /// 비어있지 않은 필드만 덮어쓴다 — 새 이벤트에서 일부 필드가 비어 있어도 기존 값이 유지된다.
    mutating func merge(_ other: TerminalContext) {
        if !other.app.isEmpty       { app = other.app }
        if !other.tty.isEmpty       { tty = other.tty }
        if !other.windowId.isEmpty  { windowId = other.windowId }
        if !other.tabIndex.isEmpty  { tabIndex = other.tabIndex }
        if !other.tmuxPane.isEmpty  { tmuxPane = other.tmuxPane }
        if !other.tmuxSocket.isEmpty { tmuxSocket = other.tmuxSocket }
        if !other.tmuxClient.isEmpty { tmuxClient = other.tmuxClient }
        if !other.managerSessionTitle.isEmpty { managerSessionTitle = other.managerSessionTitle }
    }

    /// tmux pane → TTY → 앱+창 순서로 동일 터미널 세션인지 판별한다.
    func isSameIdentity(as other: TerminalContext) -> Bool {
        if !tmuxPane.isEmpty, !other.tmuxPane.isEmpty,
           tmuxPane == other.tmuxPane,
           tmuxSocket == other.tmuxSocket,
           tmuxClient == other.tmuxClient { return true }

        if !tmuxPane.isEmpty || !other.tmuxPane.isEmpty { return false }

        if !tty.isEmpty, !other.tty.isEmpty, tty == other.tty { return true }

        if !app.isEmpty, !other.app.isEmpty,
           !windowId.isEmpty, !other.windowId.isEmpty,
           app == other.app, windowId == other.windowId,
           tabIndex == other.tabIndex { return true }

        return false
    }
}
