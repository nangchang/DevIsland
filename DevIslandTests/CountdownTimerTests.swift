import XCTest
@testable import DevIsland

final class CountdownTimerTests: XCTestCase {
    func testProgressDecreasesToZeroAndExpiresOnce() {
        let countdown = CountdownTimer()
        let expired = expectation(description: "expired")
        var progressValues: [Double] = []

        countdown.start(
            duration: 0.3,
            interval: 0.1,
            onProgress: { progressValues.append($0) },
            onExpire: { expired.fulfill() }
        )
        XCTAssertTrue(countdown.isRunning)

        wait(for: [expired], timeout: 2.0)
        XCTAssertFalse(countdown.isRunning)
        XCTAssertFalse(progressValues.isEmpty)
        // 진행률은 단조 감소하고 만료 틱에서 0에 도달한다
        XCTAssertEqual(progressValues, progressValues.sorted(by: >))
        XCTAssertEqual(progressValues.last ?? -1, 0, accuracy: 0.0001)
    }

    func testCancelStopsCallbacks() {
        let countdown = CountdownTimer()
        let notExpired = expectation(description: "expire should not fire")
        notExpired.isInverted = true

        countdown.start(
            duration: 0.2,
            interval: 0.05,
            onProgress: { _ in },
            onExpire: { notExpired.fulfill() }
        )
        countdown.cancel()
        XCTAssertFalse(countdown.isRunning)

        wait(for: [notExpired], timeout: 0.4)
    }

    func testRestartReplacesPreviousCountdown() {
        let countdown = CountdownTimer()
        let firstExpired = expectation(description: "first expire should not fire")
        firstExpired.isInverted = true
        let secondExpired = expectation(description: "second expire")

        countdown.start(
            duration: 0.15,
            interval: 0.05,
            onProgress: { _ in },
            onExpire: { firstExpired.fulfill() }
        )
        countdown.start(
            duration: 0.3,
            interval: 0.1,
            onProgress: { _ in },
            onExpire: { secondExpired.fulfill() }
        )

        wait(for: [firstExpired, secondExpired], timeout: 2.0)
        XCTAssertFalse(countdown.isRunning)
    }
}
