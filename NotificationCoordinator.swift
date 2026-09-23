import Foundation
import UserNotifications

final class NotificationCoordinator {

    private let center = UNUserNotificationCenter.current()

    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(
                options: [.alert, .sound, .badge]
            )

            let settings = await center.notificationSettings()

            print("通知許可結果: \(granted)")
            print("通知AuthorizationStatus: \(settings.authorizationStatus.rawValue)")
            print("アラート設定: \(settings.alertSetting.rawValue)")

            return granted

        } catch {
            print("❌ 通知許可エラー: \(error.localizedDescription)")
            return false
        }
    }

    func send(
        title: String,
        body: String
    ) async {

        let settings = await center.notificationSettings()

        guard settings.authorizationStatus == .authorized else {
            print("❌ 通知未許可: \(settings.authorizationStatus.rawValue)")
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
            print("✅ 通知登録成功: \(body)")
        } catch {
            print("❌ 通知登録失敗: \(error.localizedDescription)")
        }
    }
}
