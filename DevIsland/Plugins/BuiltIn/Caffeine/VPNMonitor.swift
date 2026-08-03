import Foundation
import Combine
import SystemConfiguration

/// 활성 VPN 연결 여부를 SystemConfiguration dynamic store로 감시한다.
///
/// FortiClient(Network Extension → `/VPN`)를 비롯해 IKEv2·Cisco IPSec·L2TP-over-IPSec
/// (→ `/IPSec`) 네이티브 VPN은 연결되면 `State:/Network/Service/<id>/VPN|IPSec` 런타임
/// 키가 나타난다. 다만 키 존재만으로는 부족하다 — connecting/disconnecting/suspended
/// 전이 상태에서도 키가 잔류할 수 있으므로, 각 서비스의 실제 연결 상태를
/// `SCNetworkConnectionGetStatus == .connected`로 확인해 판정한다.
///
/// `PPP` 엔티티는 PPPoE(DSL 브로드밴드) 연결도 사용하므로 패턴에서 제외한다. 순수 L2TP는
/// 사실상 항상 IPSec과 함께 쓰여 `/IPSec`로 잡히므로 실질 커버리지 손실은 없다.
///
/// `PowerSourceMonitor`와 동일하게 host-owned 모니터이며, run-loop source 콜백으로
/// 상태 변화를 감지하고 등록/생성 실패 시 폴링으로 폴백한다.
final class VPNMonitor: ObservableObject {
    @Published private(set) var isVPNConnected: Bool = false

    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var pollingTimer: Timer?

    /// VPN 서비스 상태를 노출하는 dynamic store 키의 정규식 패턴.
    private static let servicePattern = "State:/Network/Service/[^/]+/(VPN|IPSec)"

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

        // notification key 등록과 run-loop source 생성이 모두 성공해야 이벤트 구독이
        // 완성된다. 하나라도 실패하면 최초 refresh() 이후 상태가 stale하게 남으므로
        // 폴링으로 폴백한다.
        let registered = SCDynamicStoreSetNotificationKeys(store, nil, [Self.servicePattern as CFString] as CFArray)
        if registered, let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else {
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

    /// VPN 서비스 중 하나라도 실제 `.connected` 상태이면 `true`.
    ///
    /// 패턴에 매칭되는 `State:` 키로 후보 서비스를 찾되, 키 존재만으로 판정하지 않고
    /// 각 서비스의 `SCNetworkConnectionGetStatus`를 확인한다. connecting/disconnecting/
    /// suspended 상태에서 키가 잔류하더라도 `.connected`가 아니면 연결로 보지 않는다.
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
        for key in keys {
            // 키 형식: State:/Network/Service/<serviceID>/<entity>
            let parts = key.components(separatedBy: "/")
            guard parts.count >= 5 else { continue }
            let serviceID = parts[3]
            guard let connection = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, nil, nil) else {
                continue
            }
            if SCNetworkConnectionGetStatus(connection) == .connected {
                return true
            }
        }
        return false
    }

    private func startPollingFallback() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}
