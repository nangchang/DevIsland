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
    private let powerSleepHandler: PluginEffectExecutor.PowerSleepHandler?
    private let powerToggleHandler: PluginEffectExecutor.PowerToggleHandler?
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
        powerSleepHandler: powerSleepHandler,
        powerToggleHandler: powerToggleHandler
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

    /// Host Command Catalog handler for validated `session.*` commands, injected by
    /// `AppState` after registration. `nil` (e.g. in tests) makes session commands no-op.
    /// The handler re-validates the target session's state before acting (architecture §7).
    var sessionCommandHandler: (@MainActor (_ capability: String, _ sessionID: String) -> Void)?

    /// Supplies the session the user is currently viewing (selected/current), pulled at
    /// drain time so contributions can render for the user's selection instead of a recency
    /// proxy. Injected by `AppState`; `nil` (e.g. in tests) means no selection signal.
    var selectedSessionProvider: (@MainActor () -> String?)?

    nonisolated init(
        enablePlugins: Bool = true,
        pluginDataDirectory: URL = PluginStorageProvider.defaultDirectory,
        powerSleepHandler: PluginEffectExecutor.PowerSleepHandler? = nil,
        powerToggleHandler: PluginEffectExecutor.PowerToggleHandler? = nil
    ) {
        self.isEnabled = enablePlugins
        self.storageProvider = PluginStorageProvider(baseDirectory: pluginDataDirectory)
        self.powerSleepHandler = powerSleepHandler
        self.powerToggleHandler = powerToggleHandler
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

    /// The declarative settings schema a plugin exposes, for the host-owned settings UI.
    /// Empty when the plugin declares none or is not registered.
    func settingsSchema(forPluginID pluginID: String) -> [PluginSettingDescriptor] {
        runners[pluginID]?.settingsSchema ?? []
    }

    /// Notifies a plugin that its own settings changed so it can rebuild contributions.
    /// Restricted to that plugin only (a plugin reacts to its own settings — design §v1.3).
    /// The latest values are re-read at drain time, so the new values reach the plugin's
    /// `PluginContext` on this event.
    func pluginSettingChanged(pluginID: String) {
        guard isEnabled, runners[pluginID] != nil else { return }
        enqueue(eventFactory.makeLifecycleEvent(kind: .settingsChanged), restrictedTo: pluginID)
    }

    /// Resolves persisted setting values against each plugin's schema on the MainActor before
    /// the async hop, mirroring how `selectedSessionID` is pulled. Every schema key is present
    /// in the result (stored value validated, or the descriptor default), so plugins read
    /// settings without missing-key handling.
    private func resolveSettings(
        for runners: [PluginRunner]
    ) -> [String: [String: PluginSettingValue]] {
        guard let store = settingsStore else { return [:] }
        var result: [String: [String: PluginSettingValue]] = [:]
        for runner in runners where !runner.settingsSchema.isEmpty {
            let stored = store.settings(forPluginID: runner.manifest.id)
            var resolved: [String: PluginSettingValue] = [:]
            for descriptor in runner.settingsSchema {
                resolved[descriptor.key] = descriptor.validated(stored[descriptor.key])
            }
            result[runner.manifest.id] = resolved
        }
        return result
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
                let handler = powerSleepHandler
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
            let handler = powerSleepHandler
            Task {
                await handler?(false, "off")
            }
        }
    }

    /// User-initiated recovery: clears safemode and the plugin's recorded failures so the
    /// settings UI resets its error state, then re-emits `plugin.started` to that plugin.
    /// The plugin is placed on probation (see `recordFailure`) so a single failure after
    /// reset re-enters safemode immediately, preventing a safemode↔reset loop on a
    /// persistently failing plugin.
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
    /// `.hostExecuted` routing runs a host command (session catalog) or effect.
    func handleAction(_ action: PluginUIActionDTO, from pluginID: String, componentID: String) {
        guard let runner = runners[pluginID], isActive(pluginID) else { return }

        switch action.routing {
        case .hostExecuted:
            // Host Command Catalog: `session.*` capabilities need MainActor session state, so
            // they route to `sessionCommandHandler` (AppState) instead of the off-main effect
            // executor. The host gates the permission here (via the catalog); the handler
            // re-validates the *session state* it alone owns. (architecture doc §7/§8)
            if let descriptor = SessionCommandCatalog.descriptor(for: action.capability) {
                guard runner.manifest.permissions.contains(descriptor.requiredPermission),
                      let sessionID = action.payload["sessionID"], !sessionID.isEmpty
                else { return }
                print("[DevIsland] [plugin-cmd] \(pluginID) → \(descriptor.capability) " +
                      "session=\(sessionID.prefix(8)) destructive=\(descriptor.isDestructive)")
                sessionCommandHandler?(descriptor.capability, sessionID)
                return
            }
            guard HostEffectCatalog.isSupported(
                action.capability,
                pluginID: pluginID,
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
                powerStatus: nil
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
            powerStatus: nil
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
        case .powerStatusChanged:
            return permissions.contains(.controlPowerSleep)
        default:
            return true
        }
    }

    /// Re-checks `isActive` at drain time instead of trusting the runner list captured when
    /// the event was enqueued: a plugin disabled or moved to safemode after its event was
    /// queued must not run. The companion `isActive` guard in `applySnapshots` covers the
    /// narrower window where the state changes *during* the `await` below. (PR #261 Codex review)
    private func drainEvents() async {
        while let queued = nextEvent() {
            let activeRunners = queued.runners.filter { isActive($0.manifest.id) }
            let activeQueued = QueuedPluginEvent(baseEvent: queued.baseEvent, runners: activeRunners)
            // Pull the user's current selection on the MainActor before the async hop, so
            // contributions render for the selected session rather than a recency proxy.
            let selectedSessionID = selectedSessionProvider?()
            // Resolve persisted setting values against each plugin's schema here (MainActor)
            // too, so a plugin sees the latest settings on this event.
            let settingsByPlugin = resolveSettings(for: activeRunners)
            let snapshots = await eventProcessor.process(
                activeQueued,
                selectedSessionID: selectedSessionID,
                settingsByPlugin: settingsByPlugin
            )
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

    /// Clears every contribution from a plugin — global and session-scoped (all
    /// `targetSessionID`s) — for disable, safemode, and failure-clear. v1.1 opens the
    /// session slots (`notch.session.row`), so this must drop per-session contributions
    /// too; otherwise a disabled plugin's session-row badges would linger. The
    /// per-event eviction path keeps using the `sessionID`-scoped variant below.
    private func removeContributions(
        pluginID: String,
        from current: [PluginUISlot: [PluginUIContribution]]
    ) -> [PluginUISlot: [PluginUIContribution]] {
        var updated = current
        for slot in Array(current.keys) {
            updated[slot]?.removeAll { $0.pluginID == pluginID }
            if updated[slot]?.isEmpty == true {
                updated.removeValue(forKey: slot)
            }
        }
        return updated
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
