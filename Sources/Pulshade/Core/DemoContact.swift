#if os(macOS)
import Foundation

/// A copy of Pulshade on a Mac that acts as a contact who always answers, for App Review to chat with.
///
/// On only when launched with `PULSHADE_DEMO_CONTACT=1` and `PULSHADE_PROFILE=review`, so the real profile can never
/// be put into demo mode.
/// It takes every friend request, says hello once, answers every message in a one-to-one chat after a moment, says
/// hello once in a group it joins and answers there only when mentioned, turns calls down, and never locks itself.
/// Nothing in the app shows it, and nothing but ordinary Pulshade messages leaves the Mac.
@MainActor
final class DemoContact {
    static let isOn = ProcessInfo.processInfo.environment["PULSHADE_DEMO_CONTACT"] == "1"
        && ProcessInfo.processInfo.environment["PULSHADE_PROFILE"] == "review"
    static let shared = DemoContact()

    static let welcome = "Hi! I'm the Pulshade demo contact. Messages between us are end-to-end encrypted. "
        + "Send me anything – text, a photo, a voice note – and I'll answer."

    /// Per chat: when it last answered, and what arrived lately (to spot a flood).
    private var lastReply: [UUID: Date] = [:]
    private var arrivals: [UUID: [Date]] = [:]
    /// Chats with an answer already on its way: anything more that comes meanwhile is covered by it.
    private var replyDue: Set<UUID> = []
    private var greetedGroups: Set<UUID> = []
    private var accepting: Set<FriendRequest.ID> = []
    private var awake: NSObjectProtocol?

    /// More than this many messages in a minute from one chat and it goes quiet there until things calm down.
    private let floodLimit = 20

    private init() {}

    /// Keeps the Mac from going to sleep while it waits for testers.
    func start() {
        guard Self.isOn, awake == nil else { return }
        awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                      reason: "Answering as the demo contact")
    }

    // MARK: Friend requests

    /// Every request is taken, a moment after it arrives, and answered with a hello.
    func requestArrived(_ id: FriendRequest.ID, model: AppModel) {
        guard Self.isOn, !accepting.contains(id) else { return }
        accepting.insert(id)
        Task { @MainActor [weak model] in
            try? await Task.sleep(for: .seconds(1))
            defer { self.accepting.remove(id) }
            guard let model, model.phase == .unlocked, let convo = model.acceptRequest(id) else { return }
            try? await Task.sleep(for: .seconds(2))
            guard model.phase == .unlocked else { return }
            model.send(Self.welcome, in: convo.id)
        }
    }

    /// Requests left waiting from before (it was closed or locked when they came).
    func takeWaitingRequests(model: AppModel) {
        guard Self.isOn else { return }
        Task { @MainActor [weak model] in
            try? await Task.sleep(for: .seconds(3))
            guard let model, model.phase == .unlocked else { return }
            for request in model.data.requests { self.requestArrived(request.id, model: model) }
        }
    }

    // MARK: Messages

    /// A message just delivered into a chat. One-to-one, it's always answered; in a group, only when it mentions this account.
    func messageArrived(_ message: Message, in id: Conversation.ID, from sender: Contact, model: AppModel) {
        guard Self.isOn, !sender.isSelf, message.sender != "me", message.sender != "system",
              Date().timeIntervalSince(message.date) < 86_400,
              let convo = model.data.conversations.first(where: { $0.id == id }) else { return }
        let reply: String
        switch convo.kind {
        case .direct:
            reply = Self.answer(to: message)
        case .group:
            guard message.mentions.contains(where: { $0.fingerprint == "me" }) else { return }
            reply = "Hi \(sender.displayName)! " + Self.answer(to: message)
        case .channel, .broadcast:
            return
        }
        // A flood (someone holding the send button) is ignored until it calms down.
        let now = Date()
        var recent = (arrivals[id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        recent.append(now)
        arrivals[id] = recent
        guard recent.count <= floodLimit, !replyDue.contains(id) else { return }
        replyDue.insert(id)
        // A natural pause, and never more than one answer a second in the same chat.
        let since = now.timeIntervalSince(lastReply[id] ?? .distantPast)
        let wait = max(Double.random(in: 1...2), 1 - since)
        Task { @MainActor [weak model] in
            try? await Task.sleep(for: .seconds(wait))
            self.replyDue.remove(id)
            guard let model, model.phase == .unlocked else { return }
            self.lastReply[id] = Date()
            model.send(reply, in: id)
        }
    }

    /// A group this account has just been let into: one hello.
    func joinedGroup(_ id: Conversation.ID, model: AppModel) {
        guard Self.isOn, !greetedGroups.contains(id),
              model.data.conversations.first(where: { $0.id == id })?.kind == .group else { return }
        greetedGroups.insert(id)
        Task { @MainActor [weak model] in
            try? await Task.sleep(for: .seconds(2))
            guard let model, model.phase == .unlocked else { return }
            model.send("Hi everyone! I'm the Pulshade demo contact. Mention me and I'll answer.", in: id)
        }
    }

    private static func answer(to message: Message) -> String {
        if message.voice != nil || message.awaiting == .voice || message.attachment?.kind == .voice {
            return "Voice note received. It reached me end-to-end encrypted."
        }
        if message.video != nil || message.attachment?.kind == .video {
            return "Thanks, the video arrived safely."
        }
        if message.image != nil || message.awaiting == .photo || message.attachment?.kind == .photo {
            return "Thanks, the photo arrived safely."
        }
        if message.attachment != nil { return "Thanks, the file arrived safely." }
        if message.note != nil { return "Thanks, the note arrived safely." }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return "Got it, thanks!" }
        let short = text.count > 60 ? String(text.prefix(60)) + "…" : text
        return "Got it: \"\(short)\" Thanks for trying Pulshade!"
    }
}
#endif
