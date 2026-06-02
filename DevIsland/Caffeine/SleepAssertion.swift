import Foundation
import IOKit.pwr_mgt

/// IOPMAssertion 단일 인스턴스 박싱.
/// `acquire()`로 보유, `release()`로 해제. 중복 호출 안전.
final class SleepAssertion {
    private let name: String
    private let assertionType: CFString
    private var id: IOPMAssertionID = IOPMAssertionID(0)
    private var held: Bool = false

    var isHeld: Bool { held }

    init(
        name: String = "DevIsland.Caffeine",
        type: CFString = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
    ) {
        self.name = name
        self.assertionType = type
    }

    deinit {
        if held {
            IOPMAssertionRelease(id)
        }
    }

    /// assertion 생성/유지. 이미 보유 중이면 no-op.
    @discardableResult
    func acquire() -> Bool {
        guard !held else { return true }
        var newID: IOPMAssertionID = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &newID
        )
        guard status == kIOReturnSuccess else {
            return false
        }
        id = newID
        held = true
        return true
    }

    /// assertion 해제. 보유 중이 아니면 no-op.
    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        id = IOPMAssertionID(0)
        held = false
    }
}
