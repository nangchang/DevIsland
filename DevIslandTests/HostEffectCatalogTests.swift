import XCTest
@testable import DevIsland

final class HostEffectCatalogTests: XCTestCase {

    func testStorageEffectsRequireWritePluginStorage() {
        XCTAssertTrue(HostEffectCatalog.isSupported("storage.keyValue", kind: .utility, permissions: [.writePluginStorage]))
        XCTAssertTrue(HostEffectCatalog.isSupported("storage.increment", kind: .utility, permissions: [.writePluginStorage]))
        XCTAssertFalse(HostEffectCatalog.isSupported("storage.keyValue", kind: .utility, permissions: []))
    }

    func testNotificationRequiresShowNotification() {
        XCTAssertTrue(HostEffectCatalog.isSupported("notification.show", kind: .utility, permissions: [.showNotification]))
        XCTAssertFalse(HostEffectCatalog.isSupported("notification.show", kind: .utility, permissions: []))
    }

    func testScopedAudioRequiresPlayScopedAudio() {
        // Open (non-system-only) effects are available to utility plugins on the permission alone.
        XCTAssertTrue(HostEffectCatalog.isSupported("audio.playFile", kind: .utility, permissions: [.playScopedAudio]))
        XCTAssertFalse(HostEffectCatalog.isSupported("audio.playFile", kind: .utility, permissions: [.showNotification]))
        XCTAssertFalse(HostEffectCatalog.isSupported("audio.playFile", kind: .utility, permissions: []))
    }

    func testPowerEffectsRequirePermissionAndSystemKind() {
        // system kind + permission: allowed
        XCTAssertTrue(HostEffectCatalog.isSupported("power.preventIdleSleep", kind: .system, permissions: [.controlPowerSleep]))
        XCTAssertTrue(HostEffectCatalog.isSupported("power.toggle", kind: .system, permissions: [.controlPowerSleep]))
        // holds the permission but is only a utility plugin: rejected (system-only capability)
        XCTAssertFalse(
            HostEffectCatalog.isSupported("power.preventIdleSleep", kind: .utility, permissions: [.controlPowerSleep]),
            "power effects are system-only; a utility plugin holding the permission cannot run them"
        )
        // system kind but missing the permission: rejected
        XCTAssertFalse(HostEffectCatalog.isSupported("power.preventIdleSleep", kind: .system, permissions: []))
    }

    func testUnknownEffectNeverSupported() {
        let everything: Set<PluginPermission> = [.controlPowerSleep, .writePluginStorage, .showNotification, .playScopedAudio]
        XCTAssertFalse(HostEffectCatalog.isSupported("bogus.effect", kind: .system, permissions: everything))
    }

    func testPowerPermissionIsSystemOnly() {
        XCTAssertTrue(PluginPermission.controlPowerSleep.isSystemOnly)
        XCTAssertFalse(PluginPermission.playScopedAudio.isSystemOnly)
        XCTAssertFalse(PluginPermission.showNotification.isSystemOnly)
        XCTAssertFalse(PluginPermission.writePluginStorage.isSystemOnly)
    }
}
