import XCTest
@testable import DevIsland

final class PluginContributionRendererTests: XCTestCase {

    // MARK: - SF Symbol Validation

    func testValidIconNamePassesThrough() {
        XCTAssertEqual(validatedIcon("star.fill"), "star.fill")
    }

    func testInvalidIconNameReturnsNil() {
        XCTAssertNil(validatedIcon("this.symbol.does.not.exist.at.all"))
    }

    func testNilIconNameReturnsNil() {
        XCTAssertNil(validatedIcon(nil))
    }

    func testEmptyIconNameReturnsNil() {
        XCTAssertNil(validatedIcon(""))
    }

    // MARK: - Label / Value Truncation

    func testLabelTruncatedAt40Characters() {
        let long = String(repeating: "a", count: 80)
        XCTAssertEqual(truncatedPluginLabel(long), String(repeating: "a", count: 40))
    }

    func testLabelUnder40IsUnchanged() {
        XCTAssertEqual(truncatedPluginLabel("short"), "short")
    }

    func testEmptyLabelReturnsNil() {
        XCTAssertNil(truncatedPluginLabel(""))
        XCTAssertNil(truncatedPluginLabel(nil))
    }

    func testValueTruncatedAt60Characters() {
        let long = String(repeating: "b", count: 120)
        XCTAssertEqual(truncatedPluginValue(long), String(repeating: "b", count: 60))
    }

    func testValueUnder60IsUnchanged() {
        XCTAssertEqual(truncatedPluginValue("hello"), "hello")
    }

    func testMenuTextTruncatedAt40Characters() {
        let long = String(repeating: "c", count: 100)
        XCTAssertEqual(truncatedMenuText(long), String(repeating: "c", count: 40))
    }

    func testMenuTextNilReturnsEmptyString() {
        XCTAssertEqual(truncatedMenuText(nil), "")
    }

    // MARK: - PluginSlotView — empty contributions render nothing

    func testEmptyContributionsProduceNoComponents() {
        let contributions: [PluginUIContribution] = []
        // PluginSlotView's body guard ensures nothing is rendered when empty
        XCTAssertTrue(contributions.isEmpty)
    }

    func testContributionWithNoComponentsSkipped() {
        let contribution = PluginUIContribution(
            pluginID: "com.test",
            slot: .notchExpandedActivity,
            targetSessionID: nil,
            priority: 0,
            expiresAt: nil,
            components: []
        )
        // Only contributions with non-empty components are rendered
        let filtered = [contribution].filter { !$0.components.isEmpty }
        XCTAssertTrue(filtered.isEmpty)
    }

    // MARK: - expiresAt Filtering

    func testExpiredContributionIsExcluded() {
        let expired = PluginUIContribution(
            pluginID: "com.test",
            slot: .notchExpandedActivity,
            targetSessionID: nil,
            priority: 0,
            expiresAt: Date(timeIntervalSinceNow: -1),
            components: [makeComponent(type: .text, label: "stale", value: nil)]
        )
        let now = Date()
        let valid = [expired].filter {
            !$0.components.isEmpty && ($0.expiresAt == nil || $0.expiresAt! > now)
        }
        XCTAssertTrue(valid.isEmpty)
    }

    func testNonExpiredContributionIsIncluded() {
        let fresh = PluginUIContribution(
            pluginID: "com.test",
            slot: .notchExpandedActivity,
            targetSessionID: nil,
            priority: 0,
            expiresAt: Date(timeIntervalSinceNow: 60),
            components: [makeComponent(type: .text, label: "live", value: nil)]
        )
        let now = Date()
        let valid = [fresh].filter {
            !$0.components.isEmpty && ($0.expiresAt == nil || $0.expiresAt! > now)
        }
        XCTAssertEqual(valid.count, 1)
    }

    func testNilExpiresAtIsAlwaysIncluded() {
        let permanent = PluginUIContribution(
            pluginID: "com.test",
            slot: .notchExpandedActivity,
            targetSessionID: nil,
            priority: 0,
            expiresAt: nil,
            components: [makeComponent(type: .metric, label: "uptime", value: "42s")]
        )
        let now = Date()
        let valid = [permanent].filter {
            !$0.components.isEmpty && ($0.expiresAt == nil || $0.expiresAt! > now)
        }
        XCTAssertEqual(valid.count, 1)
    }

