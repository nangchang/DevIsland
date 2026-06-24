import UserNotifications
import Foundation

final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private static let categoryApproval = "DEVISLAND_APPROVAL"
    private static let actionApprove = "DEVISLAND_APPROVE"
    private static let actionDeny = "DEVISLAND_DENY"

    private override init() { super.init() }

    func setup() {
        let l = L10n.shared
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approveAction = UNNotificationAction(
            identifier: Self.actionApprove,
            title: l.notifActionApprove,
            options: []
        )
        let denyAction = UNNotificationAction(
            identifier: Self.actionDeny,
            title: l.notifActionDeny,
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryApproval,
            actions: [approveAction, denyAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func sendApprovalRequest(_ request: PendingRequest) {
        let content = UNMutableNotificationContent()
        content.title = request.toolName
        content.body = request.message.isEmpty ? L10n.shared.notifApprovalBody : request.message
        content.categoryIdentifier = Self.categoryApproval
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let notifRequest = UNNotificationRequest(
            identifier: request.id.uuidString,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(notifRequest)
    }

    func cancelNotification(id: UUID) {
        let idStr = id.uuidString
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [idStr])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [idStr])
    }

    func sendTaskCompletion(sessionTitle: String) {
        let l = L10n.shared
        let content = UNMutableNotificationContent()
        content.title = l.notifTaskCompleteTitle
        content.body = l.notifTaskCompleteBody(sessionTitle)
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let requestId = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard let uuid = UUID(uuidString: requestId) else { return }
            switch action {
            case NotificationManager.actionApprove:
                AppState.shared.respondFromNotification(requestId: uuid, approved: true)
            case NotificationManager.actionDeny:
                AppState.shared.respondFromNotification(requestId: uuid, approved: false)
            default:
                break
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 앱 포커스 중엔 배너 표시 안 함 — 노치가 이미 보여줌
        completionHandler([])
    }
}
