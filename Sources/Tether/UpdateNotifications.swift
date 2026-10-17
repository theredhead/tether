import Foundation
import UserNotifications

final class UpdateNotifications: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func requestPermission() async throws -> Bool {
        guard let center else { throw SyncFailure(message: "Notifications require the packaged Tether app.") }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }

    func notifyUpdated(_ job: SyncJob) async throws {
        guard let center else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(job.name.isEmpty ? "Sync" : job.name) updated"
        let filename = URL(fileURLWithPath: job.destinationPath).lastPathComponent
        content.body = job.isFolder ? "Updated files in \(filename)." : "Updated \(filename)."
        content.sound = .default
        content.threadIdentifier = job.id.uuidString
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Show update alerts even while Settings is the active window.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
