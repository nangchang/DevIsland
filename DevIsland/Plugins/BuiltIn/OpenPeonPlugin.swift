import Foundation

final class OpenPeonPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest = PluginManifest(
        id: "openpeon",
        name: "OpenPeon",
        version: "1.0.0",
        apiVersion: 1,
        kind: .system,
        permissions: [.playSound, .readHookSummaries],
        surfaces: [],
        activationEvents: ["hook.received"],
        localizedName: PluginLocalizedString(english: "OpenPeon", korean: "OpenPeon")
    )

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        guard event.kind == .hookReceived, let hook = event.hook else {
            return []
        }

        let agentKind = BuddyKind(from: hook.provider)

        let payloadDict = hook.payload?.mapValues { $0.rawValue }

        if let category = CESPEventMapper.category(
            event: hook.rawEvent ?? "",
            normalizedEvent: hook.eventType,
            agentKind: agentKind,
            toolName: hook.toolName ?? "",
            notificationType: hook.notificationType ?? "",
            message: hook.message ?? "",
            payload: payloadDict
        ) {
            return [
                PluginEffect(
                    capability: "sound.play",
                    payload: ["category": category.rawValue]
                )
            ]
        }

        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        return nil
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        return false
    }
}
