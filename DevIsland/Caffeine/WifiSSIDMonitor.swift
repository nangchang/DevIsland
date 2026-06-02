import Foundation
import Combine
import CoreWLAN

/// 현재 연결된 Wi-Fi SSID를 추적하고, 주변 SSID 스캔 API를 제공한다.
///
/// macOS 14+에서 `CWInterface.ssid()`는 Location 권한이 없으면 `nil`을 반환한다.
/// `locationPermissionAvailable`에 권한 가용성(추정값)을 노출한다.
final class WifiSSIDMonitor: NSObject, ObservableObject {
    @Published private(set) var currentSSID: String?
    /// SSID가 한 번이라도 nil이 아닌 적이 있었는지(권한 추정 신호).
    @Published private(set) var hasObservedSSID: Bool = false

    private let client = CWWiFiClient.shared()
    private var pollingTimer: Timer?

    override init() {
        super.init()
    }

    deinit {
        pollingTimer?.invalidate()
        try? client.stopMonitoringEvent(with: .ssidDidChange)
        client.delegate = nil
    }

    func start() {
        refresh()
        client.delegate = self
        do {
            try client.startMonitoringEvent(with: .ssidDidChange)
        } catch {
            // 이벤트 구독 실패 시 폴링으로 폴백
            startPollingFallback()
        }
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        try? client.stopMonitoringEvent(with: .ssidDidChange)
        client.delegate = nil
    }

    /// 주변 Wi-Fi 네트워크를 스캔한다. Location 권한 없으면 결과 비어 있거나 실패.
    /// 메인 스레드를 블로킹하지 않도록 background queue에서 실행.
    func scanForNetworks() async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let interface = CWWiFiClient.shared().interface()
            guard let networks = try interface?.scanForNetworks(withName: nil) else {
                return [String]()
            }
            let ssids = networks.compactMap { $0.ssid }
            return Array(Set(ssids)).sorted()
        }.value
    }

    private func refresh() {
        let ssid = client.interface()?.ssid()
        if ssid != currentSSID {
            currentSSID = ssid
        }
        if ssid != nil && !hasObservedSSID {
            hasObservedSSID = true
        }
    }

    private func startPollingFallback() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}

extension WifiSSIDMonitor: CWEventDelegate {
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
}
