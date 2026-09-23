import Foundation
import UserNotifications

final class NotificationCoordinator: NSObject,
                                     UNUserNotificationCenterDelegate {

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()

        // アプリが前面にいるときの通知も受け取る
        center.delegate = self
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(
                options: [.alert, .sound, .badge]
            )

            let settings = await center.notificationSettings()

            print("📣 通知許可結果: \(granted)")
            print(
                "📣 AuthorizationStatus: \(settings.authorizationStatus.rawValue)"
            )
            print(
                "📣 AlertSetting: \(settings.alertSetting.rawValue)"
            )

            return granted

        } catch {
            print(
                "❌ 通知許可エラー: \(error.localizedDescription)"
            )

            return false
        }
    }

    // MARK: - Send

    func send(
        title: String,
        body: String
    ) async {

        let settings = await center.notificationSettings()

        guard settings.authorizationStatus == .authorized else {
            print(
                "❌ 通知未許可: \(settings.authorizationStatus.rawValue)"
            )
            return
        }

        let content = UNMutableNotificationContent()

        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "yorisoi-support"

        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
        }

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 1,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)

            print("✅ 通知登録成功")
            print("   title: \(title)")
            print("   body: \(body)")

        } catch {
            print(
                "❌ 通知登録失敗: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Foreground Notification

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {

        print(
            "🔔 フォアグラウンド通知表示: \(notification.request.content.body)"
        )

        return [
            .banner,
            .sound,
            .badge
        ]
    }
}
