import Foundation

struct QueuedPluginEvent {
    let baseEvent: PluginEvent
    let runners: [PluginRunner]
}

actor PluginEventProcessor {
    private let storageProvider: PluginStorageProvider
    private let eventFactory: PluginEventFactory

    init(storageProvider: PluginStorageProvider, eventFactory: PluginEventFactory) {
        self.storageProvider = storageProvider
        self.eventFactory = eventFactory
    }

    func process(
        _ queued: QueuedPluginEvent,
        selectedSessionID: String? = nil
    ) async -> [PluginContributionSnapshot] {
        let storageProvider = self.storageProvider
        let eventFactory = self.eventFactory

        return await withTaskGroup(of: PluginContributionSnapshot.self) { group in
            for runner in queued.runners {
                group.addTask {
                    let event = eventFactory.redactedEvent(
                        from: queued.baseEvent,
                        permissions: runner.manifest.permissions
                    )
                    let storageSnapshot = runner.manifest.permissions.contains(.writePluginStorage)
                        ? await storageProvider.snapshot(forPluginID: runner.manifest.id)
                        : [:]
                    return await runner.handle(
                        event,
                        storageSnapshot: storageSnapshot,
                        selectedSessionID: selectedSessionID
                    )
                }
            }

            var snapshots: [PluginContributionSnapshot] = []
            for await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots
        }
    }
}

