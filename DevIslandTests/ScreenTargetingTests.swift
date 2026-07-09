import XCTest
@testable import DevIsland

/// `ScreenTargeting`의 순수 판별 로직을 고정한다.
/// 나머지 화면 선정 함수는 NSScreen/NSWorkspace/AX 시스템 싱글턴에 의존해
/// 유닛 환경에서 재현 불가하므로, 데이터 변환만 하는 `isWindowOnScreen`만 커버한다.
final class ScreenTargetingTests: XCTestCase {
    func testIsWindowOnScreen_bool() {
        XCTAssertTrue(ScreenTargeting.isWindowOnScreen(true))
        XCTAssertFalse(ScreenTargeting.isWindowOnScreen(false))
    }

    func testIsWindowOnScreen_int() {
        XCTAssertTrue(ScreenTargeting.isWindowOnScreen(1))
        XCTAssertFalse(ScreenTargeting.isWindowOnScreen(0))
        XCTAssertFalse(ScreenTargeting.isWindowOnScreen(2))
    }

    func testIsWindowOnScreen_nsNumber() {
        XCTAssertTrue(ScreenTargeting.isWindowOnScreen(NSNumber(value: true)))
        XCTAssertFalse(ScreenTargeting.isWindowOnScreen(NSNumber(value: false)))
    }

    func testIsWindowOnScreen_nilAndOther() {
        XCTAssertFalse(ScreenTargeting.isWindowOnScreen(nil))
        XCTAssertFalse(ScreenTargeting.isWindowOnScreen("1"))
    }
}
