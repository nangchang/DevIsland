import Combine
import Foundation

@MainActor
final class PluginHost: ObservableObject {
    @Published private(set) var contributions: [PluginUISlot: [PluginUIContribution]] = [:]

    nonisolated let isEnabled: Bool

    private typealias PendingEffectBatch = (pluginID: String, effects: [PluginEffect])

    private var runners: [String: PluginRunner] = [:]
    private let storageProvider = PluginStorageProvider()
    private let eventFactory = PluginEventFactory()
    private lazy var eventProcessor = PluginEventProcessor(
        storageProvider: storageProvider,
        eventFactory: eventFactory
    )
    private lazy var effectExecutor = PluginEffectExecutor(storageProvider: storageProvider)
    private var pendingEvents: [QueuedPluginEvent] = []
    private var isDraining = false
    private(set) var failures: [PluginFailure] = []

    nonisolated init(enablePlugins: Bool = true) {
        self.isEnabled = enablePlugins
    }

    func register(_ plugins: [any DevIslandPlugin]) {
        guard isEnabled else { return }
        runners = Dictionary(
            uniqueKeysWithValues: plugins.map { plugin in
                let runner = PluginRunner(plugin: plugin)
                return (runner.manifest.id, runner)
            }
        )
    }

    func enqueue(_ event: PluginEvent) {
        guard isEnabled else { return }
        let eligible = runners.values.filter { shouldDispatch(event, to: $0) }
        pendingEvents.append(QueuedPluginEvent(baseEvent: event, runners: eligible))
        guard !isDraining else { return }
        isDraining = true

        Task { [weak self] in
            await self?.drainEvents()
        }
    }

    func waitUntilIdle() async {
        while isDraining {
            await Task.yield()
        }
    }

    private func shouldDispatch(_ event: PluginEvent, to runner: PluginRunner) -> Bool {
        if let targetPluginID = event.action?.pluginID,
           targetPluginID != runner.manifest.id {
            return false
        }
        guard isEventAllowed(event, for: runner.manifest.permissions) else { return false }
        return runner.manifest.activationEvents.contains(event.kind.rawValue)
    }

    private func isEventAllowed(_ event: PluginEvent, for permissions: Set<PluginPermission>) -> Bool {
        switch event.kind {
        case .sessionStarted, .sessionUpdated, .sessionEnded:
            return permissions.contains(.readSessionEvents)
        case .hookReceived, .approvalDecided:
            return permissions.contains(.readHookSummaries)
        default:
            return true
        }
    }

    private func drainEvents() async {
        while let queued = nextEvent() {
            let snapshots = await eventProcessor.process(queued)
            let effectBatches = applySnapshots(snapshots)
            if queued.baseEvent.kind == .sessionEnded,
               let sessionID = queued.baseEvent.session?.id {
                evictSessionContributions(sessionID: sessionID)
            }
            await processEffectBatches(effectBatches)
        }
        isDraining = false
    }

    private func nextEvent() -> QueuedPluginEvent? {
        guard !pendingEvents.isEmpty else { return nil }
        return pendingEvents.removeFirst()
    }

    private func applySnapshots(_ snapshots: [PluginContributionSnapshot]) -> [PendingEffectBatch] {
        var updated = contributions
        var effectBatches: [PendingEffectBatch] = []

        for snapshot in snapshots {
            if let failure = snapshot.failure {
                recordFailure(failure)
                if failure.clearsContribution {
                    updated = removeContributions(pluginID: snapshot.pluginID, from: updated)
                    continue
                }
            }

            if !snapshot.effects.isEmpty {
                effectBatches.append((pluginID: snapshot.pluginID, effects: snapshot.effects))
            }

            for (slot, contribution) in snapshot.contributions {
                updated[slot, default: []].removeAll {
                    $0.pluginID == snapshot.pluginID &&
                        $0.targetSessionID == contribution.targetSessionID
                }
                updated[slot, default: []].append(contribution)
                updated[slot]?.sort {
                    $0.priority == $1.priority
                        ? $0.pluginID < $1.pluginID
                        : $0.priority < $1.priority
                }
            }
        }

        contributions = updated
        return effectBatches
    }

    private func evictSessionContributions(sessionID: String) {
        var updated = contributions
        for slot in updated.keys {
            updated[slot]?.removeAll { $0.targetSessionID == sessionID }
        }
        contributions = updated
    }

    private func processEffectBatches(_ batches: [PendingEffectBatch]) async {
        for batch in batches {
            await effectExecutor.enqueue(batch.effects, pluginID: batch.pluginID)
        }
    }

    private func removeContributions(
        pluginID: String,
        from current: [PluginUISlot: [PluginUIContribution]]
    ) -> [PluginUISlot: [PluginUIContribution]] {
        var updated = current
        for slot in updated.keys {
            updated[slot]?.removeAll { $0.pluginID == pluginID }
        }
        return updated
    }

    private func recordFailure(_ failure: PluginFailure) {
        failures.append(failure)
    }
}
