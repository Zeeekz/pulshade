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
        MessageTone.install()
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ content: (title: String, body: String), conversation: UUID, sound: Bool, tone: MessageTone = .standard) {
        guard let center else { return }
        let note = UNMutableNotificationContent()
        note.title = content.title
        note.body = content.body
        note.threadIdentifier = conversation.uuidString
        note.userInfo = ["conversation": conversation.uuidString]
        if sound {
            if let name = tone.fileName {
                MessageTone.install()
                note.sound = UNNotificationSound(named: UNNotificationSoundName(name))
            } else {
                note.sound = .default
            }
        }
        // Same identifier per chat: a new message replaces the old banner instead of piling up.
        center.add(UNNotificationRequest(identifier: conversation.uuidString, content: note, trigger: nil))
    }

    func clear(_ conversation: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: [conversation.uuidString])
    }

    /// Removes the "New message" banners Apple delivered while the phone was locked.
    func clearWakeBanners() async {
        guard let center else { return }
        let delivered = await center.deliveredNotifications()
        let ids = delivered.filter { $0.request.trigger is UNPushNotificationTrigger }.map(\.request.identifier)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
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
        // A wake-up push arriving while Pulshade is open is redundant: the app fetches the mail itself.
        if notification.request.trigger is UNPushNotificationTrigger { return [] }
        return [.banner, .sound, .list]
    }

    /// Finishes on the main thread: UIKit aborts the app if the completion of a tapped notification arrives from
    /// a background one while the app is being brought forward.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let raw = response.notification.request.content.userInfo["conversation"] as? String
        DispatchQueue.main.async {
            if let raw, let id = UUID(uuidString: raw) { MainActor.assumeIsolated { Notifier.shared.onOpen?(id) } }
            completionHandler()
        }
    }
}
