import Foundation
import Combine
import IOKit

enum CaffeineReason: Equatable {
    case off
    case onAC
    case excludedSSID(String)
    case onBattery
    case lowBattery(Double)
    case failure(IOReturn)
}

/// 입력 신호(전원/SSID/설정)를 결합해 IOPMAssertion 보유 여부를 결정한다.
final class CaffeineCoordinator: ObservableObject {
    static let lowBatteryOffThreshold: Double = 0.20
    static let lowBatteryOnThreshold: Double = 0.23

    @Published private(set) var isHoldingAssertion: Bool = false
    @Published private(set) var reason: CaffeineReason = .off

    @Published var caffeineEnabled: Bool = true
    @Published var excludedSSIDs: [String] = []
    @Published var isOnACPower: Bool = true
    @Published var batteryLevel: Double? = nil
    @Published var currentSSID: String? = nil

    private let assertion: SleepAssertion
    private var cancellables = Set<AnyCancellable>()
    private var lastLowBattery: Bool = false

    init(assertion: SleepAssertion = SleepAssertion()) {
        self.assertion = assertion
    }

    func bind() {
        let aggregate = Publishers.CombineLatest4($caffeineEnabled, $isOnACPower, $batteryLevel, $currentSSID)
            .combineLatest($excludedSSIDs)
        aggregate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        evaluate()
    }

    func evaluate() {
        let (nextLow, intended) = decide(prevLowBattery: lastLowBattery)
        lastLowBattery = nextLow

        let finalReason: CaffeineReason
        let shouldHold: Bool
        switch intended {
        case .onAC:
            switch assertion.acquire() {
            case .acquired, .alreadyHeld:
                shouldHold = true
                finalReason = .onAC
            case .failed(let status):
                shouldHold = false
                finalReason = .failure(status)
            }
        default:
            assertion.release()
            shouldHold = false
            finalReason = intended
        }

        if isHoldingAssertion != shouldHold { isHoldingAssertion = shouldHold }
        if reason != finalReason { reason = finalReason }
    }

    func shutdown() {
        cancellables.removeAll()
        assertion.release()
        isHoldingAssertion = false
        reason = .off
    }

    // MARK: - Decision (pure)

    /// 입력과 직전 히스테리시스 상태에서 다음 상태와 의도된 사유를 반환한다.
    /// 부수효과 없음 — 호출자가 `nextLowBattery`를 명시적으로 적용해야 함.
    ///
    /// 배터리 hysteresis는 SSID/AC 분기와 독립적으로 항상 갱신한다.
    /// 그렇지 않으면 제외 Wi-Fi에 머무는 동안 저전력 진입이 기록되지 않아,
    /// 예외에서 벗어났을 때 hysteresis가 깨진다.
    func decide(prevLowBattery: Bool) -> (nextLowBattery: Bool, reason: CaffeineReason) {
        let nextLow = nextLowBatteryState(prev: prevLowBattery, level: batteryLevel)

        guard caffeineEnabled else { return (nextLow, .off) }

        if let ssid = currentSSID, excludedSSIDs.contains(ssid) {
            return (nextLow, .excludedSSID(ssid))
        }

        if !isOnACPower {
            if nextLow, let level = batteryLevel {
                return (nextLow, .lowBattery(level))
            }
            return (nextLow, .onBattery)
        }

        if nextLow, let level = batteryLevel {
            return (nextLow, .lowBattery(level))
        }

        return (nextLow, .onAC)
    }

    /// 저전력 hysteresis 다음 상태를 계산한다(부수효과 없음).
    static func nextLowBatteryState(prev: Bool, level: Double?) -> Bool {
        guard let level else { return false }
        if prev {
            return level < lowBatteryOnThreshold
        } else {
            return level <= lowBatteryOffThreshold
        }
    }

    private func nextLowBatteryState(prev: Bool, level: Double?) -> Bool {
        Self.nextLowBatteryState(prev: prev, level: level)
    }
}
