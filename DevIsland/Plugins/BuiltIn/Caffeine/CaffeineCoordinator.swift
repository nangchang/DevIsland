import Foundation
import Combine
import IOKit

/// Host-side signal/effect adapter for the Caffeine plugin. Emits sanitized power signals
/// (`PluginPowerStatus`) and applies the plugin's `power.preventIdleSleep` effect to the real
/// `IOPMAssertion`. It holds no prevention policy — `CaffeinePlugin` is the sole policy owner;
/// this type only adapts host signals in and effect results out.
final class CaffeineCoordinator: ObservableObject {
    @Published private(set) var isHoldingAssertion: Bool = false

    @Published var caffeineEnabled: Bool = true
    @Published var excludedSSIDs: [String] = []
    @Published var isOnACPower: Bool = true
    @Published var batteryLevel: Double? = nil
    @Published var currentSSID: String? = nil

    var onStatusChanged: ((PluginPowerStatus) -> Void)?

    private let assertion: SleepAssertion
    private var cancellables = Set<AnyCancellable>()

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

    /// Emits the current input signals as a sanitized `PluginPowerStatus` for the plugin to
    /// evaluate. No policy is applied here.
    func evaluate() {
        onStatusChanged?(PluginPowerStatus(
            featureEnabled: caffeineEnabled,
            excludedSSIDs: excludedSSIDs,
            isOnACPower: isOnACPower,
            batteryLevel: batteryLevel,
            currentSSID: currentSSID
        ))
    }

    /// Applies the plugin's prevention decision to the real assertion and reports the result
    /// back as an effect-result status. `reasonString` is passed through unchanged — the
    /// coordinator does not interpret the plugin's policy reason.
    func applyPreventIdleSleep(prevent: Bool, reasonString: String) {
        let failureCode: Int32?
        if prevent {
            switch assertion.acquire() {
            case .acquired, .alreadyHeld:
                failureCode = nil
            case .failed(let status):
                failureCode = status
            }
        } else {
            assertion.release()
            failureCode = nil
        }

        let shouldHold = prevent && assertion.isHeld

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isHoldingAssertion != shouldHold { self.isHoldingAssertion = shouldHold }
            self.onStatusChanged?(PluginPowerStatus(
                featureEnabled: self.caffeineEnabled,
                excludedSSIDs: self.excludedSSIDs,
                isOnACPower: self.isOnACPower,
                batteryLevel: self.batteryLevel,
                currentSSID: self.currentSSID,
                isPreventingSleep: shouldHold,
                effectReason: reasonString,
                effectFailureCode: failureCode,
                isEffectResult: true
            ))
        }
    }

    func shutdown() {
        cancellables.removeAll()
        assertion.release()
        isHoldingAssertion = false
    }
}
