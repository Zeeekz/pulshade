import Foundation
import CryptoKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import Network
#if canImport(PulshadeShared)
import PulshadeShared
#endif
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case welcome, locked, unlocked }
    enum Link: Equatable { case offline, online }

    private(set) var phase: Phase
    private(set) var identity: Identity?
    /// True while applying another of your devices' news, so it isn't echoed back.
    var applyingSync = false
    private(set) var link: Link = .offline
    /// Which passcode slot is open. 0 is the real identity; decoys never see decoy settings.
    private(set) var slot = 0
    var isPrimary: Bool { slot == 0 }
    var data = AppData()
    /// Stories taken back, as "author|id" ("me" for your own) with when. A story that turns up after its removal
    /// (the two arriving out of order, or sent again) is dropped instead of coming back. Kept for three days,
    /// longer than any story lasts. Held in memory only: saving it would change what's saved, and builds that
    /// don't know the change would refuse the data.
    @ObservationIgnored var removedStories: [String: Date] = [:]
    /// A friend's video still arriving: when its last piece (or the story itself) came in. In memory only.
    @ObservationIgnored private var clipActivity: [ClipKey: Date] = [:]
    /// True while a Burn queues its farewells, so they aren't stamped for recall.
    @ObservationIgnored var burning = false
    /// A Burn wiped this phone but the relay still has to be told (see `BurnOrder`): the app keeps trying.
    var burnPending = false
    /// What to tell the person about a Burn, shown over every screen even after the wipe.
    var burnNotice: String?
    @ObservationIgnored let burnStore: BurnOrderStore
    @ObservationIgnored private var burnTask: Task<Void, Never>?
    /// How far a file's upload or download has got (0...1), by message. In memory only: a phone keeps no file.
    var fileProgress: [UUID: Double] = [:]
    /// Files that couldn't be sent or fetched, by message, with the reason in words.
    var fileFailed: [UUID: String] = [:]
    /// Something to tell the person about a file they tried to send, before there was a message to hang it on.
    var fileProblem: String?
    @ObservationIgnored private var fileTasks: [UUID: Task<Void, Never>] = [:]
    /// Clips being uploaded to the relay (by story or message id), and who is to be sent a pointer once each is there.
    @ObservationIgnored private var clipUploads: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var clipWaiting: [UUID: [Contact]] = [:]
    /// Clips being fetched from the relay, so a pointer sent twice is only fetched once.
    @ObservationIgnored private var clipFetching: Set<ClipKey> = []
    /// How often a stalled video has been asked for again, and when last.
    @ObservationIgnored private var clipAsks: [ClipKey: (count: Int, at: Date)] = [:]
    /// When a video was last sent again on someone's asking, as "fingerprint|id", so one asking can't make it
    /// go over and over.
    @ObservationIgnored private var clipResent: [String: Date] = [:]
    var failedAttempts = FileKeys.savedAttempts() {
        didSet { if failedAttempts != oldValue { FileKeys.saveAttempts(failedAttempts) } }
    }
    /// The passcode was right but the account's data wouldn't open, so nothing was opened (or touched).
    private(set) var dataUnreadable = false
    /// Another of your devices has a newer profile than this version can read. Set until PULSHADE is updated.
    private(set) var profileNeedsUpdate = false
    /// The format this build saves profiles in. Only tests change it, to stand in for an older or newer version.
    var profileFormat = AppData.currentFormat
    /// The chat on screen, so incoming messages there don't count as unread.
    var openConversation: Conversation.ID?
    /// A chat something outside the window (a notification, the menu bar) asked to show.
    var requestedConversation: Conversation.ID?
    /// A code that arrived as a pulshade:// link, waiting for the scan screen to use it.
    var openedCode: String?
    /// A handle from a profile link (`pulshade://u/<handle>`, a "Pulshade" button on a website), waiting for
    /// Contacts to look it up. Nothing is sent until you ask: it only shows the profile and its request button.
    var openedHandle: String?
    /// The key check that came with `openedHandle`'s link, if any: its profile must be that account's.
    var openedKeyCheck: String?
    /// The call ringing or in progress, if any. One at a time.
    var call: ActiveCall?
    private var callMedia: CallMedia?
    private var callTimeout: Task<Void, Never>?
    /// Off in tests, which have no microphone: calls then carry only what the test sends.
    var callAudio = true
    /// Locking cuts off requests still under way, so nothing of the last account reaches the relay once the next
    /// one opens. Off in tests, where several accounts share one process and one locking mustn't cut off another.
    var cutOffOnLock = true
    /// Random gaps between fetches, receipts and call joins, so the relay can't line up what one person does.
    /// Off in tests, which need things to happen at once.
    var trafficShaping = true
    /// Unlocked, and the relay hasn't answered yet (over Tor, when it's on). The chats are open meanwhile, with
    /// a bar saying so; anything sent waits in the outbox.
    private(set) var connecting = false
    /// The main relay couldn't be reached on the last checks: a strip at the top says so until it can be again.
    private(set) var relayUnreachable = false
    private(set) var retryingRelay = false
    private var relayFailures = 0
    private var lastRelayContact = Date()
    /// For the Network page: when the relay last answered, and when mail last arrived. Memory only.
    private(set) var lastRelayReached: Date?
    private(set) var lastMailReceived: Date?
    /// When Automatic last moved Tor between direct and Snowflake, and how many times since the relay last answered.
    private(set) var bridgeSwitchedAt: Date?
    private var autoSwitches = 0
    private var pathMonitor: NWPathMonitor?
    private var lastPath: String?
    private var unlockedAt = Date()
    /// The Pulshade Admin app's key, built into the app: collectibles and the reports mailbox count only if it signed
    /// them.
    static var adminKey: Data? = (Bundle.main.object(forInfoDictionaryKey: "PulshadeAdminKey") as? String)
        .flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    /// The relay's own key, built into the app: the pets it hatches and the collectibles people gift count if it signed them.
    static var petKey: Data? = (Bundle.main.object(forInfoDictionaryKey: "PulshadePetKey") as? String)
        .flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var openAfterUnlock: Conversation.ID?
    /// Reopens the main window if it was closed. Set by the window itself.
    var openMainWindow: (() -> Void)?

    /// Conversation → (fingerprint → when they last typed). Memory only.
    private(set) var typing: [Conversation.ID: [String: Date]] = [:]
    /// Receipts waiting for their moment. Memory only.
    private var pendingReceipts: [ReceiptBatch] = []
    private struct ReceiptBatch {
        var fingerprint: String
        var persona: UUID?
        var ids: [UUID]
        var read = false
        var due: Date
    }
    private var lastTypingSent: [Conversation.ID: Date] = [:]
    /// Contact (fingerprint and persona) → when their last "I'm here" reached the relay. Memory only.
    private(set) var online: [String: Date] = [:]
    /// When each contact is next sent "I'm here". Memory only.
    @ObservationIgnored private var presenceDue: [String: Date] = [:]
    private static let presenceLife: TimeInterval = 100

    /// Tests have no front app and no waiting around.
    @ObservationIgnored var presenceAlwaysActive = false
    private func jitter(_ range: ClosedRange<Double>) -> TimeInterval { trafficShaping ? .random(in: range) : 0 }

    private func presenceKey(_ fingerprint: String, _ persona: UUID?) -> String {
        fingerprint + (persona?.uuidString ?? "")
    }

    let vault: Vault
    private var syncTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// The sealed backup upload waiting its turn, and how long it waits (seconds, picked at random each time so the
    /// relay can't line an upload up with an edit). Tests shorten the wait.
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    @ObservationIgnored static var backupWait: ClosedRange<Int> = 90...600
    private var activityMonitor: Any?
    private var lastActivity = Date()
    private var profileTask: Task<Void, Never>?

    /// The colour theme isn't secret, so it's mirrored outside the vault to tint the lock screen.
    var theme: Theme {
        Theme.named(phase == .unlocked ? data.theme : UserDefaults.standard.string(forKey: "pulshade.theme") ?? "")
    }

    init(vault: Vault = .standard, watchSystem: Bool = true) {
        self.vault = vault
        burnStore = BurnOrderStore(file: vault.directory.deletingLastPathComponent().appendingPathComponent(vault.directory.lastPathComponent + "-burn-order.sealed"),
                                   service: "app.pulshade.burn-order." + vault.directory.lastPathComponent)
        phase = vault.exists ? .locked : .welcome
        Ink.source = { [weak self] in self?.theme ?? .dark }
        guard watchSystem else { return }
        resumeBurnCleanup()
        #if os(iOS)
        CallRinger.shared.model = self
        #endif
        // Tor takes a moment to connect: start it now, in the background, so it's ready by the first request.
        let onionOnly = URL(string: AppData.defaultRelay).map(Tor.isOnion) == true && AppData.directRelay == nil
        // With no account here, nothing connects until its owner has chosen between Tor and a direct connection.
        let awaitingChoice = !vault.exists && Tor.needsChoice
        if (Tor.enabled && !awaitingChoice) || onionOnly {
            DispatchQueue.global(qos: .utility).async { Tor.start() }
        }
        #if os(macOS)
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]) {
            [weak self] event in
            self?.lastActivity = Date()
            return event
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lock() }
            }
        }
        // While locked, announcements still come, as a notification: they're public, so no vault is opened.
        Task { [weak self] in
            while true {
                let locked = self.map { $0.phase != .unlocked } ?? false
                let reached = locked ? await AnnouncementWatch.check() : true
                try? await Task.sleep(for: .seconds(reached ? 60 : 15))
                if self == nil { return }
            }
        }
        #endif
    }

    // MARK: Phone lifecycle

    private var backgroundedAt: Date?
    /// When the app last came back to the front. Tor's own connections die while it's suspended, and new
    /// ones take up to half a minute on a phone, so failures for a while after are reconnecting, not the relay.
    private var resumedAt: Date?

    /// iPhone: going to the background starts the auto-lock clock (the app can't tick while suspended).
    /// While locked, opens the main lane's way to the relay, so unlocking doesn't then wait for Tor to reach the
    /// onion service. The check says nothing about the account, and it's the lane that account polls on anyway.
    func warmUp() {
        guard phase == .locked, !warming, let url = URL(string: AppData.defaultRelay), Tor.uses(url) else { return }
        warming = true
        Task { [weak self] in
            _ = await Self.reach(RelayClient(base: url, lane: "main"))
            self?.warming = false
        }
    }
    private var warming = false

    /// One health check that doesn't wait on a bad circuit. A new circuit into an onion service usually answers in
    /// a few seconds, but often enough it's one that carries nothing and only times out. So past a few seconds,
    /// a second check races it on a fresh circuit of the same lane, and the first answer counts.
    nonisolated static func reach(_ client: RelayClient, patience: Double = 5) async -> Bool {
        guard Tor.uses(client.base) else { return await client.health() }
        // A route into an onion service usually connects in seconds, but now and then one gets stuck for good, and
        // through a bridge or on a slow network that's common. So the first attempt keeps going (it may yet get
        // there) while fresh routes join it: one after 5 seconds on a lane that has worked before; on one that
        // hasn't, where everything is slower, two, further apart. Whichever answers first wins.
        let joins: [Double] = client.isEstablished ? [patience] : [20, 50]
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await client.health() }
            for delay in joins {
                group.addTask {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return false }
                    client.freshCircuit()
                    return await client.health()
                }
            }
            for await reached in group where reached {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    func didEnterBackground() {
        backgroundedAt = Date()
        if phase == .unlocked, data.security.onlineStatus { sendPresence(false) }
        presenceDue = [:]
        save()
        refreshDisguises()
        #if os(iOS)
        AnnouncementWatch.schedule()
        tendStoryUpload()
        // Requests left open would only time out while the app is suspended, and look like the relay failing on
        // the way back. Anything unsent waits in the outbox. Not while a story is going out with iOS's leave to
        // carry on (see `BackgroundUpload`): then the app keeps running, and its connections with it.
        if !BackgroundUpload.isWanted { RelayClient.closeAll() }
        #endif
    }

    #if os(iOS)
    /// A call push woke Pulshade. If it is unlocked, it reconnects and fetches at once, so the caller's name reaches the
    /// call screen while it is still ringing.
    func callPushArrived() {
        if phase == .unlocked { reconnect() } else if phase == .locked { warmUp() }
    }
    #endif

    func willEnterForeground() {
        defer { backgroundedAt = nil }
        resetPresenceSchedule()
        #if os(iOS)
        reconnect()
        #endif
        if phase == .locked { warmUp() }
        refreshPush()
        #if os(iOS)
        // The wake-up banner has done its job once Pulshade is open.
        Task { await Notifier.shared.clearWakeBanners() }
        #endif
        guard phase == .unlocked, let since = backgroundedAt else { return }
        let minutes = data.security.autoLockMinutes
        if minutes > 0, Date().timeIntervalSince(since) > Double(minutes) * 60 { lock() } else { lastActivity = Date() }
        markOpenConversationRead()
    }

    /// A message that came in while the app was behind counts as unread, even in the chat left open. Coming back
    /// to the front is when that chat is seen, so its count (and the red mark on the tab) goes now.
    func markOpenConversationRead() {
        guard phase == .unlocked, appActive, let open = openConversation else { return }
        markRead(open)
    }

    /// After a spell in the background, where iOS shuts Tor's port and lets connections die: Tor listens again,
    /// the dead connections go, and every lane checks in at once. Until then a failure is the background's
    /// fault, not the relay's, so the offline strip waits.
    private func reconnect() {
        relayFailures = 0
        lastRelayContact = Date()
        resumedAt = Date()
        Task.detached(priority: .userInitiated) {
            Tor.wake()
            await MainActor.run {
                RelayClient.closeAll()
                if self.phase == .unlocked { Task { await self.syncOnce() } }
                // Anything announced while it was away, now rather than at the next minute.
                self.nextAnnouncementCheck = Date()
            }
        }
    }

    /// Pull down on the chats: what coming back from the background does (Tor woken, stale connections dropped, every
    /// lane checked at once), and the call waits for it, up to a few seconds, so the spinner has something to show.
    func refresh() async {
        guard phase == .unlocked else { return }
        relayFailures = 0
        lastRelayContact = Date()
        resumedAt = Date()
        nextAnnouncementCheck = Date()
        // The work carries on by itself if it's slow (Tor can take a while); the spinner never waits past six seconds
        // for it. (A task group would: it waits for every child, whichever finished first.)
        var finished = false
        Task {
            await Task.detached(priority: .userInitiated) { Tor.wake() }.value
            RelayClient.closeAll()
            await syncOnce()
            finished = true
        }
        let deadline = Date().addingTimeInterval(6)
        while !finished, Date() < deadline { try? await Task.sleep(for: .milliseconds(150)) }
        Haptics.tick()
    }

    /// Any touch counts as activity on iPhone.
    func noteActivity() { lastActivity = Date() }

    // MARK: Identity lifecycle

    /// What was chosen before sign-up (Tor or a direct connection) is what this device's account uses, whatever
    /// another device or a backup said.
    private func adoptConnectionChoice(fresh: Bool = false) {
        let on = Tor.enabled
        if fresh {
            data.security.tor = on
            data.security.torSince = on ? Date() : nil
            data.security.torFromStart = on
        } else if data.security.tor != on {
            data.security.tor = on
            data.security.torSince = on ? Date() : nil
            data.security.torFromStart = false
        }
    }

    func create(identity: Identity, profile: Profile, passcode: String) async throws {
        let vault = vault
        try await Task.detached { try vault.create(identity, passcode: passcode) }.value
        self.identity = identity
        slot = 0
        data = AppData()
        data.bornAt = Date()
        data.profile = profile
        adoptConnectionChoice(fresh: true)
        didUnlock()
    }

    /// Opens the account on this device from its recovery code. With the backup a log out left behind,
    /// it carries on exactly where it stopped; without one, it starts empty.
    func restore(seed: Data, passcode: String, from backup: AppData? = nil) async throws {
        let identity = try Identity(seed: seed)
        let vault = vault
        let stored = backup == nil ? try storedData(identity) : AppData()
        try await Task.detached { try vault.create(identity, passcode: passcode) }.value
        self.identity = identity
        slot = 0
        if var backup {
            // The passcodes behind these were on the old device only.
            backup.decoySeed = nil
            backup.panicSeed = nil
            backup.linkOffers = []
            backup.relay = data.relay
            data = backup
        } else {
            data = stored
        }
        // Recovering is a choice made now, so an order from before it isn't for this account.
        if data.bornAt == nil { data.bornAt = Date() }
        adoptConnectionChoice()
        didUnlock()
        // The keys for each chat in a backup are as they were when it was saved, and chat went on after that: they are
        // behind the ones every contact holds, so neither side could read the other's messages, and nothing said so.
        // So a recovered account opens a fresh session with each of them now, which they accept, and messages go both
        // ways again. What was sent to the old keys while the phone was gone can't be read.
        if backup != nil { startFreshSessions() }
        // Recovered from the sealed backup, with no chats: anyone still holding their side of one is told to clear
        // it, in case the device this came from was wiped (Detach) before it could say so. Contacts stay.
        if backup != nil, !hasOtherDevices { clearChatsForContacts() }
        // It's on this device now. It stays on the relay and is saved over as things change, unless backups are off.
        if backup != nil, !data.security.keepBackup { Task { try? await deleteBackup(of: identity) } }
    }

    /// Whether new keys are being set up with this contact and aren't ready yet: nothing can be sent to them until their
    /// app answers, which it does when it's running. For the chat to say so, instead of showing a clock and nothing else.
    func keysPending(with fingerprint: String) -> Bool {
        guard let c = contact(fingerprint, in: activePersona), !c.awaitingAcceptance, !c.devices.isEmpty else { return false }
        let ready = c.devices.contains { $0.session?.canSend == true }
        return !ready && c.devices.contains { $0.handshake != nil || $0.session != nil }
    }

    /// Opens fresh sessions with every contact, on request (Settings > Chats), for messages that stopped getting through.
    func renewChatKeys() {
        guard phase == .unlocked else { return }
        startFreshSessions()
        save()
    }

    /// Starts a new session with a device whose messages can't be opened, at most every couple of minutes.
    @ObservationIgnored private var lastMend: [String: Date] = [:]

    private func mendSession(contact i: Int, device d: Int) {
        guard !data.contacts[i].awaitingAcceptance, data.contacts[i].devices[d].handshake == nil else { return }
        let key = sessionKey(contact: i, device: d)
        if let last = lastMend[key], Date().timeIntervalSince(last) < 120 { return }
        lastMend[key] = Date()
        startHandshake(contact: i, device: d)
    }

    /// Drops the saved keys of every chat and opens new ones, with each device of each contact. Their messages are
    /// held until the new session is ready, as always.
    private func startFreshSessions() {
        for i in data.contacts.indices where !data.contacts[i].awaitingAcceptance {
            for d in data.contacts[i].devices.indices {
                // The old keys are kept in memory only, to read what was sent to them while the phone was gone.
                if let old = data.contacts[i].devices[d].session { recoveredSessions[sessionKey(contact: i, device: d)] = old }
                data.contacts[i].devices[d].session = nil
                data.contacts[i].devices[d].handshake = nil
                data.contacts[i].devices[d].awaitingHello = nil
                data.contacts[i].devices[d].acceptedHello = nil
                startHandshake(contact: i, device: d)
            }
        }
    }

    /// Keys from before an account was recovered, by contact and device. Held in memory only, and dropped at lock.
    @ObservationIgnored private var recoveredSessions: [String: Ratchet] = [:]

    private func sessionKey(contact i: Int, device d: Int) -> String {
        "\(data.contacts[i].persona?.uuidString ?? "main")|\(data.contacts[i].fingerprint)|\(data.contacts[i].devices[d].id.hex)"
    }

    func unlock(passcode: String) async -> Bool {
        // Each wrong guess makes the next one wait longer.
        if failedAttempts > 2 {
            try? await Task.sleep(for: .seconds(min(30, 1 << min(failedAttempts - 2, 5))))
        }
        dataUnreadable = false
        do {
            let vault = vault
            let opened = try await Task.detached { try vault.unlock(passcode: passcode) }.value
            switch opened {
            case let .identity(identity, slot):
                let stored = try storedData(identity)
                self.identity = identity
                self.slot = slot
                data = stored
            case let .panic(landing, slot):
                // Looks like a normal unlock. Behind it, everything real is gone, and the landing identity
                // becomes the main one, so nothing about it looks like a disguise afterwards.
                do {
                    try await Task.detached { try vault.panic(keeping: landing, slot: slot, passcode: passcode) }.value
                } catch {
                    // The real account couldn't be destroyed. Don't report success or open the landing account
                    // over whatever is still on disk; refusing the unlock is the safe outcome.
                    return false
                }
                Notifier.shared.clearAll()
                // The real account's mailboxes can't be named any more: take this phone's token off the relay instead.
                withdrawPush()
                self.identity = landing
                self.slot = 0
                data = try storedData(landing)
            }
            failedAttempts = 0
            didUnlock()
            if data.pendingBackupForget != nil { Task { await forgetPendingBackup() } }
            // A decoy is an empty account: the real one's wake-ups stop until the real one is unlocked again.
            if !isPrimary { withdrawPush() }
            await bindToDevice(passcode: passcode)
            return true
        } catch {
            // A right passcode that found unreadable data isn't a wrong guess.
            if !dataUnreadable { failedAttempts += 1 }
            return false
        }
    }

    /// The account's data, or a fresh start when it has none yet. A file that's there but won't open stops
    /// the unlock: opening an empty account instead would save over it at the first change.
    private func storedData(_ identity: Identity) throws -> AppData {
        do {
            return try vault.load(with: identity) ?? AppData()
        } catch {
            dataUnreadable = true
            throw error
        }
    }

    /// Lock files from before the Secure Enclave binding get it on the next unlock. Only without a decoy or
    /// panic passcode: their slots can't be rewritten without passcodes this device doesn't know.
    private func bindToDevice(passcode: String) async {
        guard isPrimary, data.decoySeed == nil, data.panicSeed == nil, let identity, !vault.isDeviceBound else { return }
        let vault = vault
        try? await Task.detached { try vault.create(identity, passcode: passcode) }.value
    }

    #if DEBUG
    /// Puts the model straight into an unlocked state with given data. Demo mode only.
    func loadPreview(identity: Identity, data: AppData) {
        self.identity = identity
        self.data = data
        // PULSHADE_DEMO_CONNECTING=1 shows the connecting strip, PULSHADE_DEMO_OFFLINE=1 the server-offline one.
        connecting = ProcessInfo.processInfo.environment["PULSHADE_DEMO_CONNECTING"] != nil
        relayUnreachable = ProcessInfo.processInfo.environment["PULSHADE_DEMO_OFFLINE"] != nil
        phase = .unlocked
    }
    #endif

    private func didUnlock() {
        unlockedAt = Date()
        lastRelayContact = Date()
        moveToOnionRelay()
        purgeExpired()
        data.seenEnvelopes = data.seenEnvelopes.filter { $0.value > Date().addingTimeInterval(-Self.replayWindow) }
        // Unused contact invites die with the relay's 7-day retention.
        data.invites.removeAll { $0.channel == nil && !$0.isPublic && $0.createdAt < Date().addingTimeInterval(-7 * 24 * 3600) }
        data.invites.removeAll { ($0.retiresAt ?? .distantFuture) < Date() }
        UserDefaults.standard.set(data.theme, forKey: "pulshade.theme")
        // Written straight away: a new account must have its file before anything else happens.
        save()
        settleSaves()
        mirrorSecurity()
        lastActivity = Date()
        Notifier.shared.onOpen = { [weak self] id in self?.open(id) }
        if data.security.notifications { Notifier.shared.start() }
        if let pending = openAfterUnlock {
            openAfterUnlock = nil
            requestedConversation = pending
        }
        connecting = true
        withAnimation(.smooth(duration: 0.6)) { phase = .unlocked }
        scheduleBackup()
        // Ask straight away, and again until it answers, so the wait is only as long as Tor needs.
        Task { [weak self] in
            while let self, self.connecting, self.phase == .unlocked, let client = self.client(nil) {
                self.noteRelay(reached: await Self.reach(client))
                if self.connecting { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        startSync()
        startTicking()
        // The relay may have restarted while the app was closed: a request that hasn't been answered goes again.
        restartsHandled = relayRestartTotal()
        resendPendingRequests()
        nextAnnouncementCheck = Date().addingTimeInterval(trafficShaping ? 5 : 0)
        nextCollectibleCheck = Date().addingTimeInterval(trafficShaping ? 40 : 3600)
        announcementsVersion = nil
        announceProfiles()
        relistStrandedProfiles()
        // Once only: asking the relay about every persona's handles at each unlock would tie them together.
        if !data.handlesTidied {
            data.handlesTidied = true
            Task { await releaseLeftoverHandles() }
        }
        // Once more now that profiles can carry links and wallets, so contacts who had no way to ask get them.
        if data.profileShared < 3 {
            data.profileShared = 3
            for persona in [nil] + data.personas.map(\.id)
            where !(profile(for: persona).bio ?? "").isEmpty || profile(for: persona).handle != nil
                || !ProfileLink.cleaned(profile(for: persona).links).isEmpty {
                for c in contacts(of: persona) { enqueue(profilePayload(persona, for: c.fingerprint), to: c) }
            }
        }
    }

    /// When this build's relay is an onion service, a local relay address is that same relay reached the old way
    /// (the Mac's own or Wi-Fi address), which Tor can't reach: switch to the onion address and Tor. The mailboxes
    /// don't change, only the way there. Contacts or messages that named a local address by hand use the default.
    private func moveToOnionRelay() {
        let onion = AppData.defaultRelay
        guard let url = URL(string: onion), Tor.isOnion(url) else { return }
        func local(_ relay: String?) -> Bool {
            relay.flatMap { URL(string: $0)?.host() }.map { Invite.isLocal($0.lowercased()) } ?? false
        }
        if local(data.relay) {
            data.relay = onion
            if !data.security.tor { data.security.torSince = Date() }
            data.security.tor = true
        }
        if data.security.torSince == nil { data.security.torSince = Date() }
        for i in data.contacts.indices where local(data.contacts[i].relay) { data.contacts[i].relay = nil }
        for i in data.invites.indices where local(data.invites[i].relay) { data.invites[i].relay = nil }
        for i in data.outbox.indices where local(data.outbox[i].relay) { data.outbox[i].relay = nil }
        if local(data.inviteRelay) { data.inviteRelay = nil }
    }

    func lock() {
        guard phase == .unlocked else { return }
        dismissBanner()
        connecting = false
        relayUnreachable = false
        relayFailures = 0
        if call != nil { hangUp() }
        syncTask?.cancel()
        tickTask?.cancel()
        typing = [:]
        lastTypingSent = [:]
        online = [:]
        presenceDue = [:]
        data.outbox.removeAll { $0.ephemeral == true }
        pendingReceipts = []
        Notifier.shared.clearAll()
        // Its mailbox keys must not stay in memory for whoever unlocks next. The relay keeps the registration, so a
        // locked Pulshade is still woken for new mail.
        pushTold = nil
        save()
        refreshDisguises()
        vault.rotate()
        forgetRoutes()
        slot = 0
        identity = nil
        data = AppData()
        // Who each story is still to go to is saved with it, and picked up again on unlocking.
        storyBacklog = [:]
        storyUploadTotal = [:]
        forgetSession()
        link = .offline
        openConversation = nil
        Platform.setBadge(0)
        withAnimation(.smooth(duration: 0.5)) { phase = .locked }
        tendStoryUpload()
    }

    /// Wipes this device. `leavingNoTrace` (Burn) also deletes the Keychain items, the folder, Tor's saved state
    /// and every setting Pulshade keeps outside the vault, bridges and the Tor switch included. Detach keeps
    /// those, since the device still needs them to reach the relay.
    func destroyEverything(leavingNoTrace: Bool = false) {
        if call != nil { hangUp() }
        Notifier.shared.clearAll()
        // This account's mailboxes stop waking the phone. Done first, while the account's keys are still known.
        let hadPush = pushTold != nil || data.security.pushWake
        if hadPush, case let keys = currentLanes()[Lane(relay: nil, name: "main")] ?? [], !keys.isEmpty {
            let named = Array(keys)
            Task {
                for start in stride(from: 0, to: named.count, by: 256) {
                    try? await client(nil, lane: "push")?.unregisterPush(keys: Array(named[start..<min(start + 256, named.count)]))
                }
            }
        }
        if hadPush { withdrawPush() }
        eraseAllFilesOnRelayNow()
        syncTask?.cancel()
        tickTask?.cancel()
        // Nothing more goes to the relay from here. The backup already there is what a recovery code brings back.
        backupTask?.cancel()
        backupTask = nil
        discardSaves()
        vault.destroy(leavingNoTrace: leavingNoTrace)
        failedAttempts = 0
        AnnouncementWatch.forget()
        // The few display settings kept outside the vault, so the lock screen can look right.
        for key in ["pulshade.theme", "pulshade.menuBar", "pulshade.blockCapture", "pulshade.blur"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if leavingNoTrace {
            Tor.forget()
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("pulshade.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        Platform.setBadge(0)
        forgetRoutes()
        identity = nil
        data = AppData()
        forgetSession()
        withAnimation(.smooth(duration: 0.6)) { phase = .welcome }
    }

    /// What's held in memory only, for the account that was open: persona keys and its eggs. Whoever unlocks
    /// next, a decoy included, must not find them.
    private func forgetSession() {
        recoveredSessions = [:]
        identityCache = [:]
        DecodedImages.forget()
        eggs = []
        // Per-contact state derived from the account that was open, including text typed into requests.
        removedStories = [:]
        clipActivity = [:]
        clipAsks = [:]
        clipResent = [:]
        lastMend = [:]
        requestNotes = [:]
        movedOffIntro = []
        mailboxBackoff = [:]
    }

    /// Detach: wipes this device at once, with no questions and no waiting on the network. Everything is overwritten
    /// and deleted (the vault, Keychain items, Tor's state, settings, caches and temporary files) and Pulshade
    /// starts over as if it had just been installed. Nothing is sent: other devices keep the account, and the relay
    /// is not told.
    func wipeNow() {
        destroyEverything(leavingNoTrace: true)
        Vault.scrubLeftovers()
    }

    /// True while Detach is telling contacts to clear their chats, just before the wipe: the screen is covered.
    var detaching = false

    /// How long Detach waits to tell contacts before it wipes regardless.
    @ObservationIgnored var detachPatience: Duration = .seconds(4)

    /// Detach from the Burn tab. When this is the account's only device and the relay is in reach, everyone with a
    /// chat with you is first told to clear it (they keep you as a contact), so no conversation outlives your side
    /// of it; then the device is wiped as `wipeNow` does. It waits a few seconds at most: with no connection, or if
    /// the messages can't go in time, it wipes anyway, and the chats are cleared when the account is next recovered
    /// (see `restore`). With other devices on the account nothing is sent: they still have the chats.
    func detachNow() async {
        guard !detaching else { return }
        guard identity != nil, phase == .unlocked, !hasOtherDevices, link == .online else { wipeNow(); return }
        detaching = true
        clearChatsForContacts()
        var done = false
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            func finish() { if !done { done = true; waiting.resume() } }
            Task { @MainActor in try? await self.sendEverything(); finish() }
            Task { @MainActor in try? await Task.sleep(for: self.detachPatience); finish() }
        }
        wipeNow()
        detaching = false
    }

    /// Takes everything of yours back from your contacts, except the contact itself: their one-to-one chat with you,
    /// every story you have up (by name, and as a sweep for any this device no longer remembers), and what you said in
    /// groups and channels. They keep you as a contact. Detach does this before it wipes, and recovering an account does
    /// it again in case the device was wiped before it could.
    private func clearChatsForContacts() {
        for c in data.contacts where !c.isSelf && !c.hidden && !c.awaitingAcceptance {
            enqueue(.chatDeleted(conversation: nil), to: c)
            enqueue(.storiesCleared, to: c)
        }
        for story in data.stories where story.author == "me" && story.isLive {
            dropUnsent(story: story.id)
            for c in audience(of: story) { enqueue(.storyRemoved(id: story.id), to: c) }
        }
        // What you wrote in groups and channels is theirs to keep only if you stay; you've gone.
        for convo in data.conversations where convo.kind == .group || convo.kind == .channel {
            let mine = convo.messages.filter(\.isMine).map(\.id)
            guard !mine.isEmpty else { continue }
            for member in audience(convo) where !member.isSelf {
                for start in stride(from: 0, to: mine.count, by: 200) {
                    enqueue(.unsend(ids: Array(mine[start..<min(start + 200, mine.count)])), to: member)
                }
            }
        }
    }

    /// Whoever opens Pulshade next starts on new Tor circuits and new connections, so the relay can't tie two
    /// accounts on this device together by the circuit their requests share.
    private func forgetRoutes() {
        Tor.newRoutes()
        RelayClient.closeAll(finishing: !cutOffOnLock)
    }

    /// The newest state waiting to be written, with the account it belongs to.
    @ObservationIgnored private var unsaved: (data: AppData, identity: Identity)?
    /// Bumped for every write that starts and whenever waiting writes are dropped, so a failed write can tell
    /// whether anything newer has been queued before it puts its own copy back.
    @ObservationIgnored private var saveGeneration = 0
    @ObservationIgnored private var saveTimer: Task<Void, Never>?
    /// Writes happen here, one at a time and in order, so the main thread never waits on encrypting the whole vault.
    private static let saveQueue = DispatchQueue(label: "pulshade.save", qos: .userInitiated)

    /// Saves are gathered for a moment and written off the main thread: sending a few messages in a row would
    /// otherwise encrypt and rewrite the whole vault several times each, and freeze the chat while it did.
    func save() {
        guard let identity else { return }
        if let pending = unsaved, pending.identity.storageKey.bytes != identity.storageKey.bytes { flushSave() }
        unsaved = (data, identity)
        if saveTimer == nil {
            saveTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.flushSave()
            }
        }
        updateBadge()
        scheduleBackup()
        AnnouncementWatch.mirror(.init(notifications: data.security.notifications, content: data.security.notificationContent,
                                       sound: data.security.notificationSound,
                                       muted: conversation(Conversation.announcementsID)?.muted ?? false))
    }

    /// Starts writing whatever is waiting, in the background.
    private func flushSave() {
        saveTimer?.cancel()
        saveTimer = nil
        guard let (data, identity) = unsaved else { return }
        unsaved = nil
        saveGeneration += 1
        let generation = saveGeneration
        let vault = vault
        Self.saveQueue.async { [weak self] in
            do {
                try vault.save(data, with: identity)
            } catch {
                // A failed write keeps the waiting copy so a later save retries it, rather than losing every
                // change since the last successful write — unless something newer is already queued, or the
                // vault was wiped in the meantime.
                Task { @MainActor in
                    guard let self, self.unsaved == nil, self.saveGeneration == generation else { return }
                    self.unsaved = (data, identity)
                }
            }
        }
    }

    /// Writes whatever is waiting and returns once it's on disk: before locking, quitting, going to the background,
    /// and before anything else touches the vault's files.
    func settleSaves() {
        flushSave()
        Self.saveQueue.sync {}
    }

    /// Drops a waiting write and lets any under way finish, so nothing lands after the vault's files are wiped.
    private func discardSaves() {
        saveTimer?.cancel()
        saveTimer = nil
        unsaved = nil
        saveGeneration += 1
        Self.saveQueue.sync {}
    }

    private func updateBadge() {
        Platform.setBadge(unreadTotal)
    }

    var unreadTotal: Int {
        data.conversations.filter { !$0.muted }.reduce(0) { $0 + $1.unread }
    }

    /// Unread messages in the chats the list shows: the active persona's, the burners' and the announcements. The
    /// Chats tab counts only these, so its red mark can always be cleared by opening what is in front of you; other
    /// personas' unread shows on the account picture instead.
    var unreadInView: Int {
        data.conversations
            .filter { !$0.muted && ($0.persona == activePersona || isBurner($0.persona) || $0.isAnnouncements) }
            .reduce(0) { $0 + $1.unread }
    }

    /// Chats with something new, newest first, for the menu bar.
    var unreadConversations: [Conversation] {
        allConversationsSorted.filter { $0.unread > 0 && !$0.muted }
    }

    /// Brings Pulshade forward on a chat. If it's locked, the chat opens right after unlocking.
    func open(_ id: Conversation.ID) {
        #if os(macOS)
        if let window = NSApp?.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp?.activate(ignoringOtherApps: true)
        #endif
        if phase == .unlocked { requestedConversation = id } else { openAfterUnlock = id }
    }

    /// Whether Pulshade is the front app. False when there's no app at all, as in tests.
    private var appActive: Bool {
        #if os(macOS)
        NSApp?.isActive ?? false
        #else
        Bundle.main.bundleURL.pathExtension == "app" && Platform.isActive
        #endif
    }

    private func notify(_ message: Message, at i: Int) {
        let convo = data.conversations[i]
        // Being @-mentioned gets through a muted chat: that's someone asking for you in particular.
        guard data.security.notifications, !convo.muted || message.mentionsMe else { return }
        if appActive && openConversation == convo.id { return }
        let content = Notifier.content(for: message, in: convo, sender: displayName(message.sender),
                                       style: data.security.notificationContent)
        #if os(iOS)
        // On the phone, a message that lands while Pulshade is open gets Pulshade's own banner at the top of the
        // screen, not a system one (which would be a second banner after the wake-up one from the lock screen).
        if appActive {
            // On the chats tab the list already shows the new message, so no banner.
            if onChatsTab { return }
            // The banner only shows while Pulshade is open, so once it's unlocked it says who wrote and what,
            // whatever the lock-screen setting is. Locked, it follows that setting.
            let style: NotificationContent = phase == .unlocked ? .full : data.security.notificationContent
            let content = Notifier.content(for: message, in: convo, sender: displayName(message.sender), style: style)
            let named = style != .hidden
            showBanner(InAppBanner(conversation: convo.id, title: content.title, body: content.body,
                                   avatar: named ? (convo.kind == .direct ? contact(message.sender, in: convo.persona)?.avatar : convo.avatar) : nil,
                                   seed: convo.kind == .direct ? message.sender : convo.id.uuidString, showsAvatar: named))
            return
        }
        #endif
        Notifier.shared.post(content, conversation: convo.id, sound: data.security.notificationSound, tone: data.security.messageTone)
    }

    /// The banner showing at the top of the screen, if any. See `InAppBanner`.
    var inAppBanner: InAppBanner?
    /// Whether the phone's tab bar is on Chats, where a banner isn't needed.
    @ObservationIgnored var onChatsTab = true
    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    /// Shows a banner for a few seconds; a newer one takes its place.
    func showBanner(_ banner: InAppBanner) {
        bannerTask?.cancel()
        inAppBanner = banner
        Haptics.tick()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            self?.inAppBanner = nil
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        inAppBanner = nil
    }

    // MARK: Contacts & invites

    /// A fresh one-time invite for the active persona. Channel invites belong to the channel's persona
    /// and are reused, so the link you share stays the same.
    func makeInviteCode(channel: UUID? = nil, persona: UUID?? = nil) -> String {
        let owner = channel.flatMap { conversation($0) }.map(\.persona) ?? persona ?? activePersona
        guard let me = me(owner) else { return "" }
        let receiveKey: Data
        if let channel, let existing = data.invites.first(where: { $0.channel == channel }) {
            receiveKey = existing.receiveKey
        } else {
            receiveKey = Mailbox.make().receiveKey
            data.invites.append(OpenInvite(receiveKey: receiveKey, channel: channel, persona: owner, relay: Invite.allowedRelay(data.inviteRelay)))
            save()
        }
        let relay = data.invites.first { $0.receiveKey == receiveKey }?.relay
        return Invite(kind: channel == nil ? .contact : .channel, signingKey: me.card.signing,
                      agreementKey: me.card.agreement, sendID: Mailbox.sendID(for: receiveKey), relay: relay).code
    }

    /// Accepts someone's invite: opens a mailbox for them and says hello.
    @discardableResult
    func addContact(code: String, nickname: String, persona: UUID?? = nil) -> Contact? {
        let owner = persona ?? activePersona
        guard identity != nil, let invite = Invite(code: code), !myFingerprints.contains(invite.fingerprint) else { return nil }
        let known = contact(invite.fingerprint, in: owner)
        if let known, !known.hidden, invite.kind == .contact { return known }

        let mailbox = Mailbox.make()
        var contact = known ?? Contact(fingerprint: invite.fingerprint, signingKey: invite.signingKey,
                                       agreementKey: invite.agreementKey, sendID: invite.sendID)
        contact.persona = owner
        contact.relay = invite.relay
        contact.nickname = nickname
        contact.receiveKey = mailbox.receiveKey
        // Following a channel doesn't make its owner one of your contacts.
        contact.hidden = invite.kind == .channel ? (known?.hidden ?? true) : false
        guard let (handshake, request) = try? Handshake.start() else { return nil }
        // The invite names one of their devices' mailboxes; its id arrives with their answer.
        var link = DeviceLink(sendID: invite.sendID)
        link.handshake = handshake
        contact.devices = [link]
        guard let meCard = card(sendID: mailbox.sendID, persona: owner) else { return nil }
        upsert(contact)
        syncContact(contact.fingerprint, contact.persona)
        seal(.hello(meCard, request), to: contact.fingerprint, persona: owner)
        shareStories(with: contact)
        save()
        return contact
    }

    func rename(_ fingerprint: String, to nickname: String) {
        guard let i = data.contacts.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        data.contacts[i].nickname = nickname
        refreshDirectTitle(fingerprint)
        syncContact(fingerprint, data.contacts[i].persona)
        save()
    }

    /// For showing someone: their record under the active persona if there is one, otherwise any.
    func contact(_ fingerprint: String) -> Contact? {
        contact(fingerprint, in: activePersona) ?? data.contacts.first { $0.fingerprint == fingerprint }
    }

    /// For talking to someone: the record that belongs to one particular persona of yours.
    func contact(_ fingerprint: String, in persona: UUID?) -> Contact? {
        contactIndex(fingerprint, persona).map { data.contacts[$0] }
    }

    private func contactIndex(_ fingerprint: String, _ persona: UUID?) -> Int? {
        data.contacts.firstIndex { $0.fingerprint == fingerprint && $0.persona == persona }
    }

    var visibleContacts: [Contact] {
        data.contacts.filter { !$0.hidden && !$0.awaitingAcceptance && $0.persona == activePersona }
    }

    /// Someone the active persona knows by `profile`'s handle who isn't the account listing it now: the name
    /// changed hands, and a lookup shouldn't pass the new owner off as them.
    func earlierOwner(of profile: DirectoryProfile) -> Contact? {
        data.contacts.first { $0.persona == activePersona && !$0.isSelf && $0.handle == profile.handle && $0.signingKey != profile.signingKey }
    }

    private func contacts(of persona: UUID?) -> [Contact] {
        data.contacts.filter { !$0.hidden && $0.persona == persona }
    }

    func displayName(_ fingerprint: String) -> String {
        if fingerprint == Announcement.handle { return "PULSHADE" }
        return fingerprint == "me" ? activeProfile.displayName : contact(fingerprint)?.displayName ?? "Unknown"
    }

    private func upsert(_ contact: Contact) {
        if let i = contactIndex(contact.fingerprint, contact.persona) {
            data.contacts[i] = contact
        } else {
            withAnimation(.snappy) { data.contacts.append(contact) }
        }
    }

    private func card(sendID: Data, persona: UUID?) -> PeerCard? {
        // A persona whose stored seed is damaged has no keys; don't force-unwrap and crash the app.
        guard let keys = me(persona) else { return nil }
        let profile = profile(for: persona)
        return PeerCard(name: profile.name, avatar: profile.avatar, color: profile.color,
                        signingKey: keys.card.signing, agreementKey: keys.card.agreement, sendID: sendID, device: deviceID(for: persona))
    }

    /// The notes of a profile that one contact is sent: the ones for everyone and the ones chosen for them, checked
    /// again, none if there are none. With no contact (the public listing), only the notes for everyone.
    static func sharedNotes(_ profile: Profile, for fingerprint: String? = nil) -> [ProfileNote]? {
        ProfileNote.notes(profile.notes, sentTo: fingerprint)
    }

    /// The links and wallets of a profile that are worth sending: checked again, none if there are none.
    static func sharedLinks(_ profile: Profile) -> [ProfileLink]? {
        let links = ProfileLink.cleaned(profile.links)
        return links.isEmpty ? nil : links
    }

    /// What a profile shows contacts of its collectibles: the genuine ones, never the backup code or anything else.
    static func sharedCollectibles(_ profile: Profile) -> [Collectible]? {
        // Each was checked against this account's key when it was fetched, and the receiver checks again.
        let mine = (profile.collectibles ?? []).prefix(40)
        return mine.isEmpty ? nil : Array(mine)
    }

    private func profilePayload(_ persona: UUID?, for contact: String) -> Payload {
        let profile = profile(for: persona)
        return .profile(name: profile.name, avatar: profile.avatar, color: profile.color, banner: profile.banner,
                        bio: profile.bio.flatMap { $0.isEmpty ? nil : $0 }, handle: profile.handle, badge: profile.badge,
                        links: Self.sharedLinks(profile), collectibles: Self.sharedCollectibles(profile),
                        notes: Self.sharedNotes(profile, for: contact))
    }

    /// Someone's signature colour: what they chose, or one picked from their fingerprint.
    func signature(_ fingerprint: String) -> Color {
        let chosen = fingerprint == "me" ? activeProfile.color : contact(fingerprint)?.color
        let seed = fingerprint == "me" ? self.fingerprint : fingerprint
        return Signature.color(chosen, seed: seed)
    }

    func setVerified(_ fingerprint: String, _ verified: Bool) {
        guard let i = data.contacts.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        withAnimation(.snappy) { data.contacts[i].verified = verified }
        syncContact(fingerprint, data.contacts[i].persona)
        save()
    }

    private func refreshDirectTitle(_ fingerprint: String) {
        for i in data.conversations.indices where data.conversations[i].kind == .direct
            && data.conversations[i].members == [fingerprint] {
            data.conversations[i].title = displayName(fingerprint)
        }
    }

    // MARK: Conversations

    func startConversation(kind: ConversationKind, title: String, members: [String], avatar: Data? = nil,
                           persona: UUID?? = nil) -> Conversation {
        let owner = persona ?? activePersona
        if kind == .direct, let member = members.first, let existing = directConversation(with: member, persona: owner) {
            return existing
        }
        let name = kind == .direct ? (contact(members.first ?? "", in: owner)?.displayName ?? displayName(members.first ?? "")) : title
        var convo = Conversation(kind: kind, title: name, avatar: avatar, members: members)
        convo.persona = owner
        withAnimation(.snappy) { data.conversations.insert(convo, at: 0) }
        if kind == .group || kind == .channel, let i = index(of: convo.id) {
            data.conversations[i].version = 1
            sendInfo(data.conversations[i], to: members)
        }
        if kind != .direct { syncConversation(convo.id) }
        save()
        return convo
    }

    private func directConversation(with fingerprint: String, persona: UUID?) -> Conversation? {
        data.conversations.first { $0.kind == .direct && $0.members == [fingerprint] && $0.persona == persona }
    }

    func send(_ text: String, image: Data? = nil, voice: VoiceNote? = nil, replyTo: Message? = nil,
              quote: ReplyRef? = nil, preview: LinkPreview? = nil, collectible: Collectible? = nil, note: NoteCard? = nil,
              mentioning picks: [(fingerprint: String, name: String)] = [], in id: Conversation.ID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil || voice != nil || collectible != nil || note != nil, let i = index(of: id) else { return }
        let convo = data.conversations[i]
        guard canPost(in: convo) else { return }

        let now = Date()
        // Replying to a photo carries a small copy of it, so the quote shows what was answered.
        let reply = replyTo.map { ReplyRef(id: $0.id, author: $0.sender, snippet: Self.snippet(of: $0), picture: Self.quotePicture($0.image)) } ?? quote
        var message = Message(sender: "me", text: trimmed, image: image, voice: voice, date: now,
                              expiresAt: convo.disappearAfter.map { now.addingTimeInterval($0) }, reply: reply,
                              preview: preview)
        message.collectible = collectible
        message.note = note
        // Only people of this group that are your contacts can be mentioned.
        let allowed = Set(mentionable(in: convo).map(\.fingerprint))
        message.mentions = Mention.locate(picks.filter { allowed.contains($0.fingerprint) }, in: trimmed)
        withAnimation(.snappy(duration: 0.4)) { data.conversations[i].messages.append(message) }

        let wire = WireMessage(id: message.id, conversation: sharedID(convo), kind: convo.kind == .broadcast ? .direct : convo.kind,
                               text: trimmed, image: image, voice: voice, date: RelayClock.relay(now), expiresIn: convo.disappearAfter,
                               reply: reply.map { ReplyRef(id: $0.id, author: $0.author == "me" ? (me(convo.persona)?.fingerprint ?? "") : $0.author,
                                                           snippet: $0.snippet, picture: $0.picture) },
                               preview: preview, collectible: collectible, note: note,
                               mentions: message.mentions.isEmpty ? nil : message.mentions)
        let recipients = audience(convo)
        for member in recipients { enqueue(.message(wire), to: member, message: message.id) }
        sync(.sent(ref(convo), wire))
        if recipients.isEmpty { setStatus(.sent, for: [message.id]) }
        lastTypingSent[id] = nil
        save()
    }

    // MARK: Video clips kept on the relay

    /// Whether every device of a contact reads files kept on the relay.
    private func readsAttachments(_ contact: Contact) -> Bool {
        relayClipsEnabled && !contact.devices.isEmpty && contact.devices.allSatisfy { $0.readsAttachments == true }
    }

    /// Whether clips go to the relay and people get a pointer. Only tests switch it off, to follow the piece-by-piece
    /// way that apps from before files still use.
    @ObservationIgnored var relayClipsEnabled = true

    /// Gets a clip to one contact: as a pointer to the one sealed copy on the relay if their app reads those, otherwise in
    /// pieces as before. The clip is uploaded once, however many people are waiting for it. `known` is the copy already
    /// there, if any.
    private func deliverClip(_ clip: Data, id: UUID, to contact: Contact, known: Attachment?, lifetime: TimeInterval = 7 * 86_400,
                             only wanted: [Int]? = nil) {
        guard readsAttachments(contact) else { sendClip(clip, id: id, to: contact, only: wanted); return }
        if let known, known.expires > RelayClock.now { enqueue(.clipBlob(id: id, clip: known), to: contact); return }
        clipWaiting[id, default: []].append(contact)
        guard clipUploads[id] == nil else { return }
        guard let relay = client(nil, lane: "blob"),
              let prepared = try? BlobTransfer.prepare(data: clip, kind: .video, lifetime: min(max(lifetime, 3600) + 3600, 7 * 86_400)) else {
            clipUploaded(id, clip: clip, nil)
            return
        }
        clipUploads[id] = Task { [weak self] in
            var done: Attachment?
            do {
                try await BlobTransfer.upload(prepared, to: relay) { _ in }
                done = prepared.attachment
            } catch {}
            await MainActor.run { self?.clipUploaded(id, clip: clip, done) }
        }
    }

    /// The upload finished (or failed): whoever was waiting gets a pointer, or, if it failed, the clip in pieces.
    private func clipUploaded(_ id: UUID, clip: Data, _ a: Attachment?) {
        clipUploads[id] = nil
        let waiting = clipWaiting.removeValue(forKey: id) ?? []
        guard let a else {
            for contact in waiting { sendClip(clip, id: id, to: contact) }
            return
        }
        // Kept with the story or message, so it can be erased when that goes.
        if let s = data.stories.firstIndex(where: { $0.id == id && $0.author == "me" }) {
            // A story's clip stays until its timer runs out: everyone is sent the same pointer.
            data.stories[s].clipBlob = a
            for contact in waiting { enqueue(.clipBlob(id: id, clip: a), to: contact) }
            save()
            return
        }
        for c in data.conversations.indices {
            if let m = data.conversations[c].messages.lastIndex(where: { $0.id == id && $0.isMine }) {
                // An earlier upload of this video (sent again because someone asked) is erased now, so no copy is left
                // that a later delete wouldn't know about.
                if let old = data.conversations[c].messages[m].attachment, old.id != a.id,
                   !data.blobWipes.contains(where: { $0.id == old.id }) {
                    data.blobWipes.append(BlobWipe(id: old.id, secret: old.secret, expires: old.expires))
                    runBlobWipes()
                }
                data.conversations[c].messages[m].attachment = a
            }
        }
        save()
        // A chat video is erased from the relay once everyone it went to has it: each person gets a pointer with their own token.
        Task { [weak self] in
            guard let self else { return }
            let tokens = await self.registerReaders(for: waiting, of: a)
            await MainActor.run {
                for contact in waiting {
                    var pointer = a
                    pointer.token = tokens?[Self.personKey(contact)]
                    self.enqueue(.clipBlob(id: id, clip: pointer), to: contact)
                }
            }
        }
    }

    private static func personKey(_ contact: Contact) -> String { "\(contact.fingerprint)|\(contact.persona?.uuidString ?? "")" }

    /// Makes one token for each person a file goes to and tells the relay who is to collect it, so it can erase the file
    /// when they all have. Nil if the relay couldn't be told: the file then goes without tokens and stays until it is
    /// deleted or expires.
    private func registerReaders(for contacts: [Contact], of a: Attachment) async -> [String: Data]? {
        var tokens: [String: Data] = [:]
        var readers: [(hash: Data, uses: Int)] = []
        for contact in contacts where tokens[Self.personKey(contact)] == nil {
            let token = Data.random(32)
            tokens[Self.personKey(contact)] = token
            readers.append((Data(SHA256.hash(data: token)), max(1, contact.devices.count)))
        }
        guard !readers.isEmpty, readers.count <= 1024, let relay = client(nil, lane: "blob") else { return nil }
        do { try await relay.blobReaders(a.id, secret: a.secret, readers: readers) } catch { return nil }
        return tokens
    }

    /// Tells the relay this phone has the whole file, so it can be erased once everyone has it. Tried a few times.
    private func spendToken(of a: Attachment) {
        guard let token = a.token, let relay = client(nil, lane: "blob") else { return }
        Task.detached {
            for delay in [0.0, 5, 30, 120] {
                try? await Task.sleep(for: .seconds(delay))
                if (try? await relay.blobDone(a.id, token: token)) != nil { return }
            }
        }
    }

    /// A pointer to a clip arrived: fetch it from the relay into memory and put it where its pieces would have gone.
    private func receiveClipBlob(_ id: UUID, _ a: Attachment, from sender: Contact, persona: UUID?) {
        let fp = sender.fingerprint
        let key = ClipKey(id, persona)
        guard removedStories["\(fp)|\(id)"] == nil, !clipFetching.contains(key) else { return }
        if data.stories.contains(where: { $0.id == id && $0.author == fp && $0.persona == persona && $0.isReady }) { return }
        if let at = videoMessage(id), data.conversations[at.convo].persona == persona,
           data.conversations[at.convo].messages[at.message].video?.isEmpty == false { return }
        guard let relay = client(nil, lane: "blob") else { return }
        clipFetching.insert(key)
        clipActivity[key] = Date()
        Task { [weak self] in
            let clip = try? await BlobTransfer.download(a, from: relay) { _ in }
            await MainActor.run {
                guard let self else { return }
                self.clipFetching.remove(key)
                if let clip, self.finishClip(id, clip, author: fp, persona: persona) { self.spendToken(of: a) }
            }
        }
    }

    /// Puts a clip that came from the relay where its message or story is waiting for it.
    @discardableResult
    private func finishClip(_ id: UUID, _ clip: Data, author: String, persona: UUID?) -> Bool {
        let key = ClipKey(id, persona)
        if let at = videoMessage(id) {
            let message = data.conversations[at.convo].messages[at.message]
            let theirs = message.sender == author
            let mine = message.isMine && contact(author, in: persona)?.isSelf == true
            guard message.video?.isEmpty == true, theirs || mine, data.conversations[at.convo].persona == persona,
                  clip.count <= ChatVideo.maxBytes + 500_000 else { return false }
            data.clipParts[key.stored] = nil
            clipActivity[key] = nil
            clipAsks[key] = nil
            withAnimation(.snappy) { data.conversations[at.convo].messages[at.message].video = clip }
            return true
        }
        guard let i = data.stories.firstIndex(where: { $0.id == id && $0.author == author && $0.persona == persona }),
              case let .video(have, caption) = data.stories[i].style, have.isEmpty else { return false }
        data.clipParts[key.stored] = nil
        clipActivity[key] = nil
        clipAsks[key] = nil
        withAnimation(.snappy) { data.stories[i].style = .video(clip, caption: caption) }
        acknowledgeStory(id, author: author, persona: persona)
        save()
        return true
    }

    /// Tells the relay to erase the clips of these stories of yours.
    private func eraseClips(of stories: [Story]) {
        for story in stories where story.author == "me" {
            guard let a = story.clipBlob, !data.blobWipes.contains(where: { $0.id == a.id }) else { continue }
            data.blobWipes.append(BlobWipe(id: a.id, secret: a.secret, expires: a.expires))
        }
        runBlobWipes()
    }

    // MARK: Files kept on the relay

    /// Sends a file: sealed on this phone piece by piece, uploaded once to the relay, and named in an ordinary
    /// end-to-end encrypted message that holds the key. The message goes out once the upload is complete. See
    /// docs/blob-store.md.
    func sendFile(_ url: URL, replyTo: Message? = nil, in id: Conversation.ID) {
        guard let i = index(of: id), canPost(in: data.conversations[i]) else { return }
        Task { [weak self] in
            do {
                let prepared = try await Task.detached { try BlobTransfer.prepare(url) }.value
                self?.beginSending(prepared, replyTo: replyTo, in: id)
            } catch let error as BlobError {
                self?.fileProblem = error.words
            } catch {
                self?.fileProblem = BlobError.unreadable.words
            }
        }
    }

    private func beginSending(_ prepared: BlobTransfer.Prepared, replyTo: Message?, in id: Conversation.ID) {
        guard let i = index(of: id) else { return }
        let convo = data.conversations[i]
        let now = Date()
        let a = prepared.attachment
        let reply = replyTo.map { ReplyRef(id: $0.id, author: $0.sender, snippet: Self.snippet(of: $0), picture: Self.quotePicture($0.image)) }
        var message = Message(sender: "me", text: "", date: now, expiresAt: convo.disappearAfter.map { now.addingTimeInterval($0) }, reply: reply)
        message.attachment = a
        withAnimation(.snappy(duration: 0.4)) { data.conversations[i].messages.append(message) }
        fileProgress[message.id] = 0
        fileFailed[message.id] = nil
        save()
        startUpload(prepared, message: message.id, in: id)
    }

    /// (Re)starts an upload for a message of yours whose file is still where it was.
    private func startUpload(_ prepared: BlobTransfer.Prepared, message messageID: UUID, in id: Conversation.ID) {
        guard let client = client(nil, lane: "blob") else { fileFailed[messageID] = "No connection."; return }
        fileFailed[messageID] = nil
        fileTasks[messageID]?.cancel()
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.fileProgress[messageID] = value }
        }
        fileTasks[messageID] = Task { [weak self] in
            do {
                try await BlobTransfer.upload(prepared, to: client, progress: report)
                await MainActor.run { self?.finishUpload(messageID, in: id) }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self?.fileProgress[messageID] = nil
                    self?.fileFailed[messageID] = (error as? BlobError)?.words ?? "Couldn't upload the file. Check your connection and try again."
                }
            }
            await MainActor.run { self?.fileTasks[messageID] = nil }
        }
    }

    /// The file is on the relay: now the message that names it goes to everyone in the chat. Apps that can't read files
    /// show the words in `text` instead.
    private func finishUpload(_ messageID: UUID, in id: Conversation.ID) {
        fileProgress[messageID] = nil
        guard let i = index(of: id), let m = data.conversations[i].messages.firstIndex(where: { $0.id == messageID }),
              let a = data.conversations[i].messages[m].attachment else { return }
        let convo = data.conversations[i]
        let message = convo.messages[m]
        let fallback = "📎 \(a.shownName) (a file: update Pulshade to open it)"
        let wire = WireMessage(id: message.id, conversation: sharedID(convo), kind: convo.kind == .broadcast ? .direct : convo.kind,
                               text: fallback, image: nil, voice: nil, date: RelayClock.relay(message.date), expiresIn: convo.disappearAfter,
                               reply: message.reply.map { ReplyRef(id: $0.id, author: $0.author == "me" ? (me(convo.persona)?.fingerprint ?? "") : $0.author,
                                                                   snippet: $0.snippet, picture: $0.picture) },
                               preview: nil, attachment: a)
        let recipients = audience(convo)
        if recipients.isEmpty { setStatus(.sent, for: [message.id]); sync(.sent(ref(convo), wire)); save(); return }
        // The file is erased from the relay once everyone it goes to has it: each person (and your own other devices)
        // gets a pointer with a token of their own.
        let own = selfIndex.map { data.contacts[$0] }.flatMap { $0.devices.isEmpty ? nil : $0 }
        let ref = ref(convo)
        Task { [weak self] in
            guard let self else { return }
            let tokens = await self.registerReaders(for: recipients + (own.map { [$0] } ?? []), of: a)
            await MainActor.run {
                for member in recipients {
                    var mine = wire
                    mine.attachment?.token = tokens?[Self.personKey(member)]
                    self.enqueue(.message(mine), to: member, message: message.id)
                }
                var forMyDevices = wire
                forMyDevices.attachment?.token = own.flatMap { tokens?[Self.personKey($0)] }
                self.sync(.sent(ref, forMyDevices))
                self.save()
            }
        }
    }

    /// Fetches a file into memory and opens it there. Nothing is written to disk. The caller shows it, or saves it to
    /// Files if the person asks.
    func openFile(of message: Message) async throws -> Data {
        guard let a = message.attachment else { throw BlobError.gone }
        guard let client = client(nil, lane: "blob") else { throw BlobError.gone }
        let id = message.id
        fileProgress[id] = 0
        fileFailed[id] = nil
        defer { fileProgress[id] = nil }
        do {
            let file = try await BlobTransfer.download(a, from: client) { value in
                Task { @MainActor [weak self] in if self?.fileProgress[id] != nil { self?.fileProgress[id] = value } }
            }
            // The whole file is here: the relay is told, and erases it once everyone it went to has it. This phone doesn't
            // keep it, so from now on the card says so.
            if a.token != nil {
                spendToken(of: a)
                for c in data.conversations.indices {
                    if let m = data.conversations[c].messages.firstIndex(where: { $0.id == id && !$0.isMine }) {
                        data.conversations[c].messages[m].attachment?.collected = true
                        data.conversations[c].messages[m].attachment?.token = nil
                    }
                }
                save()
            }
            return file
        } catch {
            fileFailed[id] = (error as? BlobError)?.words ?? "Couldn't fetch the file. Check your connection and try again."
            throw error
        }
    }

    /// The chat a message is in.
    func conversationID(of message: UUID) -> Conversation.ID? {
        data.conversations.first { $0.messages.contains { $0.id == message } }?.id
    }

    /// Stops a file that is on its way up, and tells the relay to forget what has gone.
    func cancelFile(_ messageID: UUID, in id: Conversation.ID) {
        fileTasks[messageID]?.cancel()
        fileTasks[messageID] = nil
        fileProgress[messageID] = nil
        fileFailed[messageID] = nil
        guard let i = index(of: id) else { return }
        eraseFiles(in: data.conversations[i].messages.filter { $0.id == messageID })
        withAnimation(.easeOut(duration: 0.3)) { data.conversations[i].messages.removeAll { $0.id == messageID } }
        save()
    }

    /// Tries a failed upload again, if the phone still has the file's picker access; otherwise the message is removed.
    func retryFile(_ messageID: UUID, in id: Conversation.ID) { cancelFile(messageID, in: id) }

    /// Tells the relay to erase the files of yours that these messages name. If it can't be reached the erase is remembered
    /// and tried again; a file the relay still holds expires on its own after at most a week.
    private func eraseFiles(in messages: [Message]) {
        let mine = messages.filter(\.isMine).compactMap(\.attachment)
        guard !mine.isEmpty else { return }
        for a in mine where !data.blobWipes.contains(where: { $0.id == a.id }) {
            data.blobWipes.append(BlobWipe(id: a.id, secret: a.secret, expires: a.expires))
        }
        runBlobWipes()
    }

    /// A wipe (Detach, the panic passcode, Burn) tells the relay to erase every file and clip of yours it holds, in the same
    /// moment and without waiting for an answer, so the wipe stays instant: the requests are on their way before the
    /// secrets that allow them are gone. Only when this is the account's one device: with others, they still show those
    /// files, so nothing is erased. Offline, the files expire within 7 days.
    private func eraseAllFilesOnRelayNow() {
        guard isPrimary, !hasOtherDevices else { return }
        var wipes = data.blobWipes
        for convo in data.conversations {
            for m in convo.messages where m.isMine { if let a = m.attachment { wipes.append(BlobWipe(id: a.id, secret: a.secret, expires: a.expires)) } }
        }
        for story in data.stories where story.author == "me" {
            if let a = story.clipBlob { wipes.append(BlobWipe(id: a.id, secret: a.secret, expires: a.expires)) }
        }
        guard !wipes.isEmpty, let relay = client(nil, lane: "blob") else { return }
        Task.detached { for wipe in wipes { _ = try? await relay.blobDelete(wipe.id, secret: wipe.secret) } }
    }

    /// Works through the files waiting to be erased on the relay.
    @discardableResult
    func runBlobWipes() -> Task<Void, Never> {
        let now = RelayClock.now
        data.blobWipes.removeAll { $0.expires < now.addingTimeInterval(-86_400) }
        guard !data.blobWipes.isEmpty, let client = client(nil, lane: "blob") else { return Task {} }
        let list = data.blobWipes
        return Task { [weak self] in
            for wipe in list {
                if (try? await client.blobDelete(wipe.id, secret: wipe.secret)) != nil {
                    await MainActor.run {
                        self?.data.blobWipes.removeAll { $0.id == wipe.id }
                        self?.save()
                    }
                }
            }
        }
    }

    /// Sends a video (already made ready by `ChatVideo.prepare`). The message goes first, with a still from the clip,
    /// and the clip follows in pieces under the message's id, the way a video story's does. An app from before chat
    /// videos shows the still as a photo.
    func sendVideo(_ clip: Data, poster: Data?, seconds: Double, caption: String = "", replyTo: Message? = nil, in id: Conversation.ID) {
        guard !clip.isEmpty, clip.count <= ChatVideo.maxBytes + 500_000, let i = index(of: id) else { return }
        let convo = data.conversations[i]
        guard canPost(in: convo) else { return }
        let now = Date()
        let words = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = replyTo.map { ReplyRef(id: $0.id, author: $0.sender, snippet: Self.snippet(of: $0), picture: Self.quotePicture($0.image)) }
        var message = Message(sender: "me", text: words, image: poster, date: now,
                              expiresAt: convo.disappearAfter.map { now.addingTimeInterval($0) }, reply: reply)
        message.video = clip
        message.clipSeconds = seconds
        withAnimation(.snappy(duration: 0.4)) { data.conversations[i].messages.append(message) }
        let wire = WireMessage(id: message.id, conversation: sharedID(convo), kind: convo.kind == .broadcast ? .direct : convo.kind,
                               text: words, image: poster, voice: nil, date: RelayClock.relay(now), expiresIn: convo.disappearAfter,
                               reply: reply.map { ReplyRef(id: $0.id, author: $0.author == "me" ? (me(convo.persona)?.fingerprint ?? "") : $0.author,
                                                           snippet: $0.snippet, picture: $0.picture) },
                               preview: nil, clip: ClipInfo(seconds: seconds))
        let recipients = audience(convo)
        for member in recipients {
            enqueue(.message(wire), to: member, message: message.id)
            deliverClip(clip, id: message.id, to: member, known: nil)
        }
        // Your other devices get the message and the clip too.
        sync(.sent(ref(convo), wire))
        if !applyingSync, let me = selfIndex, !data.contacts[me].devices.isEmpty { deliverClip(clip, id: message.id, to: data.contacts[me], known: nil) }
        if recipients.isEmpty { setStatus(.sent, for: [message.id]) }
        lastTypingSent[id] = nil
        save()
    }

    /// A clip in pieces, to one contact, cut the way their app takes them. `only` sends just those pieces.
    private func sendClip(_ clip: Data, id: UUID, to contact: Contact, only wanted: [Int]? = nil) {
        let pieces = StoryClipPieces.split(clip, framed: readsFrames(contact))
        let fits = wanted.map { $0.allSatisfy(pieces.indices.contains) } ?? true
        let indices = fits ? wanted.map { Set($0).sorted() } ?? Array(pieces.indices) : Array(pieces.indices)
        for i in indices { enqueue(.storyPart(id: id, index: i, of: pieces.count, bytes: pieces[i]), to: contact) }
    }

    /// The message a clip belongs to, if it's a chat video: where it is, and who sent it.
    private func videoMessage(_ id: UUID) -> (convo: Int, message: Int)? {
        for c in data.conversations.indices {
            if let m = data.conversations[c].messages.lastIndex(where: { $0.id == id && $0.isVideo }) { return (c, m) }
        }
        return nil
    }

    /// Answers a friend's story in your chat with them: a like, or words. It arrives as an ordinary message
    /// quoting the story, so the relay sees nothing new and older builds show it too.
    func answerStory(_ story: Story, like: Bool = false, text: String = "") async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard story.author != "me", like || !words.isEmpty, contact(story.author, in: story.persona) != nil else { return }
        let picture = await Self.storyPicture(story)
        let convo = startConversation(kind: .direct, title: "", members: [story.author], persona: .some(story.persona))
        let quote = ReplyRef(id: story.id, author: story.author, snippet: Self.snippet(of: story), picture: picture)
        send(like ? "❤️ Liked your story" : words, quote: quote, in: convo.id)
        if like, let i = data.stories.firstIndex(where: { $0.id == story.id && $0.persona == story.persona }) {
            data.stories[i].liked = true
            save()
        }
    }

    /// A photo shrunk for the quote above a reply to it. Nil when there's no photo, or it can't be made small enough.
    static func quotePicture(_ photo: Data?) -> Data? {
        guard let photo, let small = thumbnail(photo, side: 160), small.count <= ReplyRef.maxPicture,
              PlatformImage(data: small) != nil else { return nil }
        return small
    }

    /// A small picture of a story for the quote above a like or a reply: the photo shrunk, a video's first
    /// frame, or the text card drawn small.
    static func storyPicture(_ story: Story) async -> Data? {
        let side: CGFloat = 200
        let image: PlatformImage?
        switch story.style {
        case let .image(data, _):
            image = PlatformImage(data: data)
        case let .video(data, _):
            guard !data.isEmpty else { return nil }
            image = await StoryVideo.poster(of: MemoryClip(data)).map { PlatformImage.from(cgImage: $0) }
        case .text:
            let renderer = ImageRenderer(content: StoryFace(story: story, compact: true).frame(width: 90, height: 160))
            renderer.scale = 2
            image = renderer.cgImage.map { PlatformImage.from(cgImage: $0) }
        }
        guard let image, let jpeg = cleanJPEG(image, maxSide: side), jpeg.count <= ReplyRef.maxPicture else { return nil }
        return jpeg
    }

    /// The soft bell for something you've just sent, when sounds are on and no call is using the audio.
    @ObservationIgnored var sendSounds = true

    func playSendSound() {
        guard sendSounds, data.security.notificationSound, call == nil else { return }
        SendSound.play()
    }

    /// A short line describing a story, for the quote above a like or a reply.
    static func snippet(of story: Story) -> String {
        let words: String
        switch story.style {
        case let .text(text, _): words = text
        case let .image(_, caption), let .video(_, caption): words = caption
        }
        let kind: String
        switch story.style {
        case .text: kind = "Story"
        case .image: kind = "Photo story"
        case .video: kind = "Video story"
        }
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind : "\(kind): \(trimmed.prefix(100))"
    }

    /// A short line describing a message, for quotes and previews.
    static func snippet(of message: Message) -> String {
        if !message.text.isEmpty { return String(message.text.prefix(120)) }
        if message.voice != nil { return "Voice message" }
        if let a = message.attachment, a.kind == .file { return "📎 " + a.shownName }
        if message.isVideo { return "Video" }
        if message.image != nil { return "Photo" }
        return "Message"
    }

    /// Groups and channels share an id across devices; direct chats and broadcasts don't.
    private func sharedID(_ convo: Conversation) -> UUID? {
        convo.kind == .group || convo.kind == .channel ? convo.id : nil
    }

    /// Who receives conversation-level signals (reactions, unsends, timers). Broadcasts fan out privately.
    private func audience(_ convo: Conversation) -> [Contact] {
        convo.members.compactMap { contact($0, in: convo.persona) }
    }

    /// Who you can @-mention in a chat: members of a group that are your own contacts, by name. Someone in the
    /// group you haven't added isn't offered, so a group can't be used to reach people you don't know.
    func mentionable(in convo: Conversation) -> [Contact] {
        guard convo.kind == .group else { return [] }
        return convo.members.compactMap { contact($0, in: convo.persona) }
            .filter { !$0.hidden && !$0.awaitingAcceptance && !$0.isSelf }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: Unsend, reactions, typing, timers

    func unsend(_ messageID: UUID, in id: Conversation.ID) {
        guard let i = index(of: id) else { return }
        let convo = data.conversations[i]
        guard convo.messages.contains(where: { $0.id == messageID && $0.isMine }) else { return }
        eraseFiles(in: convo.messages.filter { $0.id == messageID })
        withAnimation(.easeOut(duration: 0.38)) { data.conversations[i].messages.removeAll { $0.id == messageID } }
        for member in audience(convo) { enqueue(.unsend(ids: [messageID]), to: member) }
        sync(.unsend(ids: [messageID]))
        save()
    }

    /// Tapping the same emoji again removes it.
    func react(_ emoji: String, to messageID: UUID, in id: Conversation.ID) {
        guard let i = index(of: id), let m = data.conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let next: String? = data.conversations[i].messages[m].reactions["me"] == emoji ? nil : emoji
        withAnimation(.snappy) { data.conversations[i].messages[m].reactions["me"] = next }
        let convo = data.conversations[i]
        if convo.kind != .broadcast {
            for member in audience(convo) { enqueue(.reaction(message: messageID, emoji: next), to: member) }
        }
        sync(.reaction(message: messageID, emoji: next))
        save()
    }

    /// Typing signals are throttled to one every few seconds and never stored.
    func noteTyping(in id: Conversation.ID) {
        guard data.security.typingIndicators, let convo = conversation(id), convo.kind == .direct || convo.kind == .group else { return }
        if let last = lastTypingSent[id], Date().timeIntervalSince(last) < 3 { return }
        lastTypingSent[id] = Date()
        for member in audience(convo) { enqueue(.typing(conversation: sharedID(convo)), to: member) }
    }

    /// Whether a contact has Pulshade open right now. Always false with the setting off, since you see theirs only
    /// if you show yours.
    func isOnline(_ fingerprint: String) -> Bool {
        guard data.security.onlineStatus, !data.blocked.contains(fingerprint),
              let seen = online[presenceKey(fingerprint, activePersona)] else { return false }
        return seen > Date().addingTimeInterval(-Self.presenceLife)
    }

    /// Online status is for the people you've accepted: not blocked, not known only from a group, not your own
    /// devices, and never for or from a burner.
    private func sharesPresence(with c: Contact) -> Bool {
        !c.hidden && !c.awaitingAcceptance && !c.isSelf && !data.blocked.contains(c.fingerprint) && burner(c.persona) == nil
    }

    /// Queues something for a contact on the devices that can send it now, so nothing waits on a handshake or
    /// piles up behind one. False if no device could.
    @discardableResult
    private func sendIfReady(_ payload: Payload, contact i: Int) -> Bool {
        var sent = false
        for d in data.contacts[i].devices.indices where data.contacts[i].devices[d].session?.canSend == true {
            data.contacts[i].devices[d].pending.append(PendingPayload(payload: payload, message: nil))
            sent = true
        }
        if sent { sendPending(contact: i) }
        return sent
    }

    /// Tells the active persona's contacts who asked for it that you've arrived or gone.
    private func sendPresence(_ here: Bool) {
        for i in data.contacts.indices where data.contacts[i].persona == activePersona
            && data.contacts[i].wantsMyPresence == true && sharesPresence(with: data.contacts[i]) {
            sendIfReady(.presence(online: here), contact: i)
        }
    }

    /// Spreads the next "I'm here" over the next few seconds, a contact at a time, so they don't leave in a burst.
    private func resetPresenceSchedule() {
        presenceDue = [:]
        for c in data.contacts where c.persona == activePersona {
            presenceDue[presenceKey(c.fingerprint, c.persona)] = Date().addingTimeInterval(jitter(0...10))
        }
    }

    /// Once a second: tells contacts whether you want their status, and sends each one "I'm here" on its own
    /// clock. Someone who's here gets it every minute or so; someone who isn't, only now and then, so a contact
    /// who stays away doesn't fill their mailbox on the relay. A contact arriving is answered at once instead.
    private func tickPresence() {
        let want = data.security.onlineStatus
        for i in data.contacts.indices where data.contacts[i].persona == activePersona && sharesPresence(with: data.contacts[i]) {
            let told = data.contacts[i].toldPresence ?? false
            if told != want, sendIfReady(.wantsPresence(want), contact: i) { data.contacts[i].toldPresence = want }
        }
        guard want, appActive || presenceAlwaysActive else { return }
        let now = Date()
        for i in data.contacts.indices where data.contacts[i].persona == activePersona
            && data.contacts[i].wantsMyPresence == true && sharesPresence(with: data.contacts[i]) {
            let key = presenceKey(data.contacts[i].fingerprint, data.contacts[i].persona)
            guard let due = presenceDue[key] else {
                presenceDue[key] = now.addingTimeInterval(jitter(0...10))
                continue
            }
            guard now >= due else { continue }
            let here = (online[key] ?? .distantPast) > now.addingTimeInterval(-Self.presenceLife)
            presenceDue[key] = now.addingTimeInterval(here ? jitter(45...75) : jitter(1500...2100))
            sendIfReady(.presence(online: true), contact: i)
        }
    }

    /// Who's typing in a conversation right now.
    func typers(in id: Conversation.ID) -> [String] {
        let cutoff = Date().addingTimeInterval(-5)
        return (typing[id] ?? [:]).filter { $0.value > cutoff }.map(\.key).sorted()
    }

    func setDisappearing(_ seconds: TimeInterval?, in id: Conversation.ID) {
        guard let i = index(of: id), data.conversations[i].disappearAfter != seconds else { return }
        applyTimer(seconds, at: i)
        let convo = data.conversations[i]
        if convo.kind == .direct || convo.kind == .group {
            for member in audience(convo) { enqueue(.disappearing(conversation: sharedID(convo), seconds: seconds), to: member) }
        }
        sync(.disappearing(ref(convo), seconds: seconds))
        save()
    }

    private func applyTimer(_ seconds: TimeInterval?, at i: Int) {
        data.conversations[i].disappearAfter = seconds
        let note = Message(sender: "system", text: "⏱ \(Disappear.short(seconds))", status: .delivered)
        withAnimation(.snappy) { data.conversations[i].messages.append(note) }
    }

    /// Removes anything whose timer ran out, on this device. Each device does the same for itself.
    private func purgeExpired() {
        let now = Date()
        var changed = false
        for i in data.conversations.indices where data.conversations[i].messages.contains(where: { ($0.expiresAt ?? .distantFuture) <= now }) {
            eraseFiles(in: data.conversations[i].messages.filter { ($0.expiresAt ?? .distantFuture) <= now })
            withAnimation(.smooth) { data.conversations[i].messages.removeAll { ($0.expiresAt ?? .distantFuture) <= now } }
            clampUnread(i)
            changed = true
        }
        // Stories past their time go from the vault too, not just from view, and so do old removal notes.
        if data.stories.contains(where: { !$0.isLive }) {
            for story in data.stories where !story.isLive && story.author == "me" { dropUnsent(story: story.id) }
            eraseClips(of: data.stories.filter { !$0.isLive })
            withAnimation(.smooth) { data.stories.removeAll { !$0.isLive } }
            changed = true
        }
        let stale = now.addingTimeInterval(-3 * 24 * 3600)
        if removedStories.values.contains(where: { $0 < stale }) {
            removedStories = removedStories.filter { $0.value >= stale }
            changed = true
        }
        if changed { save() }
    }

    /// One-to-one chats (and burners) in the current list, which "Clear all chats" removes.
    var clearableChats: [Conversation] { sortedConversations.filter { $0.kind == .direct } }

    /// Deletes every one-to-one chat in view, for both sides. Groups, channels and lists stay.
    func clearAllChats() {
        let ids = clearableChats.map(\.id)
        for id in ids { delete(id) }
    }

    func togglePin(_ id: Conversation.ID) {
        guard let i = index(of: id) else { return }
        withAnimation(.snappy) { data.conversations[i].pinned.toggle() }
        save()
    }

    func toggleMute(_ id: Conversation.ID) {
        guard let i = index(of: id) else { return }
        data.conversations[i].muted.toggle()
        save()
    }

    /// Deleting a chat deletes it for everyone in it. Followers deleting a channel just unfollow;
    /// broadcast lists are your own send list, so they only go here.
    func delete(_ id: Conversation.ID) {
        guard let convo = conversation(id) else { return }
        switch convo.kind {
        case .broadcast:
            break
        case .direct:
            for member in audience(convo) { enqueue(.chatDeleted(conversation: nil), to: member) }
        case .group, .channel:
            let signal: Payload = convo.amOwner ? .chatDeleted(conversation: convo.id) : .left(conversation: convo.id)
            for member in audience(convo) { enqueue(signal, to: member) }
        }
        sync(.deleted(ref(convo)))
        removeLocally(id)
        save()
    }

    private func removeLocally(_ id: Conversation.ID) {
        if let convo = conversation(id) { eraseFiles(in: convo.messages) }
        if openConversation == id { openConversation = nil }
        typing[id] = nil
        Notifier.shared.clear(id)
        withAnimation(.snappy) { data.conversations.removeAll { $0.id == id } }
    }

    func markRead(_ id: Conversation.ID) {
        Notifier.shared.clear(id)
        guard let i = index(of: id), data.conversations[i].unread > 0 else { return }
        let convo = data.conversations[i]
        if sendsReadReceipts(convo), let sender = contact(convo.members.first ?? "", in: convo.persona) {
            for message in convo.messages.filter({ !$0.isMine && !$0.isSystem }).suffix(convo.unread) { queueReceipt(message.id, to: sender, read: true) }
        }
        data.conversations[i].unread = 0
        sync(.read(ref(data.conversations[i])))
        save()
    }

    func conversation(_ id: Conversation.ID?) -> Conversation? {
        guard let id else { return nil }
        return data.conversations.first { $0.id == id }
    }

    /// The active persona's chats, plus every burner chat (they're short-lived, so always in view).
    var sortedConversations: [Conversation] {
        allConversationsSorted.filter { $0.persona == activePersona || isBurner($0.persona) || $0.isAnnouncements }
    }

    private var allConversationsSorted: [Conversation] {
        data.conversations.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.lastActivity > $1.lastActivity
        }
    }

    private func index(of id: Conversation.ID) -> Int? {
        data.conversations.firstIndex { $0.id == id }
    }

    private func setStatus(_ status: MessageStatus, for ids: [UUID]) {
        for c in data.conversations.indices {
            for m in data.conversations[c].messages.indices
                where data.conversations[c].messages[m].isMine && ids.contains(data.conversations[c].messages[m].id) {
                if status.rank > data.conversations[c].messages[m].status.rank {
                    data.conversations[c].messages[m].status = status
                }
            }
        }
    }

    // MARK: Stories

    private func choiceKey(_ persona: UUID?) -> String { persona?.uuidString ?? "main" }

    /// The audience and lifetime offered for the next story: whatever was chosen last.
    var storyChoice: StoryChoice { data.storyChoices[choiceKey(activePersona)] ?? StoryChoice() }

    /// The contacts one of your stories goes to.
    private func audience(of story: Story) -> [Contact] {
        contacts(of: story.persona).filter { !$0.awaitingAcceptance && story.shownTo.includes($0.fingerprint) }
    }

    private func storyPayload(_ story: Story) -> Payload {
        .story(id: story.id, style: story.style, date: RelayClock.relay(story.date), lasts: story.lifetime)
    }

    /// Whether every device of a contact reads framed messages, so a clip can go to them in fewer, fuller pieces.
    private func readsFrames(_ contact: Contact) -> Bool {
        !contact.devices.isEmpty && contact.devices.allSatisfy { $0.readsFrames == true }
    }

    /// Sends a story to one contact. A video goes as the story with an empty clip, then (for people who don't
    /// have the clip yet) the clip in pieces that each fit one relay message.
    private func sendStory(_ story: Story, to contact: Contact, withClip: Bool) {
        guard case let .video(clip, caption) = story.style else { enqueue(storyPayload(story), to: contact); return }
        enqueue(.story(id: story.id, style: .video(Data(), caption: caption), date: RelayClock.relay(story.date),
                       lasts: story.lifetime), to: contact)
        guard withClip else { return }
        if readsAttachments(contact) {
            deliverClip(clip, id: story.id, to: contact, known: story.clipBlob, lifetime: story.lifetime ?? StoryLifetime.day.rawValue)
            return
        }
        let pieces = StoryClipPieces.split(clip, framed: readsFrames(contact))
        for (i, bytes) in pieces.enumerated() {
            enqueue(.storyPart(id: story.id, index: i, of: pieces.count, bytes: bytes), to: contact)
        }
    }

    /// Sends a story again to someone whose copy stalled: the story itself (in case that was what went
    /// missing), then the pieces of its clip they asked for, or all of them.
    private func resendStory(_ story: Story, to contact: Contact, pieces wanted: [Int]?) {
        guard case let .video(clip, caption) = story.style, !clip.isEmpty else { enqueue(storyPayload(story), to: contact); return }
        enqueue(.story(id: story.id, style: .video(Data(), caption: caption), date: RelayClock.relay(story.date),
                       lasts: story.lifetime), to: contact)
        if readsAttachments(contact) {
            deliverClip(clip, id: story.id, to: contact, known: story.clipBlob, lifetime: story.lifetime ?? StoryLifetime.day.rawValue)
            return
        }
        // Cut the way this person's app takes them now. If that changed since they got some (they updated), the
        // pieces they asked for by number are from the old cut, so all of the new one goes.
        let pieces = StoryClipPieces.split(clip, framed: readsFrames(contact))
        let fits = wanted.map { $0.allSatisfy(pieces.indices.contains) } ?? true
        let indices = fits ? wanted.map { Set($0).sorted() } ?? Array(pieces.indices) : Array(pieces.indices)
        for i in indices {
            enqueue(.storyPart(id: story.id, index: i, of: pieces.count, bytes: pieces[i]), to: contact)
        }
    }

    /// Pieces saved by an older build carry no id and sit under the bare story id, where two personas' copies of one
    /// story collided. Each is filed under its own persona now, and any clip that is already whole is put together
    /// (its last piece came before there was a story to join it to, or went to the wrong copy).
    private func refileOldClipParts() {
        for (key, old) in data.clipParts where old.id == nil {
            var entry = old
            entry.id = key
            data.clipParts[key] = nil
            let home = ClipKey(key, entry.persona).stored
            if data.clipParts[home] == nil { data.clipParts[home] = entry }
        }
        for entry in data.clipParts.values where entry.isComplete {
            if let id = entry.id { assembleClip(id, persona: entry.persona) }
        }
    }

    /// A video that has stopped arriving part-way: with nothing new for a while, whoever posted it is asked for
    /// what's missing. A few times at most, further apart each time, while the story is still up.
    private func askForStalledClips() {
        let now = Date()
        // Keyed by story and persona: two of your personas can be sent the same story by one friend.
        var stalled = Set(data.clipParts.values.compactMap { p in p.id.map { ClipKey($0, p.persona) } })
        for story in data.stories where story.author != "me" && story.isLive && !story.isReady {
            stalled.insert(ClipKey(story.id, story.persona))
        }
        // Chat videos whose message has come but whose pieces haven't all.
        stalled.formUnion(clipActivity.keys)
        for key in stalled {
            let id = key.id
            let story = data.stories.first { $0.id == id && $0.persona == key.persona && $0.author != "me" }
            let parts = data.clipParts[key.stored]
            if story == nil, let at = videoMessage(id), data.conversations[at.convo].persona == key.persona {
                // A chat video: asked of whoever sent it, in that chat's persona, while it's still unfinished.
                let message = data.conversations[at.convo].messages[at.message]
                guard message.video?.isEmpty == true, !message.isMine else { clipActivity[key] = nil; continue }
                guard let last = clipActivity[key] else { clipActivity[key] = now; continue }
                let asked = clipAsks[key], tries = asked?.count ?? 0
                guard tries < Self.clipAskLimit, now.timeIntervalSince(last) >= clipQuiet,
                      now.timeIntervalSince(asked?.at ?? .distantPast) >= clipQuiet * Double(1 << tries),
                      let contact = contact(message.sender, in: data.conversations[at.convo].persona) else { continue }
                clipAsks[key] = (tries + 1, now)
                enqueue(.storyWant(id: id, parts: parts.map { p in (0..<p.of).filter { p.parts[$0] == nil } }), to: contact)
                continue
            }
            guard let author = story?.author ?? parts?.author, author != "me",
                  removedStories["\(author)|\(id)"] == nil else { continue }
            if story.map({ $0.isLive && !$0.isReady }) == false { continue }
            // Seen for the first time since launch: the wait starts now.
            guard let last = clipActivity[key] else { clipActivity[key] = now; continue }
            let asked = clipAsks[key]
            let tries = asked?.count ?? 0
            guard tries < Self.clipAskLimit, now.timeIntervalSince(last) >= clipQuiet,
                  now.timeIntervalSince(asked?.at ?? .distantPast) >= clipQuiet * Double(1 << tries),
                  let contact = contact(author, in: story?.persona ?? parts?.persona) else { continue }
            let missing = parts.map { p in (0..<p.of).filter { p.parts[$0] == nil } }
            clipAsks[key] = (tries + 1, now)
            enqueue(.storyWant(id: id, parts: missing), to: contact)
        }
    }

    /// How long a video has to go without a new piece before it's asked for again, and how many times it is.
    @ObservationIgnored var clipQuiet: TimeInterval = 90
    static let clipAskLimit = 4

    /// Joins a clip's pieces into its story once the story and every piece are here.
    /// How much of a video that's still arriving is here: pieces in, out of how many. Nil before the first lands.
    func clipProgress(of id: Story.ID, persona: UUID?) -> (have: Int, of: Int)? {
        data.clipParts[ClipKey(id, persona).stored].map { ($0.parts.count, $0.of) }
    }

    /// For a friend's video story that hasn't arrived: who it's from, and whether it has been asked for yet.
    func clipWait(of story: Story) -> (name: String, asked: Bool)? {
        guard story.author != "me", let from = contact(story.author, in: story.persona) else { return nil }
        return (from.displayName, clipAsks[ClipKey(story.id, story.persona)] != nil)
    }

    /// Asks the author for a video again now, instead of waiting for the next automatic ask. Not more than once
    /// every few seconds, and it doesn't use up the automatic asks.
    func askAgain(for story: Story) {
        let key = ClipKey(story.id, story.persona)
        guard story.author != "me", !story.isReady, let author = contact(story.author, in: story.persona),
              removedStories["\(story.author)|\(story.id)"] == nil else { return }
        if let at = clipAsks[key]?.at, Date().timeIntervalSince(at) < 15 { return }
        clipAsks[key] = (clipAsks[key]?.count ?? 0, Date())
        clipActivity[key] = Date()
        let parts = data.clipParts[key.stored]
        enqueue(.storyWant(id: story.id, parts: parts.map { p in (0..<p.of).filter { p.parts[$0] == nil } }), to: author)
    }

    /// The same for a video in a chat: it is in the persona that chat belongs to.
    func clipProgress(ofMessage id: UUID) -> (have: Int, of: Int)? {
        guard let at = videoMessage(id) else { return nil }
        return clipProgress(of: id, persona: data.conversations[at.convo].persona)
    }

    private func assembleClip(_ id: UUID, persona: UUID?) {
        let key = ClipKey(id, persona)
        guard let pending = data.clipParts[key.stored], pending.isComplete else { return }
        // A video in a chat: from whoever wrote the message (or, for one of your own, from another of your devices).
        if let at = videoMessage(id) {
            let message = data.conversations[at.convo].messages[at.message]
            let theirs = message.sender == pending.author
            let mine = message.isMine && contact(pending.author, in: pending.persona)?.isSelf == true
            guard message.video?.isEmpty == true, theirs || mine, data.conversations[at.convo].persona == pending.persona else { return }
            let joined = (0..<pending.of).reduce(into: Data()) { $0.append(pending.parts[$1] ?? Data()) }
            data.clipParts[key.stored] = nil
            clipActivity[key] = nil
            clipAsks[key] = nil
            guard !joined.isEmpty, joined.count <= ChatVideo.maxBytes + 500_000 else { return }
            withAnimation(.snappy) { data.conversations[at.convo].messages[at.message].video = joined }
            return
        }
        guard let i = data.stories.firstIndex(where: { $0.id == id && $0.author == pending.author && $0.persona == pending.persona }),
              case let .video(have, caption) = data.stories[i].style, have.isEmpty else { return }
        let joined = (0..<pending.of).reduce(into: Data()) { $0.append(pending.parts[$1] ?? Data()) }
        data.clipParts[key.stored] = nil
        clipActivity[key] = nil
        clipAsks[key] = nil
        guard !joined.isEmpty else { return }
        withAnimation(.snappy) { data.stories[i].style = .video(joined, caption: caption) }
        acknowledgeStory(id, author: pending.author, persona: pending.persona)
    }

    /// Tells the author a story reached this device whole (a video: with its clip), so their app stops sending it
    /// again. Only with delivery receipts on: it says when this device was online, which is what turning those off
    /// keeps back.
    private func acknowledgeStory(_ id: UUID, author: String, persona: UUID?) {
        guard data.security.deliveryReceipts,
              let story = data.stories.first(where: { $0.id == id && $0.author == author && $0.persona == persona }) else { return }
        if case let .video(clip, _) = story.style, clip.isEmpty { return }
        guard let c = contact(author, in: persona), !c.hidden, !c.isSelf else { return }
        enqueue(.storyReceived(id: id), to: c)
    }

    /// How long after a story was last sent to send it again to anyone who hasn't said they have it. A message lost
    /// on the way (a relay restart empties what it holds) would otherwise stay lost. Four tries, then it's left.
    private static let storyRetry: [TimeInterval] = [2 * 60, 15 * 60, 3600, 6 * 3600]
    @ObservationIgnored var lastResendCheck = Date.distantPast

    private func resendUnconfirmedStories() {
        let now = Date()
        guard now.timeIntervalSince(lastResendCheck) > 30 else { return }
        lastResendCheck = now
        for i in data.stories.indices {
            let story = data.stories[i]
            guard story.author == "me", story.isLive, var delivery = story.delivery, delivery.resends < Self.storyRetry.count,
                  now.timeIntervalSince(delivery.last ?? story.date) >= Self.storyRetry[delivery.resends] else { continue }
            // Still going out for the first time (or again): sending it again would only double the load.
            guard outboxCopies(of: story.id) == 0, storyBacklog[story.id] == nil else { continue }
            let waiting = audience(of: story).filter { !delivery.confirmed.contains($0.fingerprint) }
            delivery.last = now
            // Everyone has it: nothing left to do for this one.
            delivery.resends = waiting.isEmpty ? Self.storyRetry.count : delivery.resends + 1
            data.stories[i].delivery = delivery
            // A video's clip is heavy: it goes again only the first couple of times.
            fanOut(story, to: waiting.map { ($0, delivery.resends <= 2) })
        }
    }

    func postStory(_ style: StoryStyle, audience: StoryAudience = .everyone, lifetime: TimeInterval = StoryLifetime.day.rawValue) {
        var story = Story(author: "me", style: style)
        story.persona = activePersona
        story.audience = audience
        story.lifetime = lifetime
        story.delivery = StoryDelivery()
        data.storyChoices[choiceKey(activePersona)] = StoryChoice(audience: audience, lifetime: lifetime)
        withAnimation(.snappy) { data.stories.insert(story, at: 0) }
        fanOut(story, to: self.audience(of: story).map { ($0, true) })
        trackUpload(of: story.id)
        if story.isSyncable { var shared = story; shared.delivery = nil; sync(.story(shared)) }
        save()
    }

    /// Remembers a story was taken back, keeping only the newest thousand: a contact can send as many removals as
    /// they like.
    private func noteRemoved(_ key: String) {
        removedStories[key] = Date()
        if removedStories.count > 1000 {
            for old in removedStories.sorted(by: { $0.value < $1.value }).prefix(removedStories.count - 1000) { removedStories[old.key] = nil }
        }
    }

    /// Sends the stories you still have up to someone who has just become a contact, if they're in each one's
    /// audience. Otherwise they'd only ever see stories posted after they arrived.
    private func shareStories(with contact: Contact) {
        guard !contact.isSelf, !contact.hidden else { return }
        for story in data.stories where story.author == "me" && story.isLive && story.persona == contact.persona
            && story.shownTo.includes(contact.fingerprint) {
            sendStory(story, to: contact, withClip: true)
        }
    }

    /// Changes a story you posted: its words, who sees it and how long it lasts (from when it was posted). A photo
    /// or clip stays the same one. People taken out of the audience lose it, and everyone in it gets the new version.
    func editStory(_ id: Story.ID, style: StoryStyle, audience: StoryAudience, lifetime: TimeInterval) {
        guard let i = data.stories.firstIndex(where: { $0.id == id && $0.author == "me" }) else { return }
        let before = self.audience(of: data.stories[i])
        switch (data.stories[i].style, style) {
        case let (.image(photo, _), .image(_, caption)): data.stories[i].style = .image(photo, caption: caption)
        case let (.video(clip, _), .video(_, caption)): data.stories[i].style = .video(clip, caption: caption)
        case (.text, .text): data.stories[i].style = style
        default: break
        }
        data.stories[i].audience = audience
        data.stories[i].lifetime = lifetime
        data.storyChoices[choiceKey(data.stories[i].persona)] = StoryChoice(audience: audience, lifetime: lifetime)
        if data.stories[i].delivery != nil { data.stories[i].delivery = StoryDelivery() }
        let story = data.stories[i]
        let after = self.audience(of: story)
        for c in before where !after.contains(where: { $0.fingerprint == c.fingerprint }) { enqueue(.storyRemoved(id: id), to: c) }
        storyBacklog[id] = nil
        fanOut(story, to: after.map { c in (c, !before.contains { $0.fingerprint == c.fingerprint }) })
        trackUpload(of: id)
        if story.isSyncable { var shared = story; shared.delivery = nil; sync(.story(shared)) }
        save()
    }

    func deleteStory(_ id: Story.ID) {
        guard let story = data.stories.first(where: { $0.id == id && $0.author == "me" }) else { return }
        eraseClips(of: [story])
        withAnimation(.snappy) { data.stories.removeAll { $0.id == id } }
        dropUnsent(story: id)
        noteRemoved("me|\(id)")
        for c in audience(of: story) { enqueue(.storyRemoved(id: id), to: c) }
        sync(.storyRemoved(id))
        save()
    }

    /// The first time you see someone's story, they're told (never from a one-time chat).
    /// The receipt is tried again until their app confirms it reached them.
    func markSeen(_ id: Story.ID, persona: UUID?) {
        guard let i = data.stories.firstIndex(where: { $0.id == id && $0.persona == persona }), !data.stories[i].seen else { return }
        data.stories[i].seen = true
        if data.stories[i].author != "me", canReportView(of: data.stories[i]) {
            data.stories[i].viewReport = StoryViewReport(last: Date())
            sendViewReport(id, author: data.stories[i].author, persona: data.stories[i].persona)
        }
        save()
    }

    /// Whether a view of this story can be reported: never from a one-time chat, never to a hidden contact.
    private func canReportView(of story: Story) -> Bool {
        guard data.personas.first(where: { $0.id == story.persona })?.oneTimeChat != true else { return false }
        return contact(story.author, in: story.persona).map { !$0.hidden } ?? false
    }

    private func sendViewReport(_ id: UUID, author: String, persona: UUID?) {
        guard let c = contact(author, in: persona) else { return }
        enqueue(.storyViewed(id: id), to: c)
    }

    /// How long after a view receipt was last sent to try again. A lost one (a relay restart empties what it holds)
    /// would otherwise leave the author's list wrong for good. Six tries, then it's left; the story runs out anyway.
    private static let viewRetry: [TimeInterval] = [60, 2 * 60, 5 * 60, 15 * 60, 3600, 3 * 3600]
    @ObservationIgnored private var lastViewRetryCheck = Date.distantPast

    private func resendUnconfirmedViews() {
        let now = Date()
        guard now.timeIntervalSince(lastViewRetryCheck) > 30 else { return }
        lastViewRetryCheck = now
        for i in data.stories.indices {
            let story = data.stories[i]
            guard story.author != "me", story.isLive, var report = story.viewReport, !report.confirmed,
                  report.resends < Self.viewRetry.count,
                  now.timeIntervalSince(report.last ?? story.date) >= Self.viewRetry[report.resends],
                  !storyViewQueued(story.id) else { continue }
            // The chat can't carry one now (the contact was hidden, say): nothing more to send.
            guard canReportView(of: story) else {
                data.stories[i].viewReport = nil
                continue
            }
            report.resends += 1
            report.last = now
            data.stories[i].viewReport = report
            sendViewReport(story.id, author: story.author, persona: story.persona)
        }
    }

    /// Whether a view receipt for this story is still waiting to go out somewhere.
    private func storyViewQueued(_ id: Story.ID) -> Bool {
        let waiting = data.contacts.contains { $0.devices.contains { $0.pending.contains { $0.payload.storyViewID == id } } }
        return waiting || data.outbox.contains { $0.viewReport == id }
    }

    /// How many copies of a story were waiting to go out when it was posted or last changed.
    private var storyUploadTotal: [Story.ID: Int] = [:]

    /// The people a story hasn't been queued for yet, and about how many copies each takes.
    private struct StoryBacklog { var targets: [StoryTarget]; var perContact = 1 }
    /// Sealing a story for everyone at once piles hundreds of megabytes into the outbox, and every save then wrote all
    /// of it out again, which starved the rest of the app. So it is queued for a few people at a time, as the earlier
    /// copies go. Who is left is saved with the story (`StoryDelivery.left`), so closing the app part-way loses nobody.
    @ObservationIgnored private var storyBacklog: [Story.ID: StoryBacklog] = [:]
    /// Copies of one story to hold in the outbox before queueing it for more people.
    private static let storyOutboxLimit = 12

    private func fanOut(_ story: Story, to targets: [(Contact, Bool)]) {
        storyBacklog[story.id] = StoryBacklog(targets: targets.map {
            StoryTarget(fingerprint: $0.0.fingerprint, persona: $0.0.persona, withClip: $0.1)
        })
        let queued = drainStoryBacklog(story.id)
        if queued > 0 { storyBacklog[story.id]?.perContact = max(1, unsentCopies(of: story.id) / queued) }
        noteBacklog(story.id)
    }

    /// Writes who a story is still to be queued for into the story itself, where it's saved.
    private func noteBacklog(_ id: Story.ID) {
        guard let i = data.stories.firstIndex(where: { $0.id == id }), data.stories[i].delivery != nil else { return }
        let left = storyBacklog[id].map(\.targets)
        if data.stories[i].delivery?.left != left { data.stories[i].delivery?.left = left }
    }

    /// Stories that were still going out when Pulshade was last closed carry on from where they stopped.
    private func resumeStoryUploads() {
        for story in data.stories where story.author == "me" && storyBacklog[story.id] == nil {
            guard let left = story.delivery?.left, !left.isEmpty else { continue }
            guard story.isLive else { noteBacklog(story.id); continue }
            storyBacklog[story.id] = StoryBacklog(targets: left)
            let queued = drainStoryBacklog(story.id)
            if queued > 0 { storyBacklog[story.id]?.perContact = max(1, unsentCopies(of: story.id) / queued) }
            noteBacklog(story.id)
            trackUpload(of: story.id)
        }
        // And those with nobody left to queue for, whose last copies were still waiting to be sent.
        for story in data.stories where story.author == "me" && storyUploadTotal[story.id] == nil && isUploading(story.id) {
            trackUpload(of: story.id)
        }
    }

    /// How far the stories going out now have got, all of them together, 0...1. Nil when none is.
    private var storyUploadProgress: Double? {
        var (total, left) = (0, 0)
        for (id, n) in storyUploadTotal where isUploading(id) {
            let waiting = unsentCopies(of: id) + backlogCopies(of: id)
            total += max(n, waiting)
            left += waiting
        }
        return total > 0 && left > 0 ? 1 - Double(left) / Double(total) : nil
    }

    /// While a story is going out, an iPhone doesn't sleep with Pulshade in front, and iOS is asked to let the upload
    /// carry on if you leave. Called whenever an upload starts, and on every beat after.
    private func tendStoryUpload() {
        #if os(iOS)
        let progress = phase == .unlocked ? storyUploadProgress : nil
        let inFront = backgroundedAt == nil
        let awake = progress != nil && inFront
        if UIApplication.shared.isIdleTimerDisabled != awake { UIApplication.shared.isIdleTimerDisabled = awake }
        guard let progress else {
            if BackgroundUpload.isWanted {
                BackgroundUpload.finish()
                // Nothing more to send, and nobody looking: as when the app leaves the screen with nothing going out.
                if !inFront { RelayClient.closeAll() }
            }
            return
        }
        if inFront, !BackgroundUpload.isWanted {
            BackgroundUpload.onEnded = { [weak self] in
                guard let self, self.backgroundedAt != nil else { return }
                self.save()
                RelayClient.closeAll()
            }
            // What iOS shows outside the app says no more than a notification would.
            let hidden = data.security.notificationContent == .hidden
            BackgroundUpload.begin(title: hidden ? "Uploading" : "Posting your story", subtitle: hidden ? "In progress" : "Sending it to your friends")
        }
        BackgroundUpload.report(progress)
        #endif
    }

    /// Queues stories for more people while there's room. Returns how many people it queued for.
    @discardableResult
    private func drainStoryBacklog(_ only: Story.ID? = nil) -> Int {
        var queued = 0
        for id in Array(storyBacklog.keys) where only == nil || only == id {
            guard var entry = storyBacklog[id], let story = data.stories.first(where: { $0.id == id }) else {
                storyBacklog[id] = nil
                continue
            }
            while let target = entry.targets.first, outboxCopies(of: id) < Self.storyOutboxLimit {
                entry.targets.removeFirst()
                guard let i = contactIndex(target.fingerprint, target.persona) else { continue }
                sendStory(story, to: data.contacts[i], withClip: target.withClip)
                queued += 1
            }
            storyBacklog[id] = entry.targets.isEmpty ? nil : entry
            noteBacklog(id)
        }
        return queued
    }

    /// Copies still to be queued, counted in copies.
    private func backlogCopies(of id: Story.ID) -> Int {
        guard let entry = storyBacklog[id] else { return 0 }
        return entry.targets.count * entry.perContact
    }

    /// Copies of a story not yet handed to the relay: still waiting for a session, or sealed and queued.
    private func unsentCopies(of id: Story.ID) -> Int {
        let waiting = data.contacts.reduce(0) { n, c in
            n + c.devices.reduce(0) { $0 + $1.pending.filter { $0.payload.storyID == id }.count }
        }
        return waiting + data.outbox.filter { $0.story == id }.count
    }

    /// A story that's over (its time ran out, or you deleted it) stops going out: the copies still waiting to be
    /// sent, sealed or not, are let go rather than uploaded for nobody to watch. One that's part-way up the wire
    /// finishes; whoever gets it drops it as expired or removed.
    private func dropUnsent(story id: Story.ID) {
        storyBacklog[id] = nil
        noteBacklog(id)
        storyUploadTotal[id] = nil
        if data.outbox.contains(where: { $0.story == id && !sendingIDs.contains($0.id) }) {
            data.outbox.removeAll { $0.story == id && !sendingIDs.contains($0.id) }
        }
        for c in data.contacts.indices {
            for d in data.contacts[c].devices.indices where data.contacts[c].devices[d].pending.contains(where: { $0.payload.storyID == id }) {
                data.contacts[c].devices[d].pending.removeAll { $0.payload.storyID == id }
            }
        }
    }

    private func trackUpload(of id: Story.ID) {
        let n = unsentCopies(of: id) + backlogCopies(of: id)
        if n > 0 { storyUploadTotal[id] = n } else { storyUploadTotal[id] = nil }
        markUploadedIfDone(id)
        tendStoryUpload()
    }

    /// Copies of a story sealed and waiting in the outbox. Not those still waiting for a session with someone: they
    /// can't go until that person is reachable, which isn't up to the upload.
    private func outboxCopies(of id: Story.ID) -> Int { data.outbox.filter { $0.story == id }.count }

    /// Once nothing of a story is left in the outbox, its upload is over for good. The sends that come later, to
    /// people who never confirmed, happen quietly.
    private func markUploadedIfDone(_ id: Story.ID) {
        guard outboxCopies(of: id) == 0, storyBacklog[id] == nil, let i = data.stories.firstIndex(where: { $0.id == id }),
              data.stories[i].delivery != nil, data.stories[i].delivery?.uploaded != true else { return }
        data.stories[i].delivery?.uploaded = true
        storyUploadTotal[id] = nil
    }

    /// Whether copies of a story are still waiting to go out. Unlike the progress, this holds after a restart.
    func isUploading(_ id: Story.ID) -> Bool {
        guard let story = data.stories.first(where: { $0.id == id }), story.author == "me",
              story.delivery != nil, story.delivery?.uploaded != true else { return false }
        return outboxCopies(of: id) > 0 || storyBacklog[id] != nil
    }

    /// How far a story you posted has got to its audience, 0...1, or nil once it's all gone (or never needed to).
    func uploadProgress(of id: Story.ID) -> Double? {
        guard let total = storyUploadTotal[id], data.stories.first(where: { $0.id == id })?.delivery?.uploaded != true else { return nil }
        let left = unsentCopies(of: id) + backlogCopies(of: id)
        guard left > 0 else { return nil }
        return 1 - Double(left) / Double(max(total, left))
    }

    /// Your stories on screen: any still going out, and whether any has yet to be viewed by anyone.
    var storyUpload: Double? {
        let all = myStories.compactMap { uploadProgress(of: $0.id) }
        return all.isEmpty ? nil : all.reduce(0, +) / Double(all.count)
    }

    var hasUnviewedStory: Bool {
        myStories.contains { ($0.viewers ?? [:]).isEmpty && !audience(of: $0).isEmpty }
    }

    /// A story audience in a few words: "All contacts", "3 people", "All except 2".
    func summary(of audience: StoryAudience) -> String {
        let known = Set(visibleContacts.map(\.fingerprint))
        let count = audience.people.filter(known.contains).count
        switch audience {
        case .everyone: return "All contacts"
        case .only: return count == 1 ? "1 person" : "\(count) people"
        case .except: return count == 0 ? "All contacts" : "All except \(count)"
        }
    }

    /// How many of the people a story of yours is for have said it reached them (with its video, for a video). Only
    /// people with delivery receipts on can say so, so this can be lower than the truth.
    func storyReceipt(of story: Story) -> (have: Int, of: Int)? {
        guard story.author == "me", let delivery = story.delivery else { return nil }
        let people = audience(of: story)
        guard !people.isEmpty else { return nil }
        return (people.filter { delivery.confirmed.contains($0.fingerprint) }.count, people.count)
    }

    /// Who viewed one of your stories, most recent first.
    func viewers(of id: Story.ID) -> [(fingerprint: String, at: Date)] {
        guard let story = data.stories.first(where: { $0.id == id && $0.author == "me" }) else { return [] }
        return (story.viewers ?? [:]).map { ($0.key, $0.value) }.sorted { $0.at > $1.at }
    }

    /// Someone's stories, from the first one you haven't watched, if there's any you haven't: what tapping their
    /// glowing picture plays. Nil when they have none live or you've watched them all.
    func unwatchedReel(of author: String) -> StoryReel? {
        guard !author.isEmpty, author != "me", data.stories.contains(where: { $0.author == author && !$0.seen }) else { return nil }
        let live = data.stories.filter { $0.author == author && $0.isLive && $0.persona == activePersona }.sorted { $0.date < $1.date }
        guard let first = live.firstIndex(where: { !$0.seen }) else { return nil }
        return StoryReel(stories: live, start: first)
    }

    /// Set to play someone's story from anywhere in the app. `MainView` shows it.
    var storyToOpen: StoryReel?

    /// Oldest first, the order they play in.
    var myStories: [Story] { data.stories.filter { $0.author == "me" && $0.isLive && $0.isReady && $0.persona == activePersona }.sorted { $0.date < $1.date } }

    /// Other people's live stories, newest author first.
    var friendStories: [(author: String, stories: [Story])] {
        // A video still arriving is listed too, shown as loading, so a stalled one doesn't just look missing.
        let live = data.stories.filter { $0.author != "me" && $0.isLive && $0.persona == activePersona }
        let grouped = Dictionary(grouping: live, by: \.author)
        return grouped.map { ($0.key, $0.value.sorted { $0.date < $1.date }) }
            .sorted { ($0.stories.last?.date ?? .distantPast) > ($1.stories.last?.date ?? .distantPast) }
    }

    // MARK: Personas

    var activePersona: UUID? { data.activePersona }
    private var identityCache: [UUID: Identity] = [:]

    /// The keys for one of your personas. Nil is your main identity.
    func me(_ persona: UUID?) -> Identity? {
        guard let persona else { return identity }
        if let cached = identityCache[persona] { return cached }
        guard let seed = data.personas.first(where: { $0.id == persona })?.seed,
              let made = try? Identity(seed: seed) else { return nil }
        identityCache[persona] = made
        return made
    }

    func profile(for persona: UUID?) -> Profile {
        guard let persona else { return data.profile }
        return data.personas.first { $0.id == persona }?.profile ?? Profile()
    }

    private func setProfile(_ profile: Profile, for persona: UUID?) {
        var profile = profile
        profile.format = profileFormat
        if let persona {
            guard let i = data.personas.firstIndex(where: { $0.id == persona }) else { return }
            data.personas[i].profile = profile
        } else {
            data.profile = profile
        }
    }

    var activeProfile: Profile { profile(for: activePersona) }

    /// Everyday personas. Burners live with their chats instead.
    var personas: [Persona] { data.personas.filter { !$0.isBurner } }

    /// How many everyday personas an account can make, besides the main identity. Burners don't count.
    static let personaLimit = 4

    var canAddPersona: Bool { personas.count < Self.personaLimit }

    private var myFingerprints: Set<String> {
        Set(([identity] + data.personas.map { me($0.id) }).compactMap { $0?.fingerprint })
    }

    /// True for your own account or one of your personas, on any of your linked devices.
    func isMine(_ fingerprint: String) -> Bool { myFingerprints.contains(fingerprint) }

    func isBurner(_ persona: UUID?) -> Bool { burner(persona) != nil }

    func burner(_ persona: UUID?) -> Persona? {
        guard let persona else { return nil }
        return data.personas.first { $0.id == persona && $0.isBurner }
    }

    func switchPersona(_ id: UUID?) {
        guard id == nil || data.personas.contains(where: { $0.id == id }) else { return }
        if data.security.onlineStatus, id != data.activePersona { sendPresence(false) }
        presenceDue = [:]
        openConversation = nil
        if id != data.activePersona { eggs = [] }
        withAnimation(.smooth(duration: 0.4)) { data.activePersona = id }
        save()
    }

    /// Moves to the next everyday persona, going round through your main account. Does nothing with only one account.
    func switchToNextPersona() {
        let order: [UUID?] = [nil] + personas.map { $0.id }
        guard order.count > 1 else { return }
        let here = order.firstIndex { $0 == data.activePersona } ?? -1
        switchPersona(order[(here + 1) % order.count])
    }

    @discardableResult
    func createPersona(name: String) -> Persona? {
        guard canAddPersona else { return nil }
        let persona = Persona(seed: Identity.generate().seed,
                              profile: Profile(name: name, color: Int.random(in: 0..<Signature.colors.count)))
        withAnimation(.snappy) { data.personas.append(persona) }
        sync(.persona(persona))
        save()
        return persona
    }

    /// Removes a persona and everything that belongs to it.
    func deletePersona(_ id: UUID) {
        if data.activePersona == id { data.activePersona = nil }
        if let open = openConversation, conversation(open)?.persona == id { openConversation = nil }
        // Its files and video clips on the relay are erased too.
        for convo in data.conversations where convo.persona == id { eraseFiles(in: convo.messages) }
        eraseClips(of: data.stories.filter { $0.persona == id })
        withAnimation(.snappy) {
            data.conversations.removeAll { $0.persona == id }
            data.contacts.removeAll { $0.persona == id }
            data.invites.removeAll { $0.persona == id }
            data.stories.removeAll { $0.persona == id }
            data.personas.removeAll { $0.id == id }
        }
        identityCache[id] = nil
        sync(.personaDeleted(id))
        save()
    }

    // MARK: Public profiles & requests

    enum DirectoryError: Error { case invalidHandle, taken, reserved, held, full, unreachable, invalid }

    /// Requests waiting for the active persona.
    var requests: [FriendRequest] { data.requests.filter { $0.persona == activePersona } }

    /// Requests you've sent that haven't been answered yet.
    var sentRequests: [Contact] { data.contacts.filter { $0.awaitingAcceptance && $0.persona == activePersona } }

    /// The reusable mailbox behind a persona's public profile: the same on every device with the account, since it's
    /// worked out from the account itself. One it replaces (another handle's, or a random one from before) is still
    /// read for a week, for requests already on their way.
    private func publicInvite(for persona: UUID?, handle: String, me: Identity) -> OpenInvite {
        let key = me.publicInboxKey(handle: handle)
        // Every handle in use keeps its request mailbox; only ones no longer in use are wound down.
        let inUse = Set(profile(for: persona).activeHandles.map { me.publicInboxKey(handle: $0) } + [key])
        retirePublicInvites(of: persona, except: inUse)
        if let i = data.invites.firstIndex(where: { $0.receiveKey == key }) {
            data.invites[i].retiresAt = nil
            return data.invites[i]
        }
        let invite = OpenInvite(receiveKey: key, persona: persona, isPublic: true)
        data.invites.append(invite)
        return invite
    }

    private func retirePublicInvites(of persona: UUID?, except keys: Set<Data>) {
        for i in data.invites.indices where data.invites[i].isPublic && data.invites[i].persona == persona
            && !keys.contains(data.invites[i].receiveKey) && data.invites[i].retiresAt == nil {
            data.invites[i].retiresAt = Date().addingTimeInterval(7 * 24 * 3600)
        }
    }

    /// Lists a profile again if its listing still points at a mailbox from before they were worked out from the
    /// account, which another copy of it (one recovered elsewhere, say) may have left nobody reading. Once per
    /// persona, each after its own random wait, so the relay doesn't see them all arrive together.
    private func relistStrandedProfiles() {
        for persona in [nil] + data.personas.filter({ !$0.isBurner }).map(\.id) {
            guard let handle = profile(for: persona).handle, let me = me(persona),
                  !data.invites.contains(where: { $0.receiveKey == me.publicInboxKey(handle: handle) }) else { continue }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(persona == nil ? Double.random(in: 5...30) : Double.random(in: 60...900)))
                guard let self, self.phase == .unlocked else { return }
                await self.republish(persona)
                self.syncPublicProfile(persona)
                self.save()
            }
        }
    }

    func signedEntry(handle: String, persona: UUID?) throws -> RelayClient.DirectoryEntry {
        guard let me = me(persona) else { throw DirectoryError.invalid }
        let invite = publicInvite(for: persona, handle: handle, me: me)
        let profile = profile(for: persona)
        var card = DirectoryProfile(handle: handle, name: profile.name, bio: profile.bio ?? "", avatar: profile.avatar,
                                    banner: profile.banner, color: profile.color, signingKey: me.card.signing, agreementKey: me.card.agreement,
                                    sendID: Mailbox.sendID(for: invite.receiveKey), relay: invite.relay, badge: profile.badge)
        card.links = Self.sharedLinks(profile)
        card.notes = Self.sharedNotes(profile)
        let blob = try JSONEncoder.pulshade.encode(card)
        // Milliseconds, so quick successive edits are still each "newer" than the last.
        let updated = UInt64(Date().timeIntervalSince1970 * 1000)
        let message = Data("pulshade.dir.v1".utf8) + Data(handle.utf8) + withUnsafeBytes(of: updated.bigEndian) { Data($0) } + blob
        let sig = try me.signingKey.signature(for: message)
        return .init(key: me.card.signing.base64EncodedString(), blob: blob.base64EncodedString(),
                     sig: sig.base64EncodedString(), updated: updated)
    }

    /// Lists the active persona under @handle so anyone who knows it can send a request. The first handle becomes
    /// the main one; a second or third is in use alongside it (up to `maxHandles`, counting any kept for you).
    func publishProfile(handle raw: String) async throws {
        guard let handle = DirectoryProfile.validHandle(raw) else { throw DirectoryError.invalidHandle }
        guard let client = client(nil, lane: Self.directoryLane(activePersona)) else { throw DirectoryError.unreachable }
        let persona = activePersona
        let entry = try signedEntry(handle: handle, persona: persona)
        do {
            try await client.claim(handle, entry)
        } catch RelayClient.DirectoryError.taken {
            throw DirectoryError.taken
        } catch RelayClient.DirectoryError.reserved {
            throw DirectoryError.reserved
        } catch RelayClient.DirectoryError.held {
            throw DirectoryError.held
        } catch RelayClient.DirectoryError.full {
            throw DirectoryError.full
        } catch RelayClient.DirectoryError.unreachable {
            throw DirectoryError.unreachable
        } catch RelayClient.DirectoryError.invalid {
            // Anything else the relay said no with, a rate limit among them.
            throw DirectoryError.invalid
        }
        // Read after the wait, so nothing that changed the profile meanwhile is written over.
        var profile = profile(for: persona)
        if profile.handle == nil {
            profile.handle = handle
        } else if !profile.activeHandles.contains(handle) {
            profile.moreHandles = Array(((profile.moreHandles ?? []) + [handle]).prefix(Self.maxHandles - 1))
        }
        profile.updatedAt = Date()
        setProfile(profile, for: persona)
        syncPublicProfile(persona)
        save()
    }

    /// Makes one of the active persona's handles in use the main one, shown on its profile. The others stay in use.
    func makeMainHandle(_ handle: String) {
        let persona = activePersona
        var profile = profile(for: persona)
        guard profile.activeHandles.contains(handle), profile.handle != handle else { return }
        profile.moreHandles = profile.activeHandles.filter { $0 != handle }
        profile.handle = handle
        profile.updatedAt = Date()
        setProfile(profile, for: persona)
        syncPublicProfile(persona)
        save()
    }

    /// Stops using one handle: it leaves the directory and is kept for this identity for three months (see
    /// `heldHandles`), and its request mailbox winds down. If it was the main one, the next in use takes over.
    func stopUsingHandle(_ handle: String) async {
        let persona = activePersona
        guard profile(for: persona).activeHandles.contains(handle) else { return }
        await release(handle, persona: persona)
        var profile = profile(for: persona)
        let left = profile.activeHandles.filter { $0 != handle }
        profile.handle = left.first
        profile.moreHandles = left.count > 1 ? Array(left.dropFirst()) : nil
        profile.updatedAt = Date()
        setProfile(profile, for: persona)
        if let me = me(persona) {
            if left.isEmpty {
                data.invites.removeAll { $0.isPublic && $0.persona == persona }
            } else {
                retirePublicInvites(of: persona, except: Set(left.map { me.publicInboxKey(handle: $0) }))
            }
        }
        syncPublicProfile(persona)
        save()
    }

    /// Takes the active persona out of the directory and stops reading its request mailbox.
    func unpublishProfile() async {
        let persona = activePersona
        guard profile(for: persona).handle != nil else { return }
        await releaseHandles(persona: persona, keeping: nil)
        data.invites.removeAll { $0.isPublic && $0.persona == persona }
        // Read after the wait, so nothing that changed the profile meanwhile is written over.
        var profile = profile(for: persona)
        profile.handle = nil
        profile.moreHandles = nil
        profile.updatedAt = Date()
        setProfile(profile, for: persona)
        syncPublicProfile(persona)
        save()
    }

    private func release(_ handle: String, persona: UUID?) async {
        guard let me = me(persona), let client = client(nil, lane: Self.directoryLane(persona)) else { return }
        let ts = UInt64(RelayClock.now.timeIntervalSince1970)
        let message = Data("pulshade.dir.del.v1".utf8) + Data(handle.utf8) + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
        guard let sig = try? me.signingKey.signature(for: message) else { return }
        try? await client.release(handle, sig: sig.base64EncodedString(), ts: ts)
    }

    /// Burning: every handle the identity lists or holds stays unclaimable for a while, with nothing left on
    /// the relay to say whose it was.
    private func retireHandles(persona: UUID?) async {
        guard let me = me(persona), let client = client(nil, lane: Self.directoryLane(persona)) else { return }
        let ts = UInt64(RelayClock.now.timeIntervalSince1970)
        let key = me.card.signing
        let message = Data("pulshade.dir.retire.v1".utf8) + key + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
        guard let sig = try? me.signingKey.signature(for: message) else { return }
        try? await client.retire(key: key.base64EncodedString(), sig: sig.base64EncodedString(), ts: ts)
    }

    /// Keeps a listed profile in step with name, picture and bio changes.
    private func republish(_ persona: UUID?) async {
        guard let client = client(nil, lane: Self.directoryLane(persona)) else { return }
        // Every handle in use shows the same profile.
        for handle in profile(for: persona).activeHandles {
            guard let entry = try? signedEntry(handle: handle, persona: persona) else { continue }
            try? await client.claim(handle, entry)
        }
    }

    /// Looks up exactly one handle and checks its signature. Nil if nobody has it.
    func findProfile(_ raw: String) async throws -> DirectoryProfile? {
        guard let handle = DirectoryProfile.validHandle(raw) else { throw DirectoryError.invalidHandle }
        guard let client = client(nil, lane: "lookup") else { throw DirectoryError.unreachable }
        let found: RelayClient.DirectoryEntry?
        do { found = try await client.lookup(handle) } catch { throw DirectoryError.unreachable }
        guard let entry = found else { return nil }
        guard var profile = verified(entry, handle: handle) else { throw DirectoryError.invalid }
        if profile.badge?.isGenuine(for: profile.signingKey) != true { profile.badge = nil }
        return profile
    }

    /// A directory entry's profile, if it's for this handle and really signed by the key it names.
    private func verified(_ entry: RelayClient.DirectoryEntry, handle: String) -> DirectoryProfile? {
        guard let blob = Data(base64Encoded: entry.blob), let sig = Data(base64Encoded: entry.sig),
              let profile = try? JSONDecoder.pulshade.decode(DirectoryProfile.self, from: blob),
              profile.handle == handle, Data(base64Encoded: entry.key) == profile.signingKey,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: profile.signingKey) else { return nil }
        let message = Data("pulshade.dir.v1".utf8) + Data(handle.utf8)
            + withUnsafeBytes(of: entry.updated.bigEndian) { Data($0) } + blob
        return key.isValidSignature(sig, for: message) ? profile : nil
    }

    /// Lets go of every handle an identity holds in the directory except `keep`.
    private func releaseHandles(persona: UUID?, keeping keep: String?) async {
        guard let me = me(persona) else { return }
        for listed in await publicProfiles(of: me) where listed.handle != keep {
            await release(listed.handle, persona: persona)
        }
        for old in profile(for: persona).activeHandles where old != keep { await release(old, persona: persona) }
    }

    /// Clears handles left behind by older versions, which let each device claim its own. Only when this
    /// device's handle is the identity's newest, so a device with an out-of-date profile never releases
    /// the real one.
    func releaseLeftoverHandles() async {
        // An identity may now use up to three handles at once, so nothing listed is released here any more. A
        // handle the directory lists for this identity that this device doesn't know of (claimed on another of
        // your devices before the two caught up) is taken as in use.
        for persona in [nil] + data.personas.filter { !$0.isBurner }.map(\.id) {
            guard profile(for: persona).handle != nil, let me = me(persona) else { continue }
            let listed = await publicProfiles(of: me).map(\.handle)
            var profile = profile(for: persona)
            let unknown = listed.filter { !profile.activeHandles.contains($0) }
            guard !unknown.isEmpty else { continue }
            profile.moreHandles = Array(((profile.moreHandles ?? []) + unknown).prefix(Self.maxHandles - 1))
            setProfile(profile, for: persona)
            save()
        }
    }

    /// A handle the active identity stopped using, kept for it so nobody else can take it until `until`.
    struct HeldHandle: Identifiable, Equatable {
        var handle: String
        var until: Date
        var id: String { handle }
    }

    /// How many handles an identity may have, those in use and those kept for it together. The relay enforces it.
    static let maxHandles = 3

    /// The handles kept for the active identity, soonest free first.
    func heldHandles() async throws -> [HeldHandle] {
        guard let me = me(activePersona), let client = client(nil, lane: Self.directoryLane(activePersona)) else { throw DirectoryError.unreachable }
        let (key, sig, ts) = try ownerProof("pulshade.dir.held.v1", about: me.card.signing, by: me)
        do {
            return try await client.held(key: key, sig: sig, ts: ts).map { HeldHandle(handle: $0.handle, until: $0.until) }
        } catch { throw DirectoryError.unreachable }
    }

    /// Lets go of a handle kept for the active identity: anyone may claim it from now on.
    func letGo(of handle: String) async throws {
        guard let me = me(activePersona), let client = client(nil, lane: Self.directoryLane(activePersona)) else { throw DirectoryError.unreachable }
        let (key, sig, ts) = try ownerProof("pulshade.dir.unhold.v1", about: Data(handle.utf8), by: me)
        do { try await client.unhold(handle, key: key, sig: sig, ts: ts) } catch { throw DirectoryError.unreachable }
    }

    // MARK: Collectibles

    /// What the backup code alert shows: collectibles the code now covers, and whether the code itself is new.
    struct CodeAlert: Identifiable, Equatable {
        var id = UUID()
        var items: [Collectible]
        var newCode: Bool
    }
    /// Set when the backup code starts covering something, so an alert can say so. Memory only.
    var codeAlert: CodeAlert?
    /// The next time to look for new collectibles: soon after unlocking, then every half hour.
    private var nextCollectibleCheck = Date.distantFuture
    /// After entering a giveaway code, looking for the new collectible more often until this time.
    private var collectibleWatchUntil = Date.distantPast

    /// Asks the relay which collectibles the active persona has been given, keeping only ones that check out.
    /// If the one shown after its name is no longer among them, it stops being shown. A new one joins the backup code
    /// (made the first time), and an alert asks you to keep the code safe.
    func refreshCollectibles() async throws {
        let persona = activePersona
        guard let me = me(persona), let client = client(nil, lane: Self.directoryLane(persona)) else { throw DirectoryError.unreachable }
        let (key, sig, ts) = try ownerProof("pulshade.collect.mine.v1", about: me.card.signing, by: me)
        let given: [(collectible: Collectible, coded: Bool)]
        do { given = try await client.collectibles(key: key, sig: sig, ts: ts) } catch { throw DirectoryError.unreachable }
        guard activePersona == persona else { return }
        let genuine = given.filter { $0.collectible.isGenuine(for: me.card.signing) }
            .sorted { ($0.collectible.item, $0.collectible.serial) < ($1.collectible.item, $1.collectible.serial) }
        updateProfile { profile in
            profile.collectibles = genuine.map(\.collectible)
            if let badge = profile.badge, !genuine.contains(where: { $0.collectible == badge }) { profile.badge = nil }
        }
        let known = activeProfile.collectibleCodes ?? [:]
        // A code on the relay this device doesn't know was set by another of your devices: wait for its profile to
        // arrive rather than make a second code that would break that one.
        if activeProfile.collectionCode == nil, genuine.contains(where: { $0.coded && known[$0.collectible.id] == nil }) { return }
        let code = activeProfile.collectionCode
        let uncovered = genuine.map(\.collectible).filter { ($0.kind?.transferable ?? true) && (code == nil || known[$0.id] != code) }
        guard !uncovered.isEmpty else { return }
        let fresh = code == nil
        let covered = (try? await cover(uncovered, with: code ?? Collectible.newBackupCode())) ?? []
        if !covered.isEmpty {
            codeAlert = CodeAlert(items: fresh ? genuine.map(\.collectible) : (codeAlert?.items ?? []) + covered, newCode: fresh || codeAlert?.newCode == true)
        }
    }

    // MARK: Eggs

    /// The eggs the active persona holds, and when they were last asked about (for counting down). Memory only.
    private(set) var eggs: [RelayClient.EggInfo] = []
    private var eggsAsked = Date()

    func refreshEggs() async {
        let persona = activePersona
        guard let me = me(persona), let client = client(nil, lane: Self.directoryLane(persona)),
              let (key, sig, ts) = try? ownerProof("pulshade.eggs.mine.v1", about: me.card.signing, by: me),
              let list = try? await client.eggs(key: key, sig: sig, ts: ts), activePersona == persona else { return }
        eggsAsked = Date()
        withAnimation(.smooth) { eggs = list }
    }

    /// Seconds until an egg is ready, by the relay's clock: nil if it hasn't been started, 0 when it's ready.
    func secondsLeft(_ egg: RelayClient.EggInfo, at date: Date = Date()) -> TimeInterval? {
        guard let at = egg.hatches_at else { return nil }
        let relayNow = Double(egg.now) + date.timeIntervalSince(eggsAsked)
        return max(0, Double(at) - relayNow)
    }

    /// Starts an egg's clock.
    func startEgg(_ id: String) async throws {
        guard let me = me(activePersona), let client = client(nil, lane: Self.directoryLane(activePersona)) else { throw DirectoryError.unreachable }
        let (key, sig, ts) = try ownerProof("pulshade.eggs.start.v1", about: Data(id.utf8), by: me)
        let started: RelayClient.EggInfo
        do { started = try await client.startEgg(key: key, sig: sig, ts: ts, id: id) } catch { throw DirectoryError.unreachable }
        eggsAsked = Date()
        withAnimation(.smooth) { eggs = eggs.map { $0.id == id ? started : $0 } }
    }

    /// Opens an egg that's ready. The pet inside is the relay's roll, signed by its key, so this checks that before
    /// showing it.
    func hatchEgg(_ id: String) async throws -> Collectible {
        let persona = activePersona
        guard let me = me(persona), let client = client(nil, lane: Self.directoryLane(persona)) else { throw RelayClient.HatchError.unreachable }
        let (key, sig, ts) = try ownerProof("pulshade.eggs.hatch.v1", about: Data(id.utf8), by: me)
        let pet = try await client.hatchEgg(key: key, sig: sig, ts: ts, id: id)
        guard pet.isGenuine(for: me.card.signing) else { throw RelayClient.HatchError.unreachable }
        withAnimation(.smooth) { eggs.removeAll { $0.id == id } }
        try? await refreshCollectibles()
        return pet
    }

    /// Gives a collectible to a contact. They see it the next time their app checks.
    func gift(_ item: Collectible, to contact: Contact) async throws {
        guard let me = me(activePersona), let client = client(nil, lane: Self.directoryLane(activePersona)) else { throw DirectoryError.unreachable }
        let to = contact.signingKey
        let about = Data(item.item.utf8) + Data([0]) + withUnsafeBytes(of: item.serial.bigEndian) { Data($0) } + to
        let (key, sig, ts) = try ownerProof("pulshade.collect.gift.v1", about: about, by: me)
        do { try await client.giftCollectible(key: key, sig: sig, ts: ts, item: item.item, serial: item.serial, to: to.base64EncodedString()) }
        catch { throw DirectoryError.unreachable }
        try? await refreshCollectibles()
    }

    /// Lets a collectible go. It goes back into circulation, and its number can hatch again for someone else.
    func release(_ item: Collectible) async throws {
        guard let me = me(activePersona), let client = client(nil, lane: Self.directoryLane(activePersona)) else { throw DirectoryError.unreachable }
        let about = Data(item.item.utf8) + Data([0]) + withUnsafeBytes(of: item.serial.bigEndian) { Data($0) }
        let (key, sig, ts) = try ownerProof("pulshade.collect.release.v1", about: about, by: me)
        do { try await client.releaseCollectible(key: key, sig: sig, ts: ts, item: item.item, serial: item.serial) }
        catch { throw DirectoryError.unreachable }
        try? await refreshCollectibles()
    }

    /// The backup code for all of the active persona's collectibles, if this device has it.
    var collectionCode: String? { activeProfile.collectionCode }

    /// Replaces the backup code with a new one for every collectible. The old code stops working.
    @discardableResult
    func makeNewCollectionCode() async throws -> String {
        let code = Collectible.newBackupCode()
        let all = (activeProfile.collectibles ?? []).filter { $0.kind?.transferable ?? true }
        let covered = try await cover(all, with: code)
        if covered.count < all.count { throw DirectoryError.unreachable }
        return code
    }

    /// Sets `code` on the relay for each collectible (only its hash travels) and keeps it as the collection code.
    /// Returns the ones it reached.
    private func cover(_ items: [Collectible], with code: String) async throws -> [Collectible] {
        let persona = activePersona
        guard let me = me(persona), let client = client(nil, lane: Self.directoryLane(persona)) else { throw DirectoryError.unreachable }
        let hash = Collectible.codeHash(code)
        var covered: [Collectible] = []
        for item in items {
            let about = Data(item.item.utf8) + Data([0]) + withUnsafeBytes(of: item.serial.bigEndian) { Data($0) } + hash
            let (key, sig, ts) = try ownerProof("pulshade.collect.code.v1", about: about, by: me)
            guard (try? await client.setCollectibleCode(key: key, sig: sig, ts: ts, item: item.item, serial: item.serial, hash: hash)) != nil
            else { continue }
            covered.append(item)
        }
        guard !covered.isEmpty || items.isEmpty else { throw DirectoryError.unreachable }
        // Kept like the rest of your profile, and passed to your other devices, but never to contacts.
        var profile = self.profile(for: persona)
        profile.collectionCode = code
        profile.collectibleCodes = (profile.collectibleCodes ?? [:]).merging(covered.map { ($0.id, code) }) { $1 }
        profile.updatedAt = Date()
        setProfile(profile, for: persona)
        sync(.profile(persona: persona, profile))
        save()
        return covered
    }

    /// Brings collectibles back with a backup code from another account (one that burned, say). PULSHADE then signs
    /// them over to this account, numbers unchanged; they show up here once it has. Returns what the code was for.
    func claimCollectibles(code: String) async throws -> [(item: String, serial: UInt32)] {
        guard let me = me(activePersona), let client = client(nil, lane: Self.directoryLane(activePersona)) else { throw RelayClient.ClaimError.unreachable }
        let (key, sig, ts) = try ownerProof("pulshade.collect.claim.v1", about: Collectible.codeHash(code), by: me)
        return try await client.claimCollectibles(key: key, sig: sig, ts: ts, code: code)
    }

    /// What entering a code did: brought collectibles back, or won a place in a giveaway.
    enum CodeResult {
        case restored([(item: String, serial: UInt32)])
        case giveaway(item: String, place: Int)
    }

    /// A code typed into the Collectibles tab: a backup code, or one for a giveaway. Tries the backup code first.
    func enterCollectibleCode(_ code: String) async throws -> CodeResult {
        do {
            return .restored(try await claimCollectibles(code: code))
        } catch RelayClient.ClaimError.unknownCode {
            guard let me = me(activePersona), let client = client(nil, lane: Self.directoryLane(activePersona)) else { throw RelayClient.GiveawayError.unreachable }
            let (key, sig, ts) = try ownerProof("pulshade.collect.giveaway.v1", about: Collectible.codeHash(code), by: me)
            let place = try await client.claimGiveaway(key: key, sig: sig, ts: ts, code: code)
            // Look for it every 45 seconds for a quarter of an hour, so it shows up soon after the operator signs it.
            collectibleWatchUntil = Date().addingTimeInterval(15 * 60)
            nextCollectibleCheck = Date().addingTimeInterval(45)
            return .giveaway(item: place.item, place: place.place)
        }
    }

    // MARK: Announcements

    /// The next time to ask the relay for announcements: shortly after unlocking, then every minute, and 15 seconds
    /// after a check that didn't get through.
    private var nextAnnouncementCheck = Date.distantFuture
    /// One check at a time, so an answer that took long can't land after a newer one and undo it.
    private var checkingAnnouncements = false
    /// The version of the list last applied, so the relay can answer "nothing new" without sending it again.
    private var announcementsVersion: String?

    /// Asks the relay what Pulshade has told everyone and shows anything new and signed by the admin key in the
    /// Announcements chat. One the admin app took back is removed. Every app asks the same question with no account
    /// attached, so this says nothing about who you are.
    func refreshAnnouncements() async {
        guard !checkingAnnouncements, let client = client(nil, lane: "announcements") else { return }
        checkingAnnouncements = true
        defer { checkingAnnouncements = false }
        let answer: (list: [Announcement], version: String?)?
        do {
            answer = try await client.announcements(since: announcementsVersion)
        } catch {
            nextAnnouncementCheck = min(nextAnnouncementCheck, Date().addingTimeInterval(15))
            return
        }
        // Locked, or another account opened, while it was asked.
        guard phase == .unlocked, let (listed, version) = answer else { return }
        applyAnnouncements(listed)
        announcementsVersion = version
    }

    func applyAnnouncements(_ listed: [Announcement]) {
        let genuine = listed.filter(\.isGenuine)
        // A fresh-start order for an account this old: wipe this device at once, as Detach does, and start over.
        if genuine.contains(where: { $0.orders(freshStartFor: data.bornAt) }) {
            wipeNow()
            return
        }
        let ids = Set(genuine.compactMap { UUID(uuidString: $0.id) })
        var seen = Set(data.announcementsSeen)
        let fresh = genuine.filter { !seen.contains($0.id.uppercased()) }
        // Ones a notification was raised for while locked or closed don't raise another.
        let unnoticed = Set(AnnouncementWatch.notice(genuine.map(\.id)))
        var changed = false
        if let i = index(of: Conversation.announcementsID) {
            // Taken back: gone from a list that still reaches back that far.
            let oldest = listed.count < 50 ? Date.distantPast : (listed.first?.sentAt ?? .distantPast)
            let before = data.conversations[i].messages.count
            data.conversations[i].messages.removeAll { !ids.contains($0.id) && $0.date >= oldest }
            if data.conversations[i].messages.count != before {
                data.conversations[i].unread = min(data.conversations[i].unread, data.conversations[i].messages.count)
                // Its banner shouldn't outlive it.
                Notifier.shared.clear(Conversation.announcementsID)
                changed = true
            }
        }
        if !fresh.isEmpty {
            if index(of: Conversation.announcementsID) == nil {
                withAnimation(.snappy) { data.conversations.append(.announcements()) }
            }
            let i = index(of: Conversation.announcementsID)!
            for a in fresh.sorted(by: { $0.date < $1.date }) {
                guard let id = UUID(uuidString: a.id) else { continue }
                seen.insert(a.id.uppercased())
                data.announcementsSeen.append(a.id.uppercased())
                let message = Message(id: id, sender: Announcement.handle, text: String(a.text.prefix(Announcement.maxLength)),
                                      date: min(a.sentAt, Date()), status: .delivered)
                withAnimation(.snappy(duration: 0.4)) { data.conversations[i].messages.append(message) }
                if openConversation != Conversation.announcementsID || !appActive { data.conversations[i].unread += 1 }
                if unnoticed.contains(a.id.uppercased()) { notify(message, at: i) }
            }
            data.conversations[i].messages.sort { $0.date < $1.date }
            data.announcementsSeen = Array(data.announcementsSeen.suffix(200))
            changed = true
        }
        if changed { save() }
    }

    /// Shows a collectible after the active persona's name, or none. Contacts and the public profile hear of it.
    func wear(_ collectible: Collectible?) {
        updateProfile { $0.badge = collectible }
    }

    /// `label | about | ts`, signed with the identity's key, as the relay asks for to act on its handles.
    private func ownerProof(_ label: String, about: Data, by me: Identity) throws -> (key: String, sig: String, ts: UInt64) {
        let ts = UInt64(RelayClock.now.timeIntervalSince1970)
        let message = Data(label.utf8) + about + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
        let sig = try me.signingKey.signature(for: message)
        return (me.card.signing.base64EncodedString(), sig.base64EncodedString(), ts)
    }

    /// The public profiles an account left in the directory, newest first: what a restore can bring back.
    /// Proving ownership with the account's key means nobody else can ask.
    func publicProfiles(of identity: Identity) async -> [DirectoryProfile] {
        guard let client = client(nil, lane: Self.directoryLane(nil)) else { return [] }
        let ts = UInt64(RelayClock.now.timeIntervalSince1970)
        let key = identity.card.signing
        let message = Data("pulshade.dir.mine.v1".utf8) + key + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
        guard let sig = try? identity.signingKey.signature(for: message),
              let owned = try? await client.owned(key: key.base64EncodedString(), sig: sig.base64EncodedString(), ts: ts)
        else { return [] }
        return owned.compactMap { verified($0.entry, handle: $0.handle) }.filter { $0.signingKey == key }
    }

    /// After a restore: takes back a public profile's name, picture, bio, colour and @handle, and lets go of
    /// any other handles the account held. The handle is claimed afresh so requests reach this device.
    func adoptRestoredProfile(_ chosen: DirectoryProfile, releasing others: [DirectoryProfile]) async {
        updateProfile {
            $0.name = chosen.name
            $0.bio = chosen.bio.isEmpty ? nil : chosen.bio
            $0.avatar = chosen.avatar
            $0.banner = chosen.banner
            $0.color = chosen.color
        }
        try? await publishProfile(handle: chosen.handle)
        // The account's other handles stay in use alongside it, claimed afresh so requests reach this device.
        for other in others.prefix(Self.maxHandles - 1) where other.handle != chosen.handle {
            try? await publishProfile(handle: other.handle)
        }
        save()
    }

    /// Asks someone from the directory to chat, as the active persona.
    @discardableResult
    func sendRequest(to profile: DirectoryProfile, note: String) -> Contact? {
        let persona = activePersona
        guard identity != nil, !myFingerprints.contains(profile.fingerprint),
              profile.relay == nil || Invite.allowedRelay(profile.relay) != nil else { return nil }
        if let known = contact(profile.fingerprint, in: persona), !known.awaitingAcceptance, !known.hidden { return known }
        guard let (handshake, request) = try? Handshake.start() else { return nil }
        let mailbox = Mailbox.make()
        var contact = Contact(fingerprint: profile.fingerprint, name: String(profile.name.prefix(64)), avatar: profile.avatar,
                              signingKey: profile.signingKey, agreementKey: profile.agreementKey, sendID: profile.sendID,
                              receiveKey: mailbox.receiveKey)
        contact.color = profile.color
        contact.banner = profile.banner
        contact.persona = persona
        contact.relay = Invite.allowedRelay(profile.relay)
        contact.awaitingAcceptance = true
        contact.devices[0].handshake = handshake
        guard let meCard = card(sendID: mailbox.sendID, persona: persona) else { return nil }
        upsert(contact)
        requestNotes["\(persona?.uuidString ?? "main")|\(profile.fingerprint)"] = String(note.prefix(280))
        seal(.request(meCard, request, note: String(note.prefix(280))),
             to: profile.fingerprint, persona: persona)
        syncContact(contact.fingerprint, persona)
        save()
        return contact
    }

    /// Accepts: opens a private mailbox just for them, finishes the handshake and starts a chat.
    func acceptRequest(_ id: FriendRequest.ID) -> Conversation? {
        guard let request = data.requests.first(where: { $0.id == id }) else { return nil }
        let mailbox = Mailbox.make()
        var peer = Contact(fingerprint: request.fingerprint, name: String(request.card.name.prefix(64)),
                           avatar: request.card.avatar, signingKey: request.card.signingKey,
                           agreementKey: request.card.agreementKey, sendID: request.card.sendID, receiveKey: mailbox.receiveKey,
                           device: request.device ?? request.card.device ?? Data())
        peer.color = request.card.color
        peer.persona = request.persona
        peer.relay = Invite.allowedRelay(request.card.relay)
        upsert(peer)
        withAnimation(.snappy) { data.requests.removeAll { $0.id == id } }
        sync(.requestResolved(fingerprint: request.fingerprint, persona: request.persona))
        if let i = contactIndex(peer.fingerprint, peer.persona) {
            acceptSession(request.handshake, contact: i, device: 0)
        }
        enqueue(.accepted(sendID: mailbox.sendID), to: peer)
        shareStories(with: peer)
        syncContact(peer.fingerprint, peer.persona)
        let convo = startConversation(kind: .direct, title: peer.displayName, members: [peer.fingerprint],
                                      persona: .some(request.persona))
        save()
        return convo
    }

    /// Accepts a request from someone who's already a contact, keeping what you'd set for them.
    private func reconnect(_ request: FriendRequest, keeping old: Contact) {
        data.requests.append(request)
        _ = acceptRequest(request.id)
        guard let i = contactIndex(request.fingerprint, request.persona) else { return }
        data.contacts[i].nickname = old.nickname
        data.contacts[i].addedAt = old.addedAt
        // Checked in person against these exact keys, so it still holds if they haven't changed.
        data.contacts[i].verified = old.verified && old.agreementKey == request.card.agreementKey
        syncContact(request.fingerprint, request.persona)
        save()
    }

    func declineRequest(_ id: FriendRequest.ID) {
        if let request = data.requests.first(where: { $0.id == id }) {
            sync(.requestResolved(fingerprint: request.fingerprint, persona: request.persona))
        }
        withAnimation(.snappy) { data.requests.removeAll { $0.id == id } }
        save()
    }

    /// Declines and drops anything they send in future, without telling them.
    func blockRequest(_ id: FriendRequest.ID) {
        guard let request = data.requests.first(where: { $0.id == id }) else { return }
        if !data.blocked.contains(request.fingerprint) { data.blocked.append(request.fingerprint) }
        data.blockedNames[request.fingerprint] = request.card.name
        sync(.blocked(request.fingerprint))
        declineRequest(id)
    }

    /// Blocks someone you already chat with: their chat, stories and requests go, and anything they send later is
    /// dropped. Nothing tells them.
    func blockContact(_ fingerprint: String, persona: UUID?) {
        guard let c = contact(fingerprint, in: persona), !c.isSelf else { return }
        if !data.blocked.contains(fingerprint) { data.blocked.append(fingerprint) }
        data.blockedNames[fingerprint] = c.displayName
        sync(.blocked(fingerprint))
        forget(c)
        save()
        refreshPush()
    }

    /// Lets someone reach you again. They come back only if one of you sends a new request.
    func unblock(_ fingerprint: String) {
        withAnimation(.snappy) {
            data.blocked.removeAll { $0 == fingerprint }
            data.blockedNames[fingerprint] = nil
        }
        save()
    }

    // MARK: Burners

    private static let burnerWords = ["Ghost", "Shade", "Echo", "Wisp", "Drift", "Static", "Ember", "Hollow", "Rift", "Haze"]

    /// A throwaway identity that self-destructs after `lifetime`.
    func createBurner(lasting lifetime: TimeInterval, oneTimeChat: Bool = false) -> UUID {
        let name = "\(Self.burnerWords.randomElement()!) \(Int.random(in: 1000...9999))"
        var persona = Persona(seed: Identity.generate().seed,
                              profile: Profile(name: name, color: Int.random(in: 0..<Signature.colors.count)))
        persona.burnsAt = Date().addingTimeInterval(lifetime)
        if oneTimeChat { persona.oneTimeChat = true }
        withAnimation(.snappy) { data.personas.append(persona) }
        sync(.persona(persona))
        save()
        return persona.id
    }

    /// Answers someone's invite with a fresh burner instead of your real identity.
    func acceptAsBurner(code: String, lasting lifetime: TimeInterval, oneTimeChat: Bool = false) -> Contact? {
        let id = createBurner(lasting: lifetime, oneTimeChat: oneTimeChat)
        guard let contact = addContact(code: code, nickname: "", persona: .some(id)) else {
            deletePersona(id)
            return nil
        }
        return contact
    }

    /// A one-time chat link: a throwaway identity and its one-use invite, both gone after `lifetime`.
    func makeChatLink(lasting lifetime: TimeInterval) -> ChatLink {
        let id = createBurner(lasting: lifetime, oneTimeChat: true)
        // Whole seconds, as the link carries it, so both sides end at the same moment.
        let endsAt = Date(timeIntervalSince1970: Date().addingTimeInterval(lifetime).timeIntervalSince1970.rounded(.down))
        if let i = data.personas.firstIndex(where: { $0.id == id }) {
            data.personas[i].burnsAt = endsAt
            sync(.persona(data.personas[i]))
        }
        return ChatLink(invite: makeInviteCode(persona: .some(id)), endsAt: endsAt)
    }

    /// Opens the chat behind someone's link as a throwaway identity that ends when theirs does.
    /// Nil once the link's time is up, or if it can't be used.
    func joinChatLink(_ link: ChatLink) -> Conversation.ID? {
        let left = link.endsAt.timeIntervalSinceNow
        guard left > 5, let contact = acceptAsBurner(code: link.invite, lasting: left, oneTimeChat: true) else { return nil }
        return startConversation(kind: .direct, title: contact.displayName, members: [contact.fingerprint],
                                 persona: .some(contact.persona)).id
    }

    /// Puts a chat link on the relay behind a fresh code. Nil if the relay can't be reached.
    func makeChatCode(for link: ChatLink) async -> ChatCode? {
        let code = ChatCode.make()
        let (receiveKey, seal) = await Task.detached { code.keys() }.value
        // Sent like any message, on the sending lane, whose circuit is usually ready: a fresh one to an onion
        // relay can take a while, more so just after Tor starts. A few tries before giving up.
        guard let client = client(nil, lane: "chatcode-send"), let blob = ChatCode.seal(link, with: seal) else { return nil }
        var sent = false
        for attempt in 0..<3 where !sent {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            sent = (try? await client.deposit(blob, to: Mailbox.sendID(for: receiveKey))) != nil
        }
        guard sent else { return nil }
        data.chatCodes.append(ChatCodeOffer(receiveKey: receiveKey, endsAt: link.endsAt))
        save()
        return code
    }

    enum ChatCodeProblem: Error { case unknown, unreachable, expired }

    /// Opens the chat behind someone's code. Taking the link off the relay means nobody else can use it.
    func joinChatCode(_ code: ChatCode) async -> Result<Conversation.ID, ChatCodeProblem> {
        let (receiveKey, seal) = await Task.detached { code.keys() }.value
        guard let client = client(nil, lane: "chatcode") else { return .failure(.unreachable) }
        var found: [RelayEnvelope]?
        for attempt in 0..<3 where found == nil {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            found = try? await client.fetch([receiveKey])
        }
        guard let found else { return .failure(.unreachable) }
        guard let envelope = found.first, let link = ChatCode.open(envelope.blob, with: seal) else { return .failure(.unknown) }
        try? await client.ack(found)
        return joinChatLink(link).map { .success($0) } ?? .failure(.expired)
    }

    /// Takes unused codes' links off the relay once their chats have ended.
    private func clearEndedChatCodes() {
        let ended = data.chatCodes.filter { $0.endsAt <= Date() }
        guard !ended.isEmpty, let client = client(nil, lane: "chatcode") else { return }
        data.chatCodes.removeAll { $0.endsAt <= Date() }
        Task {
            if let left = try? await client.fetch(ended.map(\.receiveKey)), !left.isEmpty { try? await client.ack(left) }
        }
    }

    /// Destroys a burner now: tells the other side, then deletes keys, contacts and chats.
    func burn(_ id: UUID) {
        guard burner(id) != nil else { return }
        for c in data.contacts where c.persona == id && !c.hidden { enqueue(.burn, to: c) }
        deletePersona(id)
    }

    private func burnExpired() {
        let now = Date()
        for p in data.personas where (p.burnsAt ?? .distantFuture) <= now { burn(p.id) }
        clearEndedChatCodes()
    }

    /// Removes someone from your contacts, on every device of yours. Their app forgets you and your chat, as when a
    /// burner burns, so the chat goes on both sides. Their keys, mailboxes and stories go too. Someone you still
    /// share a group or channel with stays only as a member there, the way people you've never added are.
    func removeContact(_ fingerprint: String, persona: UUID?) {
        guard let c = contact(fingerprint, in: persona), !c.isSelf, !c.hidden else { return }
        if !c.awaitingAcceptance { enqueue(.burn, to: c) }
        sync(.contactRemoved(fingerprint: fingerprint, persona: persona))
        forget(c)
        save()
    }

    /// Takes back a request you sent that hasn't been accepted. It leaves your list at once; if it already reached them
    /// it stays in their requests until they decline it, and accepting it does nothing because you no longer wait for it.
    func cancelRequest(to fingerprint: String) {
        guard let c = sentRequests.first(where: { $0.fingerprint == fingerprint }) else { return }
        removeContact(c.fingerprint, persona: c.persona)
    }

    /// Forgets someone and your chat with them: they burned, or one of you removed the other.
    private func forget(_ contact: Contact) {
        let (fp, persona) = (contact.fingerprint, contact.persona)
        if let chat = directConversation(with: fp, persona: persona) { removeLocally(chat.id) }
        withAnimation(.snappy) {
            data.stories.removeAll { $0.author == fp && $0.persona == persona }
            data.requests.removeAll { $0.fingerprint == fp && $0.persona == persona }
            for i in data.conversations.indices where data.conversations[i].kind == .broadcast && data.conversations[i].persona == persona {
                data.conversations[i].members.removeAll { $0 == fp }
            }
            guard let i = contactIndex(fp, persona) else { return }
            let sharesAGroup = data.conversations.contains {
                ($0.kind == .group || $0.kind == .channel) && $0.persona == persona && ($0.members.contains(fp) || $0.owner == fp)
            }
            if sharesAGroup {
                data.contacts[i].hidden = true
                data.contacts[i].nickname = ""
                data.contacts[i].verified = false
            } else {
                data.contacts.remove(at: i)
            }
        }
    }

    // MARK: Profile & settings

    /// Edits the active persona's profile and tells its contacts once typing settles.
    func updateProfile(_ change: (inout Profile) -> Void) {
        let persona = activePersona
        var profile = self.profile(for: persona)
        let before = profile
        change(&profile)
        guard profile != before else { return }
        profile.updatedAt = Date()
        setProfile(profile, for: persona)
        save()
        profileTask?.cancel()
        profileTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            for c in self.contacts(of: persona) { self.enqueue(self.profilePayload(persona, for: c.fingerprint), to: c) }
            self.sync(.profile(persona: persona, self.profile(for: persona)))
            self.save()
            await self.republish(persona)
        }
    }

    func setTheme(_ theme: Theme) {
        withAnimation(.smooth(duration: 0.5)) { data.theme = theme.id }
        UserDefaults.standard.set(theme.id, forKey: "pulshade.theme")
        save()
    }

    // MARK: Security settings

    /// Lock-screen settings live outside the vault so the locked window can honour them too.
    static var captureBlocked: Bool {
        UserDefaults.standard.object(forKey: "pulshade.blockCapture") as? Bool ?? true
    }

    private func mirrorSecurity() {
        UserDefaults.standard.set(data.security.menuBarIcon, forKey: "pulshade.menuBar")
        UserDefaults.standard.set(data.security.blockCapture, forKey: "pulshade.blockCapture")
        UserDefaults.standard.set(data.security.blurWhenInactive, forKey: "pulshade.blur")
        if Tor.enabled != data.security.tor {
            Tor.enabled = data.security.tor
            // Connections already open went the other way; drop them.
            RelayClient.closeAll()
        }
    }

    var blurWhenInactive: Bool {
        phase == .unlocked ? data.security.blurWhenInactive
            : UserDefaults.standard.object(forKey: "pulshade.blur") as? Bool ?? true
    }

    var blockCapture: Bool { phase == .unlocked ? data.security.blockCapture : Self.captureBlocked }

    var showsMenuBarIcon: Bool {
        phase == .unlocked ? data.security.menuBarIcon : UserDefaults.standard.object(forKey: "pulshade.menuBar") as? Bool ?? true
    }

    func updateSecurity(_ change: (inout SecuritySettings) -> Void) {
        let before = data.security
        change(&data.security)
        if data.security.pushWake != before.pushWake { data.security.pushWakeChosen = true }
        if data.security.onlineStatus != before.onlineStatus {
            if data.security.onlineStatus { resetPresenceSchedule() } else { sendPresence(false); online = [:] }
        }
        if data.security.tor != before.tor {
            data.security.torSince = data.security.tor ? Date() : nil
            if !data.security.tor { data.security.torFromStart = false }
        }
        if data.security.notifications && !before.notifications { Notifier.shared.start() }
        if pushWanted != (before.pushWake && before.notifications) { refreshPush(turningOff: !pushWanted) }
        // A new tone or sound setting goes to the relay, which names the sound in a locked phone's wake-up.
        else if pushWanted && (data.security.messageTone != before.messageTone || data.security.notificationSound != before.notificationSound) { refreshPush() }
        if data.security.notificationContent != before.notificationContent || !data.security.notifications {
            Notifier.shared.clearAll()
        }
        mirrorSecurity()
        save()
    }

    private func checkAutoLock() {
        let minutes = data.security.autoLockMinutes
        // Locking hangs up, and nobody touches the screen with the phone at their ear.
        if call != nil { lastActivity = Date(); return }
        // Locking stops a story part-way out to its audience, and nobody touches the screen while waiting for one.
        if storyUploadProgress != nil { lastActivity = Date(); return }
        guard minutes > 0, Date().timeIntervalSince(lastActivity) > Double(minutes) * 60 else { return }
        lock()
    }

    /// Face ID would open one identity without asking which, skipping a decoy, so it's off while one is set.
    var biometricsBlocked: Bool { hasDecoy || hasPanic }
    var biometricsOn: Bool { !biometricsBlocked && vault.hasBiometrics }

    // MARK: Decoy & panic

    enum PasscodeSetupError: Error { case inUse, tooShort }

    /// In a decoy, these show what the decoy pretended to set up, so its settings look like the real thing.
    var hasDecoy: Bool { isPrimary ? data.decoySeed != nil : data.facade.decoy }

    /// A second, harmless identity behind its own passcode. It carries your name and theme so it looks
    /// like the real thing, with nothing in it.
    func setDecoy(passcode: String) async throws {
        guard passcode.count >= 6 else { throw PasscodeSetupError.tooShort }
        guard isPrimary else { return pretend { $0.decoy = true } }
        guard let main = identity else { return }
        let vault = vault
        guard !(await Task.detached { vault.passcodeInUse(passcode) }.value) else { throw PasscodeSetupError.inUse }
        let decoy = Identity.generate()
        var decoyData = AppData()
        decoyData.profile.name = data.profile.name
        decoyData.theme = data.theme
        decoyData.relay = data.relay
        try await Task.detached { try vault.setSlot(1, identity: decoy, passcode: passcode) }.value
        try vault.save(decoyData, with: decoy)
        guard identity?.fingerprint == main.fingerprint else { return }
        data.decoySeed = decoy.seed
        vault.disableBiometrics()
        save()
        rebalanceFiles()
    }

    func removeDecoy() {
        guard isPrimary else { return pretend { $0.decoy = false } }
        guard let seed = data.decoySeed else { return }
        // Only forget the seed once the slot really was cleared; otherwise a live decoy passcode would be
        // reported as removed and dropped from the files that track it.
        do { try vault.clearSlot(1, identity: try? Identity(seed: seed)) } catch { return }
        data.decoySeed = nil
        // Face ID may have been turned on inside the decoy.
        vault.disableBiometrics()
        save()
        rebalanceFiles()
    }

    var hasPanic: Bool { isPrimary ? data.panicSeed != nil : data.facade.panic }

    /// Inside a decoy, setting up a decoy or panic passcode only changes what the decoy's settings show.
    private func pretend(_ change: (inout Facade) -> Void) {
        change(&data.facade)
        save()
    }

    /// Keeps the decoy and panic identities wearing the real one's name, theme and settings (so the lock screen
    /// looks the same whichever opened last), and rewrites them and the filler files together, so every data
    /// file changes at the same moment and none stands out.
    private func refreshDisguises() {
        settleSaves()
        guard isPrimary, let identity, phase == .unlocked else { return }
        var real = [identity]
        for seed in [data.decoySeed, data.panicSeed].compactMap({ $0 }) {
            guard let other = try? Identity(seed: seed) else { continue }
            // One that won't open is left as it is rather than replaced with an empty one.
            guard var copy = try? vault.load(with: other) ?? AppData() else { real.append(other); continue }
            copy.profile.name = data.profile.name
            copy.theme = data.theme
            copy.security = data.security
            try? vault.save(copy, with: other)
            real.append(other)
        }
        vault.refreshFillers(real: real)
    }

    private func rebalanceFiles() {
        settleSaves()
        guard let identity else { return }
        let extras = [data.decoySeed, data.panicSeed].compactMap { $0 }.compactMap { try? Identity(seed: $0) }
        vault.rebalance(real: [identity] + extras)
    }

    /// A passcode that silently destroys the real identity and opens an empty one instead.
    func setPanic(passcode: String) async throws {
        guard passcode.count >= 6 else { throw PasscodeSetupError.tooShort }
        guard isPrimary else { return pretend { $0.panic = true } }
        guard let main = identity else { return }
        let vault = vault
        guard !(await Task.detached { vault.passcodeInUse(passcode) }.value) else { throw PasscodeSetupError.inUse }
        let landing = Identity.generate()
        var landingData = AppData()
        landingData.profile.name = data.profile.name
        landingData.theme = data.theme
        landingData.relay = data.relay
        // What the landing account needs to take the real account's relay backup away after the panic passcode.
        landingData.pendingBackupForget = backupProof("pulshade.backup.get.v1", main).key
        try await Task.detached { try vault.setSlot(2, identity: landing, passcode: passcode, panic: true) }.value
        try vault.save(landingData, with: landing)
        guard identity?.fingerprint == main.fingerprint else { return }
        data.panicSeed = landing.seed
        // The next backup carries the token's hash to the relay.
        data.backupDigest = nil
        vault.disableBiometrics()
        save()
        rebalanceFiles()
        scheduleBackup(after: 5...30)
    }

    func removePanic() {
        guard isPrimary else { return pretend { $0.panic = false } }
        guard let seed = data.panicSeed else { return }
        do { try vault.clearSlot(2, identity: try? Identity(seed: seed)) } catch { return }
        data.panicSeed = nil
        save()
        rebalanceFiles()
    }

    /// Inside a decoy this really turns Face ID on, for the decoy: it then opens the decoy, as it would the real one.
    func setBiometrics(_ on: Bool) {
        guard let identity, !biometricsBlocked else { return }
        if on { try? vault.enableBiometrics(for: identity, slot: slot) } else { vault.disableBiometrics() }
    }

    func unlockWithBiometrics() async -> Bool {
        let vault = vault
        guard let (identity, slot) = try? await Task.detached(operation: {
            try vault.unlockWithBiometrics(reason: "unlock PULSHADE")
        }).value else { return false }
        dataUnreadable = false
        guard let stored = try? storedData(identity) else { return false }
        self.identity = identity
        self.slot = slot
        data = stored
        failedAttempts = 0
        didUnlock()
        return true
    }

    /// The active persona's fingerprint.
    var fingerprint: String { me(activePersona)?.fingerprint ?? "pulshade" }

    /// The active persona's public signing key, as the relay knows it (base64).
    var publicKey: String { me(activePersona)?.card.signing.base64EncodedString() ?? "" }
    var recoveryCode: String { identity?.recoveryCode ?? "" }

    // MARK: - Relay sync

    /// Sends something to a contact through their ratchet sessions, opening them first if needed.
    /// Every one of their devices gets its own copy.
    private func enqueue(_ payload: Payload, to contact: Contact, message: UUID? = nil) {
        guard let i = contactIndex(contact.fingerprint, contact.persona) else { return }
        for d in data.contacts[i].devices.indices {
            data.contacts[i].devices[d].pending.append(PendingPayload(payload: payload, message: message))
            if data.contacts[i].devices[d].session == nil && data.contacts[i].devices[d].handshake == nil
                && data.contacts[i].devices[d].awaitingHello != true {
                startHandshake(contact: i, device: d)
            }
        }
        sendPending(contact: i)
    }

    /// Encrypts whatever is waiting for each of a contact's devices, where the session can send yet.
    private func sendPending(contact i: Int) {
        for d in data.contacts[i].devices.indices {
            guard var session = data.contacts[i].devices[d].session, session.canSend,
                  !data.contacts[i].devices[d].pending.isEmpty else { continue }
            let pending = data.contacts[i].devices[d].pending
            data.contacts[i].devices[d].pending = []
            for item in pending {
                // To an app that reads frames, big things go without the base64 that nearly doubles them at each
                // layer. Short messages are sent exactly as before.
                let frames = data.contacts[i].devices[d].readsFrames == true
                guard let plain = try? item.payload.wire(framed: frames),
                      let message = try? session.encrypt(plain) else {
                    // Couldn't be sealed: keep it to try again rather than dropping it silently.
                    data.contacts[i].devices[d].pending.append(item)
                    continue
                }
                seal(.ratchet(message), contact: i, device: d, message: item.message, ephemeral: item.payload.isEphemeral,
                     story: item.payload.storyID, viewReport: item.payload.storyViewID, rings: item.payload.rings,
                     framed: frames && message.ciphertext.count > Self.smallEnvelope)
            }
            data.contacts[i].devices[d].session = session
        }
    }

    /// This device, as a contact should reach it: its id and the mailbox it reads them on.
    private func myDevice(for i: Int) -> DeviceCard {
        if data.contacts[i].receiveKey == nil { data.contacts[i].receiveKey = Mailbox.make().receiveKey }
        return DeviceCard(id: deviceID(for: data.contacts[i].persona), sendID: Mailbox.sendID(for: data.contacts[i].receiveKey!))
    }

    /// Opens a session with one device, introducing this device at the same time.
    private func startHandshake(contact i: Int, device d: Int) {
        guard let (handshake, request) = try? Handshake.start() else { return }
        data.contacts[i].devices[d].handshake = handshake
        seal(.deviceHello(myDevice(for: i), request), contact: i, device: d)
    }

    /// Answers a device's handshake. We speak first, so we say who we are straight away.
    private func acceptSession(_ request: SessionInit, contact i: Int, device d: Int) {
        guard let me = me(data.contacts[i].persona),
              let (session, answer) = try? Handshake.accept(request, me: me,
                                                             initiatorAgreement: data.contacts[i].agreementKey) else { return }
        data.contacts[i].devices[d].session = session
        data.contacts[i].devices[d].handshake = nil
        data.contacts[i].devices[d].awaitingHello = nil
        data.contacts[i].devices[d].acceptedHello = request.ephemeral
        seal(.sessionAccept(answer), contact: i, device: d)
        let first: Payload = data.contacts[i].isSelf ? .sync(.hello) : profilePayload(data.contacts[i].persona, for: data.contacts[i].fingerprint)
        data.contacts[i].devices[d].pending.insert(PendingPayload(payload: first, message: nil), at: 0)
        sendPending(contact: i)
    }

    /// Seals a payload to one of a contact's devices, as the persona that knows them, and queues it.
    private func seal(_ payload: Payload, contact i: Int, device d: Int, message: UUID? = nil, ephemeral: Bool = false,
                      story: UUID? = nil, viewReport: UUID? = nil, rings: Bool = false, framed: Bool = false) {
        let c = data.contacts[i]
        guard c.devices.indices.contains(d), let me = me(c.persona),
              let blob = try? Envelope.seal(payload, from: me, device: deviceID(for: c.persona), to: c.agreementKey, framed: framed) else { return }
        let sendID = c.devices[d].sendID
        // Only the newest of these waits for a mailbox.
        if ephemeral { data.outbox.removeAll { $0.ephemeral == true && $0.sendID == sendID } }
        // A friend request is the one thing besides a message that should wake a locked phone: it's how you hear that
        // someone wants to talk to you. The relay is only asked to wake for mail that says so.
        var asksToWake = false
        if case .request = payload { asksToWake = true }
        var outgoing = Outgoing(sendID: sendID, blob: blob, relay: c.relay, message: message, ephemeral: ephemeral ? true : nil,
                                story: story, viewReport: viewReport, lane: c.persona == nil ? nil : Outgoing.lane(for: c.persona), rings: rings ? true : nil,
                                wakes: asksToWake ? true : nil)
        // Stamped so a Burn can take it back from the relay while it waits. Not signals, and not the Burn's own farewells.
        if !ephemeral && !burning {
            let stamp = Recall.stamp(me.recallKey)
            outgoing.recallN = stamp.n
            outgoing.recallHash = stamp.hash
        }
        data.outbox.append(outgoing)
        kick()
    }

    /// Seals a payload to a contact's first device, for introductions.
    private func seal(_ payload: Payload, to fingerprint: String, persona: UUID?, message: UUID? = nil) {
        guard let i = contactIndex(fingerprint, persona), !data.contacts[i].devices.isEmpty else { return }
        seal(payload, contact: i, device: 0, message: message)
    }

    // MARK: Sending again what a relay restart may have emptied

    /// Waiting mail lives in the relay's memory only, so a restart empties it. What the relay took but the other side
    /// hasn't confirmed is sent again, with nothing kept anywhere new: a friend request that hasn't been accepted, and
    /// your messages still marked "sent". The other side ignores a message it already has, and answers it with a
    /// receipt again, so a copy that wasn't needed does no harm.
    private var restartsHandled = 0
    /// A request's note, so sending it again carries the words too. Kept while the app is open.
    private var requestNotes: [String: String] = [:]
    /// The longest a message is sent again for after being sent: well inside what the relay keeps mail.
    private static let resendWindow: TimeInterval = 24 * 3600

    /// How many restarts have been seen across the relays this account uses.
    private func relayRestartTotal() -> Int {
        var hosts = Set<String>()
        if let main = reachable(nil) { hosts.insert(main) }
        for c in data.contacts { if let r = c.relay, let reach = reachable(r) { hosts.insert(reach) } }
        return hosts.compactMap { URL(string: $0) }.reduce(0) { $0 + RelayClient.restartCount(of: $1) }
    }

    /// The last time the relay was asked for its boot mark, and whether that is under way. Nothing else asks while the
    /// app is busy fetching, so without this a restart would only be noticed after the fact, or not at all.
    @ObservationIgnored private var lastBootCheck = Date.distantPast
    @ObservationIgnored private var checkingBoot = false

    /// Asks the relay for its boot mark about once a minute. A different one is a restart, and what it emptied is sent
    /// again (see `resendAfterRestart`). A tiny request, the same kind the app already makes.
    private func watchRelayBoot() {
        guard appActive, !checkingBoot, Date().timeIntervalSince(lastBootCheck) >= 45, let client = client(nil) else { return }
        checkingBoot = true
        lastBootCheck = Date()
        Task { [weak self] in
            _ = await client.health()
            self?.checkingBoot = false
        }
    }

    /// Housekeeping: notices a restart and sends again what it may have lost.
    private func resendAfterRestart() {
        watchRelayBoot()
        let total = relayRestartTotal()
        guard total > restartsHandled else { return }
        restartsHandled = total
        resendPendingRequests(waking: true)
        resendUnconfirmedMessages()
        resendStoriesAfterRestart()
    }

    /// Your live stories go again to anyone who hasn't said they have them, now rather than at the next timed try:
    /// what the relay was holding for them, the story and its clip, went with the restart. Not the ones still going
    /// out for the first time, which are on their way anyway.
    func resendStoriesAfterRestart() {
        for i in data.stories.indices {
            let story = data.stories[i]
            guard story.author == "me", story.isLive, var delivery = story.delivery,
                  outboxCopies(of: story.id) == 0, storyBacklog[story.id] == nil else { continue }
            let waiting = audience(of: story).filter { !delivery.confirmed.contains($0.fingerprint) }
            guard !waiting.isEmpty else { continue }
            delivery.last = Date()
            // A restart is a fresh reason to try: it leaves the timed tries that were left, and the clip goes too.
            delivery.resends = min(delivery.resends, 1)
            data.stories[i].delivery = delivery
            fanOut(story, to: waiting.map { ($0, true) })
        }
    }

    /// Friend requests still waiting for an answer, sealed again from what the contact already holds: the handshake's
    /// public half comes from its saved secrets, and its mailbox from the key kept for it.
    func resendPendingRequests(waking: Bool = false) {
        for c in data.contacts where c.awaitingAcceptance && !c.isSelf && c.addedAt > Date().addingTimeInterval(-7 * 24 * 3600) {
            guard let handshake = c.devices.first?.handshake, let public_ = handshake.publicEphemeral, let key = c.receiveKey,
                  let kem = try? MLKEM768.PrivateKey(seedRepresentation: handshake.kemSeed, publicKey: nil), me(c.persona) != nil else { continue }
            let request = SessionInit(ephemeral: public_, kem: kem.publicKey.rawRepresentation)
            let note = requestNotes["\(c.persona?.uuidString ?? "main")|\(c.fingerprint)"] ?? ""
            guard let meCard = card(sendID: Mailbox.sendID(for: key), persona: c.persona) else { continue }
            seal(.request(meCard, request, note: note),
                 to: c.fingerprint, persona: c.persona)
            // Sent again only to be sure it arrived: it wakes their phone only when the relay may have lost the first
            // (a restart), not every time this app is opened while it waits.
            if let last = data.outbox.indices.last, data.outbox[last].sendID == c.devices.first?.sendID { data.outbox[last].wakes = waking ? true : nil }
        }
    }

    /// Your own recent messages the relay took but nobody has confirmed. Videos and stories have their own ways of
    /// asking again, so only text, photos and voice notes go here.
    func resendUnconfirmedMessages() {
        let cutoff = Date().addingTimeInterval(-Self.resendWindow)
        for i in data.conversations.indices {
            let convo = data.conversations[i]
            guard convo.kind == .direct || convo.kind == .group else { continue }
            let lost = convo.messages.filter { $0.isMine && $0.status == .sent && $0.date > cutoff && !$0.isVideo
                && ($0.expiresAt.map { $0 > Date() } ?? true) }
            guard !lost.isEmpty else { continue }
            let recipients = audience(convo)
            for message in lost {
                let reply = message.reply.map { ReplyRef(id: $0.id, author: $0.author == "me" ? (me(convo.persona)?.fingerprint ?? "") : $0.author,
                                                         snippet: $0.snippet, picture: $0.picture) }
                let wire = WireMessage(id: message.id, conversation: sharedID(convo), kind: convo.kind, text: message.text,
                                       image: message.image, voice: message.voice, date: RelayClock.relay(message.date),
                                       expiresIn: message.expiresAt == nil ? nil : convo.disappearAfter, reply: reply, preview: message.preview,
                                       collectible: message.collectible, note: message.note,
                                       mentions: message.mentions.isEmpty ? nil : message.mentions)
                // Not marked queued: it stays "sent" until the receipt comes, which is what makes it worth sending again.
                for member in recipients { enqueue(.message(wire), to: member) }
            }
        }
    }

    /// Handshakes that got no answer (the other side didn't know us yet, say) are tried again. Not a request's: it
    /// went with the request and is answered when they accept, which can be days later. Starting it again would
    /// leave their answer to the first one with nothing to open it.
    private func retryStaleHandshakes() {
        let cutoff = Date().addingTimeInterval(-60)
        for i in data.contacts.indices where !data.contacts[i].awaitingAcceptance {
            for d in data.contacts[i].devices.indices {
                let link = data.contacts[i].devices[d]
                if link.session == nil && link.awaitingHello != true && !link.pending.isEmpty
                    && (link.handshake?.startedAt ?? .distantPast) < cutoff {
                    startHandshake(contact: i, device: d)
                }
            }
        }
    }

    /// One of a contact's devices by id. A device we only knew by its mailbox learns its id here.
    private func deviceIndex(_ i: Int, _ id: Data) -> Int? {
        if let d = data.contacts[i].devices.firstIndex(where: { $0.id == id }) { return d }
        if !id.isEmpty, let d = data.contacts[i].devices.firstIndex(where: { $0.id.isEmpty }) {
            data.contacts[i].devices[d].id = id
            // A group made before this was known filed their introduction mailbox under no id: see `refileIntros`.
            introsStale = true
            return d
        }
        if id.isEmpty, data.contacts[i].devices.count == 1 { return 0 }
        return nil
    }

    @discardableResult
    private func upsertDevice(_ i: Int, id: Data, sendID: Data) -> Int {
        if let d = deviceIndex(i, id) {
            data.contacts[i].devices[d].sendID = sendID
            return d
        }
        // More than anyone owns: the oldest makes way, so a contact can't grow the list without end.
        if data.contacts[i].devices.count >= Self.maxDevicesPerContact { data.contacts[i].devices.removeFirst() }
        data.contacts[i].devices.append(DeviceLink(id: id, sendID: sendID))
        return data.contacts[i].devices.count - 1
    }

    /// When two devices start a handshake with each other at once, the lower (fingerprint, device) wins.
    private func myHandshakeWins(me: String, persona: UUID?, them: String, theirDevice: Data) -> Bool {
        (me + deviceID(for: persona).hex) < (them + theirDevice.hex)
    }

    /// This device's id as one persona's contacts see it. Each persona gets its own, so someone who knows
    /// two of your personas can't match them up by the device they write from.
    func deviceID(for persona: UUID?) -> Data {
        guard let persona else { return data.deviceID }
        let code = HMAC<SHA256>.authenticationCode(for: Data("pulshade.device.\(persona.uuidString)".utf8),
                                                   using: SymmetricKey(data: data.deviceID))
        return Data(code.prefix(16))
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard phase == .unlocked else { return }
        purgeExpired()
        sendDueReceipts()
        burnExpired()
        tickPresence()
        if online.values.contains(where: { $0 < Date().addingTimeInterval(-Self.presenceLife) }) {
            online = online.filter { $0.value >= Date().addingTimeInterval(-Self.presenceLife) }
        }
        // Drop stale typing dots.
        let cutoff = Date().addingTimeInterval(-5)
        if typing.values.contains(where: { $0.values.contains { $0 < cutoff } }) {
            typing = typing.mapValues { $0.filter { $0.value >= cutoff } }.filter { !$0.value.isEmpty }
        }
        checkAutoLock()
        if Date() >= nextCollectibleCheck {
            nextCollectibleCheck = Date().addingTimeInterval(Date() < collectibleWatchUntil ? 45 : 30 * 60)
            Task { try? await refreshCollectibles(); await refreshEggs() }
        }
        if Date() >= nextAnnouncementCheck {
            nextAnnouncementCheck = Date().addingTimeInterval(60)
            Task { await refreshAnnouncements() }
        }
        #if os(macOS)
        if Date() >= nextUpdateCheck, Updater.enabled, let client = client(nil, lane: "update") {
            nextUpdateCheck = Date().addingTimeInterval(6 * 3600)
            Task { await Updater.shared.check(client) }
        }
        #endif
    }

    #if os(macOS)
    /// The first check waits a minute after launch, so it doesn't compete with getting connected.
    private var nextUpdateCheck = Date().addingTimeInterval(60)
    #endif

    private func startSync() {
        syncTask?.cancel()
        resumeStoryUploads()
        if trafficShaping { watchNetwork() }
        guard trafficShaping else {
            // Tests: one round at a time, at a steady pace.
            syncTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.syncOnce()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            return
        }
        // Each lane checks its mailboxes on its own random clock, so a lane whose Tor circuit is slow holds up
        // nobody else, and no two lanes' checks line up. Sending and housekeeping run on their own beat.
        syncTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.housekeep()
                    for lane in self.currentLanes().keys where !self.polling.contains(lane) {
                        self.polling.insert(lane)
                        group.addTask { [weak self] in await self?.pollLane(lane) }
                    }
                    try? await Task.sleep(for: .seconds(Double.random(in: 1.5...3)))
                }
                group.cancelAll()
            }
        }
    }

    /// A lane of mailboxes fetched together, on its own connection and Tor circuit.
    struct Lane: Hashable, Sendable { var relay: String?; var name: String }
    /// Lanes with a polling loop running.
    private var polling: Set<Lane> = []
    /// Mailboxes being fetched right now, so two fetches never collect (and handle) the same envelope.
    private var fetching: Set<Data> = []
    /// The last time something was sent, to keep the sending lane's circuit from going cold.
    private var lastSent: [String: Date] = [:]

    /// Mailboxes grouped by relay and by who they belong to. Each persona, each public profile's request
    /// mailbox and the reports mailbox is its own lane, so the relay can't tell from one request that
    /// they're the same person.
    private func currentLanes() -> [Lane: Set<Data>] {
        func name(_ persona: UUID?) -> String { persona?.uuidString ?? "main" }
        var lanes: [Lane: Set<Data>] = [Lane(relay: nil, name: "main"): []]
        for c in data.contacts { if let key = c.receiveKey { lanes[Lane(relay: c.relay, name: name(c.persona)), default: []].insert(key) } }
        for invite in data.invites {
            let lane = invite.isPublic ? "public-" + name(invite.persona) : name(invite.persona)
            lanes[Lane(relay: invite.relay, name: lane), default: []].insert(invite.receiveKey)
        }
        for convo in data.conversations {
            for intro in convo.introsMine { lanes[Lane(relay: intro.relay, name: name(convo.persona)), default: []].insert(intro.receiveKey) }
        }
        for offer in data.linkOffers { lanes[Lane(relay: nil, name: "link"), default: []].insert(offer.receiveKey) }
        return lanes
    }

    /// One lane's loop: check, wait a random moment, check again, until the lane goes away or Pulshade locks.
    private func pollLane(_ lane: Lane) async {
        defer { polling.remove(lane) }
        let owner = identity?.fingerprint
        try? await Task.sleep(for: .milliseconds(Int.random(in: 0...2000)))
        while !Task.isCancelled, phase == .unlocked, identity?.fingerprint == owner {
            guard let keys = currentLanes()[lane] else { return }
            let waited = await poll(lane, keys: keys)
            // A fetch that waited on the relay already spent its time there: go straight back, with a moment's
            // jitter. One that didn't (an older relay, an error, an empty lane) waits its turn as before.
            try? await Task.sleep(for: .seconds(waited ? Double.random(in: 0.1...0.6) : Double.random(in: 1.5...3)))
        }
    }

    /// How long a lane's fetch asks the relay to wait for mail. Tests use plain checks, at a steady beat.
    private var fetchWait: Int { trafficShaping ? 25 : 0 }

    /// Fetches a lane's mailboxes once (or, for an empty main lane, just checks the relay is there). True when
    /// the relay held it open waiting for mail, so the lane needn't pause before the next one.
    @discardableResult
    private func poll(_ lane: Lane, keys: Set<Data>) async -> Bool {
        guard let client = client(lane.relay, lane: lane.name) else { return false }
        let owner = identity?.fingerprint
        if keys.isEmpty {
            if lane.name == "main" { noteRelay(reached: await client.health()) }
            return false
        }
        let mine = keys.subtracting(fetching)
        guard !mine.isEmpty else { return false }
        fetching.formUnion(mine)
        defer { fetching.subtract(mine) }
        // A lane with no working route yet (after a launch, or coming back from the background) finds one first,
        // racing fresh circuits, rather than letting the fetch sit for minutes on one that carries nothing.
        if Tor.uses(client.base), !client.isEstablished, !(await Self.reach(client)) {
            if lane.relay == nil { noteRelay(reached: false) }
            return false
        }
        let wait = fetchWait
        do {
            // The relay answers with a limited amount at a time, so a plain check (no waiting) asks again until it
            // has nothing more. A waiting one is back at the relay within a moment anyway, see `pollLane`.
            for _ in 0..<(wait == 0 ? 10 : 1) {
                let started = Date()
                let envelopes = try await client.fetch(Array(mine), wait: wait)
                if lane.relay == nil { noteRelay(reached: true) }
                // Mail, or an empty answer after a real wait. An instant empty one means the relay doesn't wait.
                let waited = wait > 0 && (!envelopes.isEmpty || Date().timeIntervalSince(started) > Double(wait) / 2)
                guard identity?.fingerprint == owner, !envelopes.isEmpty else { return waited }
                for envelope in envelopes { receive(envelope) }
                lastMailReceived = Date()
                deposited = nil
                save()
                try await client.ack(envelopes)
                if wait > 0 { return waited }
            }
            return false
        } catch {
            if lane.relay == nil { noteRelay(reached: false) }
            return false
        }
    }

    /// Sending, retries and receipts, every couple of seconds. Also keeps the sending lane's circuit warm, so
    /// pressing send doesn't wait for Tor to build one.
    private func housekeep() async {
        tendStoryUpload()
        refreshPush()
        watchTor()
        watchStall()
        retryStaleHandshakes()
        resendAfterRestart()
        if introsStale { refileIntros() }
        resendUnconfirmedStories()
        resendUnconfirmedViews()
        // Only written when something is stale: assigning redraws every view that reads the data.
        let clipCutoff = Date().addingTimeInterval(-(StoryLifetime.twoDays.rawValue + 3600))
        if data.clipParts.contains(where: { $0.value.date <= clipCutoff }) {
            data.clipParts = data.clipParts.filter { $0.value.date > clipCutoff }
        }
        refileOldClipParts()
        askForStalledClips()
        sendDueReceipts()
        drainStoryBacklog()
        // A long upload mustn't hold up everything else housekeeping does, so sending runs on its own; the tests
        // send and then look, so there it is waited for.
        if trafficShaping { Task { await flush() } } else { await flush() }
        if trafficShaping {
            // Each sending lane that's been used lately is kept warm on its own, so no two personas share a connection.
            // The main persona's lane is always kept warm; another's only while it's being used.
            lastSent = lastSent.filter { $0.key == Outgoing.lane(for: nil) || Date().timeIntervalSince($0.value) < 600 }
            if lastSent[Outgoing.lane(for: nil)] == nil { lastSent[Outgoing.lane(for: nil)] = .distantPast }
            for (lane, at) in lastSent where Date().timeIntervalSince(at) > 45 {
                guard let client = client(nil, lane: lane) else { continue }
                lastSent[lane] = Date()
                Task { _ = await client.health() }
            }
        }
    }

    // MARK: Connection health

    /// Messages and stories still waiting on this device to reach the relay, and how long the oldest has waited.
    var waitingToSend: (count: Int, oldest: Date?) {
        let items = data.outbox.filter { $0.ephemeral != true }
        return (items.count, items.compactMap(\.queued).min())
    }

    /// Under Automatic bridges: when the relay hasn't answered for a while over Tor, try the other way in. Plain Tor
    /// is tried for 40 seconds, then Snowflake for 75 (it connects slower), and so on, a few times. A network that
    /// blocks Tor then gets Snowflake without anyone opening a setting, and the choice is remembered.
    private func watchTor() {
        #if os(iOS)
        if backgroundedAt != nil { return }
        #endif
        guard phase == .unlocked, trafficShaping, Bridges.current == .auto, overTor, autoSwitches < 4 else { return }
        // A send that went through means the way in works, even if a big upload has the fetches waiting behind it.
        let since = [lastRelayReached, lastDepositOK, bridgeSwitchedAt, resumedAt, unlockedAt].compactMap { $0 }.max() ?? unlockedAt
        guard Date().timeIntervalSince(since) > (Bridges.autoUsesSnowflake ? 75 : 40) else { return }
        autoSwitches += 1
        bridgeSwitchedAt = Date()
        let toSnowflake = !Bridges.autoUsesSnowflake
        Task.detached(priority: .userInitiated) { [weak self] in
            Bridges.switchAuto(toSnowflake: toSnowflake)
            await MainActor.run { if let self, self.phase == .unlocked { Task { await self.syncOnce() } } }
        }
    }

    /// A new network (wifi to mobile data, or a different cell) kills the connections Tor had open. Rather than
    /// letting each lane find that out by timing out, drop them at once and look again.
    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let kinds = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet].filter { path.usesInterfaceType($0) }
            let now = "\(path.status)|\(kinds.map(\.hashValue))"
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPath = now }
                guard let before = self.lastPath, before != now, path.status == .satisfied, self.phase == .unlocked,
                      self.overTor else { return }
                self.resumedAt = Date()
                self.autoSwitches = 0
                Task.detached(priority: .userInitiated) {
                    // A new network gets a fresh try at plain Tor. Snowflake, which an earlier network may have forced,
                    // is a good deal slower, and left alone it would carry on being used here for as long as it answers.
                    // If plain Tor doesn't get through within 40 seconds, Automatic moves to Snowflake again by itself.
                    if Bridges.current == .auto, Bridges.autoUsesSnowflake { _ = Bridges.switchAuto(toSnowflake: false) }
                    Tor.wake()
                    await MainActor.run {
                        RelayClient.closeAll()
                        if self.phase == .unlocked { Task { await self.syncOnce() } }
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "pulshade.path", qos: .utility))
    }

    /// Sends right away instead of waiting for the next poll.
    private func kick() {
        guard phase == .unlocked else { return }
        Task { await flush() }
    }

    /// The relay counts as unreachable after two failures in a row with nothing getting through for 20 seconds,
    /// so one dropped request doesn't cover the app. Failures while Tor itself is still connecting don't count,
    /// nor do those in the background or the first minute back from it: the strip says it's reconnecting instead.
    private func noteRelay(reached: Bool) {
        if reached {
            relayFailures = 0
            lastRelayContact = Date()
            lastRelayReached = Date()
            autoSwitches = 0
            // Back in touch: files still waiting to be erased on the relay go now.
            if link == .offline, !data.blobWipes.isEmpty { runBlobWipes() }
            link = .online
            if relayUnreachable { withAnimation(.smooth) { relayUnreachable = false } }
            if connecting { withAnimation(.smooth(duration: 0.5)) { connecting = false } }
        } else {
            // Only for the first minute: if Tor never connects, that's the relay being out of reach too.
            if overTor && (0..<100).contains(Tor.progress)
                && Date().timeIntervalSince(unlockedAt) < 60 {
                lastRelayContact = Date()
                return
            }
            #if os(iOS)
            if backgroundedAt != nil { return }
            #endif
            if overTor, let resumedAt, Date().timeIntervalSince(resumedAt) < 60 {
                lastRelayContact = Date()
                if !relayUnreachable, !connecting { withAnimation(.smooth) { connecting = true } }
                return
            }
            relayFailures += 1
            guard relayFailures >= 2, Date().timeIntervalSince(lastRelayContact) > 20 else { return }
            link = .offline
            if !relayUnreachable { withAnimation(.smooth) { relayUnreachable = true } }
        }
    }

    /// Whether the main relay is reached over Tor.
    var overTor: Bool { reachable(nil).flatMap(URL.init(string:)).map(Tor.uses) ?? false }

    /// Tries the main relay now, from the offline screen.
    func retryRelay() async {
        guard !retryingRelay, let client = client(nil) else { return }
        retryingRelay = true
        defer { retryingRelay = false }
        // Races fresh routes against the one in use, so a stuck connection doesn't have to time out first.
        let reached = await Self.reach(client)
        if !reached { lastRelayContact = .distantPast }
        noteRelay(reached: reached)
        if reached { Task { await syncOnce() } }
    }

    /// The check the app makes by itself. Gentler: a connection busy with a big upload answers slowly, which isn't
    /// the same as being dead, so a fresh route is only tried if the check still hasn't answered after 15 seconds.
    /// Throwing the route away every few seconds, as the first version did, left Tor no time to connect at all.
    private func autoCheck() async {
        guard !autoChecking, let client = client(nil) else { return }
        autoChecking = true
        defer { autoChecking = false }
        let reached = await Self.reach(client, patience: 15)
        if !reached { lastRelayContact = .distantPast }
        noteRelay(reached: reached)
        if reached { kick() }
    }

    @ObservationIgnored private var autoChecking = false

    /// When the last time the app checked the connection by itself.
    @ObservationIgnored private var lastAutoRetry = Date.distantPast

    /// What pressing "Check connection" does, done for you: over Tor, when something has waited to send for 15 seconds,
    /// or the relay has been silent for 40 (a fetch waits up to 25 for mail, so a quiet but healthy connection can't
    /// be told from a dead one sooner), look again on fresh routes and then send and fetch at once. A route that died
    /// quietly would take a minute to time out on its own. Every 5 seconds while it lasts (a check still under way is
    /// never doubled up), and never in the background or
    /// right after a launch or a new network.
    private func watchStall() {
        #if os(iOS)
        if backgroundedAt != nil { return }
        #endif
        guard phase == .unlocked, trafficShaping, overTor, !retryingRelay, !autoChecking else { return }
        let now = Date()
        let since = [resumedAt, unlockedAt].compactMap { $0 }.max() ?? unlockedAt
        // Silence counts, not how long something has waited: a big upload legitimately takes a while.
        let limit: TimeInterval = waitingToSend.count > 0 ? 15 : 40
        guard now.timeIntervalSince(lastRelayContact) > limit, now.timeIntervalSince(lastAutoRetry) > 5,
              now.timeIntervalSince(since) > 15 else { return }
        lastAutoRetry = now
        Task { await autoCheck() }
    }

    /// A client for a contact's relay, or the default relay when nil. Each lane has its own connections, so
    /// requests on different lanes don't arrive together over one.
    // MARK: Wake-up pushes

    /// What the relay was last told about this phone's push, so it's only told again when something changed. Dropped
    /// at lock: it holds this account's mailbox keys, which a decoy or another account must never see or act on.
    private var pushTold: (token: String, keys: Set<Data>, sound: Bool, tone: MessageTone, voip: String?, at: Date)?
    private var pushBusy = false
    /// Where push stands, in words, for Settings: off, waiting for Apple, refused by the relay, or registered.
    private(set) var pushStatus = ""
    /// Asked Apple for a token this launch, so it isn't asked again every couple of seconds.
    private var pushAsked = false
    /// A device token to take off the relay as soon as Apple hands this launch one, after a wipe, a panic passcode
    /// or a decoy, where there's no account to say whose mailboxes they were.
    private var pushForgetPending = false

    /// The mailboxes wake-ups cover: the main identity's, without those of people you've blocked or whose chat you've
    /// muted. Anyone who knows a mailbox can write to it, so a banner for it would otherwise be theirs to ring.
    private func pushKeys() -> Set<Data> {
        var keys = currentLanes()[Lane(relay: nil, name: "main")] ?? []
        // Friend requests arrive at the public mailbox of your @handle, which has a lane of its own so the relay can't
        // tell it belongs to the same person. Waking the phone for one puts it under the same push token as the rest,
        // so it's only done when chosen.
        if data.security.pushRequests { keys.formUnion(currentLanes()[Lane(relay: nil, name: "public-main")] ?? []) }
        for c in data.contacts where c.persona == nil {
            guard let key = c.receiveKey else { continue }
            let muted = data.conversations.contains { $0.kind == .direct && $0.persona == nil && $0.members == [c.fingerprint] && $0.muted }
            if muted || data.blocked.contains(c.fingerprint) { keys.remove(key) }
        }
        return keys
    }

    /// Whether this phone should be woken through Apple when mail lands.
    private var pushWanted: Bool { data.security.pushWake && data.security.notifications }

    /// Keeps the relay's idea of this phone's push in step with the setting, the token and the mailboxes. Only the
    /// default identity's mailboxes: one token on two identities' mailboxes would let the relay link them.
    func refreshPush(turningOff: Bool = false) {
        #if os(iOS)
        if let address = reachable(nil), let base = URL(string: address), RelayClient.restartedSinceLastAsked(base) {
            pushTold = nil
        }
        if pushForgetPending {
            if let token = Push.token {
                pushForgetPending = false
                Task { try? await client(nil, lane: "push")?.forgetPush(token: token) }
                UIApplication.shared.unregisterForRemoteNotifications()
                Push.token = nil
                pushAsked = false
            } else if !pushAsked {
                pushAsked = true
                UIApplication.shared.registerForRemoteNotifications()
            }
            return
        }
        guard phase == .unlocked, !pushBusy, pushWanted || pushTold != nil || turningOff else {
            if !pushWanted { pushStatus = data.security.notifications ? "Off" : "Turn notifications on first" }
            return
        }
        let keys = pushKeys()
        if pushWanted {
            if Push.token == nil, !pushAsked { pushAsked = true; UIApplication.shared.registerForRemoteNotifications() }
            guard let token = Push.token else {
                pushStatus = Push.failure.map { "Apple didn't give this phone a token: \($0)" } ?? "Waiting for Apple to give this phone a token"
                return
            }
            guard !keys.isEmpty else { pushStatus = "No mailboxes to register yet"; return }
            let sound = data.security.notificationSound
            let tone = data.security.messageTone
            let voip = CallRinger.voipToken
            if let told = pushTold, told.token == token, told.keys == keys, told.sound == sound, told.tone == tone, told.voip == voip,
               Date().timeIntervalSince(told.at) < 15 * 60 { return }
            // Mailboxes registered before and not now (a contact blocked or muted since) are taken off the relay.
            let stale = Array((pushTold?.keys ?? []).subtracting(keys))
            pushBusy = true
            Task {
                defer { pushBusy = false }
                // The relay forgets registrations when it restarts and can't say so, so they're renewed every 15 minutes.
                guard let client = client(nil, lane: "push"), await client.pushEnabled() else {
                    pushStatus = "The server isn't set up for wake-ups"
                    return
                }
                // A phone's mailboxes go in a few calls; the relay takes 256 at a time.
                let all = keys.sorted { $0.hex < $1.hex }
                var ok = true
                for start in stride(from: 0, to: all.count, by: 256) {
                    let chunk = Array(all[start..<min(start + 256, all.count)])
                    do {
                        try await client.registerPush(keys: chunk, token: token, sandbox: Push.sandbox, sound: sound, tone: tone, voip: voip)
                    } catch {
                        ok = false
                        pushStatus = (error as? PushRefused).map { "The server refused the registration (\($0.status))" } ?? "Couldn't reach the server to register"
                        break
                    }
                }
                if ok {
                    for start in stride(from: 0, to: stale.count, by: 256) {
                        try? await client.unregisterPush(keys: Array(stale[start..<min(start + 256, stale.count)]))
                    }
                    pushTold = (token, keys, sound, tone, voip, Date())
                    pushStatus = "Registered \(keys.count) mailbox\(keys.count == 1 ? "" : "es") at \(Date().formatted(date: .omitted, time: .shortened)), token ending \(token.suffix(4))"
                }
            }
        } else {
            let forgotten = keys.union(pushTold?.keys ?? [])
            pushTold = nil
            pushAsked = false
            UIApplication.shared.unregisterForRemoteNotifications()
            guard !forgotten.isEmpty else { return }
            pushBusy = true
            Task {
                defer { pushBusy = false }
                let all = Array(forgotten)
                for start in stride(from: 0, to: all.count, by: 256) {
                    try? await client(nil, lane: "push")?.unregisterPush(keys: Array(all[start..<min(start + 256, all.count)]))
                }
            }
        }
        #endif
    }

    /// Takes this phone's wake-ups off the relay without needing to know whose mailboxes they were. Used when an
    /// account is wiped, and when a decoy opens (whose empty account must not buzz for the real one). The real account
    /// registers again the next time it's unlocked.
    private func withdrawPush() {
        #if os(iOS)
        pushTold = nil
        pushForgetPending = true
        refreshPush()
        #endif
    }

    /// The connection for proving a profile's handles, collectibles and eggs are its own. Never the one its mail
    /// is fetched on, so the relay can't tie a handle to a mailbox, or two personas to one account.
    static func directoryLane(_ persona: UUID?) -> String { "dir|" + (persona?.uuidString ?? "main") }

    func client(_ relay: String?, lane: String = "main") -> RelayClient? {
        guard let address = reachable(relay), let url = URL(string: address) else { return nil }
        return RelayClient(base: url, lane: lane)
    }

    /// Where to actually connect for a relay: never anywhere but an allowed one, whatever a contact or code once
    /// said, and for Pulshade's own, its onion address with Tor on and its direct one with Tor off.
    func reachable(_ relay: String?) -> String? {
        Invite.allowedRelay(relay ?? data.relay).map { Invite.route($0, overTor: Tor.enabled) }
    }

    /// One fetch at a time: two overlapping ones could both collect, and handle, the same envelope.
    private var syncing = false

    /// Sends queued envelopes: the oldest waiting one of each mailbox (so what's written to one mailbox goes out in
    /// order), the smallest first, and a new one is started the moment another finishes. A story to thirty people
    /// doesn't go out one slow round trip after another, and a short message never waits behind its photos.
    /// One that fails holds up only its own mailbox, and a relay that's down only its own envelopes. A large one
    /// that fails (a slow upload, not a relay that's gone) doesn't stop the small ones behind it.
    private func flush() async {
        let owner = identity?.fingerprint
        var down: Set<String> = []
        // Mailboxes that are full this time: what's written to them waits, nothing else does. And those a big upload
        // to just failed: that was a slow upload, not the mailbox, so short messages to it still go.
        var held: Set<Data> = []
        var heldBig: Set<Data> = []
        var tried: Set<UUID> = []
        var aborted = false

        // The smallest waiting item that may go, if there's room for it. Short messages keep their order among
        // themselves, and so do photos and story pieces, but a short message doesn't wait behind a story's pieces
        // for the same person (the ratchet reads them in either order). Big ones share one connection, so more than
        // a couple at once only makes each slower, and slow enough to time out; short ones are tiny and always
        // get through.
        func pick() -> (item: Outgoing, client: RelayClient, lane: String)? {
            guard !aborted else { return nil }
            let now = Date()
            var best: (item: Outgoing, client: RelayClient, lane: String)?
            var seenSmall: Set<Data> = [], seenBig: Set<Data> = []
            for item in data.outbox where !tried.contains(item.id) && !sendingIDs.contains(item.id) {
                let relay = item.relay ?? data.relay
                // A mailbox that just said it was full is left alone until its short backoff ends. A relay
                // that's unreachable is not backed off: retry as soon as it's back.
                if let backoff = mailboxBackoff[item.sendID], now < backoff.until { continue }
                // Photos and story pieces go on a connection of their own, so a big upload neither crowds out the short
                // messages nor takes their connection down with it when it fails.
                let lane = (item.lane ?? Outgoing.lane(for: nil)) + (item.blob.count > Self.smallEnvelope ? Self.bulkSuffix : "")
                guard !down.contains(relay), !held.contains(item.sendID) else { continue }
                if item.blob.count > Self.smallEnvelope {
                    guard !heldBig.contains(item.sendID), !seenBig.contains(item.sendID),
                          !sendingBigMail.contains(item.sendID) else { continue }
                    seenBig.insert(item.sendID)
                } else {
                    guard !seenSmall.contains(item.sendID), !sendingSmallMail.contains(item.sendID) else { continue }
                    seenSmall.insert(item.sendID)
                }
                guard let client = client(item.relay, lane: lane) else { continue }
                // A lane without a working route finds one first, once: not for every item that's waiting.
                if Tor.uses(client.base), !client.isEstablished, routeFinding.contains(lane) { continue }
                if best == nil || item.blob.count < best!.item.blob.count { best = (item, client, lane) }
            }
            guard let best else { return nil }
            let big = best.item.blob.count > Self.smallEnvelope
            let bigInFlight = sendingBig.count
            if big ? bigInFlight >= Self.bigUploads : sendingIDs.count >= Self.sendLanes + Self.bigUploads { return nil }
            return best
        }

        await withTaskGroup(of: (Outgoing, String, Error?).self) { group in
            var running = 0
            while true {
                while let next = pick() {
                    let item = next.item, client = next.client, lane = next.lane
                    let findsRoute = Tor.uses(client.base) && !client.isEstablished
                    if findsRoute { routeFinding.insert(lane) }
                    tried.insert(item.id)
                    sendingIDs.insert(item.id)
                    if item.blob.count > Self.smallEnvelope {
                        sendingBig.insert(item.id)
                        sendingBigMail.insert(item.sendID)
                    } else {
                        sendingSmallMail.insert(item.sendID)
                    }
                    running += 1
                    group.addTask {
                        // As with fetching: a lane without a working route finds one before it sends.
                        if findsRoute { _ = await Self.reach(client) }
                        do {
                            try await client.deposit(item.blob, to: item.sendID, wake: item.message != nil || item.rings == true || item.wakes == true, ring: item.rings == true,
                                                     recall: item.recallN.flatMap { n in item.recallHash.map { (n, $0) } })
                            return (item, lane, nil)
                        } catch { return (item, lane, error) }
                    }
                }
                guard running > 0, let (item, lane, error) = await group.next() else { break }
                running -= 1
                routeFinding.remove(lane)
                sendingIDs.remove(item.id)
                if sendingBig.remove(item.id) != nil { sendingBigMail.remove(item.sendID) } else { sendingSmallMail.remove(item.sendID) }
                guard identity?.fingerprint == owner else { aborted = true; group.cancelAll(); continue }
                if let error {
                    if error is RelayTooLarge {
                        // Too big for the relay, now and always: waiting would hold up everything behind it.
                        data.outbox.removeAll { $0.id == item.id }
                        mailboxBackoff[item.sendID] = nil
                        continue
                    }
                    if error is RelayMailboxFull {
                        held.insert(item.sendID)
                        let failures = (mailboxBackoff[item.sendID]?.failures ?? 0) + 1
                        mailboxBackoff[item.sendID] = (Date().addingTimeInterval(retryDelay(failures)), failures)
                    } else if item.blob.count > Self.largeEnvelope {
                        heldBig.insert(item.sendID)
                    } else {
                        down.insert(item.relay ?? data.relay)
                    }
                    // A signal that couldn't be sent is not worth sending later.
                    if item.ephemeral == true {
                        data.outbox.removeAll { $0.id == item.id }
                        mailboxBackoff[item.sendID] = nil
                    }
                } else {
                    if !lane.hasSuffix(Self.bulkSuffix) { lastSent[lane] = Date() }
                    lastDepositOK = Date()
                    data.outbox.removeAll { $0.id == item.id }
                    mailboxBackoff[item.sendID] = nil
                    if let message = item.message { setStatus(.sent, for: [message]) }
                    if item.story != nil { drainStoryBacklog() }
                    if let story = item.story { markUploadedIfDone(story) }
                }
            }
        }
        if aborted { return }
        if !down.isEmpty { link = .offline }
        // Forget backoff for mailboxes no longer waiting (a cancelled send, a deleted chat).
        let live = Set(data.outbox.map(\.sendID))
        mailboxBackoff = mailboxBackoff.filter { live.contains($0.key) }
        save()
    }

    /// Outbox items being sent right now by any flush, so two never send the same one, or write to one mailbox
    /// at the same time. A message sent during a long upload starts its own flush and goes straight out.
    @ObservationIgnored private var sendingIDs: Set<UUID> = []
    @ObservationIgnored private var sendingSmallMail: Set<Data> = []
    /// The last time the relay took something we sent.
    @ObservationIgnored private var lastDepositOK: Date?
    /// Lanes where a send is finding a route right now.
    @ObservationIgnored private var routeFinding: Set<String> = []
    @ObservationIgnored private var sendingBigMail: Set<Data> = []
    @ObservationIgnored private var sendingBig: Set<UUID> = []
    /// A mailbox the relay said was full (`507`), and when it may be tried again. Kept across flushes so a
    /// full mailbox isn't asked again every couple of seconds; it clears on the first success. Capped short,
    /// since a full mailbox is about the recipient, not the connection.
    @ObservationIgnored private var mailboxBackoff: [Data: (until: Date, failures: Int)] = [:]

    /// How long to wait before trying a full mailbox again: 30 s, doubling to at most two minutes. A relay
    /// that's down is not backed off — a Tor hiccup or waking from sleep shouldn't hold messages back once the
    /// connection is back. Off in tests, like the rest of the traffic shaping, so retries happen at once.
    private func retryDelay(_ failures: Int) -> TimeInterval {
        guard trafficShaping else { return 0 }
        let steps = min(max(failures - 1, 0), 2)
        return min(2 * 60, 30 * pow(2, Double(steps)))
    }
    /// Under this an envelope is a short message or a receipt.
    private static let smallEnvelope = 32_768
    /// Added to a sending lane's name for the connection that carries the big uploads.
    private static let bulkSuffix = "|bulk"
    /// Photos and the like sent at once. They share a connection, so more only makes each of them slower.
    private static let bigUploads = 2

    /// Mailboxes written to at once when sending.
    private static let sendLanes = 6
    /// Above this an envelope is a photo or a group's details, not a short message: if it fails, it's more likely
    /// a slow upload than the relay being gone.
    private static let largeEnvelope = 65_536

    /// One full round: send, then check every lane in a random order. Tests and Retry use it; normally each
    /// lane runs on its own (see `startSync`).
    func syncOnce() async {
        guard let identity else { link = .offline; return }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        await housekeep()
        let owner = identity.fingerprint
        for (n, (lane, keys)) in currentLanes().shuffled().enumerated() {
            if n > 0 && trafficShaping && !keys.isEmpty {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 150...900)))
                guard self.identity?.fingerprint == owner else { return }
            }
            await poll(lane, keys: keys)
        }
        guard self.identity?.fingerprint == owner else { return }
        await flush()
    }

    /// Which persona reads a mailbox: the one whose contact or invite owns it.
    private func persona(forMailbox receiveKey: Data) -> UUID?? {
        if let c = data.contacts.first(where: { $0.receiveKey == receiveKey }) { return .some(c.persona) }
        if let invite = data.invites.first(where: { $0.receiveKey == receiveKey }) { return .some(invite.persona) }
        if let convo = data.conversations.first(where: { $0.introsMine.contains { $0.receiveKey == receiveKey } }) {
            return .some(convo.persona)
        }
        return nil
    }

    /// Someone reached this device through a group introduction: give them a mailbox only they write to, so the
    /// introduction one, which the whole group knows, carries nothing more from them.
    private func moveOffIntro(_ fp: String, _ persona: UUID?) {
        let key = fp + (persona?.uuidString ?? "")
        guard !movedOffIntro.contains(key), let i = contactIndex(fp, persona), !data.contacts[i].isSelf,
              data.contacts[i].devices.contains(where: { $0.session != nil }) else { return }
        movedOffIntro.insert(key)
        enqueue(.moved(myDevice(for: i)), to: data.contacts[i])
    }

    /// Who's been given a private mailbox since launch, so it's said once.
    @ObservationIgnored private var movedOffIntro: Set<String> = []

    /// A friend still writing to your public request mailbox never heard that you accepted (the answer was lost, or
    /// reached a handshake their side had since started again). Tell them again, so they move to their own mailbox and
    /// stop showing the request as waiting. Once they've heard, nothing more of theirs comes this way.
    private func remindAccepted(_ fp: String, _ persona: UUID?) {
        guard let i = contactIndex(fp, persona) else { return }
        let c = data.contacts[i]
        guard !c.isSelf, !c.hidden, !c.awaitingAcceptance, let receiveKey = c.receiveKey,
              c.devices.contains(where: { $0.session != nil }) else { return }
        enqueue(.accepted(sendID: Mailbox.sendID(for: receiveKey)), to: c)
    }

    private func receive(_ envelope: RelayEnvelope) {
        deposited = envelope.deposited
        if let offer = data.linkOffers.firstIndex(where: { $0.receiveKey == envelope.receiveKey }) {
            receiveLinkRequest(envelope.blob, offer: offer)
            return
        }
        guard let persona = persona(forMailbox: envelope.receiveKey), let me = me(persona),
              let opened = try? Envelope.openFull(envelope.blob, with: me) else { return }
        let payload = opened.payload, signer = opened.signer, device = opened.device
        let fp = Identity.fingerprint(of: signer)
        // Anything outside a ratchet session could be sent again by the relay. Each one counts once, and only
        // while the relay could still be holding it.
        if case .ratchet = payload {} else {
            let digest = Data(SHA256.hash(data: envelope.blob).prefix(16)).hex
            let age = RelayClock.now.timeIntervalSince(opened.sentAt)
            guard age < Self.replayWindow, age > -24 * 3600, data.seenEnvelopes[digest] == nil else { return }
            data.seenEnvelopes[digest] = Date()
        }

        if case .erased = payload {
            // Signed by their identity key, so only they can erase themselves from here.
            eraseTraces(of: fp)
            return
        }

        if case let .hello(card, request) = payload {
            guard card.signingKey == signer,
                  let invite = data.invites.first(where: { $0.receiveKey == envelope.receiveKey && !$0.isPublic }) else { return }
            acceptHello(card, request, fingerprint: fp, device: device, via: invite)
            noteReads(opened, from: fp, persona: invite.persona)
            return
        }
        if case let .request(card, request, note) = payload {
            guard card.signingKey == signer, !data.blocked.contains(fp),
                  card.relay == nil || Invite.allowedRelay(card.relay) != nil,
                  let invite = data.invites.first(where: { $0.receiveKey == envelope.receiveKey && $0.isPublic }) else { return }
            var incoming = FriendRequest(fingerprint: fp, card: card, handshake: request, note: String(note.prefix(280)),
                                         persona: invite.persona)
            incoming.device = device
            // Someone known only from a group isn't a friend yet: theirs is an ordinary request.
            if let known = contactIndex(fp, invite.persona), !data.contacts[known].hidden {
                // Already a friend: they've lost the chat on their side (a reinstall, a detach), and their identity
                // key signed this, so it's them. Reconnect now, rather than leave each side waiting on the other.
                if !data.contacts[known].awaitingAcceptance { reconnect(incoming, keeping: data.contacts[known]) }
                return
            }
            // The same request sent again (the relay may have lost the first): already here, so no second banner.
            if data.requests.contains(where: { $0.fingerprint == fp && $0.persona == invite.persona && $0.handshake == request }) { return }
            withAnimation(.snappy) {
                data.requests.removeAll { $0.fingerprint == fp && $0.persona == invite.persona }
                data.requests.insert(incoming, at: 0)
            }
            sync(.requestReceived(incoming))
            if data.security.notifications {
                Notifier.shared.post(("PULSHADE", "New friend request"), conversation: incoming.id, sound: data.security.notificationSound)
            }
            return
        }
        guard let i = contactIndex(fp, persona) else { return }
        noteReads(opened, from: fp, persona: persona)
        let viaIntro = data.conversations.contains { $0.introsMine.contains { $0.receiveKey == envelope.receiveKey } }
        defer { if viaIntro { moveOffIntro(fp, persona) } }
        let viaRequestMailbox = data.invites.contains { $0.isPublic && $0.receiveKey == envelope.receiveKey }
        defer { if viaRequestMailbox { remindAccepted(fp, persona) } }

        switch payload {
        case let .deviceHello(card, request):
            // A device introducing itself (a new one, or one restarting its session). Signed by the account,
            // so it really is theirs.
            guard card.id == device else { return }
            let d = upsertDevice(i, id: card.id, sendID: card.sendID)
            // The same hello again (a relay redelivery) must not replace the session it already opened.
            if data.contacts[i].devices[d].session != nil && data.contacts[i].devices[d].acceptedHello == request.ephemeral {
                return
            }
            if data.contacts[i].devices[d].handshake != nil && myHandshakeWins(me: me.fingerprint, persona: persona, them: fp, theirDevice: device) {
                return
            }
            acceptSession(request, contact: i, device: d)
        case let .sessionInit(request):
            guard let d = deviceIndex(i, device) else { return }
            if data.contacts[i].devices[d].session != nil && data.contacts[i].devices[d].acceptedHello == request.ephemeral {
                return
            }
            if data.contacts[i].devices[d].handshake != nil && myHandshakeWins(me: me.fingerprint, persona: persona, them: fp, theirDevice: device) {
                return
            }
            acceptSession(request, contact: i, device: d)
        case let .sessionAccept(answer):
            guard let d = deviceIndex(i, device), let pending = data.contacts[i].devices[d].handshake,
                  pending.publicEphemeral == answer.replyTo,
                  let session = try? Handshake.complete(pending, answer, me: me,
                                                        responderAgreement: data.contacts[i].agreementKey) else { return }
            data.contacts[i].devices[d].session = session
            data.contacts[i].devices[d].handshake = nil
        case let .ratchet(message):
            guard let d = deviceIndex(i, device) else { return }
            let keptKey = sessionKey(contact: i, device: d)
            var plain: Data?
            if var session = data.contacts[i].devices[d].session, let opened = try? session.decrypt(message) {
                data.contacts[i].devices[d].session = session
                plain = opened
            } else if var old = recoveredSessions[keptKey], let opened = try? old.decrypt(message) {
                // Sent to the keys this account had before it was recovered, while the phone was gone: still readable.
                recoveredSessions[keptKey] = old
                plain = opened
            }
            guard let plain else {
                // Signed by their account, yet this device's keys can't open it: the two are out of step (a backup that
                // was a little behind, say). Said once in a while, so a new session is opened with them, which they
                // accept; until then what they sent can't be read, and what's sent to them can't be either.
                if data.contacts[i].devices[d].session != nil { mendSession(contact: i, device: d) }
                return
            }
            // The keys were kept above, before reading what it says, so a message this version can't read (one from a
            // newer app) still counts and doesn't leave the session behind.
            guard let inner = try? Payload.fromWire(plain), !inner.isSetup else { return }
            handle(inner, from: fp, persona: persona, device: device)
            // The first message in lets a new session start sending. Look them up again: handling it may
            // have removed them (a burned burner, say).
            if let i = contactIndex(fp, persona) { sendPending(contact: i) }
        default:
            // Anything else arriving outside a session is refused.
            return
        }
    }

    /// Keeps what a device's app says it can read, as of the last thing it sent. Only written when it changes.
    private func noteReads(_ opened: Envelope.Opened, from fp: String, persona: UUID?) {
        guard let i = contactIndex(fp, persona), let d = deviceIndex(i, opened.device) else { return }
        if (data.contacts[i].devices[d].readsFrames == true) != opened.readsFrames {
            data.contacts[i].devices[d].readsFrames = opened.readsFrames ? true : nil
        }
        if (data.contacts[i].devices[d].readsAttachments == true) != opened.readsAttachments {
            data.contacts[i].devices[d].readsAttachments = opened.readsAttachments ? true : nil
        }
    }

    static let maxAvatarBytes = 512 * 1024
    static let maxBannerBytes = 2 * 1024 * 1024
    static let maxDevicesPerContact = 16

    /// Longer than the relay keeps anything (seven days).
    static let replayWindow: TimeInterval = 8 * 24 * 3600

    private func handle(_ payload: Payload, from fp: String, persona: UUID?, device: Data) {
        guard var sender = contact(fp, in: persona) else { return }
        switch payload {
        case .report:
            // Reports go to the Pulshade Admin app, sealed on their own; one arriving here means nothing.
            break
        case .deviceRemoved:
            guard let i = contactIndex(fp, persona), data.contacts[i].devices.count > 1 else { break }
            data.contacts[i].devices.removeAll { $0.id == device }
        case .erased:
            eraseTraces(of: fp)
        case .hello, .request, .sessionInit, .deviceHello, .sessionAccept, .ratchet:
            break
        case let .sync(event):
            // Only your own devices may tell this one what you did.
            guard sender.isSelf else { break }
            applySync(event)
        case let .callOffer(invite):
            guard !sender.isSelf, !sender.hidden else { break }
            receiveCall(invite, from: sender)
        case let .callAnswer(id, accepted):
            guard !sender.isSelf else { break }
            callAnswered(id, accepted: accepted, by: sender)
        case let .callEnd(id):
            guard call?.invite.id == id, call?.peer == fp, call?.persona == persona else { break }
            endCall(note: call?.phase == .ringing && call?.outgoing == false ? "Missed call" : nil, tell: false)
        case let .profile(name, avatar, color, banner, bio, handle, badge, links, collectibles, notes):
            sender.name = String(name.prefix(64))
            sender.badge = badge.flatMap { $0.isGenuine(for: sender.signingKey) ? $0 : nil }
            sender.collectibles = collectibles.map { Array($0.prefix(40).filter { $0.isGenuine(for: sender.signingKey) }) }.flatMap { $0.isEmpty ? nil : $0 }
            sender.bio = bio.map { String($0.prefix(160)) }
            // Never trust what arrives: keep only entries that pass the same checks as ours.
            let newLinks = Optional(ProfileLink.cleaned(links)).flatMap { $0.isEmpty ? nil : $0 }
            // A wallet they already showed that now reads differently: remember when, so the sheet can warn.
            let wallets = { (list: [ProfileLink]?) in Set((list ?? []).filter(\.kind.isWallet).map { $0.kind.rawValue + ":" + $0.value }) }
            if !wallets(sender.links).isEmpty, wallets(sender.links) != wallets(newLinks) { sender.walletChangedAt = Date() }
            sender.links = newLinks
            sender.notes = Optional(ProfileNote.cleaned(notes)).flatMap { $0.isEmpty ? nil : $0 }
            let claimed = handle.flatMap(DirectoryProfile.validHandle)
            if claimed != sender.handle { sender.handle = nil }
            if let claimed, claimed != sender.handle { confirmHandle(claimed, of: sender) }
            // A picture bigger than any this app makes is not kept, so one contact can't fill the vault.
            sender.avatar = avatar.flatMap { $0.count <= Self.maxAvatarBytes ? $0 : nil }
            sender.banner = banner.flatMap { $0.count <= Self.maxBannerBytes ? $0 : nil }
            sender.color = color.map { $0.wrapped(Signature.colors.count) }
            upsert(sender)
            refreshDirectTitle(fp)
        case let .message(wire):
            deliver(wire, from: sender)
        case let .receipt(ids, read):
            // With read receipts off you don't see other people's either.
            let seen = read == true && data.security.readReceipts
            withAnimation(.smooth) { setStatus(seen ? .read : .delivered, for: ids) }
        case let .group(info):
            joinGroup(info, from: sender)
        case let .story(id, style, date, lasts):
            // Already taken back: a late or repeated copy mustn't bring it back.
            guard removedStories["\(fp)|\(id)"] == nil else { break }
            let lifetime = lasts.map { min(max($0, 3600), StoryLifetime.twoDays.rawValue) }
            // The same story can reach two of your personas (one friend in both): each keeps its own copy, so
            // only the copy for this persona counts as "sent before". The id is never taken from someone else.
            guard !data.stories.contains(where: { $0.id == id && $0.author != fp }) else { break }
            if let i = data.stories.firstIndex(where: { $0.id == id && $0.author == fp && $0.persona == persona }) {
                // A new version of one they sent before.
                var style = style
                // A new caption on a clip they already sent comes without the clip.
                if case let .video(bytes, caption) = style, bytes.isEmpty, case let .video(have, _) = data.stories[i].style, !have.isEmpty {
                    style = .video(have, caption: caption)
                }
                data.stories[i].style = style
                data.stories[i].lifetime = lifetime
                if !data.stories[i].isLive { data.stories.remove(at: i); break }
                acknowledgeStory(id, author: fp, persona: persona)
                // Sent again because pieces went missing: what's here now may complete it. The story arriving again
                // is not progress (only a piece is), or a sender that keeps repeating it would keep this from
                // ever asking for the clip.
                if clipActivity[ClipKey(id, persona)] == nil { clipActivity[ClipKey(id, persona)] = Date() }
                assembleClip(id, persona: persona)
                break
            }
            if case let .video(bytes, _) = style, bytes.isEmpty { clipActivity[ClipKey(id, persona)] = Date() }
            var story = Story(id: id, author: fp, style: style, date: dated(date))
            story.persona = persona
            story.lifetime = lifetime
            if story.isLive { withAnimation(.snappy) { data.stories.append(story) } }
            assembleClip(id, persona: persona)
            acknowledgeStory(id, author: fp, persona: persona)
        case let .storyPart(id, index, of, bytes):
            let key = ClipKey(id, persona)
            guard removedStories["\(fp)|\(id)"] == nil else { break }
            // A piece sent again after the clip came together: nothing to do with it.
            if data.stories.contains(where: { $0.id == id && $0.author == fp && $0.persona == persona && $0.isReady }) { break }
            if let at = videoMessage(id), data.conversations[at.convo].persona == persona,
               data.conversations[at.convo].messages[at.message].video?.isEmpty == false { break }
            guard (1...StoryClipPieces.maxPieces).contains(of), (0..<of).contains(index), bytes.count <= StoryClipPieces.framedSize,
                  data.clipParts[key.stored] != nil || data.clipParts.count < 32 else { break }
            var pending = data.clipParts[key.stored] ?? ClipParts(id: id, author: fp, persona: persona, of: of)
            guard pending.author == fp, pending.persona == persona else { break }
            // Cut differently from the pieces already here (their app or mine updated part-way): start over with these.
            if pending.of != of { pending = ClipParts(id: id, author: fp, persona: persona, of: of) }
            pending.parts[index] = bytes
            data.clipParts[key.stored] = pending
            clipActivity[key] = Date()
            assembleClip(id, persona: persona)
        case let .clipBlob(id, a):
            guard a.isValid, a.kind == .video, a.size <= 8_000_000 else { break }
            receiveClipBlob(id, a, from: sender, persona: persona)
        case let .storyReceived(id):
            // One of my contacts has the story: it's no longer sent to them again.
            guard let i = data.stories.firstIndex(where: { $0.id == id && $0.author == "me" && $0.persona == persona }),
                  var delivery = data.stories[i].delivery, !delivery.confirmed.contains(fp) else { break }
            delivery.confirmed.append(fp)
            data.stories[i].delivery = delivery
        case let .storyWant(id, parts):
            // A video you sent them in a chat they're in: its pieces again.
            if let at = videoMessage(id), data.conversations[at.convo].messages[at.message].isMine,
               data.conversations[at.convo].persona == persona, data.conversations[at.convo].members.contains(fp),
               let clip = data.conversations[at.convo].messages[at.message].video, !clip.isEmpty,
               !sender.isSelf, !data.blocked.contains(fp) {
                let key = "\(fp)|\(id)"
                if let last = clipResent[key], Date().timeIntervalSince(last) < clipQuiet { break }
                clipResent[key] = Date()
                deliverClip(clip, id: id, to: sender, known: nil, only: parts)
                break
            }
            // Only for a story of yours that's still up, on this persona, and that they're meant to see.
            guard let story = data.stories.first(where: { $0.id == id && $0.author == "me" && $0.persona == persona }),
                  story.isLive, story.shownTo.includes(fp), removedStories["me|\(id)"] == nil,
                  !sender.isSelf, !data.blocked.contains(fp) else { break }
            let key = "\(fp)|\(id)"
            if let last = clipResent[key], Date().timeIntervalSince(last) < clipQuiet { break }
            clipResent[key] = Date()
            resendStory(story, to: sender, pieces: parts)
        case let .storyViewed(id):
            if let i = data.stories.firstIndex(where: { $0.id == id && $0.author == "me" && $0.persona == persona }),
               data.stories[i].shownTo.includes(fp), data.stories[i].viewers?[fp] == nil {
                data.stories[i].viewers = (data.stories[i].viewers ?? [:]).merging([fp: min(deposited ?? Date(), Date())]) { old, _ in old }
            }
            // Recorded or not (the story is gone, or they were taken out of the audience), answer so the viewer can
            // stop trying.
            enqueue(.storyViewedAck(id: id), to: sender)
        case let .storyViewedAck(id):
            // The author's app has dealt with our view: no more trying.
            guard let i = data.stories.firstIndex(where: { $0.id == id && $0.author == fp && $0.persona == persona }),
                  var report = data.stories[i].viewReport else { break }
            report.confirmed = true
            data.stories[i].viewReport = report
        case let .storyRemoved(id):
            if data.clipParts[ClipKey(id, persona).stored]?.author == fp { data.clipParts[ClipKey(id, persona).stored] = nil }
            noteRemoved("\(fp)|\(id)")
            withAnimation { data.stories.removeAll { $0.id == id && $0.author == fp && $0.persona == persona } }
        case .storiesCleared:
            // Only theirs: whoever sends this can take back their own stories and nobody else's.
            for story in data.stories where story.author == fp && story.persona == persona { noteRemoved("\(fp)|\(story.id)") }
            data.clipParts = data.clipParts.filter { !($0.value.author == fp && $0.value.persona == persona) }
            withAnimation { data.stories.removeAll { $0.author == fp && $0.persona == persona } }
        case let .unsend(ids):
            applyUnsend(ids, from: sender)
        case let .reaction(message, emoji):
            applyReaction(emoji, to: message, from: sender)
        case let .typing(shared):
            guard data.security.typingIndicators, let i = conversationIndex(shared, from: sender) else { break }
            typing[data.conversations[i].id, default: [:]][fp] = Date()
        case let .wantsPresence(wants):
            guard !sender.isSelf, let i = contactIndex(fp, persona) else { break }
            data.contacts[i].wantsMyPresence = wants
            // Someone who just asked is answered within moments.
            if wants { presenceDue[presenceKey(fp, persona)] = Date().addingTimeInterval(jitter(0.5...3)) }
        case let .presence(here):
            guard data.security.onlineStatus, !sender.isSelf, !sender.hidden, !data.blocked.contains(fp) else { break }
            let key = presenceKey(fp, persona)
            let cutoff = Date().addingTimeInterval(-Self.presenceLife)
            let wasHere = (online[key] ?? .distantPast) > cutoff
            let at = min(deposited ?? Date(), Date())
            if here, at > cutoff {
                online[key] = at
                // They've just arrived: let them see you're here too.
                if !wasHere, sender.wantsMyPresence == true { presenceDue[key] = Date().addingTimeInterval(jitter(0.5...3)) }
            } else if !here {
                online[key] = nil
            }
        case let .disappearing(shared, seconds):
            guard let i = conversationIndex(shared, from: sender, create: true),
                  data.conversations[i].kind != .channel, data.conversations[i].disappearAfter != seconds else { break }
            // An unknown or out-of-range value is ignored, not applied as "turn the timer off".
            let valid: TimeInterval?
            if let seconds {
                guard let timer = Disappear(rawValue: seconds) else { break }
                valid = timer.rawValue
            } else {
                valid = nil
            }
            applyTimer(valid, at: i)
        case .burn:
            forget(sender)
        case let .chatDeleted(shared):
            guard let i = conversationIndex(shared, from: sender) else { break }
            let c = data.conversations[i]
            if c.kind == .direct || c.owner == fp {
                removeLocally(c.id)
            } else {
                // Only the owner can delete for everyone; from anyone else it means they left.
                dropMember(fp, at: i)
            }
        case let .left(shared):
            guard let i = conversationIndex(shared, from: sender) else { break }
            dropMember(fp, at: i)
        case let .removed(shared):
            guard let i = conversationIndex(shared, from: sender) else { break }
            let c = data.conversations[i]
            // Only someone allowed to take me out: the owner anyone, an admin a plain member or mod, a mod a plain member.
            guard c.canRemove("me", by: fp) else { break }
            removeLocally(data.conversations[i].id)
        case let .moved(card):
            // They opened a mailbox just for us after we said hello through a group introduction.
            guard card.id == device, card.sendID.count == 32, let i = contactIndex(fp, persona),
                  let d = deviceIndex(i, device) else { break }
            data.contacts[i].devices[d].sendID = card.sendID
            syncContact(fp, persona)
        case let .accepted(sendID):
            // They accepted our request: switch to the private mailbox they opened for us.
            guard sender.awaitingAcceptance, sendID.count == 32 else { break }
            sender.sendID = sendID
            sender.awaitingAcceptance = false
            upsert(sender)
            syncContact(fp, persona)
            _ = startConversation(kind: .direct, title: sender.displayName, members: [fp], persona: .some(persona))
            shareStories(with: sender)
        }
    }

    private func acceptHello(_ card: PeerCard, _ request: SessionInit, fingerprint fp: String, device: Data,
                             via invite: OpenInvite) {
        let persona = invite.persona
        let known = contact(fp, in: persona)
        var peer = known ?? Contact(fingerprint: fp, signingKey: card.signingKey,
                                    agreementKey: card.agreementKey, sendID: card.sendID, device: device)
        peer.persona = persona
        peer.relay = invite.relay
        peer.name = String(card.name.prefix(64))
        peer.avatar = card.avatar
        peer.color = card.color

        func answer() {
            guard let i = contactIndex(fp, persona) else { return }
            let d = upsertDevice(i, id: device, sendID: card.sendID)
            acceptSession(request, contact: i, device: d)
        }

        if let channelID = invite.channel {
            peer.hidden = known?.hidden ?? true
            upsert(peer)
            answer()
            guard let i = index(of: channelID) else { return }
            if !data.conversations[i].members.contains(fp) { data.conversations[i].members.append(fp) }
            data.conversations[i].version &+= 1
            let c = data.conversations[i]
            sendInfo(c, to: [fp] + c.admins.filter { $0 != "me" } + (c.amOwner ? [] : [c.owner]))
        } else {
            peer.hidden = false
            peer.receiveKey = invite.receiveKey
            upsert(peer)
            data.invites.removeAll { $0.receiveKey == invite.receiveKey }
            answer()
            syncContact(fp, persona)
            _ = startConversation(kind: .direct, title: peer.displayName, members: [fp], persona: .some(persona))
            shareStories(with: peer)
        }
    }

    /// The conversation a signal from `sender` belongs to: a shared group/channel id, or their direct chat.
    private func conversationIndex(_ shared: UUID?, from sender: Contact, create: Bool = false) -> Int? {
        if let shared {
            guard let found = index(of: shared), data.conversations[found].persona == sender.persona,
                  data.conversations[found].members.contains(sender.fingerprint) else { return nil }
            return found
        }
        guard !sender.hidden else { return nil }
        if let found = directConversation(with: sender.fingerprint, persona: sender.persona).flatMap({ index(of: $0.id) }) {
            return found
        }
        guard create else { return nil }
        _ = startConversation(kind: .direct, title: sender.displayName, members: [sender.fingerprint], persona: .some(sender.persona))
        return directConversation(with: sender.fingerprint, persona: sender.persona).flatMap { index(of: $0.id) }
    }

    /// When the envelope being read reached the relay, by this device's clock.
    @ObservationIgnored private var deposited: Date?

    /// When something was sent, by this device's clock. The sender's stamp is by the relay's clock as it saw it,
    /// and nothing can have been sent after the relay took it in, so a sender's wrong clock can't move it later.
    private func dated(_ sent: Date) -> Date {
        min(RelayClock.local(sent), deposited ?? Date(), Date())
    }

    private func deliver(_ wire: WireMessage, from sender: Contact) {
        guard let i = conversationIndex(wire.conversation, from: sender, create: true) else { return }
        if wire.conversation != nil, !data.conversations[i].canPost(sender.fingerprint) { return }
        guard !data.conversations[i].messages.contains(where: { $0.id == wire.id }) else {
            // Sent again because the relay may have lost it: say again that it's here, so their tick catches up.
            if wire.conversation == nil { queueReceipt(wire.id, to: sender) }
            return
        }
        let date = dated(wire.date)
        let expires = wire.expiresIn.map { date.addingTimeInterval(min($0, Disappear.week.rawValue)) }
        if let expires, expires <= Date() { return }
        let mine = me(sender.persona)?.fingerprint
        let reply = wire.reply.map {
            ReplyRef(id: $0.id, author: $0.author == mine ? "me" : $0.author, snippet: String($0.snippet.prefix(120)),
                     picture: $0.picture.flatMap { $0.count <= ReplyRef.maxPicture && PlatformImage(data: $0) != nil ? $0 : nil })
        }
        let preview = wire.preview.flatMap { p in
            !LinkPreviews.isWebLink(p.url) ? nil  // only plain http(s) links
                : LinkPreview(url: p.url, title: p.title.map { String($0.prefix(200)) }, site: p.site.map { String($0.prefix(80)) },
                              image: p.image.flatMap { $0.count <= 400_000 ? $0 : nil })
        }
        var message = Message(id: wire.id, sender: sender.fingerprint, text: String(wire.text.prefix(20_000)),
                              image: wire.image, voice: wire.voice, date: date, status: .delivered, expiresAt: expires,
                              reply: reply, preview: preview)
        // Shown only if it's really theirs: a collectible is checked against their key, a note card is just a title.
        message.collectible = wire.collectible.flatMap { $0.isGenuine(for: sender.signingKey) ? $0 : nil }
        message.note = wire.note.flatMap(NoteCard.cleaned)
        // A mention counts only in a group, and only as far as it fits the words; yours is stored as "me".
        if data.conversations[i].kind == .group {
            message.mentions = Mention.cleaned(wire.mentions, in: message.text).map {
                Mention(fingerprint: $0.fingerprint == mine ? "me" : $0.fingerprint, start: $0.start, length: $0.length)
            }
        }
        // A file on the relay: kept only if well-formed and not already gone. The words that stood in for it are dropped.
        if let a = wire.attachment, a.isValid, a.expires > RelayClock.now {
            var a = a
            a.expires = min(a.expires, RelayClock.now.addingTimeInterval(8 * 86_400))
            message.attachment = a
            message.text = ""
        }
        if let clip = wire.clip {
            // A video: its clip comes in pieces after this (some may be here already).
            message.video = Data()
            message.clipSeconds = min(max(clip.seconds, 0), ChatVideo.maxSeconds)
            clipActivity[ClipKey(wire.id, data.conversations[i].persona)] = Date()
        }
        typing[data.conversations[i].id]?[sender.fingerprint] = nil
        withAnimation(.snappy(duration: 0.4)) { data.conversations[i].messages.append(message) }
        if wire.clip != nil { assembleClip(wire.id, persona: data.conversations[i].persona) }
        if openConversation != data.conversations[i].id || !appActive { data.conversations[i].unread += 1 }
        notify(message, at: i)
        if wire.conversation == nil {
            // Seen straight away when the chat is open in front of you.
            let seen = openConversation == data.conversations[i].id && appActive && sendsReadReceipts(data.conversations[i])
            queueReceipt(wire.id, to: sender, read: seen)
        }
    }

    /// Shows a contact's @handle only once the directory has it signed by their key, so nobody can pass themselves
    /// off as someone else's handle (or the creator's).
    private func confirmHandle(_ handle: String, of contact: Contact) {
        let (fp, persona) = (contact.fingerprint, contact.persona)
        Task { [weak self] in
            guard let self, let found = try? await self.findProfile(handle), found.fingerprint == fp,
                  var current = self.contact(fp, in: persona) else { return }
            current.handle = handle
            self.upsert(current)
            self.save()
        }
    }

    /// Read receipts go only in direct chats, only with the setting on, and never in a one-time chat.
    private func sendsReadReceipts(_ convo: Conversation) -> Bool {
        guard data.security.readReceipts, convo.kind == .direct else { return false }
        return data.personas.first(where: { $0.id == convo.persona })?.oneTimeChat != true
    }

    /// Delivery receipts wait a random while and go out together, so a receipt doesn't follow a fetch closely
    /// enough to show the relay who was writing to whom.
    /// Read receipts are batched the same way.
    private func queueReceipt(_ id: UUID, to sender: Contact, read: Bool = false) {
        // A read receipt stands in for the delivery one, so it goes even with delivery receipts off.
        guard read || data.security.deliveryReceipts else { return }
        if let i = pendingReceipts.firstIndex(where: { $0.fingerprint == sender.fingerprint && $0.persona == sender.persona
                                                       && $0.read == read }) {
            pendingReceipts[i].ids.append(id)
            return
        }
        let wait = trafficShaping ? Double.random(in: 1...5) : 0
        pendingReceipts.append(ReceiptBatch(fingerprint: sender.fingerprint, persona: sender.persona, ids: [id], read: read,
                                            due: Date().addingTimeInterval(wait)))
    }

    private func sendDueReceipts() {
        let now = Date()
        let due = pendingReceipts.filter { $0.due <= now }
        guard !due.isEmpty else { return }
        pendingReceipts.removeAll { $0.due <= now }
        for batch in due {
            if let c = contact(batch.fingerprint, in: batch.persona) {
                enqueue(.receipt(ids: batch.ids, read: batch.read ? true : nil), to: c)
            }
        }
    }

    private func applyUnsend(_ ids: [UUID], from sender: Contact) {
        let ids = Set(ids)
        for i in data.conversations.indices
        where data.conversations[i].messages.contains(where: { ids.contains($0.id) && $0.sender == sender.fingerprint }) {
            withAnimation(.easeOut(duration: 0.38)) {
                data.conversations[i].messages.removeAll { ids.contains($0.id) && $0.sender == sender.fingerprint }
            }
            clampUnread(i)
        }
    }

    /// The unread count can't be more than the messages from others still there, after some were taken away.
    private func clampUnread(_ i: Int) {
        let theirs = data.conversations[i].messages.count { !$0.isMine && !$0.isSystem }
        if data.conversations[i].unread > theirs { data.conversations[i].unread = theirs }
    }

    private func applyReaction(_ emoji: String?, to messageID: UUID, from sender: Contact) {
        for i in data.conversations.indices where data.conversations[i].members.contains(sender.fingerprint) {
            guard let m = data.conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { continue }
            let clean = emoji.map { String($0.prefix(8)) }
            withAnimation(.snappy) { data.conversations[i].messages[m].reactions[sender.fingerprint] = clean }
            return
        }
    }

    /// A group or channel arrived or changed. New ones are joined. A change to one you're in counts only from its
    /// owner, an admin or (in a group) a mod, only if it's newer, and only for what that role may do: the owner
    /// anything, an admin everything but who the owner, admins and mods are and the posting rule, a mod only
    /// taking ordinary members out. Who may change it is decided before anything is touched.
    func joinGroup(_ info: GroupInfo, from sender: Contact) {
        let persona = sender.persona
        let mine = me(persona)?.card.signing
        func fingerprint(_ key: Data) -> String { key == mine ? "me" : Identity.fingerprint(of: key) }
        // This device's introduction mailbox, from whoever runs the group.
        // Filed under no id when whoever runs the group hadn't heard from this device yet: then that one is ours.
        let intro = (info.intros?[deviceID(for: persona).hex] ?? info.intros?[""]).flatMap {
            $0.count == 32 ? IntroMailbox(receiveKey: $0, relay: sender.relay) : nil
        }
        func keep(_ intro: IntroMailbox?, at i: Int) {
            guard let intro, !data.conversations[i].introsMine.contains(intro) else { return }
            data.conversations[i].introsMine.append(intro)
            // A few are plenty: each is polled, and registered for wake-ups.
            if data.conversations[i].introsMine.count > 8 { data.conversations[i].introsMine.removeFirst() }
        }

        // Who the group says is in it, worked out without changing anything.
        let cards = info.roster.prefix(Conversation.maxMembers).filter { $0.signingKey != mine }
        var members: [String] = [sender.fingerprint]
        for card in cards {
            let fp = Identity.fingerprint(of: card.signingKey)
            if !members.contains(fp) { members.append(fp) }
        }
        let owner = info.owner.map(fingerprint) ?? sender.fingerprint
        let admins = (info.admins ?? []).map(fingerprint).filter { $0 != owner }
        let mods = info.mods.map { $0.map(fingerprint).filter { $0 != owner && !admins.contains($0) } }
        let version = info.version ?? 0
        /// Meets the people in the group we only know from it. A contact we already have keeps the devices we
        /// know: what a group says about someone else's devices isn't theirs to say.
        func meetMembers() {
            for card in cards {
                let fp = Identity.fingerprint(of: card.signingKey)
                guard contactIndex(fp, persona) == nil else { continue }
                var peer = Contact(fingerprint: fp, name: String(card.name.prefix(64)), avatar: card.avatar,
                                   signingKey: card.signingKey, agreementKey: card.agreementKey,
                                   sendID: card.sendID, hidden: true)
                peer.devices = card.allDevices.filter { $0.sendID.count == 32 }.map { DeviceLink(id: $0.id, sendID: $0.sendID) }
                peer.color = card.color
                peer.persona = persona
                peer.relay = Invite.allowedRelay(card.relay)
                upsert(peer)
            }
        }

        if let i = index(of: info.id) {
            let current = data.conversations[i]
            let fromOwner = current.owner == sender.fingerprint
            let fromAdmin = current.isAdmin(sender.fingerprint)
            let fromMod = current.kind == .group && current.mods.contains(sender.fingerprint)
            guard current.persona == persona, fromAdmin || fromMod else { return }
            // The introduction mailbox that comes with an update, whether or not the update itself counts.
            keep(intro, at: i)
            // Newer, but not so far ahead that nothing after it could count: from anyone but the owner, the next few.
            guard version > current.version, fromOwner || version <= current.version + 8 else { return }
            let gone = current.members.filter { !members.contains($0) }
            if fromOwner {
                guard owner == current.owner else { return }
            } else {
                // Nobody else can change who the owner, admins and mods are, or the posting rule, or take the owner
                // or an admin out; a mod can't take another mod out.
                guard owner == current.owner, Set(admins) == Set(current.admins),
                      Set(mods ?? current.mods) == Set(current.mods),
                      (info.postPolicy ?? current.postPolicy) == current.postPolicy,
                      gone.allSatisfy({ current.canRemove($0, by: sender.fingerprint) }) else { return }
                if !fromAdmin {
                    // A mod's update is only ever members taken out: nothing added, and none of the details.
                    guard !gone.isEmpty, members.allSatisfy({ current.members.contains($0) }) else { return }
                }
            }
            meetMembers()
            if fromAdmin {
                data.conversations[i].title = String(info.title.prefix(80))
                data.conversations[i].avatar = info.avatar
                data.conversations[i].about = info.about.map { String($0.prefix(500)) }
            }
            data.conversations[i].admins = admins
            data.conversations[i].mods = mods ?? current.mods
            data.conversations[i].postPolicy = info.postPolicy ?? current.postPolicy
            data.conversations[i].members = members
            data.conversations[i].version = version
            return
        }
        meetMembers()
        var convo = Conversation(id: info.id, kind: info.kind, title: String(info.title.prefix(80)), avatar: info.avatar,
                                 members: members)
        convo.persona = persona
        convo.about = info.about.map { String($0.prefix(500)) }
        convo.owner = owner
        convo.admins = admins
        convo.mods = mods ?? []
        convo.postPolicy = info.postPolicy ?? (info.kind == .channel ? .admins : .everyone)
        convo.version = version
        convo.introsMine = intro.map { [$0] } ?? []
        withAnimation(.snappy) { data.conversations.insert(convo, at: 0) }
    }

    private func dropMember(_ fingerprint: String, at i: Int) {
        data.conversations[i].members.removeAll { $0 == fingerprint }
        data.conversations[i].admins.removeAll { $0 == fingerprint }
        data.conversations[i].mods.removeAll { $0 == fingerprint }
        data.conversations[i].introsMade[fingerprint] = nil
    }

    // MARK: - Group & channel management

    /// Whether you can post here right now.
    func canPost(in convo: Conversation) -> Bool {
        switch convo.kind {
        case .direct, .broadcast: true
        case .group, .channel: convo.canPost("me")
        }
    }

    /// In a channel you run: everyone who isn't an admin.
    func followers(of convo: Conversation) -> [String] {
        convo.members.filter { !convo.isAdmin($0) }
    }

    private func signingKey(_ fingerprint: String, in persona: UUID?) -> Data? {
        fingerprint == "me" ? me(persona)?.card.signing : contact(fingerprint, in: persona)?.signingKey
    }

    /// The group as one recipient should see it. Channel followers only learn who can post.
    func info(for convo: Conversation, to recipient: String) -> GroupInfo {
        let persona = convo.persona
        let people: [String]
        if convo.kind == .channel && !convo.isAdmin(recipient) {
            people = ([convo.owner] + convo.admins).filter { $0 != "me" && $0 != recipient }
        } else {
            people = convo.members.filter { $0 != recipient }
        }
        let roster = people.compactMap { contact($0, in: persona) }.map { member in
            let devices = introDevices(of: member, in: convo.id)
            return PeerCard(name: member.name, avatar: Self.thumbnail(member.avatar, side: 96), color: member.color, signingKey: member.signingKey,
                            agreementKey: member.agreementKey, sendID: devices.first?.sendID ?? Data(), relay: member.relay,
                            devices: devices)
        }
        if let them = contact(recipient, in: persona) { _ = introDevices(of: them, in: convo.id) }
        return GroupInfo(id: convo.id, kind: convo.kind, title: convo.title, avatar: Self.thumbnail(convo.avatar, side: 320), roster: roster,
                         about: convo.about, owner: signingKey(convo.owner, in: persona),
                         admins: convo.admins.compactMap { signingKey($0, in: persona) },
                         mods: convo.mods.compactMap { signingKey($0, in: persona) }, postPolicy: convo.postPolicy,
                         version: convo.version, intros: index(of: convo.id).flatMap { data.conversations[$0].introsMade[recipient] })
    }

    /// A picture shrunk for a group announcement. Every member's avatar and the group's own travel in each
    /// announcement, and full-size ones make it hundreds of kilobytes, many times any message, which is the
    /// one a slow Tor circuit fails to carry. Small ones go as they are; anything that can't be read as a picture,
    /// or claims more than 24 million pixels (a small file can declare gigabytes once opened), is left out. The
    /// picture is shrunk as it's read, never opened at full size, and the answer is remembered so a group of many
    /// people doesn't redo it for each.
    static func thumbnail(_ picture: Data?, side: CGFloat) -> Data? {
        guard let picture, picture.count > 12_000 else { return picture }
        let key = "\(Int(side))|\(picture.count)|" + SHA256.hash(data: picture).prefix(12).map { String(format: "%02x", $0) }.joined()
        if let hit = thumbnailCache[key] { return hit.isEmpty ? nil : hit }
        var result = Data()
        let quiet = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithData(picture as CFData, quiet),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, quiet) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0, width * height <= 24_000_000,
           let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: min(Int(side), max(width, height)),
               kCGImageSourceShouldCache: false,
           ] as CFDictionary) {
            let out = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) {
                // Only the pixels: no metadata is copied from the source.
                CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
                if CGImageDestinationFinalize(dest) { result = out as Data }
            }
        }
        if thumbnailCache.count >= 64 { thumbnailCache.removeAll() }
        thumbnailCache[key] = result
        return result.isEmpty ? nil : result
    }
    private static var thumbnailCache: [String: Data] = [:]

    /// Where the other members first reach `member`: a mailbox made for each of their devices, kept as long as
    /// the group is. Never the mailbox they use with you, which only the two of you should know.
    private func introDevices(of member: Contact, in convoID: UUID) -> [DeviceCard] {
        guard let i = index(of: convoID) else { return [] }
        var made = data.conversations[i].introsMade[member.fingerprint] ?? [:]
        let cards = member.devices.map { device in
            let key = made[device.id.hex] ?? Mailbox.make().receiveKey
            made[device.id.hex] = key
            return DeviceCard(id: device.id, sendID: Mailbox.sendID(for: key))
        }
        data.conversations[i].introsMade[member.fingerprint] = made
        return cards
    }

    /// Set when a contact's device id was just learnt, and at unlock, so `refileIntros` runs on the next beat.
    @ObservationIgnored private var introsStale = true

    /// Puts right the introduction mailboxes of groups you run that were made before you knew a member's device id
    /// (you'd added them a moment earlier and they hadn't written back). Each was filed under no id, and their app
    /// looks its own up by id, so it never found it: nobody else in the group could reach them, and they saw only
    /// what you wrote. Once the id is known the mailbox is filed under it and the member is told again. The mailbox
    /// itself doesn't change, so what the others were given for them still holds.
    private func refileIntros() {
        introsStale = false
        for i in data.conversations.indices where data.conversations[i].amAdmin {
            let convo = data.conversations[i]
            for (fp, made) in convo.introsMade {
                guard let key = made[""], let member = contact(fp, in: convo.persona),
                      let id = member.devices.map(\.id.hex).first(where: { !$0.isEmpty && made[$0] == nil }) else { continue }
                data.conversations[i].introsMade[fp]?[""] = nil
                data.conversations[i].introsMade[fp]?[id] = key
                sendInfo(data.conversations[i], to: [fp])
            }
        }
    }

    private func sendInfo(_ convo: Conversation, to recipients: [String]) {
        for fp in Set(recipients) where fp != "me" {
            guard let peer = contact(fp, in: convo.persona) else { continue }
            enqueue(.group(info(for: convo, to: fp)), to: peer)
        }
    }

    /// Bumps the version and tells everyone who needs to know.
    private func publishChange(_ i: Int, alsoTell extra: [String] = [], channelAdminsOnly: Bool = false) {
        data.conversations[i].version &+= 1
        let c = data.conversations[i]
        let everyone = c.members
        let admins = c.members.filter { c.isAdmin($0) }
        sendInfo(c, to: (c.kind == .channel && channelAdminsOnly ? admins : everyone) + extra)
        syncConversation(c.id)
        save()
    }

    func updateDetails(_ id: Conversation.ID, title: String, about: String, avatar: Data?) {
        guard let i = index(of: id), data.conversations[i].amAdmin else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        data.conversations[i].title = trimmed.isEmpty ? data.conversations[i].title : String(trimmed.prefix(80))
        data.conversations[i].about = about.isEmpty ? nil : String(about.prefix(500))
        data.conversations[i].avatar = avatar
        publishChange(i)
    }

    func setPostPolicy(_ id: Conversation.ID, _ policy: PostPolicy) {
        guard let i = index(of: id), data.conversations[i].amOwner else { return }
        data.conversations[i].postPolicy = policy
        publishChange(i)
    }

    /// Only the owner appoints or removes admins.
    func setAdmin(_ id: Conversation.ID, _ fingerprint: String, _ on: Bool) {
        guard let i = index(of: id), data.conversations[i].amOwner, data.conversations[i].members.contains(fingerprint) else { return }
        data.conversations[i].admins.removeAll { $0 == fingerprint }
        if on {
            data.conversations[i].admins.append(fingerprint)
            data.conversations[i].mods.removeAll { $0 == fingerprint }
        }
        publishChange(i)
    }

    /// Only the owner appoints or removes mods, and only in groups. An admin is already more than a mod.
    func setMod(_ id: Conversation.ID, _ fingerprint: String, _ on: Bool) {
        guard let i = index(of: id), data.conversations[i].amOwner, data.conversations[i].kind == .group,
              data.conversations[i].members.contains(fingerprint), !data.conversations[i].isAdmin(fingerprint) else { return }
        data.conversations[i].mods.removeAll { $0 == fingerprint }
        if on { data.conversations[i].mods.append(fingerprint) }
        publishChange(i)
    }

    /// Adds contacts (of this chat's persona) to a group or channel.
    func addMembers(_ id: Conversation.ID, _ fingerprints: [String]) {
        guard let i = index(of: id), data.conversations[i].amAdmin else { return }
        let persona = data.conversations[i].persona
        let room = max(0, Conversation.maxMembers - data.conversations[i].members.count)
        let new = Array(fingerprints.filter { !data.conversations[i].members.contains($0) && contact($0, in: persona) != nil }.prefix(room))
        guard !new.isEmpty else { return }
        data.conversations[i].members += new
        publishChange(i, alsoTell: new, channelAdminsOnly: true)
    }

    /// Owners can remove anyone; admins can remove people who aren't admins; mods only ordinary members.
    func removeMember(_ id: Conversation.ID, _ fingerprint: String) {
        guard let i = index(of: id) else { return }
        let c = data.conversations[i]
        guard c.canRemove(fingerprint, by: "me"),
              let peer = contact(fingerprint, in: c.persona) else { return }
        enqueue(.removed(conversation: id), to: peer)
        dropMember(fingerprint, at: i)
        publishChange(i, channelAdminsOnly: true)
    }

    func role(of fingerprint: String, in convo: Conversation) -> String? {
        if convo.owner == fingerprint { return "Owner" }
        if convo.admins.contains(fingerprint) { return "Admin" }
        if convo.mods.contains(fingerprint) { return "Mod" }
        return nil
    }
}

