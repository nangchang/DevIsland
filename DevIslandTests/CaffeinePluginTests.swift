import XCTest
@testable import DevIsland

final class CaffeinePluginTests: XCTestCase {

    private func makePlugin() -> CaffeinePlugin {
        return CaffeinePlugin()
    }

    private func makeContext() -> PluginContext {
        return PluginContext(pluginID: "caffeine", permissions: [.controlPowerSleep], storageSnapshot: [:])
    }

    func testPluginManifest() {
        let plugin = makePlugin()
        XCTAssertEqual(plugin.manifest.id, "caffeine")
        XCTAssertTrue(plugin.manifest.permissions.contains(.controlPowerSleep))
        XCTAssertTrue(plugin.manifest.permissions.contains(.showMenubarMenu))
    }

    func testDisabledReturnsFalse() throws {
        let plugin = makePlugin()
        let status = PluginPowerStatus(
            caffeineEnabled: false,
            excludedSSIDs: [],
            isOnACPower: true,
            batteryLevel: 0.9,
            currentSSID: "Home"
        )
        let event = PluginEvent(
            id: UUID(),
            kind: .powerStatusChanged,
            timestamp: Date(),
            powerStatus: status
        )

        let effects = try plugin.onEvent(event, context: makeContext())
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects[0].capability, "power.preventIdleSleep")
        XCTAssertEqual(effects[0].payload["preventSleep"], "false")
        XCTAssertEqual(effects[0].payload["reason"], "off")

