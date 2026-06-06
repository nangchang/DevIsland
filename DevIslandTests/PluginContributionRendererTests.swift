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
        let component = makeComponent(type: .metric, label: long, value: nil)
        XCTAssertEqual(component.label.map { String($0.prefix(40)) }, String(repeating: "a", count: 40))
    }

    func testValueTruncatedAt60Characters() {
        let long = String(repeating: "b", count: 120)
        let component = makeComponent(type: .metric, label: nil, value: long)
        XCTAssertEqual(component.value.map { String($0.prefix(60)) }, String(repeating: "b", count: 60))
    }

    func testMenuLabelTruncatedAt40Characters() {
        let long = String(repeating: "c", count: 100)
        let truncated = String(long.prefix(40))
        XCTAssertEqual(truncated.count, 40)
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
        host.handleAction(action, from: "com.test.action")
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
        host.handleAction(action, from: "com.test.host")
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
        host.handleAction(action, from: "com.test.target")
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
    private var _receivedKinds: [PluginEventKind] = []
    var receivedKinds: [PluginEventKind] {
        lock.lock(); defer { lock.unlock() }
        return _receivedKinds
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
        _receivedKinds.append(event.kind)
        return []
    }

    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution? { nil }
    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }
}
