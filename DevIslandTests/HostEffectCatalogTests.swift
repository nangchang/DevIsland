import XCTest
@testable import DevIsland

final class HostEffectCatalogTests: XCTestCase {

    func testStorageEffectsRequireWritePluginStorage() {
        XCTAssertTrue(HostEffectCatalog.isSupported("storage.keyValue", pluginID: "x", permissions: [.writePluginStorage]))
        XCTAssertTrue(HostEffectCatalog.isSupported("storage.increment", pluginID: "x", permissions: [.writePluginStorage]))
        XCTAssertFalse(HostEffectCatalog.isSupported("storage.keyValue", pluginID: "x", permissions: []))
    }

    func testNotificationRequiresShowNotification() {
        XCTAssertTrue(HostEffectCatalog.isSupported("notification.show", pluginID: "x", permissions: [.showNotification]))
        XCTAssertFalse(HostEffectCatalog.isSupported("notification.show", pluginID: "x", permissions: []))
    }

    func testSoundRequiresPlaySound() {
        XCTAssertTrue(HostEffectCatalog.isSupported("sound.play", pluginID: "openpeon", permissions: [.playSound]))
        XCTAssertFalse(HostEffectCatalog.isSupported("sound.play", pluginID: "openpeon", permissions: []))
    }

    func testPowerEffectsRequirePermissionAndCaffeineAllowlist() {
        // caffeine with permission: allowed
        XCTAssertTrue(HostEffectCatalog.isSupported("power.preventIdleSleep", pluginID: "caffeine", permissions: [.controlPowerSleep]))
        XCTAssertTrue(HostEffectCatalog.isSupported("power.toggle", pluginID: "caffeine", permissions: [.controlPowerSleep]))
        // holds the permission but is not on the built-in allowlist: rejected
        XCTAssertFalse(
            HostEffectCatalog.isSupported("power.preventIdleSleep", pluginID: "other", permissions: [.controlPowerSleep]),
            "power effects are built-in-allowlist only, not permission-gated public capabilities"
        )
        // on the allowlist but missing the permission: rejected
        XCTAssertFalse(HostEffectCatalog.isSupported("power.preventIdleSleep", pluginID: "caffeine", permissions: []))
    }

    func testUnknownEffectNeverSupported() {
        let everything: Set<PluginPermission> = [.controlPowerSleep, .writePluginStorage, .showNotification, .playSound]
        XCTAssertFalse(HostEffectCatalog.isSupported("bogus.effect", pluginID: "caffeine", permissions: everything))
    }

    func testDescriptorExposesAllowlistMetadata() {
        XCTAssertEqual(HostEffectCatalog.descriptor(for: "power.preventIdleSleep")?.builtInOnlyPluginIDs, ["caffeine"])
        XCTAssertEqual(HostEffectCatalog.descriptor(for: "power.toggle")?.builtInOnlyPluginIDs, ["caffeine"])
        XCTAssertNil(HostEffectCatalog.descriptor(for: "notification.show")?.builtInOnlyPluginIDs)
        XCTAssertNil(HostEffectCatalog.descriptor(for: "bogus"))
    }
}