// MARK: - Linked devices

extension AppModel {
    /// Your other devices, kept as a hidden contact under your main identity.
    private var selfIndex: Int? { data.contacts.firstIndex { $0.isSelf } }

    private func ensureSelf() -> Int? {
        if let i = selfIndex { return i }
        guard let identity else { return nil }
        var me = Contact(fingerprint: identity.fingerprint, name: "My devices", signingKey: identity.card.signing,
                         agreementKey: identity.card.agreement, sendID: Data(), receiveKey: Mailbox.make().receiveKey, hidden: true)
        me.devices = []
        me.isSelf = true
        data.contacts.append(me)
        return data.contacts.count - 1
    }

    /// The other devices logged in to this account.
    var linkedDevices: [DeviceLink] { selfIndex.map { data.contacts[$0].devices } ?? [] }

    func unlinkDevice(_ id: Data) {
        guard let i = selfIndex else { return }
        data.contacts[i].devices.removeAll { $0.id == id }
        save()
    }

    /// Tells your other devices what you just did. Does nothing while applying their news, so nothing echoes.
    func sync(_ event: SyncEvent) {
        guard !applyingSync, let i = selfIndex, !data.contacts[i].devices.isEmpty else { return }
        enqueue(.sync(event), to: data.contacts[i])
    }

