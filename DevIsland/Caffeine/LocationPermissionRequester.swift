import Foundation
import CoreLocation
import Combine

/// macOS 14+에서 SSID를 읽으려면 Location 권한이 필요하다.
/// `CWInterface` 호출만으로는 권한 다이얼로그가 뜨지 않으므로,
/// `CLLocationManager`로 명시적으로 권한을 요청한다.
final class LocationPermissionRequester: NSObject, ObservableObject {
    @Published private(set) var status: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        self.status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// 권한이 미결정 상태면 시스템 다이얼로그를 띄운다.
    /// 이미 결정된 상태(허용/거부)면 no-op — 사용자가 System Settings에서 직접 변경해야 함.
    func requestIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }
}

extension LocationPermissionRequester: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            self?.status = manager.authorizationStatus
        }
    }
}
