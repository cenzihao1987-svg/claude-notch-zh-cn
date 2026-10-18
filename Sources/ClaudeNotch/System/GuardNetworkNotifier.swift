import AppKit
import UserNotifications

@MainActor
final class GuardNetworkNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GuardNetworkNotifier()

    func send(_ issues: [GuardConnectionIssue]) async {
        // Command-line builds/tests have no notification identity; do not invoke the system there.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil, !issues.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        } else if settings.authorizationStatus == .denied { return }
        let content = UNMutableNotificationContent()
        guard !Task.isCancelled else { return }
        let language = AppLanguage.saved
        content.title = language.text("Claude 网络预警", "Claude network warning")
        // Never include addresses, controller paths, credentials, or sample fingerprints.
        content.body = issues.map { $0.message(language) }.joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = "claude-network-warning"
        try? await center.add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
