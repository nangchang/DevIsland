import XCTest
@testable import DevIsland

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SettingsStoreTests")
        defaults.removePersistentDomain(forName: "SettingsStoreTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "SettingsStoreTests")
        defaults = nil
        super.tearDown()
    }

    func testApprovalProxyDefaults() {
        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.settings.claudeSessionApprovalMode, .nativePermissions)
        XCTAssertEqual(store.settings.claudePersistentApprovalDestination, .userSettings)
        XCTAssertEqual(store.settings.bridgeTransportKind, .tcpLoopback)
        XCTAssertEqual(store.settings.bridgeSocketPath, AppSettings.defaultBridgeSocketPath)
        XCTAssertFalse(store.settings.bridgeSocketPath.hasPrefix("~"))
        XCTAssertTrue(store.settings.bridgeSocketPath.hasSuffix("DevIsland/dev-island.sock"))
        XCTAssertEqual(store.settings.bridgeTcpPort, 9090)
        XCTAssertEqual(store.settings.bridgeConnectTimeoutSeconds, 5)
        XCTAssertEqual(store.settings.bridgeResponseTimeoutSeconds, 300)
        XCTAssertTrue(store.settings.bridgeFallbackToTcp)
        XCTAssertEqual(store.settings.approvalFallbackPolicy, .denyUnknown)
        XCTAssertEqual(store.settings.replayRetentionDays, 30)
    }

    func testSettingsPersistAndReload() {
        let store = SettingsStore(userDefaults: defaults)
        store.settings.claudeSessionApprovalMode = .hybrid
        store.settings.claudePersistentApprovalDestination = .projectSettings
        store.settings.bridgeTransportKind = .unixDomainSocket
        store.settings.bridgeSocketPath = "/tmp/dev-island.sock"
        store.settings.bridgeTcpPort = 19191
        store.settings.bridgeConnectTimeoutSeconds = 7
        store.settings.bridgeResponseTimeoutSeconds = 123
        store.settings.bridgeFallbackToTcp = false
        store.settings.approvalFallbackPolicy = .allowReadOnly
        store.settings.replayRetentionDays = 14

        let reloaded = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(reloaded.settings.claudeSessionApprovalMode, .hybrid)
        XCTAssertEqual(reloaded.settings.claudePersistentApprovalDestination, .projectSettings)
        XCTAssertEqual(reloaded.settings.bridgeTransportKind, .unixDomainSocket)
        XCTAssertEqual(reloaded.settings.bridgeSocketPath, "/tmp/dev-island.sock")
        XCTAssertEqual(reloaded.settings.bridgeTcpPort, 19191)
        XCTAssertEqual(reloaded.settings.bridgeConnectTimeoutSeconds, 7)
        XCTAssertEqual(reloaded.settings.bridgeResponseTimeoutSeconds, 123)
        XCTAssertFalse(reloaded.settings.bridgeFallbackToTcp)
        XCTAssertEqual(reloaded.settings.approvalFallbackPolicy, .allowReadOnly)
        XCTAssertEqual(reloaded.settings.replayRetentionDays, 14)
    }

    func testInvalidPersistedValuesFallBackToDefaults() {
        defaults.set("bad-mode", forKey: SettingsStore.DefaultsKey.claudeSessionApprovalMode)
        defaults.set("bad-destination", forKey: SettingsStore.DefaultsKey.claudePersistentApprovalDestination)
        defaults.set("bad-transport", forKey: SettingsStore.DefaultsKey.bridgeTransportKind)
        defaults.set("", forKey: SettingsStore.DefaultsKey.bridgeSocketPath)
        defaults.set(-1, forKey: SettingsStore.DefaultsKey.bridgeTcpPort)
        defaults.set(0, forKey: SettingsStore.DefaultsKey.bridgeConnectTimeoutSeconds)
        defaults.set(-10, forKey: SettingsStore.DefaultsKey.bridgeResponseTimeoutSeconds)
        defaults.set("bad-policy", forKey: SettingsStore.DefaultsKey.approvalFallbackPolicy)
        defaults.set(0, forKey: SettingsStore.DefaultsKey.replayRetentionDays)

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.settings, .defaults)
    }
}
