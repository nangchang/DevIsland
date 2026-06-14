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

    var onStatusChanged: ((PluginPowerStatus) -> Void)?

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
        let status = PluginPowerStatus(
            caffeineEnabled: caffeineEnabled,
            excludedSSIDs: excludedSSIDs,
            isOnACPower: isOnACPower,
            batteryLevel: batteryLevel,
            currentSSID: currentSSID
        )
        onStatusChanged?(status)
    }

    func applyPreventIdleSleep(prevent: Bool, reasonString: String) {
        let parsedReason: CaffeineReason
        let failureCode: Int32?
        if prevent {
            switch assertion.acquire() {
            case .acquired, .alreadyHeld:
                parsedReason = .onAC
                failureCode = nil
            case .failed(let status):
                parsedReason = .failure(status)
                failureCode = status
            }
        } else {
            assertion.release()
            failureCode = nil
            if reasonString == "off" {
                parsedReason = .off
            } else if reasonString == "lowBattery" {
                parsedReason = .lowBattery(batteryLevel ?? 0.0)
            } else if reasonString == "onBattery" {
                parsedReason = .onBattery
            } else if reasonString.hasPrefix("excludedSSID:") {
                let ssid = reasonString.replacingOccurrences(of: "excludedSSID:", with: "")
                parsedReason = .excludedSSID(ssid)
            } else if reasonString.hasPrefix("failure:") {
                let statusStr = reasonString.replacingOccurrences(of: "failure:", with: "")
                let status = Int32(statusStr) ?? 0
                parsedReason = .failure(status)
            } else {
                parsedReason = .off
            }
        }

        let shouldHold = prevent && assertion.isHeld

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isHoldingAssertion != shouldHold { self.isHoldingAssertion = shouldHold }
            if self.reason != parsedReason { self.reason = parsedReason }
            self.onStatusChanged?(PluginPowerStatus(
                caffeineEnabled: self.caffeineEnabled,
                excludedSSIDs: self.excludedSSIDs,
                isOnACPower: self.isOnACPower,
                batteryLevel: self.batteryLevel,
                currentSSID: self.currentSSID,
                isHoldingAssertion: shouldHold,
                assertionReason: reasonString,
                assertionFailureCode: failureCode,
                isAssertionResult: true
            ))
        }
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