    func syncContact(_ fingerprint: String, _ persona: UUID?) {
        guard let c = contact(fingerprint, in: persona), !c.isSelf else { return }
        sync(.contact(card(of: c)))
    }

    func syncConversation(_ id: Conversation.ID) {
        guard let c = conversation(id), c.kind != .direct else { return }
        sync(.conversation(card(of: c)))
    }

    func ref(_ convo: Conversation) -> ConvoRef {
        ConvoRef(shared: convo.kind == .direct ? nil : convo.id, peer: convo.kind == .direct ? convo.members.first : nil,
                 persona: convo.persona)
    }

    private func card(of c: Contact) -> ContactCard {
        ContactCard(fingerprint: c.fingerprint, name: c.name, nickname: c.nickname, avatar: c.avatar, banner: c.banner, color: c.color,
                    verified: c.verified, signingKey: c.signingKey, agreementKey: c.agreementKey,
                    devices: c.devices.map { DeviceCard(id: $0.id, sendID: $0.sendID) }, relay: c.relay, hidden: c.hidden,
                    awaitingAcceptance: c.awaitingAcceptance, persona: c.persona)
    }

    private func card(of c: Conversation) -> ConversationCard {
        ConversationCard(id: c.id, kind: c.kind, title: c.title, avatar: c.avatar, about: c.about, owner: c.owner,
                         admins: c.admins, postPolicy: c.postPolicy, version: c.version, members: c.members,
                         persona: c.persona, disappearAfter: c.disappearAfter, pinned: c.pinned, muted: c.muted, mods: c.mods)
    }

