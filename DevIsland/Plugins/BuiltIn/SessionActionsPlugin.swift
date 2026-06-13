import Foundation

/// Built-in plugin that contributes a host-validated "Dismiss" action to each session's
/// context menu (`session.context-menu`, opened in v1.1 / Migration M4).
///
/// It only *proposes* the action — `AppState` re-validates the target session and removes
/// only idle, non-pending sessions with no missed approval or unread state. The plugin
/// cannot see that state (it is deliberately absent from `PluginSessionSnapshot`), so it
/// offers the action for every session the host evaluates it against and the host is the
/// gatekeeper; the label signals the idle-only restriction. Observation-only otherwise —
/// no effects, no core mutation, no replay DB access.
///
/// The host evaluates `.sessionContextMenu` per session event and evicts the contribution
/// on `session.ended` (`targetSessionID`), so the plugin keeps no session state of its own.
///
/// `Sendable`: no mutable state; the `PluginRunner` actor serializes calls anyway.
final class SessionActionsPlugin: DevIslandPlugin, Sendable {
    let manifest = PluginManifest(
        id: "com.devisland.session-actions",
        name: "Session Actions",
        version: "1.0.0",
        apiVersion: 1,
        kind: .system,
        permissions: [.readSessionEvents, .showSessionSurface],
        surfaces: [.sessionContextMenu],
        activationEvents: [
            PluginEventKind.sessionStarted.rawValue,
            PluginEventKind.sessionUpdated.rawValue,
            PluginEventKind.sessionEnded.rawValue
        ]
    )

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        []
    }

    /// Context actions are event-driven, never on a clock.
    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        guard slot == .sessionContextMenu, let session = context.session else { return nil }

        let dismiss = PluginUIComponentDTO(
            id: "dismiss",
            type: .button,
            label: "Dismiss if idle",
            value: nil,
            tone: nil,
            iconName: "xmark.circle",
            action: PluginUIActionDTO(
                id: "session.dismiss",
                capability: "session.dismiss",
                routing: .hostExecuted,
                payload: ["sessionID": session.id]
            )
        )

        // Side-effect-free host command: the host builds the sanitized resume command and
        // copies it to the pasteboard, so the plugin never sees workspace paths or shell strings.
        let copyResume = PluginUIComponentDTO(
            id: "copy-resume",
            type: .button,
            label: "Copy Resume Command",
            value: nil,
            tone: nil,
            iconName: "arrow.counterclockwise",
            action: PluginUIActionDTO(
                id: "session.copyResumeCommand",
                capability: "session.copyResumeCommand",
                routing: .hostExecuted,
                payload: ["sessionID": session.id]
            )
        )

        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: session.id,
            priority: 50,
            expiresAt: nil,
            components: [dismiss, copyResume]
        )
    }
}