        // Menu contribution
        let contribution = try plugin.makeUIContribution(for: .menubarMenu, context: PluginUIContext(slot: .menubarMenu, timestamp: Date(), session: nil))
        XCTAssertNotNil(contribution)
        let statusComponent = contribution?.components.first(where: { $0.id == "caffeine-status" })
        XCTAssertEqual(statusComponent?.value, "Disabled")
        let toggleComponent = contribution?.components.first(where: { $0.id == "caffeine-toggle" })
        XCTAssertEqual(toggleComponent?.label, "Turn On")
    }

    func testKoreanMenuContributionComesFromPluginContext() throws {
        let plugin = makePlugin()
        let status = PluginPowerStatus(
            caffeineEnabled: false,
            excludedSSIDs: [],
            isOnACPower: true,
            batteryLevel: 0.9,
            currentSSID: "Home"
        )
        let event = PluginEvent(
            id: UUID(),
            kind: .powerStatusChanged,
            timestamp: Date(),
            powerStatus: status
        )

        _ = try plugin.onEvent(event, context: makeContext())
        let contribution = try plugin.makeUIContribution(
            for: .menubarMenu,
            context: PluginUIContext(slot: .menubarMenu, timestamp: Date(), session: nil, language: .korean)
        )
        let statusComponent = contribution?.components.first(where: { $0.id == "caffeine-status" })
        XCTAssertEqual(statusComponent?.value, "비활성화됨")
        let toggleComponent = contribution?.components.first(where: { $0.id == "caffeine-toggle" })
        XCTAssertEqual(toggleComponent?.label, "켜기")
    }

    func testOnACOnNormalBatteryHolds() throws {
        let plugin = makePlugin()
        let status = PluginPowerStatus(
            caffeineEnabled: true,
            excludedSSIDs: ["Office-Internal"],
            isOnACPower: true,
            batteryLevel: 0.8,
            currentSSID: "Home"
        )
        let event = PluginEvent(
            id: UUID(),
            kind: .powerStatusChanged,
            timestamp: Date(),
            powerStatus: status
        )

        let effects = try plugin.onEvent(event, context: makeContext())
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects[0].capability, "power.preventIdleSleep")
        XCTAssertEqual(effects[0].payload["preventSleep"], "true")
        XCTAssertEqual(effects[0].payload["reason"], "onAC")

        // Menu contribution
        let contribution = try plugin.makeUIContribution(for: .menubarMenu, context: PluginUIContext(slot: .menubarMenu, timestamp: Date(), session: nil))
        XCTAssertNotNil(contribution)
        let statusComponent = contribution?.components.first(where: { $0.id == "caffeine-status" })
        XCTAssertEqual(statusComponent?.value, "Preventing sleep (AC Power)")
        let toggleComponent = contribution?.components.first(where: { $0.id == "caffeine-toggle" })
        XCTAssertEqual(toggleComponent?.label, "Turn Off")
    }

    func testExcludedSSIDReleases() throws {
        let plugin = makePlugin()
        let status = PluginPowerStatus(
            caffeineEnabled: true,
            excludedSSIDs: ["Office-Internal", "Guest"],
            isOnACPower: true,
            batteryLevel: 0.8,
            currentSSID: "Office-Internal"
        )
        let event = PluginEvent(
            id: UUID(),
            kind: .powerStatusChanged,
            timestamp: Date(),
            powerStatus: status
        )

        let effects = try plugin.onEvent(event, context: makeContext())
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects[0].capability, "power.preventIdleSleep")
        XCTAssertEqual(effects[0].payload["preventSleep"], "false")
        XCTAssertEqual(effects[0].payload["reason"], "excludedSSID:Office-Internal")

        // Menu contribution
        let contribution = try plugin.makeUIContribution(for: .menubarMenu, context: PluginUIContext(slot: .menubarMenu, timestamp: Date(), session: nil))
        XCTAssertNotNil(contribution)
        let statusComponent = contribution?.components.first(where: { $0.id == "caffeine-status" })
        XCTAssertEqual(statusComponent?.value, "Excluded Wi-Fi (Office-Internal)")
    }

    func testExcludedSSIDPreservesEmbeddedPrefixText() throws {
        let plugin = makePlugin()
        let status = PluginPowerStatus(
            caffeineEnabled: true,
            excludedSSIDs: ["Guest-excludedSSID:Lab"],
            isOnACPower: true,
            batteryLevel: 0.8,
            currentSSID: "Guest-excludedSSID:Lab"
        )
        let event = PluginEvent(
            id: UUID(),
            kind: .powerStatusChanged,
            timestamp: Date(),
            powerStatus: status
        )

        _ = try plugin.onEvent(event, context: makeContext())
        let contribution = try plugin.makeUIContribution(
            for: .menubarMenu,
            context: PluginUIContext(slot: .menubarMenu, timestamp: Date(), session: nil)
        )
        let statusComponent = contribution?.components.first(where: { $0.id == "caffeine-status" })
        XCTAssertEqual(statusComponent?.value, "Excluded Wi-Fi (Guest-excludedSSID:Lab)")
    }

    func testOnBatteryReleases() throws {
        let plugin = makePlugin()
        let status = PluginPowerStatus(
            caffeineEnabled: true,
            excludedSSIDs: [],
            isOnACPower: false,
            batteryLevel: 0.6,
            currentSSID: "Home"
        )
        let event = PluginEvent(
            id: UUID(),
            kind: .powerStatusChanged,
            timestamp: Date(),
            powerStatus: status
        )

        let updateEffects = try plugin.onEvent(event, context: makeContext())
        XCTAssertEqual(updateEffects[0].payload["preventSleep"], "false")
        XCTAssertEqual(updateEffects[0].payload["reason"], "onBattery")

        // Menu contribution
        let contribution = try plugin.makeUIContribution(for: .menubarMenu, context: PluginUIContext(slot: .menubarMenu, timestamp: Date(), session: nil))
        XCTAssertNotNil(contribution)
        let statusComponent = contribution?.components.first(where: { $0.id == "caffeine-status" })
        XCTAssertEqual(statusComponent?.value, "Battery Mode")
    }

    func testLowBatteryReleasesEvenOnAC() throws {
        let plugin = makePlugin()
        let status = PluginPowerStatus(
            caffeineEnabled: true,
            excludedSSIDs: [],
            isOnACPower: true,
            batteryLevel: 0.18,
            currentSSID: "Home"
        )
        let event = PluginEvent(
            id: UUID(),
            kind: .powerStatusChanged,
            timestamp: Date(),
            powerStatus: status
        )

        let effects = try plugin.onEvent(event, context: makeContext())
        XCTAssertEqual(effects[0].payload["preventSleep"], "false")
        XCTAssertEqual(effects[0].payload["reason"], "lowBattery")

        // Menu contribution
        let contribution = try plugin.makeUIContribution(for: .menubarMenu, context: PluginUIContext(slot: .menubarMenu, timestamp: Date(), session: nil))
        XCTAssertNotNil(contribution)
        let statusComponent = contribution?.components.first(where: { $0.id == "caffeine-status" })
        XCTAssertEqual(statusComponent?.value, "Low Battery")
    }

    func testAssertionFailureResultUpdatesMenuWithoutReemittingEffect() throws {
        let plugin = makePlugin()
        let initialStatus = PluginPowerStatus(
            caffeineEnabled: true,
            excludedSSIDs: [],
            isOnACPower: true,
            batteryLevel: 0.9,
            currentSSID: "Home"
        )
        _ = try plugin.onEvent(
            PluginEvent(id: UUID(), kind: .powerStatusChanged, timestamp: Date(), powerStatus: initialStatus),
            context: makeContext()
        )

        let failureStatus = PluginPowerStatus(
            caffeineEnabled: true,
            excludedSSIDs: [],
            isOnACPower: true,
            batteryLevel: 0.9,
            currentSSID: "Home",
            isHoldingAssertion: false,
            assertionReason: "onAC",
            assertionFailureCode: -536870212,
            isAssertionResult: true
        )

        let effects = try plugin.onEvent(
            PluginEvent(id: UUID(), kind: .powerStatusChanged, timestamp: Date(), powerStatus: failureStatus),
            context: makeContext()
        )
        XCTAssertTrue(effects.isEmpty, "assertion result events must update UI only, not re-emit power effects")

        let contribution = try plugin.makeUIContribution(
            for: .menubarMenu,
            context: PluginUIContext(slot: .menubarMenu, timestamp: Date(), session: nil)
        )
        let statusComponent = contribution?.components.first(where: { $0.id == "caffeine-status" })
        XCTAssertEqual(statusComponent?.value, "System Failure (-536870212)")
    }

    func testHysteresisLogic() throws {
        let plugin = makePlugin()
        let context = makeContext()

        // 1. 18% -> Low battery (prevLowBattery = false) -> releases
        let status1 = PluginPowerStatus(
            caffeineEnabled: true,
            excludedSSIDs: [],
            isOnACPower: true,
            batteryLevel: 0.18,
            currentSSID: "Home"
        )
        let event1 = PluginEvent(id: UUID(), kind: .powerStatusChanged, timestamp: Date(), powerStatus: status1)
        let fx1 = try plugin.onEvent(event1, context: context)
        XCTAssertEqual(fx1[0].payload["preventSleep"], "false")
        XCTAssertEqual(fx1[0].payload["reason"], "lowBattery")

        // 2. 22% -> Still low battery (prevLowBattery = true) -> releases
        let status2 = PluginPowerStatus(
            caffeineEnabled: true,
            excludedSSIDs: [],
            isOnACPower: true,
            batteryLevel: 0.22,
            currentSSID: "Home"
        )
        let event2 = PluginEvent(id: UUID(), kind: .powerStatusChanged, timestamp: Date(), powerStatus: status2)
        let fx2 = try plugin.onEvent(event2, context: context)
        XCTAssertEqual(fx2[0].payload["preventSleep"], "false")
        XCTAssertEqual(fx2[0].payload["reason"], "lowBattery")

        // 3. 23% -> Recovers (prevLowBattery = true) -> holds (onAC)
        let status3 = PluginPowerStatus(
            caffeineEnabled: true,
            excludedSSIDs: [],
            isOnACPower: true,
            batteryLevel: 0.23,
            currentSSID: "Home"
        )
        let event3 = PluginEvent(id: UUID(), kind: .powerStatusChanged, timestamp: Date(), powerStatus: status3)
        let fx3 = try plugin.onEvent(event3, context: context)
        XCTAssertEqual(fx3[0].payload["preventSleep"], "true")
        XCTAssertEqual(fx3[0].payload["reason"], "onAC")
    }
}