    private func conversationIndex(for ref: ConvoRef, create: Bool) -> Int? {
        if let shared = ref.shared { return data.conversations.firstIndex { $0.id == shared } }
        guard let peer = ref.peer else { return nil }
        if let found = data.conversations.firstIndex(where: { $0.kind == .direct && $0.members == [peer] && $0.persona == ref.persona }) {
            return found
        }
        guard create, contact(peer, in: ref.persona) != nil else { return nil }
        _ = startConversation(kind: .direct, title: "", members: [peer], persona: .some(ref.persona))
        return data.conversations.firstIndex { $0.kind == .direct && $0.members == [peer] && $0.persona == ref.persona }
    }

    /// Adds a contact (or their new devices) learned from another of your devices, and introduces this device.
    private func adopt(_ card: ContactCard) {
        if let i = contactIndex(card.fingerprint, card.persona) {
            data.contacts[i].name = card.name
            data.contacts[i].nickname = card.nickname
            data.contacts[i].avatar = card.avatar
            data.contacts[i].banner = card.banner
            data.contacts[i].color = card.color
            data.contacts[i].verified = card.verified
            data.contacts[i].hidden = card.hidden
            data.contacts[i].awaitingAcceptance = card.awaitingAcceptance
            for device in card.devices {
                let known = data.contacts[i].devices.contains { (!device.id.isEmpty && $0.id == device.id) || $0.sendID == device.sendID }
                if !known {
                    data.contacts[i].devices.append(DeviceLink(id: device.id, sendID: device.sendID))
                    startHandshake(contact: i, device: data.contacts[i].devices.count - 1)
                }
            }
            return
        }
        guard !myFingerprints.contains(card.fingerprint) else { return }
        var c = Contact(fingerprint: card.fingerprint, name: card.name, nickname: card.nickname, avatar: card.avatar,
                        signingKey: card.signingKey, agreementKey: card.agreementKey, sendID: Data(),
                        receiveKey: Mailbox.make().receiveKey, hidden: card.hidden)
        c.devices = card.devices.map { DeviceLink(id: $0.id, sendID: $0.sendID) }
        c.banner = card.banner
        c.color = card.color
        c.verified = card.verified
        c.relay = card.relay
        c.awaitingAcceptance = card.awaitingAcceptance
        c.persona = card.persona
        upsert(c)
        // Say hello from this device, unless we're still waiting for them to accept a request.
        guard !card.awaitingAcceptance, let i = contactIndex(c.fingerprint, c.persona) else { return }
        for d in data.contacts[i].devices.indices { startHandshake(contact: i, device: d) }
    }

