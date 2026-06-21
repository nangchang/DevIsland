import XCTest
@testable import DevIsland

@MainActor
final class CompactRegionPluginTests: XCTestCase {
    func testHostEvaluatesOnlySelectedProvider() async {
        let first = RegionTestPlugin(id: "test.region.first")
        let second = RegionTestPlugin(id: "test.region.second")
        var selected = first.manifest.id
        let host = PluginHost()
        host.compactRegionSelectionProvider = { [.notchCompactCenter: selected] }
        host.register([first, second])

        host.enqueue(event(.pluginStarted))
        await host.waitUntilIdle()

        XCTAssertEqual(host.compactRegionContributions[.notchCompactCenter]?.map(\.pluginID), [first.manifest.id])

        selected = second.manifest.id
        host.compactRegionSelectionChanged()
        await host.waitUntilIdle()

        XCTAssertEqual(host.compactRegionContributions[.notchCompactCenter]?.map(\.pluginID), [second.manifest.id])
    }

    func testHostRejectsCompactRegionWithoutPermission() async {
        let plugin = RegionTestPlugin(id: "test.region.unauthorized", permissions: [])
        let host = PluginHost()
        host.compactRegionSelectionProvider = { [.notchCompactCenter: plugin.manifest.id] }
        host.register([plugin])

        host.enqueue(event(.pluginStarted))
        await host.waitUntilIdle()

        XCTAssertTrue(host.compactRegionContributions.isEmpty)
    }

    func testVisibilityEventIsSentOnlyToSelectedProvider() async {
        let selected = RegionTestPlugin(id: "test.region.visible")
        let other = RegionTestPlugin(id: "test.region.not-visible")
        let host = PluginHost()
        host.compactRegionSelectionProvider = { [.notchCompactCenter: selected.manifest.id] }
        host.register([selected, other])

        host.compactRegionsBecameVisible()
        await host.waitUntilIdle()

        XCTAssertEqual(selected.receivedKinds, [.compactRegionShown])
        XCTAssertTrue(other.receivedKinds.isEmpty)
    }

    func testTransientFailureKeepsLastKnownCompactRegionContribution() async {
        let plugin = RegionTestPlugin(id: "test.region.failure")
        let host = PluginHost()
        host.compactRegionSelectionProvider = { [.notchCompactCenter: plugin.manifest.id] }
        host.register([plugin])

        host.enqueue(event(.pluginStarted))
        await host.waitUntilIdle()
        XCTAssertEqual(host.compactRegionContributions[.notchCompactCenter]?.first?.content, .text("active"))

        plugin.shouldFail = true
        host.enqueue(event(.settingsChanged))
        await host.waitUntilIdle()

        XCTAssertEqual(host.compactRegionContributions[.notchCompactCenter]?.first?.content, .text("active"))
        XCTAssertEqual(host.failures.last?.pluginID, plugin.manifest.id)
    }

    func testDisablingProviderClearsCompactRegionContribution() async {
        let plugin = RegionTestPlugin(id: "test.region.disable")
        let host = PluginHost()
        host.compactRegionSelectionProvider = { [.notchCompactCenter: plugin.manifest.id] }
        host.register([plugin])
        host.enqueue(event(.pluginStarted))
        await host.waitUntilIdle()

        host.setPluginEnabled(false, pluginID: plugin.manifest.id)

        XCTAssertTrue(host.compactRegionContributions.isEmpty)
    }

    private func event(_ kind: PluginEventKind) -> PluginEvent {
        PluginEvent(id: UUID(), kind: kind, timestamp: Date())
    }

}

private final class RegionTestPlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest: PluginManifest
    var shouldFail = false
    private(set) var receivedKinds: [PluginEventKind] = []

    init(id: String, permissions: Set<PluginPermission> = [.showCompactRegion]) {
        manifest = PluginManifest(
            id: id,
            name: id,
            version: "1.0.0",
            apiVersion: 1,
            kind: .utility,
            permissions: permissions,
            surfaces: [],
            regions: [.notchCompactCenter],
            activationEvents: [
                PluginEventKind.pluginStarted.rawValue,
                PluginEventKind.compactRegionShown.rawValue,
                PluginEventKind.settingsChanged.rawValue
            ]
        )
    }

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
        receivedKinds.append(event.kind)
        if shouldFail {
            throw NSError(domain: "RegionTestPlugin", code: 1)
        }
        return []
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        nil
    }

    func makeCompactRegionContribution(
        for region: PluginRegionID,
        context: PluginCompactRegionContext
    ) throws -> PluginCompactRegionContribution? {
        PluginCompactRegionContribution(
            pluginID: manifest.id,
            region: region,
            expiresAt: nil,
            content: .text("active")
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool { false }
}
