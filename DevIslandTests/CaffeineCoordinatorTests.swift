import XCTest
@testable import DevIsland

final class CaffeineCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> CaffeineCoordinator {
        // SleepAssertion 실제 호출은 IOKit 부수효과가 있으나 테스트에서는 acquire/release만 호출됨.
        // 단순 decide() 로직 검증이 주 목적이므로 그대로 사용.
        return CaffeineCoordinator()
    }

    func testMasterOffAlwaysReleases() {
        let c = makeCoordinator()
        c.caffeineEnabled = false
        c.isOnACPower = true
        c.batteryLevel = 0.9
        c.currentSSID = "Home"
        let (hold, reason) = c.decide()
        XCTAssertFalse(hold)
        XCTAssertEqual(reason, .off)
    }

    func testACOnNormalBatteryHolds() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = 0.8
        c.currentSSID = "Home"
        c.excludedSSIDs = ["Office-Internal"]
        let (hold, reason) = c.decide()
        XCTAssertTrue(hold)
        XCTAssertEqual(reason, .onAC)
    }

    func testExcludedSSIDReleases() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = 0.8
        c.currentSSID = "Office-Internal"
        c.excludedSSIDs = ["Office-Internal", "Guest"]
        let (hold, reason) = c.decide()
        XCTAssertFalse(hold)
        XCTAssertEqual(reason, .excludedSSID("Office-Internal"))
    }

    func testOnBatteryReleases() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = false
        c.batteryLevel = 0.6
        c.currentSSID = "Home"
        let (hold, reason) = c.decide()
        XCTAssertFalse(hold)
        XCTAssertEqual(reason, .onBattery)
    }

    func testLowBatteryReleasesEvenOnAC() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = 0.18
        c.currentSSID = "Home"
        let (hold, reason) = c.decide()
        XCTAssertFalse(hold)
        XCTAssertEqual(reason, .lowBattery(0.18))
    }

    func testLowBatteryHysteresis() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.currentSSID = nil

        // 18% → OFF
        c.batteryLevel = 0.18
        var result = c.decide()
        XCTAssertFalse(result.hold)
        XCTAssertEqual(result.reason, .lowBattery(0.18))

        // 22% → 히스테리시스 영역, 여전히 OFF
        c.batteryLevel = 0.22
        result = c.decide()
        XCTAssertFalse(result.hold)
        XCTAssertEqual(result.reason, .lowBattery(0.22))

        // 23% 도달 → ON 복귀
        c.batteryLevel = 0.23
        result = c.decide()
        XCTAssertTrue(result.hold)
        XCTAssertEqual(result.reason, .onAC)
    }

    func testNilBatteryIgnoresBatteryRule() {
        // 데스크톱 Mac — batteryLevel == nil
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = nil
        c.currentSSID = nil
        let (hold, reason) = c.decide()
        XCTAssertTrue(hold)
        XCTAssertEqual(reason, .onAC)
    }

    func testNilSSIDSkipsExclusion() {
        // Location 권한 없음 → SSID nil → 제외 규칙 무시, AC 규칙만으로 판정
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = 0.5
        c.currentSSID = nil
        c.excludedSSIDs = ["Office-Internal"]
        let (hold, reason) = c.decide()
        XCTAssertTrue(hold)
        XCTAssertEqual(reason, .onAC)
    }
}