    private func adopt(_ card: ConversationCard) {
        if let i = index(of: card.id) {
            guard card.version >= data.conversations[i].version else { return }
            data.conversations[i].title = card.title
            data.conversations[i].avatar = card.avatar
            data.conversations[i].about = card.about
            data.conversations[i].owner = card.owner
            data.conversations[i].admins = card.admins
            data.conversations[i].mods = card.mods ?? data.conversations[i].mods
            data.conversations[i].postPolicy = card.postPolicy
            data.conversations[i].version = card.version
            data.conversations[i].members = card.members
            data.conversations[i].disappearAfter = card.disappearAfter
            return
        }
        var convo = Conversation(id: card.id, kind: card.kind, title: card.title, avatar: card.avatar, members: card.members)
        convo.about = card.about
        convo.owner = card.owner
        convo.admins = card.admins
        convo.mods = card.mods ?? []
        convo.postPolicy = card.postPolicy
        convo.version = card.version
        convo.persona = card.persona
        convo.disappearAfter = card.disappearAfter
        convo.pinned = card.pinned ?? false
        convo.muted = card.muted ?? false
        withAnimation(.snappy) { data.conversations.insert(convo, at: 0) }
    }

    /// Applies something you did on another of your devices, here.
    func applySync(_ event: SyncEvent) {
        applyingSync = true
        defer { applyingSync = false }
        switch event {
        case .hello:
            break
        case let .callHandled(id):
            // Answered or declined on another of your devices.
            if call?.invite.id == id, call?.outgoing == false, call?.phase == .ringing { stopCall() }
        case let .sent(ref, wire):
            guard let i = conversationIndex(for: ref, create: true),
                  !data.conversations[i].messages.contains(where: { $0.id == wire.id }) else { break }
            let mine = me(ref.persona)?.fingerprint
            let reply = wire.reply.map { ReplyRef(id: $0.id, author: $0.author == mine ? "me" : $0.author, snippet: $0.snippet,
                                                  picture: $0.picture.flatMap { $0.count <= ReplyRef.maxPicture ? $0 : nil }) }
            var message = Message(id: wire.id, sender: "me", text: wire.text, image: wire.image, voice: wire.voice,
                                  date: dated(wire.date), status: .sent,
                                  expiresAt: wire.expiresIn.map { dated(wire.date).addingTimeInterval($0) }, reply: reply,
                                  preview: wire.preview)
            if let clip = wire.clip {
                message.video = Data()
                message.clipSeconds = min(max(clip.seconds, 0), ChatVideo.maxSeconds)
            }
            withAnimation(.snappy) { data.conversations[i].messages.append(message) }
            if wire.clip != nil { assembleClip(wire.id, persona: data.conversations[i].persona) }
        case let .reaction(id, emoji):
            for i in data.conversations.indices {
                if let m = data.conversations[i].messages.firstIndex(where: { $0.id == id }) {
                    data.conversations[i].messages[m].reactions["me"] = emoji
                }
            }
        case let .unsend(ids):
            for i in data.conversations.indices {
                data.conversations[i].messages.removeAll { ids.contains($0.id) && $0.isMine }
            }
        case let .deleted(ref):
            if let i = conversationIndex(for: ref, create: false) { removeLocally(data.conversations[i].id) }
        case let .disappearing(ref, seconds):
            if let i = conversationIndex(for: ref, create: true), data.conversations[i].disappearAfter != seconds {
                applyTimer(seconds, at: i)
            }
        case let .contact(card):
            adopt(card)
        case let .conversation(card):
            adopt(card)
        case let .profile(persona, incoming):
            // Newest wins, so devices that drifted apart settle on the same profile. But not one from a device that
            // knows fewer fields than this one (it would wipe the rest), and one from a newer device can't be read in
            // full, so it waits for an update.
            let current = self.profile(for: persona)
            let theirFormat = incoming.format ?? 0
            guard theirFormat <= profileFormat else { profileNeedsUpdate = true; break }
            guard theirFormat >= (current.format ?? 0) else { break }
            guard (incoming.updatedAt ?? .distantPast) > (current.updatedAt ?? .distantPast) else { break }
            var incoming = incoming
            incoming.links = Optional(ProfileLink.cleaned(incoming.links)).flatMap { $0.isEmpty ? nil : $0 }
            incoming.notes = Optional(ProfileNote.cleaned(incoming.notes, keepAudience: true)).flatMap { $0.isEmpty ? nil : $0 }
            setProfile(incoming, for: persona)
            // Whichever device stopped using a handle let go of it there; this one only follows which are in use,
            // and reads the request mailbox of each.
            readPublicInboxes(of: persona)
        case let .persona(persona):
            if let i = data.personas.firstIndex(where: { $0.id == persona.id }) {
                data.personas[i] = persona
            } else {
                data.personas.append(persona)
            }
        case let .personaDeleted(id):
            deletePersona(id)
        case let .story(story):
            guard removedStories["me|\(story.id)"] == nil else { break }
            if let i = data.stories.firstIndex(where: { $0.id == story.id }) {
                // An edit made on another device. Each device hears about views itself, so keep both lists.
                guard story.author == "me", data.stories[i].author == "me" else { break }
                var edited = story
                edited.viewers = (data.stories[i].viewers ?? [:]).merging(story.viewers ?? [:]) { min($0, $1) }
                data.stories[i] = edited
            } else {
                data.stories.insert(story, at: 0)
            }
        case let .contactRemoved(fingerprint, persona):
            if let c = contact(fingerprint, in: persona), !c.isSelf { forget(c) }
        case let .storyRemoved(id):
            noteRemoved("me|\(id)")
            data.stories.removeAll { $0.id == id && $0.author == "me" }
            dropUnsent(story: id)
        case let .blocked(fp):
            if !data.blocked.contains(fp) { data.blocked.append(fp) }
            data.requests.removeAll { $0.fingerprint == fp }
            // Blocked from a chat on another device: drop them here too.
            for c in data.contacts where c.fingerprint == fp && !c.isSelf {
                if data.blockedNames[fp] == nil { data.blockedNames[fp] = c.displayName }
                forget(c)
            }
        case let .read(ref):
            if let i = conversationIndex(for: ref, create: false) { data.conversations[i].unread = 0 }
        case let .publicInvite(persona, receiveKey, relay):
            adoptPublicInvite(persona: persona, receiveKey: receiveKey, relay: relay)
        case let .requestReceived(request):
            guard !data.blocked.contains(request.fingerprint), contactIndex(request.fingerprint, request.persona) == nil,
                  !data.requests.contains(where: { $0.fingerprint == request.fingerprint && $0.persona == request.persona })
            else { break }
            withAnimation(.snappy) { data.requests.insert(request, at: 0) }
        case let .requestResolved(fingerprint, persona):
            withAnimation(.snappy) { data.requests.removeAll { $0.fingerprint == fingerprint && $0.persona == persona } }
        case let .deviceLoggedOut(id):
            unlinkDevice(id)
        case .accountErased:
            destroyEverything(leavingNoTrace: true)
            Vault.scrubLeftovers()
        case .accountDetached:
            // Contacts stop writing to this device; the account itself waits in the backup.
            for c in data.contacts where !c.isSelf && !c.awaitingAcceptance { enqueue(.deviceRemoved, to: c) }
            Task {
                try? await sendEverything()
                destroyEverything()
            }
        case let .history(id, messages):
            guard let i = index(of: id) else { break }
            let known = Set(data.conversations[i].messages.map(\.id))
            let now = Date()
            let fresh = messages.filter { !known.contains($0.id) && ($0.expiresAt ?? .distantFuture) > now }
            guard !fresh.isEmpty else { break }
            data.conversations[i].messages.append(contentsOf: fresh)
            data.conversations[i].messages.sort { $0.date < $1.date }
        }
    }