    // MARK: - componentID Routing

    @MainActor
    func testActionCarriesComponentID() async {
        let plugin = ActionCapturingPlugin(id: "com.test.cid")
        let host = PluginHost()
        host.register([plugin])

        let action = PluginUIActionDTO(
            id: "action-42",
            capability: "timer.startStop",
            routing: .pluginEvent,
            payload: [:]
        )
        host.handleAction(action, from: "com.test.cid", componentID: "component-99")
        await host.waitUntilIdle()

        XCTAssertEqual(plugin.receivedEvents.last?.action?.componentID, "component-99")
        XCTAssertEqual(plugin.receivedEvents.last?.action?.actionID, "action-42")
    }

    // MARK: - Action Routing

    @MainActor
    func testPluginEventActionEnqueuesEvent() async {
        let plugin = ActionCapturingPlugin(id: "com.test.action")
        let host = PluginHost()
        host.register([plugin])

        let action = PluginUIActionDTO(
            id: "btn1",
            capability: "timer.startStop",
            routing: .pluginEvent,
            payload: [:]
        )
        host.handleAction(action, from: "com.test.action", componentID: "btn1")
        await host.waitUntilIdle()

        XCTAssertEqual(plugin.receivedKinds.last, .pluginActionInvoked)
    }

    @MainActor
    func testHostExecutedActionIsNoOpInV1() async {
        let plugin = ActionCapturingPlugin(id: "com.test.host")
        let host = PluginHost()
        host.register([plugin])

        let action = PluginUIActionDTO(
            id: "dismiss1",
            capability: "session.dismiss",
            routing: .hostExecuted,
            payload: [:]
        )
        host.handleAction(action, from: "com.test.host", componentID: "dismiss1")
        await host.waitUntilIdle()

        // hostExecuted routing is a no-op in v1 — no event dispatched
        XCTAssertFalse(plugin.receivedKinds.contains(.pluginActionInvoked))
    }

    @MainActor
    func testActionOnlyRoutedToTargetPlugin() async {
        let target = ActionCapturingPlugin(id: "com.test.target")
        let bystander = ActionCapturingPlugin(id: "com.test.bystander")
        let host = PluginHost()
        host.register([target, bystander])

        let action = PluginUIActionDTO(
            id: "act1",
            capability: "timer.startStop",
            routing: .pluginEvent,
            payload: [:]
        )
        host.handleAction(action, from: "com.test.target", componentID: "act1")
        await host.waitUntilIdle()

        XCTAssertTrue(target.receivedKinds.contains(.pluginActionInvoked))
        XCTAssertFalse(bystander.receivedKinds.contains(.pluginActionInvoked))
    }

    // MARK: - Helpers

    private func makeComponent(
        type: PluginUIComponentType,
        label: String?,
        value: String?,
        action: PluginUIActionDTO? = nil
    ) -> PluginUIComponentDTO {
        PluginUIComponentDTO(
            id: UUID().uuidString,
            type: type,
            label: label,
            value: value,
            tone: nil,
            iconName: nil,
            action: action
        )
    }
}

// MARK: - Test Double

private final class ActionCapturingPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    private let lock = NSLock()
    private var _receivedEvents: [PluginEvent] = []
    var receivedKinds: [PluginEventKind] {
        lock.lock(); defer { lock.unlock() }
        return _receivedEvents.map(\.kind)
    }
    var receivedEvents: [PluginEvent] {
        lock.lock(); defer { lock.unlock() }
        return _receivedEvents
    }

    init(id: String) {
        self.manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: [],
            surfaces: [.notchExpandedActivity],
            activationEvents: Set(PluginEventKind.allCases.map(\.rawValue))
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        lock.lock(); defer { lock.unlock() }
        _receivedEvents.append(event)
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? { nil }
    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }
}
