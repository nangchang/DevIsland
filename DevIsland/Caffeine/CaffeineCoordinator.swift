import Foundation
import Combine

/// Caffeine 동작 사유 — UI 라벨/로그에 사용.
enum CaffeineReason: Equatable {
    case off                  // 마스터 OFF
    case onAC                 // AC 연결, 정상 차단 중
    case excludedSSID(String) // 제외 SSID 매칭으로 OFF
    case onBattery            // AC 분리로 OFF
    case lowBattery(Double)   // 배터리 임계 이하로 OFF
}

/// 입력 신호(전원/SSID/설정)를 결합해 IOPMAssertion 보유 여부를 결정한다.
final class CaffeineCoordinator: ObservableObject {
    /// 저전력 OFF 임계 (≤ 20%)
    static let lowBatteryOffThreshold: Double = 0.20
    /// 저전력 복귀 임계 (≥ 23%) — 깜빡임 방지 히스테리시스
    static let lowBatteryOnThreshold: Double = 0.23

    @Published private(set) var isHoldingAssertion: Bool = false
    @Published private(set) var reason: CaffeineReason = .off

    /// 입력 신호 — 외부에서 publish.
    @Published var caffeineEnabled: Bool = true
    @Published var excludedSSIDs: [String] = []
    @Published var isOnACPower: Bool = true
    @Published var batteryLevel: Double? = nil
    @Published var currentSSID: String? = nil

    private let assertion: SleepAssertion
    private var cancellables = Set<AnyCancellable>()
    /// 히스테리시스를 위해 직전 저전력 상태를 유지.
    private var lastLowBattery: Bool = false

    init(assertion: SleepAssertion = SleepAssertion()) {
        self.assertion = assertion
    }

    deinit {
        // deinit은 nonisolated → assertion만 직접 release.
        // SleepAssertion의 deinit이 동일 처리하므로 명시 호출 불필요.
    }

    /// 모든 input publisher를 구독해 자동 재평가.
    func bind() {
        let aggregate = Publishers.CombineLatest4($caffeineEnabled, $isOnACPower, $batteryLevel, $currentSSID)
            .combineLatest($excludedSSIDs)
        aggregate
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        evaluate()
    }

    /// 외부에서 강제 재평가가 필요할 때.
    func evaluate() {
        let (hold, why) = decide()
        if hold {
            if assertion.acquire() {
                if !isHoldingAssertion { isHoldingAssertion = true }
            }
        } else {
            assertion.release()
            if isHoldingAssertion { isHoldingAssertion = false }
        }
        if reason != why { reason = why }
    }

    /// 종료 시 명시적 해제.
    func shutdown() {
        cancellables.removeAll()
        assertion.release()
        isHoldingAssertion = false
        reason = .off
    }

    // MARK: - Decision

    /// 상태 결정 로직 — 단위 테스트용으로 분리.
    func decide() -> (hold: Bool, reason: CaffeineReason) {
        guard caffeineEnabled else { return (false, .off) }

        if let ssid = currentSSID, excludedSSIDs.contains(ssid) {
            return (false, .excludedSSID(ssid))
        }

        if !isOnACPower {
            // AC 분리 시 저전력 진입 여부 갱신.
            if let level = batteryLevel {
                updateLowBatteryHysteresis(level: level)
                if lastLowBattery {
                    return (false, .lowBattery(level))
                }
            }
            return (false, .onBattery)
        }

        // AC 연결 상태 — 충전 중이지만 잔량이 OFF 임계 이하라면 안전을 위해 OFF.
        if let level = batteryLevel {
            updateLowBatteryHysteresis(level: level)
            if lastLowBattery {
                return (false, .lowBattery(level))
            }
        }

        return (true, .onAC)
    }

    private func updateLowBatteryHysteresis(level: Double) {
        if lastLowBattery {
            // OFF 상태 → ON 복귀 임계 도달 시 해제
            if level >= Self.lowBatteryOnThreshold {
                lastLowBattery = false
            }
        } else {
            if level <= Self.lowBatteryOffThreshold {
                lastLowBattery = true
            }
        }
    }
}