    /// Reads the same public mailbox as your other devices, so a request to your @handle reaches all of them.
    private func adoptPublicInvite(persona: UUID?, receiveKey: Data?, relay: String?) {
        guard let receiveKey else {
            data.invites.removeAll { $0.isPublic && $0.persona == persona }
            return
        }
        if !data.invites.contains(where: { $0.receiveKey == receiveKey }) {
            data.invites.append(OpenInvite(receiveKey: receiveKey, persona: persona, relay: relay, isPublic: true))
        }
        readPublicInboxes(of: persona, and: receiveKey)
    }

    /// Makes sure this device reads the request mailbox of every handle a persona has in use (each is worked out
    /// from the account and the handle, so every device arrives at the same ones), and winds down any other.
    private func readPublicInboxes(of persona: UUID?, and extra: Data? = nil) {
        guard let me = me(persona) else { return }
        var keys = Set(profile(for: persona).activeHandles.map { me.publicInboxKey(handle: $0) })
        for key in keys {
            if let i = data.invites.firstIndex(where: { $0.receiveKey == key }) {
                data.invites[i].retiresAt = nil
            } else {
                data.invites.append(OpenInvite(receiveKey: key, persona: persona, isPublic: true))
            }
        }
        if let extra { keys.insert(extra) }
        retirePublicInvites(of: persona, except: keys)
    }

