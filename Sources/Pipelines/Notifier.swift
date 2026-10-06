import AppKit
import Observation
import PipelineCore
import UserNotifications

@MainActor @Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var denied = false

    func start() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        denied = !granted
    }

    func post(_ event: PipelineEvent) {
        let content = UNMutableNotificationContent()
        content.title = "!\(event.mergeRequest.key.iid) \(event.mergeRequest.title)"
        content.body = event.text
        content.sound = .default
        content.userInfo = ["url": event.mergeRequest.url.absoluteString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    // The panel makes the app active, and macOS hides banners of the active app unless asked.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let text = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: text)
        else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
