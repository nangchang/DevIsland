import Combine
import Foundation

@MainActor
final class PluginHost: ObservableObject {
    @Published private(set) var contributions: [PluginUISlot: [PluginUIContribution]] = [:] {
        didSet {
            scheduleExpirationPrune()
        }
    }

    nonisolated let isEnabled: Bool

    private typealias PendingEffectBatch = (pluginID: String, effects: [PluginEffect])

    private var runners: [String: PluginRunner] = [:]
    private let storageProvider: PluginStorageProvider
    private let eventFactory = PluginEventFactory()
    private lazy var eventProcessor = PluginEventProcessor(
        storageProvider: storageProvider,
        eventFactory: eventFactory
    )
    private lazy var effectExecutor = PluginEffectExecutor(
        storageProvider: storageProvider,
        notificationHandler: { title, body in
            await AppState.presentSharedPluginNotification(title: title, body: body)
        }
    )
    private var pendingEvents: [QueuedPluginEvent] = []
    private var isDraining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var failures: [PluginFailure] = []
    private var expirationTimer: Timer?
    private var tickTask: Task<Void, Never>?
    private var visibleSurfaces: Set<PluginUISlot> = []
    /// Incremented only after the start guard passes, so tests can assert the
    /// tick loop starts at most once without observing the live timer.
    private(set) var tickStartCount = 0

    nonisolated init(
        enablePlugins: Bool = true,
        pluginDataDirectory: URL = PluginStorageProvider.defaultDirectory
    ) {
        self.isEnabled = enablePlugins
        self.storageProvider = PluginStorageProvider(baseDirectory: pluginDataDirectory)
    }

    func register(_ plugins: [any DevIslandPlugin & Sendable]) {
        guard isEnabled else { return }
        runners = Dictionary(
            uniqueKeysWithValues: plugins.map { plugin in
                let runner = PluginRunner(plugin: plugin)
                return (runner.manifest.id, runner)
            }
        )
    }

    /// Routes a UI action from the plugin that owns `pluginID`.
    /// `.pluginEvent` routing enqueues a pluginActionInvoked event back to that plugin.
    /// `.hostExecuted` routing sends the action through the same host effect executor.
    func handleAction(_ action: PluginUIActionDTO, from pluginID: String, componentID: String) {
        guard let runner = runners[pluginID] else { return }

        switch action.routing {
        case .hostExecuted:
            guard PluginEffectExecutor.isHostEffectSupported(
                action.capability,
                permissions: runner.manifest.permissions
            ) else { return }
            let effect = PluginEffect(capability: action.capability, payload: action.payload)
            let permissions = runner.manifest.permissions
            Task { [effectExecutor] in
                await effectExecutor.enqueue([effect], pluginID: pluginID, permissions: permissions)
            }
        case .pluginEvent:
            guard Self.isPluginEventCapabilityAllowed(action.capability) else { return }
            let event = PluginEvent(
                id: UUID(),
                kind: .pluginActionInvoked,
                timestamp: Date(),
                session: nil,
                hook: nil,
                action: PluginActionEvent(
                    pluginID: pluginID,
                    actionID: action.id,
                    componentID: componentID,
                    capability: action.capability,
                    payload: action.payload,
                    value: nil
                ),
                approval: nil
            )
            enqueue(event)
        }
    }

