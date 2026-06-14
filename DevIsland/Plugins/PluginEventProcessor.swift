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
        selectedSessionID: String? = nil,
        settingsByPlugin: [String: [String: PluginSettingValue]] = [:]
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
                    let settings = settingsByPlugin[runner.manifest.id] ?? [:]
                    // The selected session id is session data, so gate it on the same
                    // permission as session snapshots (architecture §6.3). Otherwise a
                    // plugin without `readSessionEvents` could learn the user's current
                    // session via the context on a non-session event (tick, app.started).
                    let allowedSelectedSessionID = runner.manifest.permissions.contains(.readSessionEvents)
                        ? selectedSessionID
                        : nil
                    return await runner.handle(
                        event,
                        storageSnapshot: storageSnapshot,
                        settings: settings,
                        selectedSessionID: allowedSelectedSessionID
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

