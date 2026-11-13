import Foundation
import RelayCore
import UserNotifications

/// 系统通知（设计方案第 14 节“送不到可见”）。通知里不放信件正文，只放提醒内容。
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    /// 设置里的“通知”开关，默认开
    static let enabledKey = "notificationsEnabled"

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ notice: Notice) {
        guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = "AgentRelay · \(notice.kind)"
        content.body = notice.text
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// 应用在前台时也显示通知
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