    /// Sends your other devices a persona's public mailbox and profile together.
    func syncPublicProfile(_ persona: UUID?) {
        let invite = data.invites.first { $0.isPublic && $0.persona == persona && $0.retiresAt == nil }
        sync(.publicInvite(persona: persona, receiveKey: profile(for: persona).handle == nil ? nil : invite?.receiveKey,
                           relay: invite?.relay))
        sync(.profile(persona: persona, profile(for: persona)))
    }

    /// On unlock, tells your other devices how your profiles look here. Whichever is newest wins everywhere,
    /// which also heals devices that drifted apart.
    func announceProfiles() {
        guard !linkedDevices.isEmpty else { return }
        syncPublicProfile(nil)
        for persona in data.personas where !persona.isBurner { syncPublicProfile(persona.id) }
    }

    // MARK: Linking a new device (the device that's already logged in)

    /// A fresh QR code for linking a new device.
    func makeLinkCode() -> String {
        let offer = LinkOffer(receiveKey: Mailbox.make().receiveKey, secret: .random(32))
        data.linkOffers.removeAll { $0.createdAt < Date().addingTimeInterval(-15 * 60) }
        data.linkOffers.append(offer)
        save()
        return LinkCode(secret: offer.secret, sendID: Mailbox.sendID(for: offer.receiveKey), relay: data.relay).text
    }

