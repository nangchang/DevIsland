import Foundation
import Combine
import IOKit.ps

/// AC 전원 상태와 배터리 잔량을 IOKit PowerSource API로 감시한다.
/// 배터리 없는 데스크톱 Mac에서는 `batteryLevel == nil` (영구).
final class PowerSourceMonitor: ObservableObject {
    @Published private(set) var isOnACPower: Bool = true
    /// 0.0 ~ 1.0. nil = 데스크톱(배터리 없음) 또는 최초 호출 전.
    @Published private(set) var batteryLevel: Double? = nil

    private var runLoopSource: CFRunLoopSource?
    /// nil = 미확정 / false = 데스크톱 / true = 노트북. 첫 성공 호출에서 확정.
    private var hasBatterySource: Bool? = nil

    init() {
        refresh()
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { monitor.refresh() }
        }, context)?.takeRetainedValue() else {
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        refresh()
    }

    func stop() {
        guard let source = runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = nil
    }

    private func refresh() {
        guard let snapshot = Self.snapshot() else {
            // 일시적 IOKit 실패 — 직전 상태를 그대로 유지(데스크톱 가정 금지).
            return
        }

        // 첫 성공 호출에서 배터리 보유 여부 확정. 이후 변경 안 함.
        if hasBatterySource == nil {
            hasBatterySource = snapshot.hasBattery
        }

        if snapshot.isOnACPower != isOnACPower {
            isOnACPower = snapshot.isOnACPower
        }

        // 데스크톱은 항상 nil, 노트북은 측정값 사용.
        let newLevel: Double? = (hasBatterySource == true) ? snapshot.batteryLevel : nil
        if newLevel != batteryLevel {
            batteryLevel = newLevel
        }
    }

    private struct Snapshot {
        let isOnACPower: Bool
        let batteryLevel: Double?
        let hasBattery: Bool
    }

    /// IOKit에서 현재 power source를 읽는다. 실패 시 nil — 호출자가 직전 상태 유지.
    private static func snapshot() -> Snapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return nil
        }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        if list.isEmpty {
            // 배터리 없는 데스크톱 Mac — 항상 AC.
            return Snapshot(isOnACPower: true, batteryLevel: nil, hasBattery: false)
        }

        var onAC = true
        var level: Double? = nil

        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let state = info[kIOPSPowerSourceStateKey] as? String {
                onAC = (state == kIOPSACPowerValue)
            }
            if let current = info[kIOPSCurrentCapacityKey] as? Int,
               let max = info[kIOPSMaxCapacityKey] as? Int,
               max > 0 {
                level = Double(current) / Double(max)
            }
        }

        return Snapshot(isOnACPower: onAC, batteryLevel: level, hasBattery: true)
    }
}
