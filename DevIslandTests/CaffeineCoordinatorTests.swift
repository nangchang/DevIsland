import XCTest
@testable import DevIsland

final class CaffeineCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> CaffeineCoordinator {
        return CaffeineCoordinator()
    }

    func testMasterOffAlwaysReleases() {
        let c = makeCoordinator()
        c.caffeineEnabled = false
        c.isOnACPower = true
        c.batteryLevel = 0.9
        c.currentSSID = "Home"
        let (_, reason) = c.decide(prevLowBattery: false)
        XCTAssertEqual(reason, .off)
    }

    func testACOnNormalBatteryHolds() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = 0.8
        c.currentSSID = "Home"
        c.excludedSSIDs = ["Office-Internal"]
        let (_, reason) = c.decide(prevLowBattery: false)
        XCTAssertEqual(reason, .onAC)
    }

    func testExcludedSSIDReleases() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = 0.8
        c.currentSSID = "Office-Internal"
        c.excludedSSIDs = ["Office-Internal", "Guest"]
        let (_, reason) = c.decide(prevLowBattery: false)
        XCTAssertEqual(reason, .excludedSSID("Office-Internal"))
    }

    func testOnBatteryReleases() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = false
        c.batteryLevel = 0.6
        c.currentSSID = "Home"
        let (_, reason) = c.decide(prevLowBattery: false)
        XCTAssertEqual(reason, .onBattery)
    }

    func testLowBatteryReleasesEvenOnAC() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = 0.18
        c.currentSSID = "Home"
        let (next, reason) = c.decide(prevLowBattery: false)
        XCTAssertTrue(next)
        XCTAssertEqual(reason, .lowBattery(0.18))
    }

    func testLowBatteryHysteresis() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.currentSSID = nil

        // 18% → OFF (저전력 진입)
        c.batteryLevel = 0.18
        var (next, reason) = c.decide(prevLowBattery: false)
        XCTAssertTrue(next)
        XCTAssertEqual(reason, .lowBattery(0.18))

        // 22% (히스테리시스 영역) — 이미 OFF 상태이므로 유지
        c.batteryLevel = 0.22
        (next, reason) = c.decide(prevLowBattery: true)
        XCTAssertTrue(next)
        XCTAssertEqual(reason, .lowBattery(0.22))

        // 23% 도달 → ON 복귀
        c.batteryLevel = 0.23
        (next, reason) = c.decide(prevLowBattery: true)
        XCTAssertFalse(next)
        XCTAssertEqual(reason, .onAC)
    }

    func testLowBatteryEnterBoundary() {
        // 21% (임계 직상단) — 진입 안 됨
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = 0.21
        let (next, reason) = c.decide(prevLowBattery: false)
        XCTAssertFalse(next)
        XCTAssertEqual(reason, .onAC)
    }

    func testNilBatteryIgnoresBatteryRule() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = nil
        c.currentSSID = nil
        let (next, reason) = c.decide(prevLowBattery: false)
        XCTAssertFalse(next)
        XCTAssertEqual(reason, .onAC)
    }

    func testNilSSIDSkipsExclusion() {
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = 0.5
        c.currentSSID = nil
        c.excludedSSIDs = ["Office-Internal"]
        let (_, reason) = c.decide(prevLowBattery: false)
        XCTAssertEqual(reason, .onAC)
    }

    func testHysteresisProgressesDuringExcludedSSID() {
        // 제외 SSID에 머무는 동안에도 배터리 hysteresis는 갱신되어야 한다.
        // (regression: 이전에는 .excludedSSID 분기에서 prev를 그대로 반환해
        // SSID를 벗어났을 때 hysteresis가 깨졌다.)
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.excludedSSIDs = ["Office-Internal"]
        c.currentSSID = "Office-Internal"

        // 예외 SSID + 18% → low로 진입해야 함
        c.batteryLevel = 0.18
        let (next1, reason1) = c.decide(prevLowBattery: false)
        XCTAssertTrue(next1, "제외 SSID 분기에서도 low battery 상태로 진입해야 함")
        XCTAssertEqual(reason1, .excludedSSID("Office-Internal"))

        // 예외에서 벗어나고 21%(데드존) → 여전히 low 유지
        c.currentSSID = "Home"
        c.batteryLevel = 0.21
        let (next2, reason2) = c.decide(prevLowBattery: next1)
        XCTAssertTrue(next2)
        XCTAssertEqual(reason2, .lowBattery(0.21))
    }

    func testDecideIsIdempotent() {
        // pure 함수 — 같은 입력 + prev에 대해 호출 횟수 무관하게 동일 결과
        let c = makeCoordinator()
        c.caffeineEnabled = true
        c.isOnACPower = true
        c.batteryLevel = 0.18
        let (next1, reason1) = c.decide(prevLowBattery: false)
        let (next2, reason2) = c.decide(prevLowBattery: false)
        XCTAssertEqual(next1, next2)
        XCTAssertEqual(reason1, reason2)
    }
}
