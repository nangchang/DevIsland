import Foundation
import os

/// Centralized `os.Logger` categories that replace ad-hoc `print()` calls.
///
/// The subsystem matches the app bundle identifier so entries are filterable in
/// Console.app by `subsystem:kr.or.nes.DevIsland`. Values that may contain user
/// data — session ids, terminal titles, tool details, filesystem paths — are
/// marked `.private` at each call site so they are redacted from release logs;
/// only structural text and non-sensitive scalars stay `.public`.
///
/// Categories are added as `print()` sites are migrated. The refactoring plan's
/// illustrative set was `bridge`, `approval`, `ui`, `plugin`; `terminal` (focus/
/// tmux), `core` (app lifecycle/persistence), and `session` (transcript/replay
/// recording) are added for logging that fits none of those.
enum Log {
    private static let subsystem = "kr.or.nes.DevIsland"

    /// IPC socket server, hook parsing, token management, installer.
    static let bridge = Logger(subsystem: subsystem, category: "bridge")

    /// Approval flow presentation, decisions, policy persistence.
    static let approval = Logger(subsystem: subsystem, category: "approval")

    /// Terminal focusing, tmux navigation, AppleScript/process execution.
    static let terminal = Logger(subsystem: subsystem, category: "terminal")

    /// Plugin host command handling, storage, effect execution.
    static let plugin = Logger(subsystem: subsystem, category: "plugin")

    /// App lifecycle: init, rule migration, log pruning, session restore.
    static let core = Logger(subsystem: subsystem, category: "core")

    /// Notch/window UI: screen targeting, window placement.
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Session transcript and replay recording.
    static let session = Logger(subsystem: subsystem, category: "session")
}
