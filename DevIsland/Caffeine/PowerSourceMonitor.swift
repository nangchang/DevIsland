import Foundation
import Combine
import IOKit.ps

/// AC 전원 상태와 배터리 잔량을 IOKit PowerSource API로 감시한다.
/// 배터리 없는 데스크톱 Mac에서는 `batteryLevel == nil`.
final class PowerSourceMonitor: ObservableObject {
    @Published private(set) var isOnACPower: Bool = true
    /// 0.0 ~ 1.0. nil이면 내장 배터리 없음(데스크톱).
    @Published private(set) var batteryLevel: Double? = nil

    private var runLoopSource: CFRunLoopSource?

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
        let snapshot = Self.snapshot()
        if snapshot.isOnACPower != isOnACPower {
            isOnACPower = snapshot.isOnACPower
        }
        if snapshot.batteryLevel != batteryLevel {
            batteryLevel = snapshot.batteryLevel
        }
    }

    private struct Snapshot {
        let isOnACPower: Bool
        let batteryLevel: Double?
    }

    private static func snapshot() -> Snapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            // 정보를 못 얻으면 안전을 위해 AC라고 가정(데스크톱 기본 동작).
            return Snapshot(isOnACPower: true, batteryLevel: nil)
        }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty else {
            return Snapshot(isOnACPower: true, batteryLevel: nil)
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

        return Snapshot(isOnACPower: onAC, batteryLevel: level)
    }
}
