import Foundation

/// @unchecked Sendable: mutable state is only ever touched inside the
/// PluginRunner actor, which serializes every call (architecture doc §6.4).
final class CaffeinePlugin: DevIslandPlugin, @unchecked Sendable {
    let manifest = PluginManifest(
        id: "caffeine",
        name: "Caffeine",
        version: "1.0.0",
        apiVersion: 1,
        kind: .system,
        permissions: [.controlPowerSleep, .showMenubarMenu],
        surfaces: [.menubarMenu],
        activationEvents: [
            "power.status.changed",
            "plugin.started",
            "plugin.tick",
            "plugin.action.invoked",
            PluginEventKind.languageChanged.rawValue
        ],
        localizedName: PluginLocalizedString(english: "Caffeine", korean: "Caffeine"),
        localizedDescription: PluginLocalizedString(
            english: "Prevents the Mac from sleeping while a session is active. Automatically turns off on low battery.",
            korean: "세션 진행 중 Mac이 잠자기 상태로 전환되는 것을 방지합니다. 배터리 부족 시 자동으로 해제됩니다."
        )
    )

    private var lastLowBattery: Bool = false
    private var lastReason: String = "off"
    private var isPreventingSleep: Bool = false
    private var caffeineEnabled: Bool = true

    private static let lowBatteryOffThreshold: Double = 0.20
    private static let lowBatteryOnThreshold: Double = 0.23

    func onEvent(_ event: PluginEvent, context: PluginContext) async throws -> [PluginEffect] {
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

        self.caffeineEnabled = status.featureEnabled

        if status.isEffectResult {
            isPreventingSleep = status.isPreventingSleep ?? false
            if let code = status.effectFailureCode {
                lastReason = "failure:\(code)"
            } else if let reason = status.effectReason, !reason.isEmpty {
                lastReason = reason
            } else {
                lastReason = isPreventingSleep ? "onAC" : "off"
            }
            return []
        }

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

        let language = context.language

        if isPreventingSleep {
            statusText = language.s("Preventing sleep (AC Power)", "슬립 차단 중 (AC 전원)")
            tone = .success
        } else {
            tone = nil
            if !caffeineEnabled {
                statusText = language.s("Disabled", "비활성화됨")
            } else if lastReason.hasPrefix("excludedSSID:") {
                let ssid = String(lastReason.dropFirst("excludedSSID:".count))
                statusText = language.s("Excluded Wi-Fi (\(ssid))", "예외 Wi-Fi (\(ssid))")
            } else if lastReason == "lowBattery" {
                statusText = language.s("Low Battery", "배터리 부족")
            } else if lastReason == "onBattery" {
                statusText = language.s("Battery Mode", "배터리 모드")
            } else if lastReason.hasPrefix("failure:") {
                let code = String(lastReason.dropFirst("failure:".count))
                statusText = language.s("System Failure (\(code))", "시스템 실패 (\(code))")
            } else {
                statusText = language.s("Idle", "대기")
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
                label: caffeineEnabled ? language.s("Turn Off", "끄기") : language.s("Turn On", "켜기"),
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

    var settingsPaneDescriptor: PluginSettingsPaneDescriptor? {
        PluginSettingsPaneDescriptor(
            pluginID: manifest.id,
            label: PluginLocalizedString(english: "Caffeine", korean: "Caffeine"),
            systemImage: "cup.and.saucer"
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

        guard status.featureEnabled else { return (nextLow, .off) }

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
