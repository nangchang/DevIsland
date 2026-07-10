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
/// target set is `bridge`, `approval`, `ui`, `plugin`; the latter two are
/// introduced by their own follow-up PRs.
enum Log {
    private static let subsystem = "kr.or.nes.DevIsland"

    /// IPC socket server, hook parsing, token management, installer.
    static let bridge = Logger(subsystem: subsystem, category: "bridge")

    /// Approval flow presentation, decisions, policy persistence.
    static let approval = Logger(subsystem: subsystem, category: "approval")
}