    private nonisolated static func isPluginEventCapabilityAllowed(_ capability: String) -> Bool {
        capability.hasPrefix("plugin.") || capability.hasPrefix("timer.")
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
        guard isDraining else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    /// Reports which UI surfaces are currently visible so `needsTick` can decide
    /// whether a plugin should keep updating. v1 has a single reporter (the notch),
    /// so a full replace is correct; per-source merging waits until menubar reports too.
    func setVisibleSurfaces(_ surfaces: Set<PluginUISlot>) {
        visibleSurfaces = surfaces
    }

    /// Starts the central 1Hz tick loop. Idempotent so the delayed app-start path
    /// (after other DevIsland instances terminate) cannot spin up a second loop.
    func startTicking() {
        guard isEnabled, tickTask == nil else { return }
        tickStartCount += 1
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                guard let self else { break }
                await self.tickIfNeeded()
            }
        }
    }

    /// Cancels the tick loop on app termination or platform shutdown.
    func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// `[weak self]` already prevents the tick loop from retaining the host, so there
    /// is no leak; this defensively stops a lingering sleep cycle if a host is dropped
    /// without `stopTicking()` (e.g. short-lived test instances).
    deinit {
        tickTask?.cancel()
    }

    /// Emits `plugin.tick` only when at least one active runner reports it needs a tick.
    /// safemode exclusion is added in PR 11; for now only host-level disable gates ticking.
    func tickIfNeeded() async {
        guard isEnabled else { return }
        let state = PluginSurfaceState(visibleSurfaces: visibleSurfaces)
        var anyNeedsTick = false
        for runner in runners.values {
            if await runner.needsTick(surfaceState: state) {
                anyNeedsTick = true
                break
            }
        }
        guard anyNeedsTick else { return }
        enqueue(PluginEvent(
            id: UUID(),
            kind: .pluginTick,
            timestamp: Date(),
            session: nil,
            hook: nil,
            action: nil,
            approval: nil
        ))
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
        finishDraining()
    }

    private func finishDraining() {
        isDraining = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
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

            updated = removeContributions(
                pluginID: snapshot.pluginID,
                slots: snapshot.evaluatedSlots,
                sessionID: snapshot.sessionID,
                from: updated
            )

            for (slot, contribution) in snapshot.contributions {
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

    func pruneExpiredContributions(now: Date = Date()) {
        let updated = pruneExpiredContributions(from: contributions, now: now)
        guard updated != contributions else { return }
        contributions = updated
    }

    /// Read-only view of a plugin's durable storage (used by tests; later by the
    /// settings UI). Reading never blocks the hook/approval path.
    func pluginStorageSnapshot(forPluginID pluginID: String) async -> [String: String] {
        await storageProvider.snapshot(forPluginID: pluginID)
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
            let permissions = runners[batch.pluginID]?.manifest.permissions ?? []
            await effectExecutor.enqueue(
                batch.effects,
                pluginID: batch.pluginID,
                permissions: permissions
            )
        }
    }

    private func removeContributions(
        pluginID: String,
        from current: [PluginUISlot: [PluginUIContribution]]
    ) -> [PluginUISlot: [PluginUIContribution]] {
        removeContributions(
            pluginID: pluginID,
            slots: Set(current.keys),
            sessionID: nil,
            from: current
        )
    }

    private func removeContributions(
        pluginID: String,
        slots: Set<PluginUISlot>,
        sessionID: String?,
        from current: [PluginUISlot: [PluginUIContribution]]
    ) -> [PluginUISlot: [PluginUIContribution]] {
        var updated = current
        for slot in slots {
            if Self.isSessionScoped(slot) {
                if let sessionID {
                    updated[slot]?.removeAll {
                        $0.pluginID == pluginID && $0.targetSessionID == sessionID
                    }
                }
            } else {
                updated[slot]?.removeAll { $0.pluginID == pluginID }
            }
            if updated[slot]?.isEmpty == true {
                updated.removeValue(forKey: slot)
            }
        }
        return updated
    }

    private func recordFailure(_ failure: PluginFailure) {
        failures.append(failure)
    }

    private func scheduleExpirationPrune() {
        expirationTimer?.invalidate()

        let now = Date()
        let updated = pruneExpiredContributions(from: contributions, now: now)
        if updated != contributions {
            contributions = updated
            return
        }

        let nextExpiration = contributions.values
            .flatMap { $0 }
            .compactMap(\.expiresAt)
            .min()
        guard let nextExpiration else { return }

        expirationTimer = Timer.scheduledTimer(
            withTimeInterval: max(0, nextExpiration.timeIntervalSince(now)),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneExpiredContributions()
            }
        }
    }

    private func pruneExpiredContributions(
        from current: [PluginUISlot: [PluginUIContribution]],
        now: Date
    ) -> [PluginUISlot: [PluginUIContribution]] {
        var updated: [PluginUISlot: [PluginUIContribution]] = [:]
        for (slot, slotContributions) in current {
            let active = activePluginContributions(slotContributions, now: now)
            if !active.isEmpty {
                updated[slot] = active
            }
        }
        return updated
    }

    private nonisolated static func isSessionScoped(_ slot: PluginUISlot) -> Bool {
        switch slot {
        case .notchSessionRow,
             .sessionDetailTimeline,
             .sessionDetailSummary,
             .sessionContextMenu,
             .sessionMessage:
            return true
        case .notchExpandedActivity,
             .notchExpandedDetails,
             .menubarMenu:
            return false
        }
    }

}