    /// A device that scanned the code and is waiting for you to approve it.
    var pendingLink: (offer: LinkOffer, request: LinkRequest)? {
        guard let offer = data.linkOffers.last(where: { $0.request != nil }), let request = offer.request else { return nil }
        return (offer, request)
    }

    enum ScanResult { case device, contact(Contact), chat(Conversation.ID), expired, unknown, refused }

    /// What a code would do, shown for a yes before anything happens.
    struct CodePreview: Equatable {
        enum Kind: Equatable { case contact, channel, chat(endsAt: Date), device }
        var kind: Kind
        /// A relay the code names that isn't yours: it would see your connection from then on.
        var relay: String?
    }

    func inspectCode(_ text: String) -> CodePreview? {
        let code = scannedPayload(text)
        if let link = ChatLink(code) { return CodePreview(kind: .chat(endsAt: link.endsAt), relay: foreignRelay(Invite(code: link.invite)?.relay)) }
        if JoinCode(code) != nil { return CodePreview(kind: .device) }
        guard let invite = Invite(code: code) else { return nil }
        return CodePreview(kind: invite.kind == .channel ? .channel : .contact, relay: foreignRelay(invite.relay))
    }

    private func foreignRelay(_ relay: String?) -> String? {
        guard let relay, relay != data.relay else { return nil }
        return relay
    }

    /// Whatever the camera read: a new device's code waits for approval, a friend's invite adds them,
    /// a one-time chat link opens its chat. A code that arrived as a link from another app never links a
    /// device: only the camera, pointed at your own new device, can do that.
    func useScannedCode(_ text: String, fromLink: Bool = false) -> ScanResult {
        let code = scannedPayload(text)
        if let link = ChatLink(code) {
            return joinChatLink(link).map(ScanResult.chat) ?? .expired
        }
        if JoinCode(code) != nil && fromLink { return .refused }
        if acceptJoinCode(code) { return .device }
        if Invite(code: code) != nil, let contact = addContact(code: code, nickname: "") { return .contact(contact) }
        return .unknown
    }

    /// A code shown by a new device: it waits to be approved like any device that scanned yours.
    func acceptJoinCode(_ text: String) -> Bool {
        guard let code = JoinCode(text) else { return false }
        // "This machine" on the new device means nothing here; it's then on the same relay as you.
        let relay = LinkCode(secret: code.secret, sendID: Data(), relay: code.relay).reachableRelay
        var offer = LinkOffer(receiveKey: Mailbox.make().receiveKey, secret: code.secret)
        offer.request = code.request
        offer.relay = relay == AppData.defaultRelay || relay == data.relay ? nil : relay
        data.linkOffers.removeAll { $0.request != nil }
        withAnimation(.snappy) { data.linkOffers.append(offer) }
        save()
        return true
    }

    /// The first device to answer a code is the only one: anyone who saw the code afterwards can't take its place.
    func receiveLinkRequest(_ blob: Data, offer i: Int) {
        let offer = data.linkOffers[i]
        guard offer.request == nil, let box = try? ChaChaPoly.SealedBox(combined: blob),
              let plain = try? ChaChaPoly.open(box, using: LinkCrypto.requestKey(offer.secret)),
              let request = try? JSONDecoder().decode(LinkRequest.self, from: plain),
              request.deviceID.count == 16, request.ephemeral.count == 32 else { return }
        withAnimation(.snappy) { data.linkOffers[i].request = request }
    }

    func cancelLink() {
        data.linkOffers.removeAll()
        save()
    }

    /// Approves the waiting device: sends it the account, encrypted to it, and starts keeping it in sync.
    func approveLink() {
        guard let identity, let (offer, request) = pendingLink, let selfIndex = ensureSelf(),
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.ephemeral) else { return }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: theirs) else { return }

        let me = data.contacts[selfIndex]
        let siblings = [DeviceCard(id: data.deviceID, sendID: Mailbox.sendID(for: me.receiveKey ?? Data()), name: deviceDisplayName)]
            + me.devices.map { DeviceCard(id: $0.id, sendID: $0.sendID, name: $0.name) }
        let bundle = LinkBundle(seed: identity.seed, profile: data.profile, personas: data.personas,
                                contacts: data.contacts.filter { !$0.isSelf }.map(card(of:)),
                                conversations: data.conversations.map(card(of:)),
                                theme: data.theme, relay: data.relay, inviteRelay: data.inviteRelay, security: data.security,
                                blocked: data.blocked, siblings: siblings,
                                publicInvites: data.invites.filter(\.isPublic), requests: data.requests)
        guard let plain = try? JSONEncoder.pulshade.encode(bundle),
              let sealed = try? ChaChaPoly.seal(plain, using: LinkCrypto.bundleKey(shared, secret: offer.secret)).combined else { return }
        data.outbox.append(Outgoing(sendID: request.bundleSendID, blob: ephemeral.publicKey.rawRepresentation + sealed, relay: offer.relay))

        var link = DeviceLink(id: request.deviceID, sendID: request.selfSendID)
        link.name = String(request.name.prefix(60))
        // Message history and stories follow once the new device opens its session with this one.
        link.pending = historyForNewDevice().map { PendingPayload(payload: .sync($0), message: nil) }
        data.contacts[selfIndex].devices.removeAll { $0.id == request.deviceID }
        data.contacts[selfIndex].devices.append(link)
        // This device opens the session with the new one, and the new one only answers. If both opened one
        // at once, a late loser could replace the session the history was already sent on.
        startHandshake(contact: selfIndex, device: data.contacts[selfIndex].devices.count - 1)
        data.linkOffers.removeAll()
        save()
        kick()
    }

    /// Every chat's past messages, in pieces small enough for the relay, then live stories.
    private func historyForNewDevice() -> [SyncEvent] {
        let limit = 1_000_000
        let now = Date()
        var events: [SyncEvent] = []
        for convo in data.conversations {
            var chunk: [Message] = []
            var size = 0
            for message in convo.messages where (message.expiresAt ?? .distantFuture) > now {
                let bytes = (try? JSONEncoder.pulshade.encode(message).count) ?? 0
                if !chunk.isEmpty && size + bytes > limit {
                    events.append(.history(conversation: convo.id, messages: chunk))
                    chunk = []
                    size = 0
                }
                chunk.append(message)
                size += bytes
            }
            if !chunk.isEmpty { events.append(.history(conversation: convo.id, messages: chunk)) }
        }
        events += data.stories.filter { $0.isLive && $0.isSyncable }.map { .story($0) }
        return events
    }

    // MARK: Becoming a linked device (the new device)

    /// Sets this device up as another device of the account in the bundle, then introduces it to everyone.
    func finishLink(_ bundle: LinkBundle, deviceID: Data, selfMailbox: Mailbox, relay: String, passcode: String) async throws {
        let identity = try Identity(seed: bundle.seed)
        let vault = vault
        try await Task.detached { try vault.create(identity, passcode: passcode) }.value
        self.identity = identity
        slot = 0
        var fresh = AppData()
        fresh.deviceID = deviceID
        fresh.profile = bundle.profile
        fresh.personas = bundle.personas
        fresh.theme = bundle.theme
        fresh.relay = relay
        fresh.inviteRelay = bundle.inviteRelay
        fresh.security = bundle.security
        fresh.blocked = bundle.blocked
        fresh.invites = bundle.publicInvites ?? []
        fresh.requests = bundle.requests ?? []
        data = fresh
        adoptConnectionChoice()

        // Your other devices.
        var me = Contact(fingerprint: identity.fingerprint, name: "My devices", signingKey: identity.card.signing,
                         agreementKey: identity.card.agreement, sendID: Data(), receiveKey: selfMailbox.receiveKey, hidden: true)
        me.devices = bundle.siblings.map {
            var link = DeviceLink(id: $0.id, sendID: $0.sendID)
            link.name = $0.name
            link.awaitingHello = $0.id == bundle.siblings.first?.id ? true : nil
            return link
        }
        me.isSelf = true
        data.contacts.append(me)

        applyingSync = true
        for card in bundle.conversations { adopt(card) }
        applyingSync = false
        // Contacts last: adopting them says hello from this device.
        for card in bundle.contacts { adopt(card) }
        // The device that approved this one opens its own session with us; introduce ourselves to the rest.
        if let i = selfIndex {
            for d in data.contacts[i].devices.indices where data.contacts[i].devices[d].id != bundle.siblings.first?.id {
                startHandshake(contact: i, device: d)
            }
        }
        didUnlock()
    }
}

// MARK: - Detach & burn

extension AppModel {
    enum LeaveError: Error { case wrongRecoveryCode, offline, backupNotRemoved }

    /// Whether this account also lives on another device, so detaching only this one loses nothing.
    var hasOtherDevices: Bool { !linkedDevices.isEmpty }

    enum DetachScope { case thisDevice, everyDevice }

    /// Takes the account off this device (or every device), keeping everything but the chats.
    ///
    /// Only this device, with others still on the account: they drop it from their list and contacts stop
    /// sending here; nothing else changes. Otherwise the recovery code is needed first. The account (profile,
    /// @handles, contacts, groups, personas, settings) is sealed and left on the relay for it, without a
    /// single message, story or request, and every device is wiped.
    func detach(_ scope: DetachScope, recoveryCode: String? = nil) async throws {
        try open(recoveryCode: recoveryCode)
        guard let identity else { return }
        if scope == .thisDevice && hasOtherDevices {
            for c in data.contacts where !c.isSelf && !c.awaitingAcceptance { enqueue(.deviceRemoved, to: c) }
            sync(.deviceLoggedOut(data.deviceID))
            try await sendEverything()
            destroyEverything()
            return
        }
        guard let code = recoveryCode, Identity.seed(fromRecoveryCode: code) == identity.seed else {
            throw LeaveError.wrongRecoveryCode
        }
        if hasOtherDevices {
            sync(.accountDetached)
            try await sendEverything()
        }
        try await leaveBackup(of: identity)
        destroyEverything()
    }

    /// Burns the account: as if it never existed. Every chat goes for both sides, every contact forgets it,
    /// every @handle is retired (unclaimable for three months, tied to no key), the relay's backup and waiting
    /// envelopes are gone, every device it's on is
    /// wiped, and this one keeps nothing, not even a Keychain item.
    ///
    /// `thisDeviceOnly` is for when the relay can't be reached: it wipes this device at once and nothing else.
    /// The relay's copy of the backup stays (it opens only with the recovery code and the relay erases it 180 days
    /// after its last save), handles are not retired and contacts are not told.
    @discardableResult
    func burn(recoveryCode: String? = nil, thisDeviceOnly: Bool = false) async throws -> BurnResult {
        try open(recoveryCode: recoveryCode)
        if thisDeviceOnly {
            data.security.keepBackup = false
            backupTask?.cancel()
            backupTask = nil
            destroyEverything(leavingNoTrace: true)
            Vault.scrubLeftovers()
            burnNotice = "This device is wiped. Your account is still on the server."
            return .deviceOnly
        }
        guard let identity else { throw LeaveError.offline }
        // No upload may land after the delete.
        data.security.keepBackup = false
        backupTask?.cancel()
        backupTask = nil
        // Everything to take back from contacts is queued, sealed, but nothing has to be sent yet: it all goes into the order.
        burning = true
        let outboxBefore = Set(data.outbox.map(\.id))
        for id in data.conversations.map(\.id) { delete(id) }
        for c in data.contacts where !c.isSelf {
            // Someone we only sent a request to has no session with us yet, so it goes straight to them.
            if c.awaitingAcceptance { seal(.erased, to: c.fingerprint, persona: c.persona) } else { enqueue(.erased, to: c) }
        }
        for id in data.stories.filter({ $0.author == "me" }).map(\.id) { deleteStory(id) }
        sync(.accountErased)
        let order = makeBurnOrder(identity: identity, outboxBefore: outboxBefore)
        burning = false
        // The order is kept first, so a crash from here on still finishes on the relay. Then one go, briefly.
        burnStore.save(order)
        let attempt = Task { await self.attemptBurnCleanup() }
        let timer = Task { try? await Task.sleep(for: .seconds(20)); attempt.cancel() }
        let finished = await attempt.value
        timer.cancel()
        // Whatever the relay said, the phone is wiped now.
        destroyEverything(leavingNoTrace: true)
        Vault.scrubLeftovers()
        if finished { return .complete }
        burnNotice = "This phone is wiped. Pulshade is finishing the erase on the server and will keep trying until it is done."
        startBurnLoop()
        return .pending
    }

    /// Everything a Burn still has to do on the relay, signed now while the keys are known: erase the backup, retire the
    /// handles, take back what is still waiting, erase the files, empty and close every mailbox, and drop the farewells.
    private func makeBurnOrder(identity: Identity, outboxBefore: Set<UUID>) -> BurnOrder {
        let ts = UInt64(RelayClock.now.timeIntervalSince1970)
        func signed(_ label: String, key: Data, by signer: Curve25519.Signing.PrivateKey) -> BurnOrder.Signed {
            let message = Data(label.utf8) + key + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
            return BurnOrder.Signed(key: key, sig: (try? signer.signature(for: message)) ?? Data())
        }
        var order = BurnOrder(ts: ts, relay: reachable(nil) ?? data.relay)
        order.backup = signed("pulshade.burn.backup.v1", key: identity.backupSigningKey.publicKey.rawRepresentation, by: identity.backupSigningKey)
        let personas: [UUID?] = [nil] + data.personas.map { Optional($0.id) }
        for persona in personas {
            guard let me = me(persona) else { continue }
            order.handles.append(signed("pulshade.burn.retire.v1", key: me.card.signing, by: me.signingKey))
            order.recall.append(me.recallKey)
        }
        order.blobs = data.blobWipes
        order.mailboxes = Array(Set(currentLanes().values.flatMap { $0 })).prefix(2048).map { $0 }
        var room = 4_000_000
        for item in data.outbox where !outboxBefore.contains(item.id) {
            guard let address = reachable(item.relay), room >= item.blob.count else { continue }
            room -= item.blob.count
            order.farewells.append(BurnOrder.Farewell(sendID: item.sendID, blob: item.blob, relay: address))
        }
        return order
    }

    /// One go at finishing the burn order kept on this phone. True when nothing is left to do (or there is no order).
    func attemptBurnCleanup() async -> Bool {
        guard var order = burnStore.load() else {
            if !burnStore.exists { burnPending = false; return true }
            // Can't be opened (its key is gone, or the phone hasn't been unlocked yet): tried again, but not for ever.
            let made = (try? burnStore.file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            if Date().timeIntervalSince(made) > 30 * 86_400 { burnStore.delete(); burnPending = false; return true }
            return false
        }
        if order.isTooOld {
            burnStore.delete()
            burnPending = false
            burnNotice = "Pulshade couldn't finish erasing your account on the server within 30 days. Your phone is wiped, and what is left there can't be opened."
            return true
        }
        guard let base = URL(string: order.relay) else { burnStore.delete(); burnPending = false; return true }
        let client = RelayClient(base: base, lane: "burn")
        if !order.serverDone, let body = try? order.requestBody(), (try? await client.burn(body)) != nil {
            order.serverDone = true
            burnStore.save(order)
        }
        // The farewells, a few at a time; each that is taken is crossed off.
        var left = order.farewells
        while !left.isEmpty, !Task.isCancelled {
            let batch = Array(left.prefix(6))
            let sent = await withTaskGroup(of: (BurnOrder.Farewell, Bool).self) { group in
                for farewell in batch {
                    group.addTask {
                        guard let url = URL(string: farewell.relay) else { return (farewell, true) }
                        do { try await RelayClient(base: url, lane: "burn").deposit(farewell.blob, to: farewell.sendID); return (farewell, true) }
                        catch is RelayTooLarge { return (farewell, true) }
                        catch { return (farewell, false) }
                    }
                }
                var done: [BurnOrder.Farewell] = []
                for await (farewell, ok) in group where ok { done.append(farewell) }
                return done
            }
            left.removeAll { sent.contains($0) }
            if sent.count < batch.count { break }
        }
        if left != order.farewells { order.farewells = left; burnStore.save(order) }
        guard order.isFinished else { return false }
        burnStore.delete()
        burnPending = false
        burnNotice = "Burn complete. Everything is erased from the server and from this device."
        return true
    }

    /// Tries the burn order now, again a minute later, then every hour, until the relay confirms.
    func startBurnLoop() {
        burnTask?.cancel()
        burnPending = true
        burnTask = Task { [weak self] in
            var early: [Double] = [60, 300, 900]
            while !Task.isCancelled {
                guard let self else { return }
                if await self.attemptBurnCleanup() { return }
                try? await Task.sleep(for: .seconds(early.isEmpty ? 3600 : early.removeFirst()))
            }
        }
    }

    /// At launch: a burn that wasn't finished carries on.
    func resumeBurnCleanup() {
        guard burnStore.exists else { return }
        startBurnLoop()
    }

    /// Burns one persona for good, leaving your main identity and other personas as they are: its @handles are
    /// retired, its chats deleted for both sides, its contacts told to forget it, and once that's sent, its keys and
    /// everything else of it go from all your devices. Its collectibles stay claimable with its backup code.
    func burnPersona(_ id: UUID) async throws {
        guard data.personas.contains(where: { $0.id == id }), let client = client(nil), await client.health() else {
            throw LeaveError.offline
        }
        await retireHandles(persona: id)
        for convo in data.conversations where convo.persona == id { delete(convo.id) }
        for c in data.contacts where c.persona == id && !c.isSelf {
            if c.awaitingAcceptance { seal(.erased, to: c.fingerprint, persona: id) } else { enqueue(.erased, to: c) }
        }
        for story in data.stories where story.author == "me" && story.persona == id { deleteStory(story.id) }
        await runBlobWipes().value
        try await sendEverything()
        // Collects whatever is still waiting in its mailboxes, so the relay doesn't hold it for days.
        let shaping = trafficShaping
        trafficShaping = false
        await syncOnce()
        trafficShaping = shaping
        data.requests.removeAll { $0.persona == id }
        deletePersona(id)
    }

    /// From the lock screen there's no passcode: the recovery code opens the account just long enough to
    /// leave. Only this device's own account opens; the screen stays locked throughout.
    private func open(recoveryCode: String?) throws {
        guard identity == nil else { return }
        guard let code = recoveryCode, let seed = Identity.seed(fromRecoveryCode: code),
              let identity = try? Identity(seed: seed),
              let stored = try? vault.load(with: identity) else { throw LeaveError.wrongRecoveryCode }
        self.identity = identity
        slot = 0
        data = stored
    }

    /// Sends Detach or Burn's farewells from the lock screen, then locks again if they couldn't go.
    func leaveFromLock(burning: Bool, recoveryCode: String) async throws {
        do {
            if burning { try await burn(recoveryCode: recoveryCode) } else { try await detach(.thisDevice, recoveryCode: recoveryCode) }
        } catch {
            if phase == .locked {
                identity = nil
                data = AppData()
            }
            throw error
        }
    }

    /// Everything a detached account keeps: no direct chats, no messages in groups or channels, no stories,
    /// requests, reports, one-time chats or unsent envelopes. Groups and channels stay so you're still in them.
    static func withoutChats(_ data: AppData, keepingDevices: Bool) -> AppData {
        var kept = data
        kept.conversations = data.conversations.filter { $0.kind != .direct }.map {
            var c = $0
            c.messages = []
            return c
        }
        kept.stories = []
        kept.requests = []
        kept.outbox = []
        kept.chatCodes = []
        kept.linkOffers = []
        if !keepingDevices, let i = kept.contacts.firstIndex(where: \.isSelf) { kept.contacts[i].devices = [] }
        return kept
    }

    /// `unreadable`: a copy is on the relay but this version can't open it (it may come from a newer one). It must
    /// not be taken for no backup, or starting over would later save across it.
    enum BackupLookup { case found(AppData), none, unreachable, unreadable }

    /// The account a log out left on the relay, opened with the recovery code's key.
    func backup(of identity: Identity) async -> BackupLookup {
        guard let client = client(nil, lane: "backup") else { return .unreachable }
        let (key, sig, ts) = backupProof("pulshade.backup.get.v1", identity)
        let sealed: Data?
        do { sealed = try await client.backup(key: key, sig: sig, ts: ts) } catch { return .unreachable }
        guard let sealed else { return .none }
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: identity.backupKey),
              let restored = try? JSONDecoder.pulshade.decode(AppData.self, from: Self.unpadded(plain)) else { return .unreadable }
        return .found(restored)
    }

    private func deleteBackup(of identity: Identity) async throws {
        guard let client = client(nil, lane: "backup") else { throw LeaveError.offline }
        let (key, sig, ts) = backupProof("pulshade.backup.del.v1", identity)
        try await client.deleteBackup(key: key, sig: sig, ts: ts)
    }

    /// Stops syncing so nothing changes after the snapshot, then seals everything and leaves it on the relay.
    /// If it can't be left there, syncing starts again and nothing on this device is touched.
    private func leaveBackup(of identity: Identity) async throws {
        syncTask?.cancel()
        while syncing { try? await Task.sleep(for: .milliseconds(50)) }
        await flush()
        do {
            guard let client = client(nil, lane: "backup") else { throw LeaveError.offline }
            let sealed = try Self.sealedBackup(of: data, with: identity)
            let (key, sig, ts) = backupProof("pulshade.backup.put.v1", identity, body: sealed)
            try await client.putBackup(sealed, key: key, sig: sig, ts: ts, forgetHash: forgetHash)
        } catch {
            startSync()
            throw LeaveError.offline
        }
    }

    // MARK: Keeping the backup fresh

    /// A hash of the panic passcode's delete-only token, sent with each backup so the relay can honour it.
    private var forgetHash: Data? {
        data.panicSeed.map { Data(SHA256.hash(data: Self.forgetToken(landingSeed: $0))) }
    }

    /// What goes in a backup: everything but chats, and not the two fields that track the backup itself.
    static func backupContents(of data: AppData) -> AppData {
        var kept = withoutChats(data, keepingDevices: false)
        kept.backupSavedAt = nil
        kept.backupDigest = nil
        // Nothing you wrote that is still waiting to be sent: that is chat, and chats never go in the backup.
        // Session keys do stay, so mail sent to you while the device was detached can still be opened.
        for c in kept.contacts.indices {
            for d in kept.contacts[c].devices.indices {
                kept.contacts[c].devices[d].pending.removeAll { $0.message != nil }
            }
        }
        // Nor story video still arriving, or the decoy and panic identities, which live only on the device
        // they were set up on.
        kept.clipParts = [:]
        kept.decoySeed = nil
        kept.panicSeed = nil
        kept.pendingBackupForget = nil
        return kept
    }

    /// Pads to a power of two (at least 64 KB) behind a marker and the real length, so the relay learns a rough size
    /// class and not how many contacts there are. The old, unpadded form starts with `{`, never with the marker.
    static func padded(_ plain: Data) -> Data {
        var size = 64 * 1024
        while size < plain.count + 5 { size *= 2 }
        var out = Data([0x01])
        withUnsafeBytes(of: UInt32(plain.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(plain)
        out.append(Data(count: size - out.count))
        return out
    }

    static func unpadded(_ data: Data) -> Data {
        guard data.first == 0x01, data.count >= 5 else { return data }
        let length = data.dropFirst().prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard 5 + length <= data.count else { return data }
        return data.subdata(in: 5..<(5 + length))
    }

    static func sealedBackup(of data: AppData, with identity: Identity) throws -> Data {
        let plain = try JSONEncoder.pulshade.encode(backupContents(of: data))
        return try AES.GCM.seal(padded(plain), using: identity.backupKey).combined!
    }

    /// Called after every save: waits a random few minutes, then saves the backup if anything in it changed.
    /// Only the main identity does it, never a decoy.
    func scheduleBackup(after wait: ClosedRange<Int>? = nil) {
        guard backupTask == nil, data.security.keepBackup, isPrimary, phase == .unlocked else { return }
        let range = wait ?? Self.backupWait
        backupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Int.random(in: range)))
            guard !Task.isCancelled, let self else { return }
            self.backupTask = nil
            await self.saveBackup()
        }
    }

    /// Seals and uploads the backup if it changed (or is a week old). Quiet on failure: it tries again later.
    @discardableResult
    func saveBackup() async -> Bool {
        guard data.security.keepBackup, isPrimary, phase == .unlocked, let identity, let client = client(nil, lane: "backup") else { return false }
        // Keys in a fixed order, so the same account always encodes to the same bytes and an unchanged one is
        // never uploaded again.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        guard let plain = try? encoder.encode(Self.backupContents(of: data)) else { return false }
        let digest = Data(SHA256.hash(data: plain))
        let week = data.backupSavedAt.map { Date().timeIntervalSince($0) > 7 * 24 * 3600 } ?? true
        if digest == data.backupDigest, !week { return true }
        guard let sealed = try? AES.GCM.seal(Self.padded(plain), using: identity.backupKey).combined else { return false }
        let (key, sig, ts) = backupProof("pulshade.backup.put.v1", identity, body: sealed)
        do { try await client.putBackup(sealed, key: key, sig: sig, ts: ts, forgetHash: forgetHash) } catch {
            // Try again in a while.
            scheduleBackup(after: 300...900)
            return false
        }
        // Nothing of the account changed, so this save doesn't ask for another upload.
        guard self.identity?.fingerprint == identity.fingerprint, data.security.keepBackup else { return true }
        data.backupDigest = digest
        data.backupSavedAt = Date()
        save()
        return true
    }

    /// One line for Settings and the Detach screen: how fresh the relay's copy is.
    var backupStatus: String {
        guard data.security.keepBackup else { return "Backups are off" }
        guard let saved = data.backupSavedAt else { return "Not saved yet" }
        let seconds = Int(Date().timeIntervalSince(saved))
        if seconds < 60 { return "Saved just now" }
        if seconds < 3600 { return "Saved \(seconds / 60) min ago" }
        if seconds < 86400 { return "Saved \(seconds / 3600) h ago" }
        return "Saved \(seconds / 86400) d ago"
    }

    /// The switch in Settings. Off also takes the copy off the relay.
    func setKeepBackup(_ on: Bool) {
        data.security.keepBackup = on
        if on {
            scheduleBackup(after: 0...5)
        } else {
            backupTask?.cancel()
            backupTask = nil
            data.backupSavedAt = nil
            data.backupDigest = nil
            if let identity { Task { try? await deleteBackup(of: identity) } }
        }
        save()
    }

    /// `label | backup key | ts`, plus the contents' hash for an upload, signed with the backup key.
    /// The delete-only token for the relay backup: made from the panic landing account's seed, so the panic passcode
    /// (which opens that account and nothing real) can work it out without holding any key to the real account. It
    /// can erase the backup and do nothing else with it.
    static func forgetToken(landingSeed: Data) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: landingSeed), info: Data("pulshade.backup.forget.v1".utf8),
                               outputByteCount: 32).bytes
    }

    /// After the panic passcode: asks the relay to erase the real account's backup, trying again at each unlock
    /// until it has answered.
    func forgetPendingBackup() async {
        guard let key = data.pendingBackupForget, let seed = identity?.seed, let client = client(nil, lane: "backup") else { return }
        guard let status = try? await client.forgetBackup(key: key, token: Self.forgetToken(landingSeed: seed)) else { return }
        // 410: nothing to erase. 404 would be a relay that doesn't know this yet, so it is tried again later.
        if (200..<300).contains(status) || status == 410 || status == 401 {
            data.pendingBackupForget = nil
            save()
        }
    }

    private func backupProof(_ label: String, _ identity: Identity, body: Data? = nil) -> (key: Data, sig: Data, ts: UInt64) {
        let signer = identity.backupSigningKey
        let key = signer.publicKey.rawRepresentation
        let ts = UInt64(RelayClock.now.timeIntervalSince1970)
        var message = Data(label.utf8) + key + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
        if let body { message += Data(SHA256.hash(data: body)) }
        return (key, (try? signer.signature(for: message)) ?? Data(), ts)
    }

    /// Sends everything waiting, retrying briefly. Throws if the relay can't be reached.
    private func sendEverything() async throws {
        for _ in 0..<20 {
            await flush()
            if data.outbox.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw LeaveError.offline
    }

    /// Someone erased their account: they, their chats, messages, stories and requests all go.
    func eraseTraces(of fp: String) {
        withAnimation(.snappy) {
            data.requests.removeAll { $0.fingerprint == fp }
            data.stories.removeAll { $0.author == fp }
            data.conversations.removeAll { ($0.kind == .direct && $0.members == [fp]) || $0.owner == fp }
            // Every chat, not just ones they're still in: leaving first doesn't keep their messages behind.
            for i in data.conversations.indices {
                data.conversations[i].messages.removeAll { $0.sender == fp }
                // Their reactions, and the quotes of their words in replies.
                for m in data.conversations[i].messages.indices {
                    data.conversations[i].messages[m].reactions[fp] = nil
                    if data.conversations[i].messages[m].reply?.author == fp { data.conversations[i].messages[m].reply = nil }
                }
                data.conversations[i].members.removeAll { $0 == fp }
                data.conversations[i].admins.removeAll { $0 == fp }
                data.conversations[i].mods.removeAll { $0 == fp }
            }
            data.contacts.removeAll { $0.fingerprint == fp && !$0.isSelf }
        }
        save()
    }
}

// MARK: - Reports

extension AppModel {
    enum ReportError: Error { case notSetUp, unreachable }

    /// Sends a report to the Pulshade team, sealed to the admin app's key so the relay can't read it. The relay
    /// says where the admin app's mailbox is, but only an address signed by the admin key built into the app is used.
    /// It's sent from a throwaway identity, so the report says nothing about who you are unless you add your
    /// @handle.
    func report(subjectKey: Data, handle: String?, name: String, reason: String, details: String,
                includeHandle: Bool = false) async throws {
        guard identity != nil, let client = client(nil, lane: "report") else { throw ReportError.unreachable }
        let inbox: ReportInbox?
        do { inbox = try await client.reportInbox() } catch { throw ReportError.unreachable }
        guard let inbox, Self.genuine(inbox), let sendID = Data(base64Encoded: inbox.sendID),
              let agreement = Data(base64Encoded: inbox.agreementKey) else { throw ReportError.notSetUp }
        let card = ReportCard(subjectKey: subjectKey, subjectHandle: handle, subjectName: String(name.prefix(64)),
                              reason: reason, details: String(details.prefix(1000)),
                              reporterHandle: includeHandle ? activeProfile.handle : nil)
        let blob = try ReportSeal.seal(card, to: agreement)
        data.outbox.append(Outgoing(sendID: sendID, blob: blob, relay: nil))
        save()
        await flush()
    }

    /// Whether a reports mailbox really is the admin app's: signed by the admin key built into the app.
    private static func genuine(_ inbox: ReportInbox) -> Bool {
        inbox.isGenuine(adminKey: adminKey)
    }

}

// MARK: - Calls

/// A call ringing or in progress: who with, which of your personas, and how far it's got.
struct ActiveCall: Equatable {
    enum Phase: Equatable { case ringing, connecting, live(since: Date) }
    var invite: CallInvite
    var peer: String
    var persona: UUID?
    var outgoing: Bool
    var phase: Phase
    var muted = false
    var speaker = false
}

extension AppModel {
    /// Rings someone. Their devices all ring; the first to pick up gets the call.
    func startCall(with fingerprint: String, persona: UUID?) {
        guard call == nil, let contact = contact(fingerprint, in: persona), !contact.hidden else { return }
        let invite = CallInvite(id: UUID(), room: .random(32), key: .random(32))
        call = ActiveCall(invite: invite, peer: fingerprint, persona: persona, outgoing: true, phase: .ringing,
                          speaker: Platform.isPhone)
        enqueue(.callOffer(invite), to: contact)
        save()
        kick()
        // Wait in the room so the audio can start the moment they answer.
        connectCall()
        // The caller hears Pulshade's ringing until they pick up.
        callMedia?.setRinging(true)
        // Long enough for a locked phone to be answered, unlocked and to fetch the call over Tor.
        ringFor(seconds: 90, else: "No answer")
    }

    func answerCall() {
        guard var current = call, !current.outgoing, current.phase == .ringing,
              let contact = contact(current.peer, in: current.persona) else { return }
        current.phase = .connecting
        call = current
        callTimeout?.cancel()
        #if os(iOS)
        CallRinger.shared.answeredInApp()
        #endif
        enqueue(.callAnswer(id: current.invite.id, accepted: true), to: contact)
        sync(.callHandled(current.invite.id))
        save()
        kick()
        connectCall()
    }

    func declineCall() {
        guard let current = call, !current.outgoing, current.phase == .ringing else { return }
        if let contact = contact(current.peer, in: current.persona) {
            enqueue(.callAnswer(id: current.invite.id, accepted: false), to: contact)
        }
        sync(.callHandled(current.invite.id))
        noteCall("Declined call", current)
        stopCall()
        save()
        kick()
    }

    /// Hangs up, or stops ringing someone.
    func hangUp() {
        guard let current = call else { return }
        if current.outgoing, current.phase == .ringing {
            endCall(note: "Cancelled call", tell: true)
        } else if !current.outgoing, current.phase == .ringing {
            declineCall()
        } else {
            endCall(note: nil, tell: true)
        }
    }

    func toggleMute() {
        guard var current = call else { return }
        current.muted.toggle()
        call = current
        callMedia?.muted = current.muted
    }

    func toggleSpeaker() {
        guard var current = call else { return }
        current.speaker.toggle()
        call = current
        callMedia?.setSpeaker(current.speaker)
    }

    /// The iPhone is at your ear: the earpiece, whatever the speaker button says. Away again, back as it was.
    func heldToEar(_ near: Bool) {
        guard let current = call else { return }
        callMedia?.setSpeaker(near ? false : current.speaker)
    }

    /// The other side's connection, for tests: what arrived, and a way to send without a microphone.
    var callMediaForTests: CallMedia? { callMedia }

    fileprivate func receiveCall(_ invite: CallInvite, from sender: Contact) {
        guard invite.room.count == 32, invite.key.count == 32 else { return }
        #if os(iOS)
        if CallRinger.shared.consumeEarlyDecline() {
            // Already declined on the call screen, before this arrived.
            enqueue(.callAnswer(id: invite.id, accepted: false), to: sender)
            kick()
            return
        }
        #endif
        guard call == nil else {
            // Already on a call: busy.
            enqueue(.callAnswer(id: invite.id, accepted: false), to: sender)
            return
        }
        call = ActiveCall(invite: invite, peer: sender.fingerprint, persona: sender.persona, outgoing: false, phase: .ringing,
                          speaker: Platform.isPhone)
        let name = data.security.notificationContent == .hidden ? "PULSHADE" : sender.displayName
        var onCallScreen = false
        #if os(iOS)
        // The system's call screen, when the call push put it up, learns who's calling.
        onCallScreen = CallRinger.shared.inviteArrived(id: invite.id, name: name)
        #endif
        if data.security.notifications && !onCallScreen {
            Notifier.shared.post((name, "Incoming call"), conversation: UUID(), sound: data.security.notificationSound)
        }
        // The caller's own timer decides first; this only covers a caller who never says they've gone.
        ringFor(seconds: 120, else: "Missed call")
    }

    fileprivate func callAnswered(_ id: UUID, accepted: Bool, by sender: Contact) {
        guard var current = call, current.invite.id == id, current.outgoing, current.phase == .ringing,
              current.peer == sender.fingerprint, current.persona == sender.persona else { return }
        callTimeout?.cancel()
        guard accepted else {
            endCall(note: "Declined", tell: false)
            return
        }
        callMedia?.setRinging(false)
        current.phase = .connecting
        call = current
    }

    /// Opens the room on the relay. The call goes live when the other side is first heard.
    private func connectCall() {
        guard let current = call else { return }
        guard let relay = reachable(contact(current.peer, in: current.persona)?.relay) else { return }
        let media = CallMedia(relay: relay, invite: current.invite, caller: current.outgoing, withAudio: callAudio) { [weak self] event in
            guard let self, self.call?.invite.id == current.invite.id else { return }
            switch event {
            case .peerHeard:
                guard var live = self.call, live.phase != .ringing || live.outgoing else { return }
                if case .live = live.phase { return }
                self.callMedia?.setRinging(false)
                live.phase = .live(since: Date())
                self.call = live
            case .closed:
                // The other side left the room, or the connection dropped.
                self.endCall(note: self.call?.phase == .connecting || self.call?.phase == .ringing ? "Call failed" : nil, tell: true)
            }
        }
        callMedia = media
        media?.setSpeaker(current.speaker)
        // Joining the room a random moment later keeps the relay from pairing the room with the message that
        // rang, or with whoever fetched it.
        let wait = trafficShaping ? Double.random(in: 0.5...2.5) : 0
        Task {
            // Ask for the microphone first: without it the call would carry silence.
            if self.callAudio { _ = await AVAudioApplication.requestRecordPermission() }
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard self.callMedia === media else { return }
            media?.start()
        }
    }

    private func ringFor(seconds: Int, else note: String) {
        callTimeout?.cancel()
        let id = call?.invite.id
        callTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, let current = self.call, current.invite.id == id, current.phase == .ringing else { return }
            self.endCall(note: note, tell: current.outgoing)
        }
    }

    /// Ends the call, notes it in the chat and, if asked, tells the other side.
    private func endCall(note: String?, tell: Bool) {
        guard let current = call else { return }
        if tell, let contact = contact(current.peer, in: current.persona) {
            enqueue(.callEnd(id: current.invite.id), to: contact)
            kick()
        }
        if let note {
            noteCall(note, current)
        } else if case let .live(since) = current.phase {
            let length = Duration.seconds(Int(Date().timeIntervalSince(since)))
            noteCall("\(current.outgoing ? "Outgoing" : "Incoming") call · \(length.formatted(.time(pattern: .minuteSecond)))", current)
        } else {
            noteCall(current.outgoing ? "Cancelled call" : "Missed call", current)
        }
        stopCall()
        save()
    }

    /// Drops the call and its connection without a word to anyone.
    private func stopCall() {
        callTimeout?.cancel()
        callMedia?.stop()
        callMedia = nil
        #if os(iOS)
        CallRinger.shared.callEnded(missed: call?.phase == .ringing)
        #endif
        call = nil
    }

    /// "Missed call", "Outgoing call · 4:12" and so on, as a note in your chat with them.
    private func noteCall(_ text: String, _ current: ActiveCall) {
        let note = Message(sender: "system", text: "📞 \(text)", status: .delivered)
        if let i = data.conversations.firstIndex(where: { $0.kind == .direct && $0.members == [current.peer] && $0.persona == current.persona }) {
            withAnimation(.snappy) { data.conversations[i].messages.append(note) }
        } else if let contact = contact(current.peer, in: current.persona) {
            let convo = startConversation(kind: .direct, title: contact.displayName, members: [current.peer], persona: .some(current.persona))
            if let i = index(of: convo.id) { data.conversations[i].messages.append(note) }
        }
    }
}

extension AppModel {
    /// A pulshade:// link opened from outside: a profile link goes to Contacts, anything else to the scan screen.
    /// Both wait there while Pulshade is locked.
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "pulshade" else { return }
        if let link = DirectoryProfile.handle(fromLink: url) {
            openedKeyCheck = link.keyCheck
            openedHandle = link.handle
        } else {
            openedCode = url.absoluteString
        }
    }
}
