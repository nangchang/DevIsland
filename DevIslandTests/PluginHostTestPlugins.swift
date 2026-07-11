import XCTest
@testable import DevIsland

final class RecordingPlugin: DevIslandPlugin, @unchecked Sendable {
    struct TestError: Error {}

    let manifest: PluginManifest
    let contribution: PluginUIContribution?
    let throwOnKinds: Set<PluginEventKind>
    let delay: TimeInterval
    let delayOnKinds: Set<PluginEventKind>?
    private let events = LockIsolated<[PluginEvent]>([])
    var receivedEvents: [PluginEvent] {
        events.value
    }
    var receivedKinds: [PluginEventKind] {
        events.value.map(\.kind)
    }

    init(
        id: String,
        name: String? = nil,
        kind: PluginKind = .utility,
        permissions: Set<PluginPermission> = [],
        activationEvents: Set<PluginEventKind>,
        contribution: PluginUIContribution? = nil,
        surfaces: Set<PluginUISlot> = [.notchExpandedActivity],
        throwOnKinds: Set<PluginEventKind> = [],
        delay: TimeInterval = 0,
        delayOnKinds: Set<PluginEventKind>? = nil
    ) {
        self.manifest = PluginManifest(
            id: id,
            name: name ?? id,
            version: "1.0.0",
            apiVersion: 1,
            kind: kind,
            permissions: permissions,
            surfaces: surfaces,
            activationEvents: Set(activationEvents.map(\.rawValue))
        )
        self.contribution = contribution
        self.throwOnKinds = throwOnKinds
        self.delay = delay
        self.delayOnKinds = delayOnKinds
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        let shouldDelay = delayOnKinds?.contains(event.kind) ?? true
        if shouldDelay && delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if throwOnKinds.contains(event.kind) {
            throw TestError()
        }
        events.withValue { $0.append(event) }
        return []
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        contribution
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

/// Deterministically parks inside `onEvent` for the gated event kinds: it signals
/// `entered` once the host is stuck on `await eventProcessor.process`, then blocks on
/// `resume` until the test releases it. This removes the timing dependence of a sleep —
/// the test controls exactly when state changes relative to the in-flight runner.
final class GatedPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let contribution: PluginUIContribution
    private let gateOn: Set<PluginEventKind>
    private let gate: AsyncGate
    private let kinds = LockIsolated<[PluginEventKind]>([])
    var receivedKinds: [PluginEventKind] {
        kinds.value
    }

    init(
        id: String,
        contribution: PluginUIContribution,
        gateOn: Set<PluginEventKind>,
        gate: AsyncGate,
        activationEvents: Set<PluginEventKind> = [.pluginStarted]
    ) {
        self.contribution = contribution
        self.gateOn = gateOn
        self.gate = gate
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [.showNotchCard],
            surfaces: [.notchExpandedActivity],
            activationEvents: Set(activationEvents.map(\.rawValue))
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        kinds.withValue { $0.append(event.kind) }
        if gateOn.contains(event.kind) {
            await gate.enterAndWaitForResume()
        }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        contribution
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

final class ScopedReaderPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let readTextStorage = LockIsolated<String?>(nil)
    private let sawMissingClientStorage = LockIsolated(false)

    var readText: String? {
        readTextStorage.value
    }

    var sawMissingClient: Bool {
        sawMissingClientStorage.value
    }

    init(id: String, permissions: Set<PluginPermission>) {
        manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: permissions,
            surfaces: [],
            activationEvents: [PluginEventKind.pluginStarted.rawValue]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        guard let scopedFiles = context.scopedFiles else {
            sawMissingClientStorage.withValue { $0 = true }
            return []
        }
        let text = try await scopedFiles.readText(scopeID: "packs", relativePath: "manifest.txt")
        readTextStorage.withValue { $0 = text }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        nil
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

final class VisibilityTickingPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let tickSurface: PluginUISlot
    private let kinds = LockIsolated<[PluginEventKind]>([])
    var receivedKinds: [PluginEventKind] {
        kinds.value
    }

    init(id: String, tickSurface: PluginUISlot = .notchExpandedActivity) {
        self.tickSurface = tickSurface
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [],
            surfaces: [],
            activationEvents: [PluginEventKind.pluginTick.rawValue]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        kinds.withValue { $0.append(event.kind) }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        nil
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        surfaceState.visibleSurfaces.contains(tickSurface)
    }
}

/// Contributes a session-scoped row badge whose value changes on every evaluation, so a test
/// can detect whether a session-bearing tick re-evaluated the slot. Tracks sessions from
/// `session.started` and ticks while the row surface is visible.
final class SessionRowTickPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let state = LockIsolated((trackedSessionIDs: Set<String>(), rowEvalCount: 0))

    init(id: String) {
        manifest = PluginManifest(
            id: id, name: id, version: "1.0.0", apiVersion: 1, kind: .system,
            permissions: [.readSessionEvents, .showSessionSurface],
            surfaces: [.notchSessionRow],
            activationEvents: [
                PluginEventKind.sessionStarted.rawValue,
                PluginEventKind.pluginTick.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        if event.kind == .sessionStarted, let session = event.session {
            state.withValue { $0.trackedSessionIDs.insert(session.id) }
        }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        guard slot == .notchSessionRow, let session = context.session else { return nil }
        guard let count = state.withValue({ state -> Int? in
            guard state.trackedSessionIDs.contains(session.id) else { return nil }
            state.rowEvalCount += 1
            return state.rowEvalCount
        }) else { return nil }
        return PluginUIContribution(
            pluginID: manifest.id, slot: slot, targetSessionID: session.id,
            priority: 10, expiresAt: nil,
            components: [PluginUIComponentDTO(id: "c", type: .text, label: nil,
                value: "\(count)", tone: nil, iconName: nil, action: nil)]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        surfaceState.visibleSurfaces.contains(.notchSessionRow)
    }
}

final class RotatingContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let lock = NSLock()
    private let slot: PluginUISlot
    private let targetSessionIDs: [String?]
    private var index = 0

    init(
        id: String,
        slot: PluginUISlot,
        targetSessionIDs: [String?],
        permissions: Set<PluginPermission>
    ) {
        self.slot = slot
        self.targetSessionIDs = targetSessionIDs
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: permissions,
            surfaces: [slot],
            activationEvents: [
                PluginEventKind.pluginStarted.rawValue,
                PluginEventKind.pluginTick.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        []
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        lock.lock()
        let targetSessionID = targetSessionIDs[min(index, targetSessionIDs.count - 1)]
        index += 1
        lock.unlock()

        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: targetSessionID,
            priority: 10,
            expiresAt: nil,
            components: [
                PluginUIComponentDTO(
                    id: "status",
                    type: .text,
                    label: "Status",
                    value: targetSessionID ?? "global",
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

final class ToggleContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let shouldRender = LockIsolated(true)

    init(id: String, permissions: Set<PluginPermission>) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: permissions,
            surfaces: [.notchExpandedActivity],
            activationEvents: [
                PluginEventKind.pluginStarted.rawValue,
                PluginEventKind.pluginTick.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        if event.kind == .pluginTick {
            shouldRender.withValue { $0 = false }
        }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        guard shouldRender.value else { return nil }

        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: nil,
            priority: 10,
            expiresAt: nil,
            components: [
                PluginUIComponentDTO(
                    id: "status",
                    type: .text,
                    label: "Status",
                    value: "Ready",
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

final class ExpiringContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest

    init(id: String, permissions: Set<PluginPermission>) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: permissions,
            surfaces: [.notchExpandedActivity],
            activationEvents: [PluginEventKind.pluginStarted.rawValue]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: nil,
            priority: 10,
            expiresAt: Date(timeIntervalSinceNow: -1),
            components: [
                PluginUIComponentDTO(
                    id: "status",
                    type: .text,
                    label: "Expired",
                    value: nil,
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

final class SessionScopedContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest

    init(id: String) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [.readSessionEvents, .showSessionSurface],
            surfaces: [.sessionDetailSummary],
            activationEvents: [PluginEventKind.sessionUpdated.rawValue]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        guard let sessionID = context.session?.id else { return nil }
        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: sessionID,
            priority: 10,
            expiresAt: nil,
            components: [
                PluginUIComponentDTO(
                    id: "summary-\(sessionID)",
                    type: .text,
                    label: sessionID,
                    value: "Active",
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

final class ToggleSessionScopedContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let hiddenSessionIDs = LockIsolated<Set<String>>([])

    init(id: String) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [.readSessionEvents, .showSessionSurface],
            surfaces: [.sessionDetailSummary],
            activationEvents: [
                PluginEventKind.sessionUpdated.rawValue,
                PluginEventKind.pluginTick.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        if event.kind == .pluginTick, let sessionID = event.session?.id {
            hiddenSessionIDs.withValue { $0.insert(sessionID) }
        }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        guard let sessionID = context.session?.id else { return nil }
        guard !hiddenSessionIDs.value.contains(sessionID) else { return nil }

        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: sessionID,
            priority: 10,
            expiresAt: nil,
            components: [
                PluginUIComponentDTO(
                    id: "summary-\(sessionID)",
                    type: .text,
                    label: sessionID,
                    value: "Active",
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

final class GlobalToggleSessionScopedContributionPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let hideAll = LockIsolated(false)

    init(id: String) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [.readSessionEvents, .showSessionSurface],
            surfaces: [.sessionDetailSummary],
            activationEvents: [
                PluginEventKind.sessionUpdated.rawValue,
                PluginEventKind.pluginTick.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        if event.kind == .pluginTick {
            hideAll.withValue { $0 = true }
        }
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? {
        guard !hideAll.value, let sessionID = context.session?.id else { return nil }

        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: sessionID,
            priority: 10,
            expiresAt: nil,
            components: [
                PluginUIComponentDTO(
                    id: "summary-\(sessionID)",
                    type: .text,
                    label: sessionID,
                    value: "Active",
                    tone: nil,
                    iconName: nil,
                    action: nil
                )
            ]
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}

final class ProbationTestPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let shouldThrowStorage = LockIsolated(false)
    var shouldThrow: Bool {
        get {
            shouldThrowStorage.value
        }
        set {
            shouldThrowStorage.withValue { $0 = newValue }
        }
    }

    init(id: String) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [.showNotchCard],
            surfaces: [.notchExpandedActivity],
            activationEvents: ["plugin.started", "plugin.tick"]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        if shouldThrow {
            throw RecordingPlugin.TestError()
        }
        return []
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        nil
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        false
    }
}
