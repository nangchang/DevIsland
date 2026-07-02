import Foundation

/// The approval/notification currently displayed in the notch, bundled into one
/// value so the display can be reset atomically instead of field-by-field.
///
/// This is the display half of the `ApprovalRequestCoordinator` proposed in
/// issue #239: `AppState` owns an instance as a single `@Published` property,
/// so every mutation notifies SwiftUI, and the repeated reset blocks collapse
/// into `clear()` / `clearResponseState()`.
struct ApprovalDisplayState {
    /// Open connection back to the CLI for the displayed request. Non-nil means
    /// an approval is waiting for a user decision (vs. an informational display).
    var responseHandler: ((String) -> Void)?
    var sessionId: String = ""
    var toolName: String = ""
    var eventName: String = ""
    var message: String = ""
    /// Raw (un-localized) tool name used for rule persistence and replay records.
    var rawToolName: String = ""
    var agentKind: BuddyKind?
    var workspaceRoot: String?
    var hookEventId: Int64?
    /// True while a pending request is on screen; guards double-display.
    var isShowingRequest = false
    var showingRequestId: UUID?

    var hasResponseHandler: Bool { responseHandler != nil }

    /// Resets everything — the notch shows nothing afterwards.
    mutating func clear() {
        self = ApprovalDisplayState()
    }

    /// Resets the response-handling state (handler, hook event, showing markers)
    /// while keeping the displayed text visible. Used when a decision was sent or
    /// the shown request is preempted, so the display doesn't flash empty before
    /// the next request (or session sync) overwrites it.
    mutating func clearResponseState() {
        responseHandler = nil
        hookEventId = nil
        isShowingRequest = false
        showingRequestId = nil
    }

    /// Clears only the displayed text, keeping response-handling state intact.
    /// Used when returning to a previous session view.
    mutating func clearDisplayText() {
        sessionId = ""
        toolName = ""
        eventName = ""
        message = ""
    }
}
