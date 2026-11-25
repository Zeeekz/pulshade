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
    /// While `endLinkedDevices` runs, so it runs once at a time.
    @ObservationIgnored var endingLinks = false
    /// While a device left over from linking wipes itself: the files on the relay stay for the device keeping the account.
    @ObservationIgnored var leavingForAnotherDevice = false
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
    /// Why, in a few words, for the lock screen (`dataUnreadable`): never anything from inside the data.
    private(set) var unreadableReason: String?
    /// How many saved pieces this unlock had to set aside (`AppData.setAside`), until the notice is dismissed.
    var setAsideNotice: Int?

    /// A few words on why the account's data didn't open, from the kind of error alone.
    static func unreadableReason(_ error: Error) -> String {
        if let decoding = error as? DecodingError, case let .dataCorrupted(context) = decoding,
           context.debugDescription.contains("newer version") {
            return "It was saved by a newer version of Pulshade. Updating the app opens it."
        }
        if error is CryptoKitError { return "The file couldn't be decrypted." }
        if error is DecodingError { return "Part of it is in a shape this version doesn't know." }
        return "The file couldn't be read."
    }
    /// The format this build saves profiles in. Only tests change it, to stand in for an older or newer version.
    var profileFormat = AppData.currentFormat
    /// Set for a moment when you switch to another persona, so the screen can show the change over.
    var personaFlash: PersonaFlash?
    /// The chat on screen, so incoming messages there don't count as unread.
    var openConversation: Conversation.ID?
    /// Contacts whose "compare your Pulse check" prompt was put away this time the app is open. Only in memory: which
    /// contacts you verified is in the vault, and a list of names on disk outside it would say who you talk to.
    var verifyPromptDismissed: Set<String> = []
    /// A chat something outside the app (a notification, a link) asked to show.
    var requestedConversation: Conversation.ID?
    /// A code that arrived as a pulshade:// link, waiting for the scan screen to use it.
    var openedCode: String?
    /// A group's join link that was opened or scanned, for its preview.
    var openedGroupLink: OpenedGroupLink?
    /// A handle from a profile link (`pulshade://u/<handle>`, a "Pulshade" button on a website), waiting for
    /// Contacts to look it up. Nothing is sent until you ask: it only shows the profile and its request button.
    var openedHandle: String?
    /// A short web link opened from outside, waiting for Pulshade to be open to be looked up.
    var openedShort: ShortCode?
    /// Why a link couldn't be opened, to show once.
    var linkProblem: String?
    /// Short links being put up now, by what they're for (`shortKey`). Memory only.
    @ObservationIgnored var preparingShort: Set<String> = []
    /// Each channel's code as handed out while the app is open (`makeInviteCode`). Memory only.
    @ObservationIgnored var channelCodes: [Data: String] = [:]
    /// Long codes whose short link couldn't be put up just now: their long link is shared instead. Memory only.
    var shortLinkFailed: Set<String> = []
    /// Groups' and channels' names `findProfile` found, until whoever searched opens them. Memory only.
    @ObservationIgnored var foundPublicNames: [String: PublicNameCard] = [:]
    /// When public names were last looked after (`tendPublicNamesNow`), and whether that's still going. Memory only.
    @ObservationIgnored var namesTended = Date.distantPast
    @ObservationIgnored var tendingNames = false
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
    /// The Pulshade Admin app's key, built into the app: announcements and the reports mailbox count only if it signed
    /// them.
    static var adminKey: Data? = (Bundle.main.object(forInfoDictionaryKey: "PulshadeAdminKey") as? String)
        .flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var openAfterUnlock: Conversation.ID?

    /// Conversation → (fingerprint → when they last typed). Memory only.
    private(set) var typing: [Conversation.ID: [String: Date]] = [:]
    /// Receipts waiting for their moment. Memory only.
    private var pendingReceipts: [ReceiptBatch] = []
    /// When a message last reached this device (or came again). Lets a push-woken app know its message has arrived.
    @ObservationIgnored private var lastIncomingAt = Date.distantPast
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
    /// The first-reach loop started at unlock; stopped at lock like the others.
    private var readyTask: Task<Void, Never>?
    /// The sealed backup upload waiting its turn, and how long it waits (seconds, picked at random each time so the
    /// relay can't line an upload up with an edit). Tests shorten the wait.
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    @ObservationIgnored static var backupWait: ClosedRange<Int> = 90...600
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
        #if os(iOS)
        // iOS keeps Keychain items when an app is deleted. A fresh install with no vault must not inherit keys left
        // by a deleted one (the notification helper's bundle and inbox, sealed files' keys). Only for the app's own
        // vault: a throwaway one (the sample account) is always new, and wiping every key from it would lock the real
        // account out for good.
        if vault.directory.standardizedFileURL == Vault.standard.directory.standardizedFileURL, vault.claimFreshInstall() {
            HelperStore.clear()
            FileKeys.forgetAll()
        }
        #endif
        Ink.source = { [weak self] in self?.theme ?? .dark }
        finishCutShortWipe()
        // Whatever a panic set aside and the app was closed before it had overwritten.
        vault.finishSetAside()
        moveLockSettingsIntoVault()
        guard watchSystem else { return }
        #if os(iOS)
        // Collecting while locked is switched off: the helper's keys (left by an earlier build) go at launch, before the
        // vault is opened, so the helper can't keep fetching with them. Mail it already collected stays for the app.
        if !Self.lockedDeliveryAvailable { HelperStore.clearDelivery() }
        #endif
        resumeBurnCleanup()
        #if os(iOS)
        CallRinger.shared.model = self
        // The iPhone locking locks Pulshade too.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.deviceLocked() }
        }
        // The Keychain answers again: lock settings an older build left in preferences can move now.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.moveLockSettingsIntoVault() }
        }
        #endif
        // Tor takes a moment to connect: start it now, in the background, so it's ready by the first request.
        let onionOnly = URL(string: AppData.defaultRelay).map(Tor.isOnion) == true && AppData.directRelay == nil
        // With no account here, nothing connects until its owner has chosen between Tor and a direct connection.
        let awaitingChoice = !vault.exists && Tor.needsChoice
        if (Tor.enabled && !awaitingChoice) || onionOnly {
            DispatchQueue.global(qos: .utility).async { Tor.start() }
        }
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
        guard Tor.uses(client.base) else {
            // A plain connection that went dead (a network change, say) can sit until its own timeout. A new one
            // joins the first after `patience`, and whichever answers first wins.
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask { await client.health() }
                group.addTask {
                    try? await Task.sleep(for: .seconds(patience))
                    guard !Task.isCancelled else { return false }
                    client.freshCircuit()
                    return await client.health()
                }
                for await reached in group where reached {
                    group.cancelAll()
                    return true
                }
                return false
            }
        }
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
        leftApp()
        if phase == .unlocked, data.security.onlineStatus { sendPresence(false) }
        presenceDue = [:]
        save()
        // iOS may suspend the app before the usual moment passes: what just arrived or queued must be on disk.
        settleSaves()
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
        if phase == .unlocked { reconnect(urgent: true) } else if phase == .locked { warmUp() }
    }

    /// A message push woke Pulshade. Unlocked, it reconnects and fetches at once, then stays awake until the message
    /// has come in and its delivery receipt has gone out (not for a fixed time: after a spell asleep Tor can take
    /// longer than that to carry anything), so the sender's second tick comes when this phone gets the message.
    /// iOS allows about 30 seconds in all.
    func messagePushArrived() async {
        guard phase == .unlocked else { warmUp(); return }
        let started = Date()
        pushHandlingSince = started
        defer { if pushHandlingSince == started { pushHandlingSince = nil } }
        callPushArrived()
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            let waited = Date().timeIntervalSince(started)
            let arrived = lastIncomingAt >= started
            // Nothing came for this push: no point holding the app awake for it.
            if !arrived && waited > 15 { return }
            // The message is in; done once its receipt is sealed and has left the outbox. The receipt waits a random
            // moment first (`queueReceipt`), as long as what's left of iOS's time allows.
            if arrived && pendingReceipts.isEmpty && data.outbox.isEmpty { return }
            if waited > Self.pushWindow - 1 { return }
        }
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
        if phase == .unlocked { resendOverdueMessages(force: true) }
        #if os(iOS)
        // The wake-up banner has done its job once Pulshade is open.
        Task { await Notifier.shared.clearWakeBanners() }
        #endif
        if lockWhenBack, phase == .unlocked, call == nil {
            lockWhenBack = false
            lock(keepingKeys: true)
        }
        lockWhenBack = false
        guard phase == .unlocked, let since = backgroundedAt else { return }
        let minutes = data.security.autoLockMinutes
        if minutes > 0, Date().timeIntervalSince(since) > Double(minutes) * 60 { lock(keepingKeys: true) } else { lastActivity = Date() }
        markOpenConversationRead()
    }

    /// A message that came in while the app was behind counts as unread, even in the chat left open. Coming back
    /// to the front is when that chat is seen, so its count (and the red mark on the tab) goes now.
    func markOpenConversationRead() {
        guard phase == .unlocked, appActive, let open = openConversation else { return }
        markRead(open)
    }

    /// After a spell in the background, where iOS shuts Tor's port and lets connections die: Tor listens again,
    /// the dead connections go, and the lanes check in again, the main one at once and each of the others at its own
    /// random moment (`staggerLanes`), or within a few seconds when a wake-up push is waiting for its message (`urgent`).
    /// Until then a failure is the background's fault, not the relay's, so the offline strip waits.
    private func reconnect(urgent: Bool = false) {
        relayFailures = 0
        lastRelayContact = Date()
        resumedAt = Date()
        Task.detached(priority: .userInitiated) {
            Tor.wake()
            await MainActor.run {
                if self.phase == .unlocked, self.trafficShaping { self.staggerLanes(urgent: urgent) }
                RelayClient.closeAll()
                // Tests have no lanes running on their own: one full round does it there.
                if self.phase == .unlocked, !self.trafficShaping { Task { await self.syncOnce() } }
                // Anything announced while it was away, now rather than at the next minute.
                self.nextAnnouncementCheck = Date()
            }
        }
    }

    /// Pull down on the chats: what coming back from the background does (Tor woken, stale connections dropped, the main
    /// lane checked at once and the others each at their own moment), and the call waits for the main one, up to a few
    /// seconds, so the spinner has something to show.
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
            guard trafficShaping else {
                RelayClient.closeAll()
                await syncOnce()
                finished = true
                return
            }
            staggerLanes()
            RelayClient.closeAll()
            let main = Lane(relay: nil, name: "main")
            await poll(main, keys: currentLanes()[main] ?? [])
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
        // The locked-delivery helper can't run Tor: with Tor on it would connect directly and show the server this
        // phone's address. Whatever a backup or another device said, it stays off here.
        if on { data.security.lockedDelivery = false }
    }

    func create(identity: Identity, profile: Profile, passcode: String) async throws {
        guard passcode.count >= LockStyle.minimumLength else { throw PasscodeSetupError.tooShort }
        let vault = vault
        let settings = newLockSettings
        try await Task.detached { try vault.create(identity, passcode: passcode, settings: settings) }.value
        pendingLockStyle = nil
        self.identity = identity
        slot = 0
        data = AppData()
        data.bornAt = Date()
        data.profile = profile
        adoptConnectionChoice(fresh: true)
        if let chosen = PendingPrivacy.chosen { data.security.adopt(chosen) }
        didUnlock()
    }

    /// Opens the account on this device from its recovery code. With the backup a log out left behind,
    /// it carries on exactly where it stopped; without one, it starts empty.
    func restore(seed: Data, passcode: String, from backup: AppData? = nil) async throws {
        guard passcode.count >= LockStyle.minimumLength else { throw PasscodeSetupError.tooShort }
        let identity = try Identity(seed: seed)
        let vault = vault
        let stored = backup == nil ? try storedData(identity) : AppData()
        let settings = newLockSettings
        try await Task.detached { try vault.create(identity, passcode: passcode, settings: settings) }.value
        pendingLockStyle = nil
        self.identity = identity
        slot = 0
        if var backup {
            // The passcodes behind these were on the old device only.
            backup.decoySeed = nil
            backup.panicSeed = nil
            backup.relay = data.relay
            data = backup
        } else {
            data = stored
            // A brand-new account (no earlier data on this device) gets what was chosen on the sign-up screen.
            if stored.bornAt == nil, let chosen = PendingPrivacy.chosen { data.security.adopt(chosen) }
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
        if backup != nil { clearChatsForContacts() }
        // The stories your friends have up were on the device that was wiped, and no backup holds them: they're asked to
        // send the ones still up again (a friend on an older build ignores it, and you see only what they post next).
        if backup != nil {
            for c in data.contacts where !c.isSelf && !c.hidden && !c.awaitingAcceptance { enqueue(.storiesWanted, to: c) }
        }
        // It's on this device now. It stays on the relay and is saved over as things change, unless backups are off.
        if backup != nil, !data.security.keepBackup { Task { try? await deleteBackup(of: identity) } }
    }

    /// Whether new keys are being set up with this contact and aren't ready yet: nothing can be sent to them until their
    /// app answers, which it does when it's running. For the chat to say so, instead of showing a clock and nothing else.
    func keysPending(with fingerprint: String) -> Bool {
        guard let c = contact(fingerprint, in: activePersona), !c.awaitingAcceptance, !c.devices.isEmpty else { return false }
        // Their messages couldn't be opened and new keys are being asked for: said in the chat, not left as silence.
        if unreadable.values.contains(where: { $0.fingerprint == fingerprint && $0.persona == activePersona }) { return true }
        if c.devices.contains(where: { sparesFetching.contains("\(c.persona?.uuidString ?? "main")|\(c.fingerprint)|\($0.id.hex)") }) { return true }
        let ready = c.devices.contains { $0.session?.canSend == true }
        return !ready && c.devices.contains { $0.handshake != nil || $0.session != nil }
    }

    /// When keys with this contact started being set up and aren't ready, if they still aren't: the oldest ask still
    /// waiting, or since when their messages couldn't be opened. Nil while a spare is only being fetched (seconds) or
    /// nothing is waiting. The chat shows a small "Sending soon" only once this is a few minutes old: messages queue
    /// and go by themselves, so a short wait isn't worth a word.
    func keysPendingSince(_ fingerprint: String) -> Date? {
        guard keysPending(with: fingerprint), let c = contact(fingerprint, in: activePersona) else { return nil }
        let asked = c.devices.compactMap { $0.session?.canSend == true ? nil : $0.handshake?.startedAt }
        let stuck = unreadable.values.filter { $0.fingerprint == fingerprint && $0.persona == activePersona }.map(\.since)
        return (asked + stuck).min()
    }

    /// How long keys may take before the chat says anything.
    static let keysQuietFor: TimeInterval = 180

    /// Opens fresh sessions with every contact. No button for it any more (keys mend themselves); kept for tests.
    func renewChatKeys() {
        guard phase == .unlocked else { return }
        startFreshSessions()
        save()
    }

    /// How long between asks for new keys from a device whose messages can't be opened. Short in tests only.
    nonisolated(unsafe) static var mendWait: TimeInterval = 120

    /// Starts a new session with a device whose messages can't be opened, at most every couple of minutes.
    @ObservationIgnored private var lastMend: [String: Date] = [:]

    /// A device whose messages couldn't be opened, until one can be again: the new keys are asked for again every couple
    /// of minutes meanwhile, not only when another unreadable message happens to arrive.
    struct Unreadable { var fingerprint: String; var persona: UUID?; var device: Data; var since: Date }
    private(set) var unreadable: [String: Unreadable] = [:]
    private func retryUnreadable() {
        guard !unreadable.isEmpty else { return }
        for (key, item) in unreadable {
            guard Date().timeIntervalSince(item.since) < 3600, let i = contactIndex(item.fingerprint, item.persona),
                  let d = data.contacts[i].devices.firstIndex(where: { $0.id == item.device }) else { unreadable[key] = nil; continue }
            if let started = data.contacts[i].devices[d].handshake?.startedAt {
                // Asked and not answered (they weren't running Pulshade): asked again after a while.
                guard Date().timeIntervalSince(started) > Self.mendWait, Date().timeIntervalSince(lastMend[key] ?? .distantPast) > Self.mendWait else { continue }
                lastMend[key] = Date()
                startHandshake(contact: i, device: d)
            } else {
                mendSession(contact: i, device: d)
            }
        }
    }

    private func mendSession(contact i: Int, device d: Int) {
        guard !data.contacts[i].awaitingAcceptance, data.contacts[i].devices[d].handshake == nil,
              data.contacts[i].devices[d].awaitingHello != true else { return }
        let key = sessionKey(contact: i, device: d)
        if sparesFetching.contains(key) { return }
        if let last = lastMend[key], Date().timeIntervalSince(last) < Self.mendWait { return }
        lastMend[key] = Date()
        // Keep the keys this chat was using, in memory only, so a message that was sealed under them and arrives
        // while the new session is being set up can still be read. Dropped at lock with the other recovery keys.
        if let old = data.contacts[i].devices[d].session { keepRecovered(old, key) }
        openKeys(contact: i, device: d)
    }

    /// Opens new keys with a device. On the spare it left for this account (see `SpareSlot`) where there is one, so
    /// the chat goes on at once instead of saying "Setting up new keys" until their app next runs; asked the ordinary
    /// way when there's none, or it can't be fetched (`takeSpares` falls back to asking).
    private func openKeys(contact i: Int, device d: Int) {
        let key = sessionKey(contact: i, device: d)
        if sparesFetching.contains(key) { return }
        if data.contacts[i].devices[d].handshake == nil, let target = spareTarget(contact: i, device: d) {
            // `takeSpares` only answers a spare for a device with no session and nothing asked, so the keys being
            // replaced are set aside while it looks: put back if no spare is waiting, so a repair that wasn't needed
            // doesn't leave the chat with no keys at all. `needsKeys` picks the fetch up again if the app closes
            // before it's done (`resumeKeyFetch`).
            if let old = data.contacts[i].devices[d].session { keptWhileFetching[key] = old }
            data.contacts[i].devices[d].session = nil
            data.contacts[i].devices[d].needsKeys = true
            sparesFetching.insert(key)
            save()
            Task { await takeSpares([target]) }
            return
        }
        startHandshake(contact: i, device: d)
    }

    /// Drops the saved keys of every chat and opens new ones, with each device of each contact. Their messages are
    /// held until the new session is ready, as always. A device that left a spare key for this account (see
    /// `SpareSlot`) is answered on it, so the chat can go on at once; any other is asked, and answers when its app runs.
    private func startFreshSessions() {
        var spareTargets: [SpareTarget] = []
        for i in data.contacts.indices where !data.contacts[i].awaitingAcceptance {
            for d in data.contacts[i].devices.indices {
                // The old keys are kept in memory only, to read what was sent to them while the phone was gone.
                if let old = data.contacts[i].devices[d].session { keepRecovered(old, sessionKey(contact: i, device: d)) }
                data.contacts[i].devices[d].session = nil
                data.contacts[i].devices[d].handshake = nil
                data.contacts[i].devices[d].earlierAsks = nil
                data.contacts[i].devices[d].awaitingHello = nil
                data.contacts[i].devices[d].acceptedHello = nil
                data.contacts[i].devices[d].acceptedHelloAt = nil
                data.contacts[i].devices[d].sessionAskAt = nil
                data.contacts[i].devices[d].needsKeys = true
                if let target = spareTarget(contact: i, device: d) {
                    spareTargets.append(target)
                    sparesFetching.insert(sessionKey(contact: i, device: d))
                } else {
                    startHandshake(contact: i, device: d)
                }
            }
        }
        save()
        guard !spareTargets.isEmpty else { return }
        Task { await takeSpares(spareTargets) }
    }

    /// Devices left with no keys and nothing asked: the app was closed while their spares were being fetched after a
    /// recovery. Fetched again (or asked, where there's no spare), as if the recovery had just happened.
    private func resumeKeyFetch() {
        var spareTargets: [SpareTarget] = []
        for i in data.contacts.indices where !data.contacts[i].awaitingAcceptance {
            for d in data.contacts[i].devices.indices {
                let link = data.contacts[i].devices[d], key = sessionKey(contact: i, device: d)
                guard link.needsKeys == true, !sparesFetching.contains(key) else { continue }
                guard link.session == nil, link.handshake == nil, link.awaitingHello != true else {
                    data.contacts[i].devices[d].needsKeys = nil
                    continue
                }
                if let target = spareTarget(contact: i, device: d) {
                    spareTargets.append(target)
                    sparesFetching.insert(key)
                } else {
                    startHandshake(contact: i, device: d)
                }
            }
        }
        guard !spareTargets.isEmpty else { return }
        Task { await takeSpares(spareTargets) }
    }

    // MARK: Spare keys

    /// A friend's device whose spare key might be waiting: who they are, and its slots' keys, in the order they're
    /// looked in (see `SpareSlot.Slot`).
    struct SpareTarget {
        var fingerprint: String
        var persona: UUID?
        var device: Data
        var relay: String?
        var slots: [(slot: SpareSlot.Slot, keys: SpareSlot.Keys)]
    }

    /// Devices whose spare key is being fetched, by `sessionKey`. Memory only: the chat says keys are on their way.
    @ObservationIgnored private var sparesFetching: Set<String> = []
    /// The keys a chat was on when its friend's spare began to be fetched (`openKeys`), by `sessionKey`: back in place
    /// if there turns out to be no spare. Memory only.
    @ObservationIgnored private var keptWhileFetching: [String: Ratchet] = [:]
    /// When this device next looks after the spares it leaves for friends. One at a time, minutes apart, so the
    /// relay never sees a run of them come from one place together (and a device stays well inside the relay's
    /// allowance of new backup keys an hour).
    @ObservationIgnored private var nextSpareWork = Date().addingTimeInterval(.random(in: 20...120))
    /// How long apart spares are left on the relay, and how long one stays before it's replaced. For the tests.
    static var spareSpacing: ClosedRange<TimeInterval> = 240...720
    static var spareLifetime: ClosedRange<TimeInterval> = 5 * 86_400...10 * 86_400
    /// How long a replaced spare is still honoured, and the oldest one a friend's device will take.
    /// A replaced spare only matters while an answer to it could still arrive, but its secret half is what opens that
    /// session, so it is kept 10 days and no more (docs/protocol.md, section 2): an answer that comes later can't be
    /// opened, and the chat mends by asking again. A friend's device takes none older than a spare is ever up, plus that.
    static let spareGrace: TimeInterval = 10 * 86_400
    static var spareMaxAge: TimeInterval { spareLifetime.upperBound + spareGrace }
    /// How many answers to a last-resort spare are remembered, to refuse one sent again.
    static let spareAnswersKept = 64

    /// Which friends this device leaves spares for: people in your contacts whose app takes them, on the main
    /// identity only (never a decoy, which must not look busy on the relay). Not your own linked devices, whose keys
    /// come back another way, nor people known only from a group.
    private func leavesSpare(for c: Contact) -> Bool {
        isPrimary && !c.isSelf && !c.hidden && !c.awaitingAcceptance && c.devices.contains { $0.takesSpares == true }
    }

    private func spareTarget(contact i: Int, device d: Int) -> SpareTarget? {
        let c = data.contacts[i], link = c.devices[d]
        guard isPrimary, !c.isSelf, !c.hidden, link.takesSpares == true, let me = me(c.persona) else { return nil }
        // Read in this order (see `takeSpares`): the first, then the last-resort one, which is always up where a device
        // leaves more than one, so an empty one there means there's nothing else to look for; then the second.
        // A friend on a build from before has only `first`.
        let order: [SpareSlot.Slot] = [.first, .lastResort, .second]
        let slots = order.compactMap { slot in
            SpareSlot.keys(mine: me.agreementKey, theirs: c.agreementKey, issuer: c.signingKey, device: link.id, slot: slot)
                .map { (slot: slot, keys: $0) }
        }
        guard slots.count == order.count else { return nil }
        return SpareTarget(fingerprint: c.fingerprint, persona: c.persona, device: link.id, relay: c.relay, slots: slots)
    }

    /// The slot this device's spare for contact `i` goes in.
    private func mySpareKeys(contact i: Int, slot: SpareSlot.Slot = .first) -> SpareSlot.Keys? {
        let c = data.contacts[i]
        guard let me = me(c.persona) else { return nil }
        return SpareSlot.keys(mine: me.agreementKey, theirs: c.agreementKey,
                              issuer: me.signingKey.publicKey.rawRepresentation, device: deviceID(for: c.persona), slot: slot)
    }

    /// What was found in a friend's slot.
    private struct FoundSpare {
        var slot: SpareSlot.Slot
        var keys: SpareSlot.Keys
        var card: SpareSlot.Card
        var client: RelayClient
        /// The relay erased it as it handed it over (`takeBackup`), so there is nothing left to erase.
        var taken = false
    }

    /// Fetches each friend's spare and answers it; a device with none waiting (or that can't be reached) is asked
    /// for new keys the ordinary way. A few at a time, each slot on its own connection.
    private func takeSpares(_ targets: [SpareTarget]) async {
        var found: [Int: FoundSpare] = [:]
        // Each slot on its own connection (over Tor, its own circuit), and spread out over a few seconds: the relay
        // must not see one connection, or one moment, read the spares of all your friends.
        let spread = trafficShaping ? Self.spareSpread : 0
        let clients = targets.map { target in target.slots.map { client(target.relay, lane: Self.spareLane($0.keys)) } }
        let taken = answeredSpares, maxAge = Self.spareMaxAge
        await withTaskGroup(of: (Int, FoundSpare?).self) { group in
            var next = 0
            func add() {
                guard next < targets.count else { return }
                let index = next, target = targets[index], slotClients = clients[index]
                next += 1
                group.addTask {
                    if spread > 0 { try? await Task.sleep(for: .seconds(Double.random(in: 0...spread))) }
                    // Slot by slot, so a recovery reads about one slot per friend (the relay allows each caller only
                    // so many reads an hour): the first one; if that's gone, the last-resort one, and if that isn't up
                    // either, there's nothing to take; if it is, the second one-time one is preferred to it. With
                    // traffic shaping a few random seconds pass between one read and the next, so the relay can't
                    // easily tell from the timing which slots belong together.
                    // A one-time spare is taken: the relay hands it over and erases it in one step, so two of your
                    // devices repairing at once can't both start from it. A relay from before that is read as it
                    // always was, and the spare erased afterwards (see `erase` below). The last-resort one is only read.
                    func read(_ n: Int) async -> FoundSpare? {
                        guard n < target.slots.count, let client = slotClients[n] else { return nil }
                        let slot = target.slots[n]
                        if spread > 0, n > 0 { try? await Task.sleep(for: .seconds(Double.random(in: 2...8))) }
                        var blob: Data?, taken = false
                        if !slot.slot.reusable {
                            let (key, sig, ts) = SpareSlot.proof("pulshade.backup.take.v1", slot.keys)
                            switch try? await client.takeBackup(key: key, sig: sig, ts: ts) {
                            case .taken(let data)?: (blob, taken) = (data, true)
                            case .unsupported?: break
                            case .empty?, nil: return nil
                            }
                        }
                        if !taken {
                            let (key, sig, ts) = SpareSlot.proof("pulshade.backup.get.v1", slot.keys)
                            blob = try? await client.backup(key: key, sig: sig, ts: ts)
                        }
                        guard let blob, let card = SpareSlot.open(blob, with: slot.keys) else { return nil }
                        return FoundSpare(slot: slot.slot, keys: slot.keys, card: card, client: client, taken: taken)
                    }
                    // Not too old, and (for a one-time one) not answered already on this run: dead on their side.
                    func usable(_ spare: FoundSpare?) -> FoundSpare? {
                        guard let spare, Date().timeIntervalSince(spare.card.madeAt) < maxAge,
                              spare.slot.reusable || !taken.contains(spare.card.request.ephemeral) else { return nil }
                        return spare
                    }
                    if let first = usable(await read(0)) { return (index, first) }
                    guard let lastResort = await read(1) else { return (index, nil) }
                    if let second = usable(await read(2)) { return (index, second) }
                    return (index, usable(lastResort))
                }
            }
            for _ in 0..<4 { add() }
            while let (index, spare) = await group.next() {
                if let spare { found[index] = spare }
                add()
            }
        }
        // A one-time spare is gone from the relay once it has been taken (the relay erased it as it handed it over), so
        // it can't be taken twice and doesn't sit in the backup store; its maker leaves a new one when their app next
        // runs. One taken and then not used (keys opened another way meanwhile) is gone too, as Signal's one-time keys
        // are: the friend's last-resort spare is still there. From a relay without taking it was only read, and is
        // erased here once it has been dealt with, as before. The last-resort one stays: its maker replaces it.
        func erase(_ index: Int) {
            guard let spare = found[index], !spare.slot.reusable, !spare.taken else { return }
            let (dkey, dsig, dts) = SpareSlot.proof("pulshade.backup.del.v1", spare.keys)
            Task { try? await spare.client.deleteBackup(key: dkey, sig: dsig, ts: dts) }
        }
        for (index, target) in targets.enumerated() {
            guard let i = contactIndex(target.fingerprint, target.persona),
                  let d = data.contacts[i].devices.firstIndex(where: { $0.id == target.device }) else { continue }
            let key = sessionKey(contact: i, device: d)
            sparesFetching.remove(key)
            let kept = keptWhileFetching.removeValue(forKey: key)
            // Something else opened keys with them meanwhile (their own ask arrived): that's kept.
            guard data.contacts[i].devices[d].session == nil, data.contacts[i].devices[d].handshake == nil else {
                data.contacts[i].devices[d].needsKeys = nil
                continue
            }
            erase(index)
            if let spare = found[index], Date().timeIntervalSince(spare.card.madeAt) < Self.spareMaxAge,
               spare.slot.reusable || !answeredSpares.contains(spare.card.request.ephemeral),
               acceptSession(spare.card.request, contact: i, device: d, spare: true, context: .spare) {
                answeredSpares.insert(spare.card.request.ephemeral)
                // A hello of theirs sent before now crossed this answer: it isn't taken (see `.deviceHello`).
                data.contacts[i].devices[d].spareTakenAt = RelayClock.now
            } else {
                // No spare waiting: the keys the chat was on stay while it asks, as a repair always did before spares.
                if let kept { data.contacts[i].devices[d].session = kept }
                startHandshake(contact: i, device: d)
            }
        }
        save()
    }

    /// Each slot has its own connection, so the relay can't tie together the slots one device reads or writes.
    static func spareLane(_ keys: SpareSlot.Keys) -> String { "spare|" + keys.name.prefix(8).hex }
    /// Spares already answered on this run, so the same one-time one is never answered twice (a second repair, say).
    @ObservationIgnored private var answeredSpares: Set<Data> = []
    /// Devices that answered a spare this device no longer had, by `sessionKey`, and when. Memory only.
    @ObservationIgnored private var deadSpareFrom: [String: Date] = [:]
    /// Over how many seconds a recovered device spreads its reads of friends' spares.
    static var spareSpread: Double = 20

    /// Looks after one of one friend's spares, if one needs it: makes one where a slot is empty, offers again one the
    /// relay didn't take, or replaces one that has been up long enough. Then waits a few minutes before the next.
    private func tendSpares() {
        guard isPrimary, phase == .unlocked, Date() >= nextSpareWork else { return }
        nextSpareWork = Date().addingTimeInterval(.random(in: Self.spareSpacing))
        // Replaced spares are honoured for a while, then forgotten.
        let grace = Date().addingTimeInterval(-Self.spareGrace)
        for i in data.contacts.indices where data.contacts[i].oldSpares?.contains(where: { ($0.retiredAt ?? .distantPast) <= grace }) == true {
            data.contacts[i].oldSpares?.removeAll { ($0.retiredAt ?? .distantPast) <= grace }
            if data.contacts[i].oldSpares?.isEmpty == true { data.contacts[i].oldSpares = nil }
        }
        let now = Date()
        // What comes first: a spare signed by keys this device no longer has (`deviceSeed`), then a friend's first spare
        // that isn't up, then their last-resort one that isn't up or is due for replacing (its secret half is kept while
        // it's up, so it must not be put off for refills), then a second one that isn't up, then one-time ones due.
        func rank(_ c: Contact, _ slot: SpareSlot.Slot) -> Int? {
            guard let spare = c.spare(in: slot), spare.publishedAt != nil else {
                return [SpareSlot.Slot.first: 1, .lastResort: 2, .second: 3][slot]
            }
            if let pin = deviceKey(for: c.persona)?.card.pin, spare.handshake.pin != pin { return 0 }
            guard (spare.replaceAt ?? .distantPast) <= now else { return nil }
            return [SpareSlot.Slot.first: 4, .lastResort: 2, .second: 5][slot]
        }
        func due(_ c: Contact) -> (rank: Int, slot: SpareSlot.Slot)? {
            guard leavesSpare(for: c) else { return nil }
            return SpareSlot.Slot.allCases.compactMap { slot in rank(c, slot).map { ($0, slot) } }.min { $0.0 < $1.0 }
        }
        guard let (i, slot) = data.contacts.indices.compactMap({ i in due(data.contacts[i]).map { (i, $0) } })
            .min(by: { $0.1.rank < $1.1.rank }).map({ ($0.0, $0.1.slot) })
        else { return }
        if let old = data.contacts[i].spare(in: slot), old.publishedAt != nil {
            var retired = old
            retired.retiredAt = now
            data.contacts[i].oldSpares = (data.contacts[i].oldSpares ?? []) + [retired]
            data.contacts[i].setSpare(nil, in: slot)
        }
        let persona = data.contacts[i].persona
        guard let me = me(persona), let mine = deviceKey(for: persona) else { return }
        // One made with keys this device no longer has is no use: a new one replaces it.
        if data.contacts[i].spare(in: slot)?.handshake.pin != mine.card.pin { data.contacts[i].setSpare(nil, in: slot) }
        if data.contacts[i].spare(in: slot) == nil { data.contacts[i].setSpare(SpareKey.make(pin: mine.card.pin, slot: slot), in: slot) }
        // Signed by this device's own keys, like any ask for keys.
        let parties = HandshakeParties(from: me.card.signing, to: data.contacts[i].signingKey, device: deviceID(for: persona))
        guard let spare = data.contacts[i].spare(in: slot), var card = spare.card,
              let signed = try? Handshake.signed(card.request, by: mine.key, card: mine.card, parties, context: .spare) else { return }
        card.request = signed
        guard let keys = mySpareKeys(contact: i, slot: slot), let sealed = SpareSlot.seal(card, with: keys),
              let client = client(data.contacts[i].relay, lane: Self.spareLane(keys)) else { return }
        let fp = data.contacts[i].fingerprint, ephemeral = spare.handshake.ephemeral
        save()
        Task { [weak self] in
            let (key, sig, ts) = SpareSlot.proof("pulshade.backup.put.v1", keys, body: sealed)
            guard (try? await client.putBackup(sealed, key: key, sig: sig, ts: ts)) != nil, let self,
                  let i = self.contactIndex(fp, persona), var up = self.data.contacts[i].spare(in: slot),
                  up.handshake.ephemeral == ephemeral else { return }
            up.publishedAt = Date()
            up.replaceAt = Date().addingTimeInterval(.random(in: Self.spareLifetime))
            self.data.contacts[i].setSpare(up, in: slot)
            self.save()
        }
    }

    /// Erases the spares this device left for someone it no longer knows as a friend.
    private func withdrawSpare(for c: Contact) {
        guard c.spare != nil || c.moreSpares != nil || c.oldSpares != nil, let i = contactIndex(c.fingerprint, c.persona) else { return }
        data.contacts[i].spare = nil
        data.contacts[i].moreSpares = nil
        data.contacts[i].oldSpares = nil
        for slot in SpareSlot.Slot.allCases {
            guard let keys = mySpareKeys(contact: i, slot: slot), let client = client(c.relay, lane: Self.spareLane(keys)) else { continue }
            Task {
                let (key, sig, ts) = SpareSlot.proof("pulshade.backup.del.v1", keys)
                try? await client.deleteBackup(key: key, sig: sig, ts: ts)
            }
        }
    }

    /// Tests: look after the next spare now.
    func tendSparesNow() {
        nextSpareWork = .distantPast
        tendSpares()
    }

    /// Keys from before an account was recovered or a session was repaired, by contact and device. Held in memory
    /// only, and dropped at lock.
    @ObservationIgnored private(set) var recoveredSessions: [String: [Ratchet]] = [:]

    /// Keeps keys a device's session is replaced from, a few at a time (a recovery, then new keys straight after, say),
    /// so what was sent under any of them and is still on its way can be read.
    private func keepRecovered(_ session: Ratchet, _ key: String) {
        recoveredSessions[key, default: []].append(session)
        if recoveredSessions[key]!.count > 4 { recoveredSessions[key]!.removeFirst() }
    }

    /// The kept keys that open a message, newest first: which, its state after, and what it said.
    private func openRecovered(_ message: RatchetMessage, _ key: String) -> (Int, Ratchet, Data)? {
        for (n, session) in (recoveredSessions[key] ?? []).enumerated().reversed() {
            var copy = session
            if let opened = try? copy.decrypt(message) { return (n, copy, opened) }
        }
        return nil
    }

    private func sessionKey(contact i: Int, device d: Int) -> String {
        "\(data.contacts[i].persona?.uuidString ?? "main")|\(data.contacts[i].fingerprint)|\(data.contacts[i].devices[d].id.hex)"
    }

    /// Counts a wrong guess (kept across restarts) and, if the person chose "wipe after wrong attempts" and this one
    /// reaches it, wipes this device exactly as Detach does: nothing is sent, and the recovery code brings back what the
    /// sealed backup holds. Every wrong guess is counted the same, whichever slots exist.
    private func noteWrongGuess() {
        failedAttempts += 1
        // The setting may still be waiting to move into the lock file: tried again before it's needed.
        moveLockSettingsIntoVault()
        if WipeAfterFailures.reached(failedAttempts, limit: lockWipeAfter) { wipeNow() }
    }

    #if DEBUG
    /// Tests only: stands in for the vault's unlock, to inject failures that aren't a wrong passcode.
    var unlockHook: (@Sendable (String) throws -> Vault.Opened)?
    #endif

    /// The passcode as the last `openVault` stretched it, for a panic to seal the landing account with (see
    /// `Vault.panic`). Taken, and dropped, straight after.
    @ObservationIgnored private var lastStretch: SymmetricKey?

    /// Opens the vault with a passcode off the main thread. Only a thrown `VaultError.wrongPasscode` means the guess was
    /// wrong; any other error (Keychain trouble, a damaged or missing file) says nothing about the guess.
    private func openVault(_ passcode: String) async throws -> Vault.Opened {
        let vault = vault
        lastStretch = nil
        #if DEBUG
        if let hook = unlockHook { return try await Task.detached { try hook(passcode) }.value }
        #endif
        let (opened, stretched) = try await Task.detached { try vault.unlockKeepingStretch(passcode: passcode) }.value
        lastStretch = stretched
        return opened
    }

    /// The real "wipe after wrong guesses" setting, kept sealed in the lock file (`Vault.LockSettings`), so it is known
    /// while locked but nothing outside Pulshade can read or change it. 0 is off.
    private var lockWipeAfter: Int {
        _ = lockSettingsRevision
        return vault.lockSettings?.wipeAfter ?? unmovedLockSettings?.wipeAfter ?? 0
    }

    /// The settings an older build kept as plain preferences, while the lock file has none yet (`moveLockSettingsIntoVault`
    /// hasn't managed to move them): what the lock screen goes by meanwhile, so an updated account's wipe isn't off, nor
    /// its keypad the wrong one, until then. Never once the lock file has settings, so a preference can't override them.
    private var unmovedLockSettings: Vault.LockSettings? {
        guard vault.exists, (vault.lockSettings ?? Vault.LockSettings()) == Vault.LockSettings() else { return nil }
        let defaults = UserDefaults.standard
        let style = (defaults.string(forKey: LockStyle.key) ?? defaults.string(forKey: LockStyle.legacyKey)).flatMap(LockStyle.init(rawValue:))
        let wipe = defaults.integer(forKey: WipeAfterFailures.key)
        let settings = Vault.LockSettings(style: style?.rawValue, wipeAfter: WipeAfterFailures.choices.contains(wipe) && wipe > 0 ? wipe : nil)
        return settings == Vault.LockSettings() ? nil : settings
    }

    /// Moves on with every change of the settings kept in the lock file, so screens showing them redraw.
    private var lockSettingsRevision = 0

    /// "Wipe after wrong attempts": 0 is off. Only from the real account, so a decoy can't turn it off.
    var wipeAfterAttempts: Int { isPrimary ? lockWipeAfter : facadeWipeAfter ?? lockWipeAfter }

    func setWipeAfterAttempts(_ n: Int) {
        guard WipeAfterFailures.choices.contains(n) else { return }
        // In a decoy the row looks and behaves the same, but the real setting is left alone.
        guard isPrimary else { facadeWipeAfter = n; return }
        try? vault.updateLockSettings { $0.wipeAfter = n }
        lockSettingsRevision += 1
    }

    /// Which keypad the lock screen shows first, kept sealed in the lock file with the setting above. Only a hint about
    /// the keyboard: every secret is tried against every slot whatever it looks like. Chosen before there's an account,
    /// it waits in memory for the lock file the account is made with.
    var lockStyle: LockStyle {
        get {
            _ = lockSettingsRevision
            return vault.lockSettings?.style.flatMap(LockStyle.init(rawValue:)) ?? unmovedLockSettings?.style.flatMap(LockStyle.init(rawValue:))
                ?? pendingLockStyle ?? .passcode
        }
        set {
            defer { lockSettingsRevision += 1 }
            if vault.exists, (try? vault.updateLockSettings({ $0.style = newValue.rawValue })) != nil {
                pendingLockStyle = nil
            } else {
                pendingLockStyle = newValue
            }
        }
    }
    @ObservationIgnored private var pendingLockStyle: LockStyle?

    /// What a lock file made now starts with: the keypad just chosen, and a wipe after 10 wrong guesses.
    private var newLockSettings: Vault.LockSettings {
        Vault.LockSettings(style: pendingLockStyle?.rawValue, wipeAfter: WipeAfterFailures.newAccountDefault)
    }

    /// Builds before these settings were sealed kept them as plain preferences, where anything that could write the
    /// app's preferences could turn the wipe off. They move into the lock file once, and the preferences go. Tried at
    /// launch, when the device's protected data becomes available, before each guess and at each unlock, until it has
    /// worked (the Keychain may not answer yet at launch). Until then the preferences are read (`unmovedLockSettings`).
    func moveLockSettingsIntoVault() {
        guard vault.exists, let settings = vault.lockSettings, settings == Vault.LockSettings() else { return }
        let defaults = UserDefaults.standard
        let style = defaults.string(forKey: LockStyle.key) ?? defaults.string(forKey: LockStyle.legacyKey)
        let wipe = defaults.integer(forKey: WipeAfterFailures.key)
        guard (try? vault.updateLockSettings({
            $0.style = style.flatMap(LockStyle.init(rawValue:))?.rawValue
            $0.wipeAfter = WipeAfterFailures.choices.contains(wipe) ? wipe : 0
        })) != nil else { return }
        lockSettingsRevision += 1
        for key in [LockStyle.key, LockStyle.legacyKey, WipeAfterFailures.key] { defaults.removeObject(forKey: key) }
    }

    /// What a decoy shows for "wipe after wrong guesses" once it has been changed there. Memory only.
    private var facadeWipeAfter: Int?
    /// When a decoy says its backup was last saved (it keeps none). Memory only.
    @ObservationIgnored private var facadeBackupAt: Date?

    /// Whether the lock screen still asks for a 4-digit PIN, shorter than a new one may be, or the account open was opened
    /// with a secret that short: it must be changed before anything else (`RootView`). The same in a decoy, which shares
    /// the keypad: a real account made to change its PIN and a decoy not would differ. The second half catches an account
    /// whose keypad another (a decoy changed first) already moved on.
    var hasShortPIN: Bool { lockStyle == .pin4 || openedWithShortSecret }

    /// The account open was unlocked with a secret shorter than a new one may be. Memory only; cleared by the sheet that
    /// changes it once all of it is done (`ChangePasscodeSheet`), so the sheet stays up until then.
    var openedWithShortSecret = false

    /// Puts the real account behind a new passcode. The current one is checked first, and opens the same account in the
    /// same slot; nothing else about the lock file changes, so a decoy or panic passcode keeps working.
    func changePasscode(current: String, to new: String) async throws {
        // A decoy changes its own passcode the same way, so its settings look no different from a real account's.
        guard phase == .unlocked, let identity else { return }
        guard new.count >= LockStyle.minimumLength else { throw PasscodeSetupError.tooShort }
        let vault = vault, slot = slot
        let opened: Vault.Opened
        do {
            opened = try await openVault(current)
        } catch VaultError.wrongPasscode {
            noteWrongGuess()
            throw PasscodeSetupError.wrongCurrent
        }
        // Any other failure propagates uncounted: it isn't a wrong guess.
        guard case let .identity(who, at) = opened, at == slot, who.fingerprint == identity.fingerprint else {
            noteWrongGuess()
            throw PasscodeSetupError.wrongCurrent
        }
        guard current != new, !(await Task.detached { vault.passcodeInUse(new) }.value) else { throw PasscodeSetupError.inUse }
        try await Task.detached { try vault.setSlot(slot, identity: identity, passcode: new) }.value
        failedAttempts = 0
    }

    /// How long after the passcode is checked an unlock may answer, at the soonest, whatever the passcode opened. What
    /// follows the check differs: the account still covered is only shown again, a real account's data is read, a panic
    /// rewrites the lock file and sets the real account's files aside, a decoy typed over a covered account closes that
    /// one first. Each answers at this moment (or later, if its own work takes longer), so the time a passcode takes
    /// doesn't say which kind it was. Tests set it to nothing.
    @ObservationIgnored var unlockSettle: Duration = .milliseconds(400)

    func unlock(passcode: String) async -> Bool {
        moveLockSettingsIntoVault()
        // Each wrong guess makes the next one wait longer.
        if failedAttempts > 2 {
            try? await Task.sleep(for: .seconds(min(30, 1 << min(failedAttempts - 2, 5))))
        }
        let opened: Vault.Opened
        do {
            opened = try await openVault(passcode)
        } catch VaultError.wrongPasscode {
            noteWrongGuess()
            return false
        } catch {
            // Keychain trouble or a damaged file isn't a wrong guess: no count, no wipe.
            return false
        }
        let settled = ContinuousClock.now + unlockSettle
        let stretched = lastStretch
        lastStretch = nil
        if covered {
            if case let .identity(who, at) = opened, at == slot, who.fingerprint == identity?.fingerprint {
                try? await Task.sleep(until: settled)
                uncover()
                return true
            }
            // Another passcode than the one this account opens with: a decoy, the panic passcode, or the real one over a
            // decoy left covered. Everything open closes, as a lock you press closes it, and the passcode opens what it
            // opens, as it would from the locked screen. So covering works the same whether or not a decoy or panic
            // passcode is set, and gives neither away.
            covered = false
            lock()
        }
        dataUnreadable = false
        do {
            let vault = vault
            switch opened {
            case let .identity(identity, slot):
                let stored = try storedData(identity)
                try? await Task.sleep(until: settled)
                self.identity = identity
                self.slot = slot
                data = stored
            case let .panic(landing, slot):
                // Looks like a normal unlock. Behind it, everything real is gone, and the landing identity
                // becomes the main one, so nothing about it looks like a disguise afterwards.
                do {
                    try await Task.detached {
                        try vault.panic(keeping: landing, slot: slot, passcode: passcode, stretched: stretched)
                    }.value
                } catch {
                    // The real account couldn't be destroyed. Don't report success or open the landing account
                    // over whatever is still on disk; refusing the unlock is the safe outcome.
                    return false
                }
                Notifier.shared.clearAll()
                // Whatever the real account left in temporary files and caches goes too, as with Burn and Detach.
                Vault.scrubLeftovers()
                // The real account's mail and keys must not outlive it in the shared Keychain either.
                HelperStore.clear()
                helperWritten = nil
                helperKnown = false
                // The real account's mailboxes can't be named any more: take this phone's token off the relay instead.
                withdrawPush()
                let stored = try storedData(landing)
                try? await Task.sleep(until: settled)
                self.identity = landing
                self.slot = 0
                data = stored
            }
            failedAttempts = 0
            openedWithShortSecret = passcode.count < LockStyle.minimumLength
            didUnlock()
            if data.pendingBackupForget != nil { Task { await forgetPendingBackup() } }
            // A decoy is an empty account: the real one's wake-ups stop until the real one is unlocked again.
            if !isPrimary { withdrawPush() }
            moveLockSettingsIntoVault()
            await bindToDevice(passcode: passcode)
            return true
        } catch {
            // Only a passcode that opened nothing is a wrong guess. Unreadable data, Keychain errors and the like aren't.
            return false
        }
    }

    /// The account's data, or a fresh start when it has none yet. A file that's there but won't open stops
    /// the unlock: opening an empty account instead would save over it at the first change.
    private func storedData(_ identity: Identity) throws -> AppData {
        do {
            unreadableReason = nil
            return try vault.load(with: identity) ?? AppData()
        } catch {
            dataUnreadable = true
            unreadableReason = Self.unreadableReason(error)
            throw error
        }
    }

    /// Lock files older than this build's form (PBKDF2, or not yet bound to the Secure Enclave) are brought up to date on
    /// the real account's next unlock: its slot is sealed again with Argon2id and the chip's answer for the passcode. The
    /// other slots stay as they are (a decoy or panic passcode may be in one, whatever this account's saved data says)
    /// and keep opening the old way until they are next set. Only when there's something to change: otherwise this would
    /// rewrite the file on every unlock for nothing.
    private func bindToDevice(passcode: String) async {
        guard isPrimary, let identity, vault.needsUpgrade else { return }
        let vault = vault
        try? await Task.detached { try vault.create(identity, passcode: passcode, replacing: true) }.value
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
        // Before anything below (expiry, say) drops a message, so its media file is wiped and reused, not left behind.
        if let identity { trackedMedia = (identity.fingerprint, allMediaNames()) }
        rebuildReceivedMedia()
        // Some saved pieces wouldn't read and were set aside: say so once, then keep them quietly.
        if let unseen = data.setAsideUnseen, unseen > 0 {
            setAsideNotice = unseen
            data.setAsideUnseen = nil
            save()
        }
        // Data a build before device keys saved (format 22 or older): its sessions are restarted once, below.
        let fromBeforeDeviceKeys = data.format < 23
        unlockedAt = Date()
        deviceKeyCache = [:]
        // A decoy keeps no backup on the relay, but says it has one like any account with backups on.
        facadeWipeAfter = nil
        facadeBackupAt = isPrimary ? nil : Date().addingTimeInterval(-Double.random(in: 300...3000))
        // A device that was linked, or an account recovered, polled the relay before there was an account. From
        // here on nothing may share a circuit or connection with that pre-account traffic.
        Tor.newRoutes()
        RelayClient.closeAll(finishing: true)
        lastRelayContact = Date()
        moveToOnionRelay()
        forgetUnusableRelays()
        purgeExpired()
        migrateInlineMedia()
        wrapDataFilesTogether()
        pruneHandshakeSecrets()
        data.seenEnvelopes = data.seenEnvelopes.filter { $0.value > Date().addingTimeInterval(-Self.seenRetention) }
        // Unused contact invites die with the relay's 7-day retention.
        data.invites.removeAll { $0.channel == nil && !$0.isPublic && $0.createdAt < Date().addingTimeInterval(-7 * 24 * 3600) }
        data.invites.removeAll { ($0.retiresAt ?? .distantFuture) < Date() }
        // A choice saved before Tor was turned on can't take effect: the helper would connect directly.
        if data.security.tor { data.security.lockedDelivery = false }
        UserDefaults.standard.set(data.theme, forKey: "pulshade.theme")
        // Contacts from before post-quantum keys are introduced to them, once.
        introducePQToContacts()
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
        readyTask?.cancel()
        readyTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.connecting, self.phase == .unlocked, let client = self.client(nil) {
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
        vault.dropOldCatalog()
        announcementsVersion = nil
        endLinkedDevicesWhenOnline()
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
        if fromBeforeDeviceKeys { restartSessionsFromBeforeDeviceKeys() }
        // Every unlock brings the saved format up to date, not only the one that restarted sessions: data left at 23 to 25
        // stayed there, and each start then took its shared groups for ones from before format 24 and closed them.
        data.format = AppData.currentFormat
        save()
    }

    /// Once, on the first unlock of data saved by a build before device keys (format 22 or older). Its ratchet sessions
    /// mean something else by their post-quantum fields than this build does, and were opened with no device keys, so
    /// none of the devices behind them is pinned: the first handshake after would pin whatever answered, unannounced.
    /// So every session, with friends and with your own devices, is dropped (not kept to read late mail either) and a
    /// fresh handshake goes to every known device; its keys are pinned by the device that really holds them. What
    /// waits for a device stays waiting and goes on the new keys. Envelopes already sealed for a friend's or your own
    /// device and not sent yet were sealed on the dropped keys, in a form this build's friends refuse: they go, and the
    /// chat messages among them are queued again for the new keys. Spares left on the relay were signed in the old way
    /// too, so new ones replace them.
    private func restartSessionsFromBeforeDeviceKeys() {
        var stale: [Data: (contact: Int, device: Int)] = [:]
        for i in data.contacts.indices {
            data.contacts[i].spare = nil
            data.contacts[i].oldSpares = nil
            data.contacts[i].moreSpares = nil
            for d in data.contacts[i].devices.indices { stale[data.contacts[i].devices[d].sendID] = (i, d) }
        }
        let dropped = data.outbox.filter { stale[$0.sendID] != nil && $0.story == nil && !sendingIDs.contains($0.id) }
        let droppedIDs = Set(dropped.map(\.id))
        data.outbox.removeAll { droppedIDs.contains($0.id) }
        for item in dropped {
            guard let id = item.message, let (i, d) = stale[item.sendID], !data.contacts[i].isSelf,
                  let convo = directConversation(with: data.contacts[i].fingerprint, persona: data.contacts[i].persona),
                  let message = convo.messages.first(where: { $0.id == id && $0.isMine && !$0.isVideo }),
                  !data.contacts[i].devices[d].pending.contains(where: { $0.message == id }) else { continue }
            data.contacts[i].devices[d].pending.append(PendingPayload(payload: .message(wireForResend(message, in: convo)), message: id))
        }
        for i in data.contacts.indices where !data.contacts[i].awaitingAcceptance {
            for d in data.contacts[i].devices.indices {
                data.contacts[i].devices[d].session = nil
                data.contacts[i].devices[d].earlierAsks = nil
                data.contacts[i].devices[d].acceptedHello = nil
                data.contacts[i].devices[d].acceptedHelloAt = nil
                data.contacts[i].devices[d].sessionAskAt = nil
                data.contacts[i].devices[d].answeredAt = nil
                data.contacts[i].devices[d].spareTakenAt = nil
                data.contacts[i].devices[d].needsKeys = nil
                // A link still waiting to learn its device's id is an invite not answered yet: its own ask stands.
                guard !data.contacts[i].devices[d].id.isEmpty else { continue }
                data.contacts[i].devices[d].handshake = nil
                data.contacts[i].devices[d].awaitingHello = nil
                startHandshake(contact: i, device: d)
            }
        }
        save()
    }

    /// This build only talks to PULSHADE's own relay, so everyone it can reach collects their mail there. A contact,
    /// invite or waiting envelope that names any other address (an old one, another spelling, a relay from a build
    /// that had more) could never be sent as it is: it sat in the outbox forever and counted as waiting. They use the
    /// built-in relay instead, where those mailboxes really are.
    private func forgetUnusableRelays() {
        guard Invite.officialRelaysOnly else { return }
        func unusable(_ relay: String?) -> Bool { relay != nil && Invite.allowedRelay(relay) == nil }
        for i in data.contacts.indices where unusable(data.contacts[i].relay) { data.contacts[i].relay = nil }
        for i in data.invites.indices where unusable(data.invites[i].relay) { data.invites[i].relay = nil }
        for i in data.outbox.indices where unusable(data.outbox[i].relay) { data.outbox[i].relay = nil }
        if unusable(data.inviteRelay) { data.inviteRelay = nil }
    }

    /// When this build's relay is an onion service, a local relay address is that same relay reached the old way
    /// (a local or Wi-Fi address), which Tor can't reach: switch to the onion address and Tor. The mailboxes
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

    /// Hidden behind the passcode with everything still running underneath (see `SecuritySettings.keepReceivingLocked`).
    private(set) var covered = false
    /// Open and showing chats: unlocked, and not covered.
    var isOpen: Bool { phase == .unlocked && !covered }

    /// Whether an automatic lock may keep the keys loaded: unless "close everything" is chosen (`fullLock`), and not
    /// while burning. The same with or without a decoy or panic passcode, and in a decoy as in the real account: typing
    /// another passcode at a covered screen closes what's open and opens that one (`unlock`), so nothing about locking
    /// gives a decoy away.
    private var canCover: Bool {
        data.security.keepReceivingLocked && !burning && identity != nil
    }

    /// Hides everything but keeps receiving, so messages still arrive and delivery receipts still go out.
    private func cover() {
        dismissBanner()
        if call != nil { hangUp() }
        typing = [:]
        lastTypingSent = [:]
        presenceDue = [:]
        data.outbox.removeAll { $0.ephemeral == true }
        Notifier.shared.clearAll()
        openConversation = nil
        save()
        withAnimation(.smooth(duration: 0.5)) { covered = true }
    }

    private func uncover() {
        failedAttempts = 0
        lastActivity = Date()
        withAnimation(.smooth(duration: 0.5)) { covered = false }
        resync()
    }

    /// Locks. `keepingKeys` is for the automatic locks (idle, leaving the app, the iPhone locking): with the setting on
    /// they only cover. A lock you press yourself always closes everything.
    func lock(keepingKeys: Bool = false) {
        guard phase == .unlocked else { return }
        if covered { return }
        if keepingKeys, canCover { cover(); return }
        dismissBanner()
        connecting = false
        relayUnreachable = false
        relayFailures = 0
        if call != nil { hangUp() }
        syncTask?.cancel()
        tickTask?.cancel()
        readyTask?.cancel()
        typing = [:]
        lastTypingSent = [:]
        online = [:]
        presenceDue = [:]
        data.outbox.removeAll { $0.ephemeral == true }
        pendingReceipts = []
        duplicateReceipts = [:]
        laneResumeAt = [:]
        sendLanes.reset()
        Notifier.shared.clearAll()
        // Its mailbox keys must not stay in memory for whoever unlocks next. The relay keeps the registration, so a
        // locked Pulshade is still woken for new mail.
        pushTold = nil
        save()
        // Everything is written before the keys leave memory, so locking can't lose the last messages or outbox.
        settleSaves()
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
    func destroyEverything(leavingNoTrace: Bool = false, keepingBurnOrder: Bool = false) {
        // A wipe the app is killed in the middle of is finished at the next launch (`finishCutShortWipe`).
        Self.markWipeDue(burnStore, keepingSettings: !leavingNoTrace)
        if call != nil { hangUp() }
        covered = false
        Notifier.shared.clearAll()
        // The notification helper's keys and contacts go with everything else.
        HelperStore.clear()
        helperKnown = false
        // This account's mailboxes stop waking the phone. Done first, while the account's keys are still known.
        let hadPush = pushTold != nil || data.security.pushWake
        if hadPush, case let keys = pushKeys().union(pushTold?.keys ?? []), !keys.isEmpty {
            let named = Array(keys)
            let token = pushTold?.token
            Task {
                for start in stride(from: 0, to: named.count, by: 256) {
                    try? await client(nil, lane: "push")?.unregisterPush(keys: Array(named[start..<min(start + 256, named.count)]), token: token)
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
        // A Burn keeps its order so the server side can still be finished; every other wipe leaves nothing behind.
        if !keepingBurnOrder {
            burnStore.delete()
            burnPending = false
        }
        failedAttempts = 0
        AnnouncementWatch.forget()
        // The few display settings kept outside the vault, so the lock screen can look right.
        for key in ["pulshade.theme", "pulshade.menuBar", "pulshade.blockCapture", "pulshade.blur", LockStyle.key, LockStyle.legacyKey] {
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
        // Last of all: until here, a wipe cut short is finished at the next launch.
        try? FileManager.default.removeItem(at: Self.wipeDueFile(burnStore))
        withAnimation(.smooth(duration: 0.6)) { phase = .welcome }
    }

    /// What's held in memory only, for the account that was open: persona keys and the like. Whoever unlocks
    /// next, a decoy included, must not find them.
    private func forgetSession() {
        readyTask?.cancel()
        readyTask = nil
        profileTask?.cancel()
        profileTask = nil
        // The helper's copy of this account's envelope keys lives in the Keychain so the locked phone can use it;
        // the copy in this process must not outlive the unlock that wrote it.
        helperWritten = nil
        helperKnown = false
        recoveredSessions = [:]
        unreadable = [:]
        resentAt = [:]
        identityCache = [:]
        deviceKeyCache = [:]
        DecodedImages.forget()
        LinkPreviews.forgetLinked()
        StoryImages.forget()
        Self.mediaCache.removeAllObjects()
        sendHolds = [:]
        refusals = [:]
        unsentMessages = []
        retriedAt = [:]
        keysAnsweredAt = [:]
        // Per-contact state derived from the account that was open, including text typed into requests.
        removedStories = [:]
        clipActivity = [:]
        clipAsks = [:]
        clipResent = [:]
        heldMailNoted = []
        receivedMediaBytes = 0
        mediaRequested = []
        pendingMediaNames = []
        trackedMedia = nil
        storageNotice = nil
        mediaLimitNoted = false
        // An upload for the account that was open must not carry on behind the lock for whoever opens next.
        for task in clipUploads.values { task.cancel() }
        clipUploads = [:]
        clipWaiting = [:]
        lastMend = [:]
        requestNotes = [:]
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
        guard identity != nil, phase == .unlocked, link == .online else { wipeNow(); return }
        // Marked before anything goes to the relay: if the app is killed in the few seconds it waits, the next launch
        // wipes this device before anything can open it. Without the mark there's no waiting at all.
        guard Self.markWipeDue(burnStore) else { wipeNow(); return }
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
    /// When each friend last asked for the stories you have up again, so one can't make you send a video over and over.
    @ObservationIgnored private var storiesWantedAt: [String: Date] = [:]
    /// Contacts already told that held mail was discarded, so the note is said once per session.
    @ObservationIgnored private var heldMailNoted: Set<String> = []
    /// Received media in messages and stories, kept in memory only and rebuilt when the account is opened.
    @ObservationIgnored private(set) var receivedMediaBytes = 0
    /// Items the user asked for again, which may use the hard ceiling.
    @ObservationIgnored private var mediaRequested: Set<UUID> = []
    /// Files sealed for a message/story not yet appended; real, never fillers.
    @ObservationIgnored private var pendingMediaNames: Set<String> = []
    /// The media files the open account's data named at its last save (see `releaseDroppedMedia`), and whose account.
    @ObservationIgnored private var trackedMedia: (account: String, names: Set<String>)?
    /// Tests can lower the ceiling and turn eviction off; production uses the 512 MiB pool budget.
    @ObservationIgnored var mediaSoftLimitForTests: Int?
    @ObservationIgnored var mediaHardLimitForTests: Int?
    @ObservationIgnored var evictsForTests = true
    /// Set once per session when the cap made the app remove old media.
    @ObservationIgnored private(set) var storageNotice: String?
    @ObservationIgnored private var mediaLimitNoted = false

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
            guard convo.shared != nil else { continue }
            for start in stride(from: 0, to: mine.count, by: 200) {
                postIfShared(.unsend(ids: Array(mine[start..<min(start + 200, mine.count)])), in: convo.id)
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
        releaseDroppedMedia(account: identity.fingerprint)
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

    /// Whether the last write of the vault failed, set by the save queue itself so a reader on the main actor sees the
    /// outcome of every write that has finished, not only the ones whose follow-up has had its turn. While it's set,
    /// nothing sealed under the ratchet leaves the device (see `flush`).
    private final class SaveHealth: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        private var writing = 0
        var lastWriteFailed: Bool { lock.withLock { failed } }
        func record(failed value: Bool) { lock.withLock { failed = value } }
        /// Writes handed to the save queue and not finished yet.
        var writesInFlight: Int { lock.withLock { writing } }
        func started() { lock.withLock { writing += 1 } }
        func finished() { lock.withLock { writing -= 1 } }
    }
    @ObservationIgnored private let saveHealth = SaveHealth()

    /// Tests: writes handed to the save queue that haven't finished.
    var saveWritesInFlight: Int { saveHealth.writesInFlight }

    /// Tests: how long each write on the save queue is held before it starts, to catch a send that doesn't wait for it.
    @ObservationIgnored var saveDelayForTesting: TimeInterval = 0

    /// Tests: whether a write has failed and nothing since has landed.
    var lastSaveFailed: Bool { saveHealth.lastWriteFailed }

    /// Tests: make the next writes fail or succeed.
    @ObservationIgnored var failSavesForTesting = false

    /// Starts writing whatever is waiting, in the background.
    private func flushSave() {
        saveTimer?.cancel()
        saveTimer = nil
        guard let (data, identity) = unsaved else { return }
        unsaved = nil
        saveGeneration += 1
        let generation = saveGeneration
        let vault = vault
        let health = saveHealth
        let failing = failSavesForTesting
        let delay = saveDelayForTesting
        health.started()
        Self.saveQueue.async { [weak self] in
            defer { health.finished() }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            do {
                if failing { throw VaultError.corrupt }
                try vault.save(data, with: identity)
                health.record(failed: false)
            } catch {
                health.record(failed: true)
                // A failed write keeps the waiting copy so a later save retries it, rather than losing every
                // change since the last successful write — unless something newer is already queued, or the
                // vault was wiped in the meantime.
                Task { @MainActor in
                    // Only while this account is still the open one. After a lock (or a wipe) the identity has
                    // left memory on purpose, and putting it back here would keep every key and message alive.
                    guard let self, self.phase == .unlocked, self.identity?.fingerprint == identity.fingerprint,
                          self.unsaved == nil, self.saveGeneration == generation else { return }
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

    /// The same, for a caller that can wait without holding the main actor: the encrypting stays on the save queue
    /// and this returns once the write that was waiting has landed. Used before acknowledging mail, so receiving
    /// stays durable without stalling the interface.
    func settleSavesAsync() async {
        flushSave()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.saveQueue.async { continuation.resume() }
        }
    }

    /// Drops a waiting write and lets any under way finish, so nothing lands after the vault's files are wiped.
    private func discardSaves() {
        saveHealth.record(failed: false)
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

    /// Brings Pulshade forward on a chat. If it's locked, the chat opens right after unlocking.
    func open(_ id: Conversation.ID) {
        if phase == .unlocked { requestedConversation = id } else { openAfterUnlock = id }
    }

    /// Whether Pulshade is the front app. False when there's no app at all, as in tests.
    private var appActive: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Platform.isActive
    }

    private func notify(_ message: Message, at i: Int) {
        let convo = data.conversations[i]
        // Being @-mentioned gets through a muted chat: that's someone asking for you in particular.
        guard data.security.notifications, !convo.muted || message.mentionsMe else { return }
        if appActive && openConversation == convo.id { return }
        #if os(iOS)
        // Behind the screen with push set up for this account, Apple's banner is the notification: Pulshade's own
        // beside it would be a second one, and one that could name the sender. (Mail for another persona isn't
        // pushed, so that still gets Pulshade's own.)
        if !appActive, convo.persona == nil, pushTold != nil { return }
        #endif
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
            let style: NotificationContent = isOpen ? .full : data.security.notificationContent
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
        // A channel's code is asked for each time its screen is drawn. Its signature comes out different every time it's
        // made, so the same code is handed back while the app is open: a screen (and its short link) keyed on the text
        // would otherwise see a new code at every redraw.
        if channel != nil, let kept = channelCodes[receiveKey] { return kept }
        let code = (try? Invite(kind: channel == nil ? .contact : .channel, identity: me,
                                sendID: Mailbox.sendID(for: receiveKey), relay: relay,
                                channel: channel.flatMap { conversation($0) }.map(\.wireID)).code) ?? ""
        if channel != nil, !code.isEmpty { channelCodes[receiveKey] = code }
        return code
    }

    /// Accepts someone's invite: opens a mailbox for them and says hello.
    @discardableResult
    func addContact(code: String, nickname: String, persona: UUID?? = nil) -> Contact? {
        let owner = persona ?? activePersona
        guard identity != nil, let invite = Invite(code: code), !myFingerprints.contains(invite.fingerprint) else { return nil }
        let known = contact(invite.fingerprint, in: owner)
        if let known, !known.hidden, invite.kind == .contact { return known }
        // Keys already pinned for this signing key must be the ones the invite commits to: they come from the same seed.
        if let pinned = known?.pq, pinned.commitment != invite.pqHash { return nil }
        // A friend's channel code used again within a few days sends nothing more: their phone already has the hello, and
        // each one keeps an ask on every one of their devices (see below), which would push out real ones.
        // Only the same code: another of their channels' codes is followed as usual.
        let followKey = Self.followKey(invite.fingerprint, owner)
        let followedLately = known.map { !$0.hidden } == true && invite.kind == .channel
            && data.followsAsked[followKey]?.contains { $0.tag == invite.codeTag && Date().timeIntervalSince($0.at) < 3 * 86_400 } == true
        if invite.kind == .channel { noteFollowAsked(invite.fingerprint, persona: owner, tag: invite.codeTag, channel: invite.channel) }
        if followedLately, let known { save(); return known }
        // Another of their channels before they've answered the first: the hello would have to go classical again, and
        // their app turns that away once it has read the first. It goes once their keys are known (`sendFollowsLater`).
        if let known, known.hidden, known.pq == nil, invite.kind == .channel, !known.devices.isEmpty, known.receiveKey != nil,
           let i = contactIndex(known.fingerprint, owner) {
            let held = (data.contacts[i].followLater ?? []).filter { $0 != invite.code }
            data.contacts[i].followLater = Array((held + [invite.code]).suffix(4))
            save()
            return data.contacts[i]
        }
        // A friend's own channel, or another channel of someone whose code you already followed: they stay exactly as they
        // are (devices, sessions, mailboxes, nickname). The hello goes to the channel's code mailbox and names the mailbox
        // they already write to, so their phone only lets this account into the channel and changes nothing else. Starting
        // over instead would leave the first channel's invite sealed to keys and a mailbox given up here.
        if let known, invite.kind == .channel, !known.hidden || (!known.devices.isEmpty && known.receiveKey != nil) {
            guard let i = contactIndex(known.fingerprint, owner), !known.devices.isEmpty, let receiveKey = known.receiveKey,
                  let (pending, request) = signedHandshake(persona: owner, to: invite.signingKey, context: .hello),
                  let meCard = card(sendID: Mailbox.sendID(for: receiveKey), persona: owner) else { return nil }
            // Their app from before this answers such a hello with new keys for the chat, from whichever of their devices
            // read the code: the ask is kept on each, so that answer completes here instead of leaving the two sides on
            // different keys. A newer app doesn't answer, and the ask is let go with the other old ones.
            for d in data.contacts[i].devices.indices { keepEarlierAsk(pending, contact: i, device: d) }
            seal(.hello(meCard, request), contact: i, device: 0, toSendID: invite.sendID, toRelay: .some(invite.relay))
            save()
            return known
        }

        let mailbox = Mailbox.make()
        var contact = known ?? Contact(fingerprint: invite.fingerprint, signingKey: invite.signingKey,
                                       agreementKey: invite.agreementKey, sendID: invite.sendID)
        contact.persona = owner
        contact.pqCommit = invite.pqHash
        contact.relay = invite.relay
        // Someone whose code you used yourself is never let go as a stranger who said hello on yours.
        contact.viaCode = nil
        contact.nickname = nickname
        contact.receiveKey = mailbox.receiveKey
        // Following a channel doesn't make its owner one of your contacts.
        contact.hidden = invite.kind == .channel ? (known?.hidden ?? true) : false
        if !contact.hidden { Self.takeBack(&contact) }
        guard let (handshake, request) = signedHandshake(persona: owner, to: invite.signingKey, context: .hello) else { return nil }
        // The invite names one of their devices' mailboxes; its id arrives with their answer.
        var link = DeviceLink(sendID: invite.sendID)
        link.handshake = handshake
        contact.devices = [link]
        guard let meCard = card(sendID: mailbox.sendID, persona: owner) else { return nil }
        upsert(contact)
        seal(.hello(meCard, request), to: contact.fingerprint, persona: owner)
        shareStories(with: contact)
        save()
        return contact
    }

    func rename(_ fingerprint: String, to nickname: String) {
        guard let i = data.contacts.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        data.contacts[i].nickname = nickname
        refreshDirectTitle(fingerprint)
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
                        signingKey: keys.card.signing, agreementKey: keys.card.agreement, sendID: sendID, device: deviceID(for: persona),
                        pq: keys.pqCard)
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


    private func profilePayload(_ persona: UUID?, for contact: String) -> Payload {
        let profile = profile(for: persona)
        return .profile(name: profile.name, avatar: profile.avatar, color: profile.color, banner: profile.banner,
                        bio: profile.bio.flatMap { $0.isEmpty ? nil : $0 }, handle: profile.handle,
                        links: Self.sharedLinks(profile), notes: Self.sharedNotes(profile, for: contact))
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
        // Groups and channels always share one mailbox (a channel keeps its followers out of its settings, see GroupRoster).
        // Whoever's app can't take part is refused before this is called (see `membersNeedingUpdate`), never put in an older format.
        if kind == .group || kind == .channel,
           let shared = startSharedGroup(title: name, members: members, avatar: avatar, persona: owner, kind: kind) {
            return shared
        }
        // No account to make a group with: nothing is made, and what comes back isn't kept anywhere.
        var convo = Conversation(kind: kind, title: name, avatar: avatar, members: kind == .group || kind == .channel ? [] : members)
        convo.persona = owner
        guard kind == .direct || kind == .broadcast else { return convo }
        withAnimation(.snappy) { data.conversations.insert(convo, at: 0) }
        save()
        return convo
    }

    private func directConversation(with fingerprint: String, persona: UUID?) -> Conversation? {
        data.conversations.first { $0.kind == .direct && $0.members == [fingerprint] && $0.persona == persona }
    }

    @discardableResult
    func send(_ text: String, image: Data? = nil, voice: VoiceNote? = nil, replyTo: Message? = nil,
              quote: ReplyRef? = nil, preview: LinkPreview? = nil, note: NoteCard? = nil,
              mentioning picks: [(fingerprint: String, name: String)] = [], forwarded: Bool = false, in id: Conversation.ID) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil || voice != nil || note != nil, let i = index(of: id) else { return false }
        let convo = data.conversations[i]
        guard canPost(in: convo) else { return false }

        let now = Date()
        // Replying to a photo carries a small copy of it, so the quote shows what was answered.
        let reply = replyTo.map { ReplyRef(id: $0.id, author: $0.sender, snippet: Self.snippet(of: $0), picture: Self.quotePicture(imageData(for: $0))) } ?? quote
        var message = Message(sender: "me", text: trimmed, image: image, voice: voice, date: now,
                              expiresAt: convo.disappearAfter.map { now.addingTimeInterval($0) }, reply: reply,
                              preview: preview)
        message.note = note
        message.noForward = noForwardFlag
        message.forwarded = forwarded ? true : nil
        // Only people of this group that are your contacts can be mentioned.
        let allowed = Set(mentionable(in: convo).map(\.fingerprint))
        message.mentions = Mention.locate(picks.filter { allowed.contains($0.fingerprint) }, in: trimmed)
        withAnimation(.snappy(duration: 0.4)) { data.conversations[i].messages.append(message) }

        var wire = WireMessage(id: message.id, conversation: sharedID(convo), kind: convo.kind == .broadcast ? .direct : convo.kind,
                               text: trimmed, image: image, voice: voice, date: RelayClock.relay(now), expiresIn: convo.disappearAfter,
                               reply: reply.map { ReplyRef(id: $0.id, author: $0.author == "me" ? (myFingerprint(in: convo) ?? "") : $0.author,
                                                           snippet: $0.snippet, picture: $0.picture) },
                               preview: preview, note: note,
                               mentions: message.mentions.isEmpty ? nil : message.mentions)
        wire.noForward = message.noForward
        wire.forwarded = message.forwarded
        // A big photo or voice note in a group that shares one mailbox goes to the relay once, not into the mailbox,
        // where the relay would hold it in memory for as long as the group's mail lives.
        if convo.shared != nil, relayClipsEnabled, let light = lightened(wire) {
            postLightened(light, full: wire, in: id, message: message.id)
            lastTypingSent[id] = nil
            save()
            return true
        }
        if postIfShared(.message(wire), in: id, message: message.id) {
            lastTypingSent[id] = nil
            save()
            return true
        }
        let recipients = audience(convo)
        // A big photo or voice note goes to the relay once for everyone whose app takes it that way; the others get it
        // inside the message, as before.
        let light = lightened(wire)
        for member in recipients {
            if let light, readsMediaBlobs(member) {
                enqueue(.message(light.wire), to: member, message: message.id)
                deliverClip(light.bytes, id: message.id, to: member, known: nil, kind: light.kind)
            } else {
                enqueue(.message(wire), to: member, message: message.id)
            }
        }
        if recipients.isEmpty { setStatus(.sent, for: [message.id]) }
        lastTypingSent[id] = nil
        save()
        return true
    }

    // MARK: Forwarding

    /// What goes on a message of yours about forwarding: nil unless you've said no in Privacy & Security.
    private var noForwardFlag: Bool? { data.security.allowForwarding ? nil : true }

    /// Whether a message can be forwarded from its chat. Not one its sender asked to keep where it is, not in a chat
    /// with a timer (a copy would outlive it), and not what only means something from its sender (a note of their
    /// profile) or a file kept on the relay that its sender can erase.
    func canForward(_ message: Message, in convo: Conversation) -> Bool {
        guard !message.isSystem, convo.disappearAfter == nil, message.expiresAt == nil,
              message.note == nil else { return false }
        if !message.isMine, message.noForward == true { return false }
        if message.isVideo { return videoData(for: message)?.isEmpty == false }
        guard message.awaiting == nil, message.attachment == nil || message.attachment?.kind == .photo
                || message.attachment?.kind == .voice else { return false }
        return !message.text.isEmpty || imageData(for: message) != nil || message.voice != nil
    }

    /// Whether Copy is offered on a message: not on someone's who asked that their messages aren't forwarded.
    func canCopy(_ message: Message) -> Bool {
        message.isMine || message.noForward != true
    }

    /// Chats a message from `source` can be forwarded to: this persona's, where you can write. Never another persona's,
    /// which would tie the two together.
    func forwardTargets(from source: Conversation.ID) -> [Conversation] {
        guard let from = conversation(source) else { return [] }
        return data.conversations.filter {
            $0.persona == from.persona && !$0.isAnnouncements && canPost(in: $0)
        }
    }

    /// Sends a copy of a message to another chat, as yours, marked only as forwarded: who wrote it first and where it
    /// came from go nowhere. Quotes and mentions stay behind.
    func forward(_ message: Message, from source: Conversation.ID, to target: Conversation.ID) {
        guard let from = conversation(source), canForward(message, in: from),
              forwardTargets(from: source).contains(where: { $0.id == target }) else { return }
        if message.isVideo, let clip = videoData(for: message), !clip.isEmpty {
            sendVideo(clip, poster: imageData(for: message), seconds: message.clipSeconds ?? 0, caption: message.text, forwarded: true, in: target)
        } else {
            var voice = message.voice
            if let audio = voiceAudio(for: message), voice?.audio.isEmpty != false { voice?.audio = audio }
            send(message.text, image: imageData(for: message), voice: voice, preview: message.preview, forwarded: true, in: target)
        }
    }

    // MARK: Video clips kept on the relay

    /// Whether every device of a contact reads files kept on the relay.
    private func readsAttachments(_ contact: Contact) -> Bool {
        relayClipsEnabled && !contact.devices.isEmpty && contact.devices.allSatisfy { $0.readsAttachments == true }
    }

    /// Whether every device of a contact takes photos, voice notes and photo stories as a pointer to a copy on the relay.
    private func readsMediaBlobs(_ contact: Contact) -> Bool {
        relayClipsEnabled && !contact.devices.isEmpty && contact.devices.allSatisfy { $0.readsMediaBlobs == true }
    }

    /// A photo or voice note bigger than this goes to the relay once, for people whose app takes it that way, instead of
    /// riding inside each copy of the message. Anything smaller costs less in the message than a trip to the relay.
    static let mediaInline = 48_000
    /// The biggest photo or voice note taken from the relay or in pieces.
    static let maxMediaBytes = 8_000_000
    /// The retained received-media budget. Older media is removed from whoever holds the most when it is reached.
    static let mediaPoolLimit = 512 * 1024 * 1024
    static let receivedMediaSoftLimit = mediaPoolLimit
    static let receivedMediaHardLimit = mediaPoolLimit

    /// What one item in the sealed pool takes on disk: its padded, sealed size (at least 64 KiB), not its own length,
    /// so the budget bounds the pool's real disk use however small the items a contact sends.
    static func poolBytes(_ ref: MediaFileRef?) -> Int {
        ref.map { MediaPool.sealedSize(ofPlain: $0.size) } ?? 0
    }

    /// The bytes in a received message that count against the media limit.
    static func mediaBytes(_ message: Message) -> Int {
        (message.image?.count ?? 0) + poolBytes(message.imageFile)
            + (message.video?.count ?? 0) + poolBytes(message.videoFile)
            + (message.voice?.audio.count ?? 0) + poolBytes(message.voice?.audioFile)
            + (message.preview?.image?.count ?? 0) + (message.reply?.picture?.count ?? 0)
    }

    static func mediaBytes(_ style: StoryStyle) -> Int {
        switch style {
        case .text: 0
        case let .image(data, _), let .video(data, _): data.count
        }
    }

    static func mediaBytes(_ story: Story) -> Int {
        mediaBytes(story.style) + poolBytes(story.mediaFile)
    }

    /// A story's style with its media removed but its words and palette kept.
    static func withoutMedia(_ style: StoryStyle) -> StoryStyle {
        switch style {
        case .text: style
        case let .image(_, caption): .image(Data(), caption: caption)
        case let .video(_, caption): .video(Data(), caption: caption)
        }
    }
    /// The most bytes one story's clip (or a chat video's pieces) may hold while it is still arriving.
    static func storyClipFits(_ parts: [Int: Data]) -> Bool {
        parts.values.reduce(0) { $0 + $1.count } <= maxMediaBytes
    }
    /// A story may say only so much: its words and caption are short, whatever a payload claims.
    static func cleanedStoryStyle(_ style: StoryStyle) -> StoryStyle {
        switch style {
        case let .text(text, palette): .text(StoryText.clipped(text), palette: palette)
        case let .image(data, caption): .image(data, caption: StoryText.clipped(caption))
        case let .video(data, caption): .video(data, caption: StoryText.clipped(caption))
        }
    }
    /// The most stories one sender's account may have live here at once, for one persona.
    static let maxStoriesPerAuthor = 100

    /// What goes to people whose app takes a message's photo or voice note on its own: the message with a tiny preview
    /// of the photo, or the voice note without its sound, and the bytes that follow. Nil when nothing in it is worth it.
    private func lightened(_ wire: WireMessage) -> (wire: WireMessage, bytes: Data, kind: Attachment.Kind)? {
        guard wire.clip == nil, wire.attachment == nil, wire.mediaFollows == nil else { return nil }
        var light = wire
        if let image = wire.image, wire.voice == nil, image.count > Self.mediaInline, image.count <= Self.maxMediaBytes {
            light.image = Self.thumbnail(image, side: 48)
            light.mediaFollows = .photo
            return (light, image, .photo)
        }
        if let voice = wire.voice, wire.image == nil, voice.audio.count > Self.mediaInline, voice.audio.count <= Self.maxMediaBytes {
            light.voice = VoiceNote(audio: Data(), duration: voice.duration, levels: voice.levels)
            light.mediaFollows = .voice
            return (light, voice.audio, .voice)
        }
        return nil
    }

    /// Whether clips go to the relay and people get a pointer. Only tests switch it off, to follow the piece-by-piece
    /// way that apps from before files still use.
    @ObservationIgnored var relayClipsEnabled = true

    /// Shared groups whose outbox is being posted right now.
    @ObservationIgnored var groupFlushing: Set<UUID> = []
    /// `flushPartingPosts` is running.
    @ObservationIgnored var partingFlushing = false
    /// When each group mailbox was last read to the end in this run, by group and epoch: a post that hasn't come back is
    /// only posted again once its mailbox has been read since it was sent.
    @ObservationIgnored var groupFetchedAt: [String: Date] = [:]
    /// When a member's catch-up request was last answered, and the answers given in the last hour per group.
    @ObservationIgnored var catchUpAnswered: [String: Date] = [:]
    @ObservationIgnored var catchUpWindow: [UUID: [Date]] = [:]
    /// What this device posted again for each group in the last day, so nobody can use up the relay's room for a mailbox.
    @ObservationIgnored var catchUpSent: [UUID: [(at: Date, bytes: Int)]] = [:]
    static let catchUpAnswersPerHour = 6
    static let catchUpMaxPosts = 100
    /// At most this much is posted again for one request, and this much for one group in a day, by one device.
    static let catchUpBytesPerAnswer = 128 * 1024
    static let catchUpBytesPerDay = 512 * 1024
    /// When a removal that didn't stick was last tried again, by group.
    @ObservationIgnored var lastGroupRetry: [UUID: Date] = [:]
    @ObservationIgnored var groupRetries: [UUID: Int] = [:]
    /// When join and answer mailboxes were last read, whether a read is under way, and asks being sent.
    @ObservationIgnored var lastJoinPoll = Date.distantPast
    @ObservationIgnored var joinPolling: Set<String> = []
    @ObservationIgnored var joinSending: Set<UUID> = []
    /// Join requests already opened, by mailbox and envelope, so a waiting one isn't opened again at every look.
    @ObservationIgnored var joinOpened: [String: JoinRequest] = [:]
    /// When a request through someone else's link was first seen, for stepping in if their phone is away.
    @ObservationIgnored var joinFirstSeen: [String: Date] = [:]
    /// When each requester was last answered, and when admins were last told of a waiting request, by group.
    @ObservationIgnored var joinAnswered: [String: Date] = [:]
    @ObservationIgnored var joinNotified: [UUID: Date] = [:]
    /// When each link let someone in on its own lately, for its hourly limit.
    @ObservationIgnored var joinAdmits: [UUID: [Date]] = [:]
    /// As an admin: when a missed key was last sent again to each member (by member key, hex).
    @ObservationIgnored var keyResent: [String: Date] = [:]
    /// When this device last tried to move each group to keys made with the current group secret.
    @ObservationIgnored var groupRenewTried: [UUID: Date] = [:]
    /// When a follower of a channel was last sent the current key because they asked (by channel and key), so a flood of asks is answered once.
    @ObservationIgnored var channelKeyAnswered: [String: Date] = [:]
    /// When each follower's ask for a staff device's chain was last answered (by channel, follower and chain), a minute apart.
    @ObservationIgnored var followerChainAnswered: [String: Date] = [:]
    /// Groups with posts just held for want of a chain: asked for together, in one direct post, once a fetch is read.
    @ObservationIgnored var chainAsksDue: Set<UUID> = []
    /// When the envelope being handled was sent (as its sender signed it), for the few payloads that mustn't act on a stale copy.
    @ObservationIgnored var handlingSentAt: Date?
    /// When each channel let someone in through its code lately, for its hourly limit.
    @ObservationIgnored var channelAdmits: [UUID: [Date]] = [:]
    /// People from groups this device has asked to be friends this session, so the button says so.
    var friendAsked: Set<String> = []

    /// Gets a clip to one contact: as a pointer to the one sealed copy on the relay if their app reads those, otherwise in
    /// pieces as before. The clip is uploaded once, however many people are waiting for it. `known` is the copy already
    /// there, if any.
    /// How long a photo, video or file in a one-to-one chat stays on the relay for a phone that hasn't fetched it: as long
    /// as the message naming it can wait (30 days), so the message doesn't arrive to a file that is already gone. Group
    /// files keep the group's own week.
    static let chatFileLife: TimeInterval = 30 * 86_400
    /// How long a phone waits before fetching a photo or clip whose pointer just arrived (one opened by hand isn't held).
    static let blobFetchDelay: ClosedRange<Double> = 2...20

    private func deliverClip(_ clip: Data, id: UUID, to contact: Contact, known: Attachment?, lifetime: TimeInterval = AppModel.chatFileLife,
                             only wanted: [Int]? = nil, kind: Attachment.Kind = .video) {
        guard kind == .video ? readsAttachments(contact) : readsMediaBlobs(contact) else {
            sendClip(clip, id: id, to: contact, only: wanted)
            return
        }
        if let known, known.expires > RelayClock.now { enqueue(.clipBlob(id: id, clip: known), to: contact); return }
        clipWaiting[id, default: []].append(contact)
        guard clipUploads[id] == nil else { return }
        guard let relay = blobClient(),
              let prepared = try? BlobTransfer.prepare(data: clip, kind: kind, lifetime: min(max(lifetime, 3600) + 3600, Self.chatFileLife)) else {
            clipUploaded(id, clip: clip, nil)
            return
        }
        clipUploads[id] = Task { [weak self] in
            defer { RelayClient.retire(lane: relay.lane) }
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
            // The fallback pieces are copies of the story too, so they keep it uploading.
            trackUpload(of: id)
            return
        }
        // Kept with the story or message, so it can be erased when that goes.
        if let s = data.stories.firstIndex(where: { $0.id == id && $0.author == "me" }) {
            // A story's clip stays until its timer runs out: everyone is sent the same pointer.
            data.stories[s].clipBlob = a
            for contact in waiting { enqueue(.clipBlob(id: id, clip: a), to: contact) }
            save()
            // The clip is on the relay now: let the progress catch up, and let more people be queued for.
            trackUpload(of: id)
            drainStoryBacklog()
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
    /// deleted or expires. The list has a fixed shape (`BlobReaders`), so the relay can't count the people or their
    /// devices: entries nobody reads, and uses nobody's device will spend, are spent by this phone later (`BlobSpend`).
    private func registerReaders(for contacts: [Contact], of a: Attachment) async -> [String: Data]? {
        var tokens: [String: Data] = [:]
        var devices: [(token: Data, count: Int)] = []
        for contact in contacts where tokens[Self.personKey(contact)] == nil {
            let token = Data.random(32)
            tokens[Self.personKey(contact)] = token
            devices.append((token, max(1, contact.devices.count)))
        }
        let plan = Self.readerPlan(devices, size: a.storedSize)
        guard !devices.isEmpty, plan.records.count <= 1024, let relay = blobClient() else { return nil }
        defer { RelayClient.retire(lane: relay.lane) }
        do { try await relay.blobReaders(a.id, secret: a.secret, readers: plan.records) } catch { return nil }
        let now = Date()
        for spend in plan.spends {
            data.blobSpends.append(BlobSpend(id: a.id, token: spend.token, uses: spend.uses,
                                             due: now.addingTimeInterval(trafficShaping ? .random(in: Self.blobSpendDelay) : 0),
                                             expires: a.expires))
        }
        if !plan.spends.isEmpty { save() }
        return tokens
    }

    /// When this phone spends the uses of a file's reader list that nobody else will: at a random moment between ten
    /// minutes and six hours after sending, each on a connection of its own.
    static let blobSpendDelay: ClosedRange<Double> = 600...21_600

    /// The reader list for people with these tokens and numbers of devices (`BlobReaders`), in random order, and the uses
    /// this phone has to spend itself: all of each made-up entry's, and those of each real one beyond its devices.
    static func readerPlan(_ readers: [(token: Data, count: Int)], size: Int)
        -> (records: [(hash: Data, uses: Int)], spends: [(token: Data, uses: Int)]) {
        let shape = BlobReaders.shape(devices: readers.map(\.count), size: size)
        var records: [(hash: Data, uses: Int)] = []
        var spends: [(token: Data, uses: Int)] = []
        for reader in readers {
            records.append((Data(SHA256.hash(data: reader.token)), shape.uses))
            let extra = shape.uses - min(reader.count, shape.uses)
            if extra > 0 { spends.append((reader.token, extra)) }
        }
        for _ in readers.count..<max(readers.count, shape.count) {
            let token = Data.random(32)
            records.append((Data(SHA256.hash(data: token)), shape.uses))
            spends.append((token, shape.uses))
        }
        return (records.shuffled(), spends)
    }

    // MARK: Mailboxes that move

    /// How long this device reads a contact on one mailbox before it moves to a fresh one.
    static let mailboxLife: TimeInterval = 7 * 86_400
    /// How long a mailbox moved from is still read once every device of theirs writes to the new one: as long as the relay
    /// keeps mail (`TTL`, 30 days), for what they sent there before they heard.
    static let formerMailboxLife: TimeInterval = 30 * 86_400

    /// Every mailbox this device reads a contact on: the one it reads now, and those it moved from that may still get mail.
    static func mailboxes(of c: Contact) -> [Data] {
        (c.receiveKey.map { [$0] } ?? []) + (c.formerMailboxes ?? []).map(\.key).filter { $0 != c.receiveKey }
    }

    /// Moves each friend's mailbox once a week (MD-001): a fresh one, which this device tells each of their devices about
    /// inside its session (`Payload.mailbox`). The old one is still read until every device of theirs has written to the new
    /// one, and then for as long as mail can wait. A friend whose app doesn't move (a build before 22) keeps writing to the
    /// old one, which is then read for as long as they do, and this device doesn't move again until they have: so nothing
    /// sent to an old mailbox is ever missed. Each friend's week starts at its own random moment, so moves don't line up.
    ///
    /// The relay is asked first (`RelayClient.moveMailbox`): the fresh mailbox takes over the old one's standing there, so a
    /// friend's mail to it waits the full month like any mail, not the two days the relay gives a mailbox nobody has collected
    /// from. Only once it has said yes does this device move and tell them; until then (an older relay, say) it stays put.
    /// Returns the moves started, for whoever wants to wait for them (the tests).
    @discardableResult
    func tendMailboxes(now: Date = Date()) -> [Task<Void, Never>] {
        var changed = false
        var started: [Task<Void, Never>] = []
        for i in data.contacts.indices {
            let c = data.contacts[i]
            if let formers = c.formerMailboxes, formers.contains(where: { ($0.until ?? .distantFuture) < now }) {
                let left = formers.filter { ($0.until ?? .distantFuture) >= now }
                data.contacts[i].formerMailboxes = left.isEmpty ? nil : left
                changed = true
            }
            guard c.receiveKey != nil, !c.isSelf, !c.hidden, !c.awaitingAcceptance, c.departing == nil, !c.devices.isEmpty,
                  c.devices.allSatisfy({ !$0.id.isEmpty && $0.session?.canSend == true }) else { continue }
            guard let since = c.mailboxSince else {
                data.contacts[i].mailboxSince = now.addingTimeInterval(-(trafficShaping ? .random(in: 0..<Self.mailboxLife) : 0))
                changed = true
                continue
            }
            guard now.timeIntervalSince(since) >= Self.mailboxLife,
                  (data.contacts[i].formerMailboxes ?? []).allSatisfy({ $0.until != nil }) else { continue }
            if let move = startMailboxMove(contact: i, now: now) { started.append(move) }
        }
        if changed { save() }
        return started
    }

    /// Moves being asked of the relay, by contact, so housekeeping doesn't start a second one. Memory only.
    @ObservationIgnored private var mailboxMoving: Set<String> = []
    /// When a move the relay didn't make may be asked for again, by contact. Memory only.
    @ObservationIgnored private var mailboxMoveRetry: [String: Date] = [:]
    /// How long after a move the relay didn't make (unreachable, an older relay, too many at once) it is asked again.
    static let mailboxMoveRetryAfter: TimeInterval = 6 * 3600

    /// Asks the relay to move contact `i`'s mailbox to a fresh one, on the lane the old one is read on (so the relay learns
    /// nothing it doesn't see already: both are read there from now on), and moves once it has.
    private func startMailboxMove(contact i: Int, now: Date) -> Task<Void, Never>? {
        let c = data.contacts[i]
        let key = sessionKeyPrefix(c)
        guard let old = c.receiveKey, !mailboxMoving.contains(key), (mailboxMoveRetry[key] ?? .distantPast) <= now else { return nil }
        let fresh = Mailbox.make().receiveKey
        let lane = currentLanes().first { $0.value.contains(old) }?.key
        guard let relay = client(lane?.relay, lane: lane?.name ?? "main") else { return nil }
        mailboxMoving.insert(key)
        let (fingerprint, persona) = (c.fingerprint, c.persona)
        return Task { [weak self] in
            let moved = await relay.moveMailbox(from: old, to: fresh)
            guard let self else { return }
            self.mailboxMoving.remove(key)
            guard let j = self.contactIndex(fingerprint, persona), self.data.contacts[j].receiveKey == old else { return }
            guard moved else {
                self.mailboxMoveRetry[key] = Date().addingTimeInterval(Self.mailboxMoveRetryAfter)
                return
            }
            self.mailboxMoveRetry[key] = nil
            self.moveMailbox(contact: j, to: fresh, now: now)
            self.save()
        }
    }

    private func sessionKeyPrefix(_ c: Contact) -> String { "\(c.persona?.uuidString ?? "main")|\(c.fingerprint)" }

    /// Moves this device to `fresh` (which the relay has already given the old one's standing) for contact `i`, and tells
    /// each of their devices.
    private func moveMailbox(contact i: Int, to fresh: Data, now: Date = Date()) {
        guard let old = data.contacts[i].receiveKey else { return }
        data.contacts[i].formerMailboxes = (data.contacts[i].formerMailboxes ?? []) + [FormerMailbox(key: old, until: nil)]
        data.contacts[i].receiveKey = fresh
        data.contacts[i].mailboxSince = now
        data.contacts[i].movedHeard = []
        enqueue(.mailbox(sendID: Mailbox.sendID(for: fresh)), to: data.contacts[i])
    }

    /// A message from device `d` of contact `i` came on `mailbox`. On the one read now, after a move: once every device of
    /// theirs has written there, the mailboxes before it are kept only as long as mail can wait.
    private func noteMailboxHeard(_ mailbox: Data, contact i: Int, device d: Int) {
        let c = data.contacts[i]
        guard mailbox == c.receiveKey, let formers = c.formerMailboxes, formers.contains(where: { $0.until == nil }) else { return }
        let id = c.devices[d].id
        var heard = c.movedHeard ?? []
        if !id.isEmpty, !heard.contains(id) { heard.append(id) }
        data.contacts[i].movedHeard = heard
        guard awaitedOnNewMailbox(contact: i).isEmpty else { return }
        settleMailboxMove(contact: i)
    }

    /// How long after a move a device of theirs not yet heard on the new mailbox is told about it again, and again after
    /// as long each time: the first `Payload.mailbox` can be lost (sealed to a session they had already replaced, say).
    static let mailboxRetell: TimeInterval = 3 * 86_400

    /// The ids of contact `i`'s devices still to be heard from on the mailbox read now before the ones before it are let
    /// go of. Not a device left out of sending (`isDormant`: silent a month while another of theirs talks): it was never
    /// told of the move, and waiting for it would stop this friend's mailbox from ever moving again. If it comes back
    /// within 30 days of that it still finds the old mailbox read; later than that, what it sends there is lost, as is
    /// anything it was sent while it was left out.
    func awaitedOnNewMailbox(contact i: Int) -> [Data] {
        let heard = data.contacts[i].movedHeard ?? []
        let counted = data.contacts[i].devices.indices.filter { !data.contacts[i].devices[$0].id.isEmpty && !isDormant(contact: i, device: $0) }
        // Nobody left to count (no device with an id) is not "everyone heard": the mailboxes before are kept.
        guard !counted.isEmpty else { return [Data()] }
        return counted.map { data.contacts[i].devices[$0].id }.filter { !heard.contains($0) }
    }

    /// Every device that counts has written to the mailbox read now: those before it are read only as long as mail can wait.
    private func settleMailboxMove(contact i: Int, now: Date = Date()) {
        let until = now.addingTimeInterval(Self.formerMailboxLife)
        data.contacts[i].formerMailboxes = data.contacts[i].formerMailboxes?.map { FormerMailbox(key: $0.key, until: $0.until ?? until) }
    }

    /// Keeps a move from being stuck (`tendMailboxes` moves no further while a mailbox before still waits for every device
    /// of theirs): one waiting only on devices that have gone dormant since is settled, and a device not heard on the new
    /// mailbox `mailboxRetell` after the move is told it again. Part of the upkeep, next to `tendMailboxes`.
    func tendMailboxMoves(now: Date = Date()) {
        var changed = false
        for i in data.contacts.indices {
            guard let formers = data.contacts[i].formerMailboxes, formers.contains(where: { $0.until == nil }),
                  let key = data.contacts[i].receiveKey else { continue }
            let awaited = awaitedOnNewMailbox(contact: i)
            if awaited.isEmpty {
                settleMailboxMove(contact: i, now: now)
                changed = true
                continue
            }
            let last = ([data.contacts[i].mailboxSince] + formers.filter { $0.until == nil }.map(\.retold)).compactMap { $0 }.max()
            guard let last, now.timeIntervalSince(last) >= Self.mailboxRetell else { continue }
            let retell = Payload.mailbox(sendID: Mailbox.sendID(for: key))
            for d in data.contacts[i].devices.indices where awaited.contains(data.contacts[i].devices[d].id) {
                // Only the newest word of a move is any use: one still waiting to go is replaced, not doubled.
                data.contacts[i].devices[d].pending.removeAll { if case .mailbox = $0.payload { return true } else { return false } }
                data.contacts[i].devices[d].pending.append(PendingPayload(payload: retell))
            }
            data.contacts[i].formerMailboxes = formers.map {
                var former = $0
                if former.until == nil { former.retold = now }
                return former
            }
            sendPending(contact: i)
            changed = true
        }
        if changed { save() }
    }

    /// Spends what's due of `blobSpends`, each token on a connection of its own, its uses a few seconds apart. One whose
    /// file has expired is dropped: the relay has forgotten it anyway.
    private func tendBlobSpends() {
        let now = Date()
        if data.blobSpends.contains(where: { $0.expires < now }) { data.blobSpends.removeAll { $0.expires < now } }
        let due = data.blobSpends.filter { $0.due <= now && !blobSpending.contains($0.token) }
        for spend in due {
            guard let relay = blobClient() else { return }
            blobSpending.insert(spend.token)
            let shaping = trafficShaping
            Task { [weak self] in
                defer { RelayClient.retire(lane: relay.lane) }
                var spent = 0
                for _ in 0..<spend.uses {
                    guard (try? await relay.blobDone(spend.id, token: spend.token)) != nil else { break }
                    spent += 1
                    if shaping { try? await Task.sleep(for: .seconds(Double.random(in: 1...6))) }
                }
                guard let self else { return }
                self.blobSpending.remove(spend.token)
                guard let i = self.data.blobSpends.firstIndex(where: { $0.token == spend.token && $0.id == spend.id }) else { return }
                if spent >= self.data.blobSpends[i].uses {
                    self.data.blobSpends.remove(at: i)
                } else {
                    // Tried again later for what's left.
                    self.data.blobSpends[i].uses -= spent
                    self.data.blobSpends[i].due = Date().addingTimeInterval(shaping ? .random(in: 300...1800) : 0)
                }
                self.save()
            }
        }
    }
    /// Tokens being spent right now. Memory only.
    @ObservationIgnored private var blobSpending: Set<Data> = []

    /// A connection for one file transfer (or one erase, or one token), used for nothing else (`Lanes.once`): the relay
    /// can't link two files, or a file and a persona's mail, by the circuit they came on. Let go of when done
    /// (`RelayClient.retire(lane:)`).
    private func blobClient() -> RelayClient? { client(nil, lane: Lanes.once("blob")) }

    /// Tells the relay this phone has the whole file, so it can be erased once everyone has it. Tried a few times.
    private func spendToken(of a: Attachment) {
        guard let token = a.token, let relay = blobClient() else { return }
        Task.detached {
            defer { RelayClient.retire(lane: relay.lane) }
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
        if let at = mediaMessage(id, persona: .some(persona)), data.conversations[at.convo].persona == persona,
           !Self.isPending(data.conversations[at.convo].messages[at.message]) { return }
        guard let relay = blobClient() else { return }
        clipFetching.insert(key)
        clipActivity[key] = Date()
        // Not the moment the pointer arrives: a download straight after a fetch would pair this phone's mailbox with the
        // file, and with whoever uploaded it, on the relay.
        let wait = trafficShaping ? Double.random(in: Self.blobFetchDelay) : 0
        Task { [weak self] in
            defer { RelayClient.retire(lane: relay.lane) }
            try? await Task.sleep(for: .seconds(wait))
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
        if let at = mediaMessage(id, persona: .some(persona)) {
            let message = data.conversations[at.convo].messages[at.message]
            let theirs = message.sender == author
            let mine = message.isMine && contact(author, in: persona)?.isSelf == true
            guard theirs || mine, data.conversations[at.convo].persona == persona, fillMessage(at, with: clip) else { return false }
            data.clipParts[key.stored] = nil
            clipActivity[key] = nil
            clipAsks[key] = nil
            save()
            return true
        }
        guard let i = data.stories.firstIndex(where: { $0.id == id && $0.author == author && $0.persona == persona }),
              fillStory(i, with: clip) else { return false }
        data.clipParts[key.stored] = nil
        clipActivity[key] = nil
        clipAsks[key] = nil
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
    /// A picture goes without its hidden details (where it was taken, the camera, when), and any file goes under a
    /// neutral name ("photo.jpg", "document.pdf") unless `keepName` (see `FileScrub`).
    func sendFile(_ url: URL, keepName: Bool = false, replyTo: Message? = nil, in id: Conversation.ID) {
        guard let i = index(of: id), canPost(in: data.conversations[i]) else { return }
        let lifetime = data.conversations[i].kind == .direct ? Self.chatFileLife : 7 * 86_400
        Task { [weak self] in
            do {
                let prepared = try await Task.detached { try BlobTransfer.prepareForSending(url, keepName: keepName, lifetime: lifetime) }.value
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
        let reply = replyTo.map { ReplyRef(id: $0.id, author: $0.sender, snippet: Self.snippet(of: $0), picture: Self.quotePicture(imageData(for: $0))) }
        var message = Message(sender: "me", text: "", date: now, expiresAt: convo.disappearAfter.map { now.addingTimeInterval($0) }, reply: reply)
        message.attachment = a
        message.noForward = noForwardFlag
        withAnimation(.snappy(duration: 0.4)) { data.conversations[i].messages.append(message) }
        fileProgress[message.id] = 0
        fileFailed[message.id] = nil
        save()
        startUpload(prepared, message: message.id, in: id)
    }

    /// (Re)starts an upload for a message of yours whose file is still where it was.
    private func startUpload(_ prepared: BlobTransfer.Prepared, message messageID: UUID, in id: Conversation.ID) {
        guard let client = blobClient() else { fileFailed[messageID] = "No connection."; return }
        fileFailed[messageID] = nil
        fileTasks[messageID]?.cancel()
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.fileProgress[messageID] = value }
        }
        fileTasks[messageID] = Task { [weak self] in
            defer { RelayClient.retire(lane: client.lane) }
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
                               reply: message.reply.map { ReplyRef(id: $0.id, author: $0.author == "me" ? (myFingerprint(in: convo) ?? "") : $0.author,
                                                                   snippet: $0.snippet, picture: $0.picture) },
                               preview: nil, attachment: a, noForward: message.noForward)
        // A shared group gets one pointer, without tokens: the file stays until it's deleted or runs out.
        if postIfShared(.message(wire), in: id, message: message.id) { save(); return }
        let recipients = audience(convo)
        if recipients.isEmpty { setStatus(.sent, for: [message.id]); save(); return }
        // The file is erased from the relay once everyone it goes to has it: each person gets a pointer with a token
        // of their own.
        Task { [weak self] in
            guard let self else { return }
            let tokens = await self.registerReaders(for: recipients, of: a)
            await MainActor.run {
                for member in recipients {
                    var mine = wire
                    mine.attachment?.token = tokens?[Self.personKey(member)]
                    self.enqueue(.message(mine), to: member, message: message.id)
                }
                self.save()
            }
        }
    }

    /// Fetches a file into memory and opens it there. Nothing is written to disk. The caller shows it, or saves it to
    /// Files if the person asks.
    func openFile(of message: Message) async throws -> Data {
        guard let a = message.attachment else { throw BlobError.gone }
        // Opened when the person asks, so not tied to when its message arrived; on a connection of its own all the same.
        guard let client = blobClient() else { throw BlobError.gone }
        defer { RelayClient.retire(lane: client.lane) }
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
        guard isPrimary, !leavingForAnotherDevice else { return }
        var wipes = data.blobWipes
        for convo in data.conversations {
            for m in convo.messages where m.isMine { if let a = m.attachment { wipes.append(BlobWipe(id: a.id, secret: a.secret, expires: a.expires)) } }
        }
        for story in data.stories where story.author == "me" {
            if let a = story.clipBlob { wipes.append(BlobWipe(id: a.id, secret: a.secret, expires: a.expires)) }
        }
        // All at once, so the wipe stays instant, but each on a connection of its own, so the relay isn't handed every
        // file of the account (every persona's) together in its last moments.
        guard !wipes.isEmpty else { return }
        for wipe in wipes {
            guard let relay = blobClient() else { return }
            Task.detached {
                _ = try? await relay.blobDelete(wipe.id, secret: wipe.secret)
                RelayClient.retire(lane: relay.lane)
            }
        }
    }

    /// Works through the files waiting to be erased on the relay.
    @discardableResult
    func runBlobWipes() -> Task<Void, Never> {
        let now = RelayClock.now
        data.blobWipes.removeAll { $0.expires < now.addingTimeInterval(-86_400) }
        guard !data.blobWipes.isEmpty, reachable(nil) != nil else { return Task {} }
        let list = data.blobWipes
        return Task { [weak self] in
            for wipe in list {
                // Each on a connection of its own, as it was uploaded.
                guard let client = await self?.blobClient() else { return }
                defer { RelayClient.retire(lane: client.lane) }
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
    func sendVideo(_ clip: Data, poster: Data?, seconds: Double, caption: String = "", replyTo: Message? = nil, forwarded: Bool = false,
                   in id: Conversation.ID) {
        guard !clip.isEmpty, clip.count <= ChatVideo.maxBytes + 500_000, let i = index(of: id) else { return }
        let convo = data.conversations[i]
        guard canPost(in: convo) else { return }
        let now = Date()
        let words = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = replyTo.map { ReplyRef(id: $0.id, author: $0.sender, snippet: Self.snippet(of: $0), picture: Self.quotePicture(imageData(for: $0))) }
        var message = Message(sender: "me", text: words, image: poster, date: now,
                              expiresAt: convo.disappearAfter.map { now.addingTimeInterval($0) }, reply: reply)
        message.video = clip
        message.clipSeconds = seconds
        message.noForward = noForwardFlag
        message.forwarded = forwarded ? true : nil
        withAnimation(.snappy(duration: 0.4)) { data.conversations[i].messages.append(message) }
        var wire = WireMessage(id: message.id, conversation: sharedID(convo), kind: convo.kind == .broadcast ? .direct : convo.kind,
                               text: words, image: poster, voice: nil, date: RelayClock.relay(now), expiresIn: convo.disappearAfter,
                               reply: reply.map { ReplyRef(id: $0.id, author: $0.author == "me" ? (myFingerprint(in: convo) ?? "") : $0.author,
                                                           snippet: $0.snippet, picture: $0.picture) },
                               preview: nil, clip: ClipInfo(seconds: seconds))
        wire.noForward = message.noForward
        wire.forwarded = message.forwarded
        if postIfShared(.message(wire), in: id, message: message.id) {
            sendSharedClip(clip, id: message.id, in: id)
            lastTypingSent[id] = nil
            save()
            return
        }
        let recipients = audience(convo)
        for member in recipients {
            enqueue(.message(wire), to: member, message: message.id)
            deliverClip(clip, id: message.id, to: member, known: nil)
        }
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

    /// The message a clip, photo or voice note that travels on its own belongs to: a chat video, or a message with a
    /// photo or voice note. Where it is.
    private func mediaMessage(_ id: UUID, persona: UUID?? = nil) -> (convo: Int, message: Int)? {
        // One device can hold the same group message twice (two personas in one group): the persona says which.
        for c in data.conversations.indices where persona.map({ data.conversations[c].persona == $0 }) ?? true {
            if let m = data.conversations[c].messages.lastIndex(where: {
                $0.id == id && ($0.isVideo || $0.awaiting != nil || $0.image != nil || $0.voice != nil)
            }) { return (c, m) }
        }
        return nil
    }

    /// A message whose video, photo or voice note hasn't arrived yet.
    static func isPending(_ message: Message) -> Bool {
        message.video?.isEmpty == true || message.awaiting != nil
    }

    /// The bytes of yours that someone can ask for again: a video's clip, a photo, a voice note's sound.
    private static func sentMedia(_ message: Message) -> (bytes: Data, kind: Attachment.Kind)? {
        if let clip = message.video { return clip.isEmpty ? nil : (clip, .video) }
        if let image = message.image, message.voice == nil { return (image, .photo) }
        if let voice = message.voice, message.image == nil, !voice.audio.isEmpty { return (voice.audio, .voice) }
        return nil
    }

    /// What is stored right now, counted from the data rather than trusted from an old total, so deletions of
    /// messages, stories or whole chats are reflected the moment the next item is considered.
    private func receivedMediaNow() -> Int {
        var total = 0
        for convo in data.conversations {
            for message in convo.messages where !message.isMine && !message.isSystem {
                total += Self.mediaBytes(message)
            }
        }
        for story in data.stories where story.author != "me" {
            total += Self.mediaBytes(story)
        }
        return total
    }

    // MARK: Sealed media pool

    @ObservationIgnored private static let mediaCache = NSCache<NSString, NSData>()

    private func allMediaNames() -> Set<String> {
        // Items sealed for a message that has not been appended yet are still real, not fillers.
        pendingMediaNames.union(mediaNamesInData())
    }

    /// The pool files the account's messages and stories name.
    private func mediaNamesInData() -> Set<String> {
        var names: Set<String> = []
        for convo in data.conversations {
            for message in convo.messages {
                if let ref = message.imageFile { names.insert(ref.name) }
                if let ref = message.videoFile { names.insert(ref.name) }
                if let ref = message.voice?.audioFile { names.insert(ref.name) }
            }
        }
        for story in data.stories {
            if let ref = story.mediaFile { names.insert(ref.name) }
        }
        return names
    }

    private func mediaPool() -> MediaPool {
        var sizes: [Int] = []
        for convo in data.conversations {
            for message in convo.messages {
                for ref in [message.imageFile, message.videoFile, message.voice?.audioFile].compactMap({ $0 }) {
                    sizes.append(MediaPool.sealedSize(ofPlain: ref.size))
                }
            }
        }
        for story in data.stories { if let ref = story.mediaFile { sizes.append(MediaPool.sealedSize(ofPlain: ref.size)) } }
        return MediaPool(directory: vault.directory, realNames: allMediaNames(), ownFillers: Set(data.mediaFillers ?? []),
                         realSizes: sizes)
    }

    /// Every way a received message or story can go (unsent, expired, evicted, a contact or persona removed, a story
    /// replaced) ends here at the next save: a file the account's data named before and doesn't now is overwritten and
    /// kept as this account's filler, so no real media is left behind unclaimed until Burn. Runs on the main actor
    /// with the change that dropped it, before the data is written, so a sealed-but-not-yet-added item can't be caught.
    private func releaseDroppedMedia(account: String) {
        let now = mediaNamesInData()
        let pending = pendingMediaNames
        // A file that couldn't be overwritten (an iPhone locked, say) stays tracked and is tried again next save.
        var failed: Set<String> = []
        defer {
            trackedMedia = (account, now.union(failed))
            pendingMediaNames = []
        }
        guard let tracked = trackedMedia, tracked.account == account else { return }
        let own = Set(data.mediaFillers ?? [])
        let dropped = tracked.names.union(pending).subtracting(now).subtracting(own)
        guard !dropped.isEmpty else { return }
        let pool = mediaPool()
        for name in dropped {
            Self.mediaCache.removeObject(forKey: name as NSString)
            do { try pool.release(name) } catch { failed.insert(name) }
        }
        keepFillers(of: pool)
    }

    /// Keeps the filler files this account made, so it can reuse them and nothing else (see `MediaPool`).
    private func keepFillers(of pool: MediaPool) {
        let fillers = pool.ownFillers.sorted()
        data.mediaFillers = fillers.isEmpty ? nil : fillers
    }

    private func loadMedia(_ ref: MediaFileRef?) -> Data? {
        guard let ref else { return nil }
        let key = ref.name as NSString
        if let hit = Self.mediaCache.object(forKey: key) { return hit as Data }
        guard let plain = try? mediaPool().load(ref) else { return nil }
        Self.mediaCache.setObject(plain as NSData, forKey: key, cost: plain.count)
        return plain
    }

    private func storeReceivedMedia(_ plain: Data) -> MediaFileRef? {
        guard !plain.isEmpty else { return nil }
        let pool = mediaPool()
        guard let ref = try? pool.store(plain, growLater: true) else { return nil }
        keepFillers(of: pool)
        if pool.wantsGrowth { growMediaSoon(after: ref) }
        pendingMediaNames.insert(ref.name)
        Self.mediaCache.setObject(plain as NSData, forKey: ref.name as NSString, cost: plain.count)
        return ref
    }

    /// A media pool grown in the background: anyone can send a photo, and doubling a big pool on the main thread froze
    /// the app (and on iPhone risked it being stopped). The new filler is this account's once it's made, if the account
    /// is still the one open; one wiped meanwhile stops the growth (`MediaPool.grow`).
    @ObservationIgnored private var growingMedia = false
    private func growMediaSoon(after stored: MediaFileRef) {
        guard !growingMedia, let identity else { return }
        growingMedia = true
        let pool = mediaPool()
        let directory = pool.directory, real = pool.realNames.union([stored.name]), own = pool.ownFillers
        let sizes = pool.realSizes, account = identity.fingerprint
        // Counted now, not when the task gets to run: a Burn in between must stop it.
        let wipes = pool.wipes
        Task.detached(priority: .utility) { [weak self] in
            let worker = MediaPool(directory: directory, realNames: real, ownFillers: own, realSizes: sizes)
            let made = (try? worker.topUp(since: wipes)) ?? []
            await MainActor.run {
                guard let self else { return }
                self.growingMedia = false
                guard !made.isEmpty, self.phase == .unlocked, self.identity?.fingerprint == account else { return }
                self.data.mediaFillers = Set(self.data.mediaFillers ?? []).union(made).sorted()
                self.save()
            }
        }
    }

    private func deleteStoredMedia(_ ref: MediaFileRef?) {
        guard let ref else { return }
        pendingMediaNames.remove(ref.name)
        Self.mediaCache.removeObject(forKey: ref.name as NSString)
        let pool = mediaPool()
        try? pool.delete(ref)
        keepFillers(of: pool)
    }

    private func deleteStoredMedia(in messages: [Message]) {
        for message in messages {
            deleteStoredMedia(message.imageFile)
            deleteStoredMedia(message.videoFile)
            deleteStoredMedia(message.voice?.audioFile)
        }
    }

    private func deleteStoredMedia(in story: Story) {
        deleteStoredMedia(story.mediaFile)
    }

    /// Moves received media already inside an old vault into the sealed pool. All of it goes, or none: the candidate
    /// copy is assigned only after every item is sealed and written, so a failure leaves the old inline data intact.
    /// If the app is killed partway, the vault still holds the inline media and the files already written are fillers.
    func migrateInlineMedia() {
        var candidate = data
        // One pool for the whole run, so the filler it makes or reuses is counted once.
        let pool = mediaPool()
        var changed = false
        var sealedNow: [MediaFileRef] = []
        func seal(_ bytes: Data) -> MediaFileRef? {
            guard !bytes.isEmpty else { return nil }
            guard let ref = try? pool.store(bytes) else { return nil }
            sealedNow.append(ref)
            Self.mediaCache.setObject(bytes as NSData, forKey: ref.name as NSString, cost: bytes.count)
            return ref
        }
        // A failure partway keeps the old inline data; what was written this run is wiped back into this account's
        // filler (and the filler it grew is kept as its own), so nothing written here is left unclaimed.
        func giveUp() {
            for ref in sealedNow {
                Self.mediaCache.removeObject(forKey: ref.name as NSString)
                try? pool.delete(ref)
            }
            if Set(data.mediaFillers ?? []) != pool.ownFillers {
                keepFillers(of: pool)
                save()
            }
        }
        for ci in candidate.conversations.indices {
            for mi in candidate.conversations[ci].messages.indices {
                var message = candidate.conversations[ci].messages[mi]
                guard !message.isMine, !message.isSystem else { continue }
                if let image = message.image, !image.isEmpty, message.imageFile == nil {
                    guard let ref = seal(image) else { return giveUp() }
                    message.image = nil
                    message.imageFile = ref
                    changed = true
                }
                if let video = message.video, !video.isEmpty, message.videoFile == nil {
                    guard let ref = seal(video) else { return giveUp() }
                    message.video = nil
                    message.videoFile = ref
                    changed = true
                }
                if let voice = message.voice, !voice.audio.isEmpty, voice.audioFile == nil {
                    guard let ref = seal(voice.audio) else { return giveUp() }
                    message.voice?.audio = Data()
                    message.voice?.audioFile = ref
                    changed = true
                }
                candidate.conversations[ci].messages[mi] = message
            }
        }
        for si in candidate.stories.indices {
            let story = candidate.stories[si]
            guard story.author != "me", story.mediaFile == nil else { continue }
            guard Self.mediaBytes(story.style) > 0 else { continue }
            switch story.style {
            case let .image(data, caption):
                guard let ref = seal(data) else { return giveUp() }
                candidate.stories[si].style = .image(Data(), caption: caption)
                candidate.stories[si].mediaFile = ref
                changed = true
            case let .video(data, caption):
                guard let ref = seal(data) else { return giveUp() }
                candidate.stories[si].style = .video(Data(), caption: caption)
                candidate.stories[si].mediaFile = ref
                changed = true
            case .text:
                break
            }
        }
        guard changed else { return }
        data = candidate
        keepFillers(of: pool)
        rebuildReceivedMedia()
        save()
    }

    /// The received photo's bytes, inline (old vaults) or from the sealed pool.
    func imageData(for message: Message) -> Data? {
        if let image = message.image, !image.isEmpty { return image }
        return loadMedia(message.imageFile)
    }

    func videoData(for message: Message) -> Data? {
        if let video = message.video, !video.isEmpty { return video }
        return loadMedia(message.videoFile)
    }

    func voiceAudio(for message: Message) -> Data? {
        if let audio = message.voice?.audio, !audio.isEmpty { return audio }
        return loadMedia(message.voice?.audioFile)
    }

    func storyData(for story: Story) -> Data? {
        if case let .image(data, _) = story.style, !data.isEmpty { return data }
        if case let .video(data, _) = story.style, !data.isEmpty { return data }
        return loadMedia(story.mediaFile)
    }

    struct MediaUsage: Identifiable {
        var id: String
        var name: String
        var bytes: Int
    }

    /// What received media is stored, by chat or by a contact's stories, biggest first.
    func mediaUsage() -> [MediaUsage] {
        var found: [String: (name: String, bytes: Int)] = [:]
        for convo in data.conversations {
            let bytes = convo.messages.reduce(0) { $0 + ($1.isMine || $1.isSystem ? 0 : Self.mediaBytes($1)) }
            guard bytes > 0 else { continue }
            let name: String
            switch convo.kind {
            case .direct: name = convo.members.first.map { displayName($0) } ?? convo.title
            case .group, .channel, .broadcast: name = convo.title
            }
            found["c:\(convo.id.uuidString)"] = (name, bytes)
        }
        for story in data.stories where story.author != "me" {
            let bytes = Self.mediaBytes(story)
            guard bytes > 0 else { continue }
            let key = "s:\(story.author)|\(story.persona?.uuidString ?? "main")"
            let name = "\(displayName(story.author)) · Stories"
            found[key] = (name, (found[key]?.bytes ?? 0) + bytes)
        }
        return found.map { MediaUsage(id: $0.key, name: $0.value.name, bytes: $0.value.bytes) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// Removes received media from one chat or one contact's stories. Text, times and reactions stay.
    func clearMedia(scopeID: String) {
        if scopeID.hasPrefix("c:"), let id = UUID(uuidString: String(scopeID.dropFirst(2))),
           let ci = index(of: id) {
            for mi in data.conversations[ci].messages.indices {
                var message = data.conversations[ci].messages[mi]
                guard !message.isMine, !message.isSystem else { continue }
                let hadMedia = Self.mediaBytes(message) > 0 || message.awaiting != nil
                deleteStoredMedia(message.imageFile)
                deleteStoredMedia(message.videoFile)
                deleteStoredMedia(message.voice?.audioFile)
                message.image = nil
                message.imageFile = nil
                message.video = nil
                message.videoFile = nil
                message.voice?.audio = Data()
                message.voice?.audioFile = nil
                message.preview?.image = nil
                message.reply?.picture = nil
                if hadMedia {
                    message.mediaDropped = true
                    message.mediaGone = true
                }
                message.awaiting = nil
                data.conversations[ci].messages[mi] = message
            }
        } else if scopeID.hasPrefix("s:"), let bar = scopeID.firstIndex(of: "|") {
            let author = String(scopeID[scopeID.index(scopeID.startIndex, offsetBy: 2)..<bar])
            let personaText = String(scopeID[scopeID.index(after: bar)...])
            let persona = personaText == "main" ? nil : UUID(uuidString: personaText)
            for si in data.stories.indices where data.stories[si].author == author && data.stories[si].persona == persona {
                deleteStoredMedia(data.stories[si].mediaFile)
                data.stories[si].mediaFile = nil
                data.stories[si].style = Self.withoutMedia(data.stories[si].style)
                data.stories[si].mediaDropped = true
                data.stories[si].mediaGone = true
            }
        }
        rebuildReceivedMedia()
        save()
    }

    /// Rebuilds the memory-only count of received media from what is stored. Own and synced items never count.
    func rebuildReceivedMedia() {
        receivedMediaBytes = receivedMediaNow()
    }

    /// Whether another item fits. At the cap, the contact or group holding the most loses its oldest media first.
    /// Counts afresh, so media removed by any path is no longer counted against it.
    private func fitsReceivedMedia(_ bytes: Int, force: Bool = false) -> Bool {
        receivedMediaBytes = receivedMediaNow()
        let limit = force ? (mediaHardLimitForTests ?? Self.receivedMediaHardLimit)
                          : (mediaSoftLimitForTests ?? Self.receivedMediaSoftLimit)
        if evictsForTests, receivedMediaBytes + bytes > limit {
            makeRoomForReceivedMedia(bytes, limit: limit)
            receivedMediaBytes = receivedMediaNow()
        }
        return receivedMediaBytes + bytes <= limit
    }

    /// Removes the oldest media from the conversation or story scope holding the most until the item fits.
    private func makeRoomForReceivedMedia(_ incoming: Int, limit: Int) {
        while receivedMediaNow() + incoming > limit {
            guard evictOldestFromBiggestScope() else { break }
        }
    }

    private func evictOldestFromBiggestScope() -> Bool {
        struct Item { var bytes: Int; var date: Date; var ci: Int?; var mi: Int?; var si: Int? }
        var scopes: [String: [Item]] = [:]
        for ci in data.conversations.indices {
            for mi in data.conversations[ci].messages.indices {
                let message = data.conversations[ci].messages[mi]
                guard !message.isMine, !message.isSystem else { continue }
                let bytes = Self.mediaBytes(message)
                guard bytes > 0 else { continue }
                scopes["c:\(data.conversations[ci].id.uuidString)", default: []]
                    .append(Item(bytes: bytes, date: message.date, ci: ci, mi: mi, si: nil))
            }
        }
        for si in data.stories.indices {
            let story = data.stories[si]
            guard story.author != "me" else { continue }
            let bytes = Self.mediaBytes(story)
            guard bytes > 0 else { continue }
            scopes["s:\(story.author)|\(story.persona?.uuidString ?? "main")", default: []]
                .append(Item(bytes: bytes, date: story.date, ci: nil, mi: nil, si: si))
        }
        guard let biggest = scopes.max(by: { a, b in
            a.value.reduce(0) { $0 + $1.bytes } < b.value.reduce(0) { $0 + $1.bytes }
        }), let oldest = biggest.value.min(by: { $0.date < $1.date }) else { return false }

        if let ci = oldest.ci, let mi = oldest.mi {
            var message = data.conversations[ci].messages[mi]
            deleteStoredMedia(message.imageFile)
            deleteStoredMedia(message.videoFile)
            deleteStoredMedia(message.voice?.audioFile)
            message.image = nil
            message.imageFile = nil
            message.video = nil
            message.videoFile = nil
            message.voice?.audio = Data()
            message.voice?.audioFile = nil
            message.preview?.image = nil
            message.reply?.picture = nil
            message.mediaDropped = true
            message.mediaGone = true
            data.conversations[ci].messages[mi] = message
        } else if let si = oldest.si {
            var story = data.stories[si]
            deleteStoredMedia(story.mediaFile)
            story.mediaFile = nil
            story.style = Self.withoutMedia(story.style)
            story.mediaDropped = true
            story.mediaGone = true
            data.stories[si] = story
        } else {
            return false
        }

        if !mediaLimitNoted {
            mediaLimitNoted = true
            storageNotice = "Storage: removed old media to stay within the limit."
            if let ci = oldest.ci {
                data.conversations[ci].messages.append(Message(sender: "system", text: storageNotice!, date: Date()))
            }
        }
        return true
    }

    /// Puts a video, photo or voice note that came on its own into the message waiting for it.
    private func fillMessage(_ at: (convo: Int, message: Int), with bytes: Data) -> Bool {
        var message = data.conversations[at.convo].messages[at.message]
        guard !bytes.isEmpty else { return false }
        let kind: Attachment.Kind
        if message.video?.isEmpty == true {
            kind = .video
        } else if let awaiting = message.awaiting {
            kind = awaiting
        } else {
            return false
        }
        guard kind == .video || kind == .photo || kind == .voice else { return false }
        if kind == .voice, message.voice == nil { return false }
        if kind == .video {
            guard bytes.count <= ChatVideo.maxBytes + 500_000 else { return false }
        } else {
            guard bytes.count <= Self.maxMediaBytes else { return false }
        }
        if kind == .photo, PlatformImage.checked(bytes) == nil { return false }

        let forced = mediaRequested.contains(message.id)
        guard fitsReceivedMedia(bytes.count, force: forced) else {
            mediaRequested.remove(message.id)
            message.mediaDropped = true
            message.mediaGone = forced ? true : nil
            message.awaiting = nil
            if kind == .video { message.video = nil }
            withAnimation(.snappy) { data.conversations[at.convo].messages[at.message] = message }
            clipActivity[ClipKey(message.id, data.conversations[at.convo].persona)] = nil
            return true
        }

        if let ref = storeReceivedMedia(bytes) {
            switch kind {
            case .video:
                message.video = nil
                message.videoFile = ref
            case .photo:
                message.image = nil
                message.imageFile = ref
                message.awaiting = nil
            case .voice:
                message.voice?.audio = Data()
                message.voice?.audioFile = ref
                message.awaiting = nil
            default:
                return false
            }
        } else {
            switch kind {
            case .video:
                message.video = bytes
            case .photo:
                message.image = bytes
                message.awaiting = nil
            case .voice:
                message.voice?.audio = bytes
                message.awaiting = nil
            default:
                return false
            }
        }
        message.mediaDropped = nil
        message.mediaGone = nil
        mediaRequested.remove(message.id)
        withAnimation(.snappy) { data.conversations[at.convo].messages[at.message] = message }
        receivedMediaBytes = receivedMediaNow()
        return true
    }

    /// Puts a clip or photo that came on its own into the story waiting for it.
    private func fillStory(_ i: Int, with bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return false }
        let story = data.stories[i]
        let forced = mediaRequested.contains(story.id)
        switch story.style {
        case let .video(have, caption) where have.isEmpty:
            guard bytes.count <= Self.maxMediaBytes else { return false }
            guard fitsReceivedMedia(bytes.count, force: forced) else {
                mediaRequested.remove(story.id)
                withAnimation(.snappy) {
                    data.stories[i].style = .video(Data(), caption: caption)
                    data.stories[i].mediaDropped = true
                    data.stories[i].mediaGone = forced ? true : nil
                }
                clipActivity[ClipKey(story.id, story.persona)] = nil
                return true
            }
            if let ref = storeReceivedMedia(bytes) {
                withAnimation(.snappy) {
                    data.stories[i].style = .video(Data(), caption: caption)
                    data.stories[i].mediaFile = ref
                    data.stories[i].mediaDropped = nil
                    data.stories[i].mediaGone = nil
                }
            } else {
                withAnimation(.snappy) {
                    data.stories[i].style = .video(bytes, caption: caption)
                    data.stories[i].mediaDropped = nil
                    data.stories[i].mediaGone = nil
                }
            }
        case let .image(have, caption) where have.isEmpty:
            guard bytes.count <= Self.maxMediaBytes, PlatformImage.checked(bytes) != nil else { return false }
            guard fitsReceivedMedia(bytes.count, force: forced) else {
                mediaRequested.remove(story.id)
                withAnimation(.snappy) {
                    data.stories[i].style = .image(Data(), caption: caption)
                    data.stories[i].mediaDropped = true
                    data.stories[i].mediaGone = forced ? true : nil
                }
                clipActivity[ClipKey(story.id, story.persona)] = nil
                return true
            }
            if let ref = storeReceivedMedia(bytes) {
                withAnimation(.snappy) {
                    data.stories[i].style = .image(Data(), caption: caption)
                    data.stories[i].mediaFile = ref
                    data.stories[i].mediaDropped = nil
                    data.stories[i].mediaGone = nil
                }
            } else {
                withAnimation(.snappy) {
                    data.stories[i].style = .image(bytes, caption: caption)
                    data.stories[i].mediaDropped = nil
                    data.stories[i].mediaGone = nil
                }
            }
        default:
            return false
        }
        mediaRequested.remove(story.id)
        receivedMediaBytes = receivedMediaNow()
        return true
    }

    /// Answers a friend's story in your chat with them: a like, or words. It arrives as an ordinary message
    /// quoting the story, so the relay sees nothing new and older builds show it too. False when nothing was sent.
    @discardableResult
    func answerStory(_ story: Story, like: Bool = false, text: String = "") async -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard story.author != "me", like || !words.isEmpty, contact(story.author, in: story.persona) != nil else { return false }
        let picture = await storyPicture(story)
        let convo = startConversation(kind: .direct, title: "", members: [story.author], persona: .some(story.persona))
        let quote = ReplyRef(id: story.id, author: story.author, snippet: Self.snippet(of: story), picture: picture)
        send(like ? "❤️ Liked your story" : words, quote: quote, in: convo.id)
        if like, let i = data.stories.firstIndex(where: { $0.id == story.id && $0.persona == story.persona }) {
            data.stories[i].liked = true
            save()
        }
        return true
    }

    /// A photo shrunk for the quote above a reply to it. Nil when there's no photo, or it can't be made small enough.
    static func quotePicture(_ photo: Data?) -> Data? {
        guard let photo, let small = thumbnail(photo, side: 160), small.count <= ReplyRef.maxPicture,
              PlatformImage(data: small) != nil else { return nil }
        return small
    }

    /// A small picture of a story for the quote above a like or a reply: the photo shrunk, a video's first
    /// frame, or the text card drawn small.
    func storyPicture(_ story: Story) async -> Data? {
        let side: CGFloat = 200
        let image: PlatformImage?
        switch story.style {
        case .image:
            // A story comes from a contact: a tiny file can claim an enormous picture. Cap it before decoding.
            image = storyData(for: story).flatMap { PlatformImage.checked($0) }
        case .video:
            guard let clip = storyData(for: story), !clip.isEmpty else { return nil }
            image = await StoryVideo.poster(of: MemoryClip(clip)).map { PlatformImage.from(cgImage: $0) }
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
        if message.image != nil || message.imageFile != nil { return "Photo" }
        return "Message"
    }

    /// Groups and channels share an id across devices; direct chats and broadcasts don't.
    private func sharedID(_ convo: Conversation) -> UUID? {
        convo.kind == .group || convo.kind == .channel ? convo.wireID : nil
    }

    /// Who receives conversation-level signals (reactions, unsends, timers) one by one: the other person in a direct chat, or
    /// the people on a broadcast list. A group or channel has one mailbox for everyone and sends nothing to its members one by one.
    private func audience(_ convo: Conversation) -> [Contact] {
        guard convo.kind == .direct || convo.kind == .broadcast else { return [] }
        return convo.members.compactMap { contact($0, in: convo.persona) }
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
        if !postIfShared(.unsend(ids: [messageID]), in: id) {
            for member in audience(convo) { enqueue(.unsend(ids: [messageID]), to: member) }
        }
        save()
    }

    /// Tapping the same emoji again removes it.
    func react(_ emoji: String, to messageID: UUID, in id: Conversation.ID) {
        guard let i = index(of: id), let m = data.conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let next: String? = data.conversations[i].messages[m].reactions["me"] == emoji ? nil : emoji
        withAnimation(.snappy) { data.conversations[i].messages[m].reactions["me"] = next }
        let convo = data.conversations[i]
        if convo.kind != .broadcast {
            if !postIfShared(.reaction(message: messageID, emoji: next), in: id) {
                for member in audience(convo) { enqueue(.reaction(message: messageID, emoji: next), to: member) }
            }
        }
        save()
    }

    /// Typing signals are throttled to one every few seconds and never stored.
    func noteTyping(in id: Conversation.ID) {
        guard data.security.typingIndicators, let convo = conversation(id), convo.kind == .direct || convo.kind == .group else { return }
        if let last = lastTypingSent[id], Date().timeIntervalSince(last) < 3 { return }
        lastTypingSent[id] = Date()
        if postIfShared(.typing(conversation: sharedID(convo)), in: id) { return }
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
        for d in data.contacts[i].devices.indices where data.contacts[i].devices[d].session?.canSend == true
            && !isDormant(contact: i, device: d)
            && !(payload.isPassing && !data.contacts[i].isSelf && data.contacts[i].devices[d].unconfirmed == true) {
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
        guard let i = index(of: id), !data.conversations[i].isOldFormat, data.conversations[i].disappearAfter != seconds else { return }
        if data.conversations[i].shared != nil {
            // In a shared group the timer is part of its settings, which only admins change.
            guard data.conversations[i].amAdmin else { return }
            applyTimer(seconds, at: i)
            publishSharedChange(i)
            save()
            return
        }
        applyTimer(seconds, at: i)
        let convo = data.conversations[i]
        if convo.kind == .direct {
            for member in audience(convo) { enqueue(.disappearing(conversation: nil, seconds: seconds), to: member) }
        }
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
            let going = data.conversations[i].messages.filter { ($0.expiresAt ?? .distantFuture) <= now }
            eraseFiles(in: going)
            deleteStoredMedia(in: going)
            withAnimation(.smooth) { data.conversations[i].messages.removeAll { ($0.expiresAt ?? .distantFuture) <= now } }
            clampUnread(i)
            changed = true
        }
        // Stories past their time go from the vault too, not just from view, and so do old removal notes.
        if data.stories.contains(where: { !$0.isLive }) {
            for story in data.stories where !story.isLive && story.author == "me" { dropUnsent(story: story.id) }
            for story in data.stories where !story.isLive { deleteStoredMedia(in: story) }
            eraseClips(of: data.stories.filter { !$0.isLive })
            withAnimation(.smooth) { data.stories.removeAll { !$0.isLive } }
            changed = true
        }
        let stale = now.addingTimeInterval(-3 * 24 * 3600)
        if removedStories.values.contains(where: { $0 < stale }) {
            removedStories = removedStories.filter { $0.value >= stale }
            changed = true
        }
        if changed {
            rebuildReceivedMedia()
            save()
        }
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

    /// Pins, or unpins, several chats at once.
    func setPinned(_ ids: [Conversation.ID], _ on: Bool) {
        withAnimation(.snappy) { for id in ids { if let i = index(of: id) { data.conversations[i].pinned = on } } }
        save()
    }

    func setMuted(_ ids: [Conversation.ID], _ on: Bool) {
        for id in ids { if let i = index(of: id) { data.conversations[i].muted = on } }
        Platform.setBadge(unreadTotal)
        save()
    }

    /// Moves chats to Archived, or back. An archived chat keeps its place in search and comes back to the list with
    /// its next message, unless it's muted.
    func setArchived(_ ids: [Conversation.ID], _ on: Bool) {
        withAnimation(.snappy) { for id in ids { if let i = index(of: id) { data.conversations[i].archived = on } } }
        save()
    }

    func markRead(_ ids: [Conversation.ID]) { for id in ids { markRead(id) } }

    func delete(_ ids: [Conversation.ID]) { for id in ids { delete(id) } }

    /// The active persona's archived chats, newest first.
    var archivedConversations: [Conversation] { sortedConversations.filter(\.archived) }

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
            let signal: Payload = convo.amOwner ? .chatDeleted(conversation: convo.wireID) : .left(conversation: convo.wireID)
            if isFollower(convo) {
                // A follower says nothing in the channel; the staff member who invited them is told over that chat, so
                // they are taken out and the next key isn't sent to them.
                _ = noticeToInviter(.channelLeave(group: convo.wireID), of: convo)
            // The chat is about to go from this device, outbox and all, so what it still has to say is kept apart and sent
            // with retries until it's on the relay (`partingPosts`). A group in the older format has no mailbox to tell: it
            // is only removed from this device.
            } else if convo.shared != nil, let i = index(of: id) {
                post(signal, at: i)
                if let shared = data.conversations[i].shared {
                    let parting = shared.outbox.filter { !$0.ephemeral }.map {
                        PartingPost(post: $0, persona: convo.persona, known: shared.postedTo.contains($0.sendID.hex))
                    }
                    data.partingPosts = Array((data.partingPosts + parting).suffix(Self.partingPostsKept))
                }
            }
        }
        // Its public name goes too (let go of on the relay in the background, tried until it's done).
        dropPublicName(of: id)
        removeLocally(id)
        save()
        if !data.partingPosts.isEmpty { kick() }
        if !data.namesToRelease.isEmpty { Task { await releasePendingNames() } }
    }

    /// How many posts of gone groups are kept waiting at most, and for how long.
    static let partingPostsKept = 200
    static let partingPostsKeepFor: TimeInterval = 7 * 86_400

    /// Posts what deleted or left groups still have to say (`AppData.partingPosts`), oldest first. One that can't go yet
    /// stops the rest until the next pass; past a week they're dropped.
    func flushPartingPosts() async {
        guard !partingFlushing else { return }
        partingFlushing = true
        defer { partingFlushing = false }
        let cutoff = Date().addingTimeInterval(-Self.partingPostsKeepFor)
        if data.partingPosts.contains(where: { $0.post.queued < cutoff }) { data.partingPosts.removeAll { $0.post.queued < cutoff } }
        while let next = data.partingPosts.first {
            // Each on a lane of its own, used once: a group's last word says nothing about the persona's other groups.
            let lane = Lanes.once("parting")
            guard let client = client(nil, lane: lane) else { break }
            defer { RelayClient.retire(lane: lane) }
            let post = next.post
            do {
                do {
                    try await client.depositGroup(post.blob, to: post.sendID, days: post.days, wake: post.wake, prove: !next.known)
                } catch let refused as RelayRefused where refused.status == 429 && next.known {
                    // The mailbox may have run out on the relay (or it lost it): starting it again needs the proof.
                    try await client.depositGroup(post.blob, to: post.sendID, days: post.days, wake: post.wake, prove: true)
                }
            } catch is RelayTooLarge {
                // Never going to fit: dropped.
            } catch {
                break
            }
            data.partingPosts.removeAll { $0.post.id == post.id }
            save()
        }
    }

    private func removeLocally(_ id: Conversation.ID) {
        if let convo = conversation(id) {
            eraseFiles(in: convo.messages)
            deleteStoredMedia(in: convo.messages)
        }
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

    /// This device's copy of a group, for one persona, by the group's own id.
    func groupIndex(_ group: UUID, persona: UUID?) -> Int? {
        data.conversations.firstIndex { $0.wireID == group && $0.persona == persona && $0.kind != .direct }
    }

    /// Where a new copy of a group is kept for a persona: under the group's own id, unless another persona of this
    /// device already has it there.
    func newGroupPlace(_ group: UUID, persona: UUID?) -> (id: UUID, groupID: UUID?) {
        index(of: group) == nil ? (group, nil) : (Conversation.localID(group: group, persona: persona), group)
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
        .story(id: story.id, style: story.style, date: RelayClock.relay(story.date), lasts: story.lifetime, loops: story.loops)
    }

    /// Whether every device of a contact reads framed messages, so a clip can go to them in fewer, fuller pieces.
    private func readsFrames(_ contact: Contact) -> Bool {
        !contact.devices.isEmpty && contact.devices.allSatisfy { $0.readsFrames == true }
    }

    /// A big photo story, to someone whose app takes it on its own: the story without its picture, then a pointer to the
    /// one copy on the relay (or, if that can't be had, the picture in pieces). False when it goes the ordinary way.
    private func sendStoryPhotoApart(_ story: Story, to contact: Contact, withPhoto: Bool, only wanted: [Int]? = nil) -> Bool {
        guard case let .image(photo, caption) = story.style, photo.count > Self.mediaInline, photo.count <= Self.maxMediaBytes,
              readsMediaBlobs(contact) else { return false }
        enqueue(.story(id: story.id, style: .image(Data(), caption: caption), date: RelayClock.relay(story.date),
                       lasts: story.lifetime, loops: story.loops), to: contact)
        if withPhoto {
            deliverClip(photo, id: story.id, to: contact, known: story.clipBlob, lifetime: story.lifetime ?? StoryLifetime.day.rawValue,
                        only: wanted, kind: .photo)
        }
        return true
    }

    /// Sends a story to one contact. A video goes as the story with an empty clip, then (for people who don't
    /// have the clip yet) the clip in pieces that each fit one relay message.
    private func sendStory(_ story: Story, to contact: Contact, withClip: Bool) {
        if sendStoryPhotoApart(story, to: contact, withPhoto: withClip) { return }
        guard case let .video(clip, caption) = story.style else { enqueue(storyPayload(story), to: contact); return }
        enqueue(.story(id: story.id, style: .video(Data(), caption: caption), date: RelayClock.relay(story.date),
                       lasts: story.lifetime, loops: story.loops), to: contact)
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
        if sendStoryPhotoApart(story, to: contact, withPhoto: true, only: wanted) { return }
        guard case let .video(clip, caption) = story.style, !clip.isEmpty else { enqueue(storyPayload(story), to: contact); return }
        enqueue(.story(id: story.id, style: .video(Data(), caption: caption), date: RelayClock.relay(story.date),
                       lasts: story.lifetime, loops: story.loops), to: contact)
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
        for story in data.stories where story.author != "me" && story.isLive && !story.isReady && story.mediaDropped != true {
            stalled.insert(ClipKey(story.id, story.persona))
        }
        // Chat videos whose message has come but whose pieces haven't all.
        stalled.formUnion(clipActivity.keys)
        for key in stalled {
            let id = key.id
            let story = data.stories.first { $0.id == id && $0.persona == key.persona && $0.author != "me" }
            let parts = data.clipParts[key.stored]
            if story == nil, let at = mediaMessage(id, persona: .some(key.persona)), data.conversations[at.convo].persona == key.persona {
                // A chat video, photo or voice note: asked of whoever sent it, in that chat's persona, while it's still unfinished.
                let message = data.conversations[at.convo].messages[at.message]
                guard Self.isPending(message), !message.isMine, message.mediaDropped != true else { clipActivity[key] = nil; continue }
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
                  story?.mediaDropped != true, removedStories["\(author)|\(id)"] == nil else { continue }
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

    /// The user asked for one received item that was not saved. Ask its sender once through the existing resend path;
    /// it is stored only if the hard ceiling has room when it arrives.
    func getMediaAnyway(messageID: UUID, in conversationID: UUID) {
        guard let ci = index(of: conversationID),
              let mi = data.conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        var message = data.conversations[ci].messages[mi]
        guard !message.isMine, !message.isSystem, message.mediaDropped == true else { return }
        guard fitsReceivedMedia(0, force: true),
              let from = contact(message.sender, in: data.conversations[ci].persona) else {
            message.mediaGone = true
            data.conversations[ci].messages[mi] = message
            save()
            return
        }
        let kind: Attachment.Kind
        if message.clipSeconds != nil || message.video != nil {
            kind = .video
        } else if message.voice != nil {
            kind = .voice
        } else {
            kind = .photo
        }
        mediaRequested.insert(message.id)
        switch kind {
        case .video: message.video = Data()
        case .voice: message.awaiting = .voice
        case .photo: message.awaiting = .photo
        default: break
        }
        message.mediaGone = nil
        data.conversations[ci].messages[mi] = message
        enqueue(.storyWant(id: message.id, parts: nil), to: from)
        save()
    }

    /// The same for a story. If it has expired or there is no longer room, the UI says it is no longer available.
    func getStoryAnyway(_ story: Story) {
        guard let i = data.stories.firstIndex(where: { $0.id == story.id && $0.persona == story.persona }) else { return }
        var saved = data.stories[i]
        guard saved.author != "me", saved.mediaDropped == true else { return }
        guard saved.isLive, fitsReceivedMedia(0, force: true),
              let from = contact(saved.author, in: saved.persona) else {
            saved.mediaGone = true
            data.stories[i] = saved
            save()
            return
        }
        mediaRequested.insert(saved.id)
        saved.mediaGone = nil
        data.stories[i] = saved
        enqueue(.storyWant(id: saved.id, parts: nil), to: from)
        save()
    }

    /// The same for a video in a chat: it is in the persona that chat belongs to.
    func clipProgress(ofMessage id: UUID) -> (have: Int, of: Int)? {
        guard let at = mediaMessage(id) else { return nil }
        return clipProgress(of: id, persona: data.conversations[at.convo].persona)
    }

    private func assembleClip(_ id: UUID, persona: UUID?) {
        let key = ClipKey(id, persona)
        guard let pending = data.clipParts[key.stored], pending.isComplete else { return }
        // A video in a chat: from whoever wrote the message (or, for one of your own, from another of your devices).
        if let at = mediaMessage(id, persona: .some(pending.persona)) {
            let message = data.conversations[at.convo].messages[at.message]
            let theirs = message.sender == pending.author
            let mine = message.isMine && contact(pending.author, in: pending.persona)?.isSelf == true
            guard Self.isPending(message), theirs || mine, data.conversations[at.convo].persona == pending.persona else { return }
            let joined = (0..<pending.of).reduce(into: Data()) { $0.append(pending.parts[$1] ?? Data()) }
            data.clipParts[key.stored] = nil
            clipActivity[key] = nil
            clipAsks[key] = nil
            _ = fillMessage(at, with: joined)
            return
        }
        guard let i = data.stories.firstIndex(where: { $0.id == id && $0.author == pending.author && $0.persona == pending.persona }),
              !data.stories[i].isReady else { return }
        let joined = (0..<pending.of).reduce(into: Data()) { $0.append(pending.parts[$1] ?? Data()) }
        data.clipParts[key.stored] = nil
        clipActivity[key] = nil
        clipAsks[key] = nil
        guard fillStory(i, with: joined) else { return }
        acknowledgeStory(id, author: pending.author, persona: pending.persona)
    }

    /// Tells the author a story reached this device whole (a video: with its clip), so their app stops sending it
    /// again.
    private func acknowledgeStory(_ id: UUID, author: String, persona: UUID?) {
        guard let story = data.stories.first(where: { $0.id == id && $0.author == author && $0.persona == persona }) else { return }
        guard story.isReady, let c = contact(author, in: persona), !c.hidden, !c.isSelf else { return }
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

    /// `loops` makes a video story play again from the start when it ends, for you and for everyone who sees it.
    func postStory(_ style: StoryStyle, audience: StoryAudience = .everyone, lifetime: TimeInterval = StoryLifetime.day.rawValue,
                   loops: Bool = false) {
        var story = Story(author: "me", style: style)
        story.persona = activePersona
        story.audience = audience
        story.lifetime = lifetime
        if case .video = style, loops { story.loops = true }
        story.delivery = StoryDelivery()
        data.storyChoices[choiceKey(activePersona)] = StoryChoice(audience: audience, lifetime: lifetime)
        withAnimation(.snappy) { data.stories.insert(story, at: 0) }
        fanOut(story, to: self.audience(of: story).map { ($0, true) })
        trackUpload(of: story.id)
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
    func editStory(_ id: Story.ID, style: StoryStyle, audience: StoryAudience, lifetime: TimeInterval, loops: Bool = false) {
        guard let i = data.stories.firstIndex(where: { $0.id == id && $0.author == "me" }) else { return }
        let before = self.audience(of: data.stories[i])
        if case .video = data.stories[i].style { data.stories[i].loops = loops ? true : nil }
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
        save()
    }

    func deleteStory(_ id: Story.ID) {
        guard let story = data.stories.first(where: { $0.id == id && $0.author == "me" }) else { return }
        eraseClips(of: [story])
        withAnimation(.snappy) { data.stories.removeAll { $0.id == id } }
        dropUnsent(story: id)
        noteRemoved("me|\(id)")
        for c in audience(of: story) { enqueue(.storyRemoved(id: id), to: c) }
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
        // A video's clip can be uploading to the relay while the small story copies have already gone. It is
        // part of the upload, and counting it keeps the progress (and iOS's background permission) alive.
        return waiting + data.outbox.filter { $0.story == id }.count + (clipUploads[id] == nil ? 0 : 1)
    }

    /// A story that's over (its time ran out, or you deleted it) stops going out: the copies still waiting to be
    /// sent, sealed or not, are let go rather than uploaded for nobody to watch. One that's part-way up the wire
    /// finishes; whoever gets it drops it as expired or removed.
    private func dropUnsent(story id: Story.ID) {
        storyBacklog[id] = nil
        noteBacklog(id)
        storyUploadTotal[id] = nil
        // A clip still going up for a story that's over is of no use to anyone.
        clipUploads[id]?.cancel()
        clipUploads[id] = nil
        clipWaiting[id] = nil
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
        guard outboxCopies(of: id) == 0, storyBacklog[id] == nil,
              clipUploads[id] == nil, (clipWaiting[id] ?? []).isEmpty,
              let i = data.stories.firstIndex(where: { $0.id == id }),
              data.stories[i].delivery != nil, data.stories[i].delivery?.uploaded != true else { return }
        data.stories[i].delivery?.uploaded = true
        storyUploadTotal[id] = nil
    }

    /// Whether copies of a story are still waiting to go out. Unlike the progress, this holds after a restart.
    func isUploading(_ id: Story.ID) -> Bool {
        guard let story = data.stories.first(where: { $0.id == id }), story.author == "me",
              story.delivery != nil, story.delivery?.uploaded != true else { return false }
        return outboxCopies(of: id) > 0 || storyBacklog[id] != nil
            || clipUploads[id] != nil || !(clipWaiting[id] ?? []).isEmpty
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
        let live = data.stories.filter { $0.author == author && $0.isLive && $0.persona == activePersona && isFriend(author, $0.persona) }
            .sorted { $0.date < $1.date }
        guard let first = live.firstIndex(where: { !$0.seen }) else { return nil }
        return StoryReel(stories: live, start: first)
    }

    /// Set to play someone's story from anywhere in the app. `MainView` shows it.
    var storyToOpen: StoryReel?

    /// Oldest first, the order they play in.
    var myStories: [Story] { data.stories.filter { $0.author == "me" && $0.isLive && $0.isReady && $0.persona == activePersona }.sorted { $0.date < $1.date } }

    /// Whether stories from someone are shown: only a friend's, never from someone you only share a group with.
    private func isFriend(_ fingerprint: String, _ persona: UUID?) -> Bool {
        contact(fingerprint, in: persona).map { !$0.hidden && !$0.awaitingAcceptance } ?? false
    }

    /// Other people's live stories, newest author first.
    var friendStories: [(author: String, stories: [Story])] {
        // A video still arriving is listed too, shown as loading, so a stalled one doesn't just look missing.
        let live = data.stories.filter { $0.author != "me" && $0.isLive && $0.persona == activePersona && isFriend($0.author, $0.persona) }
        let grouped = Dictionary(grouping: live, by: \.author)
        return grouped.map { ($0.key, $0.value.sorted { $0.date < $1.date }) }
            .sorted { ($0.stories.last?.date ?? .distantPast) > ($1.stories.last?.date ?? .distantPast) }
    }

    // MARK: Personas

    var activePersona: UUID? { data.activePersona }
    private var identityCache: [UUID: Identity] = [:]

    /// The keys for one of your personas. Nil is your main identity.
    /// This device's own keys and their card signed by the account, by persona ("main" for the main identity). Memory only.
    @ObservationIgnored private var deviceKeyCache: [String: (key: DeviceKey, card: DeviceKeyCard)] = [:]

    /// The seed of this device's own keys. A new one where the data file has none, or none this device's Keychain opens
    /// (a file brought from another device, or one restored from the backup): to everyone, that's a new device.
    private func deviceSeed() -> Data? {
        if let sealed = data.deviceKey, let seed = vault.openDeviceSeed(sealed) { return seed }
        let seed = Data.random(32)
        guard let sealed = try? vault.sealDeviceSeed(seed) else { return nil }
        data.deviceKey = sealed
        deviceKeyCache = [:]
        // Spares left on the relay were signed by the keys this replaces: none may be finished in their name from here
        // (this data may have been copied from another device). They're erased, and new ones made with the new keys.
        for c in data.contacts where c.spare != nil || c.moreSpares != nil || c.oldSpares != nil { withdrawSpare(for: c) }
        save()
        return seed
    }

    /// This device's own keys as one persona uses them, and their card, signed by that persona for this device's id.
    func deviceKey(for persona: UUID?) -> (key: DeviceKey, card: DeviceKeyCard)? {
        let tag = persona?.uuidString ?? "main"
        if let cached = deviceKeyCache[tag] { return cached }
        guard let me = me(persona), let seed = deviceSeed(), let key = try? DeviceKey(seed: seed, persona: persona),
              let card = try? key.card(account: me, device: deviceID(for: persona)) else { return nil }
        deviceKeyCache[tag] = (key, card)
        return (key, card)
    }

    /// A new ask for keys from `persona` to the account with signing key `to`, signed by this device's own keys.
    private func signedHandshake(persona: UUID?, to: Data, context: HandshakeContext) -> (PendingHandshake, SessionInit)? {
        guard let me = me(persona), var (pending, request) = try? Handshake.start(),
              let mine = deviceKey(for: persona), let signed = signedAsk(request, persona: persona, to: to, context: context)
        else { return nil }
        pending.pin = mine.card.pin
        return (pending, signed)
    }

    /// An ask for keys signed by this device's own keys, for the way in it's sent by.
    private func signedAsk(_ request: SessionInit, persona: UUID?, to: Data, context: HandshakeContext) -> SessionInit? {
        guard let me = me(persona), let mine = deviceKey(for: persona) else { return nil }
        let parties = HandshakeParties(from: me.card.signing, to: to, device: deviceID(for: persona))
        return try? Handshake.signed(request, by: mine.key, card: mine.card, parties, context: context)
    }

    /// Who a handshake signed by contact `i`'s device `device` is between.
    private func theirParties(contact i: Int, device: Data) -> HandshakeParties? {
        guard let me = me(data.contacts[i].persona) else { return nil }
        return HandshakeParties(from: data.contacts[i].signingKey, to: me.card.signing, device: device)
    }

    /// The post-quantum keys that sign contact `i`'s devices: theirs as pinned, or your own account's.
    private func accountPQ(contact i: Int) -> PQPin? {
        data.contacts[i].pq ?? (data.contacts[i].isSelf ? me(data.contacts[i].persona)?.pq.pin : nil)
    }

    /// The pin of the keys contact `i`'s device `device` signed an ask with, if they check out. Nil: not taken.
    private func askerPin(_ request: SessionInit, contact i: Int, device: Data, context: HandshakeContext) -> Data? {
        guard let pq = accountPQ(contact: i), let parties = theirParties(contact: i, device: device) else { return nil }
        return Handshake.devicePin(of: request, parties, accountPQ: pq, context: context)
    }

    /// The pin of the keys contact `i`'s device `device` signed its answer to `pending` with, if they check out.
    private func answererPin(_ answer: SessionAccept, to pending: PendingHandshake, contact i: Int, device: Data) -> Data? {
        guard let pq = accountPQ(contact: i), let parties = theirParties(contact: i, device: device),
              let kem = pending.publicKem, let mine = pending.pin else { return nil }
        return Handshake.devicePin(of: answer, parties, accountPQ: pq, askKem: kem, askerPin: mine)
    }

    /// Pins the keys a device of contact `i` proved in a handshake. Keys other than the ones pinned make it a new device,
    /// whatever its id: a friend's is said in the chat and held when you ask before new devices; one of your own is listed
    /// as one to check, as when a device you didn't approve introduces itself.
    /// A first pin where a session was already running is announced too: the keys that session was opened with were never
    /// pinned, so nothing says these belong to the same device.
    private func pinDeviceKey(_ pin: Data, contact i: Int, device d: Int) {
        let old = data.contacts[i].devices[d].keyPin
        guard old != pin else { return }
        let replacing = old == nil && data.contacts[i].devices[d].session != nil
        data.contacts[i].devices[d].keyPin = pin
        let isSelf = data.contacts[i].isSelf
        if old != nil || replacing {
            if isSelf {
                data.contacts[i].devices[d].unconfirmed = true
            } else {
                let hold = holdsNewDevices(contact: i, vouched: vouchedPins.contains(vouchKey(contact: i, pin: pin)))
                if hold { data.contacts[i].devices[d].unconfirmed = true }
                noteNewDevice(of: data.contacts[i], held: hold)
            }
        }
        // Your other devices pin it too.
    }

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
        let changed = id != data.activePersona
        withAnimation(.smooth(duration: 0.4)) { data.activePersona = id }
        if changed {
            let profile = profile(for: id)
            personaFlash = PersonaFlash(name: profile.displayName, avatar: profile.avatar,
                                        seed: me(id)?.fingerprint ?? "", isMain: id == nil)
        }
        save()
    }

    /// Before a chat is shown: switches to the persona it belongs to, so the screen never shows one identity while the
    /// chat sends as another (a notification or a link can open any persona's chat).
    func becomeOwner(of id: Conversation.ID) {
        guard let convo = conversation(id), !belongsHere(convo) else { return }
        switchPersona(convo.persona)
    }

    /// Whether a chat may be shown while the active persona is in use: its own chats, and the ones every persona lists
    /// (burners', which carry their own name and timer, and Announcements).
    func belongsHere(_ convo: Conversation) -> Bool {
        convo.persona == data.activePersona || isBurner(convo.persona) || convo.isAnnouncements
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
        save()
    }

    // MARK: Public profiles & requests

    /// `publicName`: the name is a group's or channel's (`PublicNameCard`), checked and kept for `openFoundPublicName`.
    enum DirectoryError: Error { case invalidHandle, taken, reserved, held, full, unreachable, invalid, publicName }

    /// Requests waiting for the active persona.
    var requests: [FriendRequest] { data.requests.filter { $0.persona == activePersona } }
    /// Invites to be friends from people you share a group with, for the persona in use.
    var groupFriendInvites: [GroupFriendInvite] { data.friendInvites.filter { $0.persona == activePersona } }

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
                                    sendID: Mailbox.sendID(for: invite.receiveKey), relay: invite.relay)
        card.links = Self.sharedLinks(profile)
        card.notes = Self.sharedNotes(profile)
        let blob = try JSONEncoder.pulshade.encode(card)
        let updated = directoryStamp(handle)
        let message = Data("pulshade.dir.v1".utf8) + Data(handle.utf8) + withUnsafeBytes(of: updated.bigEndian) { Data($0) } + blob
        let sig = try me.signingKey.signature(for: message)
        return .init(key: me.card.signing.base64EncodedString(), blob: blob.base64EncodedString(),
                     sig: sig.base64EncodedString(), updated: updated)
    }

    /// The time a directory entry says it was made, in the milliseconds the relay counts in: the relay's clock (not this
    /// device's, which can say where in the world it is set, or how far off it runs), rounded up to the whole minute, so
    /// anyone who looks a handle up learns only the minute it last changed. One made within the same minute as the last
    /// (for any handle: handles are listed newest first) counts a minute on, so each is still newer than the one before.
    func directoryStamp(_ handle: String, now: Date = RelayClock.now) -> UInt64 {
        let minute: UInt64 = 60_000
        let ms = UInt64(max(0, now.timeIntervalSince1970) * 1000)
        var stamp = (ms + minute - 1) / minute * minute
        if stamp <= lastDirectoryStamp { stamp = lastDirectoryStamp + minute }
        lastDirectoryStamp = stamp
        return stamp
    }
    /// The last stamp given to a directory entry. Memory only.
    @ObservationIgnored private var lastDirectoryStamp: UInt64 = 0

    /// Lists the active persona under @handle so anyone who knows it can send a request. The first handle becomes
    /// the main one; a second or third is in use alongside it (up to `maxHandles`, counting any kept for you).
    func publishProfile(handle raw: String) async throws {
        guard let handle = DirectoryProfile.validHandle(raw) else { throw DirectoryError.invalidHandle }
        guard let client = client(nil, lane: Self.directoryLane(activePersona)) else { throw DirectoryError.unreachable }
        let persona = activePersona
        do {
            try await claimOwn(handle, persona: persona, on: client)
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
            try? await claimOwn(handle, persona: persona, on: client)
        }
    }

    /// Lists `handle` for `persona`. Entries are stamped to the minute (`directoryStamp`), so one made on another of the
    /// account's devices (or before a restore) in the same minute can be as new as this one, which the relay turns away
    /// as stale: then this goes once more, stamped after the one the relay holds, if that one is this persona's own.
    private func claimOwn(_ handle: String, persona: UUID?, on client: RelayClient) async throws {
        let entry = try signedEntry(handle: handle, persona: persona)
        do {
            try await client.claim(handle, entry)
        } catch RelayClient.DirectoryError.taken {
            guard let held = try? await client.lookup(handle), held.key == entry.key, held.updated >= entry.updated else {
                throw RelayClient.DirectoryError.taken
            }
            lastDirectoryStamp = max(lastDirectoryStamp, held.updated)
            try await client.claim(handle, try signedEntry(handle: handle, persona: persona))
        }
    }

    /// Looks up exactly one handle and checks its signature. Nil if nobody has it.
    func findProfile(_ raw: String) async throws -> DirectoryProfile? {
        guard let handle = DirectoryProfile.validHandle(raw) else { throw DirectoryError.invalidHandle }
        guard let client = client(nil, lane: "lookup") else { throw DirectoryError.unreachable }
        let found: RelayClient.DirectoryEntry?
        do { found = try await client.lookup(handle) } catch { throw DirectoryError.unreachable }
        guard let entry = found else { return nil }
        guard let profile = verified(entry, handle: handle) else {
            // A group's or channel's public name, from the same pool of names.
            // Nothing is opened here: this runs in the background too (a contact's handle being checked), and only
            // someone who searched for it should see its screen (`openFoundPublicName`).
            if let card = PublicNameCard.verified(entry, handle: handle) {
                foundPublicNames[handle] = card
                throw DirectoryError.publicName
            }
            throw DirectoryError.invalid
        }
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
    /// `waiting`: a check already under way may have asked before something new went up, so one asked for now waits for
    /// it to finish and then asks itself (it used to do nothing). The regular check every minute just skips its turn.
    func refreshAnnouncements(waiting: Bool = true) async {
        while waiting, checkingAnnouncements, phase == .unlocked { try? await Task.sleep(for: .milliseconds(50)) }
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
    func sendRequest(to profile: DirectoryProfile, note: String, persona: UUID?? = nil) -> Contact? {
        let persona = persona ?? activePersona
        guard identity != nil, !myFingerprints.contains(profile.fingerprint),
              profile.relay == nil || Invite.allowedRelay(profile.relay) != nil else { return nil }
        if let known = contact(profile.fingerprint, in: persona), !known.awaitingAcceptance, !known.hidden { return known }
        guard let (handshake, request) = signedHandshake(persona: persona, to: profile.signingKey, context: .request) else { return nil }
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
                           device: request.device ?? Data())
        // Only the device id the envelope was signed under: the card's own `device` is just what the request says.
        let asking = request.device ?? Data()
        peer.color = request.card.color
        peer.persona = request.persona
        var newDevice = false
        if let old = contact(request.fingerprint, in: request.persona) {
            peer.nickname = old.nickname
            peer.addedAt = old.addedAt
            peer.verified = old.verified && old.agreementKey == request.card.agreementKey
            peer.pqCommit = old.pqCommit
            peer.revoked = old.revoked
            peer.contested = old.contested
            peer.unlinked = old.unlinked
            // Every device of theirs already known stays, with the keys pinned for it and whether it's held: a request is
            // no way round them. The asking device joins them; one not among them is a new device like any other. Links
            // still waiting for a device's id (an invite not answered yet) are what this request answers, so they go.
            var devices = old.devices.filter { !$0.id.isEmpty || $0.keyPin != nil }
            if let k = devices.firstIndex(where: { !$0.id.isEmpty && $0.id == asking }) {
                devices[k].sendID = request.card.sendID
            } else if let link = peer.devices.first {
                var link = link
                if !devices.isEmpty {
                    newDevice = true
                    // A request carries no vouch: after their account unlinked a device, a new one waits for a yes too.
                    if data.security.holdNewDevices || old.contested != nil || old.unlinked != nil { link.unconfirmed = true }
                }
                devices.append(link)
            }
            peer.devices = devices
        }
        Self.takeBack(&peer)
        peer.pq = request.card.pq?.verified(signer: request.card.signingKey, agreement: request.card.agreementKey)
        if let pin = peer.pq, !pinMatchesInvite(pin, contact: peer) { peer.pq = nil }
        peer.relay = Invite.allowedRelay(request.card.relay)
        upsert(peer)
        withAnimation(.snappy) { data.requests.removeAll { $0.id == id } }
        if let i = contactIndex(peer.fingerprint, peer.persona) {
            if newDevice { noteNewDevice(of: data.contacts[i], held: data.contacts[i].devices.last?.unconfirmed == true) }
            if let d = data.contacts[i].devices.firstIndex(where: { $0.id == asking }) {
                acceptSession(request.handshake, contact: i, device: d, context: .request)
            }
        }
        enqueue(.accepted(sendID: mailbox.sendID), to: peer)
        shareStories(with: peer)
        let convo = startConversation(kind: .direct, title: peer.displayName, members: [peer.fingerprint],
                                      persona: .some(request.persona))
        noteConnected(convo.id)
        save()
        return convo
    }

    /// Opens a new friend's chat with a line saying you're connected, so it's ready to use without either of you
    /// having to send anything first. Only on a chat with nothing in it yet.
    private func noteConnected(_ id: Conversation.ID) {
        guard let i = index(of: id), data.conversations[i].messages.isEmpty else { return }
        data.conversations[i].messages.append(Message(sender: "system", text: "You're now connected. Say hi 👋", status: .delivered))
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
        save()
    }

    func declineRequest(_ id: FriendRequest.ID) {
        if let request = data.requests.first(where: { $0.id == id }) {
        }
        withAnimation(.snappy) { data.requests.removeAll { $0.id == id } }
        save()
    }

    /// Declines and drops anything they send in future, without telling them.
    func blockRequest(_ id: FriendRequest.ID) {
        guard let request = data.requests.first(where: { $0.id == id }) else { return }
        if !data.blocked.contains(request.fingerprint) { data.blocked.append(request.fingerprint) }
        data.blockedNames[request.fingerprint] = request.card.name
        declineRequest(id)
    }

    /// Blocks someone you already chat with: their chat, stories and requests go, and anything they send later is
    /// dropped. Nothing tells them.
    func blockContact(_ fingerprint: String, persona: UUID?) {
        guard let c = contact(fingerprint, in: persona), !c.isSelf else { return }
        if !data.blocked.contains(fingerprint) { data.blocked.append(fingerprint) }
        data.blockedNames[fingerprint] = c.displayName
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
        // Chat keys that aren't ready yet (an account just recovered, a friend who hasn't answered) leave the notice
        // waiting inside the contact, and deleting the contact would delete it: their app would never hear. So the
        // person goes from your screens at once and the record stays, hidden, until the notice has gone out.
        forget(c, keepingRecord: waitingToTell(c))
        save()
    }

    /// Whether the notice that you removed them is still waiting for keys on any of their devices.
    private func waitingToTell(_ contact: Contact) -> Bool {
        guard let i = contactIndex(contact.fingerprint, contact.persona) else { return false }
        return data.contacts[i].devices.contains { device in
            device.pending.contains { if case .burn = $0.payload { true } else { false } }
        }
    }

    /// Someone you removed is a friend again: the removal is called off. Removed before the chat keys were ready, their
    /// record was kept, hidden, with the notice still waiting inside it; left there, it would go out once the new keys
    /// were ready and their app would forget you again, and the record would be forgotten here too.
    static func takeBack(_ contact: inout Contact) {
        contact.departing = nil
        // A friend now, not a stranger from a channel's code: never let go with those.
        contact.viaCode = nil
        for d in contact.devices.indices {
            contact.devices[d].pending.removeAll { if case .burn = $0.payload { true } else { false } }
        }
    }

    /// Finishes removing people whose notice has gone out (or that has waited two weeks): from here on they're forgotten
    /// the ordinary way.
    private func finishDepartures() {
        for c in data.contacts where c.departing != nil {
            guard let since = c.departing, !waitingToTell(c) || Date().timeIntervalSince(since) > 14 * 24 * 3600 else { continue }
            forget(c)
        }
    }

    /// Takes back a request you sent that hasn't been accepted. It leaves your list at once; if it already reached them
    /// it stays in their requests until they decline it, and accepting it does nothing because you no longer wait for it.
    func cancelRequest(to fingerprint: String) {
        guard let c = sentRequests.first(where: { $0.fingerprint == fingerprint }) else { return }
        removeContact(c.fingerprint, persona: c.persona)
    }

    /// Forgets someone and your chat with them: they burned, or one of you removed the other.
    private func forget(_ contact: Contact, keepingRecord: Bool = false) {
        let (fp, persona) = (contact.fingerprint, contact.persona)
        withdrawSpare(for: contact)
        if let chat = directConversation(with: fp, persona: persona) { removeLocally(chat.id) }
        withAnimation(.snappy) {
            data.stories.removeAll { $0.author == fp && $0.persona == persona }
            data.requests.removeAll { $0.fingerprint == fp && $0.persona == persona }
            for i in data.conversations.indices where data.conversations[i].kind == .broadcast && data.conversations[i].persona == persona {
                data.conversations[i].members.removeAll { $0 == fp }
            }
            guard let i = contactIndex(fp, persona) else { return }
            if keepingRecord {
                data.contacts[i].hidden = true
                data.contacts[i].nickname = ""
                data.contacts[i].verified = false
                data.contacts[i].departing = data.contacts[i].departing ?? Date()
                return
            }
            let sharesAGroup = data.conversations.contains {
                ($0.kind == .group || $0.kind == .channel) && $0.persona == persona && ($0.members.contains(fp) || $0.owner == fp)
            }
            if sharesAGroup {
                data.contacts[i].hidden = true
                data.contacts[i].nickname = ""
                data.contacts[i].verified = false
                data.contacts[i].departing = nil
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
            self.save()
            await self.republish(persona)
        }
    }

    func setTheme(_ theme: Theme) {
        withAnimation(.smooth(duration: 0.5)) { data.theme = theme.id }
        UserDefaults.standard.set(theme.id, forKey: "pulshade.theme")
        save()
    }

    /// Changes what sits behind the messages. Picking the theme's own look saves it as "the theme's", so it follows
    /// the theme when that changes.
    func setChatBackground(_ background: ChatBackground) {
        var background = background
        if background.style == theme.backdrop { background.style = .theme }
        guard background != data.chatBackground else { return }
        withAnimation(.smooth(duration: 0.35)) { data.chatBackground = background }
        save()
    }

    // MARK: Security settings

    /// Lock-screen settings live outside the vault so the locked window can honour them too.
    static var captureBlocked: Bool {
        UserDefaults.standard.object(forKey: "pulshade.blockCapture") as? Bool ?? true
    }

    private func mirrorSecurity() {
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

    func updateSecurity(_ change: (inout SecuritySettings) -> Void) {
        let before = data.security
        change(&data.security)
        if data.security.onlineStatus != before.onlineStatus {
            if data.security.onlineStatus { resetPresenceSchedule() } else { sendPresence(false); online = [:] }
        }
        if data.security.tor != before.tor {
            data.security.torSince = data.security.tor ? Date() : nil
            if !data.security.tor { data.security.torFromStart = false }
            if data.security.tor {
                // The helper runs outside Tor. Turning Tor on turns collecting-while-locked off, and takes its
                // keys out of the Keychain now rather than at the next housekeeping pass. Its inbox stays: the
                // relay has already handed those envelopes over.
                drainHelperInbox()
                HelperStore.clearDelivery()
                helperWritten = nil
            }
        }
        // Collecting while locked can't be used over Tor: it would connect directly and show the server this
        // phone's address. Turning it on while Tor is on leaves it off.
        if data.security.tor { data.security.lockedDelivery = false }
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
        lock(keepingKeys: true)
    }

    /// The iPhone locked: Pulshade locks with it, unless auto-lock is set to never. Not during a call (locking
    /// hangs up) or while a story is going out; then it locks when it's next brought back.
    func deviceLocked() {
        guard phase == .unlocked, data.security.autoLockMinutes > 0 || data.security.lockImmediately else { return }
        if call != nil || storyUploadProgress != nil { lockWhenBack = true; return }
        lock(keepingKeys: true)
    }

    /// Pulshade went to the background. With "Immediately" it locks now, with the same
    /// exceptions as `deviceLocked`.
    func leftApp() {
        guard phase == .unlocked, data.security.lockImmediately else { return }
        if call != nil || storyUploadProgress != nil { lockWhenBack = true; return }
        lock(keepingKeys: true)
    }

    /// A lock put off by a call or a story upload, done when the app is next brought back.
    @ObservationIgnored private var lockWhenBack = false

    /// Face ID would open one identity without asking which, skipping a decoy, so it's off while one is set.
    var biometricsBlocked: Bool { hasDecoy || hasPanic }
    var biometricsOn: Bool { !biometricsBlocked && vault.hasBiometrics }

    // MARK: Decoy & panic

    enum PasscodeSetupError: Error { case inUse, tooShort, wrongCurrent }

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
        // A decoy means no helper: the real account's envelope keys must not stay in the shared Keychain, where
        // someone who only has the decoy passcode (and the device) could reach them. Read what it already holds
        // first, then leave nothing of it.
        drainHelperInbox()
        HelperStore.clear()
        helperWritten = nil
        helperKnown = false
        save()
        rebalanceFiles()
    }

    /// Puts the decoy and panic passcodes behind new ones, keeping what they open: the same decoy account (and anything in
    /// it) and the same panic landing account, sealed again the way this build seals a slot (Argon2id, tied to this
    /// device's Secure Enclave). Asked for with the real account's new PIN when a 4-digit one must go
    /// (`ChangePasscodeSheet`), so neither is left on a keypad the lock screen no longer shows, nor sealed the older way.
    /// A new passcode may already open its own slot (a second try after one half worked), never any other. In a decoy it
    /// changes nothing, as setting either up there doesn't.
    func renewDisguises(decoy: String?, panic: String?) async throws {
        for new in [decoy, panic].compactMap({ $0 }) where new.count < LockStyle.minimumLength { throw PasscodeSetupError.tooShort }
        if let decoy, decoy == panic { throw PasscodeSetupError.inUse }
        guard isPrimary, phase == .unlocked, identity != nil else { return }
        let vault = vault
        func opensOnly(_ passcode: String, slot: Int) async -> Bool {
            switch await Task.detached(operation: { try? vault.unlock(passcode: passcode) }).value {
            case nil: return true
            case let .identity(_, at)?: return at == slot && slot == 1
            case let .panic(_, at)?: return at == slot && slot == 2
            }
        }
        let decoyWho = try data.decoySeed.map { try Identity(seed: $0) }
        let landing = try data.panicSeed.map { try Identity(seed: $0) }
        if let decoy, decoyWho != nil, !(await opensOnly(decoy, slot: 1)) { throw PasscodeSetupError.inUse }
        if let panic, landing != nil, !(await opensOnly(panic, slot: 2)) { throw PasscodeSetupError.inUse }
        if let decoy, let decoyWho { try await Task.detached { try vault.setSlot(1, identity: decoyWho, passcode: decoy) }.value }
        if let panic, let landing { try await Task.detached { try vault.setSlot(2, identity: landing, passcode: panic, panic: true) }.value }
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

    /// After updating from a build whose data files had no Keychain keys: the main account gives every one (its own, the
    /// decoy's and panic's, the fillers) its key in one go, so the Keychain's creation dates don't single out the real one.
    private func wrapDataFilesTogether() {
        guard isPrimary, vault.hasUnwrappedDataFiles else { return }
        save()
        settleSaves()
        refreshDisguises()
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
        // No helper with a panic passcode set: the real account's envelope keys go from the shared Keychain now.
        drainHelperInbox()
        HelperStore.clear()
        helperWritten = nil
        helperKnown = false
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
        if covered {
            if slot == self.slot, identity.fingerprint == self.identity?.fingerprint {
                uncover()
                return true
            }
            // Face ID turned on in another account than the one covered: that one closes, as with a passcode (`unlock`).
            covered = false
            lock()
        }
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
    private func enqueue(_ payload: Payload, to contact: Contact, message: UUID? = nil, resendOf: UUID? = nil) {
        guard let i = contactIndex(contact.fingerprint, contact.persona) else { return }
        for d in data.contacts[i].devices.indices where !isDormant(contact: i, device: d) {
            // A friend's device you haven't allowed only keeps what's worth having later: no signals, no calls (an old
            // one would ring when you allow it).
            if !data.contacts[i].isSelf, data.contacts[i].devices[d].unconfirmed == true, payload.isPassing { continue }
            // A signal waiting for keys is only worth its newest copy: a device that never answers would otherwise
            // collect every "typing" sent to it, here and then on the relay.
            if payload.isEphemeral, data.contacts[i].devices[d].session?.canSend != true {
                data.contacts[i].devices[d].pending.removeAll { $0.payload.isEphemeral }
            }
            data.contacts[i].devices[d].pending.append(PendingPayload(payload: payload, message: message, resendOf: resendOf))
            // A device whose spare key is being fetched gets its keys from that, and what waits goes then.
            if data.contacts[i].devices[d].session == nil && data.contacts[i].devices[d].handshake == nil
                && data.contacts[i].devices[d].awaitingHello != true && !sparesFetching.contains(sessionKey(contact: i, device: d)) {
                openKeys(contact: i, device: d)
            }
        }
        sendPending(contact: i)
    }

    /// Encrypts whatever is waiting for each of a contact's devices, where the session can send yet.
    private func sendPending(contact i: Int) {
        for d in data.contacts[i].devices.indices {
            // A friend's new device you haven't allowed: what's for it waits here, at most the newest few hundred. Only
            // the empty opener goes (`Payload.opener`): it says nothing, but without a first message from this side
            // their new device can't write, and what it sends is what you'd want to see once you allow it.
            let held = !data.contacts[i].isSelf && data.contacts[i].devices[d].unconfirmed == true
            if held, data.contacts[i].devices[d].pending.count > Self.maxHeldPending {
                // The opener is never what makes way.
                let all = data.contacts[i].devices[d].pending
                let openers = all.filter { $0.payload == Payload.opener }
                data.contacts[i].devices[d].pending = openers + all.filter { $0.payload != Payload.opener }.suffix(Self.maxHeldPending)
            }
            guard var session = data.contacts[i].devices[d].session, session.canSend,
                  data.contacts[i].devices[d].needsUpdate != true,
                  !data.contacts[i].devices[d].pending.isEmpty else { continue }
            // Nothing is sent to someone whose post-quantum keys aren't known (they are asked for), or whose app has none.
            guard data.contacts[i].pq != nil || data.contacts[i].isSelf else { sendPQIntro(contact: i); continue }
            var pending = data.contacts[i].devices[d].pending
            data.contacts[i].devices[d].pending = []
            if held {
                data.contacts[i].devices[d].pending = pending.filter { $0.payload != Payload.opener }
                pending = pending.filter { $0.payload == Payload.opener }
                if pending.isEmpty { continue }
            }
            for item in pending {
                // To an app that reads frames, big things go without the base64 that nearly doubles them at each
                // layer. Short messages are sent exactly as before.
                let frames = data.contacts[i].devices[d].readsFrames == true
                guard let plain = try? item.payload.wire(framed: frames) else {
                    data.contacts[i].devices[d].pending.append(item)
                    continue
                }
                // Post-quantum chunks fill the padding the envelope has anyway. Not while our own keys still go along
                // in the envelope (`pqCardSent`), which makes it bigger than this can tell.
                let framed = frames && plain.count + 16 > Self.smallEnvelope
                let carriesCard = data.contacts[i].pqCardSent != true && !data.contacts[i].isSelf
                let fit: ((RatchetMessage) -> (size: Int, room: Int))? = carriesCard ? nil : { candidate in
                    guard let body = try? Payload.ratchet(candidate).wire(framed: framed) else { return (0, -1) }
                    return Envelope.ratchetFit(body: body.count)
                }
                guard let message = try? session.encrypt(plain, fit: fit) else {
                    // Couldn't be sealed: keep it to try again rather than dropping it silently.
                    data.contacts[i].devices[d].pending.append(item)
                    continue
                }
                seal(.ratchet(message), contact: i, device: d, message: item.message, ephemeral: item.payload.isEphemeral,
                     collapse: item.payload.collapseKind, resendOf: item.resendOf,
                     story: item.payload.storyID, viewReport: item.payload.storyViewID, rings: item.payload.rings,
                     framed: framed, wakes: item.payload.isInvite, lane: item.payload.isReceipt ? Lanes.once("receipt") : nil)
            }
            data.contacts[i].devices[d].session = session
        }
    }

    /// Whether keys may be pinned for a contact: if the invite that added them committed to their post-quantum keys, only keys
    /// that match it. Without such an invite (a public handle, a group, a request) the first verified card is what there is.
    private func pinMatchesInvite(_ pin: PQPin, contact: Contact?) -> Bool {
        guard let commit = contact?.pqCommit else { return true }
        return pin.commitment == commit
    }

    /// Sends this account's post-quantum card to a contact that hasn't got it: the way their keys are asked for, since they
    /// answer an introduction with theirs. Once per contact; a classical introduction is answered whenever one arrives.
    private func sendPQIntro(contact i: Int, force: Bool = false) {
        let c = data.contacts[i]
        guard c.pqCardSent != true || force, !c.isSelf, !c.devices.isEmpty, c.tooOld == nil, let me = me(c.persona) else { return }
        seal(.pqIntro(me.pqCard), contact: i, device: 0)
    }

    /// Every contact made before post-quantum keys, once after an update: introduces this account to it, and gets theirs back
    /// if their app has them. The contact, its chat and its session all stay as they were.
    func introducePQToContacts() {
        for i in data.contacts.indices where data.contacts[i].pq == nil && !data.contacts[i].hidden && !data.contacts[i].awaitingAcceptance {
            sendPQIntro(contact: i)
        }
    }

    /// When this device last answered a contact's classical introduction with its own card (memory only).
    @ObservationIgnored private var introRepliedAt: [String: Date] = [:]
    private static let introReplyGap: TimeInterval = 600

    /// Whether a contact's classical introduction may be answered now, and notes that it was.
    private func introReplyDue(_ fp: String, _ persona: UUID?) -> Bool {
        let key = "\(persona?.uuidString ?? "main")|\(fp)"
        if let last = introRepliedAt[key], Date().timeIntervalSince(last) < Self.introReplyGap { return false }
        introRepliedAt[key] = Date()
        return true
    }

    /// A classical envelope from a contact who has post-quantum keys or never will (an app from before): refused, and the person
    /// is told once a day to ask them to update, by name.
    private func noteTooOld(_ signer: Data, persona: UUID?) {
        guard let i = contactIndex(Identity.fingerprint(of: signer), persona), !data.contacts[i].isSelf else { return }
        if let last = data.contacts[i].tooOld, Date().timeIntervalSince(last) < 24 * 3600 { return }
        data.contacts[i].tooOld = Date()
        if let c = data.conversations.firstIndex(where: { $0.kind == .direct && $0.members == [data.contacts[i].fingerprint] && $0.persona == persona }) {
            data.conversations[c].messages.append(Message(sender: "system", text: "\(data.contacts[i].displayName) needs to update Pulshade before you can message each other.",
                                                          date: Date()))
        }
        save()
    }

    /// This device, as a contact should reach it: its id and the mailbox it reads them on.
    private func myDevice(for i: Int) -> DeviceCard {
        if data.contacts[i].receiveKey == nil { data.contacts[i].receiveKey = Mailbox.make().receiveKey }
        return DeviceCard(id: deviceID(for: data.contacts[i].persona), sendID: Mailbox.sendID(for: data.contacts[i].receiveKey!),
                          vouch: data.contacts[i].persona == nil ? data.deviceVouch : nil)
    }

    /// Opens a session with one device, introducing this device at the same time.
    private func startHandshake(contact i: Int, device d: Int) {
        guard let (handshake, request) = signedHandshake(persona: data.contacts[i].persona, to: data.contacts[i].signingKey, context: .device) else { return }
        if let earlier = data.contacts[i].devices[d].handshake { keepEarlierAsk(earlier, contact: i, device: d) }
        data.contacts[i].devices[d].handshake = handshake
        data.contacts[i].devices[d].needsKeys = nil
        // Only the newest ask is any use (it carries the keys this device is waiting on), so it replaces the last one
        // on the relay: a device that never answers holds one, however often it's asked.
        seal(.deviceHello(myDevice(for: i), request), contact: i, device: d, collapse: "hello")
    }

    /// Keeps an ask for keys that a newer one replaces: its answer may already be on the relay, waiting for this phone
    /// to wake. Only a few, and none older than `askLifetime`.
    private func keepEarlierAsk(_ ask: PendingHandshake, contact i: Int, device d: Int) {
        var asks = (data.contacts[i].devices[d].earlierAsks ?? []) + [ask]
        asks.removeAll { Date().timeIntervalSince($0.startedAt) > Self.askLifetime }
        data.contacts[i].devices[d].earlierAsks = Array(asks.suffix(Self.earlierAsksKept))
    }

    /// How many asks for keys, before the current one, are still taken an answer for.
    static let earlierAsksKept = 3
    /// How long the secret half of an unanswered ask for keys is kept: an answer that comes later can't be opened, and the
    /// chat mends by asking again (see docs/protocol.md, section 2). A friend request waiting to be accepted keeps its
    /// ask for `requestAskLifetime`, since nothing else can finish it.
    static let askLifetime: TimeInterval = 8 * 86_400
    static let requestAskLifetime: TimeInterval = replayWindow

    /// Forgets handshake secrets past their time: asks older than `askLifetime` (a request's, `requestAskLifetime`), and
    /// replaced spares past `spareGrace`. At unlock and with the rest of the upkeep, so they go on time even with the app
    /// left open. A device left with no keys and no ask is asked again (or its spare taken) by `resumeKeyFetch`.
    /// Old keys of skipped messages go the same way (`Ratchet.skippedLifetime`).
    @discardableResult
    func pruneHandshakeSecrets(now: Date = Date()) -> Bool {
        var changed = false
        for i in data.contacts.indices {
            let life = data.contacts[i].awaitingAcceptance ? Self.requestAskLifetime : Self.askLifetime
            for d in data.contacts[i].devices.indices {
                let link = data.contacts[i].devices[d]
                if let asks = link.earlierAsks, asks.contains(where: { now.timeIntervalSince($0.startedAt) > life }) {
                    let kept = asks.filter { now.timeIntervalSince($0.startedAt) <= life }
                    data.contacts[i].devices[d].earlierAsks = kept.isEmpty ? nil : kept
                    changed = true
                }
                if let ask = link.handshake, now.timeIntervalSince(ask.startedAt) > life {
                    changed = true
                    data.contacts[i].devices[d].handshake = nil
                    if link.session == nil && !data.contacts[i].awaitingAcceptance && !link.id.isEmpty {
                        data.contacts[i].devices[d].needsKeys = true
                    }
                }
                if let session = link.session, session.hasExpiredSkipped(now: now) {
                    data.contacts[i].devices[d].session?.dropExpiredSkipped(now: now)
                    changed = true
                }
            }
            let grace = now.addingTimeInterval(-Self.spareGrace)
            if data.contacts[i].oldSpares?.contains(where: { ($0.retiredAt ?? .distantPast) <= grace }) == true {
                data.contacts[i].oldSpares?.removeAll { ($0.retiredAt ?? .distantPast) <= grace }
                if data.contacts[i].oldSpares?.isEmpty == true { data.contacts[i].oldSpares = nil }
                changed = true
            }
        }
        return changed
    }

    /// When this device last opened fresh keys with a device because the post-quantum ratchet had stalled, by
    /// `sessionKey`. Memory only: at most one such ask a day per device.
    @ObservationIgnored private var pqRefreshedAt: [String: Date] = [:]

    /// Opens fresh keys with any device whose session's post-quantum ratchet has stalled (`Ratchet.postQuantumStalled`):
    /// the new handshake's root is post-quantum, as SPQR starts over when its epochs stop moving. The chat goes on on the
    /// old keys until the answer comes.
    private func refreshStalledPostQuantum() {
        let now = Date()
        for i in data.contacts.indices where !data.contacts[i].awaitingAcceptance {
            for d in data.contacts[i].devices.indices {
                let link = data.contacts[i].devices[d]
                guard let session = link.session, session.canSend, session.postQuantumStalled, link.handshake == nil,
                      link.awaitingHello != true, link.needsUpdate != true, link.unconfirmed != true,
                      !isDormant(contact: i, device: d) else { continue }
                let key = sessionKey(contact: i, device: d)
                guard now.timeIntervalSince(pqRefreshedAt[key] ?? .distantPast) > 86_400, !sparesFetching.contains(key) else { continue }
                pqRefreshedAt[key] = now
                startHandshake(contact: i, device: d)
            }
        }
    }

    /// Takes back an ask for keys still waiting in the outbox: it was answered already, through an earlier one.
    /// Whether it was: false when it has gone, or is going.
    @discardableResult
    private func withdrawHello(contact i: Int, device d: Int) -> Bool {
        // By kind and mailbox, not by tag: the tag changes every few minutes, and an ask queued earlier still counts.
        let box = data.contacts[i].devices[d].sendID
        let before = data.outbox.count
        data.outbox.removeAll { $0.collapseKind == "hello" && $0.sendID == box && !sendingIDs.contains($0.id) }
        return data.outbox.count < before
    }

    /// Answers a device's handshake. We speak first, so we say who we are straight away. `spare`: the ask is a spare key
    /// they left for us (see `SpareSlot`), so the answer also says which device this is, since they may not know it yet.
    /// `sentAt`: when they sent the ask, by their clock, where it's known.
    /// The ask must carry the asking device's keys, signed by its account, and its own signature over the ask; the keys
    /// are pinned (`pinDeviceKey`), and the answer is signed by this device's keys in turn. Whether it was answered.
    @discardableResult
    private func acceptSession(_ request: SessionInit, contact i: Int, device d: Int, spare: Bool = false, sentAt: Date? = nil,
                               context: HandshakeContext) -> Bool {
        let persona = data.contacts[i].persona
        guard let me = me(persona), let mine = deviceKey(for: persona),
              let theirPin = askerPin(request, contact: i, device: data.contacts[i].devices[d].id, context: context),
              !isRevoked(contact: i, id: data.contacts[i].devices[d].id, pin: theirPin),
              let (session, answer) = try? Handshake.accept(request, me: me, initiatorAgreement: data.contacts[i].agreementKey,
                                                             initiatorPin: theirPin, responderPin: mine.card.pin),
              let signed = try? Handshake.signed(answer, by: mine.key, card: mine.card,
                                                 HandshakeParties(from: me.card.signing, to: data.contacts[i].signingKey,
                                                                  device: deviceID(for: persona)),
                                                 askKem: request.kem, askerPin: theirPin) else { return false }
        pinDeviceKey(theirPin, contact: i, device: d)
        // What they wrote on the keys this replaces, still on its way, stays readable for now.
        if let old = data.contacts[i].devices[d].session { keepRecovered(old, sessionKey(contact: i, device: d)) }
        data.contacts[i].devices[d].session = session
        data.contacts[i].devices[d].handshake = nil
        data.contacts[i].devices[d].earlierAsks = nil
        data.contacts[i].devices[d].needsKeys = nil
        data.contacts[i].devices[d].awaitingHello = nil
        data.contacts[i].devices[d].answeredAt = nil
        data.contacts[i].devices[d].acceptedHello = request.ephemeral
        data.contacts[i].devices[d].acceptedHelloAt = sentAt
        data.contacts[i].devices[d].sessionAskAt = nil
        data.contacts[i].devices[d].spareTakenAt = nil
        // New keys are in place: no more asking for them because of messages that were read with the old ones.
        unreadable[sessionKey(contact: i, device: d)] = nil
        seal(spare ? .spareAccept(myDevice(for: i), signed) : .sessionAccept(signed), contact: i, device: d)
        let first: Payload = data.contacts[i].isSelf ? .sync(.hello) : profilePayload(data.contacts[i].persona, for: data.contacts[i].fingerprint)
        data.contacts[i].devices[d].pending.insert(PendingPayload(payload: first, message: nil), at: 0)
        // A held friend's device gets the empty opener now; the profile waits with the rest until you allow it.
        if !data.contacts[i].isSelf, data.contacts[i].devices[d].unconfirmed == true {
            data.contacts[i].devices[d].pending.insert(PendingPayload(payload: .opener, message: nil), at: 0)
        }
        sendPending(contact: i)
        resendUnconfirmed(contact: i, device: d)
        return true
    }

    /// When each device last had what wasn't confirmed sent again because of new keys. Memory only.
    @ObservationIgnored private var keyResendAt: [String: Date] = [:]
    /// The most messages sent again at once because of new keys, newest first; the timed resend covers older ones.
    static let keyResendBatch = 50

    /// New keys with one of someone's devices: what of yours they haven't confirmed goes again now, to that device, on the
    /// new keys, rather than at the next timed try (which can be a day away). New keys usually mean the old ones had gone
    /// out of step, and what was written on them couldn't be opened on their side; they drop a copy they already have.
    /// At most once every ten minutes per device, the newest `keyResendBatch` messages, none sent again in the last ten
    /// minutes: a contact asking for new keys over and over can't make this phone upload its history each time. Groups
    /// keep their own mail.
    private func resendUnconfirmed(contact i: Int, device d: Int) {
        let c = data.contacts[i]
        guard !c.isSelf, !c.hidden, c.devices.indices.contains(d),
              let convo = directConversation(with: c.fingerprint, persona: c.persona) else { return }
        let key = sessionKey(contact: i, device: d)
        let now = Date(), cutoff = now.addingTimeInterval(-Self.resendWindow)
        guard now.timeIntervalSince(keyResendAt[key] ?? .distantPast) > 600 else { return }
        let due = convo.messages.filter { message in
            message.isMine && !message.isVideo && message.status == .sent && message.date > cutoff
                && (message.expiresAt.map { $0 > now } ?? true)
                && (resentAt[message.id].map { now.timeIntervalSince($0.at) > 600 } ?? true)
        }.suffix(Self.keyResendBatch)
        guard !due.isEmpty else { return }
        keyResendAt[key] = now
        for message in due {
            resentAt[message.id] = (now, (resentAt[message.id]?.count ?? 0) + 1)
            data.contacts[i].devices[d].pending.append(PendingPayload(payload: .message(wireForResend(message, in: convo)),
                                                                     message: nil, resendOf: message.id))
        }
        sendPending(contact: i)
    }

    /// Seals a payload to one of a contact's devices, as the persona that knows them, and queues it.
    private func seal(_ payload: Payload, contact i: Int, device d: Int, message: UUID? = nil, ephemeral: Bool = false,
                      collapse: String? = nil, resendOf: UUID? = nil, story: UUID? = nil, viewReport: UUID? = nil, rings: Bool = false, framed: Bool = false,
                      wakes: Bool = false, toSendID: Data? = nil, toRelay: String?? = nil, lane: String? = nil) {
        let c = data.contacts[i]
        guard c.devices.indices.contains(d), let me = me(c.persona) else { return }
        let blob: Data
        var introduces = false
        if let pin = c.pq ?? (c.isSelf ? me.pq.pin : nil) {
            // Their post-quantum keys are known: version 3. Ours go along until they're known to have them.
            let introduce = c.pqCardSent != true && !c.isSelf
            guard let sealed = try? Envelope.seal(payload, from: me, device: deviceID(for: c.persona),
                                                  to: EnvelopeRecipient(agreement: c.agreementKey, pq: pin), framed: framed,
                                                  introduce: introduce) else { return }
            blob = sealed
            if introduce { data.contacts[i].pqCardSent = true }
            // Key setup and other control messages now carry a signature, so they are bigger than the messages sent beside them
            // and must still go first and on the ordinary lane.
            introduces = introduce || !payload.isRatchet
        } else if payload.carriesPQCard {
            // Nothing is known of their post-quantum keys, and this is what carries ours: the one classical envelope left.
            guard let sealed = try? Envelope.sealIntroduction(payload, from: me, device: deviceID(for: c.persona), to: c.agreementKey)
            else { return }
            blob = sealed
            data.contacts[i].pqCardSent = true
            introduces = true
        } else {
            // Not to anyone whose keys are unknown: nothing classical goes out. Their keys are asked for (by sending ours);
            // a message that was waiting stays where it is (`sendPending`).
            sendPQIntro(contact: i)
            return
        }
        let sendID = toSendID ?? c.devices[d].sendID
        // Only the newest of these waits for a mailbox.
        if ephemeral { data.outbox.removeAll { $0.ephemeral == true && $0.sendID == sendID } }
        // A friend request is the one thing besides a message that should wake a locked phone: it's how you hear that
        // someone wants to talk to you. The relay is only asked to wake for mail that says so.
        var asksToWake = wakes
        if case .request = payload { asksToWake = true }
        var outgoing = Outgoing(sendID: sendID, blob: blob, relay: toRelay ?? c.relay, message: message, ephemeral: ephemeral ? true : nil,
                                story: story, viewReport: viewReport, lane: lane ?? (c.persona == nil ? nil : Outgoing.lane(for: c.persona)), rings: rings ? true : nil,
                                wakes: asksToWake ? true : nil)
        if introduces { outgoing.introduces = true }
        // A signal carries no lifetime of its own (from build 22): one marked short-lived told the relay which deposits
        // were typing or "I'm here" rather than messages. A device that's away still doesn't come back to a pile of them:
        // the newest of a kind replaces the one before, and typing that arrives late is ignored (`isFreshSignal`).
        if let collapse {
            outgoing.collapse = Self.collapseTag(collapse, sendID: sendID, from: deviceID(for: c.persona))
            outgoing.collapseKind = collapse
        } else if let resendOf {
            outgoing.collapse = Self.resendTag(resendOf, sendID: sendID, from: deviceID(for: c.persona))
            outgoing.collapseKind = "resend"
        }
        // Stamped so a Burn can take it back from the relay while it waits. Not signals, and not the Burn's own farewells.
        if !ephemeral && !burning {
            let stamp = Recall.stamp(me.recallKey)
            outgoing.recallN = stamp.n
            outgoing.recallHash = stamp.hash
        }
        data.outbox.append(outgoing)
        #if DEBUG
        sealTap?(outgoing)
        #endif
        kick()
    }

    #if DEBUG
    /// Tests: every envelope sealed for a contact, as it goes into the outbox.
    @ObservationIgnored var sealTap: ((Outgoing) -> Void)?
    #endif

    /// How old a typing signal may be, from when it reached the relay, and still be shown: long enough to cross a slow
    /// Tor circuit, short enough that it means something when it lands. ("I'm here" has its own, `presenceLife`.)
    static let signalLife: TimeInterval = 20

    /// Whether a signal that reached the relay at `deposited` (by this device's clock) is still worth showing. One
    /// with no time (an older relay) counts as fresh. `deposited` is the relay's `age` taken from this device's `Date()`
    /// when it was fetched (`RelayClient.fetch`), so it is compared with `Date()` too: `RelayClock.now` would count the
    /// difference between the two clocks as time gone by.
    static func isFreshSignal(deposited: Date?, now: Date = Date()) -> Bool {
        guard let deposited else { return true }
        return now.timeIntervalSince(deposited) <= signalLife
    }

    /// How long one collapse tag lasts. A signal is only kept two minutes and a key request that crosses a boundary
    /// just leaves one extra copy (the receiver ignores a stale ask), so the tag can change often.
    nonisolated static let collapseWindow: TimeInterval = 600

    /// The relay's tag for "the same kind of thing from the same sender": a hash of the kind, this device's id, the
    /// mailbox and a ten-minute window. Within a window it is stable, so the relay can replace the older copy; across
    /// windows it changes, so the relay can't tell for longer than that that signals to one mailbox come from one
    /// sender device.
    nonisolated static func collapseTag(_ kind: String, sendID: Data, from device: Data, at time: Date = Date()) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("pulshade.collapse.\(kind)".utf8))
        hasher.update(data: sendID)
        hasher.update(data: device)
        var window = Int64((time.timeIntervalSince1970 / collapseWindow).rounded(.down)).bigEndian
        withUnsafeBytes(of: &window) { hasher.update(bufferPointer: $0) }
        return Data(hasher.finalize().prefix(16))
    }

    /// The relay's tag for copies of one message sent again: the same for every try within a three-day window, so each
    /// replaces the one before while it waits. It changes every three days (`resendTagWindow`), so the relay can tie copies
    /// of one message together, and deposits made over different connections to one sender device, for three days at
    /// most rather than for the whole month a message is tried; a new window leaves at most one more copy waiting.
    nonisolated static let resendTagWindow: TimeInterval = 3 * 86_400

    nonisolated static func resendTag(_ message: UUID, sendID: Data, from device: Data, at time: Date = Date()) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("pulshade.resend".utf8))
        hasher.update(data: sendID)
        hasher.update(data: device)
        withUnsafeBytes(of: message.uuid) { hasher.update(bufferPointer: $0) }
        var window = Int64((time.timeIntervalSince1970 / resendTagWindow).rounded(.down)).bigEndian
        withUnsafeBytes(of: &window) { hasher.update(bufferPointer: $0) }
        return Data(hasher.finalize().prefix(16))
    }

    /// How long a device can stay silent, while another of the same person's devices still talks, before it's left
    /// out of what's sent (an old phone, a reinstall, a laptop put away). Heard from again, it's back at once.
    static var dormantAfter: TimeInterval = 30 * 24 * 3600

    /// A device left out of sending: silent for `dormantAfter` while another device of the same contact was heard
    /// from more recently. A contact's only device is never dormant, so nobody is cut off for being away.
    func isDormant(contact i: Int, device d: Int) -> Bool {
        let devices = data.contacts[i].devices
        guard devices.indices.contains(d), let heard = devices[d].lastHeard,
              Date().timeIntervalSince(heard) > Self.dormantAfter else { return false }
        return devices.indices.contains { $0 != d && (devices[$0].lastHeard ?? .distantPast) > heard }
    }

    /// Notes that a device was heard from: at most once an hour, so a busy chat doesn't rewrite it on every message.
    private func heard(contact i: Int, device d: Int) {
        guard data.contacts[i].devices.indices.contains(d) else { return }
        if let last = data.contacts[i].devices[d].lastHeard, Date().timeIntervalSince(last) < 3600 { return }
        data.contacts[i].devices[d].lastHeard = Date()
    }

    /// Seals a payload to a contact's first device, for introductions.
    private func seal(_ payload: Payload, to fingerprint: String, persona: UUID?, message: UUID? = nil) {
        guard let i = contactIndex(fingerprint, persona), !data.contacts[i].devices.isEmpty else { return }
        seal(payload, contact: i, device: 0, message: message)
    }

    // MARK: Sending again what a relay restart may have emptied

    /// Waiting mail lives in the relay's memory and, from this build's relay on, in a sealed journal on its disk, so a restart or crash keeps it; a relay without the journal, or a lost disk, still empties it. What the relay took but the other side
    /// hasn't confirmed is sent again, with nothing kept anywhere new: a friend request that hasn't been accepted, and
    /// your messages still marked "sent". The other side ignores a message it already has, and answers it with a
    /// receipt again, so a copy that wasn't needed does no harm.
    private var restartsHandled = 0
    /// A request's note, so sending it again carries the words too. Kept while the app is open.
    private var requestNotes: [String: String] = [:]
    /// The longest a message is sent again for after being sent: as long as the relay keeps mail (30 days), so a friend
    /// whose phone was off, or whose keys had to be mended, still gets it. Each copy sent again replaces the one before it
    /// on the relay (`resendTag`), so a friend who is gone for good has one spare copy waiting, not one per try.
    private static let resendWindow: TimeInterval = 30 * 24 * 3600
    /// How long mail this device can't use yet (a contact or device it hasn't met) is left on the relay.
    static let deferredMailLimit: TimeInterval = 10 * 60
    /// How long a message waits for its receipt before it is sent again, then again after the next wait, and so on.
    static var resendGaps: [TimeInterval] = [90, 300, 900, 2700, 7200, 21_600, 86_400]
    /// When each of your messages was last sent again, and how many times, while the app is open.
    @ObservationIgnored private var resentAt: [UUID: (at: Date, count: Int)] = [:]
    @ObservationIgnored private var lastDueCheck = Date.distantPast
    /// When invites to groups were last told about, so a flood of them makes a few banners an hour at most.
    @ObservationIgnored private var offerNotices: [Date] = []
    static let offerNoticesPerHour = 5
    #if DEBUG
    /// For tests about other things: invites to groups and channels are taken as if you'd said yes at once.
    @ObservationIgnored var acceptsInvitesForTests = false
    #else
    let acceptsInvitesForTests = false
    #endif

    private func resendIsDue(_ message: Message) -> Bool {
        if resentAt[message.id] == nil {
            // Older than a first resend could be while this app has been open: it was sent before this launch. Picked
            // up where its timetable has got to, not started again from the top (which sent every unconfirmed message
            // several more times each time the app was opened).
            let age = Date().timeIntervalSince(message.date)
            if Self.resendGaps[0] > 0, age > Self.resendGaps[0] * 2 {
                var passed = 0, elapsed: TimeInterval = 0
                // Bounded: a gap of nothing (as a test may set) would otherwise never end.
                while passed < 64 {
                    let gap = Self.resendGaps[min(passed, Self.resendGaps.count - 1)]
                    guard gap > 0, elapsed + gap <= age else { break }
                    elapsed += gap
                    passed += 1
                }
                resentAt[message.id] = (Date(), passed)
                return false
            }
        }
        let tried = resentAt[message.id]
        let wait = Self.resendGaps[min(tried?.count ?? 0, Self.resendGaps.count - 1)]
        return Date().timeIntervalSince(tried?.at ?? message.date) >= wait
    }

    /// The timed resend, looked at every few seconds at most: housekeeping runs more often than that.
    private func resendOverdueMessages(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastDueCheck) >= 15 else { return }
        lastDueCheck = Date()
        resendUnconfirmedMessages(dueOnly: true)
    }

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
            // Signed again by this device's keys: an unsigned ask isn't taken.
            guard let request = signedAsk(SessionInit(ephemeral: public_, kem: kem.publicKey.rawRepresentation), persona: c.persona,
                                          to: c.signingKey, context: .request) else { continue }
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
    ///
    /// `dueOnly`: the timed kind, for messages that have waited long enough since they were sent (or sent again).
    /// A restart isn't the only way mail is lost (a phone that wasn't open to notice one, a crash, a reboot), so
    /// anything still unconfirmed is tried again, soon at first and then less often, until its receipt comes.
    func resendUnconfirmedMessages(dueOnly: Bool = false) {
        let cutoff = Date().addingTimeInterval(-Self.resendWindow)
        if dueOnly { resentAt = resentAt.filter { $0.value.at > cutoff } }
        for i in data.conversations.indices {
            let convo = data.conversations[i]
            // Groups keep their own mail (see `KeptPost`); only a direct chat is sent again from here.
            guard convo.kind == .direct else { continue }
            let now = Date()
            let lost = convo.messages.filter { message in
                message.isMine && !message.isVideo && message.date > cutoff && (message.expiresAt.map { $0 > now } ?? true)
                    && (!dueOnly || resendIsDue(message)) && message.status == .sent
            }
            guard !lost.isEmpty else { continue }
            for message in lost {
                let missing = audience(convo)
                guard !missing.isEmpty else { continue }
                resentAt[message.id] = (Date(), (resentAt[message.id]?.count ?? 0) + 1)
                let wire = wireForResend(message, in: convo)
                // Not marked queued: it stays "sent" until the receipt comes, which is what makes it worth sending again.
                for member in missing { enqueue(.message(wire), to: member, resendOf: message.id) }
            }
        }
    }

    // MARK: Two ticks while locked

    /// Switched off in build 16 (the reliability build): collecting mail while locked is a second way for mail to arrive,
    /// and the delivery counter doesn't cover it yet. The setting is hidden and the helper isn't given keys; mail it
    /// collected before is still taken in (`drainHelperInbox`). Someone's saved choice is kept for when it comes back.
    static var lockedDeliveryAvailable = false

    /// Whether the notification helper runs while this iPhone is locked: it collects short mail, and confirms
    /// delivery only when delivery receipts are on (see `LockedDelivery`).
    var lockedDeliveryOn: Bool {
        let s = data.security
        guard Self.lockedDeliveryAvailable, pushWanted, s.lockedDeliveryChosen, !s.tor, !hasDecoy, !hasPanic, AppData.directRelay != nil
        else { return false }
        return true
    }

    /// What the helper is given: this account's two envelope keys, this device's id, the relay's direct address and
    /// the main persona's friends with their mailboxes. Never the seed, the chats' keys or any message. Personas
    /// aren't here: their phones aren't woken by push, so the relay can't tie them to this one.
    private func helperBundle(_ me: Identity, relay: String? = AppData.directRelay) -> HelperBundle? {
        guard let relay else { return nil }
        var friends: [String: HelperBundle.Friend] = [:]
        for c in data.contacts where c.persona == nil && !c.isSelf && !c.awaitingAcceptance && !data.blocked.contains(c.fingerprint) {
            guard let key = c.receiveKey, !c.devices.isEmpty, friends[c.fingerprint] == nil else { continue }
            friends[c.fingerprint] = HelperBundle.Friend(agreementKey: c.agreementKey, receiveKey: key,
                                                         devices: c.devices.map { .init(id: $0.id, sendID: $0.sendID) },
                                                         pq: c.pq, hasCard: c.pqCardSent)
        }
        let pq = me.pq
        return HelperBundle(signing: me.signingKey.rawRepresentation, agreement: me.agreementKey.rawRepresentation,
                            pqKem: pq.kemSeed, pqSig: pq.sigSeed,
                            device: deviceID(for: nil), relay: relay, friends: friends,
                            confirms: true)
    }

    /// The helper's bundle for this account as it stands, pointed at `relay` (tests use their own relay).
    func lockedDeliveryBundle(relay: String) -> HelperBundle? {
        identity.flatMap { helperBundle($0, relay: relay) }
    }

    /// Reads what the helper took off the relay while the phone was locked, through the same path as mail from the
    /// relay, oldest first. Each is removed only once what it changed is saved, as with the relay's acknowledgement.
    /// One this device can't use yet (a device it hasn't met) waits as long as it would have on the relay.
    func drainHelperInbox() {
        guard phase == .unlocked, isPrimary, identity != nil else { return }
        let waiting = HelperStore.inbox()
        guard !waiting.isEmpty else { return }
        var done: [String] = []
        for (name, item) in waiting {
            // Not a mailbox this account reads: never thrown away for that, only once it's as old as the relay would
            // keep it.
            guard persona(forMailbox: item.receiveKey) != nil else {
                if Date().timeIntervalSince(item.collected) > 7 * 24 * 3600 { done.append(name) }
                continue
            }
            let envelope = RelayEnvelope(receiveKey: item.receiveKey, id: 0, blob: item.blob, deposited: item.deposited)
            switch receive(envelope) {
            case .handled, .junk:
                done.append(name)
            case .retry:
                if Date().timeIntervalSince(item.deposited ?? item.collected) >= Self.deferredMailLimit { done.append(name) }
            }
        }
        guard !done.isEmpty else { return }
        lastMailReceived = Date()
        save()
        settleSaves()
        HelperStore.remove(done)
    }

    /// The bundle as last written, so it's only written again when it changes.
    @ObservationIgnored private var helperWritten: HelperBundle?
    @ObservationIgnored private var helperKnown = false
    @ObservationIgnored private var helperChecked = Date.distantPast

    /// Keeps the helper's bundle in step with the friends list and the setting, or removes it. Only with the main
    /// account open: a decoy never writes, and with a decoy or panic passcode set up there's no bundle at all.
    private func refreshHelper() {
        #if os(iOS)
        guard phase == .unlocked, isPrimary, identity != nil, Date().timeIntervalSince(helperChecked) >= 10 else { return }
        helperChecked = Date()
        reconcileHelper()
        #endif
    }

    /// The part of `refreshHelper` that decides what the Keychain should hold (apart from where it runs), so tests reach it on
    /// macOS too. With the setting off (including every account saved before it was a choice, which counts as off), the bundle
    /// with the account's keys and the confirmed digests are removed, once what the helper had taken off the relay has been read.
    /// If they can't be removed, it is tried again on the next pass instead of being taken as done.
    func reconcileHelper() {
        guard phase == .unlocked, isPrimary, let identity else { return }
        let bundle = lockedDeliveryOn ? helperBundle(identity) : nil
        guard !helperKnown || bundle != helperWritten else { return }
        if let bundle {
            HelperStore.save(bundle)
        } else {
            // Turned off: what the helper took off the relay is read first, so none of it goes unread. Only the
            // bundle goes: mail still waiting in the inbox stays for the next drain.
            drainHelperInbox()
            HelperStore.clearDelivery()
            if HelperStore.load() != nil || !HelperStore.confirmed().isEmpty { return }
        }
        helperWritten = bundle
        helperKnown = true
    }

    // MARK: Messages that didn't send

    /// How long a message may wait on this device before it shows as not sent, with a way to try again.
    static var unsentAfter: TimeInterval = 3 * 60

    /// Your messages that never reached the relay: still waiting after a few minutes, or given up on (the relay
    /// refused them, say). The chat shows them as "Not sent" with a tap to try again. Worked out every few seconds,
    /// and only assigned when it changes, so chats don't redraw for nothing.
    private(set) var unsentMessages: Set<UUID> = []

    /// When each message was last tried again by hand, so the wait starts over from then. Memory only.
    @ObservationIgnored private var retriedAt: [UUID: Date] = [:]

    /// Message ids something is still trying to send: an envelope in the outbox, or one waiting for a session.
    private var stillGoing: Set<UUID> {
        var ids = Set(data.outbox.compactMap(\.message))
        for c in data.contacts { for d in c.devices { for p in d.pending { if let m = p.message { ids.insert(m) } } } }
        for convo in data.conversations { for item in convo.shared?.outbox ?? [] { if let m = item.message { ids.insert(m) } } }
        return ids
    }

    private func noteUnsent() {
        let now = Date()
        let going = stillGoing
        var found: Set<UUID> = []
        for convo in data.conversations where convo.kind != .channel {
            // Only the newest ones need looking at. Videos aren't here: their clip has its own upload and retries.
            for message in convo.messages.suffix(200) where message.isMine && message.status == .queued && !message.isSystem && !message.isVideo {
                let since = retriedAt[message.id] ?? message.date
                if !going.contains(message.id) || now.timeIntervalSince(since) > Self.unsentAfter { found.insert(message.id) }
            }
        }
        if found != unsentMessages { unsentMessages = found }
    }

    /// Sends a message that didn't go once more, from the start: whatever was left of the first try is taken out of
    /// the queue first, so it can't go twice. Someone who did get the first copy just ignores the second.
    func retrySend(_ id: UUID, in conversation: Conversation.ID) {
        guard let convo = self.conversation(conversation), convo.kind != .channel,
              let message = convo.messages.first(where: { $0.id == id && $0.isMine && !$0.isVideo }) else { return }
        data.outbox.removeAll { $0.message == id && !sendingIDs.contains($0.id) }
        for i in data.contacts.indices {
            for d in data.contacts[i].devices.indices where data.contacts[i].devices[d].pending.contains(where: { $0.message == id }) {
                data.contacts[i].devices[d].pending.removeAll { $0.message == id }
            }
        }
        retriedAt[id] = Date()
        unsentMessages.remove(id)
        let wire = wireForResend(message, in: convo)
        if convo.shared != nil {
            // Still waiting to go in the outbox: it goes from there. Otherwise posted again (members ignore a repeat).
            if !(convo.shared?.outbox.contains { $0.message == id } ?? false) { postIfShared(.message(wire), in: conversation, message: id) }
        } else if !convo.isOldFormat {
            for member in audience(convo) { enqueue(.message(wire), to: member, message: id) }
        }
        save()
        kick()
    }

    /// A device has the message. A direct chat's tick follows its receipts (read ones too, when they're on). A group's mail
    /// is "sent" once it's in the mailbox: nobody confirms it one by one.
    func noteDelivery(of id: UUID, by fingerprint: String, read: Bool) {
        for c in data.conversations.indices {
            guard data.conversations[c].messages.contains(where: { $0.id == id && $0.isMine }) else { continue }
            guard data.conversations[c].kind == .direct || data.conversations[c].kind == .broadcast else { continue }
            // Only from someone the message went to: another contact who learned its id can't tick it, or stop it being
            // sent again to the person who hasn't got it.
            guard data.conversations[c].members.contains(fingerprint) else { return }
            setStatus(read ? .read : .delivered, for: [id])
            return
        }
    }

    /// A message rebuilt as it goes out again. It must carry everything the first copy did: a file's pointer that
    /// only travelled with the lost copy can't be fetched, so the retry would show as an empty bubble.
    func wireForResend(_ message: Message, in convo: Conversation) -> WireMessage {
        let mine = me(convo.persona)?.fingerprint
        let reply = message.reply.map {
            ReplyRef(id: $0.id, author: $0.author == "me" ? (mine ?? "") : $0.author,
                     snippet: $0.snippet, picture: $0.picture)
        }
        return WireMessage(id: message.id, conversation: sharedID(convo),
                           kind: convo.kind == .broadcast ? .direct : convo.kind,
                           text: message.text, image: message.image, voice: message.voice,
                           date: RelayClock.relay(message.date),
                           expiresIn: message.expiresAt == nil ? nil : convo.disappearAfter,
                           reply: reply, preview: message.preview, note: message.note,
                           mentions: message.mentions.isEmpty ? nil : message.mentions,
                           attachment: message.attachment?.kind == .file ? message.attachment : nil,
                           noForward: message.noForward, forwarded: message.forwarded)
    }

    /// Handshakes that got no answer (the other side didn't know us yet, say) are tried again. Not a request's: it
    /// went with the request and is answered when they accept, which can be days later. Starting it again would
    /// leave their answer to the first one with nothing to open it.
    private func retryStaleHandshakes() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-60)
        let patience = now.addingTimeInterval(-Self.keysPatience)
        let awake = [resumedAt, unlockedAt].compactMap { $0 }.max() ?? unlockedAt
        for i in data.contacts.indices where !data.contacts[i].awaitingAcceptance {
            // Never before the mailbox their answers come to has been looked in, since the ask and since this phone woke.
            // Coming back to Pulshade, housekeeping runs before the first check, and asking again then made the
            // answer already waiting there useless (it no longer matched): between two people who only share a group,
            // who meet on the first message, whoever reopened Pulshade more than a minute after writing never got
            // through.
            func looked(since date: Date?) -> Bool {
                guard let mailbox = data.contacts[i].receiveKey else { return true }
                return (mailboxChecked[mailbox] ?? .distantPast) > max(date ?? .distantPast, awake)
            }
            for d in data.contacts[i].devices.indices {
                // A device known from before this was kept starts its silence clock now.
                if data.contacts[i].devices[d].lastHeard == nil { data.contacts[i].devices[d].lastHeard = now }
                let link = data.contacts[i].devices[d]
                guard link.awaitingHello != true, !isDormant(contact: i, device: d) else { continue }
                let key = sessionKey(contact: i, device: d)
                // Its spare key is being fetched: asking for new keys now would cross it.
                if sparesFetching.contains(key) { continue }
                if link.session?.canSend == true { handshakeTries[key] = nil }
                // Asked and never answered: asked again less and less often (a minute, 5, 15, then hourly), so a
                // device that's gone isn't asked every minute for as long as this app is open.
                let tries = handshakeTries[key] ?? 0
                let backoff = now.addingTimeInterval(-Self.handshakeGaps[min(tries, Self.handshakeGaps.count - 1)])
                if link.session == nil && !link.pending.isEmpty && (link.handshake?.startedAt ?? .distantPast) < min(cutoff, backoff) {
                    guard looked(since: link.handshake?.startedAt) else { continue }
                    handshakeTries[key] = tries + 1
                    startHandshake(contact: i, device: d)
                } else if link.session == nil, let started = link.handshake?.startedAt, started < patience, tries == 0 || started < backoff {
                    guard looked(since: started) else { continue }
                    handshakeTries[key] = tries + 1
                    // Asked for new keys and never answered, with nothing waiting to send: the ask itself was lost
                    // (a relay restart, an app restart before it went). It used to wait forever, on "Setting up new
                    // keys", until you happened to write to them. Asked again, rarely, so a slow answer to the last
                    // one isn't overtaken.
                    startHandshake(contact: i, device: d)
                } else if let session = link.session, !session.canSend, link.handshake == nil {
                    // They answered our ask, and we can write on the new keys once their first message arrives.
                    // They send it straight away; when it never comes (lost, or stuck on their phone) the chat sat on
                    // "Setting up new keys" for good. After a while we ask again. The keys we have stay readable.
                    guard let since = keysAnsweredAt[key] else { keysAnsweredAt[key] = now; continue }
                    guard since < patience, looked(since: since) else { continue }
                    keysAnsweredAt[key] = nil
                    keepRecovered(session, key)
                    startHandshake(contact: i, device: d)
                }
            }
        }
    }

    /// When each mailbox was last fetched, as of the moment the fetch began. Memory only.
    @ObservationIgnored private var mailboxChecked: [Data: Date] = [:]

    /// How long to wait before asking a silent device for keys again, after each ask in turn.
    static var handshakeGaps: [TimeInterval] = [60, 300, 900, 3600]
    /// How many times each device has been asked for keys without answering, while the app is open.
    @ObservationIgnored private var handshakeTries: [String: Int] = [:]

    /// How long new keys wait for the other side before asking again. Long enough that an answer on its way over a
    /// slow Tor circuit isn't overtaken by a second ask (which would leave it with nothing to open it).
    static var keysPatience: TimeInterval = 5 * 60

    /// When a contact answered this device's ask for new keys, by contact and device. Memory only.
    @ObservationIgnored private var keysAnsweredAt: [String: Date] = [:]

    /// Device keys of contacts that came with a vouch from a device of theirs still trusted (`vouchKey`). Memory only.
    @ObservationIgnored private var vouchedPins: Set<String> = []

    /// The secrets of new devices' codes this device has sent the account to since it was opened. Memory only.

    /// One of a contact's devices by id. A device we only knew by its mailbox learns its id here.
    private func deviceIndex(_ i: Int, _ id: Data) -> Int? {
        if let d = data.contacts[i].devices.firstIndex(where: { $0.id == id }) { return d }
        if !id.isEmpty, let d = data.contacts[i].devices.firstIndex(where: { $0.id.isEmpty }) {
            data.contacts[i].devices[d].id = id
            return d
        }
        // An app from before device ids, whose only device has none either.
        if id.isEmpty, data.contacts[i].devices.count == 1, data.contacts[i].devices[0].id.isEmpty { return 0 }
        return nil
    }

    @discardableResult
    private func upsertDevice(_ i: Int, id: Data, sendID: Data, vouched: Bool = false) -> Int {
        let isSelf = data.contacts[i].isSelf
        // Known by this very id before now (not an old slot without one that `deviceIndex` names now).
        let knownByID = !id.isEmpty && data.contacts[i].devices.contains { $0.id == id }
        if let d = deviceIndex(i, id) {
            // A device of a friend's that now reads another mailbox is as good as a new device (anyone with their account's
            // keys could claim its id): said in the chat, and held again if you ask before new devices.
            if !isSelf, knownByID, data.contacts[i].devices[d].sendID != sendID, !data.contacts[i].devices[d].sendID.isEmpty {
                let hold = holdsNewDevices(contact: i, vouched: vouched)
                if hold { data.contacts[i].devices[d].unconfirmed = true }
                noteNewDevice(of: data.contacts[i], held: hold)
            }
            data.contacts[i].devices[d].sendID = sendID
            return d
        }
        // More than anyone owns: one makes way, so a contact can't grow the list without end. A held device goes first,
        // then the one heard from longest ago, so nobody can push a friend's real devices out by adding new ones.
        if data.contacts[i].devices.count >= Self.maxDevicesPerContact {
            let devices = data.contacts[i].devices
            let out = devices.firstIndex { $0.unconfirmed == true && !isSelf }
                ?? devices.indices.min { (devices[$0].lastHeard ?? .distantPast) < (devices[$1].lastHeard ?? .distantPast) } ?? 0
            data.contacts[i].devices.remove(at: out)
        }
        // A device we haven't met, from an account we already had one for: its messages from now on go to it as well,
        // so say so where the person would see it (their chat, or the list of your own devices).
        let announce = !data.contacts[i].devices.isEmpty && !id.isEmpty
        var link = DeviceLink(id: id, sendID: sendID)
        let hold = announce && !isSelf && holdsNewDevices(contact: i, vouched: vouched)
        if announce && (isSelf || hold) { link.unconfirmed = true }
        data.contacts[i].devices.append(link)
        if announce && !isSelf { noteNewDevice(of: data.contacts[i], held: hold) }
        // Your other devices hold it too.
        return data.contacts[i].devices.count - 1
    }


    // MARK: Unlinked devices

    /// The most unlinked devices remembered for one contact.
    static let maxRevoked = 32
    /// How long an unlinked device's session is kept, only to read a removal the other way round from it.
    static let revokedSessionLife: TimeInterval = 30 * 24 * 3600

    /// New devices of contact `i` wait until you allow them: you ask that for everyone, two of theirs unlinked each other,
    /// or their account unlinked a device and no device of theirs you still trust vouched for this one (`vouched`).
    private func holdsNewDevices(contact i: Int, vouched: Bool = false) -> Bool {
        data.security.holdNewDevices || data.contacts[i].contested != nil || (data.contacts[i].unlinked != nil && !vouched)
    }

    /// Whether `vouch` comes from a device of contact `i` this device still trusts (listed, allowed, with the keys pinned
    /// for it, never unlinked), for their device `device` with keys `pin`.
    private func vouchHolds(_ vouch: DeviceVouch, contact i: Int, device: Data, pin: Data) -> Bool {
        guard let pq = accountPQ(contact: i), vouch.by != device,
              let voucher = data.contacts[i].devices.first(where: { $0.id == vouch.by }), voucher.unconfirmed != true,
              voucher.keyPin == vouch.card.pin, !isRevoked(contact: i, id: vouch.by, pin: vouch.card.pin) else { return false }
        return vouch.checks(account: data.contacts[i].signingKey, accountPQ: pq, device: device, pin: pin)
    }

    private func vouchKey(contact i: Int, pin: Data) -> String {
        "\(data.contacts[i].persona?.uuidString ?? "main")|\(data.contacts[i].fingerprint)|\(pin.hex)"
    }

    /// A device contact `i`'s account unlinked, by its id or by its keys.
    private func isRevoked(contact i: Int, id: Data, pin: Data?) -> Bool {
        guard let gone = data.contacts[i].revoked else { return false }
        return gone.contains { (!id.isEmpty && $0.id == id) || (pin != nil && $0.pin == pin) }
    }

    /// Takes a device off contact `i` for good: its session, what waits for it, and its place in the list go, and it is
    /// remembered so it is never taken back (`RevokedDevice`). Its session is kept a while, read-only, when one of their
    /// devices said so (`by`), for the removal the other way round.
    private func revoke(_ id: Data, pin: Data?, by: Data?, contact i: Int) {
        guard !id.isEmpty else { return }
        let link = data.contacts[i].devices.first { $0.id == id }
        let key = "\(data.contacts[i].persona?.uuidString ?? "main")|\(data.contacts[i].fingerprint)|\(id.hex)"
        data.contacts[i].devices.removeAll { $0.id == id }
        unreadable[key] = nil
        keysAnsweredAt[key] = nil
        deadSpareFrom[key] = nil
        var gone = data.contacts[i].revoked ?? []
        if let k = gone.firstIndex(where: { $0.id == id }) {
            if gone[k].pin == nil { gone[k].pin = pin ?? link?.keyPin }
        } else {
            let keep = by != nil && !data.contacts[i].isSelf
            gone.append(RevokedDevice(id: id, pin: pin ?? link?.keyPin, by: by, at: Date(), session: keep ? link?.session : nil))
        }
        // Sessions past their time are let go; the oldest entries make way.
        for k in gone.indices where Date().timeIntervalSince(gone[k].at) > Self.revokedSessionLife { gone[k].session = nil }
        if gone.count > Self.maxRevoked { gone.removeFirst(gone.count - Self.maxRevoked) }
        data.contacts[i].revoked = gone
    }

    /// Contact `i`'s device `by` says their account unlinked these devices. It speaks over its own session, which only
    /// that device's keys (signed for by their account) could have opened, so this is their account and a device of
    /// theirs still on it. The devices are dropped and never taken back; they can only return with new device keys, as a
    /// new device. A device can't unlink itself this way (that's `deviceRemoved`).
    private func devicesUnlinked(_ ids: [Data], kept: [Data]? = nil, by: Data, contact i: Int) {
        guard !by.isEmpty, data.contacts[i].devices.contains(where: { $0.id == by && $0.unconfirmed != true }) else { return }
        var dropped = 0
        for id in ids.prefix(Self.maxDevicesPerContact) where !id.isEmpty && id != by && !isRevoked(contact: i, id: id, pin: nil) {
            if data.contacts[i].devices.contains(where: { $0.id == id }) { dropped += 1 }
            revoke(id, pin: nil, by: by, contact: i)
        }
        // From now on their new devices wait for a yes unless a device of theirs still trusted vouches for them
        // (`DeviceVouch`): the device they unlinked still has the account's keys.
        if ids.contains(where: { !$0.isEmpty && $0 != by }) { data.contacts[i].unlinked = Date() }
        // Their devices the one that unlinked doesn't know of (added by the one taken out, say) wait for a yes too.
        if let kept {
            let known = Set(kept.prefix(Self.maxDevicesPerContact)).union([by])
            for d in data.contacts[i].devices.indices where !data.contacts[i].devices[d].id.isEmpty
                && !known.contains(data.contacts[i].devices[d].id) && data.contacts[i].devices[d].unconfirmed != true {
                data.contacts[i].devices[d].unconfirmed = true
            }
        }
        if dropped > 0 { noteUnlinked(of: data.contacts[i]) }
        save()
    }

    /// Something arrived over the kept session of a device contact `i`'s account unlinked. Only one thing is read from
    /// it: that device unlinking the one that unlinked it. Then two of their devices each say the other is gone, and this
    /// device can't tell which is theirs and which was taken: both are dropped, the safety code counts as unchecked, and
    /// their next device is held until you allow it (`Contact.contested`). Nothing else from it is read.
    private func readRevoked(_ message: RatchetMessage, contact i: Int, entry r: Int) {
        guard var session = data.contacts[i].revoked?[r].session, let gone = data.contacts[i].revoked?[r],
              Date().timeIntervalSince(gone.at) < Self.revokedSessionLife,
              let plain = try? session.decrypt(message) else { return }
        data.contacts[i].revoked?[r].session = session
        guard let inner = try? Payload.fromWire(plain), case let .devicesUnlinked(ids, _) = inner,
              let by = gone.by, ids.contains(by) else { return }
        revoke(by, pin: nil, by: gone.id, contact: i)
        for k in (data.contacts[i].revoked ?? []).indices { data.contacts[i].revoked?[k].session = nil }
        data.contacts[i].contested = Date()
        data.contacts[i].verified = false
        let contact = data.contacts[i]
        if !contact.hidden, !contact.awaitingAcceptance {
            let convo = startConversation(kind: .direct, title: "", members: [contact.fingerprint], persona: .some(contact.persona))
            if let c = index(of: convo.id) {
                data.conversations[c].messages.append(Message(
                    sender: "system",
                    text: "Two of \(contact.displayName)'s devices removed each other, so neither gets your messages now. "
                        + "Check their safety code with them; a new device of theirs waits until you allow it.",
                    date: Date()))
            }
        }
        save()
    }

    /// A line in the chat with a contact whose account unlinked a device: it gets nothing from you from now on.
    private func noteUnlinked(of contact: Contact) {
        guard !contact.hidden, !contact.awaitingAcceptance else { return }
        let convo = startConversation(kind: .direct, title: "", members: [contact.fingerprint], persona: .some(contact.persona))
        guard let c = index(of: convo.id) else { return }
        data.conversations[c].messages.append(Message(sender: "system", text: "\(contact.displayName) removed a device from their account. "
                                                      + "It no longer gets your messages.", date: Date()))
    }

    /// A line in the chat with a contact whose account just added a device we hadn't seen. Their messages and ours
    /// reach it from now on, as with any device of theirs, which matters most when it isn't theirs.
    private func noteNewDevice(of contact: Contact, held: Bool) {
        // A friend always has a chat to say it in, even one you haven't written in yet. Someone known only from a
        // group has none, and isn't told about.
        guard !contact.hidden, !contact.awaitingAcceptance else { return }
        let convo = startConversation(kind: .direct, title: "", members: [contact.fingerprint], persona: .some(contact.persona))
        guard let c = index(of: convo.id) else { return }
        data.conversations[c].messages.append(Message(sender: "system", text: "\(contact.displayName)'s account added a new device"
                                                      + (held ? ". Your messages wait until you allow it." : ""), date: Date()))
    }

    /// The most kept waiting for a friend's device you haven't allowed, and the most kept from it.
    static let maxHeldPending = 500
    static let maxHeldMail = 200
    /// The most held from a contact's unconfirmed devices, across all of them.
    static let maxHeldMailBytes = 16 * 1024 * 1024

    /// Keeps one sealed envelope from an unconfirmed device, dropping the oldest across this contact's devices to
    /// stay within `maxHeldMailBytes`. Confirmed devices hold nothing here and are never touched.
    func holdDeviceMail(_ mail: HeldMail, contact i: Int, device d: Int) {
        var held = data.contacts[i].devices[d].heldMail ?? []
        // The relay may hand the same one over twice.
        if !held.contains(where: { $0.blob == mail.blob }) { held.append(mail) }
        var dropped = false
        if held.count > Self.maxHeldMail {
            held.removeFirst(held.count - Self.maxHeldMail)
            dropped = true
        }
        data.contacts[i].devices[d].heldMail = held.isEmpty ? nil : held
        if trimHeldMail(contact: i) { dropped = true }
        if dropped { noteHeldMailDropped(contact: i) }
    }

    /// Drops the oldest sealed envelopes from a contact's unconfirmed devices until the total fits.
    private func trimHeldMail(contact i: Int) -> Bool {
        func total() -> Int {
            data.contacts[i].devices.reduce(0) { sum, device in
                sum + (device.heldMail ?? []).reduce(0) { $0 + $1.blob.count }
            }
        }
        var dropped = false
        while total() > Self.maxHeldMailBytes {
            var oldest: (device: Int, index: Int, at: Date)?
            for d in data.contacts[i].devices.indices {
                for (index, mail) in (data.contacts[i].devices[d].heldMail ?? []).enumerated() {
                    let at = mail.at ?? .distantPast
                    if oldest == nil || at < oldest!.at { oldest = (d, index, at) }
                }
            }
            guard let oldest else { break }
            data.contacts[i].devices[oldest.device].heldMail?.remove(at: oldest.index)
            if data.contacts[i].devices[oldest.device].heldMail?.isEmpty == true {
                data.contacts[i].devices[oldest.device].heldMail = nil
            }
            dropped = true
        }
        return dropped
    }

    /// Tells you once per contact that held mail was discarded; not once per envelope.
    private func noteHeldMailDropped(contact i: Int) {
        let c = data.contacts[i]
        let key = "\(c.fingerprint)|\(c.persona?.uuidString ?? "main")"
        guard !c.hidden, !c.awaitingAcceptance, !heldMailNoted.contains(key) else { return }
        heldMailNoted.insert(key)
        let convo = startConversation(kind: .direct, title: "", members: [c.fingerprint], persona: .some(c.persona))
        guard let j = index(of: convo.id) else { return }
        withAnimation(.snappy) {
            data.conversations[j].messages.append(Message(
                sender: "system",
                text: "Some messages from \(c.displayName)'s new device were discarded to free space.",
                date: Date()))
        }
    }

    /// A friend's devices that their account added while "ask before new devices" was on, not allowed yet.
    func heldDevices(of fingerprint: String, persona: UUID?) -> Int {
        guard let i = contactIndex(fingerprint, persona), !data.contacts[i].isSelf else { return 0 }
        return data.contacts[i].devices.filter { $0.unconfirmed == true }.count
    }

    /// Lets a friend's new devices have your messages: what waited for them goes now.
    func allowHeldDevices(of fingerprint: String, persona: UUID?) {
        guard let i = contactIndex(fingerprint, persona), !data.contacts[i].isSelf else { return }
        for d in data.contacts[i].devices.indices where data.contacts[i].devices[d].unconfirmed == true { release(contact: i, device: d) }
        // Your other devices let it through too.
        save()
    }

    /// A held friend's device allowed (here or on another of your devices): what waited for it goes, and what it sent
    /// meanwhile is read now, in order.
    private func release(contact i: Int, device d: Int) {
        data.contacts[i].devices[d].unconfirmed = false
        let waiting = data.contacts[i].devices[d].heldMail ?? []
        data.contacts[i].devices[d].heldMail = nil
        sendPending(contact: i)
        let fp = data.contacts[i].fingerprint, persona = data.contacts[i].persona, id = data.contacts[i].devices[d].id
        var again: [HeldMail] = []
        for mail in waiting where receive(RelayEnvelope(receiveKey: mail.receiveKey, id: 0, blob: mail.blob)) == .retry { again.append(mail) }
        // Anything that couldn't be read yet stays, sealed, and is tried with the next one allowed.
        if !again.isEmpty, let c = contactIndex(fp, persona), let k = data.contacts[c].devices.firstIndex(where: { $0.id == id }) {
            data.contacts[c].devices[k].heldMail = again
        }
    }

    /// Whether a hello was sent before the other device answered ours: the two started at once, ours won and theirs
    /// got here after our session was already open. Taking it would replace that session with one they no longer have
    /// (they gave theirs up to answer ours), and nothing after would open on either side.
    private func hello(_ sentAt: Date, crossedOurs link: DeviceLink) -> Bool {
        guard link.session != nil, let answered = believable(link.answeredAt) else { return false }
        return sentAt <= answered
    }

    /// Whether a hello was sent before the one behind the keys in use: the same device asked again since (a phone that
    /// woke and asked anew), and both asks got here, the older one last (held back on the way, or kept to read later).
    /// Taking it would leave this side on keys the other has moved on from, and what each then wrote couldn't be read by
    /// the other: between two people who only share a group, each saw only their own messages. Clocks here are whole
    /// seconds, so only strictly earlier counts, and only within the time the relay keeps mail (a phone whose clock was
    /// set back can still start over).
    private func hello(_ sentAt: Date, overtakenIn link: DeviceLink) -> Bool {
        guard link.session != nil, let accepted = believable(link.acceptedHelloAt) else { return false }
        return sentAt < accepted && accepted.timeIntervalSince(sentAt) < Self.replayWindow
    }

    /// A time a device stamped on something it sent, as far as it can be trusted for ordering: one more than a couple of
    /// minutes ahead of the relay's clock (a clock set wrong, or an older build) would make everything after it look
    /// older, so new keys would be turned away for good. Such a time is ignored.
    func believable(_ date: Date?) -> Date? {
        return date.flatMap { $0 <= RelayClock.now.addingTimeInterval(120) ? $0 : nil }
    }

    /// Whether this device has lately failed to open what a device of theirs sent: the keys in use don't work, so
    /// there's nothing for the rules that keep them from being replaced to protect.
    private func keysBroken(contact i: Int, device d: Int) -> Bool {
        unreadable[sessionKey(contact: i, device: d)] != nil
    }

    /// How long this device's own ask for keys may go unanswered before it gives way to an ask of theirs, and before it
    /// nudges them (see `nudgeStuckDevices`).
    static let askPatience: TimeInterval = 120
    static let nudgeAfter: TimeInterval = 300

    /// Whether to take their ask over this device's own: ours has had no answer for a while, so they aren't taking it
    /// (an app that turns it down, or keys that went out of step), and theirs is the way through.
    private func yields(to sentAt: Date, contact i: Int, device d: Int) -> Bool {
        // Only with proof the keys are broken (something of theirs couldn't be opened): two asks that merely crossed are
        // settled by the usual rule, or both sides would give way and cross again.
        guard keysBroken(contact: i, device: d), let started = data.contacts[i].devices[d].handshake?.startedAt,
              Date().timeIntervalSince(started) > Self.askPatience else { return false }
        // Ours is taken back if it hasn't gone, so the two don't cross again.
        withdrawHello(contact: i, device: d)
        return true
    }

    /// Nudges, by device, for the current ask: how many, and when last. Memory only.
    @ObservationIgnored private var nudges: [String: (ask: Data, count: Int, at: Date)] = [:]

    /// A device that hasn't answered this one's ask for keys in a while is sent something sealed for it that its keys
    /// can't open. Every Pulshade, older builds included, answers that by asking for new keys itself, and this device
    /// takes that ask (`yields`). So two phones whose keys went out of step find their way back on their own, even when
    /// the other phone's app turns this one's asks down. A few times per ask, and only the newest waits on the relay.
    private func nudgeStuckDevices() {
        let now = Date()
        for i in data.contacts.indices where !data.contacts[i].isSelf && !data.contacts[i].awaitingAcceptance {
            for d in data.contacts[i].devices.indices {
                let link = data.contacts[i].devices[d]
                let key = sessionKey(contact: i, device: d)
                // Only where there's proof the keys are broken: something of theirs that couldn't be opened.
                guard let ask = link.handshake, link.sendID.count == 32, now.timeIntervalSince(ask.startedAt) > Self.nudgeAfter,
                      unreadable[key] != nil else { continue }
                let held = nudges[key]
                let count = held?.ask == ask.ephemeral ? held!.count : 0
                guard count < 3, now.timeIntervalSince(held?.at ?? .distantPast) > Self.nudgeAfter else { continue }
                nudges[key] = (ask.ephemeral, count + 1, now)
                let header = RatchetHeader(dh: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, pn: 0, n: 0, v: RatchetHeader.version)
                seal(.ratchet(RatchetMessage(header: header, ciphertext: .random(64))), contact: i, device: d, collapse: "nudge")
            }
        }
    }

    /// Whether a hello was sent before this device answered that device's spare key: it was overtaken, and taking it
    /// would replace the session the answer opened with one they will drop.
    private func hello(_ sentAt: Date, crossedSpareOf link: DeviceLink) -> Bool {
        guard link.session != nil, let taken = link.spareTakenAt else { return false }
        // Strictly before, in whole seconds: the time a message says it was sent is cut to the second, and their ask
        // for new keys because our answer named a spare they no longer have can come in the very same second, and must
        // be taken. (Compared with the exact moment, an ask sent half a second after it read as sent before.)
        return sentAt < Date(timeIntervalSince1970: taken.timeIntervalSince1970.rounded(.down))
    }

    /// When two devices start a handshake with each other at once, the lower (fingerprint, device) wins.
    private func myHandshakeWins(me: String, persona: UUID?, them: String, theirDevice: Data) -> Bool {
        (me + deviceID(for: persona).hex) < (them + theirDevice.hex)
    }

    /// This device's id as one persona's contacts see it. Each persona gets its own, so someone who knows
    /// two of your personas can't match them up by the device they write from.
    func deviceID(for persona: UUID?) -> Data { Self.deviceID(data.deviceID, for: persona) }

    /// The id a device with main id `main` writes to one persona's contacts with.
    static func deviceID(_ main: Data, for persona: UUID?) -> Data {
        guard let persona else { return main }
        let code = HMAC<SHA256>.authenticationCode(for: Data("pulshade.device.\(persona.uuidString)".utf8),
                                                   using: SymmetricKey(data: main))
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
        if Date() >= nextAnnouncementCheck {
            nextAnnouncementCheck = Date().addingTimeInterval(60)
            Task { await refreshAnnouncements(waiting: false) }
        }
    }

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
    /// Which circuit each sending lane is on now (`SendLanes`). Memory only.
    @ObservationIgnored private var sendLanes = SendLanes()

    /// Mailboxes grouped by relay and by who they belong to. Each persona, each public profile's request
    /// mailbox and the reports mailbox is its own lane, so the relay can't tell from one request that
    /// they're the same person. Over Tor a persona's one-to-one mailboxes are spread over a few lanes, and every shared
    /// group is read on its own (see `Lanes`).
    func currentLanes() -> [Lane: Set<Data>] {
        func name(_ persona: UUID?) -> String { persona?.uuidString ?? "main" }
        let split = isolatesLanes
        let salt = laneSalt
        func fetchLane(_ persona: UUID?, _ key: Data) -> String {
            split ? Lanes.fetchLane(persona: persona, bucket: Lanes.bucket(of: key, salt: salt)) : name(persona)
        }
        var lanes: [Lane: Set<Data>] = [Lane(relay: nil, name: "main"): []]
        for c in data.contacts { for key in Self.mailboxes(of: c) { lanes[Lane(relay: c.relay, name: fetchLane(c.persona, key)), default: []].insert(key) } }
        for invite in data.invites {
            let lane = invite.isPublic ? "public-" + name(invite.persona) : fetchLane(invite.persona, invite.receiveKey)
            lanes[Lane(relay: invite.relay, name: lane), default: []].insert(invite.receiveKey)
        }
        // Shared groups are read on lanes of their own over Tor; otherwise they ride along on their persona's lane, which
        // a persona whose only mail is in groups still needs.
        let groups = liveGroups
        for convo in groups {
            let lane = Lane(relay: nil, name: groupLane(convo, among: groups.count))
            if lanes[lane] == nil { lanes[lane] = [] }
        }
        return lanes
    }

    /// Shared groups still in use on this device.
    private var liveGroups: [Conversation] { data.conversations.filter { $0.shared.map { !$0.gone } == true } }

    /// The lane a shared group is read on: over Tor, its own while there are at most `Lanes.maxGroupLanes`, otherwise one
    /// of that many shared only with other groups; over a direct connection, its persona's.
    func groupLane(_ convo: Conversation, among count: Int) -> String {
        guard isolatesLanes else { return convo.persona?.uuidString ?? "main" }
        guard count > Lanes.maxGroupLanes else { return "group|" + convo.id.uuidString }
        return "groups/" + String(Lanes.bucket(of: Data(convo.id.uuidString.utf8), salt: laneSalt, count: Lanes.maxGroupLanes))
    }

    /// Whether traffic is spread over separate lanes (`Lanes`). Over Tor each lane is a circuit of its own; over a direct
    /// connection they all come from one address, so spreading buys nothing and only uses up the relay's allowance of
    /// waiting fetches for that address.
    var isolatesLanes: Bool {
        #if DEBUG
        if isolateLanesForTests { return true }
        #endif
        return reachable(nil).flatMap(URL.init(string:)).map(Tor.uses) ?? false
    }
    #if DEBUG
    /// Tests run without Tor: this has them use the lanes Tor would.
    @ObservationIgnored var isolateLanesForTests = false
    #endif

    /// Which of a persona's fetch lanes each mailbox goes on: made from the account's seed, so every device of the account
    /// (and the account restored) spreads them the same way, and the relay never sees one mailbox read beside different
    /// others. Without an identity, nothing is fetched anyway.
    private var laneSalt: Data {
        guard let seed = identity?.seed else { return Data(count: 32) }
        return Data(HMAC<SHA256>.authenticationCode(for: Data("pulshade.lanes.v1".utf8), using: SymmetricKey(data: seed)))
    }

    /// One lane's loop: check, wait a random moment, check again, until the lane goes away or Pulshade locks. A lane that
    /// goes away (a group left, say) lets go of its connections.
    private func pollLane(_ lane: Lane) async {
        defer {
            polling.remove(lane)
            if currentLanes()[lane] == nil { RelayClient.retire(lane: lane.name) }
        }
        let owner = identity?.fingerprint
        // The first check waits its turn too (see `staggerLanes`): main at once, the rest each at their own moment.
        if trafficShaping, laneResumeAt[lane] == nil { laneResumeAt[lane] = Date().addingTimeInterval(resumeDelay(lane, urgent: false)) }
        while !Task.isCancelled, phase == .unlocked, identity?.fingerprint == owner {
            if let at = laneResumeAt[lane], at > Date() {
                try? await Task.sleep(for: .seconds(min(at.timeIntervalSinceNow, 60)))
                continue
            }
            guard let keys = currentLanes()[lane] else { return }
            let waited = await poll(lane, keys: keys)
            // A fetch that waited on the relay already spent its time there: go straight back, with a moment's
            // jitter. One that didn't (an older relay, an error, an empty lane) waits its turn as before.
            try? await Task.sleep(for: .seconds(waited ? Double.random(in: 0.1...0.6) : Double.random(in: 1.5...3)))
        }
    }

    /// When each lane may next ask the relay, after a reconnect. Memory only.
    @ObservationIgnored private var laneResumeAt: [Lane: Date] = [:]

    private func resumeDelay(_ lane: Lane, urgent: Bool) -> TimeInterval {
        let mainPersona = lane.name == "main" || lane.name.hasPrefix("main/")
        return Lanes.resumeDelay(lane: lane.name, mainPersona: mainPersona, urgent: urgent)
    }

    /// After coming back to the front, a refresh or an unlock: each lane starts again at its own random moment rather
    /// than all in the same second, which would show the relay they're one phone's. `urgent` (a wake-up push, waiting
    /// for its message) keeps the spread to a few seconds.
    private func staggerLanes(urgent: Bool = false) {
        guard trafficShaping else { return }
        let now = Date()
        laneResumeAt = Dictionary(uniqueKeysWithValues: currentLanes().keys.map { ($0, now.addingTimeInterval(resumeDelay($0, urgent: urgent))) })
    }

    /// How long a lane's fetch asks the relay to wait for mail. Tests use plain checks, at a steady beat.
    private var fetchWait: Int { trafficShaping ? 25 : 0 }

    /// Fetches a lane's mailboxes once (or, for an empty main lane, just checks the relay is there). True when
    /// the relay held it open waiting for mail, so the lane needn't pause before the next one.
    @discardableResult
    private func poll(_ lane: Lane, keys: Set<Data>) async -> Bool {
        guard let client = client(lane.relay, lane: lane.name) else { return false }
        let owner = identity?.fingerprint
        let hasGroups = !groupCursors(for: lane).isEmpty
        if keys.isEmpty && !hasGroups {
            if lane.name == "main" { noteRelay(reached: await client.health()) }
            return false
        }
        let mine = keys.subtracting(fetching)
        guard !mine.isEmpty || hasGroups else { return false }
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
                // Group mailboxes are read from where each was left, alongside the lane's own.
                let cursors = groupCursors(for: lane)
                let (envelopes, groupMail, more) = try await client.fetch(Array(mine), groups: cursors.map { ($0.key, $0.after) }, wait: wait)
                if lane.relay == nil { noteRelay(reached: true) }
                // Whatever is handled below comes before any housekeeping that reads this.
                for key in mine { mailboxChecked[key] = started }
                // Mail, or an empty answer after a real wait. An instant empty one means the relay doesn't wait.
                let waited = wait > 0 && (!envelopes.isEmpty || !groupMail.isEmpty || Date().timeIntervalSince(started) > Double(wait) / 2)
                if identity?.fingerprint == owner, !groupMail.isEmpty {
                    for mail in groupMail {
                        guard let at = cursors.first(where: { $0.key == mail.receiveKey }) else { continue }
                        receiveGroupMail(mail, convo: at.convo, epoch: at.epoch)
                    }
                    askDueChains()
                    lastMailReceived = Date()
                    save()
                }
                // Read to the end: the posts this device made that haven't come back by now can be posted again.
                if !more, identity?.fingerprint == owner { noteGroupsFetched(cursors, at: started) }
                // More group mail than fitted: straight back for the rest.
                if more, envelopes.isEmpty { if wait > 0 { return true } else { continue } }
                guard identity?.fingerprint == owner, !envelopes.isEmpty else { return waited }
                // Only what this device is finished with comes off the relay. One it can't use yet (a device it
                // hasn't met, a chat whose details haven't arrived) stays for the next check instead of being lost.
                var done: [RelayEnvelope] = []
                var deferred = false
                for envelope in envelopes {
                    let result = receive(envelope)
                    #if DEBUG
                    receiveResultTap?(result)
                    #endif
                    switch result {
                    case .retry:
                        // Held only briefly. Past that it isn't waiting on a hello or a roster, it's from someone
                        // we don't know, and keeping it would have it fetched again on every check (and crowd out
                        // newer mail: the relay hands out the oldest first). Without a deposit time, don't hold it.
                        if let at = envelope.deposited, Date().timeIntervalSince(at) < Self.deferredMailLimit {
                            deferred = true
                        } else {
                            done.append(envelope)
                        }
                    case .handled, .junk: done.append(envelope)
                    }
                }
                lastMailReceived = Date()
                deposited = nil
                // When every envelope was deferred, nothing changed: don't rewrite the whole vault just to
                // acknowledge nothing, and leave the mail where it is.
                if !done.isEmpty {
                    save()
                    // The relay forgets everything it acknowledges. Write first, so a crash or a suspended app
                    // between the answer and the disk can't take the message down with it. This one blocks until the
                    // write lands: `settleSavesAsync` (waits off the main actor) let a second check start in the gap
                    // and made the relay-flow video test fail under load, so it isn't used here yet.
                    settleSaves()
                    try await client.ack(done)
                }
                // A lane left holding only mail it couldn't use isn't in a hurry: take the ordinary beat.
                if wait > 0 { return waited && !deferred }
            }
            return false
        } catch {
            if lane.relay == nil { noteRelay(reached: false) }
            return false
        }
    }

    /// Sending, retries and receipts, every couple of seconds.
    private func housekeep() async {
        drainHelperInbox()
        tendSharedGroups()
        tendJoinLinks()
        tendPublicNamesNow()
        tendStoryUpload()
        refreshPush()
        watchTor()
        watchStall()
        if pruneHandshakeSecrets() { save() }
        resumeKeyFetch()
        retryStaleHandshakes()
        retryUnreadable()
        nudgeStuckDevices()
        refreshStalledPostQuantum()
        tendSpares()
        tendBlobSpends()
        tendMailboxMoves()
        tendMailboxes()
        // Held follows whose person's keys came some other way (another of your devices, say).
        for c in data.contacts where c.followLater != nil && c.pq != nil { sendFollowsLater(c.fingerprint, persona: c.persona) }
        // An app left open for days would otherwise keep every envelope digest it ever saw. Only assign when
        // something has actually aged out: writing redraws every view that reads the data.
        let stale = Date().addingTimeInterval(-Self.replayWindow)
        let staleSeen = Date().addingTimeInterval(-Self.seenRetention)
        if data.seenEnvelopes.contains(where: { $0.value <= staleSeen }) {
            data.seenEnvelopes = data.seenEnvelopes.filter { $0.value > staleSeen }
        }
        if data.sentDigests.contains(where: { $0.value.at <= stale }) {
            data.sentDigests = data.sentDigests.filter { $0.value.at > stale }
        }
        resendAfterRestart()
        resendOverdueMessages()
        noteUnsent()
        refreshHelper()
        resendUnconfirmedStories()
        resendUnconfirmedViews()
        finishDepartures()
        // Only written when something is stale: assigning redraws every view that reads the data.
        let clipCutoff = Date().addingTimeInterval(-(StoryLifetime.twoDays.rawValue + 3600))
        if data.clipParts.contains(where: { $0.value.date <= clipCutoff }) {
            data.clipParts = data.clipParts.filter { $0.value.date > clipCutoff }
        }
        // Stalled videos that never completed: their asking bookkeeping goes with the story's life.
        if clipActivity.contains(where: { $0.value <= clipCutoff }) {
            clipActivity = clipActivity.filter { $0.value > clipCutoff }
        }
        if clipAsks.contains(where: { $0.value.at <= clipCutoff }) {
            clipAsks = clipAsks.filter { $0.value.at > clipCutoff }
        }
        refileOldClipParts()
        askForStalledClips()
        sendDueReceipts()
        drainStoryBacklog()
        // A long upload mustn't hold up everything else housekeeping does, so sending runs on its own; the tests
        // send and then look, so there it is waited for.
        if trafficShaping { Task { await flush() } } else { await flush() }
        // Sending lanes are not kept warm (a lane pinged every minute links everything sent on it, burst to burst): one
        // that has gone quiet is let go of, and the next send builds a fresh one (`SendLanes`).
        for lane in sendLanes.takeIdle() { RelayClient.retire(lane: lane) }
    }

    // MARK: Connection health

    /// Messages and stories still waiting on this device to reach the relay, and how long the oldest has waited.
    var waitingToSend: (count: Int, oldest: Date?) {
        let items = data.outbox.filter { $0.ephemeral != true }
        return (items.count, items.compactMap(\.queued).min())
    }

    /// Why a waiting envelope didn't go the last time it was tried. Memory only, for the Network page.
    enum SendHold: String {
        case unreachable = "The relay didn't answer"
        case full = "Their mailbox on the relay is full"
        case slowUpload = "Upload timed out"
        case busy = "The relay asked this connection to slow down"
        case refused = "The relay refused it"
    }

    private(set) var sendHolds: [UUID: SendHold] = [:]
    /// Times the relay has refused each envelope outright. A few refusals and it never will take it.
    @ObservationIgnored private var refusals: [UUID: Int] = [:]

    /// What's waiting to send, for the Network page: what kind of thing it is, why it's waiting, and who it's for.
    struct WaitingReport {
        var kinds: [(String, Int)] = []
        var reasons: [(String, Int)] = []
        var people: [(String, Int)] = []
        var mailboxes = 0
    }

    var waitingReport: WaitingReport {
        let items = data.outbox.filter { $0.ephemeral != true }
        func tally(_ names: [String]) -> [(String, Int)] {
            Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        }
        let kinds = items.map { item -> String in
            if item.story != nil { return "Story pieces" }
            if item.viewReport != nil { return "Story views" }
            if item.rings == true { return "Calls" }
            if item.message != nil { return item.isBulk ? "Photos and videos" : "Messages" }
            if item.wakes == true { return "Friend requests" }
            return "Receipts and updates"
        }
        let reasons = items.map { item -> String in
            if sendingIDs.contains(item.id) { return "Sending now" }
            if reachable(item.relay) == nil { return "Addressed to a relay this app can't use" }
            if let hold = sendHolds[item.id] { return hold.rawValue }
            if mailboxBackoff[item.sendID] != nil { return SendHold.full.rawValue }
            return "Not tried yet"
        }
        // Who it's for, by the mailbox it goes to: one of a contact's devices, or one of your own.
        var owners: [Data: String] = [:]
        for c in data.contacts {
            let name = c.isSelf ? "Your other devices" : displayName(c.fingerprint)
            for d in c.devices { owners[d.sendID] = name }
        }
        return WaitingReport(kinds: tally(kinds), reasons: tally(reasons),
                             people: Array(tally(items.map { owners[$0.sendID] ?? "Someone no longer in your contacts" }).prefix(5)),
                             mailboxes: Set(items.map(\.sendID)).count)
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
            await MainActor.run { if let self, self.phase == .unlocked { self.resync() } }
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
                        if self.phase == .unlocked { self.resync() }
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
        if reached { resync() }
    }

    /// Everything checked again: each lane at its own moment (`staggerLanes`), the main one at once. In tests, which have
    /// no lanes running on their own, one full round.
    private func resync(urgent: Bool = false) {
        if trafficShaping { staggerLanes(urgent: urgent) } else { Task { await syncOnce() } }
    }

    /// The check the app makes by itself. Gentler: a connection busy with a big upload answers slowly, which isn't
    /// the same as being dead, so a fresh route is only tried if the check still hasn't answered after 15 seconds.
    /// Throwing the route away every few seconds, as the first version did, left Tor no time to connect at all.
    private func autoCheck() async {
        guard !autoChecking, let client = client(nil) else { return }
        autoChecking = true
        defer { autoChecking = false }
        // Once the strip says it can't reach the server, as quick as the Retry button: waiting longer is for a
        // connection that's only busy, which doesn't show the strip.
        let reached = await Self.reach(client, patience: relayUnreachable ? 5 : 15)
        if !reached { lastRelayContact = .distantPast }
        noteRelay(reached: reached)
        if reached { kick() }
    }

    @ObservationIgnored private var autoChecking = false

    /// When the last time the app checked the connection by itself.
    @ObservationIgnored private var lastAutoRetry = Date.distantPast

    /// What pressing "Check connection" does, done for you, over Tor or not: when something has waited to send for 15 seconds,
    /// or the relay has been silent for 40 (a fetch waits up to 25 for mail, so a quiet but healthy connection can't
    /// be told from a dead one sooner), look again on fresh routes and then send and fetch at once. A route that died
    /// quietly would take a minute to time out on its own. Every 5 seconds while it lasts (a check still under way is
    /// never doubled up), and never in the background or
    /// right after a launch or a new network.
    private func watchStall() {
        #if os(iOS)
        if backgroundedAt != nil { return }
        #endif
        guard phase == .unlocked, trafficShaping, !retryingRelay, !autoChecking else { return }
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
    /// `parts` are the requests they went in (`pushParts`), so what's taken off later goes in the same company.
    private var pushTold: (token: String, keys: Set<Data>, parts: [Set<Data>], sound: Bool, tone: MessageTone, voip: String?, at: Date)?
    private var pushBusy = false
    /// After a registration didn't go through, nothing more is asked of the relay before this (`pushRetryWait`).
    private var pushRetryAt: Date?
    /// Where push stands, in words, for Settings: off, waiting for Apple, refused by the relay, or registered.
    private(set) var pushStatus = ""
    /// Asked Apple for a token this launch, so it isn't asked again every couple of seconds.
    private var pushAsked = false
    /// A device token to take off the relay as soon as Apple hands this launch one, after a wipe, a panic passcode
    /// or a decoy, where there's no account to say whose mailboxes they were.
    private var pushForgetPending = false

    /// The mailboxes wake-ups cover: the main identity's, without those of people you've blocked or whose chat you've
    /// muted. Anyone who knows a mailbox can write to it, so a banner for it would otherwise be theirs to ring.
    func pushKeys() -> Set<Data> { Set(pushParts().flatMap { $0 }) }

    /// The same mailboxes, in the parts they're registered in, each with a request of its own on a connection of its own
    /// (`refreshPush`): your @handle's request mailbox, your one-to-one mailboxes spread as they are for fetching
    /// (`Lanes.bucket`), and each shared group on its own. So no one request names everything this phone is woken for.
    /// (The relay still holds one token for them all: see docs/push-notifications.md.)
    /// Only where lanes are kept apart (`isolatesLanes`, over Tor). Over a direct connection every request comes from the
    /// same address, so splitting hides nothing, and a part per group soon used up the relay's 60 wake-up requests an hour
    /// for that address (renewed every 15 minutes): there it is one part, sent 256 mailboxes at a time as before build 22.
    func pushParts() -> [Set<Data>] {
        var parts: [Set<Data>] = []
        // Friend requests arrive at the public mailbox of your @handle, which has a lane of its own so the relay can't
        // tell it belongs to the same person.
        if data.security.pushRequests {
            let handle = Set(data.invites.filter { $0.isPublic && $0.persona == nil && $0.relay == nil }.map(\.receiveKey))
            if !handle.isEmpty { parts.append(handle) }
        }
        var direct: [Int: Set<Data>] = [:]
        let salt = laneSalt
        for c in data.contacts where c.persona == nil && c.relay == nil {
            let muted = data.conversations.contains { $0.kind == .direct && $0.persona == nil && $0.members == [c.fingerprint] && $0.muted }
            if muted || data.blocked.contains(c.fingerprint) { continue }
            for key in Self.mailboxes(of: c) { direct[Lanes.bucket(of: key, salt: salt), default: []].insert(key) }
        }
        for invite in data.invites where !invite.isPublic && invite.persona == nil && invite.relay == nil {
            direct[Lanes.bucket(of: invite.receiveKey, salt: salt), default: []].insert(invite.receiveKey)
        }
        parts += direct.keys.sorted().compactMap { direct[$0] }
        // Shared groups wake the phone through their current mailbox, unless muted.
        for convo in data.conversations where convo.persona == nil && !convo.muted {
            if let shared = convo.shared, !shared.gone, let epoch = shared.current { parts.append([epoch.receiveKey]) }
        }
        parts = parts.filter { !$0.isEmpty }
        guard isolatesLanes else {
            let all = parts.reduce(into: Set<Data>()) { $0.formUnion($1) }
            return all.isEmpty ? [] : [all]
        }
        return parts
    }

    /// The requests that take mailboxes no longer covered (`keys`) off the relay: those of each part they were registered
    /// in go together, 256 at a time, since that request named them together anyway. (One request per mailbox used up the
    /// relay's allowance as quickly as the parts did.)
    static func pushRemovals(told parts: [Set<Data>], keys: Set<Data>) -> [[Data]] {
        parts.flatMap { part -> [[Data]] in
            let gone = part.subtracting(keys).sorted { $0.hex < $1.hex }
            return stride(from: 0, to: gone.count, by: 256).map { Array(gone[$0..<min($0 + 256, gone.count)]) }
        }
    }

    /// How long to leave the relay alone after a registration didn't go through. Refused (over its 60 an hour, say): 15
    /// to 60 minutes, at random; trying again at every turn of the upkeep, every couple of seconds, only kept it over.
    /// Not reached at all, nothing was counted, so sooner: 1 to 5 minutes. A registration still in place lasts days on the
    /// relay, so a wait costs no wake-ups.
    static func pushRetryWait(refused: Bool) -> TimeInterval {
        refused ? .random(in: 900...3600) : .random(in: 60...300)
    }

    /// The pause between wake-up registrations' parts.
    static let pushPartGap: ClosedRange<Double> = 1...20

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
            if let wait = pushRetryAt, Date() < wait { return }
            let sound = data.security.notificationSound
            let tone = data.security.messageTone
            let voip = CallRinger.voipToken
            if let told = pushTold, told.token == token, told.keys == keys, told.sound == sound, told.tone == tone, told.voip == voip,
               Date().timeIntervalSince(told.at) < 15 * 60 { return }
            // Mailboxes registered before and not now (a contact blocked or muted since) are taken off the relay.
            let removals = Self.pushRemovals(told: pushTold?.parts ?? [], keys: keys)
            let registered = pushParts()
            let parts = registered.shuffled()
            let shaping = trafficShaping
            pushBusy = true
            Task {
                defer { pushBusy = false }
                // The relay forgets registrations when it restarts and can't say so, so they're renewed every 15 minutes.
                let check = Lanes.once("push")
                defer { RelayClient.retire(lane: check) }
                guard let client = client(nil, lane: check), await client.pushEnabled() else {
                    pushStatus = "The server isn't set up for wake-ups"
                    pushRetryAt = Date().addingTimeInterval(Self.pushRetryWait(refused: false))
                    return
                }
                // Each part in a request of its own, on a connection of its own, at its own moment (`pushParts`); the
                // relay takes 256 mailboxes at a time.
                var ok = true
                for (n, part) in parts.enumerated() {
                    if n > 0, shaping { try? await Task.sleep(for: .seconds(Double.random(in: Self.pushPartGap))) }
                    let lane = Lanes.once("push")
                    defer { RelayClient.retire(lane: lane) }
                    guard let client = self.client(nil, lane: lane) else { ok = false; break }
                    let all = part.sorted { $0.hex < $1.hex }
                    for start in stride(from: 0, to: all.count, by: 256) {
                        do {
                            try await client.registerPush(keys: Array(all[start..<min(start + 256, all.count)]), token: token,
                                                          sandbox: Push.sandbox, sound: sound, tone: tone, voip: voip)
                        } catch {
                            ok = false
                            let refused = error as? PushRefused
                            let retry = Date().addingTimeInterval(Self.pushRetryWait(refused: refused != nil))
                            pushRetryAt = retry
                            let when = "trying again at \(retry.formatted(date: .omitted, time: .shortened))"
                            pushStatus = refused.map { "The server refused the registration (\($0.status)), \(when)" } ?? "Couldn't reach the server to register, \(when)"
                            break
                        }
                    }
                    if !ok { break }
                }
                if ok {
                    pushRetryAt = nil
                    for batch in removals {
                        let lane = Lanes.once("push")
                        try? await self.client(nil, lane: lane)?.unregisterPush(keys: batch, token: token)
                        RelayClient.retire(lane: lane)
                    }
                    pushTold = (token, keys, registered, sound, tone, voip, Date())
                    pushStatus = "Registered \(keys.count) mailbox\(keys.count == 1 ? "" : "es") in \(parts.count) part\(parts.count == 1 ? "" : "s") at \(Date().formatted(date: .omitted, time: .shortened)), token ending \(token.suffix(4))"
                }
            }
        } else {
            let forgotten = keys.union(pushTold?.keys ?? [])
            let told = pushTold?.token ?? Push.token
            pushTold = nil
            pushAsked = false
            UIApplication.shared.unregisterForRemoteNotifications()
            guard !forgotten.isEmpty else { return }
            pushBusy = true
            Task {
                defer { pushBusy = false }
                let all = Array(forgotten)
                for start in stride(from: 0, to: all.count, by: 256) {
                    try? await client(nil, lane: "push")?.unregisterPush(keys: Array(all[start..<min(start + 256, all.count)]), token: told)
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

    /// The connection for proving a profile's handles are its own. Never the one its mail
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
    /// Tests: a sync is under way (one asked for now returns at once without doing anything).
    var isSyncing: Bool { syncing }

    /// Whether what's about to be sent may go: whatever sealing it moved on (a ratchet, a group's chain) has to be on the
    /// disk before it leaves, and the nonces follow from that state alone, so a state rolled back to one already used
    /// would seal a new message under a nonce and key already spent. Whenever envelopes are waiting this starts any write that
    /// is queued and waits for the save queue to drain, so a write the debounce has already started counts too (it may still
    /// be under way, and its outcome isn't known until it ends). If the last write failed, this writes again now with
    /// everything as it stands, and if it still isn't on the disk it says no: the envelopes stay queued and go on a later
    /// pass, once a write has landed. The write itself happens off the main thread; this only waits for it.
    func stateIsOnDiskBeforeSending() async -> Bool {
        let waiting = !data.outbox.isEmpty || !data.partingPosts.isEmpty
            || data.conversations.contains { !($0.shared?.outbox.isEmpty ?? true) }
        guard waiting else { return true }
        if saveHealth.lastWriteFailed { save() }
        await settleSavesAsync()
        return !saveHealth.lastWriteFailed
    }

    /// Sends queued envelopes: the oldest waiting one of each mailbox (so what's written to one mailbox goes out in
    /// order), the smallest first, and a new one is started the moment another finishes. A story to thirty people
    /// doesn't go out one slow round trip after another, and a short message never waits behind its photos.
    /// One that fails holds up only its own mailbox, and a relay that's down only its own envelopes. A large one
    /// that fails (a slow upload, not a relay that's gone) doesn't stop the small ones behind it.
    private func flush() async {
        guard await stateIsOnDiskBeforeSending() else { return }
        await flushSharedGroups()
        await flushPartingPosts()
        let owner = identity?.fingerprint
        var down: Set<String> = []
        // Mailboxes that are full this time: what's written to them waits, nothing else does. And those a big upload
        // to just failed: that was a slow upload, not the mailbox, so short messages to it still go.
        var held: Set<Data> = []
        var heldBig: Set<Data> = []
        // Connections the relay asked to slow down this time: only what goes on them waits.
        var heldLanes: Set<String> = []
        var tried: Set<UUID> = []
        var aborted = false

        // The smallest waiting item that may go, if there's room for it. Short messages keep their order among
        // themselves, and so do photos and story pieces, but a short message doesn't wait behind a story's pieces
        // for the same person (the ratchet reads them in either order). Big ones share one connection, so more than
        // a couple at once only makes each slower, and slow enough to time out; short ones are tiny and always
        // get through.
        func pick() -> (item: Outgoing, lane: String)? {
            guard !aborted else { return nil }
            let now = Date()
            var best: (item: Outgoing, lane: String)?
            var seenSmall: Set<Data> = [], seenBig: Set<Data> = []
            for item in data.outbox where !tried.contains(item.id) && !sendingIDs.contains(item.id) {
                let relay = item.relay ?? data.relay
                // A mailbox that just said it was full is left alone until its short backoff ends. A relay
                // that's unreachable is not backed off: retry as soon as it's back.
                if let backoff = mailboxBackoff[item.sendID], now < backoff.until { continue }
                // Photos and story pieces go on a connection of their own, so a big upload neither crowds out the short
                // messages nor takes their connection down with it when it fails.
                let lane = (item.lane ?? Outgoing.lane(for: nil)) + (item.isBulk ? Self.bulkSuffix : "")
                guard !down.contains(relay), !held.contains(item.sendID), !heldLanes.contains(lane) else { continue }
                if item.isBulk {
                    guard !heldBig.contains(item.sendID), !seenBig.contains(item.sendID),
                          !sendingBigMail.contains(item.sendID) else { continue }
                    seenBig.insert(item.sendID)
                } else {
                    guard !seenSmall.contains(item.sendID), !sendingSmallMail.contains(item.sendID) else { continue }
                    seenSmall.insert(item.sendID)
                }
                guard reachable(item.relay) != nil else { continue }
                // A lane without a working route finds one first, once: not for every item that's waiting.
                if routeFinding.contains(lane) { continue }
                if best == nil || item.weight < best!.item.weight { best = (item, lane) }
            }
            guard let best else { return nil }
            let big = best.item.isBulk
            let bigInFlight = sendingBig.count
            if big ? bigInFlight >= Self.bigUploads : sendingIDs.count >= Self.sendLanes + Self.bigUploads { return nil }
            return best
        }

        await withTaskGroup(of: (Outgoing, String, String, Error?).self) { group in
            var running = 0
            while true {
                while let next = pick() {
                    let item = next.item, lane = next.lane
                    // The circuit for this lane now: a fresh one after a quiet spell (`SendLanes`). A lane used once
                    // (a receipt) is already fresh, and is let go of as soon as it's done.
                    let once = lane.hasPrefix(Lanes.oncePrefix)
                    let current = once ? (name: lane, retired: nil) : sendLanes.current(lane)
                    if let retired = current.retired { RelayClient.retire(lane: retired) }
                    guard let client = client(item.relay, lane: current.name) else { tried.insert(item.id); continue }
                    if !once { sendLanes.note(current.name, busy: 1) }
                    let sentOn = current.name
                    let findsRoute = Tor.uses(client.base) && !client.isEstablished
                    if findsRoute { routeFinding.insert(lane) }
                    tried.insert(item.id)
                    sendingIDs.insert(item.id)
                    if item.isBulk {
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
                                                     recall: item.recallN.flatMap { n in item.recallHash.map { (n, $0) } },
                                                     life: item.life, collapse: item.collapse)
                            return (item, lane, sentOn, nil)
                        } catch { return (item, lane, sentOn, error) }
                    }
                }
                guard running > 0, let (item, lane, sentOn, error) = await group.next() else { break }
                running -= 1
                if lane.hasPrefix(Lanes.oncePrefix) { RelayClient.retire(lane: sentOn) } else { sendLanes.note(sentOn, busy: -1) }
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
                    let refused = (error as? RelayRefused)?.status
                    if error is RelayMailboxFull {
                        held.insert(item.sendID)
                        let failures = (mailboxBackoff[item.sendID]?.failures ?? 0) + 1
                        mailboxBackoff[item.sendID] = (Date().addingTimeInterval(retryDelay(failures)), failures)
                        sendHolds[item.id] = .full
                    } else if refused == 429 {
                        heldLanes.insert(lane)
                        sendHolds[item.id] = .busy
                    } else if let refused, (400..<500).contains(refused) {
                        // The relay answered and turned down this one envelope: the relay is fine, so everything
                        // else still goes. (This used to count as the relay being down, and a tiny envelope it always
                        // refused, tried first for being the smallest, held the whole outbox back on every try.)
                        // Refused a few times, it never will be taken.
                        let times = (refusals[item.id] ?? 0) + 1
                        if times >= 3 {
                            data.outbox.removeAll { $0.id == item.id }
                            refusals[item.id] = nil
                            sendHolds[item.id] = nil
                            continue
                        }
                        refusals[item.id] = times
                        sendHolds[item.id] = .refused
                    } else if item.blob.count > Self.largeEnvelope {
                        heldBig.insert(item.sendID)
                        sendHolds[item.id] = .slowUpload
                    } else {
                        down.insert(item.relay ?? data.relay)
                        sendHolds[item.id] = .unreachable
                    }
                    // A signal that couldn't be sent is not worth sending later.
                    if item.ephemeral == true {
                        data.outbox.removeAll { $0.id == item.id }
                        mailboxBackoff[item.sendID] = nil
                    }
                } else {
                    lastDepositOK = Date()
                    data.outbox.removeAll { $0.id == item.id }
                    mailboxBackoff[item.sendID] = nil
                    if sendHolds[item.id] != nil { sendHolds[item.id] = nil }
                    refusals[item.id] = nil
                    if let message = item.message {
                        setStatus(.sent, for: [message])
                        // So their phone can confirm it while locked (`Payload.collected`).
                        data.sentDigests[LockedDelivery.digest(of: item.blob).hex] = SentDigest(message: message, at: Date())
                    }
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
        let waiting = Set(data.outbox.map(\.id))
        if sendHolds.keys.contains(where: { !waiting.contains($0) }) { sendHolds = sendHolds.filter { waiting.contains($0.key) } }
        refusals = refusals.filter { waiting.contains($0.key) }
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
    private static var smallEnvelope: Int { Outgoing.smallEnvelope }
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
        if let c = data.contacts.first(where: { Self.mailboxes(of: $0).contains(receiveKey) }) { return .some(c.persona) }
        if let invite = data.invites.first(where: { $0.receiveKey == receiveKey }) { return .some(invite.persona) }
        return nil
    }

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

    /// Tests only: sees every envelope this device takes in, so one can be handed to `receive` again.
    @ObservationIgnored var envelopeTap: ((RelayEnvelope) -> Void)?
    /// Tests only: mail this says yes to is left on the relay for now, as if it hadn't arrived yet.
    @ObservationIgnored var holdMail: ((RelayEnvelope) -> Bool)?
    /// Tests only: what became of each envelope fetched from the relay (the delivery counter tallies these).
    #if DEBUG
    @ObservationIgnored var receiveResultTap: ((ReceiveResult) -> Void)?
    #endif

    /// What became of an envelope taken from the relay.
    enum ReceiveResult: Equatable {
        /// Read and acted on: it can be acknowledged and forgotten.
        case handled
        /// Not for this device, or impossible to use: acknowledging it is all that can be done.
        case junk
        /// Unusable yet, but it may be once the contact or device it names is known. Left on the relay.
        case retry
    }

    @discardableResult
    func receive(_ envelope: RelayEnvelope) -> ReceiveResult {
        if holdMail?(envelope) == true { return .retry }
        envelopeTap?(envelope)
        deposited = envelope.deposited
        // A logged-in device no longer shows a code for new devices to answer (someone filming both screens could
        // answer it with digits ground to match): it only scans theirs. Nothing that lands on a link mailbox is a request.
        guard let persona = persona(forMailbox: envelope.receiveKey), let me = me(persona) else { return .junk }
        let opened: Envelope.Opened
        do {
            opened = try Envelope.openFull(envelope.blob, with: me,
                                           known: { [self] in $0 == me.card.signing ? me.pq.pin : contact(Identity.fingerprint(of: $0), in: persona)?.pq })
        } catch let EnvelopeRefusal.classical(signer, sentAt) {
            // Only a recent one says anything: an old classical envelope can be replayed by the relay or anyone who kept a copy,
            // and must not put "needs to update" under a friend's name or stop this account introducing itself.
            let age = RelayClock.now.timeIntervalSince(sentAt)
            if age < Self.replayWindow, age > -24 * 3600 { noteTooOld(signer, persona: persona) }
            return .junk
        } catch let EnvelopeRefusal.unpinned(signer) {
            // From a contact whose keys are on their way (their hello is in another mailbox, fetched after this one): left on
            // the relay for the next check, as with mail from a device not met yet, rather than lost.
            if let known = contactIndex(Identity.fingerprint(of: signer), persona), data.contacts[known].pq == nil { return .retry }
            return .junk
        } catch { return .junk }
        let payload = opened.payload, signer = opened.signer, device = opened.device
        let fp = Identity.fingerprint(of: signer)
        // Keys the envelope introduced are pinned now; one sealed to ours shows they have our card.
        if let known = contactIndex(fp, persona) {
            if data.contacts[known].pq == nil, let pin = opened.introduced {
                // Held to what their invite committed to: anything else isn't the person who made the invite.
                guard pinMatchesInvite(pin, contact: data.contacts[known]) else { return .junk }
                data.contacts[known].pq = pin
                // What was waiting for their keys goes now, and your other devices are told them.
                sendPending(contact: known)
                sendFollowsLater(fp, persona: persona)
            }
            if opened.postQuantum, data.contacts[known].pqCardSent != true { data.contacts[known].pqCardSent = true }
            if data.contacts[known].tooOld != nil { data.contacts[known].tooOld = nil }
        }
        // Anything outside a ratchet session could be sent again by the relay. Each one counts once, and only
        // while the relay could still be holding it.
        // The digest is only written down once the sender is someone this account knows (a contact, or the invite the
        // mailbox belongs to): anyone with a public key can seal an envelope to this account, and each one counted
        // before that would grow the table, and make a real envelope for a contact not yet added look like a repeat.
        let replayDigest = Data(SHA256.hash(data: envelope.blob).prefix(16)).hex
        let isRatchet: Bool = { if case .ratchet = payload { return true } else { return false } }()
        // Friend requests to a public username and hellos to a channel's code can come from anyone: they count in a pool
        // of their own, so a flood of them can't push out (or raise the floor over) what only contacts can send.
        let fromAnyone: Bool = {
            switch payload {
            case .request: return true
            case .hello: return data.invites.contains { $0.receiveKey == envelope.receiveKey && ($0.isPublic || $0.channel != nil) }
            default: return false
            }
        }()
        let pool: SeenPool = fromAnyone ? .stranger : .contact
        if !isRatchet {
            let age = RelayClock.now.timeIntervalSince(opened.sentAt)
            // No more than a day ahead of either clock, so a relay moving its clock can't let a send time sit far ahead
            // (and with it a floor).
            let horizon = min(RelayClock.now, Date()).addingTimeInterval(24 * 3600)
            guard age < Self.replayWindow, opened.sentAt <= horizon, !wasSeen(replayDigest, in: pool) else { return .junk }
            // The pool was full once and let go of digests up to its floor: anything sent by then may be one of them.
            if let key = pool.floorKey, let floor = data.seenEnvelopes[key], opened.sentAt <= floor { return .junk }
        }
        // Kept under the later of now and its signed send time, so a let-go digest always lies at or under the floor.
        func markSeen() { if !isRatchet { noteSeen(replayDigest, in: pool, sentAt: opened.sentAt) } }

        if case let .pqIntro(card) = payload {
            guard let known = contactIndex(fp, persona), let pin = card.verified(signer: signer, agreement: opened.agreement),
                  data.contacts[known].pq == pin else { return .junk }
            markSeen()
            // Sent in a classical envelope: they haven't got ours, so they get it now. At most once in a while per contact: a
            // reply carries a whole card, and an introduction sent again must not make this device answer each time.
            if !opened.postQuantum, introReplyDue(fp, persona) { sendPQIntro(contact: known, force: true) }
            save()
            return .handled
        }

        if case .erased = payload {
            // Signed by their identity key, so only they can erase themselves from here.
            if contactIndex(fp, persona) != nil { markSeen() }
            eraseTraces(of: fp)
            return .handled
        }

        if case let .hello(card, request) = payload {
            // The card must name the agreement key the envelope was actually sealed with: the signing key's
            // binding covers that one, not whatever a payload chooses to claim.
            guard card.signingKey == signer, card.agreementKey == opened.agreement,
                  let invite = data.invites.first(where: { $0.receiveKey == envelope.receiveKey && !$0.isPublic }) else { return .junk }
            guard let pin = card.pq?.verified(signer: signer, agreement: opened.agreement) ?? opened.introduced,
                  contact(fp, in: invite.persona)?.pq == nil || contact(fp, in: invite.persona)?.pq == pin,
                  pinMatchesInvite(pin, contact: contact(fp, in: invite.persona)),
                  let mine = self.me(invite.persona),
                  let helloPin = Handshake.devicePin(of: request, HandshakeParties(from: signer, to: mine.card.signing, device: device),
                                                     accountPQ: pin, context: .hello)
            else { return .junk }
            markSeen()
            // A device their account unlinked gets nothing by saying hello on a code (a friend's follow included, which
            // otherwise changes nothing about them and only lets them in).
            if let i = contactIndex(fp, invite.persona), isRevoked(contact: i, id: device, pin: helloPin) { return .junk }
            acceptHello(card, request, fingerprint: fp, device: device, via: invite, pq: pin, sentAt: opened.sentAt)
            noteReads(opened, from: fp, persona: invite.persona)
            // Following through a channel's code: invited into its mailbox now that their app's abilities are known (when
            // their app can take part), up to the hourly limit.
            // Only someone actually kept (there was room): one turned away uses none of the hour's places.
            if let channelID = invite.channel, let c = index(of: channelID), data.conversations[c].shared != nil,
               contact(fp, in: invite.persona) != nil {
                admitFromCode([fp], at: c)
                save()
            }
            return .handled
        }
        if case let .request(card, request, note) = payload {
            guard card.signingKey == signer, card.agreementKey == opened.agreement, !data.blocked.contains(fp),
                  card.relay == nil || Invite.allowedRelay(card.relay) != nil,
                  let pin = card.pq?.verified(signer: signer, agreement: opened.agreement),
                  contact(fp, in: persona)?.pq == nil || contact(fp, in: persona)?.pq == pin,
                  pinMatchesInvite(pin, contact: contact(fp, in: persona)),
                  let invite = data.invites.first(where: { $0.receiveKey == envelope.receiveKey && $0.isPublic }),
                  Handshake.devicePin(of: request, HandshakeParties(from: signer, to: me.card.signing, device: device), accountPQ: pin,
                                      context: .request) != nil
            else { return .junk }
            markSeen()
            // A stranger's card is kept in the vault until answered, so it is held to the sizes a profile may have.
            var kept = card
            kept.name = String(card.name.prefix(64))
            if let avatar = card.avatar, avatar.count > Self.maxAvatarBytes { kept.avatar = nil }
            var incoming = FriendRequest(fingerprint: fp, card: kept, handshake: request, note: String(note.prefix(280)),
                                         persona: invite.persona)
            incoming.device = device
            // From a device their account unlinked: not taken, whatever it says.
            if let known = contactIndex(fp, invite.persona), isRevoked(contact: known, id: device, pin: nil) { return .junk }
            // Someone known only from a group isn't a friend yet: theirs is an ordinary request.
            if let known = contactIndex(fp, invite.persona), !data.contacts[known].hidden {
                // Already a friend: they've lost the chat on their side (a reinstall, a detach), and their identity
                // key signed this, so it's them. Reconnect now, rather than leave each side waiting on the other.
                // A request in a classical envelope (they have lost our keys too, so it can't be sealed to them) is not
                // trusted that far: it could be forged by someone who has broken X25519 and Ed25519. It waits for you
                // to accept it, like a stranger's, and what you set for them is kept (`acceptRequest`).
                if data.contacts[known].awaitingAcceptance { return .handled }
                if opened.postQuantum { reconnect(incoming, keeping: data.contacts[known]); return .handled }
            }
            // The same request sent again (the relay may have lost the first): already here, so no second banner. The same
            // keys make it the same request: it is signed afresh each time it is sent, and a post-quantum signature comes out
            // different every time.
            if data.requests.contains(where: { $0.fingerprint == fp && $0.persona == invite.persona
                && $0.handshake.ephemeral == request.ephemeral && $0.handshake.kem == request.kem }) { return .handled }
            withAnimation(.snappy) {
                data.requests.removeAll { $0.fingerprint == fp && $0.persona == invite.persona }
                data.requests.insert(incoming, at: 0)
                // Anyone who knows a username can send requests from throwaway keys: the oldest make way.
                if data.requests.count > Self.maxRequests { data.requests.removeLast(data.requests.count - Self.maxRequests) }
            }
            if data.security.notifications {
                Notifier.shared.post(("PULSHADE", "New friend request"), conversation: incoming.id, sound: data.security.notificationSound)
            }
            return .handled
        }
        // A message from someone this persona doesn't know yet. Kept rather than acknowledged: the contact
        // may arrive a moment later (a group's roster, a hello in the same fetch).
        guard let i = contactIndex(fp, persona) else { return .retry }
        // A device their account unlinked: nothing it says is taken, bar one thing read from its kept session (`readRevoked`).
        if !device.isEmpty, let r = data.contacts[i].revoked?.firstIndex(where: { $0.id == device }) {
            markSeen()
            if case let .ratchet(message) = payload, !data.contacts[i].isSelf { readRevoked(message, contact: i, entry: r) }
            return .handled
        }
        markSeen()
        // The notification helper's note (`.collected`) says caps 0 because it knows nothing of what the app reads: taking that
        // as the truth would mark the friend's device as needing an update (bit 7 absent) until its next real envelope.
        if case .collected = payload {} else { noteReads(opened, from: fp, persona: persona) }
        let viaRequestMailbox = data.invites.contains { $0.isPublic && $0.receiveKey == envelope.receiveKey }
        defer { if viaRequestMailbox { remindAccepted(fp, persona) } }

        switch payload {
        case let .deviceHello(card, request):
            // A device introducing itself (a new one, or one restarting its session). Signed by the account,
            // so it really is theirs. Every current app names its device: one that doesn't could take over another
            // device's place unannounced.
            // Its own keys must sign it, under a card its account signed for this id: anything else isn't taken.
            guard card.id == device, !device.isEmpty, let pin = askerPin(request, contact: i, device: device, context: .device),
                  !isRevoked(contact: i, id: device, pin: pin) else { return .junk }
            // Vouched for by a device of theirs still trusted: not held for want of one (`holdsNewDevices`).
            let vouched = !data.contacts[i].isSelf && card.vouch.map { vouchHolds($0, contact: i, device: device, pin: pin) } == true
            if vouched { vouchedPins.insert(vouchKey(contact: i, pin: pin)) }
            let d = upsertDevice(i, id: card.id, sendID: card.sendID, vouched: vouched)
            // Held only because their account unlinked a device, and now vouched for with the keys it was held under. A hold
            // for any other reason (you ask before new devices, on this device or another of yours) isn't a vouch's to lift.
            if vouched, data.contacts[i].unlinked != nil, data.contacts[i].devices[d].unconfirmed == true,
               !holdsNewDevices(contact: i, vouched: true),
               data.contacts[i].devices[d].keyPin == nil || data.contacts[i].devices[d].keyPin == pin {
                release(contact: i, device: d)
            }
            // The same hello again (a relay redelivery) must not replace the session it already opened.
            if data.contacts[i].devices[d].session != nil && data.contacts[i].devices[d].acceptedHello == request.ephemeral {
                return .handled
            }
            if data.contacts[i].devices[d].handshake != nil && myHandshakeWins(me: me.fingerprint, persona: persona, them: fp, theirDevice: device)
                && !yields(to: opened.sentAt, contact: i, device: d) {
                return .handled
            }
            // Keys that can't open what they send aren't worth keeping: their hello is taken whatever its time.
            let broken = keysBroken(contact: i, device: d)
            if !broken, hello(opened.sentAt, crossedOurs: data.contacts[i].devices[d])
                && myHandshakeWins(me: me.fingerprint, persona: persona, them: fp, theirDevice: device) {
                return .handled
            }
            // Sent before this device answered their spare: they drop that ask when the answer reaches them.
            if !broken, hello(opened.sentAt, crossedSpareOf: data.contacts[i].devices[d]) { return .handled }
            if !broken, hello(opened.sentAt, overtakenIn: data.contacts[i].devices[d]) { return .handled }
            acceptSession(request, contact: i, device: d, sentAt: opened.sentAt, context: .device)
            return .handled
        case let .sessionInit(request):
            // Every current app names its device: one that doesn't could take a device's place unannounced.
            guard !device.isEmpty, let d = deviceIndex(i, device) else { return .junk }
            if hello(opened.sentAt, crossedSpareOf: data.contacts[i].devices[d]) { return .handled }
            if data.contacts[i].devices[d].session != nil && data.contacts[i].devices[d].acceptedHello == request.ephemeral {
                return .handled
            }
            if data.contacts[i].devices[d].handshake != nil && myHandshakeWins(me: me.fingerprint, persona: persona, them: fp, theirDevice: device)
                && !yields(to: opened.sentAt, contact: i, device: d) {
                return .handled
            }
            let broken = keysBroken(contact: i, device: d)
            if !broken, hello(opened.sentAt, crossedOurs: data.contacts[i].devices[d])
                && myHandshakeWins(me: me.fingerprint, persona: persona, them: fp, theirDevice: device) {
                return .handled
            }
            if !broken, hello(opened.sentAt, overtakenIn: data.contacts[i].devices[d]) { return .handled }
            acceptSession(request, contact: i, device: d, sentAt: opened.sentAt, context: .initial)
            return .handled
        case let .sessionAccept(answer):
            guard let d = deviceIndex(i, device) else { return .junk }
            let link = data.contacts[i].devices[d]
            // The answer may be to an ask this device has since made again: a phone that was asleep when it came
            // asks again on waking, and the answer to the first ask is still the one they hold.
            let asks = [link.handshake].compactMap { $0 } + (link.earlierAsks ?? [])
            guard let pending = asks.first(where: { $0.publicEphemeral == answer.replyTo }),
                  let theirPin = answererPin(answer, to: pending, contact: i, device: link.id),
                  !isRevoked(contact: i, id: link.id, pin: theirPin),
                  let session = try? Handshake.complete(pending, answer, me: me, responderAgreement: data.contacts[i].agreementKey,
                                                        responderPin: theirPin) else { return .junk }
            pinDeviceKey(theirPin, contact: i, device: d)
            if link.handshake?.publicEphemeral != answer.replyTo {
                // Never older than the answer behind the keys in use.
                let broken = keysBroken(contact: i, device: d)
                if !broken, link.session != nil, let answered = believable(link.answeredAt), opened.sentAt < answered { return .junk }
                // Nor to an ask older than the one behind them: their side took the newer ask (see `hello(_:overtakenIn:)`),
                // and these keys would be ones they've moved on from. The two answers can arrive either way round.
                if !broken, link.session != nil, let askAt = believable(link.sessionAskAt), pending.startedAt < askAt { return .junk }
                // The newer ask isn't needed now if it hasn't gone: taken back.
                if link.handshake != nil, !withdrawHello(contact: i, device: d) {
                    // It has gone, so they'll answer it too and move to the keys it opens, dropping these. Anything
                    // written on these meanwhile would reach them after they'd moved (and, with Pulshade closed in
                    // between, could never be read). So these are only read from, for what they wrote on them, and
                    // what this device has to say waits for the answer to the newer ask.
                    keepRecovered(session, sessionKey(contact: i, device: d))
                    data.contacts[i].devices[d].earlierAsks?.removeAll { $0.publicEphemeral == answer.replyTo }
                    if data.contacts[i].devices[d].earlierAsks?.isEmpty == true { data.contacts[i].devices[d].earlierAsks = nil }
                    heard(contact: i, device: d)
                    return .handled
                }
            }
            // The session is open: the ask it answers and every ask older than it are of no more use (while these keys work,
            // an answer to one is refused as older than them), so their secret halves go now. One made after it stays, in case
            // they answered that too and move to it.
            data.contacts[i].devices[d].earlierAsks?.removeAll { $0.publicEphemeral == answer.replyTo || $0.startedAt <= pending.startedAt }
            if data.contacts[i].devices[d].earlierAsks?.isEmpty == true { data.contacts[i].devices[d].earlierAsks = nil }
            // What they wrote on the keys this replaces, still on its way, stays readable for now.
            if let old = link.session { keepRecovered(old, sessionKey(contact: i, device: d)) }
            data.contacts[i].devices[d].session = session
            data.contacts[i].devices[d].handshake = nil
            data.contacts[i].devices[d].needsKeys = nil
            data.contacts[i].devices[d].sessionAskAt = pending.startedAt
            data.contacts[i].devices[d].acceptedHelloAt = nil
            heard(contact: i, device: d)
            // When they answered, by their clock: a hello of theirs sent before that crossed ours (see `hello(_:crossedOurs:)`).
            data.contacts[i].devices[d].answeredAt = opened.sentAt
            // New keys are in place: no more asking for them because of messages that were read with the old ones.
            unreadable[sessionKey(contact: i, device: d)] = nil
            // We can write on these keys once their first message arrives; they send it straight after answering.
            keysAnsweredAt[sessionKey(contact: i, device: d)] = Date()
            resendUnconfirmed(contact: i, device: d)
            return .handled
        case let .spareAccept(card, answer):
            // A device of theirs took the spare key this device left for them (see `SpareSlot`) and is already
            // writing on the session it opens. Signed by the account, so it's theirs.
            guard card.id == device, !card.id.isEmpty else { return .junk }
            let currentPin = deviceKey(for: persona)?.card.pin
            // Only spares this device's present keys signed, and a last-resort one no older than a friend would take:
            // anything else is answered as a spare this device no longer has.
            let spares = (data.contacts[i].liveSpares + (data.contacts[i].oldSpares ?? [])).filter { spare in
                spare.handshake.pin == currentPin
                    && (!spare.place.reusable || Date().timeIntervalSince(spare.madeAt) < Self.spareMaxAge)
            }
            let used = spares.first(where: { $0.handshake.publicEphemeral == answer.replyTo })
            // Signed by the answering device's own keys, under a card its account signed: anything else isn't taken.
            let theirPin = used.flatMap { answererPin(answer, to: $0.handshake, contact: i, device: device) }
            if used != nil, theirPin == nil { return .junk }
            if let theirPin, isRevoked(contact: i, id: device, pin: theirPin) { return .junk }
            // An answer to the last-resort spare that was taken already (sent again, by the relay or anyone): finishing
            // it a second time would put the chat back on keys it has moved on from.
            if let used, used.place.reusable, used.answers?.contains(answer.ephemeral) == true { return .handled }
            guard let used, let theirPin,
                  let session = try? Handshake.complete(used.handshake, answer, me: me, responderAgreement: data.contacts[i].agreementKey,
                                                        responderPin: theirPin) else {
                // A spare this device no longer has (it was used already, or the account was recovered from a backup
                // older than it): what they write on it can't be read here. Nothing in it was checked against a device's
                // keys, so it adds no device and moves none to another mailbox: only a device already known by this very
                // id is asked for new keys, at the mailbox it already has (its ask is checked as usual). Expect what they
                // already wrote on it to be unreadable for a while, without asking again over each one.
                guard let d = data.contacts[i].devices.firstIndex(where: { $0.id == card.id }) else { return .junk }
                deadSpareFrom[sessionKey(contact: i, device: d)] = Date()
                if data.contacts[i].devices[d].handshake == nil { startHandshake(contact: i, device: d) }
                return .handled
            }
            let d = upsertDevice(i, id: card.id, sendID: card.sendID)
            pinDeviceKey(theirPin, contact: i, device: d)
            if used.place.reusable {
                // The last-resort spare stays for anyone else who needs it, until it's replaced; this answer is noted.
                func note(_ spare: inout SpareKey) {
                    spare.answers = Array(((spare.answers ?? []) + [answer.ephemeral]).suffix(Self.spareAnswersKept))
                }
                if var live = data.contacts[i].spare(in: .lastResort), live.handshake.publicEphemeral == answer.replyTo {
                    note(&live)
                    data.contacts[i].setSpare(live, in: .lastResort)
                } else if let n = data.contacts[i].oldSpares?.firstIndex(where: { $0.handshake.publicEphemeral == answer.replyTo }) {
                    note(&data.contacts[i].oldSpares![n])
                }
            } else {
                // Each one-time spare opens one session. The next one is made and left on the relay soon after.
                if data.contacts[i].spare(in: used.place)?.handshake.publicEphemeral == answer.replyTo {
                    data.contacts[i].setSpare(nil, in: used.place)
                    nextSpareWork = min(nextSpareWork, Date().addingTimeInterval(.random(in: 30...180)))
                }
                data.contacts[i].oldSpares?.removeAll { $0.handshake.publicEphemeral == answer.replyTo }
                if data.contacts[i].oldSpares?.isEmpty == true { data.contacts[i].oldSpares = nil }
            }
            // Both recovered at about the same time: each took the other's spare, and each now hears that the other
            // took theirs. Left alone, each would switch to the other's answer and the two would end up apart. The
            // lower side's spare wins on both ends (as with crossed hellos): the higher side keeps the keys it opened
            // by answering the lower side's spare, and the lower side switches to them on hearing the answer. Only
            // while their answer could have crossed ours: once anything of theirs has opened on the keys we made from
            // their spare (`spareTakenAt` is cleared then), or our answer is older than the relay keeps mail, this is
            // a friend who recovered later, and their answer is the one to take.
            let link = data.contacts[i].devices[d]
            if link.session != nil, let taken = link.spareTakenAt, opened.sentAt.timeIntervalSince(taken) < Self.replayWindow,
               !myHandshakeWins(me: me.fingerprint, persona: persona, them: fp, theirDevice: device) {
                // What they wrote on it before hearing our answer stays readable.
                keepRecovered(session, sessionKey(contact: i, device: d))
                heard(contact: i, device: d)
                return .handled
            }
            // Mail already sent on the keys this replaces stays readable for now.
            if let old = data.contacts[i].devices[d].session { keepRecovered(old, sessionKey(contact: i, device: d)) }
            data.contacts[i].devices[d].spareTakenAt = nil
            data.contacts[i].devices[d].session = session
            data.contacts[i].devices[d].sessionAskAt = nil
            data.contacts[i].devices[d].acceptedHelloAt = nil
            data.contacts[i].devices[d].handshake = nil
            data.contacts[i].devices[d].earlierAsks = nil
            data.contacts[i].devices[d].needsKeys = nil
            data.contacts[i].devices[d].awaitingHello = nil
            data.contacts[i].devices[d].acceptedHello = nil
            heard(contact: i, device: d)
            data.contacts[i].devices[d].answeredAt = opened.sentAt
            unreadable[sessionKey(contact: i, device: d)] = nil
            keysAnsweredAt[sessionKey(contact: i, device: d)] = Date()
            // Something small on these keys as soon as they can carry it, so their device knows this one has its
            // answer (see the crossing above).
            data.contacts[i].devices[d].pending.insert(PendingPayload(payload: .receipt(ids: []), message: nil), at: 0)
            return .handled
        case let .collected(digests):
            // A friend's phone has these envelopes of yours, said by its notification helper while it was locked
            // (see `LockedDelivery`): the second tick, before they've opened Pulshade.
            let ids = digests.compactMap { data.sentDigests[$0.hex]?.message }
            if !ids.isEmpty { withAnimation(.smooth) { for id in ids { noteDelivery(of: id, by: fp, read: false) } } }
            return .handled
        case let .ratchet(message):
            // A message from a device this account hasn't met yet (its hello may be right behind in the same
            // fetch). Kept rather than acknowledged, so it can be read once the device is known.
            guard let d = deviceIndex(i, device) else { return .retry }
            // From a friend's device you haven't allowed: kept sealed and unread until you do, so it can't put words in
            // their mouth next to the Allow button. Opened in order then, as if it had just come.
            if !data.contacts[i].isSelf, data.contacts[i].devices[d].unconfirmed == true {
                holdDeviceMail(HeldMail(receiveKey: envelope.receiveKey, blob: envelope.blob, at: Date()),
                               contact: i, device: d)
                return .handled
            }
            // A build from before the sparse post-quantum ratchet: its messages aren't read, and the chat tells whose app
            // has to update. Not a broken session, so no new keys are started over it.
            // One from a newer build (a version past this one's) can't be read either, but it is this app that is behind,
            // so the friend isn't blamed for it.
            if (message.header.v ?? 0) < RatchetHeader.version { markNeedsUpdate(contact: i, device: d) }
            if message.header.v != RatchetHeader.version || data.contacts[i].devices[d].needsUpdate == true { return .handled }
            let keptKey = sessionKey(contact: i, device: d)
            // The very same ciphertext again (the relay sent it twice, or its sender sent it again after a dropped
            // connection): already read, so nothing to do. Without this it can't be opened a second time, which looked
            // like the two phones being out of step and started new keys over a healthy chat.
            let readBefore = replayDigest
            if wasSeen(readBefore, in: .ratchet) { return .handled }
            var plain: Data?
            if var session = data.contacts[i].devices[d].session, let opened = try? session.decrypt(message) {
                data.contacts[i].devices[d].session = session
                heard(contact: i, device: d)
                noteMailboxHeard(envelope.receiveKey, contact: i, device: d)
                // They're on the keys this device made from their spare: they have our answer.
                if data.contacts[i].devices[d].spareTakenAt != nil { data.contacts[i].devices[d].spareTakenAt = nil }
                plain = opened
            } else if let (n, old, opened) = openRecovered(message, keptKey) {
                // Sent to the keys this account had before it was recovered, while the phone was gone: still readable.
                recoveredSessions[keptKey]?[n] = old
                plain = opened
            }
            guard let plain else {
                // Written on a spare this device no longer had: expected, and new keys are already on their way.
                if let since = deadSpareFrom[keptKey], Date().timeIntervalSince(since) < 600 { return .handled }
                // Sent before the keys this chat is on now were set up, or longer ago than the relay keeps mail: an old
                // envelope (sent again by the relay, say), not keys out of step. New keys over it would throw away a
                // working session (and use up the friend's spare) on nothing.
                let link = data.contacts[i].devices[d]
                let since = [link.answeredAt, link.acceptedHelloAt, link.spareTakenAt].compactMap { $0 }.max()
                if link.session != nil,
                   RelayClock.now.timeIntervalSince(opened.sentAt) > Self.replayWindow || since.map({ opened.sentAt < $0 }) == true {
                    return .handled
                }
                // Signed by their account, yet this device's keys can't open it: the two are out of step (a backup that
                // was a little behind, say). Said once in a while, so a new session is opened with them, which they
                // accept; until then what they sent can't be read, and what's sent to them can't be either.
                // Also with no session at all: a device that lost its keys still hears from a chat it once had.
                unreadable[keptKey] = Unreadable(fingerprint: fp, persona: persona, device: data.contacts[i].devices[d].id,
                                                 since: unreadable[keptKey]?.since ?? Date())
                mendSession(contact: i, device: d)
                return .handled
            }
            // The keys were kept above, before reading what it says, so a message this version can't read (one from a
            // newer app) still counts and doesn't leave the session behind.
            unreadable[keptKey] = nil
            deadSpareFrom[keptKey] = nil
            noteSeen(readBefore, in: .ratchet)
            guard let inner = try? Payload.fromWire(plain), !inner.isSetup else { return .handled }
            handlingSentAt = opened.sentAt
            handle(inner, from: fp, persona: persona, device: device)
            handlingSentAt = nil
            // The first message in lets a new session start sending. Look them up again: handling it may
            // have removed them (a burned burner, say).
            if let i = contactIndex(fp, persona) { sendPending(contact: i) }
            return .handled
        default:
            // Anything else arriving outside a session is refused.
            return .junk
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
        if (data.contacts[i].devices[d].takesSpares == true) != opened.takesSpares {
            data.contacts[i].devices[d].takesSpares = opened.takesSpares ? true : nil
        }
        if (data.contacts[i].devices[d].readsSharedGroups == true) != opened.readsSharedGroups {
            data.contacts[i].devices[d].readsSharedGroups = opened.readsSharedGroups ? true : nil
        }
        if (data.contacts[i].devices[d].readsMediaBlobs == true) != opened.readsMediaBlobs {
            data.contacts[i].devices[d].readsMediaBlobs = opened.readsMediaBlobs ? true : nil
        }
        if (data.contacts[i].devices[d].readsChannels == true) != opened.readsChannels {
            data.contacts[i].devices[d].readsChannels = opened.readsChannels ? true : nil
        }
        // Said on everything it sends, so a device that updates is let in again by its next envelope. A ratchet message in an
        // older header form is behind whatever its envelope says, so it never lets the device back in.
        var behind = !opened.readsPostQuantumRatchet
        if case let .ratchet(message) = opened.payload, (message.header.v ?? 0) < RatchetHeader.version { behind = true }
        if behind {
            markNeedsUpdate(contact: i, device: d)
        } else if data.contacts[i].devices[d].needsUpdate == true {
            data.contacts[i].devices[d].needsUpdate = nil
        }
    }

    /// A friend's device is on a build from before this one's ratchet: nothing goes either way until it updates, and the chat
    /// says by name whose app has to update, once each time it falls behind.
    private func markNeedsUpdate(contact i: Int, device d: Int) {
        guard data.contacts[i].devices[d].needsUpdate != true else { return }
        data.contacts[i].devices[d].needsUpdate = true
        guard !data.contacts[i].isSelf, !data.contacts[i].hidden else { return }
        let fp = data.contacts[i].fingerprint, persona = data.contacts[i].persona
        if let c = data.conversations.firstIndex(where: { $0.kind == .direct && $0.members == [fp] && $0.persona == persona }) {
            data.conversations[c].messages.append(Message(sender: "system", text: "\(data.contacts[i].displayName) needs to update Pulshade before you can message each other.",
                                                          date: Date()))
        }
        save()
    }

    static let maxAvatarBytes = 512 * 1024
    /// The most friend requests kept waiting for an answer.
    static let maxRequests = 200
    /// The most clips one sender may have part-way here at once, out of the 32 there is room for.
    static let maxClipsPerSender = 6
    static let maxBannerBytes = 2 * 1024 * 1024
    static let maxDevicesPerContact = 16

    /// Longer than the relay keeps anything (30 days).
    static let replayWindow: TimeInterval = 32 * 24 * 3600
    /// How long a seen envelope's digest is kept. The age check uses the relay's clock, which a hostile relay can
    /// move by up to `RelayClock`'s 7-day limit to make an old envelope look young, so digests outlive that too.
    static let seenRetention: TimeInterval = replayWindow + 7 * 24 * 3600

    /// The most envelope digests kept. Far more than a busy account sees in the retention time; past it the oldest go
    /// first, so what an outsider can make this table hold is bounded whatever they send.
    @ObservationIgnored var maxSeenEnvelopes = 50_000

    /// Whether a digest is in a pool. Digests saved before the pools existed have no prefix, so those count for all of them.
    private func wasSeen(_ digest: String, in pool: SeenPool) -> Bool {
        data.seenEnvelopes[pool.prefix + digest] != nil || data.seenEnvelopes[digest] != nil
    }

    /// Writes a digest down in its pool. Past `maxSeenEnvelopes` in that pool the oldest of it go, and the newest time
    /// among them becomes the pool's floor, below which its envelopes are refused, so flooding it can't make an old one
    /// count again. Other pools are untouched.
    private func noteSeen(_ digest: String, in pool: SeenPool, sentAt: Date? = nil) {
        data.seenEnvelopes[pool.prefix + digest] = max(Date(), sentAt ?? .distantPast)
        // Cheap test first: only when the whole table is past one pool's cap can this pool be.
        guard data.seenEnvelopes.count > maxSeenEnvelopes else { return }
        let mine = data.seenEnvelopes.filter { pool.holds($0.key) }
        guard mine.count > maxSeenEnvelopes else { return }
        let keep = maxSeenEnvelopes * 9 / 10
        let sorted = mine.sorted { $0.value > $1.value }
        for (key, _) in sorted.dropFirst(keep) { data.seenEnvelopes[key] = nil }
        // Send times are whole seconds, so the floor is too: a let-go envelope's send time is still at or under it, and one
        // sent later in that second isn't refused for nothing.
        if let floorKey = pool.floorKey, let dropped = sorted.dropFirst(keep).first?.value {
            let floor = Date(timeIntervalSince1970: dropped.timeIntervalSince1970.rounded(.down))
            data.seenEnvelopes[floorKey] = max(data.seenEnvelopes[floorKey] ?? .distantPast, floor)
        }
    }

    /// Tests: the floor of the pool contacts' envelopes count in, and of the one anyone's can, if they were ever full.
    var seenFloorForTests: Date? { data.seenEnvelopes[SeenPool.contact.floorKey!] }
    var strangerFloorForTests: Date? { data.seenEnvelopes[SeenPool.stranger.floorKey!] }

    /// Tests: writes a digest down as if an envelope of that pool had been read.
    func noteSeenForTests(_ digest: String, in pool: SeenPool, sentAt: Date) { noteSeen(digest, in: pool, sentAt: sentAt) }

    /// Tests: how many envelope digests are kept.
    var seenEnvelopeCount: Int { data.seenEnvelopes.keys.filter { !AppData.seenFloorKeys.contains($0) }.count }

    private func handle(_ payload: Payload, from fp: String, persona: UUID?, device: Data) {
        guard var sender = contact(fp, in: persona) else { return }
        switch payload {
        case .report:
            // Reports go to the Pulshade Admin app, sealed on their own; one arriving here means nothing.
            break
        case let .groupInvite(invite):
            acceptGroupInvite(invite, from: sender)
        case let .groupJoin(group, card):
            acceptGroupJoin(group, card: card, from: sender)
        case let .channelLeave(group):
            // From a follower, over the chat they were invited in; who they are comes from this chat's session.
            guard !sender.isSelf else { break }
            followerLeft(group, from: sender)
        case let .channelKeyWanted(group, held):
            guard !sender.isSelf else { break }
            answerKeyRequest(group, held: held, from: sender)
        case let .groupChainWanted(group, wants):
            guard !sender.isSelf else { break }
            answerFollowerChainWants(group, wants: wants, from: sender)
        case let .groupChainKeys(group, keys):
            guard !sender.isSelf else { break }
            takeChainKeysFromInviter(group, keys: keys, from: sender)
        case .groupSettings, .groupRekey, .groupLinks, .groupRoster, .groupKeyWanted, .groupCatchUp, .memberCard, .friendAsk, .membersAdded, .left,
             .groupDirect:
            // Only ever said in a group's own mailbox.
            break
        case .deviceRemoved:
            guard let i = contactIndex(fp, persona), data.contacts[i].devices.count > 1 else { break }
            data.contacts[i].devices.removeAll { $0.id == device }
        case let .devicesUnlinked(ids, kept):
            // Your own devices hear of it by sync (`deviceLoggedOut`).
            guard let i = contactIndex(fp, persona), !data.contacts[i].isSelf else { break }
            devicesUnlinked(ids, kept: kept, by: device, contact: i)
        case .erased:
            eraseTraces(of: fp)
        case .hello, .request, .pqIntro, .sessionInit, .deviceHello, .sessionAccept, .spareAccept, .ratchet, .collected:
            break
        case let .sync(event):
            // Only another device of this account, on a build that could link.
            guard sender.isSelf else { break }
            handleOwnDevice(event)
        case let .callOffer(invite):
            guard !sender.isSelf, !sender.hidden else { break }
            receiveCall(invite, from: sender)
        case let .callAnswer(id, accepted):
            guard !sender.isSelf else { break }
            callAnswered(id, accepted: accepted, by: sender)
        case let .callEnd(id):
            guard call?.invite.id == id, call?.peer == fp, call?.persona == persona else { break }
            endCall(note: call?.phase == .ringing && call?.outgoing == false ? "Missed call" : nil, tell: false)
        case let .profile(name, avatar, color, banner, bio, handle, links, notes):
            sender.name = String(name.prefix(64))
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
            // A message for a group or channel only comes in that group's own mailbox (see `receiveGroupMail`), never one by one.
            guard wire.conversation == nil else { break }
            deliver(wire, from: sender)
        case let .receipt(ids, read):
            // With read receipts off you don't see other people's either.
            let seen = read == true && data.security.readReceipts
            withAnimation(.smooth) { for id in ids { noteDelivery(of: id, by: fp, read: seen) } }
        case let .story(id, style, date, lasts, loops):
            // Already taken back: a late or repeated copy mustn't bring it back. And only a friend's: someone you only
            // share a group with doesn't get to show you stories, whatever their app sends.
            guard removedStories["\(fp)|\(id)"] == nil, !sender.hidden, !sender.awaitingAcceptance else { break }
            let cleanedStyle = Self.cleanedStoryStyle(style)
            let lifetime = lasts.map { min(max($0, 3600), StoryLifetime.twoDays.rawValue) }
            // The same story can reach two of your personas (one friend in both): each keeps its own copy, so
            // only the copy for this persona counts as "sent before". The id is never taken from someone else.
            guard !data.stories.contains(where: { $0.id == id && $0.author != fp }) else { break }
            if let i = data.stories.firstIndex(where: { $0.id == id && $0.author == fp && $0.persona == persona }) {
                // A new version of one they sent before. New media that would push this device over is ignored, so
                // the media already stored is never deleted.
                let oldBytes = Self.mediaBytes(data.stories[i])
                let newBytes = Self.mediaBytes(cleanedStyle)
                // Recount first: a story update after something was deleted must not be refused for a total that
                // no longer reflects what is stored.
                if newBytes > 0, !fitsReceivedMedia(newBytes - oldBytes) { break }
                var style = cleanedStyle
                // A new caption on a clip they already sent comes without the clip.
                if case let .video(bytes, caption) = style, bytes.isEmpty, case let .video(have, _) = data.stories[i].style, !have.isEmpty {
                    style = .video(have, caption: caption)
                }
                if case let .image(bytes, caption) = style, bytes.isEmpty, case let .image(have, _) = data.stories[i].style, !have.isEmpty {
                    style = .image(have, caption: caption)
                }
                var newRef: MediaFileRef?
                if newBytes > 0 {
                    switch style {
                    case let .image(data, caption):
                        if let ref = storeReceivedMedia(data) { style = .image(Data(), caption: caption); newRef = ref }
                    case let .video(data, caption):
                        if let ref = storeReceivedMedia(data) { style = .video(Data(), caption: caption); newRef = ref }
                    case .text:
                        break
                    }
                }
                let oldRef = data.stories[i].mediaFile
                data.stories[i].style = style
                if newBytes > 0 {
                    deleteStoredMedia(oldRef)
                    data.stories[i].mediaFile = newRef
                }
                data.stories[i].lifetime = lifetime
                data.stories[i].loops = loops == true ? true : nil
                receivedMediaBytes += Self.mediaBytes(data.stories[i]) - oldBytes
                if newBytes > 0 {
                    data.stories[i].mediaDropped = nil
                    data.stories[i].mediaGone = nil
                }
                if !data.stories[i].isLive {
                    receivedMediaBytes -= Self.mediaBytes(data.stories[i])
                    data.stories.remove(at: i)
                    break
                }
                acknowledgeStory(id, author: fp, persona: persona)
                // Sent again because pieces went missing: what's here now may complete it. The story arriving again
                // is not progress (only a piece is), or a sender that keeps repeating it would keep this from
                // ever asking for the clip.
                if data.stories[i].isReady || data.stories[i].mediaDropped == true {
                    clipActivity[ClipKey(id, persona)] = nil
                } else if clipActivity[ClipKey(id, persona)] == nil {
                    clipActivity[ClipKey(id, persona)] = Date()
                }
                assembleClip(id, persona: persona)
                break
            }
            let styleBytes = Self.mediaBytes(cleanedStyle)
            var style = cleanedStyle
            var dropped = false
            if styleBytes > 0, !fitsReceivedMedia(styleBytes) {
                style = Self.withoutMedia(style)
                dropped = true
            }
            var storyMedia: MediaFileRef?
            if !dropped, styleBytes > 0 {
                switch style {
                case let .image(data, caption):
                    if let ref = storeReceivedMedia(data) { style = .image(Data(), caption: caption); storyMedia = ref }
                case let .video(data, caption):
                    if let ref = storeReceivedMedia(data) { style = .video(Data(), caption: caption); storyMedia = ref }
                case .text:
                    break
                }
            }
            var story = Story(id: id, author: fp, style: style, date: dated(date))
            story.mediaFile = storyMedia
            story.mediaDropped = dropped ? true : nil
            if !story.isReady {
                if dropped || !fitsReceivedMedia(0) {
                    story.mediaDropped = true
                    clipActivity[ClipKey(id, persona)] = nil
                } else {
                    clipActivity[ClipKey(id, persona)] = Date()
                }
            }
            story.persona = persona
            story.lifetime = lifetime
            story.loops = loops == true ? true : nil
            if story.isLive {
                // A contact may send as many distinct story ids as they like. Past a hundred live ones for this author
                // and persona, the oldest go, so a flood can't fill the vault or make every scan grow without end.
                let theirs = data.stories.filter { $0.author == fp && $0.persona == persona }
                if theirs.count >= Self.maxStoriesPerAuthor {
                    let keep = Set(theirs.sorted { $0.date > $1.date }.prefix(Self.maxStoriesPerAuthor - 1).map(\.id))
                    data.stories.removeAll { $0.author == fp && $0.persona == persona && !keep.contains($0.id) }
                }
                receivedMediaBytes += Self.mediaBytes(story)
                withAnimation(.snappy) { data.stories.append(story) }
            }
            assembleClip(id, persona: persona)
            acknowledgeStory(id, author: fp, persona: persona)
        case let .storyPart(id, index, of, bytes):
            let key = ClipKey(id, persona)
            guard removedStories["\(fp)|\(id)"] == nil else { break }
            // A piece sent again after the clip came together, or for a story whose media was not saved: nothing to do,
            // unless the user has just asked for that item again.
            if !mediaRequested.contains(id), data.stories.contains(where: { $0.id == id && $0.author == fp && $0.persona == persona
                && ($0.isReady || $0.mediaDropped == true) }) { break }
            if let at = mediaMessage(id, persona: .some(persona)), data.conversations[at.convo].persona == persona,
               (data.conversations[at.convo].messages[at.message].mediaDropped == true
                || !Self.isPending(data.conversations[at.convo].messages[at.message])), !mediaRequested.contains(id) { break }
            guard (1...StoryClipPieces.maxPieces).contains(of), (0..<of).contains(index), bytes.count <= StoryClipPieces.framedSize,
                  data.clipParts[key.stored] != nil
                    || (data.clipParts.count < 32 && data.clipParts.values.filter { $0.author == fp }.count < Self.maxClipsPerSender)
            else { break }
            var pending = data.clipParts[key.stored] ?? ClipParts(id: id, author: fp, persona: persona, of: of)
            guard pending.author == fp, pending.persona == persona else { break }
            // Cut differently from the pieces already here (their app or mine updated part-way): start over with these.
            if pending.of != of { pending = ClipParts(id: id, author: fp, persona: persona, of: of) }
            pending.parts[index] = bytes
            // A clip arrives a piece at a time; keep the pieces to the size the finished clip is allowed, so a sender
            // can't park megabytes of parts here waiting to be joined.
            guard Self.storyClipFits(pending.parts) else { break }
            data.clipParts[key.stored] = pending
            clipActivity[key] = Date()
            assembleClip(id, persona: persona)
        case let .clipBlob(id, a):
            guard a.isValid, [.video, .photo, .voice].contains(a.kind), a.size <= 8_000_000 else { break }
            receiveClipBlob(id, a, from: sender, persona: persona)
        case let .storyReceived(id):
            // One of my contacts has the story: it's no longer sent to them again.
            guard let i = data.stories.firstIndex(where: { $0.id == id && $0.author == "me" && $0.persona == persona }),
                  var delivery = data.stories[i].delivery, !delivery.confirmed.contains(fp) else { break }
            delivery.confirmed.append(fp)
            data.stories[i].delivery = delivery
        case let .storyWant(id, parts):
            // A video, photo or voice note you sent them in a chat they're in: again.
            if let at = mediaMessage(id, persona: .some(persona)), data.conversations[at.convo].messages[at.message].isMine,
               data.conversations[at.convo].persona == persona, data.conversations[at.convo].members.contains(fp),
               let sent = Self.sentMedia(data.conversations[at.convo].messages[at.message]),
               !sender.isSelf, !data.blocked.contains(fp) {
                let key = "\(fp)|\(id)"
                if let last = clipResent[key], Date().timeIntervalSince(last) < clipQuiet { break }
                clipResent[key] = Date()
                deliverClip(sent.bytes, id: id, to: sender, known: nil, only: parts, kind: sent.kind)
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
            if let story = data.stories.first(where: { $0.id == id && $0.author == fp && $0.persona == persona }) {
                deleteStoredMedia(in: story)
            }
            withAnimation { data.stories.removeAll { $0.id == id && $0.author == fp && $0.persona == persona } }
        case .storiesWanted:
            // A friend's account was recovered and has no stories: theirs are sent again, by the audience each one has
            // (so only what they could already see). Asked at most once in ten minutes, since a story can be a big video.
            let key = "\(fp)|\(persona?.uuidString ?? "main")"
            guard !sender.isSelf, !sender.hidden, !sender.awaitingAcceptance, !data.blocked.contains(fp),
                  Date().timeIntervalSince(storiesWantedAt[key] ?? .distantPast) > 600 else { break }
            storiesWantedAt[key] = Date()
            shareStories(with: sender)
        case .storiesCleared:
            // Only theirs: whoever sends this can take back their own stories and nobody else's.
            for story in data.stories where story.author == fp && story.persona == persona {
                noteRemoved("\(fp)|\(story.id)")
                deleteStoredMedia(in: story)
            }
            data.clipParts = data.clipParts.filter { !($0.value.author == fp && $0.value.persona == persona) }
            withAnimation { data.stories.removeAll { $0.author == fp && $0.persona == persona } }
        case let .unsend(ids):
            applyUnsend(ids, from: sender)
        case let .reaction(message, emoji):
            applyReaction(emoji, to: message, from: sender)
        case let .typing(shared):
            // A typing signal waits on the relay as long as a message would, so one that reached it a while ago says
            // nothing now.
            guard data.security.typingIndicators, Self.isFreshSignal(deposited: deposited),
                  let i = conversationIndex(shared, from: sender) else { break }
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
            // Only in a direct chat: a group's timer is part of its settings.
            guard shared == nil, let i = conversationIndex(shared, from: sender, create: true),
                  data.conversations[i].disappearAfter != seconds else { break }
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
            // Only a direct chat is deleted this way. A group's owner deletes it in the group's own mailbox.
            guard shared == nil, let i = conversationIndex(nil, from: sender) else { break }
            removeLocally(data.conversations[i].id)
        case let .mailbox(sendID):
            // That device of theirs reads us on a new mailbox now (`tendMailboxes` on their side). Only the device the session
            // is with can say so, so it isn't a new device and nothing is held.
            guard sendID.count == 32, let i = contactIndex(fp, persona), let d = deviceIndex(i, device),
                  data.contacts[i].devices[d].session != nil else { break }
            data.contacts[i].devices[d].sendID = sendID
            save()
        case let .accepted(sendID):
            // They accepted our request: switch to the private mailbox they opened for us.
            guard sender.awaitingAcceptance, sendID.count == 32 else { break }
            sender.sendID = sendID
            sender.awaitingAcceptance = false
            upsert(sender)
            let convo = startConversation(kind: .direct, title: sender.displayName, members: [fp], persona: .some(persona))
            noteConnected(convo.id)
            shareStories(with: sender)
        }
    }

    /// Most people kept for one channel who said hello on its code and haven't got in yet.
    @ObservationIgnored var maxCodeStrangers = AppModel.defaultMaxCodeStrangers
    static let defaultMaxCodeStrangers = 1_000
    /// How long someone who said hello on a channel's code and never got in is kept: as long as their invite lasts.
    static let codeStrangerLife: TimeInterval = inviteLife

    /// Makes room for one more person saying hello on a channel's code. Whoever said hello longer ago than an invite
    /// lasts and never got in is let go; past the limit, the one who said hello first and hasn't got in (and isn't
    /// waiting their turn) makes way, so a flood of throwaway accounts that never answer can't keep newcomers out.
    /// False only if everyone held is waiting their turn.
    private func roomForCodeHello(_ channel: UUID, persona: UUID?) -> Bool {
        let now = Date()
        func shared(_ c: Contact) -> SharedGroup? { c.viaCode.flatMap { index(of: $0) }.flatMap { data.conversations[$0].shared } }
        func admitted(_ c: Contact) -> Bool { shared(c)?.knownAs[c.fingerprint] != nil }
        func queued(_ c: Contact) -> Bool { shared(c)?.joinWaiting?.contains(c.fingerprint) == true }
        func invitedLately(_ c: Contact) -> Bool {
            shared(c)?.invited[c.fingerprint].map { now.timeIntervalSince($0) < Self.inviteLife } == true
        }
        func inAGroup(_ c: Contact) -> Bool {
            data.conversations.contains { $0.persona == c.persona && ($0.members.contains(c.fingerprint) || $0.owner == c.fingerprint) }
        }
        // Anyone this account depends on, whatever channel code they first came through: the one a channel is followed
        // through, someone known in any channel, someone invited to (or asked to staff) a channel other than the one whose
        // code they said hello on, or someone asked to be a friend. An unanswered invite to that same channel doesn't count:
        // that's the stranger the limit is for.
        let convos = data.conversations
        let inviters = Set(convos.compactMap { $0.shared?.ownerAccount })
        let known = Set(convos.flatMap { $0.shared?.knownAs.keys.map { $0 } ?? [] })
        func neededElsewhere(_ c: Contact) -> Bool {
            inviters.contains(c.fingerprint) || known.contains(c.fingerprint)
                || convos.contains { $0.id != c.viaCode && ($0.shared?.invited[c.fingerprint] != nil || $0.shared?.staffInvited?[c.fingerprint] != nil) }
        }
        func stranger(_ c: Contact) -> Bool {
            c.viaCode != nil && c.hidden && !c.isSelf && !c.awaitingAcceptance && !admitted(c) && !inAGroup(c) && !neededElsewhere(c)
        }
        // Worked out first and taken out after: the checks read the vault's data, which can't be read while it's changed.
        let contacts = data.contacts
        var gone = Set(contacts.indices.filter { i in
            let c = contacts[i]
            return stranger(c) && now.timeIntervalSince(c.addedAt) > Self.codeStrangerLife && !queued(c) && !invitedLately(c)
        })
        var held = contacts.indices.filter { !gone.contains($0) && contacts[$0].viaCode == channel && contacts[$0].persona == persona && stranger(contacts[$0]) }
        while held.count >= maxCodeStrangers {
            guard let oldest = held.filter({ !queued(contacts[$0]) }).min(by: { contacts[$0].addedAt < contacts[$1].addedAt }) else { break }
            gone.insert(oldest)
            held.removeAll { $0 == oldest }
        }
        if !gone.isEmpty {
            data.contacts = contacts.indices.filter { !gone.contains($0) }.map { contacts[$0] }
            save()
        }
        return held.count < maxCodeStrangers
    }

    private func acceptHello(_ card: PeerCard, _ request: SessionInit, fingerprint fp: String, device: Data,
                             via invite: OpenInvite, pq: PQPin, sentAt: Date? = nil) {
        let persona = invite.persona
        let known = contact(fp, in: persona)
        // Both added each other at about the same time (each scanned the other's code): this hello crossed the one this
        // device sent them. Taking both would leave each side on the keys it answered and reading the mailbox from its
        // own invite, so neither could read or even fetch what the other writes. One side's ask wins on both ends, as
        // with other crossed hellos: the winner keeps its ask, its mailbox and the mailbox it writes to, and leaves this
        // hello unanswered; the other side takes the winner's hello as if it had been added the ordinary way.
        if invite.channel == nil, let known, !known.hidden, let i = contactIndex(fp, persona),
           let d = data.contacts[i].devices.firstIndex(where: { $0.id == device || $0.id.isEmpty }) {
            let link = data.contacts[i].devices[d]
            let crossed = link.handshake != nil || sentAt.map { hello($0, crossedOurs: link) } == true
            // Our side gives way: our hello carried our post-quantum card, but they may read this answer before that hello
            // (another mailbox), so the answer carries the card again.
            if crossed { data.contacts[i].pqCardSent = nil }
            if crossed, let me = me(persona), myHandshakeWins(me: me.fingerprint, persona: persona, them: fp, theirDevice: device) {
                data.contacts[i].pq = pq
                data.contacts[i].name = String(card.name.prefix(64))
                data.contacts[i].avatar = card.avatar
                data.contacts[i].color = card.color
                data.invites.removeAll { $0.receiveKey == invite.receiveKey }
                save()
                return
            }
        }
        var peer = contact(fp, in: persona) ?? Contact(fingerprint: fp, signingKey: card.signingKey,
                                                     agreementKey: card.agreementKey, sendID: card.sendID, device: device)
        peer.persona = persona
        peer.pq = pq
        peer.relay = invite.relay
        peer.name = String(card.name.prefix(64))
        peer.avatar = card.avatar.flatMap { $0.count <= Self.maxAvatarBytes ? $0 : nil }
        peer.color = card.color

        func answer() {
            // A hello that names no device could take over another device's place unannounced.
            guard let i = contactIndex(fp, persona), !device.isEmpty || data.contacts[i].devices.isEmpty else { return }
            let d = upsertDevice(i, id: device, sendID: card.sendID)
            acceptSession(request, contact: i, device: d, context: .hello)
        }

        if let channelID = invite.channel {
            // A friend, or someone already following another of these channels, from an app that leaves things as they are:
            // the hello names the mailbox this device already writes to them at. Nothing about them changes (no new
            // session, nothing replaced); the caller lets them into the channel.
            if let known, known.devices.contains(where: { $0.sendID == card.sendID }) {
                _ = channelID
                return
            }
            if known == nil {
                // A stranger on the code: no picture kept (staff never show one), and only while there's room.
                guard roomForCodeHello(channelID, persona: persona) else { return }
                peer.viaCode = channelID
                peer.avatar = nil
            }
            peer.hidden = known?.hidden ?? true
            upsert(peer)
            answer()
            // The channel invites them into its mailbox once what their app reads is known (`noteReads`, right after this).
            save()
        } else {
            peer.hidden = false
            Self.takeBack(&peer)
            peer.receiveKey = invite.receiveKey
            upsert(peer)
            data.invites.removeAll { $0.receiveKey == invite.receiveKey }
            answer()
            _ = startConversation(kind: .direct, title: peer.displayName, members: [fp], persona: .some(persona))
            shareStories(with: peer)
        }
    }

    /// How many people a channel's code lets in on its own in an hour. The rest wait (kept, and let in as the hour allows),
    /// so someone with the code can't make staff send an invite and rekey for a crowd of throwaway accounts at once.
    @ObservationIgnored var channelAdmitsPerHour = AppModel.defaultChannelAdmitsPerHour
    static let defaultChannelAdmitsPerHour = 60

    /// Invites people who followed through a channel's code, up to the hourly limit; the rest wait. Only people who are new
    /// count: someone already in the roster, or invited within the hour, or already waiting is skipped (one identity saying
    /// hello again and again uses no more of the limit and sends nothing more). People this account knows otherwise (a
    /// friend) go first. Strangers are let in by lot, and when the waiting list is full a newcomer takes a place drawn at
    /// random: whoever keeps the list topped up with throwaway accounts can't hold everyone else out for good, as keeping the
    /// earliest would let them. Called with no one new, it lets in whoever is waiting as the hour allows.
    private func admitFromCode(_ fingerprints: [String], at i: Int) {
        guard let shared = data.conversations[i].shared else { return }
        let id = data.conversations[i].id
        let now = Date()
        let known = Set(shared.roster?.live.map { Identity.fingerprint(of: $0.signingKey) } ?? [])
        let live = Set(shared.knownAs.filter { known.contains($0.value) }.keys)
        func settled(_ fp: String) -> Bool {
            live.contains(fp) || shared.invited[fp].map { now.timeIntervalSince($0) < 3600 } == true
        }
        let persona = data.conversations[i].persona
        var seen = Set<String>()
        var queue = (shared.joinWaiting ?? []).filter { !settled($0) && seen.insert($0).inserted }
        for fp in fingerprints where !settled(fp) && seen.insert(fp).inserted { queue.append(fp) }
        let friends = Set(data.contacts.filter { $0.persona == persona && !$0.hidden }.map(\.fingerprint))
        queue = queue.filter { friends.contains($0) } + queue.filter { !friends.contains($0) }.shuffled()
        let recent = (channelAdmits[id] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        let room = max(0, channelAdmitsPerHour - recent.count)
        let go = Array(queue.prefix(room))
        var rest = Array(queue.dropFirst(room))
        channelAdmits[id] = recent + go.map { _ in now }
        if !go.isEmpty {
            // Whoever the invite refused for good (an app too old) is dropped; whoever it simply had no room for waits.
            let refused = Set(invite(go, at: i))
            let invited = data.conversations[i].shared?.invited ?? [:]
            let unplaced = go.filter { !refused.contains($0) && invited[$0] == nil && contact($0, in: persona) != nil }
            rest = unplaced + rest
        }
        data.conversations[i].shared?.joinWaiting = rest.isEmpty ? nil : Array(rest.prefix(GroupRoster.Body.maxEntries))
    }

    /// The conversation a signal from `sender` belongs to: a shared group/channel id, or their direct chat.
    private func conversationIndex(_ shared: UUID?, from sender: Contact, create: Bool = false) -> Int? {
        if let shared {
            // Never one kept in the older format: nothing is read for it any more.
            guard let found = groupIndex(shared, persona: sender.persona), !data.conversations[found].isOldFormat,
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

    func deliver(_ wire: WireMessage, from sender: Contact) {
        guard let i = conversationIndex(wire.conversation, from: sender, create: true) else { return }
        if wire.conversation != nil, !data.conversations[i].canPost(sender.fingerprint) { return }
        guard !data.conversations[i].messages.contains(where: { $0.id == wire.id }) else {
            // Sent again because the relay may have lost it: say again that it's here, so their tick catches up. Only
            // so often (`Lanes.duplicateReceiptGap`), so sending the same message over and over can't be used to find
            // out when this device is running.
            if wire.conversation == nil { queueReceipt(wire.id, to: sender, duplicate: true) }
            return
        }
        let date = dated(wire.date)
        let expires = wire.expiresIn.map { date.addingTimeInterval(min($0, Disappear.week.rawValue)) }
        if let expires, expires <= Date() { return }
        let mine = myFingerprint(in: data.conversations[i])
        let reply = wire.reply.map { quoted in
            // Attribute a quote only from what this device already holds: a message in this chat, or a story here.
            // Never trust the author the sender claims, and never show an author for something not found locally.
            let known = data.conversations[i].messages.first { $0.id == quoted.id }?.sender
                ?? data.stories.first { $0.id == quoted.id }?.author
            let author = known.map { $0 == mine ? "me" : $0 } ?? ""
            return ReplyRef(id: quoted.id, author: author, snippet: String(quoted.snippet.prefix(120)),
                            picture: quoted.picture.flatMap { $0.count <= ReplyRef.maxPicture && PlatformImage.checked($0) != nil ? $0 : nil })
        }
        let preview = wire.preview.flatMap { p in
            !LinkPreviews.isWebLink(p.url) ? nil  // only plain http(s) links
                : LinkPreview(url: p.url, title: p.title.map { String($0.prefix(200)) }, site: p.site.map { String($0.prefix(80)) },
                              image: p.image.flatMap { $0.count <= 400_000 ? $0 : nil })
        }
        // A picture too big to decode is left off; the words stay.
        let picture = wire.image.flatMap { ImageLimits.isReasonable($0) || $0.isEmpty ? $0 : nil }
        var message = Message(id: wire.id, sender: sender.fingerprint, text: String(wire.text.prefix(20_000)),
                              image: picture, voice: wire.voice?.checked, date: date, status: .delivered, expiresAt: expires,
                              reply: reply, preview: preview)
        // A note card is just a title: opening it reads the note from their profile.
        message.note = wire.note.flatMap(NoteCard.cleaned)
        message.noForward = wire.noForward == true ? true : nil
        message.forwarded = wire.forwarded == true ? true : nil
        // A mention counts only in a group, and only as far as it fits the words; yours is stored as "me".
        if data.conversations[i].kind == .group {
            message.mentions = Mention.cleaned(wire.mentions, in: message.text).map {
                Mention(fingerprint: $0.fingerprint == mine ? "me" : $0.fingerprint, start: $0.start, length: $0.length)
            }
        }
        // A file on the relay: kept only if well-formed and not already gone. The words that stood in for it are dropped.
        if let a = wire.attachment, a.isValid, a.expires > RelayClock.now {
            var a = a
            // As long as the relay keeps it (`chatFileLife` one to one, a week in groups), and a day more for clocks.
            let life = data.conversations[i].kind == .direct ? Self.chatFileLife : 7 * 86_400
            a.expires = min(a.expires, RelayClock.now.addingTimeInterval(life + 86_400))
            message.attachment = a
            message.text = ""
        }
        let roomForNewMedia = fitsReceivedMedia(0)
        let clipKey = ClipKey(wire.id, data.conversations[i].persona)
        if let clip = wire.clip {
            // A video: its clip comes in pieces after this (some may be here already).
            message.clipSeconds = min(max(clip.seconds, 0), ChatVideo.maxSeconds)
            if roomForNewMedia {
                message.video = Data()
                clipActivity[clipKey] = Date()
            } else {
                message.mediaDropped = true
                message.image = nil
            }
        } else if message.attachment == nil, let follows = wire.mediaFollows {
            // A photo or voice note that follows on its own: until then the message holds a tiny preview, or the voice
            // note's length and waveform.
            if roomForNewMedia {
                switch follows {
                case .photo where wire.voice == nil:
                    message.awaiting = .photo
                    if let preview = message.image, preview.count > ReplyRef.maxPicture { message.image = nil }
                case .voice where wire.voice != nil && wire.image == nil:
                    message.awaiting = .voice
                    message.voice?.audio = Data()
                default:
                    break
                }
                if message.awaiting != nil { clipActivity[clipKey] = Date() }
            } else {
                message.mediaDropped = true
                message.image = nil
                message.voice?.audio = Data()
            }
        }
        // The photo and voice note go into the sealed pool below, where they take their padded size on disk.
        var incomingMedia = Self.mediaBytes(message)
        if message.awaiting == nil, let image = message.image, !image.isEmpty {
            incomingMedia += MediaPool.sealedSize(ofPlain: image.count) - image.count
        }
        if let audio = message.voice?.audio, !audio.isEmpty {
            incomingMedia += MediaPool.sealedSize(ofPlain: audio.count) - audio.count
        }
        var counted = false
        if incomingMedia > 0 {
            if fitsReceivedMedia(incomingMedia) {
                receivedMediaBytes += incomingMedia
                counted = true
            } else {
                // Too much here already: keep the words, time and reactions, and let the UI offer to fetch the main
                // media anyway. Small quote and link-preview pictures are simply left off.
                let hadPrimary = message.image != nil || message.video != nil || message.voice != nil
                message.image = nil
                message.video = nil
                message.voice?.audio = Data()
                message.reply?.picture = nil
                message.preview?.image = nil
                message.awaiting = nil
                if hadPrimary { message.mediaDropped = true }
                message.mediaGone = nil
                clipActivity[clipKey] = nil
            }
        }
        // Received media lives in the sealed pool; the vault keeps only the reference. If sealing fails, the inline
        // bytes stay in the encrypted vault rather than anything going to disk in the clear.
        if message.awaiting == nil, let image = message.image, !image.isEmpty, let ref = storeReceivedMedia(image) {
            message.image = nil
            message.imageFile = ref
        }
        if let voice = message.voice, !voice.audio.isEmpty, let ref = storeReceivedMedia(voice.audio) {
            message.voice?.audio = Data()
            message.voice?.audioFile = ref
        }
        // What was counted above assumed both went into the pool; one that stayed inline counts its own length.
        if counted { receivedMediaBytes += Self.mediaBytes(message) - incomingMedia }
        typing[data.conversations[i].id]?[sender.fingerprint] = nil
        withAnimation(.snappy(duration: 0.4)) { data.conversations[i].messages.append(message) }
        if Self.isPending(message) { assembleClip(wire.id, persona: data.conversations[i].persona) }
        if openConversation != data.conversations[i].id || !appActive { data.conversations[i].unread += 1 }
        if !data.conversations[i].muted { data.conversations[i].archived = false }
        notify(message, at: i)
        // Only a direct chat has ticks (a group's mail is "sent" once it's in the mailbox). Seen straight away when the chat
        // is open in front of you.
        if wire.conversation == nil {
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

    /// Delivery receipts wait a random while (`Lanes.receiptDelay`, 5 to 20 seconds) and go out together, each on a
    /// connection used for nothing else (`Lanes.once`), so a receipt doesn't follow the fetch that brought the message
    /// closely enough, or on the same circuit as anything else, to show the relay who was writing to whom.
    /// Read receipts are batched the same way.
    private func queueReceipt(_ id: UUID, to sender: Contact, read: Bool = false, duplicate: Bool = false) {
        lastIncomingAt = Date()
        if duplicate, !allowDuplicateReceipt(id, from: sender) { return }
        // Delivery receipts always go (the sender would otherwise keep sending again); read receipts only with the setting on.
        if let i = pendingReceipts.firstIndex(where: { $0.fingerprint == sender.fingerprint && $0.persona == sender.persona
                                                       && $0.read == read }) {
            if !pendingReceipts[i].ids.contains(id) { pendingReceipts[i].ids.append(id) }
            return
        }
        let wait = trafficShaping ? Lanes.receiptWait(room: appActive ? nil : backgroundRoom) : 0
        pendingReceipts.append(ReceiptBatch(fingerprint: sender.fingerprint, persona: sender.persona, ids: [id], read: read,
                                            due: Date().addingTimeInterval(wait)))
    }

    /// When a receipt for a duplicate went out, by message, and those sent for each contact (fingerprint and persona) in
    /// the last hour. Memory only.
    @ObservationIgnored private var duplicateReceipts: [UUID: Date] = [:]
    @ObservationIgnored private var duplicateReceiptsByContact: [String: [Date]] = [:]

    /// Whether a duplicate of message `id` may be answered with a receipt now: once a day for each message, and no more
    /// than `Lanes.duplicateReceiptsPerHour` an hour for each contact.
    func allowDuplicateReceipt(_ id: UUID, from sender: Contact, now: Date = Date()) -> Bool {
        if let at = duplicateReceipts[id], now.timeIntervalSince(at) < Lanes.duplicateReceiptGap { return false }
        let who = presenceKey(sender.fingerprint, sender.persona)
        let recent = (duplicateReceiptsByContact[who] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        guard recent.count < Lanes.duplicateReceiptsPerHour else { duplicateReceiptsByContact[who] = recent; return false }
        duplicateReceiptsByContact[who] = recent + [now]
        if duplicateReceipts.count > 5000 { duplicateReceipts = duplicateReceipts.filter { now.timeIntervalSince($0.value) < Lanes.duplicateReceiptGap } }
        duplicateReceipts[id] = now
        return true
    }

    /// Seconds left of the time iOS gives a wake-up push, less what sending a receipt on a fresh circuit takes. Nil when
    /// there is no such limit (the app in front, the macOS test build, or no push being handled).
    private var backgroundRoom: TimeInterval? {
        guard let started = pushHandlingSince else { return nil }
        return Self.pushWindow - Date().timeIntervalSince(started) - Self.receiptSendTime
    }
    /// When the wake-up push being handled now arrived. Memory only.
    @ObservationIgnored private var pushHandlingSince: Date?
    /// About what iOS allows a woken app, and what a receipt on a fresh circuit needs of it.
    static let pushWindow: TimeInterval = 28
    static let receiptSendTime: TimeInterval = 8

    func sendDueReceipts() {
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
        where !data.conversations[i].isOldFormat
            && data.conversations[i].messages.contains(where: { ids.contains($0.id) && $0.sender == sender.fingerprint }) {
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
        for i in data.conversations.indices
        where data.conversations[i].persona == sender.persona && !data.conversations[i].isOldFormat
            && data.conversations[i].members.contains(sender.fingerprint) {
            guard let m = data.conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { continue }
            let clean = emoji.map { String($0.prefix(8)) }
            withAnimation(.snappy) { data.conversations[i].messages[m].reactions[sender.fingerprint] = clean }
            return
        }
    }

    // MARK: - Group & channel management

    /// Whether you can post here right now.
    func canPost(in convo: Conversation) -> Bool {
        switch convo.kind {
        case .direct: peerNeedingUpdate(in: convo) == nil
        case .broadcast: true
        // A group or channel kept in the older format (a copy sent to each member) can still be read, but nothing goes in it.
        case .group, .channel: !convo.isOldFormat && convo.canPost("me") && !(convo.shared.map { $0.joining || $0.gone } ?? false)
        }
    }

    /// Why you can't post in a group or channel when the cause isn't who may post: still joining, or no longer in it.
    func cantPostReason(in convo: Conversation) -> String? {
        guard convo.kind == .group || convo.kind == .channel, let shared = convo.shared else { return nil }
        let noun = convo.kind == .channel ? "channel" : "group"
        if shared.gone { return "You're no longer in this \(noun)." }
        if shared.joining { return "Joining. You can post once an admin's phone has added you." }
        return nil
    }

    /// In a chat with one friend: their name, if their app is from before the sparse post-quantum ratchet and has to update
    /// before anything can go either way.
    func peerNeedingUpdate(in convo: Conversation) -> String? {
        guard convo.kind == .direct else { return nil }
        let behind = friendsNeedingUpdate(persona: convo.persona)
        return convo.members.first { behind.contains($0) }.map { displayName($0) }
    }

    /// In a channel you run: everyone who isn't an admin.
    func followers(of convo: Conversation) -> [String] {
        convo.members.filter { !convo.isAdmin($0) }
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

    /// Bumps the version and tells everyone who needs to know.
    private func publishChange(_ i: Int) {
        if data.conversations[i].shared != nil { publishSharedChange(i) }
    }

    func updateDetails(_ id: Conversation.ID, title: String, about: String, avatar: Data?) {
        guard let i = index(of: id), data.conversations[i].shared != nil, data.conversations[i].amAdmin else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        data.conversations[i].title = trimmed.isEmpty ? data.conversations[i].title : String(trimmed.prefix(80))
        data.conversations[i].about = about.isEmpty ? nil : String(about.prefix(500))
        data.conversations[i].avatar = avatar
        publishChange(i)
    }

    func setPostPolicy(_ id: Conversation.ID, _ policy: PostPolicy) {
        guard let i = index(of: id), data.conversations[i].shared != nil, data.conversations[i].amOwner else { return }
        data.conversations[i].postPolicy = policy
        publishChange(i)
    }

    /// Only the owner appoints or removes admins.
    func setAdmin(_ id: Conversation.ID, _ fingerprint: String, _ on: Bool) {
        guard let i = index(of: id), data.conversations[i].shared != nil, data.conversations[i].amOwner,
              data.conversations[i].members.contains(fingerprint) else { return }
        // A follower of a channel that shares one mailbox has no card: they're asked for one first, and made an admin when
        // they answer.
        if on, let shared = data.conversations[i].shared, shared.settings.kind == .channel,
           let known = shared.knownAs[fingerprint], shared.roster?.live.contains(where: { Identity.fingerprint(of: $0.signingKey) == known }) == true {
            promoteFollower(fingerprint, at: i)
            return
        }
        let wasAdmin = data.conversations[i].admins.contains(fingerprint)
        data.conversations[i].admins.removeAll { $0 == fingerprint }
        if on {
            data.conversations[i].admins.append(fingerprint)
            data.conversations[i].mods.removeAll { $0 == fingerprint }
        }
        publishChange(i)
        // An admin let go no longer has the staff mailbox.
        if !on, wasAdmin, data.conversations[i].shared?.settings.kind == .channel { rotateStaffKey(at: i) }
    }

    /// Only the owner appoints or removes mods, and only in groups. An admin is already more than a mod.
    func setMod(_ id: Conversation.ID, _ fingerprint: String, _ on: Bool) {
        guard let i = index(of: id), data.conversations[i].shared != nil, data.conversations[i].amOwner, data.conversations[i].kind == .group,
              data.conversations[i].members.contains(fingerprint), !data.conversations[i].isAdmin(fingerprint) else { return }
        data.conversations[i].mods.removeAll { $0 == fingerprint }
        if on { data.conversations[i].mods.append(fingerprint) }
        publishChange(i)
    }

    /// Adds contacts (of this chat's persona) to a group or channel, and gives back the ones whose app is too old to take
    /// part: they aren't added, and the caller says so (see `membersNeedingUpdate`).
    @discardableResult
    func addMembers(_ id: Conversation.ID, _ fingerprints: [String]) -> [String] {
        guard let i = index(of: id), data.conversations[i].shared != nil, data.conversations[i].amAdmin else { return [] }
        let already = contactsIn(data.conversations[i])
        return invite(fingerprints.filter { !data.conversations[i].members.contains($0) && !already.contains($0) }, at: i)
    }

    /// Owners can remove anyone; admins can remove people who aren't admins; mods only ordinary members.
    func removeMember(_ id: Conversation.ID, _ fingerprint: String) {
        guard let i = index(of: id), data.conversations[i].shared != nil else { return }
        let c = data.conversations[i]
        guard c.canRemove(fingerprint, by: "me"), contact(fingerprint, in: c.persona) != nil else { return }
        removeSharedMember(fingerprint, at: i)
    }

    func role(of fingerprint: String, in convo: Conversation) -> String? {
        if convo.owner == fingerprint { return "Owner" }
        if convo.admins.contains(fingerprint) { return "Admin" }
        if convo.mods.contains(fingerprint) { return "Mod" }
        return nil
    }
}

// MARK: - One device per account

extension AppModel {
    /// An account lives on one iPhone. Builds before 22 could link more: those were kept as a hidden contact of your own
    /// (`Contact.isSelf`) holding your other devices, which `endLinkedDevices` takes apart.
    private var selfIndex: Int? { data.contacts.firstIndex { $0.isSelf } }

    /// Once the relay is in reach after an unlock, ends any linking left from an older build.
    func endLinkedDevicesWhenOnline() {
        guard selfIndex != nil else { return }
        Task { [weak self] in
            while let self, self.phase == .unlocked, self.selfIndex != nil {
                if self.link == .online { await self.endLinkedDevices(); return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Ends linking left from an older build, on the device that keeps the account: the one with the lowest id among
    /// the account's devices heard from in the last month (`dormantAfter`). One silent longer, or never heard from (a Mac
    /// put away, a phone wiped by an instant Detach), doesn't count. It is unlinked like the rest but never makes this
    /// device give way. The keeper tells the others to wipe themselves (`accountDetached`, which every build since linking
    /// obeys). Once that has left for every device that counts, it tells every contact they're all unlinked, forgets
    /// them and moves the groups to keys they can't work out. Any other device does nothing here: it keeps the account
    /// until the keeper's word arrives (`leaveForAnotherDevice`), so a device list gone stale can never wipe the only
    /// phone left. Should two devices each think they keep it, both keep it, which loses nothing.
    func endLinkedDevices() async {
        guard !endingLinks, !burning, !burnPending, !detaching, let identity, let i = selfIndex else { return }
        let now = Date()
        let mine = data.deviceID
        func recent(_ d: DeviceLink) -> Bool { d.lastHeard.map { now.timeIntervalSince($0) < Self.dormantAfter } ?? false }
        let siblings = data.contacts[i].devices.filter { $0.id != mine }
        // One known only by its mailbox can't be compared with: wait, keeping the account.
        if siblings.contains(where: { $0.id.isEmpty && recent($0) }) { return }
        let live = siblings.filter { !$0.id.isEmpty && recent($0) }
        guard live.allSatisfy({ mine.hex < $0.id.hex }) else { return }
        endingLinks = true
        defer { endingLinks = false }
        if !live.isEmpty {
            let liveIDs = Set(live.map(\.id))
            func waiting(_ d: DeviceLink) -> Bool {
                d.pending.contains { if case .sync(.accountDetached) = $0.payload { true } else { false } }
            }
            if !data.contacts[i].devices.contains(where: { liveIDs.contains($0.id) && waiting($0) }) {
                enqueue(.sync(.accountDetached), to: data.contacts[i])
            }
            _ = try? await sendEverything()
            // Burn, Detach or a lock while it was sending: they go on, this waits for the next unlock.
            guard !burning, !burnPending, !detaching, phase == .unlocked, self.identity?.seed == identity.seed,
                  let i = selfIndex else { return }
            // Not yet gone to one of them (no session yet, say): tried again at the next unlock.
            if data.contacts[i].devices.contains(where: { liveIDs.contains($0.id) && waiting($0) }) { return }
        }
        guard let i = selfIndex else { return }
        let others = data.contacts[i].devices.map(\.id).filter { !$0.isEmpty && $0 != mine }
        if !others.isEmpty {
            for c in data.contacts where !c.isSelf && !c.awaitingAcceptance && !c.devices.isEmpty {
                enqueue(.devicesUnlinked(others.map { Self.deviceID($0, for: c.persona) }, kept: [deviceID(for: c.persona)]), to: c)
            }
        }
        data.contacts.remove(at: i)
        if !others.isEmpty { renewGroupSecret() }
        save()
        kick()
        if !live.isEmpty {
            burnNotice = "Pulshade now works on one iPhone per account. Your account stays on this iPhone, and your other devices were signed out."
        }
    }

    /// The device keeping the account told this one to go (or an older build detached every device). Contacts are told
    /// this device is gone, then it wipes, leaving the files on the relay, which the account still shows elsewhere. It
    /// wipes even if the goodbyes can't go: the account is already in the other device's hands.
    private func leaveForAnotherDevice() {
        guard !burning, !burnPending, !detaching, !leavingForAnotherDevice, let identity else { return }
        for c in data.contacts where !c.isSelf && !c.awaitingAcceptance { enqueue(.deviceRemoved, to: c) }
        // Marked first, as Burn does: killed while it waits, the next launch wipes this device before anything opens it.
        guard Self.markWipeDue(burnStore, keepingSettings: true) else { return }
        leavingForAnotherDevice = true
        Task {
            _ = try? await sendEverything()
            defer { leavingForAnotherDevice = false }
            // A Burn started meanwhile does the wipe itself, with its own order.
            guard !burning, !burnPending, self.identity?.seed == identity.seed else { return }
            destroyEverything()
            Vault.scrubLeftovers()
            burnNotice = "Pulshade now works on one iPhone per account. Your account stays on your other device, so this iPhone was signed out."
        }
    }

    /// Word from another device of this account, on a build that could link. Only the two that end the account here are
    /// taken: everything else it says was synced data, which an account on one device no longer takes.
    func handleOwnDevice(_ event: SyncEvent) {
        switch event {
        case .accountErased:
            // Burned on that device. The files on the relay are that device's to erase.
            guard !burning, !burnPending else { return }
            leavingForAnotherDevice = true
            destroyEverything(leavingNoTrace: true)
            leavingForAnotherDevice = false
            Vault.scrubLeftovers()
        case .accountDetached:
            leaveForAnotherDevice()
        default:
            break
        }
    }

    enum ScanResult { case contact(Contact), chat(Conversation.ID), expired, unknown, outdated }

    /// What a code would do, shown for a yes before anything happens.
    struct CodePreview: Equatable {
        enum Kind: Equatable { case contact, channel, chat(endsAt: Date) }
        var kind: Kind
        /// A relay the code names that isn't yours: it would see your connection from then on.
        var relay: String?
    }

    func inspectCode(_ text: String) -> CodePreview? {
        let code = scannedPayload(text)
        if let link = ChatLink(code) { return CodePreview(kind: .chat(endsAt: link.endsAt), relay: foreignRelay(Invite(code: link.invite)?.relay)) }
        guard let invite = Invite(code: code) else { return nil }
        return CodePreview(kind: invite.kind == .channel ? .channel : .contact, relay: foreignRelay(invite.relay))
    }

    private func foreignRelay(_ relay: String?) -> String? {
        guard let relay, relay != data.relay else { return nil }
        return relay
    }

    /// Whatever the camera read: a friend's invite adds them, a one-time chat link opens its chat.
    func useScannedCode(_ text: String) -> ScanResult {
        let code = scannedPayload(text)
        if let link = ChatLink(code) {
            return joinChatLink(link).map(ScanResult.chat) ?? .expired
        }
        if Invite(code: code) != nil, let contact = addContact(code: code, nickname: "") { return .contact(contact) }
        return Invite.isOutdated(code) ? .outdated : .unknown
    }
}

// MARK: - Detach & burn

extension AppModel {
    enum LeaveError: Error { case wrongRecoveryCode, offline, backupNotRemoved, burnNotSaved, wipeNotMarked }

    /// Takes the account off this device, keeping everything but the chats. The recovery code is needed first. The
    /// account (profile, @handles, contacts, groups, personas, settings) is sealed and left on the relay for it,
    /// without a single message, story or request, and the device is wiped.
    func detach(recoveryCode: String? = nil) async throws {
        try open(recoveryCode: recoveryCode)
        guard let identity else { return }
        guard let code = recoveryCode, Identity.seed(fromRecoveryCode: code) == identity.seed else {
            throw LeaveError.wrongRecoveryCode
        }
        guard Self.markWipeDue(burnStore) else { throw LeaveError.wipeNotMarked }
        do {
            try await leaveBackup(of: identity)
        } catch {
            // Nothing was wiped, and the person is told it didn't work: the mark goes, or the next launch would wipe.
            Self.clearWipeDue(burnStore)
            throw error
        }
        destroyEverything(leavingNoTrace: true)
        Vault.scrubLeftovers()
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
        // Groups' and channels' public names are let go of while their keys are still here: once wiped, nobody could.
        // A release has to be signed at the moment it's sent, so it can't wait in the burn order; a few seconds at most.
        for name in data.publicNames { dropPublicName(of: name.conversation) }
        let names = Task { await self.releasePendingNames(); await self.revokeAllShortLinks() }
        let namesTimer = Task { try? await Task.sleep(for: .seconds(15)); names.cancel() }
        await names.value
        namesTimer.cancel()
        let order = makeBurnOrder(identity: identity, outboxBefore: outboxBefore)
        burning = false
        // Marked first, so a wipe cut short (the app killed, the battery gone) is finished at the next launch.
        // The device is marked as due a wipe and the order is kept before anything is sent: if the app is killed from
        // here on, the next launch wipes the phone before anything can open it, and the relay side still finishes.
        // If either can't be written, nothing goes further: a Burn that would silently skip the server is refused.
        guard Self.markWipeDue(burnStore) else { throw LeaveError.burnNotSaved }
        guard burnStore.save(order) else {
            try? FileManager.default.removeItem(at: Self.wipeDueFile(burnStore))
            throw LeaveError.burnNotSaved
        }
        // One go, briefly, while the sync is still running (groups you own are deleted through it).
        let attempt = Task { await self.attemptBurnCleanup() }
        let timer = Task { try? await Task.sleep(for: .seconds(20)); attempt.cancel() }
        let finished = await attempt.value
        timer.cancel()
        // Whatever the relay said, the phone is wiped now. The order outlives the wipe so the rest can still finish.
        destroyEverything(leavingNoTrace: true, keepingBurnOrder: true)
        Vault.scrubLeftovers()
        if finished { return .complete }
        burnNotice = "This phone is wiped. Pulshade is finishing the erase on the server and will keep trying until it is done, for up to 30 days. Until then this device keeps a sealed note of what's left, which shows an account was burned here."
        startBurnLoop()
        return .pending
    }

    /// Mailboxes in one part of a burn order: what the relay takes in one request (`MAX_BURN_MAILBOXES`), well inside
    /// its 256 KiB for the whole request.
    static let burnMailboxesPerPart = 2048

    /// Everything a Burn still has to do on the relay, signed now while the keys are known: erase the backup, retire the
    /// handles, take back what is still waiting, erase the files, empty and close every mailbox, and drop the farewells.
    /// In parts (`BurnOrder.Part`): one for each persona, with its handle, recall key and mailboxes (the main one's also
    /// erases the backup), and one for the files, each signed with a time of its own, so no one request ties the personas
    /// together.
    func makeBurnOrder(identity: Identity, outboxBefore: Set<UUID>) -> BurnOrder {
        let now = UInt64(RelayClock.now.timeIntervalSince1970)
        // Each part's time is a little before now, by a different random amount: the relay accepts signatures up to
        // 30 days old, and parts all stamped with the same second would say they're one order.
        func stamp() -> UInt64 { now - (trafficShaping ? UInt64.random(in: 0...900) : 0) }
        func signed(_ label: String, key: Data, by signer: Curve25519.Signing.PrivateKey, ts: UInt64) -> BurnOrder.Signed {
            let message = Data(label.utf8) + key + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
            return BurnOrder.Signed(key: key, sig: (try? signer.signature(for: message)) ?? Data())
        }
        var order = BurnOrder(ts: now, relay: reachable(nil) ?? data.relay)
        var parts: [BurnOrder.Part] = []
        // Every persona anything is kept under, even one whose own entry is gone: its contacts' mailboxes are closed all
        // the same, only without its signature (the relay rations those, `UNSIGNED_CLOSINGS_PER_HOUR`).
        var personas: [UUID?] = [nil] + data.personas.map { Optional($0.id) }
        for persona in data.contacts.map(\.persona) + data.invites.map(\.persona) where !personas.contains(persona) {
            personas.append(persona)
        }
        for persona in personas {
            let owner: Identity? = persona == nil ? identity : self.me(persona)
            var boxes = Set(data.contacts.filter { $0.persona == persona }.flatMap(Self.mailboxes(of:)))
            boxes.formUnion(data.invites.filter { $0.persona == persona }.map(\.receiveKey))
            // The relay takes `burnMailboxesPerPart` at a time; past that the persona's mailboxes go in more parts, each
            // signed with its handle like the first (retiring a handle twice does nothing more), so none are left out
            // and none is held to the ration for unsigned closings.
            let all = boxes.sorted { $0.hex < $1.hex }
            for start in stride(from: 0, to: max(all.count, 1), by: Self.burnMailboxesPerPart) {
                var part = BurnOrder.Part(ts: stamp())
                if let me = owner {
                    part.handles = [signed("pulshade.burn.retire.v1", key: me.card.signing, by: me.signingKey, ts: part.ts)]
                }
                if start == 0 {
                    if persona == nil {
                        part.backup = signed("pulshade.burn.backup.v1", key: identity.backupSigningKey.publicKey.rawRepresentation,
                                             by: identity.backupSigningKey, ts: part.ts)
                    }
                    if let owner { part.recall = [owner.recallKey] }
                }
                part.mailboxes = Array(all[start..<min(start + Self.burnMailboxesPerPart, all.count)])
                if !part.isEmpty { parts.append(part) }
            }
        }
        // The files on their own: erasing them needs only each file's secret, and says nothing about whose they were.
        if !data.blobWipes.isEmpty {
            for start in stride(from: 0, to: data.blobWipes.count, by: 1024) {
                var part = BurnOrder.Part(ts: stamp())
                part.blobs = Array(data.blobWipes[start..<min(start + 1024, data.blobWipes.count)])
                parts.append(part)
            }
        }
        order.parts = parts
        order.ts = parts.map(\.ts).min() ?? now
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
        if var parts = order.parts {
            // Each part on a connection of its own, in a random order, a random few seconds apart.
            var first = true
            for k in parts.indices.shuffled() where !parts[k].done {
                if !first, trafficShaping { try? await Task.sleep(for: .seconds(Double.random(in: Self.burnPartGap))) }
                if Task.isCancelled { break }
                first = false
                let lane = Lanes.once("burn")
                let sent: Bool
                if parts[k].isEmpty {
                    sent = true
                } else if let body = try? BurnOrder.requestBody(parts[k]) {
                    sent = (try? await RelayClient(base: base, lane: lane).burn(body)) != nil
                } else {
                    sent = false
                }
                RelayClient.retire(lane: lane)
                guard sent else { continue }
                parts[k].done = true
                order.parts = parts
                burnStore.save(order)
            }
        } else {
            let client = RelayClient(base: base, lane: Lanes.once("burn"))
            if !order.serverDone, let body = try? order.requestBody(), (try? await client.burn(body)) != nil {
                order.serverDone = true
                burnStore.save(order)
            }
            RelayClient.retire(lane: client.lane)
        }
        // The farewells, a few at a time, each on a connection of its own (sharing one would tie those contacts together);
        // each that is taken is crossed off.
        var left = order.farewells
        while !left.isEmpty, !Task.isCancelled {
            let batch = Array(left.prefix(6))
            let sent = await withTaskGroup(of: (BurnOrder.Farewell, Bool).self) { group in
                for farewell in batch {
                    group.addTask {
                        guard let url = URL(string: farewell.relay) else { return (farewell, true) }
                        let lane = Lanes.once("farewell")
                        defer { RelayClient.retire(lane: lane) }
                        do { try await RelayClient(base: url, lane: lane).deposit(farewell.blob, to: farewell.sendID); return (farewell, true) }
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

    /// The pause between a Burn's parts.
    static let burnPartGap: ClosedRange<Double> = 2...12

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

    /// Set before any wipe of this device starts (and before a Burn or Detach talks to the relay), and gone once the wipe
    /// is done. Found at launch, the wipe was cut short.
    static func wipeDueFile(_ store: BurnOrderStore) -> URL {
        store.file.deletingPathExtension().appendingPathExtension("wipe-due")
    }

    /// What the mark holds for a wipe that keeps the settings Pulshade needs to reach the relay (Detach of one device of
    /// several). Empty is a wipe that leaves no trace.
    private static let keepingSettingsMark = Data("keep".utf8)

    /// Marks a wipe as due. A mark already there is kept as it is (a wipe that leaves no trace never becomes one that
    /// keeps the settings). True if a mark is there afterwards.
    @discardableResult
    static func markWipeDue(_ store: BurnOrderStore, keepingSettings: Bool = false) -> Bool {
        let file = wipeDueFile(store)
        if FileManager.default.fileExists(atPath: file.path) { return true }
        return FileManager.default.createFile(atPath: file.path, contents: keepingSettings ? keepingSettingsMark : Data())
    }

    static func clearWipeDue(_ store: BurnOrderStore) {
        try? FileManager.default.removeItem(at: wipeDueFile(store))
    }

    /// At launch: a wipe that was cut short (a Burn or Detach waiting on the relay, or a wipe itself, when the app was
    /// killed) is finished now, before anything can open the account.
    func finishCutShortWipe() {
        let file = Self.wipeDueFile(burnStore)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let keeping = (try? Data(contentsOf: file)) == Self.keepingSettingsMark
        destroyEverything(leavingNoTrace: !keeping, keepingBurnOrder: true)
        Vault.scrubLeftovers()
    }

    /// At launch: a burn that wasn't finished carries on.
    func resumeBurnCleanup() {
        guard burnStore.exists else { return }
        startBurnLoop()
    }

    /// Burns one persona for good, leaving your main identity and other personas as they are: its @handles are
    /// retired, its chats deleted for both sides, its contacts told to forget it, and once that's sent, its keys and
    /// everything else of it go from all your devices.
    func burnPersona(_ id: UUID) async throws {
        guard data.personas.contains(where: { $0.id == id }), let client = client(nil), await client.health() else {
            throw LeaveError.offline
        }
        await retireHandles(persona: id)
        for convo in data.conversations where convo.persona == id { delete(convo.id) }
        // Its groups' and channels' names are let go of, and short links to its invites marked, before its keys are gone.
        await releasePendingNames()
        await revokeShortLinks(ofPersona: id)
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
    ///
    /// A code, once given, is always checked: also when the keys are still in memory because the screen is only
    /// covered. Without a code only an open, uncovered account can leave, so nothing behind the lock screen skips it.
    private func open(recoveryCode: String?) throws {
        guard let code = recoveryCode else {
            guard identity != nil, !covered, phase == .unlocked else { throw LeaveError.wrongRecoveryCode }
            return
        }
        guard let seed = Identity.seed(fromRecoveryCode: code) else { throw LeaveError.wrongRecoveryCode }
        if let identity {
            guard Self.sameBytes(seed, identity.seed) else { throw LeaveError.wrongRecoveryCode }
            return
        }
        guard let identity = try? Identity(seed: seed),
              let stored = try? vault.load(with: identity) else { throw LeaveError.wrongRecoveryCode }
        self.identity = identity
        slot = 0
        data = stored
    }

    /// Sends Detach or Burn's farewells from the lock screen, then locks again if they couldn't go.
    func leaveFromLock(burning: Bool, recoveryCode: String) async throws {
        do {
            if burning { try await burn(recoveryCode: recoveryCode) } else { try await detach(recoveryCode: recoveryCode) }
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
    /// Compares two secrets in time that doesn't depend on where they first differ.
    static func sameBytes(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func withoutChats(_ data: AppData, keepingDevices: Bool) -> AppData {
        var kept = data
        kept.conversations = data.conversations.filter { $0.kind != .direct }.map {
            var c = $0
            c.messages = []
            // A shared group's sending chains and tag belong to this device alone: another (or this one restored) makes
            // its own, so no message key is ever used twice. What's waiting to be posted is chat.
            c.shared?.myTag = nil
            c.shared?.chains = [:]
            c.shared?.outbox = []
            // Posts kept to be posted again are chat too, and so is when this device last read or asked.
            c.shared?.kept = nil
            c.shared?.lastFetch = nil
            c.shared?.catchUpSince = nil
            c.shared?.catchUpAsked = nil
            return c
        }
        kept.stories = []
        // Pieces set aside because they wouldn't read stay on this device only: never in a backup or a detached copy.
        kept.setAside = nil
        kept.setAsideUnseen = nil
        // The media pool's filler belongs to this device's files: never in a backup or a detached copy.
        kept.mediaFillers = nil
        // Reader uses this device still has to spend are about files it sent: chat, like the rest.
        kept.blobSpends = []
        kept.requests = []
        kept.outbox = []
        kept.chatCodes = []
        if !keepingDevices, let i = kept.contacts.firstIndex(where: \.isSelf) { kept.contacts[i].devices = [] }
        return kept
    }

    /// `unreadable`: a copy is on the relay but this version can't open it (it may come from a newer one). It must
    /// not be taken for no backup, or starting over would later save across it. `older`: the copy the relay gave is
    /// older than one this device already made or restored for the account (the relay served an old one), so it isn't
    /// restored; its date, if it says one.
    enum BackupLookup { case found(AppData), none, unreachable, unreadable, older(Date?) }

    /// The account a log out left on the relay, opened with the recovery code's key.
    func backup(of identity: Identity) async -> BackupLookup {
        guard let client = client(nil, lane: "backup") else { return .unreachable }
        let (key, sig, ts) = backupProof("pulshade.backup.get.v1", identity)
        let sealed: Data?
        do { sealed = try await client.backup(key: key, sig: sig, ts: ts) } catch { return .unreachable }
        guard let sealed else { return .none }
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: identity.backupKey) else { return .unreadable }
        let json = Self.unpadded(plain)
        // A backup with one piece that won't read still brings back everything else.
        guard var restored = (try? JSONDecoder.pulshade.decode(AppData.self, from: json)) ?? AppData.rescue(json)
        else { return .unreadable }
        // What a backup couldn't give back isn't kept: a backup never holds anything set aside on the device it came from.
        restored.setAside = nil
        restored.setAsideUnseen = nil
        // Older than one this device made or restored for this account (its saved data is still here): the relay handed
        // back an old copy. Not restored. A device that has none of the account's data can't tell; it shows the date.
        if let seen = (try? vault.load(with: identity))?.backupStamp, (restored.backupStamp?.counter ?? 0) < seen.counter {
            return .older(restored.backupStamp?.madeAt)
        }
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
            let sealed = try Self.sealedBackup(of: data, with: identity, stamp: .next(after: data.backupStamp))
            let (key, sig, ts) = backupProof("pulshade.backup.put.v1", identity, body: sealed)
            try await client.putBackup(sealed, key: key, sig: sig, ts: ts, forgetHash: forgetHash(for: identity))
        } catch {
            startSync()
            throw LeaveError.offline
        }
    }

    // MARK: Keeping the backup fresh

    /// A hash of the panic passcode's delete-only token, sent with each backup so the relay can honour it. Always
    /// sent: with no panic passcode it is a stand-in no one holds a token for, the same for every upload of this
    /// account (as a real one is), so the relay can't tell from the header whether a panic passcode exists.
    private func forgetHash(for identity: Identity) -> Data {
        if let seed = data.panicSeed { return Data(SHA256.hash(data: Self.forgetToken(landingSeed: seed))) }
        return Self.decoyForgetHash(for: identity)
    }

    static func decoyForgetHash(for identity: Identity) -> Data {
        let stand = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: identity.seed),
                                           info: Data("pulshade.backup.forget.standin.v1".utf8), outputByteCount: 32).bytes
        return Data(SHA256.hash(data: stand))
    }

    /// What goes in a backup: everything but chats, and not the two fields that track the backup itself.
    static func backupContents(of data: AppData) -> AppData {
        var kept = withoutChats(data, keepingDevices: false)
        kept.backupSavedAt = nil
        kept.backupDigest = nil
        // Its stamp goes in as it is sealed (`stamped`), so an unchanged account still compares equal.
        kept.backupStamp = nil
        // Nothing you wrote that is still waiting to be sent: that is chat, and chats never go in the backup.
        // No session keys either: a recovered account opens fresh ones with every contact (`startFreshSessions`), so a
        // copy of the backup, with the recovery code, shows no chat key that was ever used. Only a contact who hasn't
        // accepted yet keeps its half of the handshake, since nothing else can finish it.
        for c in kept.contacts.indices {
            for d in kept.contacts[c].devices.indices {
                kept.contacts[c].devices[d].pending.removeAll { $0.message != nil }
                guard !kept.contacts[c].awaitingAcceptance else { continue }
                kept.contacts[c].devices[d].session = nil
                kept.contacts[c].devices[d].handshake = nil
                kept.contacts[c].devices[d].earlierAsks = nil
                kept.contacts[c].devices[d].awaitingHello = nil
                kept.contacts[c].devices[d].acceptedHello = nil
                kept.contacts[c].devices[d].acceptedHelloAt = nil
                kept.contacts[c].devices[d].sessionAskAt = nil
            }
        }
        // Nor story video still arriving, or the decoy and panic identities, which live only on the device
        // they were set up on.
        kept.clipParts = [:]
        // Nor this device's own keys, which never leave it, nor the spares they signed: a copy of the backup must not be
        // able to finish one in this device's name. A recovered account makes new ones, with new keys.
        kept.deviceKey = nil
        for c in kept.contacts.indices {
            kept.contacts[c].spare = nil
            kept.contacts[c].oldSpares = nil
            kept.contacts[c].moreSpares = nil
        }
        // Nor your own chat background photo: it's big, and the look falls back to the theme's until you set it again.
        kept.chatBackground.photo = nil
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

    static func sealedBackup(of data: AppData, with identity: Identity, stamp: BackupStamp) throws -> Data {
        let plain = try JSONEncoder.pulshade.encode(stamped(backupContents(of: data), stamp))
        return try AES.GCM.seal(padded(plain), using: identity.backupKey).combined!
    }

    /// What a backup holds, with its stamp: inside the seal, so the relay can't change its count or date.
    static func stamped(_ contents: AppData, _ stamp: BackupStamp) -> AppData {
        var out = contents
        out.backupStamp = stamp
        return out
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

    /// What decides whether the backup changed enough to upload (`saveBackup`): its contents without what changes on its
    /// own often enough that an upload right after would tie this backup on the relay to it. Spares change every few days
    /// per friend (an upload every few minutes while they're first made; one made since an upload is simply not in it, and
    /// its friend falls back). Mailbox moves (`tendMailboxes`) happen weekly
    /// for each friend, on theirs and on this side: a backup going up minutes after each would tell the relay which
    /// mailboxes are this account's. Both still go in the backup, with the next upload that happens anyway or the weekly
    /// one. A recovery from a backup made before a move still works: the recovered account opens fresh sessions, and the
    /// hello that opens each names the mailbox it reads (`DeviceCard.sendID`), which the friend's device then writes to.
    /// What was waiting in a mailbox moved to since is not read.
    static func backupChangeDigest(of data: AppData) -> Data? {
        var kept = backupContents(of: data)
        for c in kept.contacts.indices {
            kept.contacts[c].spare = nil
            kept.contacts[c].oldSpares = nil
            kept.contacts[c].moreSpares = nil
            kept.contacts[c].receiveKey = nil
            kept.contacts[c].mailboxSince = nil
            kept.contacts[c].formerMailboxes = nil
            kept.contacts[c].movedHeard = nil
            for d in kept.contacts[c].devices.indices {
                kept.contacts[c].devices[d].sendID = Data()
                // The word of a move, while it waits for a session to go on.
                kept.contacts[c].devices[d].pending.removeAll { if case .mailbox = $0.payload { return true } else { return false } }
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(kept)).map { Data(SHA256.hash(data: $0)) }
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
        let stamp = BackupStamp.next(after: data.backupStamp)
        guard let plain = try? encoder.encode(Self.stamped(Self.backupContents(of: data), stamp)) else { return false }
        guard let digest = Self.backupChangeDigest(of: data) else { return false }
        let week = data.backupSavedAt.map { Date().timeIntervalSince($0) > 7 * 24 * 3600 } ?? true
        if digest == data.backupDigest, !week { return true }
        guard let sealed = try? AES.GCM.seal(Self.padded(plain), using: identity.backupKey).combined else { return false }
        let (key, sig, ts) = backupProof("pulshade.backup.put.v1", identity, body: sealed)
        do { try await client.putBackup(sealed, key: key, sig: sig, ts: ts, forgetHash: forgetHash(for: identity)) } catch {
            // Try again in a while.
            scheduleBackup(after: 300...900)
            return false
        }
        // Nothing of the account changed, so this save doesn't ask for another upload.
        guard self.identity?.fingerprint == identity.fingerprint, data.security.keepBackup else { return true }
        data.backupDigest = digest
        data.backupSavedAt = Date()
        data.backupStamp = stamp
        save()
        return true
    }

    /// One line for Settings and the Detach screen: how fresh the relay's copy is.
    var backupStatus: String {
        guard data.security.keepBackup else { return "Backups are off" }
        guard let saved = isPrimary ? data.backupSavedAt : facadeBackupAt else { return "Not saved yet" }
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

    func backupProof(_ label: String, _ identity: Identity, body: Data? = nil) -> (key: Data, sig: Data, ts: UInt64) {
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
        for story in data.stories where story.author == fp { deleteStoredMedia(in: story) }
        for convo in data.conversations {
            deleteStoredMedia(in: convo.messages.filter { $0.sender == fp })
        }
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
                          speaker: true)
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
        save()
        kick()
        connectCall()
    }

    func declineCall() {
        guard let current = call, !current.outgoing, current.phase == .ringing else { return }
        if let contact = contact(current.peer, in: current.persona) {
            enqueue(.callAnswer(id: current.invite.id, accepted: false), to: contact)
        }
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
                          speaker: true)
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
    /// What a web link stands for, opened as its own link would be. Each waits on its screen while Pulshade is locked; a
    /// short link is looked up once Pulshade is open (`openedShort`).
    func openTarget(_ target: WebLinks.Target) {
        switch target {
        case let .name(handle, check): openedKeyCheck = check; openedHandle = handle
        case let .group(code): openedGroupLink = OpenedGroupLink(code: code)
        case let .invite(code): openedCode = code
        case let .chat(link): openedCode = link.link
        case let .short(code): openedShort = code
        }
    }

    /// A pulshade:// link opened from outside: a profile link goes to Contacts, anything else to the scan screen.
    /// Both wait there while Pulshade is locked.
    func open(_ url: URL) {
        // A web link (`https://<domain>/name` or `/+code`): the same as the pulshade:// link it stands for.
        if let target = WebLinks.parse(url) {
            openTarget(target)
            return
        }
        guard url.scheme?.lowercased() == "pulshade" else { return }
        // `pulshade://i/<letters>`, the pulsh.me page's Open button for a short link.
        if url.host()?.lowercased() == "i", url.pathComponents.count == 2, let short = ShortCode(url.lastPathComponent) {
            openedShort = short
        } else if let code = GroupLinkCode(url.absoluteString) {
            openedGroupLink = OpenedGroupLink(code: code)
        } else if let link = DirectoryProfile.handle(fromLink: url) {
            openedKeyCheck = link.keyCheck
            openedHandle = link.handle
        } else {
            openedCode = url.absoluteString
        }
    }
}


/// What the persona-switch animation shows: who you have just become.
struct PersonaFlash: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var avatar: Data?
    var seed: String
    var isMain: Bool
}

// MARK: - Groups that share one mailbox

/// A group whose members each post once into one mailbox on the relay, and read everyone else's from there (see
/// docs/groups-design.md and `GroupKeys.swift`). Members are known inside it by a key made for that group alone; each
/// is kept as a hidden contact with no devices, so everything that shows names, roles and messages works as it does
/// for other groups. Nothing said in the group is sent to them one by one: only where each device's chain starts, over a
/// pairwise session in the group's own mailbox (`GroupPeer`), which makes no friends and shows no chat.
extension AppModel {
    /// Which of these people can't be put in a group or channel because their app is too old to take part: every device of
    /// theirs has to say it can. Nobody is ever put in a group in an older format instead, so the person making the group
    /// is told to ask them to update Pulshade first.
    func membersNeedingUpdate(_ fingerprints: [String], persona: UUID?, kind: ConversationKind) -> [String] {
        fingerprints.filter { fp in contact(fp, in: persona).map { !takes($0, kind) } ?? true }
    }

    /// Friends with a device whose app is from before the sparse post-quantum ratchet: nothing is exchanged with them until
    /// they update Pulshade. Names, for the chat to say so.
    func friendsNeedingUpdate(persona: UUID?) -> [String] {
        data.contacts.filter { $0.persona == persona && !$0.isSelf && !$0.hidden && $0.devices.contains { $0.needsUpdate == true } }
            .map(\.fingerprint)
    }

    /// What to tell someone who tried to add people whose app is too old.
    func needsUpdateMessage(_ fingerprints: [String]) -> String {
        let names = fingerprints.map { displayName($0) }
        return "\(Self.list(names)) \(names.count == 1 ? "needs" : "need") to update Pulshade first."
    }

    /// Whether a contact's app takes part in groups that share one mailbox (every device of theirs says so).
    func takesSharedGroups(_ contact: Contact) -> Bool {
        !contact.devices.isEmpty && contact.devices.allSatisfy { $0.readsSharedGroups == true }
    }

    /// Whether a contact's app takes part in channels that share one mailbox, as a follower or as staff.
    func takesChannels(_ contact: Contact) -> Bool {
        !contact.devices.isEmpty && contact.devices.allSatisfy { $0.readsChannels == true }
    }

    /// Whether a contact's app can be in a shared mailbox of this kind.
    func takes(_ contact: Contact, _ kind: ConversationKind) -> Bool {
        kind == .channel ? takesChannels(contact) : takesSharedGroups(contact)
    }

    /// Your contacts invited to a shared group whose app hasn't answered yet, oldest first.
    func contactsInvited(to convo: Conversation) -> [String] {
        guard let shared = convo.shared, !shared.gone else { return [] }
        return shared.invited.sorted { $0.value < $1.value }.map(\.key).filter { contact($0, in: convo.persona) != nil }
    }

    /// The contacts already in a group, or invited to it, as this device knows them: the member list (contact
    /// fingerprints), anyone whose group key (`knownAs`, by contact) is a member or in a channel's staff-only roster of
    /// followers, and anyone invited.
    func contactsIn(_ convo: Conversation) -> Set<String> {
        guard let shared = convo.shared else { return Set(convo.members) }
        let following = Set(shared.roster?.live.map { Identity.fingerprint(of: $0.signingKey) } ?? [])
        let keyed = shared.knownAs.filter { convo.members.contains($0.value) || following.contains($0.value) }.map(\.key)
        return Set(convo.members).union(keyed).union(shared.invited.keys)
    }

    /// This account's keys in a group: made with the group secret the group is on (`SharedGroup.memberSecret`), or the
    /// current one. A group still marked as on an older secret whose settings already list the keys made with the current
    /// one (another of your devices moved it on) gets those.
    func memberKeys(_ persona: UUID?, group: UUID) -> GroupMemberKeys? {
        guard let me = me(persona) else { return nil }
        if let i = groupIndex(group, persona: persona), let shared = data.conversations[i].shared, let held = shared.memberSecret {
            let old = GroupMemberKeys(seed: me.seed, group: group, secret: held)
            if !shared.settings.isMember(old.publicKey) {
                let new = GroupMemberKeys(seed: me.seed, group: group, secret: data.groupSecret)
                if shared.settings.isMember(new.publicKey) { return new }
            }
            return old
        }
        return GroupMemberKeys(seed: me.seed, group: group, secret: data.groupSecret)
    }

    /// The keys made with the current group secret, for a group still on an older one. Nil when it isn't.
    private func renewedKeys(at i: Int) -> GroupMemberKeys? {
        guard data.conversations[i].shared?.memberSecret != nil, let me = me(data.conversations[i].persona) else { return nil }
        return GroupMemberKeys(seed: me.seed, group: data.conversations[i].wireID, secret: data.groupSecret)
    }

    /// This account's card in a group: the persona's name, picture and colour.
    private func myCard(_ persona: UUID?, group: UUID) -> MemberCard? {
        guard let keys = memberKeys(persona, group: group) else { return nil }
        let p = profile(for: persona)
        return MemberCard.make(keys, group: group, name: p.name, avatar: Self.thumbnail(p.avatar, side: 96), color: p.color)
    }

    /// What a follower of a channel gives the staff: their group key for it and nothing else, no name or picture, so the
    /// roster tells even the staff only what rekeying needs (they know the account from the chat the invite came over).
    func followerCard(_ persona: UUID?, group: UUID) -> MemberCard? {
        guard let keys = memberKeys(persona, group: group) else { return nil }
        return MemberCard.make(keys, group: group, name: "", avatar: nil, color: nil)
    }

    /// How you appear in a conversation's messages to others: your group key there, or your account.
    func myFingerprint(in convo: Conversation) -> String? {
        if convo.shared != nil { return memberKeys(convo.persona, group: convo.wireID)?.fingerprint }
        return me(convo.persona)?.fingerprint
    }

    // MARK: Making one

    /// Makes a group that shares one mailbox, and invites `members` over your chats with them. Each joins once their
    /// app answers with its card.
    func startSharedGroup(title: String, members: [String], avatar: Data?, persona: UUID?, kind: ConversationKind = .group) -> Conversation? {
        var convo = Conversation(kind: kind, title: title, avatar: avatar, members: [])
        convo.persona = persona
        guard let shared = freshSharedGroup(id: convo.id, persona: persona, title: title, about: nil, avatar: avatar,
                                            postPolicy: kind == .channel ? .admins : .everyone, disappearAfter: nil, kind: kind) else { return nil }
        convo.shared = shared
        convo.owner = "me"
        convo.version = 1
        withAnimation(.snappy) { data.conversations.insert(convo, at: 0) }
        if let i = index(of: convo.id) { invite(members, at: i) }
        save()
        return index(of: convo.id).map { data.conversations[$0] }
    }

    /// Version 1 of a group with only this account in it, as owner, in a fresh first epoch.
    private func freshSharedGroup(id: UUID, persona: UUID?, title: String, about: String?, avatar: Data?,
                                  postPolicy: PostPolicy, disappearAfter: TimeInterval?, kind: ConversationKind = .group) -> SharedGroup? {
        guard let keys = memberKeys(persona, group: id), let card = myCard(persona, group: id) else { return nil }
        let epoch = GroupEpoch.fresh(number: 1)
        var settings = GroupSettings(group: id, kind: kind, version: 1, epoch: 1, title: String(title.prefix(80)), about: about,
                                     avatar: Self.thumbnail(avatar, side: 320), owner: keys.publicKey, postPolicy: postPolicy,
                                     disappearAfter: disappearAfter, members: [card.withoutAvatar], epochCheck: epoch.check)
        settings.sign(with: keys)
        var group = SharedGroup(settings: settings, epochs: [epoch])
        if kind == .channel { group.staffKey = .random(32) }
        return group
    }

    /// Sends each of `fingerprints` (contacts of the group's persona whose apps take part) what they need to join.
    /// Whoever adds someone to a group starts a new epoch first, so a newcomer reads from when they joined and nothing
    /// before (a channel, only when something was said in this one). Gives back the ones whose app is too old to take part: they are not invited, and
    /// nothing is kept to invite them later.
    @discardableResult
    private func invite(_ fingerprints: [String], at i: Int) -> [String] {
        guard var shared = data.conversations[i].shared, !shared.gone, let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              shared.settings.isAdmin(keys.publicKey) else { return [] }
        let persona = data.conversations[i].persona
        let everyone = fingerprints.compactMap { contact($0, in: persona) }
        let kind = shared.settings.kind
        let people = everyone.filter { takes($0, kind) }
        let tooOld = everyone.filter { !takes($0, kind) && shared.invited[$0.fingerprint] == nil }.map(\.fingerprint)
        guard !people.isEmpty else { return tooOld }
        // In a channel the followers are in the roster, not the settings.
        let held = kind == .channel ? (shared.roster?.live.count ?? 0) : shared.settings.members.count
        let room = (kind == .channel ? GroupRoster.Body.maxEntries : GroupSettings.maxMembers) - held - shared.invited.count
        guard room > 0 else { return tooOld }
        // Someone joining a group always starts in a new epoch: whether anything was said in this one is only what this
        // device has read, and other members' devices may have posted that it hasn't. If no new epoch could be made,
        // nobody is invited. A channel's follower is handed staff chains only from where they are when they come in
        // (`admittedAt`), so a channel moves on only once something was said.
        if kind == .group || shared.chatInEpoch {
            let before = shared.settings.epoch
            startEpoch(at: i, without: [])
            guard let updated = data.conversations[i].shared else { return tooOld }
            shared = updated
            if kind == .group, shared.settings.epoch == before { return tooOld }
        }
        guard let epoch = shared.current else { return tooOld }
        let added = Array(people.prefix(room))
        // A channel says which code it's for, so whoever followed that code takes it without asking.
        let id = data.conversations[i].id
        let code = kind == .channel
            ? data.invites.first { $0.channel == id }.map { Invite.codeTag(sendID: Mailbox.sendID(for: $0.receiveKey)) } : nil
        for person in added {
            shared.invited[person.fingerprint] = Date()
            shared.invitedEpoch[person.fingerprint] = epoch.number
            enqueue(.groupInvite(vouched(GroupInvite(settings: shared.settings, epoch: epoch, code: code), at: i)), to: person)
        }
        data.conversations[i].shared = shared
        if kind == .channel { for person in added { noteAdmitted(person.fingerprint, at: i) } }
        // Everyone sees who was added straight away, as in other apps, not only when each one's app answers. Not in a
        // channel: its followers are hidden from each other.
        let names = added.map { String($0.displayName.prefix(40)) }
        // Not when the group is being made: only people added to one that already has others in it.
        if kind == .group, shared.settings.members.count > 1 {
            post(.membersAdded(names: names), at: i)
            withAnimation(.snappy) {
                data.conversations[i].messages.append(Message(sender: "system", text: "You added \(Self.list(names))", date: Date()))
            }
        }
        save()
        return tooOld
    }

    /// How long an invite waits for an answer. Past it the invite is dropped and, if its key is still the group's, a new
    /// epoch is started, so someone who never joined doesn't go on reading.
    static let inviteLife: TimeInterval = 3 * 86_400

    /// Takes back an invite nobody has answered: a new epoch, if the one they were given is still in use.
    func cancelInvite(_ fingerprint: String, in id: Conversation.ID) {
        guard let i = index(of: id), var shared = data.conversations[i].shared, shared.invited[fingerprint] != nil else { return }
        let given = shared.invitedEpoch[fingerprint]
        shared.invited[fingerprint] = nil
        shared.invitedEpoch[fingerprint] = nil
        data.conversations[i].shared = shared
        if given == shared.current?.number { startEpoch(at: i, without: []) }
        save()
    }

    /// A channel's invite with this staff member's word that the account sending it is theirs (`StaffVouch`).
    private func vouched(_ invite: GroupInvite, at i: Int) -> GroupInvite {
        guard invite.settings.kind == .channel, let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              invite.settings.isAdmin(keys.publicKey), let me = me(data.conversations[i].persona) else { return invite }
        var out = invite
        out.vouch = StaffVouch.make(keys, group: invite.settings.group, account: me.card.signing)
        return out
    }

    // MARK: Being invited

    /// An invite over a chat with someone you know. A group or channel this account isn't in yet waits for you to say yes
    /// (`groupOffers`), unless it's the channel of someone whose channel code you followed: nobody puts you in a group,
    /// gets your card, or makes themselves the one a channel listens to on this account without you choosing them. Once
    /// you're in, the card goes back to whoever invited.
    func acceptGroupInvite(_ invite: GroupInvite, from sender: Contact, consented: Bool = false) {
        let s = invite.settings
        guard s.kind == .group || s.kind == .channel, s.signatureIsValid, s.wellFormed(),
              s.isAdmin(s.signer), s.epoch == invite.epoch.number, invite.epoch.isValid, s.epochCheck == invite.epoch.check, !sender.isSelf,
              let keys = memberKeys(sender.persona, group: s.group),
              let card = s.kind == .channel && invite.staff != true && !s.isMember(memberKeys(sender.persona, group: s.group)?.publicKey ?? Data())
                ? followerCard(sender.persona, group: s.group) : myCard(sender.persona, group: s.group) else { return }
        var quiet = false
        if let i = groupIndex(s.group, persona: sender.persona) {
            if var shared = data.conversations[i].shared {
                // Invited again (an answer that went astray, or added back after missing a key): taken only if it is the
                // settings held, the next version and one its signer may make, or a later one the owner signed.
                // Anything else could be someone rewriting the group.
                guard s == shared.settings || shared.settings.accepts(s) || shared.settings.acceptsJump(s),
                      shared.disputed?.contains(s.signer) != true else { return }
                // A group this account left (or was taken out of) comes back only when it has been added again: newer
                // settings that list it as a member, which only an admin can make. The settings from before, sent again
                // by anyone who still holds them, bring nothing back. A channel's follower comes back only through the
                // staff member who invited them.
                if shared.gone {
                    let addedBack = s.version > shared.settings.version && s.isMember(keys.publicKey)
                    let sameStaff = s.kind == .channel && shared.ownerAccount == sender.fingerprint
                    guard addedBack || sameStaff else { return }
                }
                // A channel this account follows takes (and answers) an invite only from the staff member who invited them:
                // anyone else holding the settings and key (another follower, say) must not get this follower's card, nor
                // be able to change anything here.
                // Someone else's copy still refreshes the keys (settings and epoch are checked above), but changes nothing else.
                if s.kind == .channel, !s.isMember(keys.publicKey), shared.ownerAccount != sender.fingerprint { quiet = true }
                shared.previous = s == shared.settings ? shared.previous : shared.settings
                install(invite.epoch, in: &shared)
                shared.settings = s
                shared.gone = false
                shared.missedKey = false
                shared.keyAskedAt = nil
                if let pending = shared.pendingSettings, pending.version <= s.version { shared.pendingSettings = nil }
                shared.joining = !s.isMember(keys.publicKey)
                data.conversations[i].shared = shared
            } else {
                // The same group id as one saved in the older format here: that copy stays as it is, read-only. Nothing moves
                // it over any more, so the owner starts the group again.
                return
            }
            applySharedSettings(at: i)
        } else {
            // A new group comes from a friend. Someone known only through another group or a channel can't put this
            // account in one (and so get its name and picture card back); a channel's own invite is how it is followed.
            if s.kind == .group, sender.hidden { return }
            // A channel comes only from its staff, by their word (`StaffVouch`): someone who forwards an invite they were
            // sent can't become the account this one follows it through. Staff on an app from before can't give it.
            if s.kind == .channel, invite.vouch?.checks(s, account: sender.signingKey) != true {
                if invite.vouch == nil { noteChannelInviteTooOld(from: sender) }
                return
            }
            let match = s.kind == .channel && !consented ? takeFollowAsked(sender.fingerprint, persona: sender.persona, tag: invite.code, group: s.group) : .none
            let followed = match == .matched
            // Nor a channel, unless it's the one whose code you followed: anyone who said hello on a channel's code, or
            // the staff of a channel you follow, would otherwise have a way to send you invites (and notifications) of
            // their own making. An invite that doesn't say which code it's for (their app is older) comes from someone
            // whose code you followed, so it is asked about, by the channel's name, rather than dropped or taken.
            if s.kind == .channel, sender.hidden, match == .none, !consented { return }
            if !consented, !acceptsInvitesForTests, !followed {
                noteGroupOffer(invite, from: sender, followed: match == .untagged)
                return
            }
            data.groupOffers.removeAll { $0.invite.settings.group == s.group && $0.persona == sender.persona }
            let place = newGroupPlace(s.group, persona: sender.persona)
            var convo = Conversation(id: place.id, kind: s.kind, title: String(s.title.prefix(80)), avatar: s.avatar, members: [])
            convo.groupID = place.groupID
            convo.persona = sender.persona
            convo.shared = SharedGroup(settings: s, epochs: [invite.epoch], joining: !s.isMember(keys.publicKey))
            convo.shared?.ownerAccount = sender.fingerprint
            withAnimation(.snappy) { data.conversations.insert(convo, at: 0) }
            if let i = groupIndex(s.group, persona: sender.persona) { applySharedSettings(at: i) }
        }
        // The staff mailbox's key, from the account the channel first came from and nobody else: a follower can't hand
        // someone a key of their own and cut them off from the roster.
        if invite.staff == true, s.kind == .channel, s.signer == s.owner, let key = invite.staffKey, key.count == 32,
           let i = groupIndex(s.group, persona: sender.persona), data.conversations[i].shared?.ownerAccount == sender.fingerprint,
           data.conversations[i].shared?.staffKey != key {
            data.conversations[i].shared?.staffKey = key
            data.conversations[i].shared?.chains["0"] = nil
            data.conversations[i].shared?.chainStarts?["0"] = nil
            data.conversations[i].shared?.cursors["0"] = nil
            data.conversations[i].shared?.reader.forget(epoch: 0)
        }
        if !s.isMember(keys.publicKey), !quiet { enqueue(.groupJoin(group: s.group, card: card), to: sender) }
        save()
    }

    /// Puts an epoch the settings name in place. One already held under the same number but a different key (from a
    /// competing change that lost) is replaced, with this device's chain, cursor and reading state for it.
    private func install(_ epoch: GroupEpoch, in shared: inout SharedGroup) {
        if let held = shared.epoch(epoch.number) {
            guard held.key != epoch.key else { return }
            shared.epochs.removeAll { $0.number == epoch.number }
            let n = String(epoch.number)
            shared.chains[n] = nil
            shared.chainStarts?[n] = nil
            shared.cursors[n] = nil
            shared.reader.forget(epoch: epoch.number)
        }
        var epoch = epoch
        epoch.from = nil
        if epoch.number > (shared.epochs.last?.number ?? 0) { shared.chatsInEpoch = nil }
        shared.epochs.append(epoch)
        shared.epochs.sort { $0.number < $1.number }
        // Earlier hand-outs are done with; another key for this same epoch is kept, in case its settings win.
        shared.candidates.removeAll { $0.number < epoch.number || $0.key == epoch.key }
    }

    /// A newcomer's card, back from someone this device invited: in it goes, for everyone. From a follower this device let
    /// in, with no invite waiting, a card under a new key is their account moving to new group keys (it unlinked a
    /// device): the new card takes the old one's place, and the channel moves to a new epoch the old key doesn't get.
    func acceptGroupJoin(_ group: UUID, card: MemberCard, from sender: Contact) {
        if let i = groupIndex(group, persona: sender.persona), let shared = data.conversations[i].shared,
           shared.invited[sender.fingerprint] == nil, shared.staffInvited?[sender.fingerprint] == nil,
           let (_, old) = followerEntry(of: sender, group: group), old.signingKey != card.signingKey,
           card.name.isEmpty, card.avatarHash == nil, card.verified(group: group), !shared.settings.isMember(card.signingKey),
           shared.links?.bans.contains(card.signingKey) != true {
            let previous = shared.knownAs[sender.fingerprint]
            data.conversations[i].shared?.knownAs[sender.fingerprint] = card.fingerprint
            addFollower(card, replacing: previous, at: i)
            if data.conversations[i].shared?.rekeyAfter.map({ shared.settings.epoch > $0 }) ?? true {
                data.conversations[i].shared?.rekeyAfter = shared.settings.epoch
            }
            data.conversations[i].shared?.rekeyDue = Date()
            save()
            return
        }
        guard let i = groupIndex(group, persona: sender.persona), var shared = data.conversations[i].shared, !shared.gone,
              let asked = shared.invited[sender.fingerprint] ?? shared.staffInvited?[sender.fingerprint],
              Date().timeIntervalSince(asked) < Self.inviteLife, card.verified(group: group),
              let keys = memberKeys(sender.persona, group: group), shared.settings.isAdmin(keys.publicKey) else { return }
        // A key an admin banned doesn't come in through an old invitation: the ask is dropped and nothing is added.
        if shared.links?.bans.contains(card.signingKey) == true {
            shared.invited[sender.fingerprint] = nil
            shared.invitedEpoch[sender.fingerprint] = nil
            shared.staffInvited?[sender.fingerprint] = nil
            data.conversations[i].shared = shared
            save()
            return
        }
        let wasStaffInvite = shared.invited[sender.fingerprint] == nil
        let previousKnown = shared.knownAs[sender.fingerprint]
        shared.invited[sender.fingerprint] = nil
        shared.invitedEpoch[sender.fingerprint] = nil
        shared.knownAs[sender.fingerprint] = card.fingerprint
        data.conversations[i].shared = shared
        // A follower the owner asked to join the staff: their named card goes in the settings, as an admin, and they
        // leave the roster (they are staff now). Only for an answer to that ask, with a name.
        if shared.settings.kind == .channel, wasStaffInvite, shared.staffInvited?[sender.fingerprint] != nil, !card.name.isEmpty,
           shared.settings.owner == keys.publicKey {
            shared.staffInvited?[sender.fingerprint] = nil
            data.conversations[i].shared = shared
            guard !shared.settings.isMember(card.signingKey), shared.settings.members.count < GroupSettings.maxMembers else { save(); return }
            var next = shared.settings
            next.members.append(card.withoutAvatar)
            next.admins.append(card.signingKey)
            if publishSettings(next, at: i) {
                if let avatar = card.avatar { noteAvatar(avatar, of: card, at: i) }
                if var roster = data.conversations[i].shared?.roster {
                    roster = roster.merged(with: .init(entries: [], removed: [.init(key: card.signingKey, at: Date())]), group: group)
                    data.conversations[i].shared?.roster = roster
                }
                publishRoster(at: i)
            }
            return
        }
        // A follower of a channel goes in the staff's roster, never in the settings every follower holds.
        if shared.settings.kind == .channel {
            guard !shared.settings.isMember(card.signingKey), card.name.isEmpty, card.avatarHash == nil else {
                data.conversations[i].shared?.knownAs[sender.fingerprint] = previousKnown
                save()
                return
            }
            addFollower(card, replacing: previousKnown, at: i)
            return
        }
        guard !shared.settings.isMember(card.signingKey), shared.settings.members.count < GroupSettings.maxMembers else { save(); return }
        var next = shared.settings
        next.members.append(card.withoutAvatar)
        if publishSettings(next, at: i), let avatar = card.avatar { noteAvatar(avatar, of: card, at: i) }
    }

    // MARK: A follower leaving, or asking for a key it missed

    /// Whether this account follows the channel (holds its key, is in nobody's list) rather than being staff.
    func isFollower(_ convo: Conversation) -> Bool {
        guard convo.kind == .channel, let shared = convo.shared, !shared.gone,
              let keys = memberKeys(convo.persona, group: convo.wireID) else { return false }
        return !shared.settings.isMember(keys.publicKey)
    }

    /// The staff member who invited this follower, if their chat can still carry a message from here: a known contact (hidden
    /// or not: someone who followed through a channel code is a hidden contact on both sides) with a device to write to.
    private func inviterContact(of convo: Conversation) -> Contact? {
        guard let account = convo.shared?.ownerAccount, let inviter = contact(account, in: convo.persona), !inviter.isSelf,
              inviter.devices.contains(where: { !$0.sendID.isEmpty || $0.session != nil }) else { return nil }
        return inviter
    }

    /// Whether a notice from this follower can be sent to the staff member who invited them (the details sheet says so
    /// plainly when it can't, before they leave).
    func canTellInviter(_ convo: Conversation) -> Bool { inviterContact(of: convo) != nil }

    /// Says something to the staff member who invited this follower, over their chat: the only one who can tell which
    /// account a roster entry is. It waits there until the chat can deliver. False if that chat is gone, so the caller can say so.
    @discardableResult
    private func noticeToInviter(_ payload: Payload, of convo: Conversation) -> Bool {
        guard let inviter = inviterContact(of: convo), let c = contactIndex(inviter.fingerprint, inviter.persona) else { return false }
        // Asking twice while the first still waits adds nothing.
        if case let .channelKeyWanted(group, _) = payload {
            for d in data.contacts[c].devices.indices {
                data.contacts[c].devices[d].pending.removeAll {
                    if case let .channelKeyWanted(g, _) = $0.payload { g == group } else { false }
                }
            }
        }
        enqueue(payload, to: inviter)
        return true
    }

    /// This follower missed a new key and can ask for it again: ten minutes apart (the staff phone answers a follower at
    /// most once in ten minutes whatever is sent).
    func canAskForKey(_ convo: Conversation) -> Bool {
        guard isFollower(convo), let shared = convo.shared, shared.missedKey, canTellInviter(convo) else { return false }
        return Date().timeIntervalSince(shared.keyAskedAt ?? .distantPast) > Self.keyAskCooldown
    }

    static let keyAskCooldown: TimeInterval = 600

    /// Asks the staff member who invited this follower for the key of the epoch it missed, over their chat.
    func askForKeyAgain(_ id: Conversation.ID) {
        guard let i = index(of: id), let convo = conversation(id), canAskForKey(convo), let shared = convo.shared else { return }
        let held = shared.epochs.map(\.number).max() ?? 0
        guard noticeToInviter(.channelKeyWanted(group: convo.wireID, epoch: held), of: convo) else { return }
        data.conversations[i].shared?.keyAskedAt = Date()
        save()
    }

    /// The roster entry of the follower this device invited under the account that is writing, in the channel named: only
    /// someone this phone itself admitted, who is still in the roster, and not staff. Whatever the message says plays no part.
    private func followerEntry(of sender: Contact, group: UUID) -> (index: Int, card: MemberCard)? {
        guard let i = groupIndex(group, persona: sender.persona), let shared = data.conversations[i].shared,
              shared.settings.kind == .channel, !shared.gone, let keys = memberKeys(sender.persona, group: group),
              shared.settings.isAdmin(keys.publicKey), let known = shared.knownAs[sender.fingerprint],
              let card = shared.roster?.live.first(where: { Identity.fingerprint(of: $0.signingKey) == known }),
              !shared.settings.isMember(card.signingKey) else { return nil }
        return (i, card)
    }

    /// How long after a follower leaves the channel's next epoch is made, so followers who leave close together share one
    /// (every new epoch costs the staff a copy of the key for each follower left, and each follower who was away a question).
    static var leaveRekeyWindow: TimeInterval = 600
    /// A new epoch with everyone still in is started once the current one is this old, or this many chat posts long (once
    /// something was said in it, and an admin's device is on), so someone who got hold of a group key is locked out again
    /// within days. Three days, not less: a new epoch's key is posted in the one before, and a member away for longer than
    /// the relay keeps that (7 days) has to be added again. Old keys go a week after the next epoch begins
    /// (`SharedGroup.readable`, erased in `tendSharedGroups`).
    static var epochMaxAge: TimeInterval = 3 * 86_400
    static var epochMaxChats = 300
    /// An admin device whose attempt didn't take waits this long before another.
    static var rotationRetry: TimeInterval = 3_600
    /// How soon a new epoch for someone taken out that couldn't be made is tried again.
    static var rekeyRetry: TimeInterval = 30

    /// A follower says they are leaving: gone from the roster at once (so no later key is sealed to them), and the channel
    /// moves to a new epoch without them together with anyone else who leaves in the next few minutes. A removal always
    /// ends in a new epoch: the maintenance pass keeps trying (`rekeyAfter`) until the settings name one. Said again, or
    /// by someone else, it finds no live entry and does nothing; one older than the entry (a stale copy after they were
    /// added again) is dropped.
    private func followerLeft(_ group: UUID, from sender: Contact) {
        guard let (i, card) = followerEntry(of: sender, group: group), var shared = data.conversations[i].shared else { return }
        if let sent = handlingSentAt,
           let added = shared.roster?.entries.first(where: { $0.card.signingKey == card.signingKey })?.added,
           sent < added.addingTimeInterval(-600) { return }
        shared.roster = (shared.roster ?? .init(entries: [], removed: [])).merged(
            with: .init(entries: [], removed: [.init(key: card.signingKey, at: Date())]), group: group)
        // A mark left from an epoch that has since moved on is stale (the maintenance pass clears it lazily): this leave
        // needs a new epoch of its own.
        if shared.rekeyAfter.map({ shared.settings.epoch > $0 }) ?? true {
            shared.rekeyAfter = shared.settings.epoch
            shared.rekeyDue = Date().addingTimeInterval(Self.leaveRekeyWindow)
        }
        data.conversations[i].shared = shared
        publishRoster(at: i)
        applySharedSettings(at: i)
        save()
    }

    /// Asks the admin who invited this account into a group for the current key, over the 1:1 chat (`channelKeyWanted`,
    /// the same ask a channel's follower makes), at most once every ten minutes.
    private func askInviterForKey(at i: Int) {
        let convo = data.conversations[i]
        guard let shared = convo.shared, !shared.gone, Date().timeIntervalSince(shared.inviterAskedAt ?? .distantPast) > Self.keyAskCooldown
        else { return }
        let held = shared.epochs.map(\.number).max() ?? 0
        guard noticeToInviter(.channelKeyWanted(group: convo.wireID, epoch: held), of: convo) else { return }
        data.conversations[i].shared?.inviterAskedAt = Date()
    }

    /// The member of a group this device invited under the account that is writing: only someone this phone itself added,
    /// who is still a member. Whatever the message says plays no part.
    private func memberEntry(of sender: Contact, group: UUID) -> (index: Int, card: MemberCard)? {
        guard let i = groupIndex(group, persona: sender.persona), let shared = data.conversations[i].shared,
              shared.settings.kind == .group, !shared.gone, let keys = memberKeys(sender.persona, group: group),
              shared.settings.isAdmin(keys.publicKey), let known = shared.knownAs[sender.fingerprint],
              let card = shared.settings.members.first(where: { $0.fingerprint == known }) else { return nil }
        return (i, card)
    }

    /// A follower asks for the current key, because the channel moved on while they were away. Answered with the same
    /// invite that admitted them (settings and the current epoch's key), over their own chat, so no other follower sees
    /// anything. Only if they are still in the roster and the epoch they hold is older than the current one, and once every
    /// ten minutes however many requests come. A group's member asks the same way, and is answered by the admin's
    /// phone that invited them, if they are still a member.
    private func answerKeyRequest(_ group: UUID, held: Int, from sender: Contact) {
        guard let (i, card) = followerEntry(of: sender, group: group) ?? memberEntry(of: sender, group: group), let shared = data.conversations[i].shared,
              let current = shared.current, held >= 0, held < current.number, shared.settings.epoch == current.number else { return }
        let limit = group.uuidString + card.signingKey.hex
        guard Date().timeIntervalSince(channelKeyAnswered[limit] ?? .distantPast) > 600 else { return }
        channelKeyAnswered[limit] = Date()
        enqueue(.groupInvite(vouched(GroupInvite(settings: shared.settings, epoch: current), at: i)), to: sender)
    }

#if DEBUG
    /// For tests: the invite this device would send for one of its channels now, with its word as staff, naming `code`.
    func vouchedInviteForTests(_ id: Conversation.ID, code: Data?) -> GroupInvite? {
        guard let i = index(of: id), let shared = data.conversations[i].shared, let epoch = shared.current else { return nil }
        return vouched(GroupInvite(settings: shared.settings, epoch: epoch, code: code), at: i)
    }

    /// For tests: lets people who followed through the channel's code in, as a hello would.
    func admitFromCodeForTests(_ fingerprints: [String], in id: Conversation.ID) {
        if let i = index(of: id) { admitFromCode(fingerprints, at: i) }
    }

    /// For tests: says something over a chat the way this device would.
    func sendForTests(_ payload: Payload, to contact: Contact) { enqueue(payload, to: contact) }

    /// For tests: takes in a payload as if it had arrived over that contact's chat (the sender is the one named, as the
    /// session would have said).
    func receiveForTests(_ payload: Payload, from contact: Contact) {
        handle(payload, from: contact.fingerprint, persona: contact.persona, device: contact.devices.first?.id ?? Data())
    }

    /// For tests: the history a newly linked device would be sent.
#endif

    // MARK: A channel's followers

    /// Puts a follower in the staff's roster and tells the other staff. The channel's own settings never name them.
    private func addFollower(_ card: MemberCard, replacing previous: String?, at i: Int) {
        guard var shared = data.conversations[i].shared, shared.settings.kind == .channel else { return }
        let gid = data.conversations[i].wireID
        let body = shared.roster ?? GroupRoster.Body(entries: [], removed: [])
        // The same account again under another key: the older key is taken out, so one account is one follower and
        // taking them out takes out every key they had.
        let older = body.live.filter { Identity.fingerprint(of: $0.signingKey) == previous && $0.signingKey != card.signingKey }
        let cleared = body.merged(with: .init(entries: [], removed: older.map { .init(key: $0.signingKey, at: Date()) }), group: gid)
        let next = cleared.merged(with: .init(entries: [.init(card: card.withoutAvatar, added: Date())], removed: []), group: gid)
        guard next.entries.count <= GroupRoster.Body.maxEntries, next.live.count > cleared.live.count || !older.isEmpty else { save(); return }
        shared.roster = next
        data.conversations[i].shared = shared
        publishRoster(at: i)
        applySharedSettings(at: i)
        save()
    }

    /// Posts the roster, sealed to this channel's staff, in the current epoch's mailbox. Only staff can open it.
    private func publishRoster(at i: Int) {
        guard let shared = data.conversations[i].shared, shared.settings.kind == .channel, let body = shared.roster,
              let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              shared.settings.isAdmin(keys.publicKey), let epoch = shared.current, shared.staffEpoch != nil else { return }
        // Sealed to the admins only (a plain member of a channel mustn't be able to open it).
        let admins = shared.settings.members.filter { shared.settings.isAdmin($0.signingKey) }
        guard let roster = GroupRoster.make(body, group: shared.settings.group, epoch: epoch.number, staff: admins, keys: keys),
              roster.isReasonable, GroupSeal.fits(payload: (try? Payload.groupRoster(roster).wire(framed: false).count) ?? Int.max) else { return }
        // In the staff mailbox, not the channel's own: followers would see each change as it happens.
        post(.groupRoster(roster), at: i, inEpoch: 0)
        data.conversations[i].shared?.rosterEpoch = Int(Date().timeIntervalSince1970)
        data.conversations[i].shared?.rosterStaff = admins.map(\.signingKey).sorted { $0.hex < $1.hex }
    }

    /// What another staff member's roster adds to this one. If this device knows more than they did, the fuller one is
    /// posted too, so every staff member ends up with the same list.
    private func adoptRoster(_ body: GroupRoster.Body, at i: Int) {
        guard var shared = data.conversations[i].shared, shared.settings.kind == .channel else { return }
        let gid = data.conversations[i].wireID
        let mine = shared.roster ?? GroupRoster.Body(entries: [], removed: [])
        let merged = mine.merged(with: body, group: gid)
        guard merged != mine else { return }
        shared.roster = merged
        data.conversations[i].shared = shared
        if merged != body.merged(with: body, group: gid) { publishRoster(at: i) }
        applySharedSettings(at: i)
    }

    /// Asks a follower to join the staff: they answer with a card with their name, and go in the settings as an admin.
    private func promoteFollower(_ fingerprint: String, at i: Int) {
        guard var shared = data.conversations[i].shared, let epoch = shared.current,
              let target = contact(fingerprint, in: data.conversations[i].persona), takesChannels(target) else { return }
        shared.staffInvited = (shared.staffInvited ?? [:]).merging([fingerprint: Date()]) { _, new in new }
        data.conversations[i].shared = shared
        enqueue(.groupInvite(vouched(GroupInvite(settings: shared.settings, epoch: epoch, staff: true, staffKey: shared.staffKey), at: i)), to: target)
        save()
    }

    /// A new staff mailbox key, after an admin was taken out or let go: the old key opens nothing from now on. The owner
    /// gives the new one to each admin who is left, over the chat they were asked in.
    private func rotateStaffKey(at i: Int) {
        guard var shared = data.conversations[i].shared, shared.settings.kind == .channel,
              let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              shared.settings.owner == keys.publicKey, let epoch = shared.current else { return }
        shared.staffKey = .random(32)
        shared.chains["0"] = nil
        shared.chainStarts?["0"] = nil
        shared.cursors["0"] = nil
        shared.reader.forget(epoch: 0)
        data.conversations[i].shared = shared
        let adminKeys = Set(shared.settings.admins).subtracting([shared.settings.owner])
        for (account, fingerprint) in shared.knownAs where adminKeys.contains(where: { Identity.fingerprint(of: $0) == fingerprint }) {
            guard let contact = contact(account, in: data.conversations[i].persona) else { continue }
            enqueue(.groupInvite(vouched(GroupInvite(settings: shared.settings, epoch: epoch, staff: true, staffKey: shared.staffKey), at: i)), to: contact)
        }
        publishRoster(at: i)
        save()
    }

    /// Takes a follower out of a channel by their key in the roster (staff who didn't invite them know no more than that).
    func removeFollower(_ key: Data, in id: Conversation.ID) {
        if let i = index(of: id) { removeFollower(key, at: i) }
    }

    /// Takes a follower out of a channel: gone from the roster, then a new epoch they don't get.
    private func removeFollower(_ key: Data, at i: Int) {
        guard var shared = data.conversations[i].shared, shared.settings.kind == .channel,
              let me = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              shared.settings.isAdmin(me.publicKey), shared.roster?.live.contains(where: { $0.signingKey == key }) == true else { return }
        shared.roster = (shared.roster ?? .init(entries: [], removed: [])).merged(
            with: .init(entries: [], removed: [.init(key: key, at: Date())]), group: data.conversations[i].wireID)
        shared.rekeyAfter = shared.settings.epoch
        shared.rekeyDue = nil
        data.conversations[i].shared = shared
        startEpoch(at: i, without: [])
        publishRoster(at: i)
    }

    // MARK: Settings

    /// Signs and posts a new version of the settings, if it's one the others will take from this account and it fits in
    /// one envelope.
    @discardableResult
    private func publishSettings(_ proposed: GroupSettings, at i: Int) -> Bool {
        guard let shared = data.conversations[i].shared, let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID) else { return false }
        var next = proposed
        next.version = shared.settings.version + 1
        next.sign(with: keys)
        guard shared.settings.accepts(next), next.fitsInMailbox else { return false }
        data.conversations[i].shared?.previous = shared.settings
        data.conversations[i].shared?.noteAdded(from: shared.settings, to: next)
        data.conversations[i].shared?.settings = next
        applySharedSettings(at: i)
        post(.groupSettings(next), at: i)
        // Posts held because their sender wasn't listed yet (a newcomer asking for chains before its card was in) are
        // read again now that it may be, as they are when someone else's settings arrive.
        rereadHeldMail(at: i)
        save()
        return true
    }

    /// The settings as this conversation shows them: names, roles and who is in it, with this account as "me".
    private func applySharedSettings(at i: Int) {
        guard let shared = data.conversations[i].shared, let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID) else { return }
        let s = shared.settings
        let persona = data.conversations[i].persona
        let mine = keys.publicKey
        func fp(_ key: Data) -> String { key == mine ? "me" : Identity.fingerprint(of: key) }
        // Everyone else in it is met as a hidden contact with no devices: shown by name, never written to directly.
        for card in s.members where card.signingKey != mine {
            let f = card.fingerprint
            if let c = contactIndex(f, persona) {
                guard data.contacts[c].hidden, data.contacts[c].devices.allSatisfy({ $0.sendID.isEmpty }) else { continue }
                data.contacts[c].name = card.name
                data.contacts[c].color = card.color
                // A picture stays only while it is the one their card names.
                if card.avatarHash == nil || data.contacts[c].avatar.map({ Data(SHA256.hash(data: $0)) }) != card.avatarHash {
                    data.contacts[c].avatar = nil
                }
            } else {
                var peer = Contact(fingerprint: f, name: card.name, signingKey: card.signingKey,
                                   agreementKey: card.agreementKey, sendID: Data(), hidden: true)
                peer.devices = []
                peer.color = card.color
                peer.persona = persona
                upsert(peer)
            }
        }
        data.conversations[i].title = String(s.title.prefix(80))
        data.conversations[i].avatar = s.avatar
        data.conversations[i].about = s.about.map { String($0.prefix(500)) }
        data.conversations[i].members = s.members.map(\.signingKey).filter { $0 != mine }.map(fp)
        // Staff of a channel also see the followers they invited, by the accounts they know them as.
        if s.kind == .channel, s.isAdmin(mine), let live = shared.roster?.live.map(\.signingKey) {
            let liveFingerprints = Set(live.map { Identity.fingerprint(of: $0) })
            let followers = shared.knownAs.filter { liveFingerprints.contains($0.value) }.map(\.key).sorted()
            data.conversations[i].members += followers.filter { !data.conversations[i].members.contains($0) }
        }
        data.conversations[i].owner = fp(s.owner)
        data.conversations[i].admins = s.admins.filter { $0 != s.owner }.map(fp)
        data.conversations[i].mods = s.mods.map(fp)
        data.conversations[i].postPolicy = s.postPolicy
        data.conversations[i].version = s.version
        if data.conversations[i].disappearAfter != s.disappearAfter { applyTimer(s.disappearAfter, at: i) }
        if shared.joining, s.isMember(mine) {
            data.conversations[i].shared?.joining = false
        }
    }

    /// A member's picture, kept if their card in the settings names it.
    private func noteAvatar(_ avatar: Data, of card: MemberCard, at i: Int) {
        guard let held = data.conversations[i].shared?.settings.card(card.signingKey), held.sameCard(as: card),
              card.verified(group: data.conversations[i].wireID), let c = contactIndex(card.fingerprint, data.conversations[i].persona),
              data.contacts[c].hidden, data.contacts[c].devices.allSatisfy({ $0.sendID.isEmpty }) else { return }
        data.contacts[c].avatar = avatar
    }

    /// The settings the conversation's fields now describe (an admin changed the name, a role, the timer).
    private func proposedSettings(at i: Int) -> GroupSettings? {
        let convo = data.conversations[i]
        guard let shared = convo.shared, let keys = memberKeys(convo.persona, group: convo.wireID) else { return nil }
        let persona = convo.persona
        func key(_ fp: String) -> Data? { fp == "me" ? keys.publicKey : contact(fp, in: persona)?.signingKey }
        var next = shared.settings
        next.title = convo.title
        next.about = convo.about
        next.avatar = Self.thumbnail(convo.avatar, side: 320)
        next.postPolicy = convo.postPolicy
        next.admins = convo.admins.compactMap(key).filter { $0 != next.owner }
        next.mods = convo.mods.compactMap(key)
        next.disappearAfter = convo.disappearAfter
        return next
    }

    /// An admin's change to a group's details or roles.
    func publishSharedChange(_ i: Int) {
        guard let next = proposedSettings(at: i), !publishSettings(next, at: i) else { return }
        // Not one this account may make: put the conversation back as the settings say.
        applySharedSettings(at: i)
    }

    // MARK: Epochs

    /// Starts a new epoch: its key is sealed to everyone still in (all but `without`) and posted in the current
    /// mailbox, then the settings move to it. Whoever is left out can still read the old mailbox, never the new.
    private func startEpoch(at i: Int, without removed: Set<Data>) {
        guard var shared = data.conversations[i].shared, let current = shared.current,
              let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID) else { return }
        guard groupNumberRange.contains(current.number + 1) else { return }
        // Every new epoch gets the shorter relay life, even in a group that began with the old week.
        let next = GroupEpoch.fresh(number: current.number + 1, days: GroupEpoch.defaultDays)
        var settings = shared.settings
        settings.members.removeAll { removed.contains($0.signingKey) }
        settings.admins.removeAll { removed.contains($0) }
        settings.mods.removeAll { removed.contains($0) }
        settings.epoch = next.number
        settings.epochCheck = next.check
        settings.version = shared.settings.version + 1
        settings.sign(with: keys)
        guard shared.settings.accepts(settings), settings.fitsInMailbox else { return }
        // The key goes out in the old mailbox first, then the settings that move to it, in that order.
        let channel = settings.kind == .channel
        let readers = settings.members.filter { $0.signingKey != keys.publicKey } + (channel ? (shared.roster?.live ?? []) : [])
        // Each copy carries an ML-KEM ciphertext (about 1.5 KB once posted); a hand-out that wouldn't fit one envelope
        // isn't made.
        let rekey = GroupRekey.make(next, group: shared.settings.group, for: readers, tagged: channel)
        guard rekey.isReasonable, GroupSeal.fits(payload: (try? Payload.groupRekey(rekey).wire(framed: false).count) ?? Int.max) else { return }
        post(.groupRekey(rekey), at: i)
        post(.groupSettings(settings), at: i)
        shared = data.conversations[i].shared ?? shared
        shared.previous = shared.settings
        install(next, in: &shared)
        shared.noteAdded(from: shared.settings, to: settings)
        shared.settings = settings
        shared.chatInEpoch = false
        shared.chatsInEpoch = nil
        data.conversations[i].shared = shared
        applySharedSettings(at: i)
        rereadHeldMail(at: i)
        save()
    }

    /// Names as a sentence: "Mariah", "Mariah and Sam", "Mariah, Sam and Lee".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "nobody"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    /// Starts a new epoch with everyone still in. For tests, and for an admin who wants fresh keys.
    func startNewEpoch(_ id: Conversation.ID) {
        guard let i = index(of: id), data.conversations[i].shared != nil else { return }
        startEpoch(at: i, without: [])
    }

    /// Takes someone out of a shared group: a new epoch they don't get. Remembered until it has stuck, so a competing
    /// change that wins doesn't quietly undo it.
    func removeSharedMember(_ fingerprint: String, at i: Int) {
        // A channel's follower is known to staff only by the account that was invited, and held in the roster.
        if let shared = data.conversations[i].shared, shared.settings.kind == .channel,
           let key = shared.roster?.live.first(where: { Identity.fingerprint(of: $0.signingKey) == shared.knownAs[fingerprint] })?.signingKey {
            data.conversations[i].shared?.staffInvited?[fingerprint] = nil
            removeFollower(key, at: i)
            return
        }
        guard let shared = data.conversations[i].shared, let target = contact(fingerprint, in: data.conversations[i].persona),
              shared.settings.isMember(target.signingKey) else { return }
        let wasAdmin = shared.settings.isAdmin(target.signingKey)
        data.conversations[i].shared?.wantRemoved[target.signingKey.hex] = Date()
        startEpoch(at: i, without: [target.signingKey])
        if wasAdmin, shared.settings.kind == .channel { rotateStaffKey(at: i) }
    }

    // MARK: New group keys after a device is unlinked

    /// Makes a new group secret, tells the account's other devices, and moves every group to keys made with it
    /// (`renewMemberKeys`). The device that was unlinked holds only the secret before, so it can't work out the new
    /// keys: it is left out of every new epoch, and no member device hands it a chain again.
    func renewGroupSecret() {
        stampGroups(with: data.groupSecret ?? Data())
        let secret = Data.random(32)
        data.groupSecret = secret
        data.groupRenewAfter = Date()
        for i in data.conversations.indices { renewMemberKeys(at: i) }
        save()
    }

    /// How long a device that didn't make a new group secret waits before moving groups to it itself.
    static let groupRenewWait: TimeInterval = 600

    /// Marks every group not already marked as still on `secret`, before the current secret changes.
    private func stampGroups(with secret: Data) {
        for i in data.conversations.indices where data.conversations[i].shared != nil && data.conversations[i].shared?.memberSecret == nil {
            data.conversations[i].shared?.memberSecret = secret
        }
    }

    /// Moves this account in one group from keys made with an older group secret to keys made with the current one: a
    /// new card under the new key in place of the old, with its roles, and a new epoch sealed to everyone but the old
    /// key (`GroupSettings.renewal`). A channel's follower sends the new card to the staff member who invited them, who
    /// does the same in the roster. False if it couldn't be done now (tried again later).
    @discardableResult
    private func renewMemberKeys(at i: Int) -> Bool {
        let convo = data.conversations[i]
        guard var shared = convo.shared, let held = shared.memberSecret, let me = me(convo.persona) else { return true }
        let gid = convo.wireID
        let old = GroupMemberKeys(seed: me.seed, group: gid, secret: held)
        let new = GroupMemberKeys(seed: me.seed, group: gid, secret: data.groupSecret)
        let s = shared.settings
        if shared.gone || old.publicKey == new.publicKey || s.isMember(new.publicKey) {
            data.conversations[i].shared?.memberSecret = nil
            if !shared.gone, old.publicKey != new.publicKey { data.conversations[i].shared?.peers = nil }
            return true
        }
        guard s.isMember(old.publicKey) else {
            // A follower: the staff member who invited them puts the new card in the roster in place of the old.
            guard s.kind == .channel else { return false }
            let card = MemberCard.make(new, group: gid, name: "", avatar: nil, color: nil)
            guard noticeToInviter(.groupJoin(group: gid, card: card), of: convo) else { return false }
            data.conversations[i].shared?.memberSecret = nil
            return true
        }
        guard let current = shared.current, groupNumberRange.contains(current.number + 1) else { return false }
        let p = profile(for: convo.persona)
        let card = MemberCard.make(new, group: gid, name: p.name, avatar: Self.thumbnail(p.avatar, side: 96), color: p.color)
        let epoch = GroupEpoch.fresh(number: current.number + 1)
        func swap(_ key: Data) -> Data { key == old.publicKey ? new.publicKey : key }
        var next = s
        next.members = s.members.map { $0.signingKey == old.publicKey ? card.withoutAvatar : $0 }
        next.owner = swap(s.owner)
        next.admins = s.admins.map(swap)
        next.mods = s.mods.map(swap)
        next.epoch = epoch.number
        next.epochCheck = epoch.check
        next.version = s.version + 1
        next.sign(with: old)
        guard s.accepts(next), next.fitsInMailbox else { return false }
        // Sealed to the new card too, so this account's other devices can open it before their settings move.
        let channel = s.kind == .channel
        let readers = next.members + (channel ? (shared.roster?.live ?? []) : [])
        let rekey = GroupRekey.make(epoch, group: s.group, for: readers, tagged: channel)
        guard rekey.isReasonable, GroupSeal.fits(payload: (try? Payload.groupRekey(rekey).wire(framed: false).count) ?? Int.max) else { return false }
        // Posted under the old key, which the settings held now list.
        post(.groupRekey(rekey), at: i)
        post(.groupSettings(next), at: i)
        shared = data.conversations[i].shared ?? shared
        shared.previous = shared.settings
        install(epoch, in: &shared)
        shared.noteAdded(from: s, to: next)
        shared.settings = next
        shared.chatInEpoch = false
        shared.chatsInEpoch = nil
        shared.memberSecret = nil
        shared.renewing = held
        shared.renewals = Array(((shared.renewals ?? []) + [RenewalMark(old: old.publicKey, new: new.publicKey, version: next.version)]).suffix(RenewalMark.kept))
        // Sessions were opened under the old keys; new ones are opened under the new as they're needed.
        shared.peers = nil
        shared.chainAsked = nil
        shared.cardPostedEpoch = nil
        data.conversations[i].shared = shared
        applySharedSettings(at: i)
        if channel {
            // The staff mailbox's key and the roster: the old key opens neither from now on.
            if next.owner == new.publicKey { rotateStaffKey(at: i) } else { publishRoster(at: i) }
        }
        save()
        return true
    }

    /// Groups still on an older group secret are moved on, once this device may (`groupRenewAfter`), at most every ten
    /// minutes each. An account that has no group secret yet gets one from its lead device.
    private func tendGroupSecret() {
        settleForeignMoves()
        if data.groupSecret == nil, identity != nil {
            renewGroupSecret()
            return
        }
        guard Date() >= data.groupRenewAfter ?? .distantPast else { return }
        let now = Date()
        for i in data.conversations.indices where data.conversations[i].shared?.memberSecret != nil {
            let id = data.conversations[i].id
            guard now.timeIntervalSince(groupRenewTried[id] ?? .distantPast) > 600 else { continue }
            groupRenewTried[id] = now
            if renewMemberKeys(at: i) { groupRenewTried[id] = nil }
        }
    }

    /// Groups where this account's place was moved to keys this device couldn't make (`SharedGroup.foreignMove`). Once
    /// the group secret that makes them arrives (another of this account's devices moved it), the move is taken. If it
    /// hasn't after `groupRenewWait`, a device holding the account's old keys made it: this device moves the same place to
    /// a key of its own from the same version, so every member sees two moves of one place and holds both back
    /// (`disputeRenewal`), and leaves, asking to be added again.
    private func settleForeignMoves() {
        for i in data.conversations.indices {
            guard let shared = data.conversations[i].shared, !shared.gone, let move = shared.foreignMove,
                  let me = me(data.conversations[i].persona) else { continue }
            let gid = data.conversations[i].wireID
            let makeable = [data.groupSecret, shared.memberSecret].compactMap { $0 }.map { GroupMemberKeys(seed: me.seed, group: gid, secret: $0).publicKey }
            let taker = move.members.map(\.signingKey).first { !shared.settings.isMember($0) }
            if let taker, makeable.contains(taker) {
                data.conversations[i].shared?.foreignMove = nil
                data.conversations[i].shared?.foreignMoveAt = nil
                adoptSettings(move, at: i)
                continue
            }
            guard Date().timeIntervalSince(shared.foreignMoveAt ?? .distantPast) > Self.groupRenewWait else { continue }
            counterMove(move, at: i)
        }
    }

    /// Moves this account's place in group `i` to a throwaway key, from the same version as `move` (another device's move
    /// of the same place): members then hold two moves of one place, so they take neither (`disputeRenewal`). Then this
    /// device leaves the group.
    private func counterMove(_ move: GroupSettings, at i: Int) {
        guard let shared = data.conversations[i].shared, let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              let current = shared.current, groupNumberRange.contains(current.number + 1) else { return }
        let s = shared.settings
        let gid = data.conversations[i].wireID
        let decoy = GroupMemberKeys(seed: .random(32), group: gid)
        let card = MemberCard.make(decoy, group: gid, name: "", avatar: nil, color: nil)
        let epoch = GroupEpoch.fresh(number: current.number + 1)
        func swap(_ key: Data) -> Data { key == keys.publicKey ? decoy.publicKey : key }
        var counter = s
        counter.members = s.members.map { $0.signingKey == keys.publicKey ? card : $0 }
        counter.owner = swap(s.owner)
        counter.admins = s.admins.map(swap)
        counter.mods = s.mods.map(swap)
        counter.epoch = epoch.number
        counter.epochCheck = epoch.check
        counter.version = move.version
        counter.sign(with: keys)
        if s.renewal(to: counter) != nil, counter.fitsInMailbox {
            let channel = s.kind == .channel
            let readers = counter.members.filter { $0.signingKey != decoy.publicKey } + (channel ? (shared.roster?.live ?? []) : [])
            post(.groupRekey(GroupRekey.make(epoch, group: gid, for: readers, tagged: channel)), at: i)
            post(.groupSettings(counter), at: i)
            // The group goes from this device, outbox and all: these still go out, with retries (`partingPosts`).
            if let after = data.conversations[i].shared {
                let parting = after.outbox.filter { !$0.ephemeral }.map {
                    PartingPost(post: $0, persona: data.conversations[i].persona, known: after.postedTo.contains($0.sendID.hex))
                }
                data.partingPosts = Array((data.partingPosts + parting).suffix(Self.partingPostsKept))
            }
        }
        data.conversations[i].shared?.foreignMove = nil
        data.conversations[i].shared?.foreignMoveAt = nil
        defer { if !data.partingPosts.isEmpty { kick() } }
        leftShared(at: i, note: "A device holding your account's old keys moved your place in this group, so the members can't tell which is you. "
                   + "If it isn't one of yours, unlink it in Devices, and ask an admin to add you again.")
        save()
    }

    // MARK: Posting

    /// Says something to a shared group: sealed once, posted once. False when this isn't a shared group (the caller
    /// sends to each member as before).
    @discardableResult
    func postIfShared(_ payload: Payload, in id: Conversation.ID, message: UUID? = nil) -> Bool {
        guard let i = index(of: id), data.conversations[i].shared != nil else { return false }
        post(payload, at: i, message: message)
        return true
    }

    private func post(_ payload: Payload, at i: Int, message: UUID? = nil, inEpoch number: Int? = nil, replay: Bool = false) {
        guard var shared = data.conversations[i].shared, !shared.gone, let epoch = number.flatMap({ shared.epoch($0) }) ?? shared.current,
              let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID) else { return }
        // Until an admin has put this device's card in, nothing it says would be taken: hold back everything but
        // leaving.
        if shared.joining, !payload.isLeaving { return }
        // A channel's followers only read; nothing of theirs goes in its mailbox.
        if shared.settings.kind == .channel, !shared.settings.isMember(keys.publicKey) { return }
        let tag = shared.myTag ?? .random(GroupSeal.deviceLength)
        shared.myTag = tag
        if payload.goesWithoutChain {
            guard epoch.number != 0, let plain = try? payload.wire(framed: false), GroupSeal.fits(payload: plain.count),
                  let blob = try? GroupSeal.sealDirect(plain, group: data.conversations[i].wireID, epoch: epoch, keys: keys, device: tag) else { return }
            shared.outbox.append(GroupOutgoing(sendID: epoch.sendID, days: epoch.days, blob: blob, message: nil, wake: payload.wakes,
                                               ephemeral: false, epoch: epoch.number))
            data.conversations[i].shared = shared
            kick()
            return
        }
        // This device's chain in the epoch starts from random bytes of its own, and where it starts goes to every member
        // device this one has a session with, over that session, before the first post on it.
        let n = String(epoch.number)
        let first = shared.chains[n] == nil
        var chain = shared.chains[n] ?? .fresh()
        let before = chain
        guard let plain = try? payload.wire(framed: false),
              let blob = try? GroupSeal.seal(plain, group: data.conversations[i].wireID, epoch: epoch, keys: keys, device: tag, chain: &chain) else { return }
        shared.chains[n] = chain
        if first {
            shared.chainStarts = (shared.chainStarts ?? [:]).merging([n: before]) { _, new in new }
            data.conversations[i].shared = shared
            handOutChainStart(before, epoch: epoch.number, at: i)
            shared = data.conversations[i].shared ?? shared
        }
        if payload.isChat {
            shared.chatInEpoch = true
            if epoch.number == shared.current?.number { shared.chatsInEpoch = (shared.chatsInEpoch ?? 0) + 1 }
        }
        if payload.isEphemeral { shared.outbox.removeAll { $0.ephemeral } }
        var about = message
        if about == nil, case let .clipBlob(id, _) = payload { about = id }
        shared.outbox.append(GroupOutgoing(sendID: epoch.sendID, days: epoch.days, blob: blob, message: message,
                                           wake: replay ? false : payload.wakes, ephemeral: payload.isEphemeral, epoch: epoch.number, about: about,
                                           catchUp: replay ? nil : payload.isChat && !payload.isEphemeral, replay: replay ? true : nil))
        data.conversations[i].shared = shared
        kick()
    }

    /// Posts what's waiting in every shared group's outbox, oldest first, one group at a time each.
    func flushSharedGroups() async {
        for convo in data.conversations where !(convo.shared?.outbox.isEmpty ?? true) && !groupFlushing.contains(convo.id) {
            // Over Tor each group is posted to on a lane of its own, apart from the persona's one-to-one sending and from
            // its other groups, on a circuit that lasts one burst of posting (`SendLanes`).
            let base = isolatesLanes ? Lanes.groupSendLane(convo.id) : Outgoing.lane(for: convo.persona)
            let lane = sendLanes.current(base)
            if let retired = lane.retired { RelayClient.retire(lane: retired) }
            guard let client = client(nil, lane: lane.name) else { continue }
            let id = convo.id
            groupFlushing.insert(id)
            sendLanes.note(lane.name, busy: 1)
            defer {
                groupFlushing.remove(id)
                sendLanes.note(lane.name, busy: -1)
            }
            while let next = index(of: id).flatMap({ data.conversations[$0].shared?.outbox.first }) {
                // Typing that waited too long means nothing now.
                if next.ephemeral, Date().timeIntervalSince(next.queued) > 10 {
                    if let i = index(of: id) { data.conversations[i].shared?.outbox.removeAll { $0.id == next.id } }
                    continue
                }
                // The first post this device makes to a mailbox may be the one that starts it: that carries a proof of
                // work over Tor, so nobody can start endless mailboxes for free.
                let first = !(convo.shared?.postedTo.contains(next.sendID.hex) ?? false)
                    && !(index(of: id).flatMap { data.conversations[$0].shared?.postedTo.contains(next.sendID.hex) } ?? false)
                do {
                    do {
                        try await client.depositGroup(next.blob, to: next.sendID, days: next.days, wake: next.wake, prove: first)
                    } catch let refused as RelayRefused where refused.status == 429 && !first {
                        // The mailbox may have run out on the relay (or it lost it): starting it again needs the proof.
                        try await client.depositGroup(next.blob, to: next.sendID, days: next.days, wake: next.wake, prove: true)
                    }
                    if let i = index(of: id) { data.conversations[i].shared?.postedTo.insert(next.sendID.hex) }
                } catch is RelayTooLarge {
                    // Never going to fit: drop it rather than hold up everything behind it.
                } catch {
                    break
                }
                guard let i = index(of: id) else { break }
                data.conversations[i].shared?.outbox.removeAll { $0.id == next.id }
                notePosted(next, at: i)
                if let m = next.message { setStatus(.sent, for: [m]) }
                save()
            }
        }
    }

    /// A chat video in a shared group: the clip goes up once, sealed, and everyone gets one pointer to it.
    func sendSharedClip(_ clip: Data, id: UUID, in convoID: UUID) {
        guard let relay = blobClient(),
              let prepared = try? BlobTransfer.prepare(data: clip, kind: .video, lifetime: 7 * 86_400) else { return }
        Task { [weak self] in
            defer { RelayClient.retire(lane: relay.lane) }
            do { try await BlobTransfer.upload(prepared, to: relay) { _ in } } catch { return }
            guard let self, let i = self.index(of: convoID) else { return }
            if let m = self.data.conversations[i].messages.lastIndex(where: { $0.id == id && $0.isMine }) {
                self.data.conversations[i].messages[m].attachment = prepared.attachment
            }
            self.post(.clipBlob(id: id, clip: prepared.attachment), at: i)
            self.save()
        }
    }

    /// A big photo or voice note in a shared group: the sealed bytes go up once, then the group gets the message with
    /// a tiny preview and a pointer to them. If the upload can't be done (offline, say) the whole message goes into the
    /// mailbox as it always did, so it is never lost.
    private func postLightened(_ light: (wire: WireMessage, bytes: Data, kind: Attachment.Kind), full: WireMessage,
                               in convoID: UUID, message: UUID) {
        guard let relay = blobClient(),
              let prepared = try? BlobTransfer.prepare(data: light.bytes, kind: light.kind, lifetime: 7 * 86_400) else {
            postIfShared(.message(full), in: convoID, message: message)
            return
        }
        Task { [weak self] in
            defer { RelayClient.retire(lane: relay.lane) }
            var uploaded = true
            do { try await BlobTransfer.upload(prepared, to: relay) { _ in } } catch { uploaded = false }
            guard let self, let i = self.index(of: convoID) else { return }
            if uploaded {
                if let m = self.data.conversations[i].messages.lastIndex(where: { $0.id == message && $0.isMine }) {
                    self.data.conversations[i].messages[m].attachment = prepared.attachment
                }
                self.post(.message(light.wire), at: i, message: message)
                self.post(.clipBlob(id: message, clip: prepared.attachment), at: i)
            } else {
                self.post(.message(full), at: i, message: message)
            }
            self.save()
        }
    }

    /// Group mailboxes a lane reads, with where each was read up to.
    func groupCursors(for lane: Lane) -> [(key: Data, after: UInt64, convo: UUID, epoch: Int)] {
        guard lane.relay == nil else { return [] }
        let count = liveGroups.count
        var out: [(key: Data, after: UInt64, convo: UUID, epoch: Int)] = []
        for convo in data.conversations {
            guard let shared = convo.shared, !shared.gone, groupLane(convo, among: count) == lane.name else { continue }
            for epoch in shared.readable {
                out.append((epoch.receiveKey, shared.cursors[String(epoch.number)] ?? 0, convo.id, epoch.number))
            }
            // A channel's staff also read their own mailbox, where the follower roster is.
            if let staff = shared.staffEpoch, let me = memberKeys(convo.persona, group: convo.wireID), shared.settings.isAdmin(me.publicKey) {
                out.append((staff.receiveKey, shared.cursors["0"] ?? 0, convo.id, 0))
            }
        }
        return out
    }

    // MARK: Posts that must not get lost

    /// A deposited post is kept, sealed as it went, until it has been read back from the mailbox.
    private func notePosted(_ post: GroupOutgoing, at i: Int) {
        guard var shared = data.conversations[i].shared, !post.ephemeral, post.replay != true else { return }
        var kept = shared.kept ?? []
        if let k = post.keeps {
            guard let j = kept.firstIndex(where: { $0.id == k }) else { return }
            kept[j].tries += 1
            kept[j].lastTry = Date()
        } else {
            guard post.blob.count <= KeptPost.maxBlob, let number = post.epoch, let epoch = shared.epoch(number),
                  let outer = try? GroupSeal.outer(post.blob, group: data.conversations[i].wireID, epoch: epoch), !outer.isDirect else { return }
            kept.append(KeptPost(epoch: number, index: outer.index, sendID: post.sendID, days: post.days, blob: post.blob,
                                 about: post.about, chat: post.catchUp == true))
        }
        // The oldest go first, past a few hundred or a couple of megabytes.
        while kept.count > KeptPost.maxCount || (kept.count > 1 && kept.reduce(0, { $0 + $1.blob.count }) > KeptPost.maxBytes) {
            kept.removeFirst()
        }
        shared.kept = kept
        data.conversations[i].shared = shared
    }

    /// Notes that these mailboxes were just read to the end. A device that was away longer than the relay keeps mail
    /// remembers when it last read, to ask the others for what it missed.
    private func noteGroupsFetched(_ cursors: [(key: Data, after: UInt64, convo: UUID, epoch: Int)], at time: Date) {
        for at in cursors where at.epoch != 0 { groupFetchedAt["\(at.convo)|\(at.epoch)"] = time }
        for id in Set(cursors.map(\.convo)) {
            guard let i = index(of: id), let shared = data.conversations[i].shared, !shared.gone, !shared.joining,
                  let life = shared.current?.days else { continue }
            if let last = shared.lastFetch {
                if time.timeIntervalSince(last) > Double(life) * 86_400, shared.catchUpSince == nil {
                    data.conversations[i].shared?.catchUpSince = last
                    // Away longer than the relay keeps mail: any new key handed out meanwhile has gone with it, so the
                    // admin who invited this account is asked over the 1:1 chat (they answer only if there is a newer one).
                    if shared.settings.kind == .group { askInviterForKey(at: i) }
                }
                if time.timeIntervalSince(last) > 600 { data.conversations[i].shared?.lastFetch = time }
            } else {
                data.conversations[i].shared?.lastFetch = time
            }
        }
    }

    /// Posts what this device said since `since` again, for a member who was away (once an hour for each, a few requests
    /// an hour for the group, and a few hundred kilobytes a day, so nobody can make everyone post over and over or use up
    /// the relay's room for the mailbox).
    private func answerCatchUp(since: Date, from sender: Data, at i: Int) {
        let now = Date()
        let id = data.conversations[i].id
        // A request that sat in the mailbox is not answered later as if it were new, and its time must be sane.
        guard deposited.map({ now.timeIntervalSince($0) < 3600 }) ?? true,
              since <= now.addingTimeInterval(300), since > now.addingTimeInterval(-KeptPost.keepFor - 2 * 86_400),
              now.timeIntervalSince(catchUpAnswered[sender.hex] ?? .distantPast) > 3600,
              let shared = data.conversations[i].shared, !shared.gone, !shared.joining, let kept = shared.kept else { return }
        let recent = (catchUpWindow[id] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        guard recent.count < Self.catchUpAnswersPerHour else { return }
        let sentToday = (catchUpSent[id] ?? []).filter { now.timeIntervalSince($0.at) < 86_400 }
        var room = min(Self.catchUpBytesPerAnswer, Self.catchUpBytesPerDay - sentToday.reduce(0) { $0 + $1.bytes })
        // What the sender asked since (coarse, a day or so before they really were away), newest first until the room is
        // used, and nothing whose message has gone.
        let messages = Set(data.conversations[i].messages.map(\.id))
        var wanted: [KeptPost] = []
        for k in kept.reversed() where k.chat && k.at > since && (k.about.map(messages.contains) ?? true) {
            guard wanted.count < Self.catchUpMaxPosts, k.blob.count <= room else { continue }
            wanted.append(k)
            room -= k.blob.count
        }
        // Nothing to say again costs nothing and uses up no one's allowance.
        guard !wanted.isEmpty else { return }
        catchUpWindow[id] = recent + [now]
        catchUpAnswered[sender.hex] = now
        catchUpSent[id] = sentToday + [(now, wanted.reduce(0) { $0 + $1.blob.count })]
        // Each goes again as a new post on this device's chain, not as the same bytes: whoever asked was handed this chain
        // only from where it was when they first showed they held it (so a phone taken from them can't ask for what it
        // already read), and an old post from before that would never open for them. It goes in its own epoch's mailbox,
        // never a later one: a newcomer (who can ask too) holds no key of an epoch from before it was let in, so it reads
        // none of what was said then. Everyone else already has the message and ignores the copy by its id.
        for k in wanted.reversed() {
            guard data.conversations[i].shared?.epoch(k.epoch) != nil, let payload = ownPayload(of: k, at: i) else { continue }
            post(payload, at: i, message: nil, inEpoch: k.epoch, replay: true)
        }
        kick()
    }

    /// What one of this device's own kept posts said, opened again with the key its chain gave it.
    private func ownPayload(of k: KeptPost, at i: Int) -> Payload? {
        guard let shared = data.conversations[i].shared, let start = shared.chainStarts?[String(k.epoch)], k.index >= start.index,
              k.index - start.index <= GroupReader.maxSkip, let epoch = shared.epoch(k.epoch),
              let outer = try? GroupSeal.outer(k.blob, group: data.conversations[i].wireID, epoch: epoch), outer.index == k.index else { return nil }
        var chain = start
        while chain.index < k.index { chain = chain.step().next }
        guard let plain = GroupSeal.inner(outer, messageKey: chain.step().messageKey) else { return nil }
        return try? Payload.fromWire(plain)
    }

    /// Housekeeping for a group's kept posts: ones that are gone with their message or too old are let go, those the
    /// mailbox never gave back are posted again, and a device that was away asks for what it missed.
    private func tendKept(at i: Int) {
        // A group this device has left or been taken out of keeps nothing to post again.
        if data.conversations[i].shared?.gone == true, data.conversations[i].shared?.kept != nil {
            data.conversations[i].shared?.kept = nil
        }
        guard var shared = data.conversations[i].shared, !shared.gone, !shared.joining else { return }
        let now = Date()
        let id = data.conversations[i].id
        let gid = data.conversations[i].wireID
        if var kept = shared.kept, !kept.isEmpty {
            let messages = Set(data.conversations[i].messages.map(\.id))
            let readable = Set(shared.readable.map(\.number))
            kept.removeAll { k in
                now.timeIntervalSince(k.at) > (k.chat ? KeptPost.keepFor : KeptPost.housekeepingFor)
                    || (k.seen && !k.chat) || !readable.contains(k.epoch) || (k.about.map { !messages.contains($0) } ?? false)
            }
            for j in kept.indices where !kept[j].seen && kept[j].tries < KeptPost.maxTries {
                let k = kept[j]
                guard now.timeIntervalSince(k.lastTry) > KeptPost.gap(k.tries),
                      let read = groupFetchedAt["\(id)|\(k.epoch)"], read > k.lastTry.addingTimeInterval(5),
                      !shared.outbox.contains(where: { $0.keeps == k.id }) else { continue }
                shared.outbox.append(GroupOutgoing(sendID: k.sendID, days: k.days, blob: k.blob, message: nil, wake: false, ephemeral: false,
                                                   epoch: k.epoch, keeps: k.id))
            }
            shared.kept = kept
        }
        var ask: Date?
        if let since = shared.catchUpSince, shared.settings.kind == .group,
           now.timeIntervalSince(shared.catchUpAsked ?? .distantPast) > 3600 {
            shared.catchUpSince = nil
            shared.catchUpAsked = now
            // Only a day or two before this device was away, not the moment: members shouldn't learn when it last read.
            ask = Calendar(identifier: .gregorian).startOfDay(for: since).addingTimeInterval(-86_400)
        }
        data.conversations[i].shared = shared
        if let since = ask { post(.groupCatchUp(group: gid, since: since), at: i) }
        if !shared.outbox.isEmpty { kick() }
    }

    // MARK: Keeping groups in order

    /// Housekeeping for shared groups: removals that didn't stick are done again, unanswered invites run out, reading
    /// state for epochs no longer read is let go, and this device's picture is posted where members haven't got it.
    func tendSharedGroups() {
        let now = Date()
        tendGroupSecret()
        for i in data.conversations.indices {
            // Before the copy of the group below is taken: this changes it.
            tendKept(at: i)
            guard var shared = data.conversations[i].shared, !shared.gone,
                  let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID) else { continue }
            if let oldest = shared.readable.first?.number, shared.reader.chains.keys.contains(where: { (Int($0.split(separator: "|").first ?? "") ?? 0) < oldest }) {
                shared.reader.drop(before: oldest)
                data.conversations[i].shared = shared
            }
            // Keys of epochs no longer read are erased, with this device's sending chains in them: kept, they would let
            // whoever later took this device open that group's old mail from a copy of the relay's traffic.
            // (Number 0 is a channel's staff mailbox, which is never among the epochs: its chain stays.)
            let stillRead = Set(shared.readable.map(\.number)).union([0])
            if shared.epochs.contains(where: { !stillRead.contains($0.number) })
                || shared.chains.keys.contains(where: { !stillRead.contains(Int($0) ?? -1) }) {
                shared.epochs.removeAll { !stillRead.contains($0.number) }
                shared.chains = shared.chains.filter { stillRead.contains(Int($0.key) ?? -1) }
                data.conversations[i].shared?.epochs = shared.epochs
                data.conversations[i].shared?.chains = shared.chains
            }
            // Where this device's chains began goes with the epochs no longer read; sessions with devices of people no
            // longer in go too, and posts still waiting for a chain are asked for again.
            if let starts = shared.chainStarts, starts.keys.contains(where: { !stillRead.contains(Int($0) ?? -1) }) {
                data.conversations[i].shared?.chainStarts = starts.filter { stillRead.contains(Int($0.key) ?? -1) }
            }
            tendPeers(at: i)
            expireHeldMail(at: i)
            askForHeldChains(at: i)
            let readableBoxes = Set(shared.readable.map { $0.sendID.hex })
            if !shared.postedTo.isSubset(of: readableBoxes) {
                shared.postedTo.formIntersection(readableBoxes)
                data.conversations[i].shared?.postedTo = shared.postedTo
            }
            let staff = shared.settings.isAdmin(keys.publicKey) || shared.settings.mods.contains(keys.publicKey)
            // An epoch's key opens everything said in it, and is kept for a week after the next one begins. So an admin's
            // device starts a new epoch, with everyone still in, once the current one is old or long and something was
            // said in it. Quiet groups keep theirs. Two admins doing it together settle like two removals.
            if shared.settings.isAdmin(keys.publicKey), shared.chatInEpoch, !shared.joining, let current = shared.current,
               shared.settings.epoch == current.number, shared.wantRemoved.isEmpty, shared.rekeyAfter == nil,
               now.timeIntervalSince(current.started) >= Self.epochMaxAge || (shared.chatsInEpoch ?? 0) >= Self.epochMaxChats,
               now.timeIntervalSince(shared.rotationTried ?? .distantPast) > Self.rotationRetry {
                data.conversations[i].shared?.rotationTried = now
                startEpoch(at: i, without: [])
                continue
            }
            // Taken out by this device, but a competing change won and they're back in: done again. Watched for a while
            // after it seemed to work, since the competing change can arrive later.
            let settled = shared.wantRemoved.filter { key, at in
                !shared.settings.members.contains { $0.signingKey.hex == key } && now.timeIntervalSince(at) > 600
            }
            for key in settled.keys { shared.wantRemoved[key] = nil }
            data.conversations[i].shared?.wantRemoved = shared.wantRemoved
            let id = data.conversations[i].id
            let tries = groupRetries[id] ?? 0
            // Backs off to every ten minutes, and keeps going until the removal sticks.
            // Everyone still to go that this device's role lets it take out goes in one new epoch.
            func mayGo(_ key: Data) -> Bool {
                let s = shared.settings
                return s.isAdmin(key) ? s.owner == keys.publicKey : !s.mods.contains(key) || s.isAdmin(keys.publicKey)
            }
            let targets = shared.settings.members.map(\.signingKey).filter { shared.wantRemoved[$0.hex] != nil && mayGo($0) }
            if staff, !targets.isEmpty,
               now.timeIntervalSince(lastGroupRetry[id] ?? .distantPast) > min(600, 5 * pow(2, Double(min(tries, 10)))) {
                lastGroupRetry[id] = now
                groupRetries[id] = tries + 1
                startEpoch(at: i, without: Set(targets))
                continue
            }
            if shared.wantRemoved.isEmpty { groupRetries[id] = nil }
            // A follower taken out whose new key didn't get made (settings it couldn't make yet, say): tried again until it is.
            if staff, let after = shared.rekeyAfter {
                if shared.settings.epoch > after {
                    data.conversations[i].shared?.rekeyAfter = nil
                    data.conversations[i].shared?.rekeyDue = nil
                } else if let due = shared.rekeyDue {
                    // Followers who left: one new epoch for all of them once the window is over.
                    if now >= due {
                        data.conversations[i].shared?.rekeyDue = nil
                        data.conversations[i].shared?.rekeyTried = now
                        startEpoch(at: i, without: [])
                    }
                } else if now.timeIntervalSince(shared.rekeyTried ?? .distantPast) > Self.rekeyRetry {
                    data.conversations[i].shared?.rekeyTried = now
                    startEpoch(at: i, without: [])
                }
            }
            // People who followed through the channel's code while its hourly limit was reached are let in as room comes.
            if staff, shared.settings.kind == .channel, let waiting = shared.joinWaiting, !waiting.isEmpty {
                admitFromCode([], at: i)
            }
            // Asks to join the staff that nobody answered run out, like invites.
            if let asks = shared.staffInvited, asks.contains(where: { now.timeIntervalSince($0.value) > Self.inviteLife }) {
                data.conversations[i].shared?.staffInvited = asks.filter { now.timeIntervalSince($0.value) <= Self.inviteLife }
            }
            // The owner's phone puts the follower roster in the staff mailbox again every few days (the relay keeps mail a
            // week) and whenever the admins change.
            if shared.settings.kind == .channel, shared.settings.owner == keys.publicKey, shared.roster != nil,
               now.timeIntervalSince1970 - Double(shared.rosterEpoch ?? 0) > 3 * 86_400
                || shared.rosterStaff != shared.settings.members.filter({ shared.settings.isAdmin($0.signingKey) }).map(\.signingKey).sorted(by: { $0.hex < $1.hex }) {
                publishRoster(at: i)
            }
            // Settings name a key this device never got: ask for it again, on the key it has, every ten minutes.
            if let pending = shared.pendingSettings, pending.isMember(keys.publicKey), pending.epoch > (shared.current?.number ?? 0),
               now.timeIntervalSince(shared.keyAskedAt ?? .distantPast) > 600, !shared.joining {
                data.conversations[i].shared?.keyAskedAt = now
                post(.groupKeyWanted(group: data.conversations[i].wireID, epoch: pending.epoch), at: i)
            }
            // A new key never came: the admin who invited this account is asked too, over the 1:1 chat with them
            // (post-quantum, and still there after the group's old mailbox has gone).
            if shared.settings.kind == .group, shared.missedKey, !shared.joining {
                askInviterForKey(at: i)
            }
            for (fp, at) in shared.invited where now.timeIntervalSince(at) > Self.inviteLife {
                cancelInvite(fp, in: data.conversations[i].id)
            }
            // Once in, and in each new epoch while the group is small, this device posts its card with its picture, so
            // members (and newcomers) can show it. In a big group only when the picture changes.
            if !shared.joining, let current = shared.current?.number, shared.cardPostedEpoch != current,
               let card = myCard(data.conversations[i].persona, group: data.conversations[i].wireID), card.avatar != nil,
               shared.cardPostedEpoch == nil || shared.settings.members.count <= 300 {
                data.conversations[i].shared?.cardPostedEpoch = current
                post(.memberCard(card), at: i)
            }
        }
    }

    // MARK: Reading

    /// One envelope from a group's mailbox. Its number moves the cursor whatever is in it, so nothing is read twice: one
    /// at or below the cursor (the relay handing an old one out again) is dropped, unless it is held mail read again.
    func receiveGroupMail(_ mail: RelayClient.GroupMail, convo id: UUID, epoch number: Int, rereading: Bool = false) {
        guard let i = index(of: id), var shared = data.conversations[i].shared, !shared.gone,
              let epoch = shared.epoch(number) else { return }
        let key = String(number)
        if !rereading, let cursor = shared.cursors[key], mail.seq <= cursor { return }
        if mail.seq > shared.cursors[key] ?? 0 { shared.cursors[key] = mail.seq }
        data.conversations[i].shared = shared
        let persona = data.conversations[i].persona
        let gid = data.conversations[i].wireID
        guard let keys = memberKeys(persona, group: gid),
              let outer = try? GroupSeal.outer(mail.blob, group: gid, epoch: epoch) else { return }
        // Our own from this device: nothing to do. From another device of ours, only the group's housekeeping (the
        // messages themselves reach this device as its own through sync).
        let ours = outer.sender == keys.publicKey
        if ours, outer.device == shared.myTag {
            // Read back from the mailbox: the relay has it for everyone, so there's nothing to post again.
            if let j = data.conversations[i].shared?.kept?.firstIndex(where: { $0.epoch == number && $0.index == outer.index }) {
                data.conversations[i].shared?.kept?[j].seen = true
            }
            return
        }
        // From a key whose place this device saw moved: a late copy of another move of that place is what's looked for.
        if !shared.settings.isMember(outer.sender), outer.isDirect, shared.renewals?.contains(where: { $0.old == outer.sender }) == true {
            data.conversations[i].shared = shared
            if outer.inner.count <= GroupSeal.maxPadded, case let .groupSettings(next)? = try? Payload.fromWire(outer.inner),
               next.signer == outer.sender { checkMovedPlace(next, at: i) }
            return
        }
        // Keys two devices fought over: nothing they post is read until an admin adds them again.
        if shared.disputed?.contains(outer.sender) == true {
            data.conversations[i].shared = shared
            return
        }
        // The staff mailbox carries rosters and nothing else, and rosters are read nowhere else.
        if number == 0 {
            guard shared.settings.isAdmin(outer.sender) || ours else { return }
        } else if !shared.settings.isMember(outer.sender) && !ours && shared.settings.kind == .channel {
            // A channel's followers hold its key but may say nothing in it: whatever is posted by anyone else is dropped,
            // not kept (anyone following could fill a phone with it).
            return
        }
        if !shared.settings.isMember(outer.sender) && !ours {
            // Not listed yet: the settings that add them may still be on the way. Kept for a while, and read again then.
            hold(mail, epoch: number, from: outer.sender, device: outer.device, chain: false, in: &shared)
            data.conversations[i].shared = shared
            return
        }
        // A direct post: items for single devices, each sealed by its pairwise session, or the group's own settings and new
        // keys (see `Payload.goesWithoutChain`). Needs no chain.
        var unchained: Payload?
        if outer.isDirect {
            data.conversations[i].shared = shared
            guard outer.inner.count <= GroupSeal.maxPadded, let payload = try? Payload.fromWire(outer.inner) else { return }
            if case let .groupDirect(items) = payload {
                receiveDirect(items, from: outer.sender, device: outer.device, deposited: mail.deposited, epoch: number, at: i)
                return
            }
            guard payload.goesWithoutChain, number != 0 else { return }
            unchained = payload
        }
        let messageKey: Data
        switch unchained != nil ? GroupReader.Lookup.key(Data()) : shared.reader.messageKey(epoch: number, sender: outer.sender, device: outer.device, index: outer.index) {
        case .used:
            data.conversations[i].shared = shared
            return
        case .missing:
            // Where this sender device's chain is hasn't come yet (or not from this far back): kept, and the device that
            // posted it is asked over the pairwise session with it (a channel's follower asks the staff member who invited it),
            // all the asks from one fetch in one direct post. Only for a device this one could still follow: a member who
            // makes up device tags gets nothing held, and nothing asked.
            guard mayHold(epoch: number, sender: outer.sender, device: outer.device, in: shared) else {
                data.conversations[i].shared = shared
                return
            }
            hold(mail, epoch: number, from: outer.sender, device: outer.device, chain: true, in: &shared)
            data.conversations[i].shared = shared
            chainAsksDue.insert(id)
            return
        case let .key(key):
            messageKey = key
        }
        let inner = unchained == nil ? GroupSeal.inner(outer, messageKey: messageKey) : nil
        if unchained == nil {
            if inner == nil, shared.reader.dropUnproven(epoch: number, sender: outer.sender, device: outer.device) {
                // The chain it was read with was passed on and isn't this device's: dropped, the post held, and the
                // chain asked for again.
                hold(mail, epoch: number, from: outer.sender, device: outer.device, chain: true, in: &shared)
                data.conversations[i].shared = shared
                chainAsksDue.insert(id)
                return
            }
            if inner != nil { shared.reader.proved(epoch: number, sender: outer.sender, device: outer.device) }
        }
        guard let payload = unchained ?? inner.flatMap({ try? Payload.fromWire($0) }) else {
            data.conversations[i].shared = shared
            return
        }
        // Settings and new keys only ever come without a chain: one sealed on a chain isn't taken.
        if unchained == nil, payload.goesWithoutChain { data.conversations[i].shared = shared; return }
        if number == 0 {
            guard case .groupRoster = payload else { return }
        }
        if payload.isChat, number == shared.current?.number {
            shared.chatInEpoch = true
            shared.chatsInEpoch = (shared.chatsInEpoch ?? 0) + 1
        }
        data.conversations[i].shared = shared
        let fp = Identity.fingerprint(of: outer.sender)
        deposited = mail.deposited
        defer { deposited = nil }
        switch payload {
        case let .groupSettings(next):
            guard next.signer == outer.sender else { return }
            adoptSettings(next, at: i)
        case let .groupRekey(rekey):
            // Kept as a candidate; the settings that follow say which key the group moves to.
            guard rekey.group == gid, groupNumberRange.contains(rekey.epoch), (1...7).contains(rekey.days),
                  shared.settings.isMember(outer.sender),
                  rekey.epoch > (shared.current?.number ?? 0) - 1,
                  var opened = rekey.open(with: keys) ?? renewedKeys(at: i).flatMap({ rekey.open(with: $0) }),
                  !shared.candidates.contains(where: { $0.key == opened.key }) else { return }
            opened.from = outer.sender
            // Two at most from each member, sixteen in all: nobody can push out someone else's.
            var candidates = shared.candidates
            let theirs = candidates.filter { $0.from == outer.sender }
            if theirs.count >= 2, let oldest = theirs.first { candidates.removeAll { $0.key == oldest.key } }
            candidates.append(opened)
            if candidates.count > 16 { candidates.removeFirst(candidates.count - 16) }
            data.conversations[i].shared?.candidates = candidates
            // Settings naming it may have come first (a competing change read out of order).
            if let pending = data.conversations[i].shared?.pendingSettings { adoptSettings(pending, at: i) }
        case let .memberCard(card):
            guard !ours, card.signingKey == outer.sender, let avatar = card.avatar else { return }
            noteAvatar(avatar, of: card, at: i)
        case let .groupLinks(links):
            adoptLinks(links, from: outer.sender, at: i)
        case let .groupRoster(roster):
            // Only staff can open it, and only staff may have made it.
            guard number == 0, roster.group == gid, shared.settings.kind == .channel, roster.signer == outer.sender, roster.signatureIsValid,
                  shared.settings.isAdmin(outer.sender), shared.settings.isAdmin(keys.publicKey),
                  let body = roster.open(with: keys) else { return }
            adoptRoster(body, at: i)
        case let .friendAsk(to, sealed):
            guard !ours, to == keys.publicKey, sealed.count <= 64 * 1024,
                  let header = try? EnvelopeCore.open(sealed, agreement: keys.agreement), header.signer == outer.sender,
                  let body = try? JSONDecoder.pulshade.decode(FriendInviteBody.self, from: header.body) else { return }
            noteFriendInvite(body, from: fp, persona: persona, group: id)
        case let .membersAdded(names):
            // Not shown to someone still joining: it's about them, or from before they were in.
            guard !ours, !shared.joining, shared.settings.isAdmin(outer.sender), (1...50).contains(names.count) else { return }
            // Not shown to the one it's about: a newcomer can read its own epoch from the start, this notice included.
            if let myName = shared.settings.card(keys.publicKey)?.name, !myName.isEmpty, names.contains(myName) { return }
            let clean = names.prefix(50).map { String($0.prefix(40)) }.filter { !$0.isEmpty }
            guard !clean.isEmpty else { return }
            let who = contact(fp, in: persona)?.displayName ?? "An admin"
            withAnimation(.snappy) {
                data.conversations[i].messages.append(Message(sender: "system", text: "\(who) added \(Self.list(clean))", date: deposited ?? Date()))
            }
        case let .groupKeyWanted(group, wanted):
            // A member never got the current key: an admin's phone sends it again, sealed to them alone, in the mailbox
            // they asked from. Once per member every ten minutes.
            guard !ours, group == gid, wanted == shared.settings.epoch, shared.settings.isAdmin(keys.publicKey),
                  let card = shared.settings.card(outer.sender), let current = shared.current, current.number == wanted,
                  Date().timeIntervalSince(keyResent[outer.sender.hex] ?? .distantPast) > 600 else { return }
            keyResent[outer.sender.hex] = Date()
            post(.groupRekey(GroupRekey.make(current, group: gid, for: [card])), at: i, inEpoch: number)
            post(.groupSettings(shared.settings), at: i, inEpoch: number)
        case let .groupCatchUp(group, since):
            // A member was away longer than the relay keeps mail: this device posts again what it said since, if it still has it.
            guard !ours, group == gid, shared.settings.kind == .group, shared.settings.isMember(outer.sender) else { return }
            answerCatchUp(since: since, from: outer.sender, at: i)
        case let .left(conversation):
            guard !ours, conversation == gid else { return }
            // The owner's device takes them out for everyone, with a new epoch. Only the owner's, so two admins don't
            // each start a different one (and if two of the owner's devices both do, the settings settle it).
            if shared.settings.owner == keys.publicKey { removeSharedMember(fp, at: i) }
        case let .chatDeleted(conversation):
            guard conversation == gid, outer.sender == shared.settings.owner else { return }
            removeLocally(id)
        case let .message(wire):
            guard !ours, wire.conversation == gid, let sender = contact(fp, in: persona) else { return }
            deliver(wire, from: sender)
        case let .typing(conversation):
            // Group mail stays for days: typing read long after it was posted (coming back to a group) means nothing.
            guard !ours, conversation == gid, Self.isFreshSignal(deposited: mail.deposited) else { return }
            handle(payload, from: fp, persona: persona, device: outer.device)
        case .reaction, .unsend, .clipBlob:
            guard !ours else { return }
            handle(payload, from: fp, persona: persona, device: outer.device)
        default:
            // Nothing else is said in a group's mailbox.
            break
        }
    }

    /// Keeps a post to read again later (its sender isn't listed yet, or its chain can't be started yet): for eight days at
    /// most, a hundred posts and a few megabytes. Past that, the oldest of whoever has the most held goes, so one member
    /// can't push out everyone else's.
    private func hold(_ mail: RelayClient.GroupMail, epoch number: Int, from sender: Data, device: Data, chain: Bool,
                      in shared: inout SharedGroup) {
        // What is past its eight days goes in `expireHeldMail`, which says so.
        var held = (shared.heldMail ?? []).filter { $0.seq != mail.seq || $0.epoch != number }
        held.append(HeldGroupMail(epoch: number, seq: mail.seq, blob: mail.blob, at: mail.deposited ?? Date(), from: sender,
                                  device: device, chain: chain ? true : nil))
        func size() -> Int { held.reduce(0) { $0 + $1.blob.count } }
        while held.count > HeldGroupMail.max || (held.count > 1 && size() > HeldGroupMail.maxBytes) {
            let counts = Dictionary(grouping: held.indices, by: { held[$0].from ?? Data() })
            guard let most = counts.max(by: { ($0.value.count, $1.key.hex) < ($1.value.count, $0.key.hex) }),
                  let oldest = most.value.min(by: { held[$0].at < held[$1].at }) else { break }
            held.remove(at: oldest)
        }
        shared.heldMail = held
    }

    /// Whether a post from this sender device may be held for want of its chain: its chain is followed already, or this
    /// device could still start following it (at most `GroupReader.maxDevicesPerSender` devices of one member in an epoch,
    /// counting those whose posts are held, and `maxChainsPerEpoch` in all).
    private func mayHold(epoch number: Int, sender: Data, device: Data, in shared: SharedGroup) -> Bool {
        if shared.reader.follows(epoch: number, sender: sender, device: device) { return true }
        let prefix = "\(number)|\(sender.hex)|"
        let followed = Set(shared.reader.chains.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        let waiting = Set((shared.heldMail ?? []).filter { $0.epoch == number && $0.from == sender && $0.chain == true }
            .compactMap { $0.device?.hex }).subtracting(followed)
        guard followed.count + waiting.union([device.hex]).count <= GroupReader.maxDevicesPerSender else { return false }
        return shared.reader.chains.keys.count(where: { $0.hasPrefix("\(number)|") }) < GroupReader.maxChainsPerEpoch
    }

    /// Posts held back because their sender wasn't listed yet, read again now that the settings have moved on. Any
    /// whose sender still isn't listed go back to waiting.
    private func rereadHeldMail(at i: Int) {
        guard let held = data.conversations[i].shared?.heldMail, !held.isEmpty else { return }
        let id = data.conversations[i].id
        data.conversations[i].shared?.heldMail = []
        for item in held {
            receiveGroupMail(RelayClient.GroupMail(receiveKey: Data(), seq: item.seq, blob: item.blob, deposited: item.at),
                             convo: id, epoch: item.epoch, rereading: true)
        }
    }

    /// Held mail past its eight days goes; if any of it was waiting for a chain, the chat says some posts couldn't be
    /// opened (their sender's device never answered), once each time.
    private func expireHeldMail(at i: Int) {
        guard let held = data.conversations[i].shared?.heldMail, !held.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-8 * 86_400)
        let expired = held.filter { $0.at <= cutoff }
        guard !expired.isEmpty else { return }
        data.conversations[i].shared?.heldMail = held.filter { $0.at > cutoff }
        if expired.contains(where: { $0.chain == true }) {
            withAnimation(.snappy) {
                data.conversations[i].messages.append(Message(sender: "system", text: "Some posts couldn't be opened: the phone that sent them never handed over their keys",
                                                              date: Date()))
            }
        }
    }

    /// A version of a group's settings. Taken if it is the next one and its signer may make it; a later one the owner
    /// signed (to catch up after missing some); or a competing one with the same number that wins the tie-break (two
    /// admins changed the group at once: everyone keeps the same one). An epoch it moves to is used only if its key
    /// matches the check the settings carry.
    private func adoptSettings(_ next: GroupSettings, at i: Int) {
        guard var shared = data.conversations[i].shared, var keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID) else { return }
        // Another of this account's devices may have moved the group to keys made with the current group secret.
        let renewed = renewedKeys(at: i)
        func listed(_ s: GroupSettings) -> Bool { s.isMember(keys.publicKey) || renewed.map { s.isMember($0.publicKey) } == true }
        let held = shared.settings
        // Nothing a key two devices fought over signs is taken (`disputeRenewal`).
        if shared.disputed?.contains(next.signer) == true { return }
        let competing = next.version == held.version && next != held
        if competing {
            guard let previous = shared.previous, previous.accepts(next) || previous.acceptsJump(next) else { return }
            switch next.contest(held, base: previous) {
            case .wins: break
            case .loses: return
            case let .dispute(old, disputed):
                disputeRenewal(old: old, keys: disputed, at: i)
                return
            }
        } else {
            guard next.version > held.version else {
                checkMovedPlace(next, at: i)
                return
            }
            guard held.accepts(next) || held.acceptsJump(next) else { return }
        }
        let base = competing ? shared.previous : held
        // This device's own move to new keys lost to a change made at the same moment: back to the keys the group still
        // lists, and moved again later (`tendGroupSecret`).
        if let from = shared.renewing, let me = me(data.conversations[i].persona), !next.isMember(keys.publicKey) {
            let before = GroupMemberKeys(seed: me.seed, group: data.conversations[i].wireID, secret: from)
            if next.isMember(before.publicKey) {
                shared.memberSecret = from
                shared.renewing = nil
                shared.peers = nil
                shared.chainAsked = nil
                keys = before
            }
        }
        // This account's own place moved to keys this device can't make (yet): another of its devices may have moved it
        // with a group secret that hasn't reached this one, or a device holding the account's old keys (one taken, or
        // unlinked) did. Held, and settled in `tendGroupSecret`.
        if let (old, new) = base?.renewal(to: next), old == keys.publicKey, new != renewed?.publicKey {
            if shared.foreignMove?.version != next.version {
                shared.foreignMove = next
                shared.foreignMoveAt = Date()
            }
            data.conversations[i].shared = shared
            return
        }
        // The epoch it names: held already, or a candidate whose check matches.
        if shared.epoch(next.epoch)?.check != next.epochCheck {
            guard let key = shared.candidates.first(where: { $0.number == next.epoch && $0.check == next.epochCheck }) else {
                // Not being listed means being removed in a group, but a channel's followers are never listed: for them a key
                // that doesn't come is all there is to go on.
                if !listed(next) && next.kind != .channel {
                    leftShared(at: i, note: "You were removed from this group")
                } else if next.epoch > (shared.current?.number ?? 0) {
                    // Its key may still be on the way (read out of order): wait for it. If it never comes, this device
                    // missed it and needs adding again.
                    shared.pendingSettings = next
                    shared.missedKey = shared.candidates.allSatisfy { $0.number != next.epoch }
                    data.conversations[i].shared = shared
                }
                return
            }
            install(key, in: &shared)
        }
        if !competing { shared.previous = held }
        if let base { shared.noteAdded(from: base, to: next) }
        shared.settings = next
        if let renewed, next.isMember(renewed.publicKey) {
            // The sessions were opened under the old keys: new ones are opened under the new.
            shared.memberSecret = nil
            shared.peers = nil
            shared.chainAsked = nil
            keys = renewed
        }
        // A member who moved to new keys is known by them from now on.
        if let (old, new) = base?.renewal(to: next) {
            shared.renewals = Array(((shared.renewals ?? []) + [RenewalMark(old: old, new: new, version: next.version)]).suffix(RenewalMark.kept))
            let oldFP = Identity.fingerprint(of: old), newFP = Identity.fingerprint(of: new)
            for (account, fp) in shared.knownAs where fp == oldFP { shared.knownAs[account] = newFP }
            if let at = shared.wantRemoved[old.hex] {
                shared.wantRemoved[old.hex] = nil
                shared.wantRemoved[new.hex] = at
            }
        }
        // Epochs past the one these settings name (from a change that lost) go back to being candidates.
        let later = shared.epochs.filter { $0.number > next.epoch }
        if !later.isEmpty {
            shared.epochs.removeAll { $0.number > next.epoch }
            shared.candidates += later.filter { e in !shared.candidates.contains { $0.key == e.key } }
            // Nothing made with those keys is used again: a later key under the same number starts afresh.
            for e in later {
                shared.chains[String(e.number)] = nil
                shared.chainStarts?[String(e.number)] = nil
                shared.cursors[String(e.number)] = nil
                shared.reader.forget(epoch: e.number)
            }
        }
        shared.pendingSettings = nil
        shared.missedKey = false
        // Someone an admin added anew is no longer held back by a dispute over their keys.
        shared.disputed?.removeAll { next.isMember($0) && !held.isMember($0) }
        if shared.renewing != nil, next.version > held.version, !competing, next.isMember(keys.publicKey) { shared.renewing = nil }
        data.conversations[i].shared = shared
        if !next.isMember(keys.publicKey) && !shared.joining && next.kind != .channel {
            // This account's own keys moved to keys this device can't make: another device holding them did it.
            if let (old, _) = base?.renewal(to: next), old == keys.publicKey {
                leftShared(at: i, note: "Another device signed in to your account moved your place in this group to keys this one can't make. "
                           + "If it isn't one of yours, unlink it in Devices.")
            } else {
                leftShared(at: i, note: "You were removed from this group")
            }
            return
        }
        applySharedSettings(at: i)
        rereadHeldMail(at: i)
        // The owner's device signs every change someone else made over again, so a member who missed versions can
        // catch up on the newest (only owner-signed versions may skip).
        if next.owner == keys.publicKey, next.signer != keys.publicKey { publishSettings(next, at: i) }
    }

    /// A version from a key whose place this device already saw moved (`SharedGroup.renewals`), arriving after the group
    /// moved on: if it gives that place to another key than the one taken, two devices hold that old key.
    private func checkMovedPlace(_ next: GroupSettings, at i: Int) {
        guard let shared = data.conversations[i].shared,
              let mark = shared.renewals?.last(where: { $0.old == next.signer && $0.version == next.version }),
              let taker = next.movesPlace(of: mark.old, at: mark.version, otherThan: mark.new, from: shared.settings) else { return }
        disputeRenewal(old: mark.old, keys: [mark.old, mark.new] + (taker.isEmpty ? [] : [taker]), at: i)
    }

    /// Two devices hold one member's old group keys, and each moved the place to keys of its own: one of them is likely
    /// a device their account unlinked, and nobody else can tell which. Neither is taken: nothing either key signs or
    /// posts is read from now on, and the place is cleared. An admin's phone takes whichever key the settings hold out
    /// (with a new epoch), so the account comes back only when an admin adds them again over a 1:1 chat. If the place is
    /// the owner's, nobody can take it out, so the group can't go on safely and is closed on this device. If it is this
    /// account's own place, this device leaves too, and asks to be added again.
    ///
    /// Whatever the claimed keys did before the dispute came to light goes with them: everyone a version they signed
    /// brought in (and whoever those brought in, and any keys any of them moved to since) is held back the same way, and
    /// an admin's phone takes them out in the same new epoch (`SharedGroup.broughtIn`).
    private func disputeRenewal(old: Data, keys disputed: [Data], at i: Int) {
        guard var shared = data.conversations[i].shared, !shared.gone,
              let mine = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID) else { return }
        let suspects = shared.broughtIn(under: disputed.filter { $0 != old })
        let named = disputed + suspects.filter { !disputed.contains($0) }.sorted { $0.hex < $1.hex }
        let fresh = named.filter { !$0.isEmpty && !(shared.disputed ?? []).contains($0) }
        guard !fresh.isEmpty else { return }
        shared.disputed = Array(((shared.disputed ?? []) + fresh).suffix(GroupSettings.maxMembers + 3 * RenewalMark.kept))
        data.conversations[i].shared = shared
        let s = shared.settings
        // Whoever holds the claimed place now (the key it was moved to, or one that key moved to since).
        let holder = disputed.map(shared.holder(of:)).first { s.isMember($0) }
        // Members the claimed keys brought in, oldest card first.
        let brought = s.members.map(\.signingKey).filter { suspects.contains($0) && $0 != holder }
        let renewed = renewedKeys(at: i)?.publicKey
        if disputed.contains(mine.publicKey) || renewed.map(disputed.contains) == true {
            leftShared(at: i, note: "A device you unlinked tried to keep your place in this group, so the members can't tell which is you. "
                       + "Ask an admin to add you again.")
            save()
            return
        }
        if suspects.contains(mine.publicKey) || renewed.map(suspects.contains) == true {
            leftShared(at: i, note: "You were added to this group under keys two devices fought over, so the members no longer read you. "
                       + "Ask an admin to add you again.")
            save()
            return
        }
        if holder == s.owner || brought.contains(s.owner) {
            leftShared(at: i, note: "Two devices each claimed the owner's place in this group (one of the owner's devices was likely taken), "
                       + "so it can't go on safely. Ask the owner to start a new one.")
            save()
            return
        }
        let name = holder.flatMap { s.card($0)?.name }.flatMap { $0.isEmpty ? nil : $0 } ?? "A member"
        func mayRemove(_ key: Data) -> Bool { s.isAdmin(mine.publicKey) && (!s.isAdmin(key) || s.owner == mine.publicKey) }
        let canRemove = holder.map(mayRemove) ?? false
        let knows = holder.map { h in shared.knownAs.values.contains(Identity.fingerprint(of: h)) || shared.knownAs.values.contains(Identity.fingerprint(of: old)) } ?? false
        let names = brought.map { s.card($0)?.name ?? "" }.map { $0.isEmpty ? "someone" : $0 }
        let alsoHeld = brought.isEmpty ? "" : ", nor from \(Self.list(names)), added under the claimed keys,"
        withAnimation(.snappy) {
            data.conversations[i].messages.append(Message(
                sender: "system",
                text: "Two devices each claimed \(name)'s place in this group (one of their devices was likely taken). Nothing from either is shown"
                    + alsoHeld + " until an admin adds them again" + (canRemove && knows ? ": add them again from your chat with them." : "."),
                date: Date()))
        }
        // The claimed place and everyone brought in under it go in one new epoch. An admin takes out ordinary members; an
        // admin brought in (made one by the owner since) only the owner can.
        let removing = ((holder.map { [$0] } ?? []) + brought).filter(mayRemove)
        if !removing.isEmpty {
            for key in removing { data.conversations[i].shared?.wantRemoved[key.hex] = Date() }
            startEpoch(at: i, without: Set(removing))
        }
        save()
    }

    /// This device is out of a shared group: it stops reading and posting, and keeps the history.
    private func leftShared(at i: Int, note: String) {
        data.conversations[i].shared?.gone = true
        data.conversations[i].shared?.outbox = []
        data.conversations[i].shared?.kept = nil
        data.conversations[i].shared?.catchUpSince = nil
        // Nothing more is read: the group's keys and this device's chains go, so a later look at this device can't open
        // the group's old mail from a copy of the relay's traffic.
        data.conversations[i].shared?.epochs = []
        data.conversations[i].shared?.chains = [:]
        data.conversations[i].shared?.chainStarts = nil
        data.conversations[i].shared?.peers = nil
        data.conversations[i].shared?.followerWants = nil
        data.conversations[i].shared?.candidates = []
        data.conversations[i].shared?.reader = GroupReader()
        data.conversations[i].members = []
        withAnimation(.snappy) { data.conversations[i].messages.append(Message(sender: "system", text: note, date: Date())) }
    }
}

// MARK: - Chains handed over pairwise sessions

/// Where each sender device's chain starts reaches every other member device over a pairwise session (`GroupPeer`),
/// never in the posts themselves (see docs/groups-design.md, section 21). A device hands its chain over when it first posts
/// in an epoch (to every device it has a session with), when a session opens (where it is now), and whenever a device asks
/// for a post it holds and can't open. Sessions are opened on demand, by whoever needs one, in the group's own mailbox, and
/// make no friends and show no chat. A channel's followers never post: the staff member who invited each one passes the
/// chains on over their 1:1 chat.
extension AppModel {
    /// How far a chain is stepped to answer an ask (an epoch is a few hundred posts at most from one device).
    static let maxChainSteps: UInt32 = 20_000

    /// This device's chain in `epoch` at message `index` (no earlier than where it began, no later than where it is), to
    /// hand to a device. Where it may be handed from is up to the caller (`handOverFrom`, `followerFloor`).
    private func myChain(epoch: Int, from index: UInt32, at i: Int) -> GroupChainKey? {
        guard let shared = data.conversations[i].shared, let tag = shared.myTag,
              let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              let start = shared.chainStarts?[String(epoch)], let now = shared.chains[String(epoch)] else { return nil }
        let target = min(max(index, start.index), now.index)
        guard target - start.index <= Self.maxChainSteps else { return nil }
        var chain = start
        while chain.index < target { chain = chain.step().next }
        return GroupChainKey(epoch: epoch, sender: keys.publicKey, device: tag, index: chain.index, key: chain.key)
    }

    /// The same chain moved on to `index` (never back).
    private static func stepped(_ k: GroupChainKey, to index: UInt32) -> GroupChainKey? {
        guard index > k.index else { return k }
        guard index - k.index <= maxChainSteps else { return nil }
        var chain = k.chain
        while chain.index < index { chain = chain.step().next }
        return GroupChainKey(epoch: k.epoch, sender: k.sender, device: k.device, index: chain.index, key: chain.key)
    }

    /// Whether a member device may be handed chains here and talk pairwise: a member of a group; in a channel, staff.
    private func mayPair(_ member: Data, in shared: SharedGroup) -> Bool {
        shared.settings.kind == .channel ? shared.settings.isAdmin(member) : shared.settings.isMember(member)
    }

    /// Whether this device may open sessions with other members and ask them for their chains. A group's newcomer may
    /// while still joining, so it has the chains of what is said in the meantime once the settings that list it come. That
    /// gives nothing away: whoever is asked hands chains only to members its own settings list.
    private func mayPairAsMe(_ me: Data, in shared: SharedGroup) -> Bool {
        mayPair(me, in: shared) || (shared.joining && shared.settings.kind == .group)
    }

    /// Where this device's chain in `epoch` may be handed to `peer` from, when it asks for `index`: never before the
    /// peer's floor. A device met for the first time starts where the chain is now if another device of the same member
    /// has been handed it already (one made up by whoever took a member's phone reads nothing said before); if none has, no
    /// device of that member could read any of it, and the ask is answered as made. A member's genuinely linked devices
    /// pass what they are handed to each other (`SyncEvent.groupChains`), so floors hold against a phone once it is
    /// unlinked and the group keys renewed, not while it is still linked.
    private func handOverFrom(_ index: UInt32, epoch: Int, to peer: GroupPeer, at i: Int) -> UInt32? {
        guard let shared = data.conversations[i].shared, let now = shared.chains[String(epoch)] else { return nil }
        let n = String(epoch)
        if let floor = peer.floor?[n] { return max(index, floor) }
        let id = GroupPeer.id(member: peer.member, device: peer.device)
        let another = (shared.peers ?? [:]).contains { $0.key != id && $0.value.member == peer.member && $0.value.floor?[n] != nil }
        return another ? max(index, now.index) : index
    }

    /// Chain positions handed to a peer: the lowest is its floor in that epoch (if it has none yet), and each waits for the
    /// peer to show it got it.
    private static func noteHanded(_ keys: [GroupChainKey], to peer: inout GroupPeer) {
        guard !keys.isEmpty else { return }
        var floor = peer.floor ?? [:]
        var waiting = peer.unconfirmed ?? []
        for k in keys {
            let n = String(k.epoch)
            floor[n] = min(floor[n] ?? k.index, k.index)
            if !waiting.contains(n) { waiting.append(n) }
        }
        peer.floor = floor
        peer.unconfirmed = waiting
    }

    /// The peer sent something that opened on the session after this device handed it chains: it holds them, and steps
    /// them on itself, so from now on it is handed nothing from before where this device's chains are now.
    private static func confirmHanded(_ peer: inout GroupPeer, chains: [String: SenderChain]) {
        guard let waiting = peer.unconfirmed, !waiting.isEmpty else { return }
        var floor = peer.floor ?? [:]
        for n in waiting { if let now = chains[n] { floor[n] = max(floor[n] ?? 0, now.index) } }
        peer.floor = floor
        peer.unconfirmed = nil
    }

    /// This device's chains for a peer: as its asks want them (no earlier than `handOverFrom` allows; asks for other
    /// devices' chains are not for this one), and with `current` every other epoch's where it is now. Noted on the peer.
    private func handOver(_ wants: [GroupChainWant], current: Bool, to peer: inout GroupPeer, at i: Int) -> [GroupChainKey] {
        guard let shared = data.conversations[i].shared, let tag = shared.myTag,
              let me = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID) else { return [] }
        var lowest: [Int: UInt32] = [:]
        for want in wants.prefix(GroupDirectBody.maxEach) where want.isValid && want.sender == me.publicKey && want.device == tag {
            lowest[want.epoch] = min(lowest[want.epoch] ?? want.index, want.index)
        }
        var out: [GroupChainKey] = []
        for (epoch, index) in lowest.sorted(by: { $0.key < $1.key }) {
            guard let from = handOverFrom(index, epoch: epoch, to: peer, at: i), let k = myChain(epoch: epoch, from: from, at: i) else { continue }
            out.append(k)
        }
        if current {
            // A device just met gets each other epoch's chain (since the epoch they met in) from where it may start: the
            // start of the epoch's chain, as any member in it could read, unless another device of the same member was handed
            // it first (then from where it is now: see `handOverFrom`). Handed only where it is now, it could never open what this device posted in the
            // epoch before they met, and asking later would find the floor already past it.
            for k in currentPositions(except: Set(out.map(\.epoch)), at: i) {
                // Only epochs since the two met: of an older one (from before a newcomer was in) nothing said before.
                guard k.epoch >= (peer.metIn ?? Int.max) else { out.append(k); continue }
                let start = data.conversations[i].shared?.chainStarts?[String(k.epoch)]?.index ?? k.index
                let from = min(k.index, handOverFrom(start, epoch: k.epoch, to: peer, at: i) ?? k.index)
                out.append(from < k.index ? (myChain(epoch: k.epoch, from: from, at: i) ?? k) : k)
            }
        }
        Self.noteHanded(out, to: &peer)
        return out
    }

    /// Hands where this device's chain in `epoch` starts to every member device it has a session with (queued for any
    /// whose session is still being opened). Devices it has none with ask when they see the post. In a channel, staff also
    /// pass it to the followers they invited.
    private func handOutChainStart(_ start: SenderChain, epoch: Int, at i: Int) {
        guard let shared = data.conversations[i].shared, let tag = shared.myTag,
              let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID) else { return }
        let key = GroupChainKey(epoch: epoch, sender: keys.publicKey, device: tag, index: start.index, key: start.key)
        var items: [GroupDirect] = []
        for peer in (shared.peers ?? [:]).values where mayPair(peer.member, in: shared) && !(peer.member == keys.publicKey && peer.device == tag) {
            let id = GroupPeer.id(member: peer.member, device: peer.device)
            if var p = data.conversations[i].shared?.peers?[id] {
                Self.noteHanded([key], to: &p)
                data.conversations[i].shared?.peers?[id] = p
            }
            if let item = directItem(GroupDirectBody(keys: [key]), to: peer.member, device: peer.device, at: i) { items.append(item) }
        }
        postDirect(items, at: i, chainEpoch: epoch)
        if shared.settings.kind == .channel, epoch != 0 { passToFollowers(key, accounts: nil, at: i) }
    }

    /// One item for a member device carrying `body`: a message on the session if it can write; otherwise an ask for a
    /// session (with what is wanted alongside), the chain positions waiting until it opens. Nil when nothing goes now.
    private func directItem(_ body: GroupDirectBody, to member: Data, device: Data, at i: Int) -> GroupDirect? {
        guard var shared = data.conversations[i].shared, !shared.gone, member.count == 32, device.count == GroupSeal.deviceLength else { return nil }
        let id = GroupPeer.id(member: member, device: device)
        var peers = shared.peers ?? [:]
        var peer = peers[id] ?? GroupPeer(member: member, device: device, metIn: shared.current?.number)
        if shared.myTag == nil { shared.myTag = .random(GroupSeal.deviceLength) }
        var item: GroupDirect?
        if var session = peer.session, session.canSend, let plain = try? JSONEncoder.pulshade.encode(body),
           let message = try? session.encrypt(plain) {
            peer.session = session
            peer.used = Date()
            item = GroupDirect(to: member, device: device, message: message)
        } else {
            if let keys = body.keys, !keys.isEmpty { peer.queued = Array(((peer.queued ?? []) + keys).suffix(GroupDirectBody.maxEach)) }
            if peer.pending.map({ Date().timeIntervalSince($0.startedAt) > GroupPeer.helloRetry }) ?? true,
               let (pending, hello) = try? GroupHandshake.start() {
                peer.pending = pending
                item = GroupDirect(to: member, device: device, hello: hello, wants: body.wants.map { Array($0.prefix(GroupDirectBody.maxEach)) })
            }
        }
        peers[id] = peer
        shared.peers = peers
        data.conversations[i].shared = shared
        return item
    }

    /// Posts direct items: in a channel in the staff mailbox (followers needn't see staff talk among themselves), in a
    /// group in the current epoch's. As many posts as it takes to fit.
    private func postDirect(_ items: [GroupDirect], at i: Int, chainEpoch: Int? = nil, inEpoch asked: Int? = nil) {
        guard !items.isEmpty, var shared = data.conversations[i].shared, !shared.gone,
              let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              shared.settings.isMember(keys.publicKey) || mayPairAsMe(keys.publicKey, in: shared), let tag = shared.myTag else { return }
        let channel = shared.settings.kind == .channel
        // An answer goes where it was asked, if this device still reads that epoch: across a change of epoch the asker may
        // not have the new key yet, and may be asking for the very chains that would give it.
        let answered = channel ? nil : asked.flatMap { shared.epoch($0) }
        guard let epoch = answered ?? (channel ? shared.staffEpoch : nil) ?? shared.current else { return }
        let gid = data.conversations[i].wireID
        let wake = items.contains { $0.hello != nil || $0.wants != nil }
        var batches = stride(from: 0, to: items.count, by: 300).map { Array(items[$0..<min($0 + 300, items.count)]) }
        while let batch = batches.first {
            batches.removeFirst()
            guard let plain = try? Payload.groupDirect(batch).wire(framed: false) else { continue }
            if !GroupSeal.fits(payload: plain.count) {
                if batch.count > 1 { batches.insert(contentsOf: [Array(batch.prefix(batch.count / 2)), Array(batch.dropFirst(batch.count / 2))], at: 0) }
                continue
            }
            guard let blob = try? GroupSeal.sealDirect(plain, group: gid, epoch: epoch, keys: keys, device: tag) else { continue }
            shared.outbox.append(GroupOutgoing(sendID: epoch.sendID, days: epoch.days, blob: blob, message: nil, wake: wake,
                                               ephemeral: false, epoch: epoch.number))
        }
        data.conversations[i].shared = shared
        kick()
    }

    /// Asks the devices that posted for their chains from each want's index on, ten minutes apart for each chain, all in
    /// one direct post (one item per device). A channel's follower asks the staff member who invited it, over their 1:1 chat.
    private func askForChains(_ wants: [GroupChainWant], at i: Int) {
        guard !wants.isEmpty, let shared = data.conversations[i].shared, !shared.gone,
              let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              !shared.joining || isFollower(data.conversations[i]) || mayPairAsMe(keys.publicKey, in: shared) else { return }
        let now = Date()
        var asked = (shared.chainAsked ?? [:]).filter { now.timeIntervalSince($0.value) < 86_400 }
        var due: [GroupChainWant] = []
        for want in wants where want.isValid && !(want.sender == keys.publicKey && want.device == shared.myTag) {
            guard now.timeIntervalSince(asked[want.chainID] ?? .distantPast) > Self.keyAskCooldown else { continue }
            asked[want.chainID] = now
            due.append(want)
        }
        guard !due.isEmpty else { return }
        data.conversations[i].shared?.chainAsked = asked
        if isFollower(data.conversations[i]) {
            let staff = due.filter { $0.epoch != 0 && shared.settings.isMember($0.sender) }
            for start in stride(from: 0, to: staff.count, by: 16) {
                noticeToInviter(.groupChainWanted(group: data.conversations[i].wireID, wants: Array(staff[start..<min(start + 16, staff.count)])),
                                of: data.conversations[i])
            }
            return
        }
        guard mayPairAsMe(keys.publicKey, in: shared) else { return }
        let byDevice = Dictionary(grouping: due.filter { mayPair($0.sender, in: shared) }) { GroupPeer.id(member: $0.sender, device: $0.device) }
        var items: [GroupDirect] = []
        for (_, theirs) in byDevice.sorted(by: { $0.key < $1.key }) {
            guard let first = theirs.first else { continue }
            if let item = directItem(GroupDirectBody(wants: Array(theirs.prefix(GroupDirectBody.maxEach))), to: first.sender, device: first.device, at: i) {
                items.append(item)
            }
        }
        postDirect(items, at: i)
    }

    /// For each sender device with posts held here that this device can't open: the earliest such post.
    private func heldWants(at i: Int) -> [String: GroupChainWant] {
        guard let shared = data.conversations[i].shared, let held = shared.heldMail, !held.isEmpty else { return [:] }
        let gid = data.conversations[i].wireID
        var out: [String: GroupChainWant] = [:]
        for item in held {
            guard let epoch = shared.epoch(item.epoch), let outer = try? GroupSeal.outer(item.blob, group: gid, epoch: epoch),
                  !outer.isDirect, shared.settings.isMember(outer.sender) else { continue }
            let want = GroupChainWant(epoch: item.epoch, sender: outer.sender, device: outer.device, index: outer.index)
            if let have = out[want.chainID], have.index <= want.index { continue }
            out[want.chainID] = want
        }
        return out
    }

    /// Held posts whose chain hasn't come: asked for again (each chain ten minutes apart), in one direct post.
    private func askForHeldChains(at i: Int) {
        askForChains(heldWants(at: i).values.sorted { $0.chainID < $1.chainID }, at: i)
    }

    /// The groups that held posts for want of a chain while a fetch was read: asked for now, one direct post each.
    func askDueChains() {
        let due = chainAsksDue
        chainAsksDue = []
        for id in due { if let i = index(of: id) { askForHeldChains(at: i) } }
    }

    /// The indexes of held posts for each chain, so a chain handed over from further back fills in just those.
    private func heldIndexes(at i: Int) -> [String: [UInt32]] {
        guard let shared = data.conversations[i].shared, let held = shared.heldMail, !held.isEmpty else { return [:] }
        let gid = data.conversations[i].wireID
        var out: [String: [UInt32]] = [:]
        for item in held {
            guard let epoch = shared.epoch(item.epoch), let outer = try? GroupSeal.outer(item.blob, group: gid, epoch: epoch), !outer.isDirect else { continue }
            out[GroupReader.id(epoch: item.epoch, sender: outer.sender, device: outer.device), default: []].append(outer.index)
        }
        return out
    }

    /// Takes chain positions in: only a sender device's own (`from`), or, with `from` nil, any staff device's (passed on
    /// by the staff member who invited this follower). True if any was new.
    private func takeChainKeys(_ keys: [GroupChainKey], from: (member: Data, device: Data)?, at i: Int) -> Bool {
        guard var shared = data.conversations[i].shared, !shared.gone else { return false }
        let held = heldIndexes(at: i)
        var took = false
        for k in keys.prefix(GroupDirectBody.maxEach) where k.isValid {
            if let from, k.sender != from.member || k.device != from.device { continue }
            guard k.epoch == 0 ? shared.staffEpoch != nil : shared.epoch(k.epoch) != nil else { continue }
            let id = GroupReader.id(epoch: k.epoch, sender: k.sender, device: k.device)
            // Passed on by someone else (a channel's inviter), it stands only once a post its device signed opens with it.
            if shared.reader.start(epoch: k.epoch, sender: k.sender, device: k.device, chain: k.chain, wanted: held[id] ?? [],
                                   proven: from != nil) { took = true }
            shared.chainAsked?[id] = nil
        }
        data.conversations[i].shared = shared
        return took
    }

    /// Direct items in a post from `member`'s `device`: the ones for this device are taken in, and answered. At most
    /// `GroupDirect.maxForOneDevice` are looked at, and one ask for a session.
    private func receiveDirect(_ items: [GroupDirect], from member: Data, device: Data, deposited: Date?, epoch number: Int, at i: Int) {
        guard let shared = data.conversations[i].shared, !shared.gone, let tag = shared.myTag,
              let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              mayPair(member, in: shared), mayPairAsMe(keys.publicKey, in: shared),
              let card = shared.settings.card(member), !(member == keys.publicKey && device == tag) else { return }
        let gid = data.conversations[i].wireID
        let id = GroupPeer.id(member: member, device: device)
        let mine = items.prefix(GroupDirect.maxItems).filter { $0.to == keys.publicKey && $0.device == tag }.prefix(GroupDirect.maxForOneDevice)
        var replies: [GroupDirect] = []
        var took = false
        var helloSeen = false
        for item in mine {
            let known = data.conversations[i].shared?.peers?[id]
            var peer = known ?? GroupPeer(member: member, device: device, metIn: shared.current?.number)
            var body: GroupDirectBody?
            // The session has just opened at this end: the other end hears back, even with nothing to say, so it knows
            // what it handed over arrived.
            var ack = false
            if let hello = item.hello {
                guard !helloSeen else { continue }
                helloSeen = true
                guard hello.ephemeral.count == 32, hello.kem.count == PQPin.kemSize, !peer.answered.contains(hello.ephemeral) else { continue }
                // A device met for the first time: at most a few of one member's in an epoch, so nobody can make up tags
                // to fill this phone with sessions.
                if known == nil {
                    let epochNow = shared.current?.number
                    let fresh = (data.conversations[i].shared?.peers ?? [:]).values.count { $0.member == member && $0.metIn == epochNow }
                    guard fresh < GroupPeer.maxNewPerMember else { continue }
                }
                // With a session open, an ask for a new one replaces it only if it was posted after the session opened, or
                // a message from that device lately didn't open here (its end lost the session). An old ask posted again
                // changes nothing.
                if peer.session != nil {
                    let newer = (deposited ?? Date()) > (peer.openedAt ?? .distantPast)
                    let failed = Date().timeIntervalSince(peer.failedAt ?? .distantPast) < GroupPeer.failedWindow
                    guard newer || failed else { continue }
                }
                // Both asked at once: the one whose key and device sort first is answered, the other let go. What the one let
                // go asked for still goes to them, once the session the other ask opens is there.
                if peer.pending != nil, (keys.publicKey + tag).hex < (member + device).hex {
                    let give = handOver(item.wants ?? [], current: false, to: &peer, at: i)
                    if !give.isEmpty {
                        peer.queued = Array(((peer.queued ?? []) + give).suffix(GroupDirectBody.maxEach))
                        let peers = (data.conversations[i].shared?.peers ?? [:]).merging([id: peer]) { _, new in new }
                        data.conversations[i].shared?.peers = peers
                    }
                    continue
                }
                guard let (session, accept) = try? GroupHandshake.accept(hello, group: gid, me: keys, myDevice: tag, them: card, theirDevice: device)
                else { continue }
                peer.session = session
                peer.pending = nil
                peer.answered = Array((peer.answered + [hello.ephemeral]).suffix(8))
                peer.used = Date()
                peer.openedAt = deposited ?? Date()
                peer.failedAt = nil
                // A device gets this device's chains where they are now (not what was said before), and what it asked
                // for, no earlier than its floor allows.
                var give = handOver(item.wants ?? [], current: true, to: &peer, at: i)
                give += peer.queued ?? []
                peer.queued = nil
                var s = session
                guard let plain = try? JSONEncoder.pulshade.encode(GroupDirectBody(keys: Array(give.prefix(GroupDirectBody.maxEach)))),
                      let message = try? s.encrypt(plain) else { continue }
                peer.session = s
                replies.append(GroupDirect(to: member, device: device, accept: accept, message: message))
            } else if let accept = item.accept, let message = item.message {
                guard let pending = peer.pending, accept.replyTo == pending.publicEphemeral,
                      var session = try? GroupHandshake.complete(pending, accept, group: gid, me: keys, myDevice: tag, them: card, theirDevice: device),
                      let plain = try? session.decrypt(message) else { continue }
                peer.session = session
                peer.pending = nil
                peer.used = Date()
                peer.openedAt = deposited ?? Date()
                peer.failedAt = nil
                body = try? JSONDecoder.pulshade.decode(GroupDirectBody.self, from: plain)
                // The session is open both ways now: the other device gets this one's chains where they are now.
                let give = handOver([], current: true, to: &peer, at: i)
                if !give.isEmpty { peer.queued = Array(((peer.queued ?? []) + give).suffix(GroupDirectBody.maxEach)) }
                ack = true
            } else if let message = item.message {
                if var session = peer.session, let plain = try? session.decrypt(message) {
                    peer.session = session
                    peer.used = Date()
                    // Anything that opens shows that device got what this one handed it before.
                    Self.confirmHanded(&peer, chains: data.conversations[i].shared?.chains ?? [:])
                    body = try? JSONDecoder.pulshade.decode(GroupDirectBody.self, from: plain)
                } else {
                    peer.failedAt = Date()
                    if peer.pending == nil, Date().timeIntervalSince(peer.resetAt ?? .distantPast) > GroupPeer.helloRetry {
                        // A message that doesn't open: their side holds a session this device doesn't. A new one is asked for.
                        peer.resetAt = Date()
                        // Read first, then write: reading `data` inside an optional-chained write to it is an exclusivity conflict,
                        // which stops the app.
                        let peers = (data.conversations[i].shared?.peers ?? [:]).merging([id: peer]) { _, new in new }
                        data.conversations[i].shared?.peers = peers
                        if let hello = directItem(GroupDirectBody(), to: member, device: device, at: i) { replies.append(hello) }
                        continue
                    }
                }
            }
            let peers = (data.conversations[i].shared?.peers ?? [:]).merging([id: peer]) { _, new in new }
            data.conversations[i].shared?.peers = peers
            if let body {
                if let given = body.keys, !given.isEmpty {
                    if takeChainKeys(given, from: (member, device), at: i) {
                        took = true
                    }
                    if data.conversations[i].shared?.settings.kind == .channel { passOn(given, from: member, device: device, at: i) }
                }
                if let wants = body.wants, !wants.isEmpty, var p = data.conversations[i].shared?.peers?[id] {
                    let give = handOver(wants, current: false, to: &p, at: i)
                    data.conversations[i].shared?.peers?[id] = p
                    if !give.isEmpty, let reply = directItem(GroupDirectBody(keys: give), to: member, device: device, at: i) { replies.append(reply) }
                }
            }
            // Positions that waited for the session to open (or, just opened, a word back with nothing in it).
            if data.conversations[i].shared?.peers?[id]?.session?.canSend == true {
                let queued = data.conversations[i].shared?.peers?[id]?.queued ?? []
                if !queued.isEmpty || ack {
                    data.conversations[i].shared?.peers?[id]?.queued = nil
                    let reply = directItem(GroupDirectBody(keys: queued.isEmpty ? nil : queued), to: member, device: device, at: i)
                    if let reply { replies.append(reply) }
                }
            }
        }
        postDirect(replies, at: i, inEpoch: number)
        if took { rereadHeldMail(at: i) }
    }

    /// This device's chains in every epoch still read where they are now (for a device just met: nothing said before).
    private func currentPositions(except epochs: Set<Int>, at i: Int) -> [GroupChainKey] {
        guard let shared = data.conversations[i].shared else { return [] }
        return shared.chains.keys.compactMap(Int.init).filter { n in
            !epochs.contains(n) && (n == 0 ? shared.settings.kind == .channel : shared.epoch(n) != nil)
        }.compactMap { n in myChain(epoch: n, from: shared.chains[String(n)]?.index ?? 0, at: i) }
    }

    // MARK: A channel's followers

    /// The followers this staff device's account invited, by account, still following.
    private func myFollowers(at i: Int) -> [Contact] {
        guard let shared = data.conversations[i].shared, shared.settings.kind == .channel, let live = shared.roster?.live else { return [] }
        let keys = Set(live.filter { !shared.settings.isMember($0.signingKey) }.map { Identity.fingerprint(of: $0.signingKey) })
        return shared.knownAs.filter { keys.contains($0.value) }.keys.sorted().compactMap { contact($0, in: data.conversations[i].persona) }
    }

    /// Where a staff device's chain (by `GroupReader.id`) is as this device knows it: its own where it is, another's where
    /// this device reads it from.
    private func knownPosition(_ chain: String, at i: Int) -> UInt32? {
        guard let shared = data.conversations[i].shared,
              let me = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID) else { return nil }
        let parts = chain.split(separator: "|")
        if parts.count == 3, let tag = shared.myTag, parts[1] == Substring(me.publicKey.hex), parts[2] == Substring(tag.hex) {
            return shared.chains[String(parts[0])]?.index
        }
        return shared.reader.chains[chain]?.index
    }

    /// Notes, as this device lets a follower in, where every staff device's chain it knows is, so the follower is handed
    /// nothing said before they came in.
    private func noteAdmitted(_ account: String, at i: Int) {
        guard let shared = data.conversations[i].shared, shared.settings.kind == .channel,
              let me = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID) else { return }
        var at: [String: UInt32] = [:]
        if let tag = shared.myTag {
            for (n, chain) in shared.chains where n != "0" {
                if let e = Int(n) { at[GroupReader.id(epoch: e, sender: me.publicKey, device: tag)] = chain.index }
            }
        }
        for (id, chain) in shared.reader.chains where !id.hasPrefix("0|") { at[id] = chain.index }
        data.conversations[i].shared?.admittedAt = (shared.admittedAt ?? [:]).merging([account: at]) { _, new in new }
    }

    /// The earliest position of a staff device's chain a follower this device let in may be given: where it was when they
    /// came in (a chain this device didn't know of then from its start). With no note of when, where it is now.
    private func followerFloor(_ account: String, chain: String, at i: Int) -> UInt32 {
        if let admitted = data.conversations[i].shared?.admittedAt?[account] { return admitted[chain] ?? 0 }
        return knownPosition(chain, at: i) ?? 0
    }

    /// Passes a chain position on to followers this account invited, over their 1:1 chats: those who asked for it (at the
    /// place each asked), or with `accounts` nil, all of them; never from before each came in.
    private func passToFollowers(_ k: GroupChainKey, accounts: [String: UInt32]?, at i: Int) {
        let gid = data.conversations[i].wireID
        let id = GroupReader.id(epoch: k.epoch, sender: k.sender, device: k.device)
        for follower in myFollowers(at: i) {
            var index = k.index
            if let accounts {
                guard let asked = accounts[follower.fingerprint] else { continue }
                index = max(index, asked)
            }
            index = max(index, followerFloor(follower.fingerprint, chain: id, at: i))
            guard let give = Self.stepped(k, to: index) else { continue }
            enqueue(.groupChainKeys(group: gid, keys: [give]), to: follower)
        }
    }

    /// As staff of a channel, chain positions another staff device handed over: passed on to the followers who asked for
    /// them, and a chain's start to every follower this device let in. Each device passes chains to the followers it let in
    /// itself (`knownAs` is kept on that device alone), so a follower let in on any of an account's devices gets them.
    private func passOn(_ keys: [GroupChainKey], from member: Data, device: Data, at i: Int) {
        guard let me = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              data.conversations[i].shared?.settings.isAdmin(me.publicKey) == true else { return }
        for k in keys where k.isValid && k.epoch != 0 && k.sender == member && k.device == device {
            let id = GroupReader.id(epoch: k.epoch, sender: k.sender, device: k.device)
            if let wanted = data.conversations[i].shared?.followerWants?[id] {
                data.conversations[i].shared?.followerWants?[id] = nil
                passToFollowers(k, accounts: wanted, at: i)
            } else if k.index == 0 || data.conversations[i].shared?.reader.starts?[id] == k.index {
                // A chain's start, or the first place this device was given it: every follower this device let in gets it.
                passToFollowers(k, accounts: nil, at: i)
            }
        }
    }

    /// A follower this device let in holds posts it can't open: this device's own chain is handed straight back; for
    /// another staff device's, that device is asked over the pairwise session, and the answer passed on. Never from before
    /// the follower came in.
    private func answerFollowerChainWants(_ group: UUID, wants: [GroupChainWant], from sender: Contact) {
        guard let (i, _) = followerEntry(of: sender, group: group), let shared = data.conversations[i].shared,
              let me = memberKeys(sender.persona, group: group) else { return }
        var mine: [GroupChainKey] = []
        var asks: [GroupChainWant] = []
        for want in Set(wants.prefix(16)) where want.isValid && want.epoch != 0 && shared.epoch(want.epoch) != nil
            && shared.settings.isAdmin(want.sender) {
            let limit = group.uuidString + sender.fingerprint + want.chainID
            guard Date().timeIntervalSince(followerChainAnswered[limit] ?? .distantPast) > 60 else { continue }
            followerChainAnswered[limit] = Date()
            let from = max(want.index, followerFloor(sender.fingerprint, chain: want.chainID, at: i))
            if want.sender == me.publicKey && want.device == shared.myTag {
                if let k = myChain(epoch: want.epoch, from: from, at: i) { mine.append(k) }
            } else {
                var wanted = data.conversations[i].shared?.followerWants ?? [:]
                if wanted.count >= 200, wanted[want.chainID] == nil { continue }
                wanted[want.chainID, default: [:]][sender.fingerprint] = min(from, wanted[want.chainID]?[sender.fingerprint] ?? .max)
                data.conversations[i].shared?.followerWants = wanted
                asks.append(GroupChainWant(epoch: want.epoch, sender: want.sender, device: want.device, index: from))
            }
        }
        if !asks.isEmpty {
            let byDevice = Dictionary(grouping: asks) { GroupPeer.id(member: $0.sender, device: $0.device) }
            var items: [GroupDirect] = []
            for (_, theirs) in byDevice.sorted(by: { $0.key < $1.key }) {
                guard let first = theirs.first else { continue }
                if let item = directItem(GroupDirectBody(wants: theirs), to: first.sender, device: first.device, at: i) { items.append(item) }
            }
            postDirect(items, at: i)
        }
        if !mine.isEmpty { enqueue(.groupChainKeys(group: group, keys: mine), to: sender) }
        save()
    }

    /// Staff chains passed on by the staff member who invited this follower (and by nobody else).
    private func takeChainKeysFromInviter(_ group: UUID, keys: [GroupChainKey], from sender: Contact) {
        guard let i = groupIndex(group, persona: sender.persona), let shared = data.conversations[i].shared,
              isFollower(data.conversations[i]), shared.ownerAccount == sender.fingerprint else { return }
        // Never a jump far past a chain already followed: that would replace the real chain with one of the inviter's
        // choosing, and the staff member's posts would stop opening here.
        let staff = keys.filter { k in
            guard k.epoch != 0, shared.settings.isAdmin(k.sender) else { return false }
            guard let held = shared.reader.chains[GroupReader.id(epoch: k.epoch, sender: k.sender, device: k.device)] else { return true }
            return !(k.index > held.index && k.index - held.index > GroupReader.maxSkip)
        }
        if takeChainKeys(staff, from: nil, at: i) { rereadHeldMail(at: i) }
        save()
    }

    /// Sessions with devices of people no longer in go; past the cap, the ones unused longest; an ask unanswered for a week
    /// is let go.
    private func tendPeers(at i: Int) {
        guard let shared = data.conversations[i].shared, var peers = shared.peers, !peers.isEmpty else { return }
        let before = peers
        peers = peers.filter { mayPair($0.value.member, in: shared) }
        for (id, peer) in peers where peer.session == nil && peer.pending.map({ Date().timeIntervalSince($0.startedAt) > 7 * 86_400 }) == true {
            peers[id] = nil
        }
        if peers.count > GroupPeer.maxPerGroup {
            for (id, _) in peers.sorted(by: { $0.value.used < $1.value.used }).prefix(peers.count - GroupPeer.maxPerGroup) { peers[id] = nil }
        }
        // Floors go with the epochs no longer read (this device's chains in them are gone).
        let stillRead = Set(shared.readable.map { String($0.number) }).union(["0"])
        for (id, peer) in peers where peer.floor?.keys.contains(where: { !stillRead.contains($0) }) == true
            || peer.unconfirmed?.contains(where: { !stillRead.contains($0) }) == true {
            peers[id]?.floor = peer.floor?.filter { stillRead.contains($0.key) }
            peers[id]?.unconfirmed = peer.unconfirmed?.filter { stillRead.contains($0) }
        }
        if peers != before { data.conversations[i].shared?.peers = peers }
        // Notes of where followers came in go with followers this device no longer has, or is no longer inviting.
        if let admitted = shared.admittedAt, admitted.keys.contains(where: { shared.knownAs[$0] == nil && shared.invited[$0] == nil }) {
            data.conversations[i].shared?.admittedAt = admitted.filter { shared.knownAs[$0.key] != nil || shared.invited[$0.key] != nil }
        }
    }
}

extension Payload {
    /// Worth waking a locked phone for.
    var wakes: Bool {
        switch self {
        case .message, .groupSettings, .groupRekey: true
        default: false
        }
    }

    var isLeaving: Bool {
        if case .left = self { return true }
        return false
    }

    /// An invite to a group: worth waking a locked phone for, so it's taken up at once.
    var isInvite: Bool {
        switch self {
        case .groupInvite: true
        default: false
        }
    }

    /// The group's settings and the hand-out of a new epoch's key: posted under the epoch's outer layer only, signed by the
    /// poster, never on a chain. Everyone in the epoch reads them at once, including a newcomer who has no chains yet (it
    /// learns from them that it's in) and someone just removed (it learns it was). Neither says anything anyone wrote, the
    /// settings are signed by whoever made them, and each copy of a new key is sealed to its reader inside.
    ///
    /// The same goes for leaving and for the owner deleting the group: the device that posts them lets the group go at once,
    /// so nobody could ask it for a chain to read them by.
    ///
    /// The cost (see "Known trade-off" in docs/groups-design.md, section 21): those copies are sealed to keys a member keeps
    /// while it is in the group, so whoever records the relay and later takes a member's keys can work out every epoch key
    /// since, and with them who posted when and the settings. Never what anyone wrote: that stays on the chains.
    var goesWithoutChain: Bool {
        switch self {
        case .groupSettings, .groupRekey, .left, .chatDeleted: true
        default: false
        }
    }

    /// Something people said (not the group's own housekeeping): a newcomer shouldn't be able to read it.
    var isChat: Bool {
        switch self {
        case .groupSettings, .groupRekey, .groupLinks, .groupRoster, .groupKeyWanted, .groupCatchUp, .friendAsk, .membersAdded, .typing, .memberCard,
             .groupDirect, .groupChainWanted, .groupChainKeys: false
        default: true
        }
    }
}

// MARK: - Join links

/// Links into groups that share one mailbox (see `JoinLinks.swift` and docs/groups-design.md, section 5). Admins make
/// them; the phone of the admin who made a link lets in people who ask through it when it's open (other admins' phones
/// step in if that one is away), and holds the rest for any admin's yes. Anyone with a link sees a signed preview first and
/// asks with a key made for that group alone, and takes an answer only from the owner or an admin the preview named.
extension AppModel {
    /// The group's links and bans as this device holds them.
    func joinLinks(_ id: Conversation.ID) -> GroupLinks? { conversation(id)?.shared?.links }

    /// Requests waiting for an admin's yes.
    func heldJoins(_ id: Conversation.ID) -> [HeldJoin] { conversation(id)?.shared?.held ?? [] }

    /// A link as people share it (it names the group's owner, whose phone signs its preview).
    func linkCode(_ link: JoinLink, in id: Conversation.ID) -> GroupLinkCode? {
        conversation(id)?.shared.map { link.code(owner: $0.settings.owner) }
    }

    private func amGroupOwner(at i: Int) -> GroupMemberKeys? {
        guard let keys = amGroupAdmin(at: i), data.conversations[i].shared?.settings.owner == keys.publicKey else { return nil }
        return keys
    }

    private func amGroupAdmin(at i: Int) -> GroupMemberKeys? {
        guard let shared = data.conversations[i].shared, !shared.gone, !shared.joining,
              let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              shared.settings.isAdmin(keys.publicKey) else { return nil }
        return keys
    }

    /// The owner and admins, as (member key, group agreement key), from their cards in the settings.
    private func staffCards(at i: Int) -> [MemberCard] {
        guard let s = data.conversations[i].shared?.settings else { return [] }
        return s.members.filter { s.isAdmin($0.signingKey) }
    }

    private func heldSecrets(at i: Int) -> [UUID: LinkSecrets] {
        var out: [UUID: LinkSecrets] = [:]
        for (id, secrets) in data.conversations[i].shared?.linkSecrets ?? [:] { if let uuid = UUID(uuidString: id) { out[uuid] = secrets } }
        return out
    }

    // MARK: Making and changing links

    /// A new link. Nil if this account isn't an admin or the group has as many as it may.
    @discardableResult
    func makeJoinLink(in id: Conversation.ID, label: String, approval: Bool, expires: Date? = nil, limit: Int? = nil) -> JoinLink? {
        guard let i = index(of: id), let keys = amGroupAdmin(at: i),
              (data.conversations[i].shared?.links?.links.count ?? 0) < GroupLinks.maxLinks,
              let (link, secrets) = JoinLink.make(label: label, approval: approval, expires: expires, limit: limit, creator: keys.publicKey),
              publishLinks(at: i, adding: [link.id: secrets], { $0.links.append(link) }) else { return nil }
        writePreviews(at: i)
        return link
    }

    /// New secrets for a link: every copy of the old one stops working, and its preview is erased. This account becomes
    /// the one whose phone lets people in through it first.
    func resetJoinLink(_ link: UUID, in id: Conversation.ID) {
        guard let i = index(of: id), let keys = amGroupAdmin(at: i), let old = data.conversations[i].shared?.links?.link(link),
              var (fresh, secrets) = old.reset() else { return }
        fresh.creator = keys.publicKey
        guard publishLinks(at: i, adding: [link: secrets], { links in
            if let n = links.links.firstIndex(where: { $0.id == link }) { links.links[n] = fresh }
        }) else { return }
        erasePreview(old)
        data.conversations[i].shared?.previews?[link.uuidString] = nil
        writePreviews(at: i)
        // A public name opening this link is listed again with its new code.
        if publicName(id)?.link == link { Task { await refreshPublicName(for: id) } }
    }

    func deleteJoinLink(_ link: UUID, in id: Conversation.ID) {
        guard let i = index(of: id), amGroupAdmin(at: i) != nil, let old = data.conversations[i].shared?.links?.link(link) else { return }
        guard publishLinks(at: i, { $0.links.removeAll { $0.id == link } }) else { return }
        erasePreview(old)
        data.conversations[i].shared?.previews?[link.uuidString] = nil
        data.conversations[i].shared?.held?.removeAll { $0.request.link == link }
        save()
        // The public name that opened it has nothing to open any more.
        if publicName(id)?.link == link { Task { await removePublicName(for: id) } }
    }

    /// Takes someone out and turns down any request of theirs from now on. False if the ban list is full.
    @discardableResult
    func banMember(_ fingerprint: String, in id: Conversation.ID) -> Bool {
        guard let i = index(of: id), amGroupAdmin(at: i) != nil, let target = contact(fingerprint, in: data.conversations[i].persona),
              ban(target.signingKey, at: i) else { return false }
        if data.conversations[i].shared?.settings.isMember(target.signingKey) == true, data.conversations[i].canRemove(fingerprint, by: "me") {
            removeSharedMember(fingerprint, at: i)
        }
        return true
    }

    /// Turns down a waiting request and bans its key. False if the ban list is full (the request is still turned down).
    @discardableResult
    func declineAndBan(_ heldID: Data, in id: Conversation.ID) -> Bool {
        guard let i = index(of: id), let held = data.conversations[i].shared?.held?.first(where: { $0.id == heldID }) else { return false }
        declineJoin(heldID, in: id)
        return ban(held.key, at: i)
    }

    private func ban(_ key: Data, at i: Int) -> Bool {
        guard amGroupAdmin(at: i) != nil, (data.conversations[i].shared?.links?.bans.count ?? 0) < GroupLinks.maxBans || data.conversations[i].shared?.links?.bans.contains(key) == true
        else { return false }
        let done = publishLinks(at: i) { links in
            if !links.bans.contains(key) { links.bans.append(key) }
            links.unbans.removeAll { $0 == key }
        }
        data.conversations[i].shared?.held?.removeAll { $0.request.card.signingKey == key }
        save()
        return done
    }

    func unban(_ key: Data, in id: Conversation.ID) {
        guard let i = index(of: id), amGroupAdmin(at: i) != nil else { return }
        _ = publishLinks(at: i) { links in
            links.bans.removeAll { $0 == key }
            links.unbans = Array((links.unbans.filter { $0 != key } + [key]).suffix(GroupLinks.maxUnbans))
        }
    }

    /// The name a banned key was last known by in this group, if any.
    func bannedName(_ key: Data, in id: Conversation.ID) -> String {
        guard let convo = conversation(id) else { return "Someone" }
        return contact(Identity.fingerprint(of: key), in: convo.persona)?.displayName ?? "Someone"
    }

    /// Signs and posts the next version of the links, changed by `change`, with every link's secrets sealed again to the
    /// owner and admins of the moment. An admin whose phone doesn't hold every link's secrets yet (the owner's phone hasn't
    /// sealed them to it) can't change the links; the owner's phone gives such a link new secrets, since nothing else would
    /// let its requests be read.
    private func publishLinks(at i: Int, adding added: [UUID: LinkSecrets] = [:], _ change: (inout GroupLinks) -> Void) -> Bool {
        guard let keys = amGroupAdmin(at: i), let shared = data.conversations[i].shared else { return false }
        let owner = shared.settings.owner == keys.publicKey
        var next = shared.links ?? GroupLinks(group: data.conversations[i].wireID, version: 0)
        change(&next)
        var secrets = heldSecrets(at: i).merging(added) { $1 }
        let missing = next.links.indices.filter { secrets[next.links[$0].id].map(next.links[$0].matches) != true }
        if !missing.isEmpty && !owner { return false }
        for n in missing {
            guard var (fresh, made) = next.links[n].reset() else { continue }
            fresh.creator = keys.publicKey
            erasePreview(next.links[n])
            next.links[n] = fresh
            secrets[fresh.id] = made
        }
        secrets = secrets.filter { id, _ in next.link(id) != nil }
        let staff = staffCards(at: i)
        next.seal(secrets, to: staff)
        next.version += 1
        next.sign(with: keys)
        guard next.wellFormed else { return false }
        data.conversations[i].shared?.links = next
        data.conversations[i].shared?.linkSecrets = Dictionary(uniqueKeysWithValues: secrets.map { ($0.key.uuidString, $0.value) })
        data.conversations[i].shared?.linksEpoch = shared.current?.number
        if owner {
            let sealedTo = staff.map(\.signingKey).sorted { $0.hex < $1.hex }
            data.conversations[i].shared?.linksSealedTo = sealedTo
            // A version made now with new secrets for every link starts the record afresh.
            let renewedAll = !next.links.isEmpty && next.links.allSatisfy { link in shared.links?.link(link.id)?.secret != link.secret }
            let before = renewedAll ? [] : (shared.linksExposed ?? [])
            data.conversations[i].shared?.linksExposed = Array(Set(before + sealedTo))
        }
        post(.groupLinks(next), at: i)
        save()
        return true
    }

    /// A version of the links from the group's mailbox: taken if an admin signed it and it's newer (or, at the same
    /// number, wins the same tie-break everyone uses). An admin's phone opens its copy of the links' keys. A ban or a use
    /// count this device holds that the new version lost (two admins changed it at once) is put back.
    func adoptLinks(_ next: GroupLinks, from sender: Data, at i: Int) {
        guard let shared = data.conversations[i].shared, next.group == data.conversations[i].wireID,
              shared.settings.isAdmin(next.signer), shared.settings.isMember(sender) || next.signer == sender,
              next.signatureIsValid, next.wellFormed else { return }
        let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID)
        let owner = shared.settings.owner
        if let held = shared.links {
            // The next version from an admin, any later one from the owner, or a competing one that wins (the owner's first).
            let next1 = next.version == held.version + 1
            let ownerJump = next.signer == owner && next.version > held.version
            let competing = next.version == held.version && next != held && next.winsOver(held, settings: shared.settings)
            guard next1 || ownerJump || competing else { return }
            // As the owner: a link that's gone or was reset elsewhere has its old preview erased.
            if let keys, owner == keys.publicKey {
                for old in held.links where next.link(old.id)?.secret != old.secret {
                    erasePreview(old)
                    data.conversations[i].shared?.previews?[old.id.uuidString] = nil
                }
            }
        }
        let held = shared.links
        data.conversations[i].shared?.links = next
        if let keys, shared.settings.isAdmin(keys.publicKey) {
            // This copy, or (if the owner's phone hasn't sealed one to this account yet) whatever held still fits.
            let opened = next.open(with: keys) ?? heldSecrets(at: i).filter { id, secrets in next.link(id)?.matches(secrets) == true }
            data.conversations[i].shared?.linkSecrets = Dictionary(uniqueKeysWithValues: opened.map { ($0.key.uuidString, $0.value) })
        } else {
            data.conversations[i].shared?.linkSecrets = nil
        }
        // As the owner: everyone the secrets have been sealed to since the last reset, whoever sealed them.
        if let keys, owner == keys.publicKey {
            data.conversations[i].shared?.linksExposed = Array(Set((shared.linksExposed ?? []) + Array(next.sealedTo)))
        }
        data.conversations[i].shared?.held?.removeAll { item in
            next.link(item.request.link) == nil || next.bans.contains(item.request.card.signingKey)
        }
        // Lost in a competing change: put back.
        if let held, amGroupAdmin(at: i) != nil {
            let lostBans = held.bans.filter { !next.bans.contains($0) && !next.unbans.contains($0) }
            let lostUses = next.links.contains { link in held.link(link.id).map { $0.secret == link.secret && $0.used > link.used } ?? false }
            // Never past the cap (that would push out someone else's ban, and two phones could go back and forth).
            let room = GroupLinks.maxBans - next.bans.count
            if (!lostBans.isEmpty && room >= lostBans.count) || lostUses {
                _ = publishLinks(at: i) { links in
                    if room >= lostBans.count { links.bans += lostBans.filter { !links.bans.contains($0) } }
                    for n in links.links.indices {
                        if let old = held.link(links.links[n].id), old.secret == links.links[n].secret { links.links[n].used = max(links.links[n].used, old.used) }
                    }
                }
            }
        }
        writePreviews(at: i)
        save()
    }

    // MARK: Previews

    /// The preview of one link as the owner's phone signs it now.
    private func preview(of link: JoinLink, at i: Int, keys: GroupMemberKeys) -> GroupPreview? {
        guard let shared = data.conversations[i].shared else { return nil }
        let s = shared.settings
        var preview = GroupPreview(group: s.group, link: link.id, title: String(s.title.prefix(100)), about: s.about.map { String($0.prefix(500)) },
                                   avatar: Self.thumbnail(s.avatar, side: 160), members: s.members.count, approval: link.approval,
                                   expires: link.expires.map(wholeSecond), requestKey: link.requestPublic, mailbox: link.mailboxSendID,
                                   owner: s.owner, admins: Array(s.admins.prefix(200)), made: wholeSecond(Date()))
        if (preview.avatar?.count ?? 0) > 32 * 1024 { preview.avatar = nil }
        preview.slot = JoinSlot.tag(link.secret)
        preview.sign(with: keys)
        return preview
    }

    /// The owner's phone writes every link's preview whose content changed (a new name, size, or set of admins), or that
    /// hasn't been written for a day (so one a link holder deleted or overwrote doesn't stay broken, and openers, who take
    /// a preview only for two weeks after it was made, always find a fresh one). Only the owner signs
    /// previews, and the link names the owner, so nobody who stops being an admin can put out one of their own.
    func writePreviews(at i: Int) {
        guard let keys = amGroupOwner(at: i),
              let links = data.conversations[i].shared?.links else { return }
        let now = Date()
        for link in links.links where link.isOpen(at: now) {
            guard let preview = preview(of: link, at: i, keys: keys), let slot = JoinSlot.keys(link.secret),
                  let sealed = JoinSlot.seal(preview, with: slot) else { continue }
            let mark = data.conversations[i].shared?.previews?[link.id.uuidString]
            if let mark, mark.hash == preview.contentHash, now.timeIntervalSince(mark.at) < 86_400 { continue }
            guard let client = client(nil, lane: "join-\(link.id.uuidString.prefix(8))") else { continue }
            let group = data.conversations[i].id, hash = preview.contentHash, id = link.id.uuidString
            // Marked before it goes, so a slow write isn't started again; put back if it fails.
            var marks = data.conversations[i].shared?.previews ?? [:]
            marks[id] = PreviewMark(hash: hash, at: now)
            data.conversations[i].shared?.previews = marks
            Task { [weak self] in
                let (key, sig, ts) = SpareSlot.proof("pulshade.backup.put.v1", slot, body: sealed)
                let done = (try? await client.putBackup(sealed, key: key, sig: sig, ts: ts)) != nil
                guard !done, let self, let i = self.index(of: group) else { return }
                self.data.conversations[i].shared?.previews?[id] = nil
            }
        }
    }

    private func erasePreview(_ link: JoinLink) {
        guard let slot = JoinSlot.keys(link.secret), let client = client(nil, lane: "join-\(link.id.uuidString.prefix(8))") else { return }
        Task {
            let (key, sig, ts) = SpareSlot.proof("pulshade.backup.del.v1", slot)
            try? await client.deleteBackup(key: key, sig: sig, ts: ts)
        }
    }

    // MARK: Reading requests and answers

    /// How often join and answer mailboxes are looked at while the app is open.
    static let joinPoll: TimeInterval = 15
    /// How long a request through an open link waits for the phone of the admin who made the link before another admin's
    /// phone lets them in instead (so two phones don't both do it).
    static let joinStandIn: TimeInterval = 120

    /// Housekeeping: the owner's phone seals the links' keys again when the admins change (and gives every link new keys
    /// when someone stops being an admin); the links are posted, signed afresh, into a new epoch's mailbox; asks still to
    /// go are sent and old ones dropped; and every join and answer mailbox this device looks after is read, each group's
    /// and each ask's on a connection of its own.
    func tendJoinLinks(force: Bool = false) {
        dropStaleOffers()
        let now = Date()
        for i in data.conversations.indices {
            guard let keys = amGroupAdmin(at: i), let shared = data.conversations[i].shared, let links = shared.links else { continue }
            let staff = Set(staffCards(at: i).map(\.signingKey))
            if shared.settings.owner == keys.publicKey, !links.links.isEmpty {
                let exposed = Set(shared.linksExposed ?? Array(links.sealedTo)).union(links.sealedTo)
                if !exposed.subtracting(staff).isEmpty {
                    // Someone who held the keys isn't an admin now: every link gets new keys.
                    var fresh: [UUID: LinkSecrets] = [:]
                    var renewed: [JoinLink] = []
                    for link in links.links {
                        guard var (next, secrets) = link.reset() else { continue }
                        next.creator = keys.publicKey
                        erasePreview(link)
                        renewed.append(next)
                        fresh[next.id] = secrets
                    }
                    data.conversations[i].shared?.linkSecrets = [:]
                    _ = publishLinks(at: i, adding: fresh) { $0.links = renewed }
                    writePreviews(at: i)
                    continue
                }
                // A new admin gets a copy (judged by who this phone sealed to, so an admin it can't seal to doesn't make it
                // post again and again).
                if !staff.subtracting(shared.linksSealedTo ?? Array(links.sealedTo)).isEmpty {
                    _ = publishLinks(at: i) { _ in }
                    continue
                }
            }
            // A new epoch: the links go into its mailbox too, signed afresh (by the owner's phone, or whoever signed last).
            if let current = shared.current?.number, shared.linksEpoch != current,
               shared.settings.owner == keys.publicKey || links.signer == keys.publicKey {
                _ = publishLinks(at: i) { _ in }
            }
        }
        // Only written when something goes: any write to `data`, even one that changes nothing, redraws every screen
        // that shows it, and this runs on every sync.
        if data.joinAsks.contains(where: { now.timeIntervalSince($0.asked) > JoinAsk.life }) {
            data.joinAsks.removeAll { now.timeIntervalSince($0.asked) > JoinAsk.life }
            save()
        }
        for ask in data.joinAsks where !ask.sent { sendAsk(ask.id) }
        guard force || now.timeIntervalSince(lastJoinPoll) >= Self.joinPoll else { return }
        lastJoinPoll = now
        for convo in data.conversations {
            guard let i = index(of: convo.id), amGroupAdmin(at: i) != nil, let links = convo.shared?.links else { continue }
            let secrets = heldSecrets(at: i)
            let served = links.links.compactMap { link in secrets[link.id].map { (link, $0) } }
            guard !served.isEmpty else { continue }
            readJoinMailboxes(convo.id, served)
        }
        for ask in data.joinAsks where ask.sent && !ask.declined { readAnswers(ask) }
    }

    private func readJoinMailboxes(_ group: UUID, _ served: [(JoinLink, LinkSecrets)]) {
        let lane = "joins|\(group.uuidString)"
        guard !joinPolling.contains(lane), let client = client(nil, lane: lane) else { return }
        joinPolling.insert(lane)
        let byMailbox = Dictionary(served.map { ($0.1.mailbox, $0) }, uniquingKeysWith: { a, _ in a })
        Task { [weak self] in
            let fetched = try? await client.fetch(Array(byMailbox.keys))
            guard let self else { return }
            self.joinPolling.remove(lane)
            // A fetch that failed says nothing about what's waiting: the held list stays as it is.
            guard let envelopes = fetched else { return }
            var done: [RelayEnvelope] = []
            var seen: [UUID: Set<Data>] = [:]
            var admitting: [(JoinRequest, UUID, RelayEnvelope)] = []
            var perMailbox: [Data: Int] = [:]
            for envelope in envelopes {
                guard let (link, secrets) = byMailbox[envelope.receiveKey] else { continue }
                perMailbox[envelope.receiveKey, default: 0] += 1
                switch self.readRequest(envelope, link: link, secrets: secrets, group: group) {
                case .done: done.append(envelope)
                case let .held(id): seen[link.id, default: []].insert(id)
                case .wait: break
                case let .admit(request): admitting.append((request, link.id, envelope))
                }
            }
            // Everyone let in this time goes in one change to the settings.
            if !admitting.isEmpty, let i = self.index(of: group),
               self.admitAll(admitting.map { ($0.0, $0.1) }, at: i) {
                done += admitting.map(\.2)
            }
            // Held requests no longer on the relay were decided by another admin (or ran out): they go here too. Only for a
            // mailbox the relay returned in full (it gives at most 64 at a time).
            if let i = self.index(of: group) {
                for (link, secrets) in served where link.approval && (perMailbox[secrets.mailbox] ?? 0) < 64 {
                    self.data.conversations[i].shared?.held?.removeAll { $0.request.link == link.id && !(seen[link.id] ?? []).contains($0.id) }
                }
            }
            if !done.isEmpty { try? await client.ack(done) }
            if !done.isEmpty || !seen.isEmpty || !admitting.isEmpty { self.save() }
        }
    }

    private func readAnswers(_ ask: JoinAsk) {
        let lane = "ask|\(ask.id.uuidString)"
        guard !joinPolling.contains(lane), let client = client(nil, lane: lane) else { return }
        joinPolling.insert(lane)
        let id = ask.id, reply = ask.reply
        Task { [weak self] in
            let envelopes = (try? await client.fetch([reply])) ?? []
            guard let self else { return }
            self.joinPolling.remove(lane)
            guard !envelopes.isEmpty else { return }
            for envelope in envelopes { self.readAnswer(envelope, ask: id) }
            try? await client.ack(envelopes)
        }
    }

    private enum RequestOutcome { case done, held(Data), wait, admit(JoinRequest) }

    /// How many people one link lets in on its own in an hour. Past it, requests wait for an admin's yes, as on a link
    /// that needs approval, so someone with the link can't fill the group (and its mailbox's daily allowance) with
    /// made-up members.
    static let admitsPerHour = 30

    /// A request through one of the group's links. Through an open link the phone of the admin who made it lets them in at
    /// once (another admin's after a couple of minutes); through one that needs approval it's kept for a yes; a banned key,
    /// or a link that's used up or past its date, gets "no"; anything not genuine is dropped.
    private func readRequest(_ envelope: RelayEnvelope, link: JoinLink, secrets: LinkSecrets, group: UUID) -> RequestOutcome {
        guard let i = index(of: group), let keys = amGroupAdmin(at: i), let shared = data.conversations[i].shared,
              let current = shared.links?.link(link.id), current.mailboxSendID == link.mailboxSendID else { return .done }
        let gid = data.conversations[i].wireID
        let cacheKey = "\(secrets.mailbox.hex)|\(envelope.id)"
        let request: JoinRequest
        if let known = joinOpened[cacheKey] {
            request = known
        } else {
            guard let requestKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secrets.requestKey),
                  let opened = JoinSeal.open(envelope.blob, with: requestKey), case let .request(found) = opened.mail,
                  found.group == gid, found.link == link.id, found.wellFormed,
                  opened.signer == found.card.signingKey, opened.agreement == found.card.agreementKey,
                  found.card.verified(group: gid), abs(opened.at.timeIntervalSinceNow) < 86_400 else { return .done }
            request = found
            if joinOpened.count >= 500, let oldest = joinOpened.keys.first { joinOpened[oldest] = nil }
            joinOpened[cacheKey] = found
        }
        // One already dealt with, sent again (by the relay, say): nothing more to do.
        let digest = Data(SHA256.hash(data: envelope.blob).prefix(16))
        if shared.handledJoins?.contains(digest) == true { return .done }
        let key = request.card.signingKey
        if shared.links?.bans.contains(key) == true { answer(.declined(group: gid), to: request, at: i); markHandled(digest, at: i); return .done }
        if shared.settings.isMember(key) {
            // In already: the answer may have gone astray, so it goes again, but only from the phone that lets people in
            // through this link and not more than once a day per person.
            if current.creator == keys.publicKey, let epoch = shared.current {
                answer(.admitted(GroupInvite(settings: shared.settings, epoch: epoch)), to: request, at: i, every: 86_400)
            }
            return .done
        }
        guard current.isOpen(), shared.settings.members.count < GroupSettings.maxMembers else {
            answer(.declined(group: gid), to: request, at: i)
            markHandled(digest, at: i)
            return .done
        }
        let recent = (joinAdmits[link.id] ?? []).filter { Date().timeIntervalSince($0) < 3600 }
        joinAdmits[link.id] = recent
        if current.approval || recent.count >= Self.admitsPerHour {
            var held = shared.held ?? []
            let id = HeldJoin(request: request, envelope: envelope.id, seen: Date()).id
            if let n = held.firstIndex(where: { $0.id == id }) {
                held[n].envelope = envelope.id
            } else {
                held.append(HeldJoin(request: request, envelope: envelope.id, seen: Date()))
                noteJoinRequest(at: i)
            }
            // At most so many per link: the oldest go first.
            let forLink = held.filter { $0.request.link == link.id }
            if forLink.count > HeldJoin.maxPerLink, let oldest = forLink.min(by: { $0.seen < $1.seen }) {
                held.removeAll { $0.id == oldest.id }
            }
            data.conversations[i].shared?.held = held
            return .held(id)
        }
        // Only one phone lets them in straight away: the leading device of the admin who made the link. Another of that
        // account's devices, or another admin's, steps in later if it hasn't.
        let first = current.creator == keys.publicKey
        if !first {
            if joinFirstSeen.count > 2_000 { joinFirstSeen = joinFirstSeen.filter { Date().timeIntervalSince($0.value) < 3600 } }
            let seenAt = joinFirstSeen[cacheKey] ?? Date()
            joinFirstSeen[cacheKey] = seenAt
            let wait = current.creator == keys.publicKey ? Self.joinStandIn / 2 : Self.joinStandIn
            guard Date().timeIntervalSince(seenAt) > wait else { return .wait }
        }
        markHandled(digest, at: i)
        return .admit(request)
    }

    /// Remembers a request as dealt with, for long enough that the relay can't replay it.
    private func markHandled(_ digest: Data, at i: Int) {
        var handled = data.conversations[i].shared?.handledJoins ?? []
        guard !handled.contains(digest) else { return }
        handled.append(digest)
        data.conversations[i].shared?.handledJoins = Array(handled.suffix(1_000))
    }

    /// Tells the admins a request is waiting, at most once every ten minutes per group, without the name the requester
    /// chose (it could say anything).
    private func noteJoinRequest(at i: Int) {
        let id = data.conversations[i].id
        guard !data.conversations[i].muted, data.security.notifications,
              Date().timeIntervalSince(joinNotified[id] ?? .distantPast) > 600 else { return }
        joinNotified[id] = Date()
        // The group's name only when notifications may show names: the system keeps this text outside the vault.
        let title = data.security.notificationContent == .hidden ? "PULSHADE" : data.conversations[i].title
        Notifier.shared.post((title, "Someone asked to join"), conversation: id, sound: data.security.notificationSound)
    }

    /// Puts everyone who asked (and may come in) into the group in one change to the settings, and tells each of them. A
    /// new epoch comes first, so they read from when they joined. False if they
    /// couldn't be added (the change wasn't one this account may make, or the settings would be too big).
    private func admitAll(_ requests: [(JoinRequest, UUID)], at i: Int) -> Bool {
        guard amGroupAdmin(at: i) != nil, var shared = data.conversations[i].shared else { return false }
        var seenKeys = Set<Data>()
        let fresh = requests.filter { request, _ in
            !shared.settings.isMember(request.card.signingKey) && seenKeys.insert(request.card.signingKey).inserted
        }
        guard !fresh.isEmpty else { return true }
        // A group's newcomers always start in a new epoch (see `invite`); none is let in if it couldn't be made.
        if shared.settings.kind == .group || shared.chatInEpoch {
            let before = shared.settings.epoch
            startEpoch(at: i, without: [])
            guard let updated = data.conversations[i].shared else { return false }
            shared = updated
            if shared.settings.kind == .group, shared.settings.epoch == before { return false }
        }
        var next = shared.settings
        let room = GroupSettings.maxMembers - next.members.count
        let taken = Array(fresh.prefix(max(0, room)))
        next.members += taken.map { $0.0.card.withoutAvatar }
        guard !taken.isEmpty, publishSettings(next, at: i), let settings = data.conversations[i].shared?.settings,
              let epoch = data.conversations[i].shared?.current else { return false }
        for (request, link) in taken {
            if let avatar = request.card.avatar { noteAvatar(avatar, of: request.card, at: i) }
            answer(.admitted(GroupInvite(settings: settings, epoch: epoch)), to: request, at: i)
            joinAdmits[link, default: []].append(Date())
        }
        let counts = Dictionary(grouping: taken, by: \.1).mapValues(\.count)
        _ = publishLinks(at: i) { links in
            for (link, count) in counts { if let n = links.links.firstIndex(where: { $0.id == link }) { links.links[n].used += count } }
        }
        return true
    }

    /// An admin says yes to a request waiting for approval (`HeldJoin.id`).
    func approveJoin(_ heldID: Data, in id: Conversation.ID) {
        decide(heldID, in: id, yes: true)
    }

    func declineJoin(_ heldID: Data, in id: Conversation.ID) {
        decide(heldID, in: id, yes: false)
    }

    private func decide(_ heldID: Data, in id: Conversation.ID, yes: Bool) {
        guard let i = index(of: id), amGroupAdmin(at: i) != nil,
              let held = data.conversations[i].shared?.held?.first(where: { $0.id == heldID }),
              let link = data.conversations[i].shared?.links?.link(held.request.link),
              let secrets = heldSecrets(at: i)[link.id] else { return }
        if yes, link.isOpen() {
            // Kept, and left on the relay, if they couldn't be added: nothing is lost.
            guard admitAll([(held.request, link.id)], at: i) else { return }
        } else {
            answer(.declined(group: data.conversations[i].wireID), to: held.request, at: i)
        }
        data.conversations[i].shared?.held?.removeAll { $0.id == heldID }
        save()
        // Let go of it on the relay, so the other admins' phones drop it too.
        guard let client = client(nil, lane: "joins|\(id.uuidString)") else { return }
        let envelope = RelayEnvelope(receiveKey: secrets.mailbox, id: held.envelope, blob: Data(), deposited: nil)
        Task { try? await client.ack([envelope]) }
    }

    /// Sends an answer to whoever asked, from this account's key in the group to theirs. It doesn't wake their phone (the
    /// mailbox is one they chose, and their app is looking for the answer), and the same person isn't answered again
    /// within ten minutes.
    private func answer(_ mail: JoinMail, to request: JoinRequest, at i: Int, every gap: TimeInterval = 600) {
        // By who asked (whatever mailbox they named, so asking with many mailboxes doesn't get many answers) and by the kind
        // of answer, so a yes doesn't hold back a later no.
        let kind: String
        switch mail {
        case .admitted: kind = "yes"
        case .declined: kind = "no"
        case .request: kind = "?"
        }
        let mark = request.card.signingKey.hex + "|" + kind
        guard Date().timeIntervalSince(joinAnswered[mark] ?? .distantPast) > gap,
              let keys = memberKeys(data.conversations[i].persona, group: data.conversations[i].wireID),
              let blob = JoinSeal.seal(mail, from: keys, to: request.card),
              let client = client(nil, lane: "joins|\(data.conversations[i].id.uuidString)") else { return }
        if joinAnswered.count > 2_000 { joinAnswered = joinAnswered.filter { Date().timeIntervalSince($0.value) < 86_400 } }
        joinAnswered[mark] = Date()
        let to = request.reply
        Task {
            for delay in [0.0, 5, 30] {
                try? await Task.sleep(for: .seconds(delay))
                if (try? await client.deposit(blob, to: to, wake: false)) != nil { return }
            }
        }
    }

    // MARK: Asking to join

    /// Reads a link's preview from the relay and checks it's from the admin the link names.
    func previewGroup(_ code: GroupLinkCode) async -> GroupPreview? {
        guard let slot = JoinSlot.keys(code.secret), let client = client(nil, lane: "join-preview|\(UUID().uuidString)") else { return nil }
        let (key, sig, ts) = SpareSlot.proof("pulshade.backup.get.v1", slot)
        guard let blob = try? await client.backup(key: key, sig: sig, ts: ts, limit: JoinSlot.maxBlob), let preview = JoinSlot.open(blob, with: slot),
              preview.verified(by: code) else { return nil }
        return preview
    }

    /// Whether you're already in the group a preview is for, as this persona.
    func isInGroup(_ preview: GroupPreview, persona: UUID?) -> Bool {
        guard let i = groupIndex(preview.group, persona: persona) else { return false }
        return data.conversations[i].shared.map { !$0.gone } == true
    }

    /// The conversation for a group you're in as this persona, if any.
    func conversationID(forGroup group: UUID, persona: UUID?) -> Conversation.ID? {
        groupIndex(group, persona: persona).map { data.conversations[$0].id }
    }

    /// Asks to join, as `persona`, with a key made for this group alone. The answer comes to a mailbox made for it.
    func askToJoin(_ preview: GroupPreview, note: String = "", persona: UUID?) {
        guard !isInGroup(preview, persona: persona),
              !data.joinAsks.contains(where: { $0.group == preview.group && $0.persona == persona && !$0.declined }),
              let keys = memberKeys(persona, group: preview.group), var card = myCard(persona, group: preview.group) else { return }
        if (card.avatar?.count ?? 0) > 16 * 1024 { card.avatar = nil }
        let reply = Data.random(32)
        let words = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = JoinRequest(group: preview.group, link: preview.link, card: card, reply: Mailbox.sendID(for: reply),
                                  note: words.isEmpty ? nil : String(words.prefix(200)), at: RelayClock.now)
        guard let blob = JoinSeal.seal(.request(request), from: keys, to: preview.requestKey) else { return }
        data.joinAsks.removeAll { $0.group == preview.group && $0.persona == persona }
        let ask = JoinAsk(group: preview.group, persona: persona, title: preview.title, avatar: preview.avatar, approval: preview.approval,
                          reply: reply, request: blob, mailbox: preview.mailbox, owner: preview.owner, staff: Array(preview.staff))
        data.joinAsks.append(ask)
        save()
        sendAsk(ask.id)
    }

    func cancelJoinAsk(_ id: UUID) {
        data.joinAsks.removeAll { $0.id == id }
        save()
    }

    private func sendAsk(_ id: UUID) {
        guard !joinSending.contains(id), let ask = data.joinAsks.first(where: { $0.id == id }), !ask.sent,
              let client = client(nil, lane: "ask|\(id.uuidString)") else { return }
        joinSending.insert(id)
        Task { [weak self] in
            let sent = (try? await client.deposit(ask.request, to: ask.mailbox, wake: true)) != nil
            guard let self else { return }
            self.joinSending.remove(id)
            guard sent, let n = self.data.joinAsks.firstIndex(where: { $0.id == id }) else { return }
            self.data.joinAsks[n].sent = true
            self.save()
            self.tendJoinLinks(force: true)
        }
    }

    /// An answer to one of your asks: in, with what's needed to read the group, or turned down. Taken only from the owner
    /// or an admin the preview named, with settings one of them signed that keep the same owner, so whoever else got hold
    /// of the link can't hand you a group of their own.
    private func readAnswer(_ envelope: RelayEnvelope, ask id: UUID) {
        guard let n = data.joinAsks.firstIndex(where: { $0.id == id }) else { return }
        let ask = data.joinAsks[n]
        let staff = Set(ask.staff + [ask.owner])
        guard let keys = memberKeys(ask.persona, group: ask.group), let opened = JoinSeal.openAnswer(envelope.blob, with: keys),
              staff.contains(opened.signer) else { return }
        switch opened.mail {
        case let .declined(group) where group == ask.group:
            data.joinAsks[n].declined = true
        case let .admitted(invite):
            let s = invite.settings
            guard s.group == ask.group, s.kind == .group, s.owner == ask.owner, staff.contains(s.signer), s.signatureIsValid, s.wellFormed(),
                  s.isAdmin(s.signer), s.isAdmin(opened.signer), s.isMember(keys.publicKey),
                  invite.epoch.isValid, s.epoch == invite.epoch.number, s.epochCheck == invite.epoch.check,
                  joinedThroughLink(invite, persona: ask.persona) else { return }
            data.joinAsks.removeAll { $0.id == id }
        default:
            break
        }
        save()
    }

    /// In through a link: the group is added (or, if you'd been in it before, picked up again), already a member. A group
    /// you're in now only moves on to settings that follow from the ones held; one you'd left only comes back under the
    /// same owner. False if the answer couldn't be taken.
    private func joinedThroughLink(_ invite: GroupInvite, persona: UUID?) -> Bool {
        let s = invite.settings
        if let i = groupIndex(s.group, persona: persona) {
            // An older-style group under the same id is never taken over this way.
            guard data.conversations[i].kind == .group, data.conversations[i].shared != nil else { return false }
            if var shared = data.conversations[i].shared, !shared.gone {
                guard s == shared.settings || shared.settings.accepts(s) || shared.settings.acceptsJump(s) else { return false }
                install(invite.epoch, in: &shared)
                if s != shared.settings { shared.previous = shared.settings }
                shared.settings = s
                shared.joining = false
                shared.missedKey = false
                data.conversations[i].shared = shared
            } else {
                guard let old = data.conversations[i].shared, old.settings.owner == s.owner else { return false }
                // Left (or was taken out) before: back in, with only what the group says now.
                data.conversations[i].shared = SharedGroup(settings: s, epochs: [invite.epoch])
                withAnimation(.snappy) { data.conversations[i].messages.append(Message(sender: "system", text: "You joined again", date: Date())) }
            }
            applySharedSettings(at: i)
        } else {
            let place = newGroupPlace(s.group, persona: persona)
            var convo = Conversation(id: place.id, kind: .group, title: String(s.title.prefix(80)), avatar: s.avatar, members: [])
            convo.groupID = place.groupID
            convo.persona = persona
            convo.shared = SharedGroup(settings: s, epochs: [invite.epoch])
            withAnimation(.snappy) { data.conversations.insert(convo, at: 0) }
            if let i = groupIndex(s.group, persona: persona) {
                applySharedSettings(at: i)
            }
        }
        return true
    }
}

// MARK: - Friends from groups

/// Becoming friends with someone you only share a group with. They're sent a one-time invite code for your account, sealed
/// so only they can open it, through the group's mailbox to their key in that group. Accepting it is the same as scanning the code. Nothing reaches anyone else in the group but that something was sent.
extension AppModel {
    enum FriendState: Equatable { case me, friend, asked, canAsk, unknown }

    /// Where you stand with someone in a chat, for the profile's button.
    func friendState(of fingerprint: String, in convo: Conversation) -> FriendState {
        if fingerprint == "me" || myFingerprints.contains(fingerprint) { return .me }
        guard let c = contact(fingerprint, in: convo.persona) else { return .unknown }
        if !c.hidden && !c.awaitingAcceptance { return .friend }
        if c.awaitingAcceptance || friendAsked.contains(friendKey(fingerprint, convo.persona)) { return .asked }
        return convo.kind == .group && convo.shared != nil ? .canAsk : .unknown
    }

    private func friendKey(_ fingerprint: String, _ persona: UUID?) -> String { "\(persona?.uuidString ?? "main")|\(fingerprint)" }

    /// Asks someone from a group to be friends, as the persona that's in the group.
    func addFriend(_ fingerprint: String, in id: Conversation.ID, note: String = "") {
        guard let i = index(of: id), let c = contact(fingerprint, in: data.conversations[i].persona) else { return }
        let convo = data.conversations[i]
        guard friendState(of: fingerprint, in: convo) == .canAsk else { return }
        friendAsked.insert(friendKey(fingerprint, convo.persona))
        let words = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = words.isEmpty ? nil : String(words.prefix(200))
        sendFriendInvite(to: fingerprint, at: id, note: trimmed)
    }

    private func sendFriendInvite(to fingerprint: String, at id: Conversation.ID, note: String?) {
        guard let i = index(of: id), let c = contact(fingerprint, in: data.conversations[i].persona) else { return }
        let persona = data.conversations[i].persona
        let code = makeInviteCode(persona: .some(persona))
        guard !code.isEmpty else { return }
        guard data.conversations[i].shared != nil, let keys = memberKeys(persona, group: data.conversations[i].wireID),
              let body = try? JSONEncoder.pulshade.encode(FriendInviteBody(code: code, note: note)),
              let sealed = try? EnvelopeCore.seal(body: body, framed: false, signing: keys.signing, agreement: keys.agreement,
                                                 device: Data(), caps: 0, at: RelayClock.now, to: c.agreementKey) else { return }
        post(.friendAsk(to: c.signingKey, sealed: sealed), at: i)
        save()
    }

    /// An invite to be friends arrived from someone in a group: kept until you answer, and you're told.
    private func noteFriendInvite(_ body: FriendInviteBody, from fp: String, persona: UUID?, group: UUID?) {
        guard let invite = Invite(code: body.code), invite.kind == .contact, !myFingerprints.contains(invite.fingerprint),
              !data.blocked.contains(fp), !data.blocked.contains(invite.fingerprint),
              contact(invite.fingerprint, in: persona).map({ $0.hidden || $0.awaitingAcceptance }) ?? true else { return }
        let sender = contact(fp, in: persona)
        let title = group.flatMap { conversation($0)?.title } ?? "a group"
        data.friendInvites.removeAll { $0.from == fp && $0.persona == persona }
        data.friendInvites.insert(GroupFriendInvite(persona: persona, group: group, groupTitle: title, from: fp,
                                                    name: String((sender?.displayName ?? "Someone").prefix(64)), avatar: sender?.avatar,
                                                    code: body.code, note: body.note.map { String($0.prefix(200)) }), at: 0)
        if data.friendInvites.count > GroupFriendInvite.max { data.friendInvites.removeLast(data.friendInvites.count - GroupFriendInvite.max) }
        save()
        if data.security.notifications {
            // Names only when notifications may show them: the system keeps this text outside the vault.
            let words = data.security.notificationContent == .hidden || persona != activePersona ? "New friend request"
                : "\(sender?.displayName ?? "Someone") from \(title) wants to be friends"
            Notifier.shared.post(("PULSHADE", words), conversation: group ?? UUID(), sound: data.security.notificationSound)
        }
    }

    // MARK: Group and channel invites waiting for a yes

    /// Invites past their time are let go (housekeeping), with the group keys they hold.
    private func dropStaleOffers() {
        // Only written when one goes (see `tendJoinLinks`): this runs on every sync.
        let now = Date()
        guard data.groupOffers.contains(where: { now.timeIntervalSince($0.at) >= GroupOffer.life }) else { return }
        data.groupOffers.removeAll { now.timeIntervalSince($0.at) >= GroupOffer.life }
        save()
    }

    var groupOffers: [GroupOffer] {
        data.groupOffers.filter { $0.persona == activePersona && Date().timeIntervalSince($0.at) < GroupOffer.life }
    }

    private static func followKey(_ fp: String, _ persona: UUID?) -> String { "\(persona?.uuidString ?? "")|\(fp)" }
    private static let followAskLife: TimeInterval = 14 * 86_400

    /// The hellos for more of someone's channel codes, held until their post-quantum keys were known (`Contact.followLater`).
    private func sendFollowsLater(_ fp: String, persona: UUID?) {
        // Only onto the contact as it is (devices and a mailbox to name): otherwise a held code would start them over.
        guard let i = contactIndex(fp, persona), let codes = data.contacts[i].followLater, data.contacts[i].pq != nil,
              !data.contacts[i].devices.isEmpty, data.contacts[i].receiveKey != nil else { return }
        data.contacts[i].followLater = nil
        for code in codes { addContact(code: code, nickname: "", persona: .some(persona)) }
        save()
    }

    /// You followed this person's channel code: the invite for that code's channel is taken without asking again.
    private func noteFollowAsked(_ fp: String, persona: UUID?, tag: Data, channel: Data?) {
        pruneFollowsAsked()
        let key = Self.followKey(fp, persona)
        let held = (data.followsAsked[key] ?? []).filter { $0.tag != tag }
        data.followsAsked[key] = Array((held + [FollowedCode(tag: tag, at: Date(), channel: channel)]).suffix(4))
    }

    /// Lets go of codes followed more than two weeks ago, each by its own time.
    private func pruneFollowsAsked() {
        let now = Date()
        data.followsAsked = data.followsAsked
            .mapValues { $0.filter { now.timeIntervalSince($0.at) < Self.followAskLife } }
            .filter { !$0.value.isEmpty }
    }

    enum FollowMatch { case none, matched, untagged }

    /// Whether an invite from this person is for a channel whose code you followed lately. `.matched` when it carries
    /// that code's tag and is for the very channel the code names (`Invite.channelCommit`), which uses that follow up.
    /// `.untagged` when it carries no tag (their app is older, so it can't say which channel), when the code named no
    /// channel (a code from an older app), or when it names another channel than the invite is for: asked about, and
    /// nothing used up, since there's no telling which follow it answers; the follows still wait for their own channels'
    /// invites, and the offer limits (`GroupOffer.perSender`) bound what such invites can do. An invite naming another
    /// code, or a tag that isn't one, uses nothing up and isn't taken.
    private func takeFollowAsked(_ fp: String, persona: UUID?, tag: Data?, group: UUID) -> FollowMatch {
        pruneFollowsAsked()
        let key = Self.followKey(fp, persona)
        guard var held = data.followsAsked[key] else { return .none }
        guard let tag else { return .untagged }
        guard tag.count == 16, let n = held.firstIndex(where: { $0.tag == tag }) else { return .none }
        guard held[n].channel == Invite.channelCommit(group) else { return .untagged }
        held.remove(at: n)
        data.followsAsked[key] = held.isEmpty ? nil : held
        return .matched
    }

    /// A channel invite from an app too old to vouch for its sender: said once in the chat with a friend who sent it.
    private func noteChannelInviteTooOld(from sender: Contact) {
        guard !sender.hidden, !sender.awaitingAcceptance else { return }
        let convo = startConversation(kind: .direct, title: "", members: [sender.fingerprint], persona: .some(sender.persona))
        guard let c = index(of: convo.id) else { return }
        let text = "\(sender.displayName) invited you to a channel, but their app is too old for it. They need to update PULSHADE."
        guard data.conversations[c].messages.last?.text != text else { return }
        data.conversations[c].messages.append(Message(sender: "system", text: text, date: Date()))
    }

    /// An invite to a group or channel you aren't in: kept, without joining anything, until you answer.
    private func noteGroupOffer(_ invite: GroupInvite, from sender: Contact, followed: Bool = false) {
        guard !data.blocked.contains(sender.fingerprint), !sender.hidden || followed else { return }
        let s = invite.settings
        data.groupOffers.removeAll {
            Date().timeIntervalSince($0.at) >= GroupOffer.life
                || ($0.invite.settings.group == s.group && $0.persona == sender.persona && $0.from == sender.fingerprint)
        }
        // A few from any one person at a time: one friend can't push everyone else's out.
        let theirs = data.groupOffers.filter { $0.from == sender.fingerprint && $0.persona == sender.persona }
        if theirs.count >= GroupOffer.perSender, let oldest = theirs.last { data.groupOffers.removeAll { $0.id == oldest.id } }
        let isNew = !data.groupOffers.contains { $0.invite.settings.group == s.group && $0.persona == sender.persona }
        data.groupOffers.insert(GroupOffer(persona: sender.persona, from: sender.fingerprint,
                                               name: String(sender.displayName.prefix(64)), avatar: sender.avatar,
                                               title: String(s.title.prefix(80)), invite: invite), at: 0)
        if data.groupOffers.count > GroupOffer.max { data.groupOffers.removeLast(data.groupOffers.count - GroupOffer.max) }
        save()
        let now = Date()
        offerNotices = offerNotices.filter { now.timeIntervalSince($0) < 3600 }
        if isNew, data.security.notifications, offerNotices.count < Self.offerNoticesPerHour {
            offerNotices.append(now)
            // Names only when notifications may show them, and only for the persona in use: one shown while another is
            // would tell whoever sees the screen who that persona knows.
            let words = data.security.notificationContent == .hidden || sender.persona != activePersona ? "New invite"
                : "\(sender.displayName) invites you to \(s.kind == .channel ? "follow" : "join") \(s.title)"
            Notifier.shared.post(("PULSHADE", String(words.prefix(160))), conversation: s.group, sound: data.security.notificationSound)
        }
    }

    /// Says yes to one invite: the group is joined, or the channel followed, through the person who sent it and nobody else.
    func acceptGroupOffer(_ id: UUID) {
        guard let offer = data.groupOffers.first(where: { $0.id == id }) else { return }
        data.groupOffers.removeAll { $0.invite.settings.group == offer.invite.settings.group && $0.persona == offer.persona }
        if let sender = contact(offer.from, in: offer.persona) { acceptGroupInvite(offer.invite, from: sender, consented: true) }
        save()
    }

    func declineGroupOffer(_ id: UUID) {
        data.groupOffers.removeAll { $0.id == id }
        save()
    }

    /// Says yes: their invite code is used, as if scanned, under the persona they asked.
    @discardableResult
    func acceptFriendInvite(_ id: UUID) -> Contact? {
        guard let invite = data.friendInvites.first(where: { $0.id == id }) else { return nil }
        data.friendInvites.removeAll { $0.id == id }
        let contact = addContact(code: invite.code, nickname: "", persona: .some(invite.persona))
        save()
        return contact
    }

    func declineFriendInvite(_ id: UUID) {
        data.friendInvites.removeAll { $0.id == id }
        save()
    }
}

