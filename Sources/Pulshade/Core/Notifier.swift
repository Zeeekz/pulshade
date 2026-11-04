import Foundation
import UserNotifications

/// Mac notifications for new messages.
///
/// macOS stores notification text in its own database, outside Pulshade's encryption, so by
/// default a notification only says "New message". One notification per chat is kept and
/// replaced, and all of them are cleared when Pulshade locks.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called with the conversation id when someone clicks a notification.
    var onOpen: ((UUID) -> Void)?

    private var center: UNUserNotificationCenter? {
        // Notifications need a real .app bundle; tests and `swift run` would crash asking for one.
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    func attach() {
        center?.delegate = self
    }

    func start() {
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ content: (title: String, body: String), conversation: UUID, sound: Bool) {
        guard let center else { return }
        let note = UNMutableNotificationContent()
        note.title = content.title
        note.body = content.body
        note.threadIdentifier = conversation.uuidString
        note.userInfo = ["conversation": conversation.uuidString]
        if sound { note.sound = .default }
        // Same identifier per chat: a new message replaces the old banner instead of piling up.
        center.add(UNNotificationRequest(identifier: conversation.uuidString, content: note, trigger: nil))
    }

    func clear(_ conversation: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: [conversation.uuidString])
    }

    func clearAll() {
        center?.removeAllDeliveredNotifications()
        center?.removeAllPendingNotificationRequests()
    }

    /// What a notification says, given the privacy setting.
    static func content(for message: Message, in conversation: Conversation, sender: String,
                        style: NotificationContent) -> (title: String, body: String) {
        switch style {
        case .hidden:
            return ("PULSHADE", "New message")
        case .name:
            return (title(conversation, sender: sender), "New message")
        case .full:
            let body: String
            if message.voice != nil { body = "🎤 Voice note" }
            else if !message.text.isEmpty { body = String(message.text.prefix(200)) }
            else if message.image != nil { body = "📷 Photo" }
            else { body = "New message" }
            let prefix = conversation.kind == .group ? "\(sender): " : ""
            return (title(conversation, sender: sender), prefix + body)
        }
    }

    private static func title(_ conversation: Conversation, sender: String) -> String {
        conversation.kind == .direct ? sender : conversation.title
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["conversation"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { self.onOpen?(id) }
    }
}
