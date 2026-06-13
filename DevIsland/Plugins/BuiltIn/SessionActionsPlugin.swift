import Foundation

/// Built-in plugin that contributes a host-validated "Dismiss" action to each session's
/// context menu (`session.context-menu`, opened in v1.1 / Migration M4).
///
/// It only *proposes* the action — `AppState` re-validates the target session and removes
/// only idle, non-pending sessions with no missed approval or unread state. The plugin
/// cannot see that state (it is deliberately absent from `PluginSessionSnapshot`), so it
/// offers the action for every tracked session and the host is the gatekeeper; the label
/// signals the idle-only restriction. Observation-only otherwise — no effects, no core
/// mutation, no replay DB access.
///
/// `@unchecked Sendable`: mutable state (`activeSessionIDs`) is only ever touched inside
/// the `PluginRunner` actor, which serializes every call (architecture doc §6.4).
final class SessionActionsPlugin: DevIslandPlugin, @unchecked Sendable {
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

    private var activeSessionIDs: Set<String> = []

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        switch event.kind {
        case .sessionStarted, .sessionUpdated:
            if let id = event.session?.id {
                activeSessionIDs.insert(id)
            }
        case .sessionEnded:
            if let id = event.session?.id {
                activeSessionIDs.remove(id)
            }
        default:
            break
        }
        return []
    }

    /// Context actions are event-driven, never on a clock.
    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        guard slot == .sessionContextMenu,
              let session = context.session,
              activeSessionIDs.contains(session.id) else { return nil }

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

        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: session.id,
            priority: 50,
            expiresAt: nil,
            components: [dismiss]
        )
    }
}
