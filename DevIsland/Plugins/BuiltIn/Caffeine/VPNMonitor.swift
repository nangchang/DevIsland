import Foundation
import Combine
import SystemConfiguration

/// 활성 VPN 연결 여부를 SystemConfiguration dynamic store로 감시한다.
///
/// FortiClient를 포함한 네이티브 VPN(Network Extension·IKEv2·L2TP 등)은 연결되면
/// `State:/Network/Service/<id>/VPN|PPP|IPSec` 런타임 키가 나타나고 해제되면 사라진다.
/// 설정만 되어 있고 연결되지 않은 서비스는 `Setup:` 도메인에만 존재하므로,
/// `State:` 도메인의 해당 키 존재 여부만으로 연결 상태를 판정한다.
///
/// `PowerSourceMonitor`와 동일하게 host-owned 모니터이며, run-loop source 콜백으로
/// 상태 변화를 감지하고 생성 실패 시 폴링으로 폴백한다.
final class VPNMonitor: ObservableObject {
    @Published private(set) var isVPNConnected: Bool = false

    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var pollingTimer: Timer?

    /// 활성 VPN 서비스 상태를 노출하는 dynamic store 키의 정규식 패턴.
    private static let servicePattern = "State:/Network/Service/[^/]+/(VPN|PPP|IPSec)"

    init() {
        refresh()
    }

    deinit {
        stop()
    }

    func start() {
        guard store == nil else { return }

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<VPNMonitor>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { monitor.refresh() }
        }

        guard let store = SCDynamicStoreCreate(
            nil,
            "DevIsland.Caffeine.VPNMonitor" as CFString,
            callback,
            &context
        ) else {
            // dynamic store 생성 실패 — 폴링으로 폴백.
            startPollingFallback()
            return
        }
        self.store = store

        SCDynamicStoreSetNotificationKeys(store, nil, [Self.servicePattern as CFString] as CFArray)
        if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else {
            // 이벤트 구독 실패 — 폴링으로 폴백.
            startPollingFallback()
        }
        refresh()
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        store = nil
    }

    private func refresh() {
        let connected = Self.hasActiveVPN(store: store)
        if connected != isVPNConnected {
            isVPNConnected = connected
        }
    }

    /// dynamic store에 활성 VPN 서비스 키가 하나라도 있으면 `true`.
    /// 시작 전(store == nil) 최초 호출에서는 임시 store로 조회한다.
    private static func hasActiveVPN(store: SCDynamicStore?) -> Bool {
        let resolved = store ?? SCDynamicStoreCreate(
            nil,
            "DevIsland.Caffeine.VPNMonitor.query" as CFString,
            nil,
            nil
        )
        guard let resolved else { return false }
        guard let keys = SCDynamicStoreCopyKeyList(resolved, servicePattern as CFString) as? [String] else {
            return false
        }
        return !keys.isEmpty
    }

    private func startPollingFallback() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}
