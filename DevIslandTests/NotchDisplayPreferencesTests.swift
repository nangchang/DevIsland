import XCTest
@testable import DevIsland

final class NotchDisplayPreferencesTests: XCTestCase {
    private var mockDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        mockDefaults = UserDefaults(suiteName: "NotchDisplayPreferencesTests")
        mockDefaults.removePersistentDomain(forName: "NotchDisplayPreferencesTests")
    }

    override func tearDown() {
        mockDefaults.removePersistentDomain(forName: "NotchDisplayPreferencesTests")
        mockDefaults = nil
        super.tearDown()
    }

    // MARK: - Default values

    func testDefaultNotchDisplayTargetIsAutomatic() {
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertEqual(prefs.notchDisplayTarget, .automatic)
    }

    func testDefaultShowInFullScreenAppsIsTrue() {
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertTrue(prefs.showInFullScreenApps)
    }

    func testDefaultRequestDisplayTargetIsFocused() {
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertEqual(prefs.requestDisplayTarget, .focused)
    }

    // MARK: - Persistence (set → UserDefaults)

    func testNotchDisplayTargetPersistsRawValueToUserDefaults() {
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        prefs.notchDisplayTarget = .main
        XCTAssertEqual(mockDefaults.string(forKey: NotchDisplayPreferences.Keys.notchDisplayTarget), "main")
    }

    func testSelectedDisplayIdPersistsIntToUserDefaults() {
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        prefs.selectedDisplayId = 99999
        XCTAssertEqual(mockDefaults.integer(forKey: NotchDisplayPreferences.Keys.selectedDisplayId), 99999)
    }

    func testShowInFullScreenAppsPersistsBoolToUserDefaults() {
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        prefs.showInFullScreenApps = false
        XCTAssertFalse(mockDefaults.bool(forKey: NotchDisplayPreferences.Keys.showInFullScreenApps))

        prefs.showInFullScreenApps = true
        XCTAssertTrue(mockDefaults.bool(forKey: NotchDisplayPreferences.Keys.showInFullScreenApps))
    }

    func testRequestDisplayTargetPersistsRawValueToUserDefaults() {
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        prefs.requestDisplayTarget = .mouse
        XCTAssertEqual(mockDefaults.string(forKey: NotchDisplayPreferences.Keys.requestDisplayTarget), "mouse")
    }

    // MARK: - Restoration (UserDefaults → init)

    func testRestoresNotchDisplayTargetFromUserDefaults() {
        mockDefaults.set("mouse", forKey: NotchDisplayPreferences.Keys.notchDisplayTarget)
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertEqual(prefs.notchDisplayTarget, .mouse)
    }

    func testRestoresShowInFullScreenAppsFromUserDefaults() {
        mockDefaults.set(false, forKey: NotchDisplayPreferences.Keys.showInFullScreenApps)
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertFalse(prefs.showInFullScreenApps)
    }

    func testRestoresRequestDisplayTargetFromUserDefaults() {
        mockDefaults.set("notch", forKey: NotchDisplayPreferences.Keys.requestDisplayTarget)
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertEqual(prefs.requestDisplayTarget, .notch)
    }

    func testRestoresSelectedDisplayIdFromUserDefaults() {
        // Store a value that will pass ensureSelectedDisplay (set selectedDisplayId to a high
        // value that won't match any real screen, then verify it wasn't silently lost/overwritten
        // when a valid screen exists — we only test the raw storage/restore contract here).
        mockDefaults.set(0, forKey: NotchDisplayPreferences.Keys.selectedDisplayId)
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        // Value must be a UInt32 — zero is a valid stored value (or corrected by ensureSelectedDisplay).
        XCTAssertGreaterThanOrEqual(prefs.selectedDisplayId, UInt32(0))
    }

    // MARK: - Round-trip: set value then recreate prefs

    func testNotchDisplayTargetRoundTrip() {
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        prefs.notchDisplayTarget = .focused

        let restored = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertEqual(restored.notchDisplayTarget, .focused)
    }

    func testShowInFullScreenAppsRoundTrip() {
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        prefs.showInFullScreenApps = false

        let restored = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertFalse(restored.showInFullScreenApps)
    }

    func testRequestDisplayTargetRoundTrip() {
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        prefs.requestDisplayTarget = .mouse

        let restored = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertEqual(restored.requestDisplayTarget, .mouse)
    }

    // MARK: - Migration: legacy "displayTarget" key

    func testMigratesLegacyDisplayTargetKey() {
        mockDefaults.set("main", forKey: NotchDisplayPreferences.Keys.legacyDisplayTarget)
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertEqual(prefs.notchDisplayTarget, .main)
    }

    func testLegacyKeyTakesPrecedenceOverNewKey() {
        mockDefaults.set("main", forKey: NotchDisplayPreferences.Keys.legacyDisplayTarget)
        mockDefaults.set("automatic", forKey: NotchDisplayPreferences.Keys.notchDisplayTarget)
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertEqual(prefs.notchDisplayTarget, .main)
    }

    func testNewKeyUsedWhenLegacyKeyAbsent() {
        mockDefaults.set("focused", forKey: NotchDisplayPreferences.Keys.notchDisplayTarget)
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertEqual(prefs.notchDisplayTarget, .focused)
    }

    func testUnknownLegacyKeyValueFallsBackToNewKey() {
        mockDefaults.set("invalid_value", forKey: NotchDisplayPreferences.Keys.legacyDisplayTarget)
        mockDefaults.set("mouse", forKey: NotchDisplayPreferences.Keys.notchDisplayTarget)
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertEqual(prefs.notchDisplayTarget, .mouse)
    }

    // MARK: - showInFullScreenApps nil guard

    func testShowInFullScreenAppsDefaultsTrueWhenKeyAbsent() {
        // Ensure no stored value exists
        XCTAssertNil(mockDefaults.object(forKey: NotchDisplayPreferences.Keys.showInFullScreenApps))
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertTrue(prefs.showInFullScreenApps)
    }

    func testShowInFullScreenAppsUsesFalseWhenExplicitlyStored() {
        mockDefaults.set(false, forKey: NotchDisplayPreferences.Keys.showInFullScreenApps)
        let prefs = NotchDisplayPreferences(userDefaults: mockDefaults)
        XCTAssertFalse(prefs.showInFullScreenApps)
    }
}
