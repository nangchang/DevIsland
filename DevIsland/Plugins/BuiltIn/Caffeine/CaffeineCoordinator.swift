import Foundation
import Combine
import IOKit

/// Host-side signal/effect adapter for the Caffeine plugin. Emits sanitized power signals
/// (`PluginPowerStatus`) and applies the plugin's `power.preventIdleSleep` effect to the real
/// `IOPMAssertion`. It holds no prevention policy — `CaffeinePlugin` is the sole policy owner;
/// this type only adapts host signals in and effect results out.
@MainActor
final class CaffeineCoordinator: ObservableObject {
    @Published private(set) var isHoldingAssertion: Bool = false

    @Published var caffeineEnabled: Bool = true
    @Published var excludedSSIDs: [String] = []
    @Published var isOnACPower: Bool = true
    @Published var batteryLevel: Double? = nil
    @Published var currentSSID: String? = nil
    @Published var isVPNConnected: Bool = false
    @Published var activateOnVPN: Bool = true

    // Session idle timeout inputs (set from AppState)
    @Published var sessionTimeoutEnabled: Bool = false
    @Published var sessionTimeoutMinutes: Int = 5
    @Published var lastSessionActivityAt: Date = Date()

    var onStatusChanged: ((PluginPowerStatus) -> Void)?

    private let assertion: SleepAssertion
    private var cancellables = Set<AnyCancellable>()
    private var sessionTimeoutTimer: AnyCancellable?
    private var sessionTimeoutGeneration = UUID()
    private var sessionIdleTimedOut: Bool = false

    init(assertion: SleepAssertion = SleepAssertion()) {
        self.assertion = assertion
    }

    func bind() {
        let aggregate = Publishers.CombineLatest4($caffeineEnabled, $isOnACPower, $batteryLevel, $currentSSID)
            .combineLatest($excludedSSIDs)
            .combineLatest($isVPNConnected)
            .combineLatest($activateOnVPN)
        aggregate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        Publishers.CombineLatest3($lastSessionActivityAt, $sessionTimeoutEnabled, $sessionTimeoutMinutes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activityAt, enabled, minutes in
                self?.rescheduleSessionTimeout(activityAt: activityAt, enabled: enabled, minutes: minutes)
            }
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
            currentSSID: currentSSID,
            isVPNConnected: isVPNConnected,
            activateOnVPN: activateOnVPN,
            sessionIdleTimedOut: sessionIdleTimedOut
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
                isVPNConnected: self.isVPNConnected,
                activateOnVPN: self.activateOnVPN,
                isPreventingSleep: shouldHold,
                effectReason: reasonString,
                effectFailureCode: failureCode,
                isEffectResult: true,
                sessionIdleTimedOut: self.sessionIdleTimedOut
            ))
        }
    }

    func shutdown() {
        sessionTimeoutTimer?.cancel()
        cancellables.removeAll()
        assertion.release()
        isHoldingAssertion = false
    }

    // MARK: - Session Idle Timeout

    private func rescheduleSessionTimeout(activityAt: Date, enabled: Bool, minutes: Int) {
        sessionTimeoutTimer?.cancel()
        sessionTimeoutTimer = nil
        sessionTimeoutGeneration = UUID()
        let generation = sessionTimeoutGeneration

        guard enabled else {
            if sessionIdleTimedOut {
                sessionIdleTimedOut = false
                evaluate()
            }
            return
        }

        let deadline = activityAt.addingTimeInterval(Double(minutes) * 60)
        let now = Date()

        if deadline <= now {
            if !sessionIdleTimedOut {
                sessionIdleTimedOut = true
                evaluate()
            }
            return
        }

        if sessionIdleTimedOut {
            sessionIdleTimedOut = false
            evaluate()
        }

        let delay = deadline.timeIntervalSince(now)
        sessionTimeoutTimer = Timer.publish(every: delay, on: .main, in: .common)
            .autoconnect()
            .prefix(1)
            .sink { [weak self] _ in
                guard let self, self.sessionTimeoutGeneration == generation else { return }
                self.sessionIdleTimedOut = true
                self.evaluate()
            }
    }
}
