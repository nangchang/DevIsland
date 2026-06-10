import Foundation

/// @unchecked Sendable: mutable state is only ever touched inside the
/// PluginRunner actor, which serializes every call (architecture doc §6.4).
final class CaffeinePlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest = PluginManifest(
        id: "caffeine",
        name: "Caffeine",
        version: "1.0.0",
        apiVersion: 1,
        kind: .utility,
        permissions: [.controlPowerSleep, .showMenubarMenu],
        surfaces: [.menubarMenu],
        activationEvents: [
            "power.status.changed",
            "plugin.started",
            "plugin.tick",
            "plugin.action.invoked"
        ]
    )

    private var lastLowBattery: Bool = false
    private var lastReason: String = "off"
    private var isPreventingSleep: Bool = false
    private var caffeineEnabled: Bool = true

    private static let lowBatteryOffThreshold: Double = 0.20
    private static let lowBatteryOnThreshold: Double = 0.23

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect] {
        if event.kind == .pluginActionInvoked, event.action?.actionID == "caffeine.toggle" {
            // Request host to toggle caffeine settings
            return [
                PluginEffect(
                    capability: "power.toggle",
                    payload: [:]
                )
            ]
        }

        guard let status = event.powerStatus else {
            return []
        }

        self.caffeineEnabled = status.caffeineEnabled

        let (nextLow, intendedReason) = decide(
            status: status,
            prevLowBattery: lastLowBattery
        )
        lastLowBattery = nextLow

        let preventSleep: Bool
        let reasonString: String

        switch intendedReason {
        case .onAC:
            preventSleep = true
            reasonString = "onAC"
        case .onBattery:
            preventSleep = false
            reasonString = "onBattery"
        case .lowBattery:
            preventSleep = false
            reasonString = "lowBattery"
        case .excludedSSID(let ssid):
            preventSleep = false
            reasonString = "excludedSSID:\(ssid)"
        case .off:
            preventSleep = false
            reasonString = "off"
        case .failure(let status):
            preventSleep = false
            reasonString = "failure:\(status)"
        }

        self.isPreventingSleep = preventSleep
        self.lastReason = reasonString

        return [
            PluginEffect(
                capability: "power.preventIdleSleep",
                payload: [
                    "preventSleep": preventSleep ? "true" : "false",
                    "reason": reasonString
                ]
            )
        ]
    }

    func makeUIContribution(
        for slot: PluginUISlot,
        context: PluginUIContext
    ) throws -> PluginUIContribution? {
        guard slot == .menubarMenu else { return nil }

        let statusText: String
        let tone: PluginUITone?

        if isPreventingSleep {
            statusText = "Preventing sleep (AC Power)"
            tone = .success
        } else {
            tone = nil
            if !caffeineEnabled {
                statusText = "Disabled"
            } else if lastReason.hasPrefix("excludedSSID:") {
                let ssid = lastReason.replacingOccurrences(of: "excludedSSID:", with: "")
                statusText = "Excluded Wi-Fi (\(ssid))"
            } else if lastReason == "lowBattery" {
                statusText = "Low Battery"
            } else if lastReason == "onBattery" {
                statusText = "Battery Mode"
            } else if lastReason.hasPrefix("failure:") {
                statusText = "System Failure"
            } else {
                statusText = "Idle"
            }
        }

        let components = [
            PluginUIComponentDTO(
                id: "caffeine-status",
                type: .metric,
                label: "Caffeine",
                value: statusText,
                tone: tone,
                iconName: "cup.and.saucer",
                action: nil
            ),
            PluginUIComponentDTO(
                id: "caffeine-toggle",
                type: .button,
                label: caffeineEnabled ? "Turn Off" : "Turn On",
                value: nil,
                tone: nil,
                iconName: nil,
                action: PluginUIActionDTO(
                    id: "caffeine.toggle",
                    capability: "plugin.caffeine.toggle",
                    routing: .pluginEvent,
                    payload: [:]
                )
            )
        ]

        return PluginUIContribution(
            pluginID: manifest.id,
            slot: slot,
            targetSessionID: nil,
            priority: 10,
            expiresAt: nil,
            components: components
        )
    }

    func needsTick(surfaceState: PluginSurfaceState) -> Bool {
        return false
    }

    // MARK: - Internal Decision
    private enum DecidedReason {
        case off
        case onAC
        case excludedSSID(String)
        case onBattery
        case lowBattery
        case failure(Int32)
    }

    private func decide(
        status: PluginPowerStatus,
        prevLowBattery: Bool
    ) -> (nextLowBattery: Bool, reason: DecidedReason) {
        let nextLow: Bool
        if let level = status.batteryLevel {
            if prevLowBattery {
                nextLow = level < Self.lowBatteryOnThreshold
            } else {
                nextLow = level <= Self.lowBatteryOffThreshold
            }
        } else {
            nextLow = false
        }

        guard status.caffeineEnabled else { return (nextLow, .off) }

        if let ssid = status.currentSSID, status.excludedSSIDs.contains(ssid) {
            return (nextLow, .excludedSSID(ssid))
        }

        if !status.isOnACPower {
            if nextLow {
                return (nextLow, .lowBattery)
            }
            return (nextLow, .onBattery)
        }

        if nextLow {
            return (nextLow, .lowBattery)
        }

        return (nextLow, .onAC)
    }
}
