import Foundation

/// 고정 간격으로 남은 진행률(1.0 → 0.0)을 보고하고 만료 시 한 번 콜백하는 카운트다운.
/// 승인 타임아웃과 알림 자동 접힘 타이머가 공유한다.
/// 메인 런루프 Timer 기반이므로 메인 스레드에서 사용한다.
final class CountdownTimer {
    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    /// 진행 중인 카운트다운이 있으면 취소하고 새로 시작한다.
    /// `onProgress`는 매 틱마다 남은 비율(max(0, 1 - elapsed/duration))로 호출되고,
    /// 만료 틱에서는 `onProgress(0)` 이후 `onExpire`가 한 번 호출된다.
    func start(
        duration: TimeInterval,
        interval: TimeInterval = 0.1,
        onProgress: @escaping (Double) -> Void,
        onExpire: @escaping () -> Void
    ) {
        cancel()
        var elapsed: Double = 0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            elapsed += interval
            onProgress(max(0, 1.0 - (elapsed / duration)))
            guard elapsed >= duration else { return }
            timer.invalidate()
            self?.timer = nil
            onExpire()
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}
