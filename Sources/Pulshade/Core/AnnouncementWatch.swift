import Foundation
#if canImport(PulshadeShared)
import PulshadeShared
#endif
#if os(iOS)
import BackgroundTasks
#endif

/// Announcements while Pulshade is locked or closed: the Mac checks while locked, and on iPhone iOS wakes the app now
/// and then (Background App Refresh). Announcements are public, so this needs no vault: it asks the relay on a lane of
/// its own with no account attached, checks each one against the admin key, and raises a notification the way the
/// last unlocked account's settings say. They reach the Announcements chat itself at the next unlock, as before.
@MainActor
enum AnnouncementWatch {
    /// What the notification may say, copied out of the vault at each save. Nil until an account has been opened
    /// here, and then nothing is shown.
    struct Settings: Codable, Equatable {
        var notifications: Bool
        var content: NotificationContent
        var sound: Bool
        var muted: Bool
    }

    static let taskID = "app.pulshade.ios.announcements"
    private static let settingsKey = "pulshade.announcements.watch"
    private static let noticedKey = "pulshade.announcements.noticed"
    private static let versionKey = "pulshade.announcements.version"
    private static let shownKey = "pulshade.announcements.shown"

    static func mirror(_ settings: Settings) {
        guard settings != self.settings, let raw = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(raw, forKey: settingsKey)
    }

    static func forget() {
        for key in [settingsKey, noticedKey, versionKey, shownKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    private static var settings: Settings? {
        UserDefaults.standard.data(forKey: settingsKey).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
    }

    /// Announcements a notification was already raised for, here or in the chat, so none is raised twice.
    private static var noticed: [String] {
        get { UserDefaults.standard.stringArray(forKey: noticedKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: noticedKey) }
    }

    /// Records `ids` as noticed and hands back the ones that weren't yet.
    @discardableResult
    static func notice(_ ids: [String]) -> [String] {
        var known = noticed
        var fresh: [String] = []
        // `known` grows as we go, so a list that repeats an id still reports it only once.
        for id in ids.map({ $0.uppercased() }) where !known.contains(id) {
            known.append(id)
            fresh.append(id)
        }
        if !fresh.isEmpty { noticed = known }
        return fresh
    }

    /// Asks the relay once. False if it couldn't be reached, so the caller can try again sooner.
    @discardableResult
    static func check() async -> Bool {
        guard let settings,
              let relay = Invite.allowedRelay(AppData.defaultRelay).map({ Invite.route($0, overTor: Tor.enabled) }),
              let url = URL(string: relay) else { return true }
        let client = RelayClient(base: url, lane: "announcements-watch")
        let answer: (list: [Announcement], version: String?)?
        do { answer = try await client.announcements(since: UserDefaults.standard.string(forKey: versionKey)) } catch { return false }
        guard let (listed, version) = answer else { return true }
        let genuine = listed.filter(\.isGenuine)
        // The one last shown was taken back: its banner goes too.
        if let shown = UserDefaults.standard.string(forKey: shownKey), listed.count < 50,
           !genuine.contains(where: { $0.id.uppercased() == shown }) {
            Notifier.shared.clear(Conversation.announcementsID)
            UserDefaults.standard.removeObject(forKey: shownKey)
        }
        let fresh = notice(genuine.map(\.id))
        if let newest = genuine.filter({ fresh.contains($0.id.uppercased()) }).max(by: { $0.date < $1.date }),
           settings.notifications, !settings.muted {
            let body = switch settings.content {
            case .full: fresh.count == 1 ? String(newest.text.prefix(200)) : "\(fresh.count) new announcements"
            case .hidden, .name: fresh.count == 1 ? "New announcement" : "\(fresh.count) new announcements"
            }
            Notifier.shared.post((settings.content == .hidden ? "PULSHADE" : "Announcements", body),
                                 conversation: Conversation.announcementsID, sound: settings.sound)
            UserDefaults.standard.set(newest.id.uppercased(), forKey: shownKey)
        }
        UserDefaults.standard.set(version, forKey: versionKey)
        return true
    }

    #if os(iOS)
    /// Called once at launch, before the app finishes launching, as iOS requires.
    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return task.setTaskCompleted(success: false) }
            Task { @MainActor in run(task) }
        }
    }

    /// Asks iOS for the next wake. It decides when: often within the hour, later on a phone that's rarely used.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// One wake: Tor's port opened again (iOS shut it while suspended), then a check or two in the half minute iOS
    /// allows. A route into the onion service can stall, so a second try gets a fresh one.
    private static func run(_ task: BGAppRefreshTask) {
        schedule()
        // Install the expiration handler before the work starts, so a wake that expires immediately still cancels it.
        let box = TaskBox()
        task.expirationHandler = { box.task?.cancel() }
        box.task = Task { @MainActor in
            await Task.detached { Tor.start(); Tor.wake() }.value
            RelayClient.closeAll()
            var reached = await check()
            if !reached, !Task.isCancelled { reached = await check() }
            task.setTaskCompleted(success: reached)
        }
    }
    #endif
}

/// Lets the expiration handler be installed before the work it cancels is created.
private final class TaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}
