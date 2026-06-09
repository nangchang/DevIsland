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
    private let caffeineHandler: PluginEffectExecutor.CaffeineHandler?
    private let caffeineToggleHandler: PluginEffectExecutor.CaffeineToggleHandler?
    private let eventFactory = PluginEventFactory()
    private lazy var eventProcessor = PluginEventProcessor(
        storageProvider: storageProvider,
        eventFactory: eventFactory
    )
    private lazy var effectExecutor = PluginEffectExecutor(
        storageProvider: storageProvider,
        notificationHandler: { title, body in
            await AppState.presentSharedPluginNotification(title: title, body: body)
        },
        caffeineHandler: caffeineHandler,
        caffeineToggleHandler: caffeineToggleHandler
    )
    private var pendingEvents: [QueuedPluginEvent] = []
    private var isDraining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @Published private(set) var failures: [PluginFailure] = []
    /// Plugins the user disabled (persisted by `PluginSettingsStore`). A disabled
    /// plugin stays registered but is excluded from dispatch and ticking.
    @Published private(set) var disabledPluginIDs: Set<String> = []
    /// Plugins forced inactive after repeated failures. PR 10 owns the state and the
    /// user-facing reset; PR 11 wires the failure-threshold detector that enters it.
    @Published private(set) var safemodePluginIDs: Set<String> = []
    private var expirationTimer: Timer?
    private var tickTask: Task<Void, Never>?
    private var visibleSurfaces: Set<PluginUISlot> = []
    /// Incremented only after the start guard passes, so tests can assert the
    /// tick loop starts at most once without observing the live timer.
    private(set) var tickStartCount = 0
    private var probationPluginIDs: Set<String> = []
    private var failureTimestamps: [String: [Date]] = [:]
    private var settingsStore: PluginSettingsStore?
    private var lastResetTimestamps: [String: Date] = [:]

    nonisolated init(
        enablePlugins: Bool = true,
        pluginDataDirectory: URL = PluginStorageProvider.defaultDirectory,
        caffeineHandler: PluginEffectExecutor.CaffeineHandler? = nil,
        caffeineToggleHandler: PluginEffectExecutor.CaffeineToggleHandler? = nil
    ) {
        self.isEnabled = enablePlugins
        self.storageProvider = PluginStorageProvider(baseDirectory: pluginDataDirectory)
        self.caffeineHandler = caffeineHandler
        self.caffeineToggleHandler = caffeineToggleHandler
    }

    /// Registers the built-in plugins. `disabledPluginIDs` must be supplied here so the
    /// disabled set is applied *before* the first lifecycle emission — otherwise a
    /// persisted-disabled plugin would run for one cycle on launch.
    func register(
        _ plugins: [any DevIslandPlugin & Sendable],
        disabledPluginIDs: Set<String> = [],
        settingsStore: PluginSettingsStore? = nil
    ) {
        guard isEnabled else { return }
        let store = settingsStore ?? PluginSettingsStore.shared
        self.settingsStore = store
        runners = Dictionary(
            uniqueKeysWithValues: plugins.map { plugin in
                let runner = PluginRunner(plugin: plugin)
                return (runner.manifest.id, runner)
            }
        )
        self.disabledPluginIDs = disabledPluginIDs.filter { runners[$0] != nil }

        // Startup probation recovery:
        let storedSafemode = store.safemodePluginIDs
        for id in storedSafemode where runners[id] != nil {
            self.probationPluginIDs.insert(id)
            store.setSafemode(false, pluginID: id)
        }
        self.safemodePluginIDs = []
    }

    /// Manifests of every registered plugin, sorted by display name for the settings list.
    var registeredPlugins: [PluginManifest] {
        runners.values.map(\.manifest).sorted { $0.name < $1.name }
    }

    func isPluginEnabled(_ pluginID: String) -> Bool {
        !disabledPluginIDs.contains(pluginID)
    }

    func isInSafemode(_ pluginID: String) -> Bool {
        safemodePluginIDs.contains(pluginID)
    }

    /// A plugin receives events and ticks only when it is neither user-disabled nor
    /// in safemode. Both gates share this check so dispatch/tick stay consistent.
    private func isActive(_ pluginID: String) -> Bool {
        !disabledPluginIDs.contains(pluginID) && !safemodePluginIDs.contains(pluginID)
    }

    /// Enables or disables a registered plugin. Disabling clears its cached
    /// contributions; enabling re-emits `plugin.started` to that plugin only so it can
    /// rebuild without disturbing other plugins.
    func setPluginEnabled(_ enabled: Bool, pluginID: String) {
        guard isEnabled, runners[pluginID] != nil else { return }
        if enabled {
            guard disabledPluginIDs.contains(pluginID) else { return }
            disabledPluginIDs.remove(pluginID)
            enqueue(eventFactory.makeLifecycleEvent(kind: .pluginStarted), restrictedTo: pluginID)
        } else {
            disabledPluginIDs.insert(pluginID)
            contributions = removeContributions(pluginID: pluginID, from: contributions)
            if pluginID == "caffeine" {
                let handler = caffeineHandler
                Task {
                    await handler?(false, "off")
                }
            }
        }
    }

    /// Flags a plugin inactive and clears its contributions. Exposed as the seam PR 11's
    /// failure-threshold detector calls; entering safemode without the dispatch exclusion
    /// would let the next event re-run the plugin and undo the clear.
    func enterSafemode(pluginID: String) {
        guard runners[pluginID] != nil, !safemodePluginIDs.contains(pluginID) else { return }
        safemodePluginIDs.insert(pluginID)
        settingsStore?.setSafemode(true, pluginID: pluginID)
        contributions = removeContributions(pluginID: pluginID, from: contributions)
        if pluginID == "caffeine" {
            let handler = caffeineHandler
            Task {
                await handler?(false, "off")
            }
        }
    }

    /// User-initiated recovery: clears safemode and the plugin's recorded failures so the
    /// settings UI resets its error state. The plugin reactivates and rebuilds on the next
    /// natural event; the limited automatic retry is added in PR 11.
    // TODO: [PR 11] reset 후 제어된 plugin.started 재발행 (1회 제한 재시도) 추가.
    // 즉시 재발행하면 동일 오류 반복 시 safemode↔reset 루프 위험이 있으므로,
    // failure threshold와 함께 1회 재시도 + 재실패 시 safemode 재진입으로 구현. (PR #261 Gemini review)
    func resetPlugin(pluginID: String) {
        guard runners[pluginID] != nil else { return }
        safemodePluginIDs.remove(pluginID)
        settingsStore?.setSafemode(false, pluginID: pluginID)
        failures.removeAll { $0.pluginID == pluginID }
        failureTimestamps[pluginID] = []
        probationPluginIDs.insert(pluginID)
        lastResetTimestamps[pluginID] = Date()
        
        enqueue(eventFactory.makeLifecycleEvent(kind: .pluginStarted), restrictedTo: pluginID)
    }

    /// Clears a plugin's durable storage. Fire-and-forget so the settings UI never blocks
    /// on storage I/O.
    func resetStorage(forPluginID pluginID: String) {
        Task { [storageProvider] in
            await storageProvider.reset(pluginID: pluginID)
        }
    }

    /// Routes a UI action from the plugin that owns `pluginID`.
    /// `.pluginEvent` routing enqueues a pluginActionInvoked event back to that plugin.
    /// `.hostExecuted` routing sends the action through the same host effect executor.
    func handleAction(_ action: PluginUIActionDTO, from pluginID: String, componentID: String) {
        guard let runner = runners[pluginID], isActive(pluginID) else { return }

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
                approval: nil,
                caffeineStatus: nil
            )
            enqueue(event)
        }
    }

    private nonisolated static func isPluginEventCapabilityAllowed(_ capability: String) -> Bool {
        capability.hasPrefix("plugin.") || capability.hasPrefix("timer.")
    }

    func enqueue(_ event: PluginEvent) {
        guard isEnabled else { return }
        appendAndDrain(event, eligibleRunners: runners.values.filter { shouldDispatch(event, to: $0) })
    }

    /// Enqueues an event for a single plugin only (used when re-enabling a plugin so
    /// `plugin.started` does not re-fire to every other plugin).
    private func enqueue(_ event: PluginEvent, restrictedTo pluginID: String) {
        guard isEnabled, let runner = runners[pluginID], shouldDispatch(event, to: runner) else { return }
        appendAndDrain(event, eligibleRunners: [runner])
    }

    private func appendAndDrain(_ event: PluginEvent, eligibleRunners: some Sequence<PluginRunner>) {
        pendingEvents.append(QueuedPluginEvent(baseEvent: event, runners: Array(eligibleRunners)))
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
    /// "Active" excludes user-disabled and safemode plugins (see `isActive`); the
    /// failure-threshold detector that *enters* safemode arrives in PR 11.
    func tickIfNeeded() async {
        guard isEnabled else { return }
        let state = PluginSurfaceState(visibleSurfaces: visibleSurfaces)
        var anyNeedsTick = false
        for runner in runners.values where isActive(runner.manifest.id) {
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
            approval: nil,
            caffeineStatus: nil
        ))
    }

    private func shouldDispatch(_ event: PluginEvent, to runner: PluginRunner) -> Bool {
        guard isActive(runner.manifest.id) else { return false }
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

    // TODO: [PR 11] drain 루프에서 각 queued event의 runner를 처리하기 전에 isActive 재체크 추가.
    // enqueue 시점에 캡처된 runner 리스트가 drain 중 disable/safemode 변경을 반영하지 못하는 갭 해소.
    // @MainActor 직렬화로 실질적 race는 없지만, 방어적 재체크로 견고성 확보. (PR #261 Codex review)
    private func drainEvents() async {
        while let queued = nextEvent() {
            let activeRunners = queued.runners.filter { isActive($0.manifest.id) }
            let activeQueued = QueuedPluginEvent(baseEvent: queued.baseEvent, runners: activeRunners)
            let snapshots = await eventProcessor.process(activeQueued)
            let effectBatches = applySnapshots(snapshots, eventKind: queued.baseEvent.kind)
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

    private func applySnapshots(
        _ snapshots: [PluginContributionSnapshot],
        eventKind: PluginEventKind
    ) -> [PendingEffectBatch] {
        var updated = contributions
        var effectBatches: [PendingEffectBatch] = []

        for snapshot in snapshots {
            // Discard snapshots for disabled/safemoded plugins or stale snapshots from before the last reset
            guard isActive(snapshot.pluginID) else { continue }
            if let lastReset = lastResetTimestamps[snapshot.pluginID],
               snapshot.timestamp < lastReset {
                continue
            }

            if let failure = snapshot.failure {
                recordFailure(failure)
                if safemodePluginIDs.contains(snapshot.pluginID) {
                    updated = removeContributions(pluginID: snapshot.pluginID, from: updated)
                    continue
                }
                if failure.clearsContribution {
                    updated = removeContributions(pluginID: snapshot.pluginID, from: updated)
                    continue
                }
            } else {
                if eventKind != .pluginStarted && eventKind != .appStarted {
                    probationPluginIDs.remove(snapshot.pluginID)
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

    /// Clears all of a plugin's global contributions (disable, safemode, failure-clear).
    /// Forwards `sessionID: nil`, so the session-scoped branch in the call below does not
    /// remove session-keyed contributions. Unreachable in v1 — no built-in declares
    /// `.showSessionSurface` — but revisit when the v1.1/M4 session slots open so that
    /// disabling a plugin also evicts its per-session contributions.
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
        let pluginID = failure.pluginID

        if probationPluginIDs.contains(pluginID) {
            probationPluginIDs.remove(pluginID)
            enterSafemode(pluginID: pluginID)
            return
        }

        let now = failure.occurredAt
        var times = failureTimestamps[pluginID, default: []]
        times.append(now)
        times = times.filter { now.timeIntervalSince($0) <= 60 }
        failureTimestamps[pluginID] = times

        if times.count >= 3 {
            enterSafemode(pluginID: pluginID)
        }
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
