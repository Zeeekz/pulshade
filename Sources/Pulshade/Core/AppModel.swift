import Foundation
import CryptoKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif
#if os(macOS)
import AppKit
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
    @ObservationIgnored private var clipActivity: [UUID: Date] = [:]
    /// How often a stalled video has been asked for again, and when last.
    @ObservationIgnored private var clipAsks: [UUID: (count: Int, at: Date)] = [:]
    /// When a video was last sent again on someone's asking, as "fingerprint|id", so one asking can't make it
    /// go over and over.
    @ObservationIgnored private var clipResent: [String: Date] = [:]
    var failedAttempts = 0
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
    private var activityMonitor: Any?
    private var lastActivity = Date()
    private var profileTask: Task<Void, Never>?

    /// The colour theme isn't secret, so it's mirrored outside the vault to tint the lock screen.
    var theme: Theme {
        Theme.named(phase == .unlocked ? data.theme : UserDefaults.standard.string(forKey: "pulshade.theme") ?? "")
    }

    init(vault: Vault = .standard, watchSystem: Bool = true) {
        self.vault = vault
        phase = vault.exists ? .locked : .welcome
        Ink.source = { [weak self] in self?.theme ?? .dark }
        guard watchSystem else { return }
        // Tor takes a moment to connect: start it now, in the background, so it's ready by the first request.
        let onionOnly = URL(string: AppData.defaultRelay).map(Tor.isOnion) == true && AppData.directRelay == nil
        if Tor.enabled || onionOnly {
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
    nonisolated static func reach(_ client: RelayClient) async -> Bool {
        guard Tor.uses(client.base) else { return await client.health() }
        // A route into an onion service usually connects in seconds, but now and then one gets stuck for good, and
        // through a bridge or on a slow network that's common. So the first attempt keeps going (it may yet get
        // there) while fresh routes join it: one after 5 seconds on a lane that has worked before; on one that
        // hasn't, where everything is slower, two, further apart. Whichever answers first wins.
        let joins: [Double] = client.isEstablished ? [5] : [20, 50]
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
        // Requests left open would only time out while the app is suspended, and look like the relay failing on
        // the way back. Anything unsent waits in the outbox.
        RelayClient.closeAll()
        #endif
    }

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

    /// Any touch counts as activity on iPhone.
    func noteActivity() { lastActivity = Date() }

    // MARK: Identity lifecycle

    func create(identity: Identity, profile: Profile, passcode: String) async throws {
        let vault = vault
        try await Task.detached { try vault.create(identity, passcode: passcode) }.value
        self.identity = identity
        slot = 0
        data = AppData()
        data.profile = profile
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
        didUnlock()
        // It's on this device now. An old copy left behind could only fall out of step.
        if backup != nil { Task { try? await deleteBackup(of: identity) } }
    }

    func unlock(passcode: String) async -> Bool {
        // Each wrong guess makes the next one wait longer.
        if failedAttempts > 2 {
            try? await Task.sleep(for: .seconds(min(30, 1 << (failedAttempts - 2))))
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
                try? await Task.detached { try vault.panic(keeping: landing, slot: slot, passcode: passcode) }.value
                Notifier.shared.clearAll()
                // The real account's mailboxes can't be named any more: take this phone's token off the relay instead.
                withdrawPush()
                self.identity = landing
                self.slot = 0
                data = (try? vault.load(with: landing)) ?? AppData()
            }
            failedAttempts = 0
            didUnlock()
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
        data.stories.removeAll { !$0.isLive }
        data.seenEnvelopes = data.seenEnvelopes.filter { $0.value > Date().addingTimeInterval(-Self.replayWindow) }
        // Unused contact invites die with the relay's 7-day retention.
        data.invites.removeAll { $0.channel == nil && !$0.isPublic && $0.createdAt < Date().addingTimeInterval(-7 * 24 * 3600) }
        data.invites.removeAll { ($0.retiresAt ?? .distantFuture) < Date() }
        UserDefaults.standard.set(data.theme, forKey: "pulshade.theme")
        save()
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
        // Ask straight away, and again until it answers, so the wait is only as long as Tor needs.
        Task { [weak self] in
            while let self, self.connecting, self.phase == .unlocked, let client = self.client(nil) {
                self.noteRelay(reached: await Self.reach(client))
                if self.connecting { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        startSync()
        startTicking()
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
                for c in contacts(of: persona) { enqueue(profilePayload(persona), to: c) }
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
        link = .offline
        openConversation = nil
        Platform.setBadge(0)
        withAnimation(.smooth(duration: 0.5)) { phase = .locked }
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
        syncTask?.cancel()
        tickTask?.cancel()
        vault.destroy(leavingNoTrace: leavingNoTrace)
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
        withAnimation(.smooth(duration: 0.6)) { phase = .welcome }
    }

    /// Whoever opens Pulshade next starts on new Tor circuits and new connections, so the relay can't tie two
    /// accounts on this device together by the circuit their requests share.
    private func forgetRoutes() {
        Tor.newRoutes()
        RelayClient.closeAll(finishing: !cutOffOnLock)
    }

    func save() {
        guard let identity else { return }
        try? vault.save(data, with: identity)
        updateBadge()
        AnnouncementWatch.mirror(.init(notifications: data.security.notifications, content: data.security.notificationContent,
                                       sound: data.security.notificationSound,
                                       muted: conversation(Conversation.announcementsID)?.muted ?? false))
    }

    private func updateBadge() {
        Platform.setBadge(unreadTotal)
    }

    var unreadTotal: Int {
        data.conversations.filter { !$0.muted }.reduce(0) { $0 + $1.unread }
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
        guard data.security.notifications, !convo.muted else { return }
        if appActive && openConversation == convo.id { return }
        #if os(iOS)
        // On the phone, a message that lands while Pulshade is open is already in front of you (and counted on the
        // list). A banner on top of that, after the wake-up banner from the lock screen, would be a second one.
        if appActive { return }
        #endif
        let content = Notifier.content(for: message, in: convo, sender: displayName(message.sender),
                                       style: data.security.notificationContent)
        Notifier.shared.post(content, conversation: convo.id, sound: data.security.notificationSound)
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
        upsert(contact)
        syncContact(contact.fingerprint, contact.persona)
        seal(.hello(card(sendID: mailbox.sendID, persona: owner), request), to: contact.fingerprint, persona: owner)
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

    private func card(sendID: Data, persona: UUID?) -> PeerCard {
        let profile = profile(for: persona), keys = me(persona)!.card
        return PeerCard(name: profile.name, avatar: profile.avatar, color: profile.color,
                        signingKey: keys.signing, agreementKey: keys.agreement, sendID: sendID, device: deviceID(for: persona))
    }

    /// The notes of a profile that are worth sending: checked again, none if there are none.
    static func sharedNotes(_ profile: Profile) -> [ProfileNote]? {
        let notes = ProfileNote.cleaned(profile.notes)
        return notes.isEmpty ? nil : notes
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

    private func profilePayload(_ persona: UUID?) -> Payload {
        let profile = profile(for: persona)
        return .profile(name: profile.name, avatar: profile.avatar, color: profile.color, banner: profile.banner,
                        bio: profile.bio.flatMap { $0.isEmpty ? nil : $0 }, handle: profile.handle, badge: profile.badge,
                        links: Self.sharedLinks(profile), collectibles: Self.sharedCollectibles(profile),
                        notes: Self.sharedNotes(profile))
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
              quote: ReplyRef? = nil, preview: LinkPreview? = nil, in id: Conversation.ID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil || voice != nil, let i = index(of: id) else { return }
        let convo = data.conversations[i]
        guard canPost(in: convo) else { return }

        let now = Date()
        let reply = replyTo.map { ReplyRef(id: $0.id, author: $0.sender, snippet: Self.snippet(of: $0)) } ?? quote
        let message = Message(sender: "me", text: trimmed, image: image, voice: voice, date: now,
                              expiresAt: convo.disappearAfter.map { now.addingTimeInterval($0) }, reply: reply,
                              preview: preview)
        withAnimation(.snappy(duration: 0.4)) { data.conversations[i].messages.append(message) }

        let wire = WireMessage(id: message.id, conversation: sharedID(convo), kind: convo.kind == .broadcast ? .direct : convo.kind,
                               text: trimmed, image: image, voice: voice, date: RelayClock.relay(now), expiresIn: convo.disappearAfter,
                               reply: reply.map { ReplyRef(id: $0.id, author: $0.author == "me" ? (me(convo.persona)?.fingerprint ?? "") : $0.author,
                                                           snippet: $0.snippet, picture: $0.picture) },
                               preview: preview)
        let recipients = audience(convo)
        for member in recipients { enqueue(.message(wire), to: member, message: message.id) }
        sync(.sent(ref(convo), wire))
        if recipients.isEmpty { setStatus(.sent, for: [message.id]) }
        lastTypingSent[id] = nil
        save()
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
        if like, let i = data.stories.firstIndex(where: { $0.id == story.id }) {
            data.stories[i].liked = true
            save()
        }
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
            guard !data.isEmpty, let url = StoryVideo.tempFile(for: data) else { return nil }
            defer { try? FileManager.default.removeItem(at: url) }
            image = await StoryVideo.poster(of: url).map { PlatformImage.from(cgImage: $0) }
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

    // MARK: Unsend, reactions, typing, timers

    func unsend(_ messageID: UUID, in id: Conversation.ID) {
        guard let i = index(of: id) else { return }
        let convo = data.conversations[i]
        guard convo.messages.contains(where: { $0.id == messageID && $0.isMine }) else { return }
        withAnimation(.snappy) { data.conversations[i].messages.removeAll { $0.id == messageID } }
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
            withAnimation(.smooth) { data.conversations[i].messages.removeAll { ($0.expiresAt ?? .distantFuture) <= now } }
            changed = true
        }
        // Stories past their time go from the vault too, not just from view, and so do old removal notes.
        if data.stories.contains(where: { !$0.isLive }) {
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
            for message in convo.messages.filter({ !$0.isMine }).suffix(convo.unread) { queueReceipt(message.id, to: sender, read: true) }
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

    /// Sends a story to one contact. A video goes as the story with an empty clip, then (for people who don't
    /// have the clip yet) the clip in pieces that each fit one relay message.
    private func sendStory(_ story: Story, to contact: Contact, withClip: Bool) {
        guard case let .video(clip, caption) = story.style else { enqueue(storyPayload(story), to: contact); return }
        enqueue(.story(id: story.id, style: .video(Data(), caption: caption), date: RelayClock.relay(story.date),
                       lasts: story.lifetime), to: contact)
        guard withClip else { return }
        let pieces = StoryClipPieces.split(clip)
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
        let pieces = StoryClipPieces.split(clip)
        let indices = wanted.map { Set($0).filter(pieces.indices.contains).sorted() } ?? Array(pieces.indices)
        for i in indices {
            enqueue(.storyPart(id: story.id, index: i, of: pieces.count, bytes: pieces[i]), to: contact)
        }
    }

    /// A video that has stopped arriving part-way: with nothing new for a while, whoever posted it is asked for
    /// what's missing. A few times at most, further apart each time, while the story is still up.
    private func askForStalledClips() {
        let now = Date()
        var stalled = Set(data.clipParts.keys)
        for story in data.stories where story.author != "me" && story.isLive && !story.isReady { stalled.insert(story.id) }
        for id in stalled {
            let story = data.stories.first { $0.id == id }
            let parts = data.clipParts[id]
            guard let author = story?.author ?? parts?.author, author != "me",
                  removedStories["\(author)|\(id)"] == nil else { continue }
            if story.map({ $0.isLive && !$0.isReady }) == false { continue }
            // Seen for the first time since launch: the wait starts now.
            guard let last = clipActivity[id] else { clipActivity[id] = now; continue }
            let asked = clipAsks[id]
            let tries = asked?.count ?? 0
            guard tries < Self.clipAskLimit, now.timeIntervalSince(last) >= clipQuiet,
                  now.timeIntervalSince(asked?.at ?? .distantPast) >= clipQuiet * Double(1 << tries),
                  let contact = contact(author, in: story?.persona ?? parts?.persona) else { continue }
            let missing = parts.map { p in (0..<p.of).filter { p.parts[$0] == nil } }
            clipAsks[id] = (tries + 1, now)
            enqueue(.storyWant(id: id, parts: missing), to: contact)
        }
    }

    /// How long a video has to go without a new piece before it's asked for again, and how many times it is.
    @ObservationIgnored var clipQuiet: TimeInterval = 90
    static let clipAskLimit = 4

    /// Joins a clip's pieces into its story once the story and every piece are here.
    private func assembleClip(_ id: UUID) {
        guard let pending = data.clipParts[id], pending.isComplete,
              let i = data.stories.firstIndex(where: { $0.id == id && $0.author == pending.author && $0.persona == pending.persona }),
              case let .video(have, caption) = data.stories[i].style, have.isEmpty else { return }
        let joined = (0..<pending.of).reduce(into: Data()) { $0.append(pending.parts[$1] ?? Data()) }
        data.clipParts[id] = nil
        clipActivity[id] = nil
        clipAsks[id] = nil
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
            let waiting = audience(of: story).filter { !delivery.confirmed.contains($0.fingerprint) }
            delivery.last = now
            // Everyone has it: nothing left to do for this one.
            delivery.resends = waiting.isEmpty ? Self.storyRetry.count : delivery.resends + 1
            data.stories[i].delivery = delivery
            // A video's clip is heavy: it goes again only the first couple of times.
            for c in waiting { sendStory(story, to: c, withClip: delivery.resends <= 2) }
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
        for c in self.audience(of: story) { sendStory(story, to: c, withClip: true) }
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
        for c in after { sendStory(story, to: c, withClip: !before.contains { $0.fingerprint == c.fingerprint }) }
        trackUpload(of: id)
        if story.isSyncable { var shared = story; shared.delivery = nil; sync(.story(shared)) }
        save()
    }

    func deleteStory(_ id: Story.ID) {
        guard let story = data.stories.first(where: { $0.id == id && $0.author == "me" }) else { return }
        withAnimation(.snappy) { data.stories.removeAll { $0.id == id } }
        noteRemoved("me|\(id)")
        for c in audience(of: story) { enqueue(.storyRemoved(id: id), to: c) }
        sync(.storyRemoved(id))
        save()
    }

    /// The first time you see someone's story, they're told (with story views on, and never from a one-time chat).
    func markSeen(_ id: Story.ID) {
        guard let i = data.stories.firstIndex(where: { $0.id == id }), !data.stories[i].seen else { return }
        data.stories[i].seen = true
        let story = data.stories[i]
        if story.author != "me", data.security.storyViews,
           data.personas.first(where: { $0.id == story.persona })?.oneTimeChat != true,
           let author = contact(story.author, in: story.persona), !author.hidden {
            enqueue(.storyViewed(id: id), to: author)
        }
        save()
    }

    /// How many copies of a story were waiting to go out when it was posted or last changed.
    private var storyUploadTotal: [Story.ID: Int] = [:]

    /// Copies of a story not yet handed to the relay: still waiting for a session, or sealed and queued.
    private func unsentCopies(of id: Story.ID) -> Int {
        let waiting = data.contacts.reduce(0) { n, c in
            n + c.devices.reduce(0) { $0 + $1.pending.filter { $0.payload.storyID == id }.count }
        }
        return waiting + data.outbox.filter { $0.story == id }.count
    }

    private func trackUpload(of id: Story.ID) {
        let n = unsentCopies(of: id)
        if n > 0 { storyUploadTotal[id] = n } else { storyUploadTotal[id] = nil }
    }

    /// How far a story you posted has got to its audience, 0...1, or nil once it's all gone (or never needed to).
    func uploadProgress(of id: Story.ID) -> Double? {
        guard let total = storyUploadTotal[id] else { return nil }
        let left = unsentCopies(of: id)
        guard left > 0 else { return nil }
        return 1 - Double(left) / Double(max(total, left))
    }

    /// Your stories on screen: any still going out, and whether any has yet to be viewed by anyone.
    var storyUpload: Double? {
        let all = myStories.compactMap { uploadProgress(of: $0.id) }
        return all.isEmpty ? nil : all.reduce(0, +) / Double(all.count)
    }

    var hasUnviewedStory: Bool {
        data.security.storyViews && myStories.contains { ($0.viewers ?? [:]).isEmpty && !audience(of: $0).isEmpty }
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

    /// Who viewed one of your stories, most recent first. Empty with story views off.
    func viewers(of id: Story.ID) -> [(fingerprint: String, at: Date)] {
        guard data.security.storyViews, let story = data.stories.first(where: { $0.id == id && $0.author == "me" }) else { return [] }
        return (story.viewers ?? [:]).map { ($0.key, $0.value) }.sorted { $0.at > $1.at }
    }

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
        withAnimation(.smooth(duration: 0.4)) { data.activePersona = id }
        save()
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
        retirePublicInvites(of: persona, except: key)
        if let i = data.invites.firstIndex(where: { $0.receiveKey == key }) {
            data.invites[i].retiresAt = nil
            return data.invites[i]
        }
        let invite = OpenInvite(receiveKey: key, persona: persona, isPublic: true)
        data.invites.append(invite)
        return invite
    }

    private func retirePublicInvites(of persona: UUID?, except key: Data) {
        for i in data.invites.indices where data.invites[i].isPublic && data.invites[i].persona == persona
            && data.invites[i].receiveKey != key && data.invites[i].retiresAt == nil {
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

    /// Lists the active persona under @handle so anyone who knows it can send a request.
    func publishProfile(handle raw: String) async throws {
        guard let handle = DirectoryProfile.validHandle(raw) else { throw DirectoryError.invalidHandle }
        guard let client = client(nil) else { throw DirectoryError.unreachable }
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
        }
        var profile = profile(for: persona)
        if let old = profile.handle, old != handle { await release(old, persona: persona) }
        profile.handle = handle
        profile.updatedAt = Date()
        setProfile(profile, for: persona)
        syncPublicProfile(persona)
        save()
        // One handle per identity: anything else it still holds goes.
        await releaseHandles(persona: persona, keeping: handle)
    }

    /// Takes the active persona out of the directory and stops reading its request mailbox.
    func unpublishProfile() async {
        let persona = activePersona
        var profile = profile(for: persona)
        guard profile.handle != nil else { return }
        await releaseHandles(persona: persona, keeping: nil)
        data.invites.removeAll { $0.isPublic && $0.persona == persona }
        profile.handle = nil
        profile.updatedAt = Date()
        setProfile(profile, for: persona)
        syncPublicProfile(persona)
        save()
    }

    private func release(_ handle: String, persona: UUID?) async {
        guard let me = me(persona), let client = client(nil) else { return }
        let ts = UInt64(RelayClock.now.timeIntervalSince1970)
        let message = Data("pulshade.dir.del.v1".utf8) + Data(handle.utf8) + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
        guard let sig = try? me.signingKey.signature(for: message) else { return }
        try? await client.release(handle, sig: sig.base64EncodedString(), ts: ts)
    }

    /// Burning: every handle the identity lists or holds stays unclaimable for a while, with nothing left on
    /// the relay to say whose it was.
    private func retireHandles(persona: UUID?) async {
        guard let me = me(persona), let client = client(nil) else { return }
        let ts = UInt64(RelayClock.now.timeIntervalSince1970)
        let key = me.card.signing
        let message = Data("pulshade.dir.retire.v1".utf8) + key + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
        guard let sig = try? me.signingKey.signature(for: message) else { return }
        try? await client.retire(key: key.base64EncodedString(), sig: sig.base64EncodedString(), ts: ts)
    }

    /// Keeps a listed profile in step with name, picture and bio changes.
    private func republish(_ persona: UUID?) async {
        guard let handle = profile(for: persona).handle, let client = client(nil),
              let entry = try? signedEntry(handle: handle, persona: persona) else { return }
        try? await client.claim(handle, entry)
    }

    /// Looks up exactly one handle and checks its signature. Nil if nobody has it.
    func findProfile(_ raw: String) async throws -> DirectoryProfile? {
        guard let handle = DirectoryProfile.validHandle(raw) else { throw DirectoryError.invalidHandle }
        guard let client = client(nil) else { throw DirectoryError.unreachable }
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
        if let old = profile(for: persona).handle, old != keep { await release(old, persona: persona) }
    }

    /// Clears handles left behind by older versions, which let each device claim its own. Only when this
    /// device's handle is the identity's newest, so a device with an out-of-date profile never releases
    /// the real one.
    func releaseLeftoverHandles() async {
        for persona in [nil] + data.personas.filter { !$0.isBurner }.map(\.id) {
            guard let current = profile(for: persona).handle, let me = me(persona) else { continue }
            let listed = await publicProfiles(of: me)
            guard listed.count > 1, listed.first?.handle == current else { continue }
            for old in listed.dropFirst() { await release(old.handle, persona: persona) }
        }
    }

    /// A handle the active identity stopped using, kept for it so nobody else can take it until `until`.
    struct HeldHandle: Identifiable, Equatable {
        var handle: String
        var until: Date
        var id: String { handle }
    }

    /// How many handles an identity may have, the one in use and those kept for it together. The relay enforces it.
    static let maxHandles = 3

    /// The handles kept for the active identity, soonest free first.
    func heldHandles() async throws -> [HeldHandle] {
        guard let me = me(activePersona), let client = client(nil) else { throw DirectoryError.unreachable }
        let (key, sig, ts) = try ownerProof("pulshade.dir.held.v1", about: me.card.signing, by: me)
        do {
            return try await client.held(key: key, sig: sig, ts: ts).map { HeldHandle(handle: $0.handle, until: $0.until) }
        } catch { throw DirectoryError.unreachable }
    }

    /// Lets go of a handle kept for the active identity: anyone may claim it from now on.
    func letGo(of handle: String) async throws {
        guard let me = me(activePersona), let client = client(nil) else { throw DirectoryError.unreachable }
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
        guard let me = me(persona), let client = client(nil) else { throw DirectoryError.unreachable }
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
        guard let me = me(persona), let client = client(nil),
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
        guard let me = me(activePersona), let client = client(nil) else { throw DirectoryError.unreachable }
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
        guard let me = me(persona), let client = client(nil) else { throw RelayClient.HatchError.unreachable }
        let (key, sig, ts) = try ownerProof("pulshade.eggs.hatch.v1", about: Data(id.utf8), by: me)
        let pet = try await client.hatchEgg(key: key, sig: sig, ts: ts, id: id)
        guard pet.isGenuine(for: me.card.signing) else { throw RelayClient.HatchError.unreachable }
        withAnimation(.smooth) { eggs.removeAll { $0.id == id } }
        try? await refreshCollectibles()
        return pet
    }

    /// Gives a collectible to a contact. They see it the next time their app checks.
    func gift(_ item: Collectible, to contact: Contact) async throws {
        guard let me = me(activePersona), let client = client(nil) else { throw DirectoryError.unreachable }
        let to = contact.signingKey
        let about = Data(item.item.utf8) + Data([0]) + withUnsafeBytes(of: item.serial.bigEndian) { Data($0) } + to
        let (key, sig, ts) = try ownerProof("pulshade.collect.gift.v1", about: about, by: me)
        do { try await client.giftCollectible(key: key, sig: sig, ts: ts, item: item.item, serial: item.serial, to: to.base64EncodedString()) }
        catch { throw DirectoryError.unreachable }
        try? await refreshCollectibles()
    }

    /// Lets a collectible go. It goes back into circulation, and its number can hatch again for someone else.
    func release(_ item: Collectible) async throws {
        guard let me = me(activePersona), let client = client(nil) else { throw DirectoryError.unreachable }
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
        guard let me = me(persona), let client = client(nil) else { throw DirectoryError.unreachable }
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
        guard let me = me(activePersona), let client = client(nil) else { throw RelayClient.ClaimError.unreachable }
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
            guard let me = me(activePersona), let client = client(nil) else { throw RelayClient.GiveawayError.unreachable }
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
        guard let client = client(nil) else { return [] }
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
        for other in others where other.handle != chosen.handle { await release(other.handle, persona: nil) }
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
        upsert(contact)
        seal(.request(card(sendID: mailbox.sendID, persona: persona), request, note: String(note.prefix(280))),
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
        data.blocked.append(request.fingerprint)
        sync(.blocked(request.fingerprint))
        declineRequest(id)
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
            for c in self.contacts(of: persona) { self.enqueue(self.profilePayload(persona), to: c) }
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
        if data.security.notificationContent != before.notificationContent || !data.security.notifications {
            Notifier.shared.clearAll()
        }
        mirrorSecurity()
        save()
    }

    private func checkAutoLock() {
        let minutes = data.security.autoLockMinutes
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
        try? vault.clearSlot(1, identity: try? Identity(seed: seed))
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
        try await Task.detached { try vault.setSlot(2, identity: landing, passcode: passcode, panic: true) }.value
        try vault.save(landingData, with: landing)
        guard identity?.fingerprint == main.fingerprint else { return }
        data.panicSeed = landing.seed
        vault.disableBiometrics()
        save()
        rebalanceFiles()
    }

    func removePanic() {
        guard isPrimary else { return pretend { $0.panic = false } }
        guard let seed = data.panicSeed else { return }
        try? vault.clearSlot(2, identity: try? Identity(seed: seed))
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
            for item in data.contacts[i].devices[d].pending {
                guard let plain = try? JSONEncoder.pulshade.encode(item.payload),
                      let message = try? session.encrypt(plain) else { continue }
                seal(.ratchet(message), contact: i, device: d, message: item.message, ephemeral: item.payload.isEphemeral,
                     story: item.payload.storyID)
            }
            data.contacts[i].devices[d].session = session
            data.contacts[i].devices[d].pending = []
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
        let first: Payload = data.contacts[i].isSelf ? .sync(.hello) : profilePayload(data.contacts[i].persona)
        data.contacts[i].devices[d].pending.insert(PendingPayload(payload: first, message: nil), at: 0)
        sendPending(contact: i)
    }

    /// Seals a payload to one of a contact's devices, as the persona that knows them, and queues it.
    private func seal(_ payload: Payload, contact i: Int, device d: Int, message: UUID? = nil, ephemeral: Bool = false,
                      story: UUID? = nil) {
        let c = data.contacts[i]
        guard c.devices.indices.contains(d), let me = me(c.persona),
              let blob = try? Envelope.seal(payload, from: me, device: deviceID(for: c.persona), to: c.agreementKey) else { return }
        let sendID = c.devices[d].sendID
        // Only the newest of these waits for a mailbox.
        if ephemeral { data.outbox.removeAll { $0.ephemeral == true && $0.sendID == sendID } }
        data.outbox.append(Outgoing(sendID: sendID, blob: blob, relay: c.relay, message: message, ephemeral: ephemeral ? true : nil,
                                  story: story, lane: c.persona == nil ? nil : Outgoing.lane(for: c.persona)))
        kick()
    }

    /// Seals a payload to a contact's first device, for introductions.
    private func seal(_ payload: Payload, to fingerprint: String, persona: UUID?, message: UUID? = nil) {
        guard let i = contactIndex(fingerprint, persona), !data.contacts[i].devices.isEmpty else { return }
        seal(payload, contact: i, device: 0, message: message)
    }

    /// Handshakes that got no answer (the other side didn't know us yet, say) are tried again.
    private func retryStaleHandshakes() {
        let cutoff = Date().addingTimeInterval(-60)
        for i in data.contacts.indices {
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
                self?.tick()
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
        guard trafficShaping else {
            // Tests: one round at a time, at a steady pace.
            syncTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.syncOnce()
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
        let wait = fetchWait
        let started = Date()
        do {
            let envelopes = try await client.fetch(Array(mine), wait: wait)
            if lane.relay == nil { noteRelay(reached: true) }
            // Mail, or an empty answer after a real wait. An instant empty one means the relay doesn't wait.
            let waited = wait > 0 && (!envelopes.isEmpty || Date().timeIntervalSince(started) > Double(wait) / 2)
            guard identity?.fingerprint == owner, !envelopes.isEmpty else { return waited }
            for envelope in envelopes { receive(envelope) }
            deposited = nil
            save()
            try await client.ack(envelopes)
            return waited
        } catch {
            if lane.relay == nil { noteRelay(reached: false) }
            return false
        }
    }

    /// Sending, retries and receipts, every couple of seconds. Also keeps the sending lane's circuit warm, so
    /// pressing send doesn't wait for Tor to build one.
    private func housekeep() async {
        refreshPush()
        retryStaleHandshakes()
        resendUnconfirmedStories()
        data.clipParts = data.clipParts.filter { $0.value.date.addingTimeInterval(StoryLifetime.twoDays.rawValue + 3600) > Date() }
        askForStalledClips()
        sendDueReceipts()
        await flush()
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
        let reached = await client.health()
        if !reached { lastRelayContact = .distantPast }
        noteRelay(reached: reached)
        if reached { Task { await syncOnce() } }
    }

    /// A client for a contact's relay, or the default relay when nil. Each lane has its own connections, so
    /// requests on different lanes don't arrive together over one.
    // MARK: Wake-up pushes

    /// What the relay was last told about this phone's push, so it's only told again when something changed. Dropped
    /// at lock: it holds this account's mailbox keys, which a decoy or another account must never see or act on.
    private var pushTold: (token: String, keys: Set<Data>, sound: Bool, at: Date)?
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
            if let told = pushTold, told.token == token, told.keys == keys, told.sound == sound,
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
                        try await client.registerPush(keys: chunk, token: token, sandbox: Push.sandbox, sound: sound)
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
                    pushTold = (token, keys, sound, Date())
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

    func client(_ relay: String?, lane: String = "main") -> RelayClient? {
        guard let address = reachable(relay), let url = URL(string: address) else { return nil }
        return RelayClient(base: url, lane: lane)
    }

    /// Where to actually connect for a relay: never anywhere but an allowed one, whatever a contact or code once
    /// said, and for Pulshade's own, its onion address with Tor on and its direct one with Tor off.
    func reachable(_ relay: String?) -> String? {
        Invite.allowedRelay(relay ?? data.relay).map { Invite.route($0, overTor: Tor.enabled) }
    }

    private var flushing = false
    /// One fetch at a time: two overlapping ones could both collect, and handle, the same envelope.
    private var syncing = false

    /// Sends queued envelopes, oldest first, a few mailboxes at a time. Each round sends the oldest waiting one for
    /// up to `Self.sendLanes` different mailboxes at once, so a burst (one story to thirty people) doesn't go out
    /// one slow round trip after another, and what's written to one mailbox still goes out in order.
    /// One that fails holds up only its own mailbox, and a relay that's down only its own envelopes. A large one
    /// that fails (a slow upload, not a relay that's gone) doesn't stop the small ones behind it.
    private func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        let owner = identity?.fingerprint
        var down: Set<String> = []
        // Mailboxes that failed or are full this time: what's written to them waits, nothing else does.
        var held: Set<Data> = []
        var tried: Set<UUID> = []
        while true {
            var wave: [(item: Outgoing, client: RelayClient, lane: String)] = []
            var inWave: Set<Data> = []
            for item in data.outbox where !tried.contains(item.id) {
                let relay = item.relay ?? data.relay
                let lane = item.lane ?? Outgoing.lane(for: nil)
                guard !down.contains(relay), !held.contains(item.sendID), !inWave.contains(item.sendID),
                      let client = client(item.relay, lane: lane) else { continue }
                wave.append((item, client, lane))
                inWave.insert(item.sendID)
                tried.insert(item.id)
                if wave.count == Self.sendLanes { break }
            }
            if wave.isEmpty { break }
            var failures: [UUID: Error] = [:]
            await withTaskGroup(of: (UUID, Error?).self) { group in
                for (item, client, _) in wave {
                    group.addTask {
                        do { try await client.deposit(item.blob, to: item.sendID, wake: item.message != nil); return (item.id, nil) } catch { return (item.id, error) }
                    }
                }
                for await (id, error) in group { if let error { failures[id] = error } }
            }
            guard identity?.fingerprint == owner else { return }
            for (item, _, lane) in wave {
                if let error = failures[item.id] {
                    if error is RelayTooLarge {
                        // Too big for the relay, now and always: waiting would hold up everything behind it.
                        data.outbox.removeAll { $0.id == item.id }
                        continue
                    }
                    if error is RelayMailboxFull || item.blob.count > Self.largeEnvelope {
                        held.insert(item.sendID)
                    } else {
                        down.insert(item.relay ?? data.relay)
                    }
                    // A signal that couldn't be sent is not worth sending later.
                    if item.ephemeral == true { data.outbox.removeAll { $0.id == item.id } }
                } else {
                    lastSent[lane] = Date()
                    data.outbox.removeAll { $0.id == item.id }
                    if let message = item.message { setStatus(.sent, for: [message]) }
                }
            }
        }
        if !down.isEmpty { link = .offline }
        save()
    }

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
        let viaIntro = data.conversations.contains { $0.introsMine.contains { $0.receiveKey == envelope.receiveKey } }
        defer { if viaIntro { moveOffIntro(fp, persona) } }

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
            guard let d = deviceIndex(i, device), var session = data.contacts[i].devices[d].session,
                  let plain = try? session.decrypt(message) else { return }
            // Kept before reading what it says, so a message this version can't read (one from a newer app)
            // still counts and doesn't leave the session behind.
            data.contacts[i].devices[d].session = session
            guard let inner = try? JSONDecoder.pulshade.decode(Payload.self, from: plain), !inner.isSetup else { return }
            handle(inner, from: fp, persona: persona, device: device)
            // The first message in lets a new session start sending. Look them up again: handling it may
            // have removed them (a burned burner, say).
            if let i = contactIndex(fp, persona) { sendPending(contact: i) }
        default:
            // Anything else arriving outside a session is refused.
            return
        }
    }

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
            sender.avatar = avatar
            sender.banner = banner
            sender.color = color.map { abs($0) % Signature.colors.count }
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
            if let i = data.stories.firstIndex(where: { $0.id == id }) {
                // A new version of one they sent before.
                guard data.stories[i].author == fp, data.stories[i].persona == persona else { break }
                var style = style
                // A new caption on a clip they already sent comes without the clip.
                if case let .video(bytes, caption) = style, bytes.isEmpty, case let .video(have, _) = data.stories[i].style, !have.isEmpty {
                    style = .video(have, caption: caption)
                }
                data.stories[i].style = style
                data.stories[i].lifetime = lifetime
                if !data.stories[i].isLive { data.stories.remove(at: i); break }
                acknowledgeStory(id, author: fp, persona: persona)
                // Sent again because pieces went missing: what's here now may complete it.
                clipActivity[id] = Date()
                assembleClip(id)
                break
            }
            if case let .video(bytes, _) = style, bytes.isEmpty { clipActivity[id] = Date() }
            var story = Story(id: id, author: fp, style: style, date: dated(date))
            story.persona = persona
            story.lifetime = lifetime
            if story.isLive { withAnimation(.snappy) { data.stories.append(story) } }
            assembleClip(id)
            acknowledgeStory(id, author: fp, persona: persona)
        case let .storyPart(id, index, of, bytes):
            guard removedStories["\(fp)|\(id)"] == nil else { break }
            // A piece sent again after the clip came together: nothing to do with it.
            if data.stories.contains(where: { $0.id == id && $0.author == fp && $0.isReady }) { break }
            guard (1...StoryClipPieces.maxPieces).contains(of), (0..<of).contains(index), bytes.count <= StoryClipPieces.size,
                  data.clipParts[id] != nil || data.clipParts.count < 32 else { break }
            var pending = data.clipParts[id] ?? ClipParts(author: fp, persona: persona, of: of)
            guard pending.author == fp, pending.persona == persona, pending.of == of else { break }
            pending.parts[index] = bytes
            data.clipParts[id] = pending
            clipActivity[id] = Date()
            assembleClip(id)
        case let .storyReceived(id):
            // One of my contacts has the story: it's no longer sent to them again.
            guard let i = data.stories.firstIndex(where: { $0.id == id && $0.author == "me" && $0.persona == persona }),
                  var delivery = data.stories[i].delivery, !delivery.confirmed.contains(fp) else { break }
            delivery.confirmed.append(fp)
            data.stories[i].delivery = delivery
        case let .storyWant(id, parts):
            // Only for a story of yours that's still up, on this persona, and that they're meant to see.
            guard let story = data.stories.first(where: { $0.id == id && $0.author == "me" && $0.persona == persona }),
                  story.isLive, story.shownTo.includes(fp), removedStories["me|\(id)"] == nil,
                  !sender.isSelf, !data.blocked.contains(fp) else { break }
            let key = "\(fp)|\(id)"
            if let last = clipResent[key], Date().timeIntervalSince(last) < clipQuiet { break }
            clipResent[key] = Date()
            resendStory(story, to: sender, pieces: parts)
        case let .storyViewed(id):
            guard data.security.storyViews,
                  let i = data.stories.firstIndex(where: { $0.id == id && $0.author == "me" && $0.persona == persona }),
                  data.stories[i].shownTo.includes(fp), data.stories[i].viewers?[fp] == nil else { break }
            data.stories[i].viewers = (data.stories[i].viewers ?? [:]).merging([fp: min(deposited ?? Date(), Date())]) { old, _ in old }
        case let .storyRemoved(id):
            if data.clipParts[id]?.author == fp { data.clipParts[id] = nil }
            noteRemoved("\(fp)|\(id)")
            withAnimation { data.stories.removeAll { $0.id == id && $0.author == fp && $0.persona == persona } }
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
            let valid = seconds.flatMap(Disappear.init(rawValue:))?.rawValue
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
            data.conversations[i].version += 1
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
        guard !data.conversations[i].messages.contains(where: { $0.id == wire.id }) else { return }
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
        let message = Message(id: wire.id, sender: sender.fingerprint, text: String(wire.text.prefix(20_000)),
                              image: wire.image, voice: wire.voice, date: date, status: .delivered, expiresAt: expires,
                              reply: reply, preview: preview)
        typing[data.conversations[i].id]?[sender.fingerprint] = nil
        withAnimation(.snappy(duration: 0.4)) { data.conversations[i].messages.append(message) }
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
        for i in data.conversations.indices {
            withAnimation(.snappy) {
                data.conversations[i].messages.removeAll { ids.contains($0.id) && $0.sender == sender.fingerprint }
            }
        }
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
        let intro = info.intros?[deviceID(for: persona).hex].flatMap {
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

    private func sendInfo(_ convo: Conversation, to recipients: [String]) {
        for fp in Set(recipients) where fp != "me" {
            guard let peer = contact(fp, in: convo.persona) else { continue }
            enqueue(.group(info(for: convo, to: fp)), to: peer)
        }
    }

    /// Bumps the version and tells everyone who needs to know.
    private func publishChange(_ i: Int, alsoTell extra: [String] = [], channelAdminsOnly: Bool = false) {
        data.conversations[i].version += 1
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
            let message = Message(id: wire.id, sender: "me", text: wire.text, image: wire.image, voice: wire.voice,
                                  date: dated(wire.date), status: .sent,
                                  expiresAt: wire.expiresIn.map { dated(wire.date).addingTimeInterval($0) }, reply: reply,
                                  preview: wire.preview)
            withAnimation(.snappy) { data.conversations[i].messages.append(message) }
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
            if let old = current.handle, old != incoming.handle {
                // Another device chose a different handle for this account: let go of the one this device held.
                Task { await self.release(old, persona: persona) }
            }
            var incoming = incoming
            incoming.links = Optional(ProfileLink.cleaned(incoming.links)).flatMap { $0.isEmpty ? nil : $0 }
            incoming.notes = Optional(ProfileNote.cleaned(incoming.notes)).flatMap { $0.isEmpty ? nil : $0 }
            setProfile(incoming, for: persona)
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
        case let .blocked(fp):
            if !data.blocked.contains(fp) { data.blocked.append(fp) }
            data.requests.removeAll { $0.fingerprint == fp }
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
        retirePublicInvites(of: persona, except: receiveKey)
        guard !data.invites.contains(where: { $0.receiveKey == receiveKey }) else { return }
        data.invites.append(OpenInvite(receiveKey: receiveKey, persona: persona, relay: relay, isPublic: true))
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
    enum LeaveError: Error { case wrongRecoveryCode, offline }

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
    func burn(recoveryCode: String? = nil) async throws {
        try open(recoveryCode: recoveryCode)
        guard let client = client(nil), await client.health(), let identity else { throw LeaveError.offline }
        for persona in [nil] + data.personas.map(\.id) { await retireHandles(persona: persona) }
        try? await deleteBackup(of: identity)
        for id in data.conversations.map(\.id) { delete(id) }
        for c in data.contacts where !c.isSelf {
            // Someone we only sent a request to has no session with us yet, so it goes straight to them.
            if c.awaitingAcceptance { seal(.erased, to: c.fingerprint, persona: c.persona) } else { enqueue(.erased, to: c) }
        }
        for id in data.stories.filter({ $0.author == "me" }).map(\.id) { deleteStory(id) }
        sync(.accountErased)
        try await sendEverything()
        // Collects whatever is still waiting in our mailboxes, so the relay doesn't hold it for days.
        let shaping = trafficShaping
        trafficShaping = false
        await syncOnce()
        trafficShaping = shaping
        destroyEverything(leavingNoTrace: true)
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

    enum BackupLookup { case found(AppData), none, unreachable }

    /// The account a log out left on the relay, opened with the recovery code's key.
    func backup(of identity: Identity) async -> BackupLookup {
        guard let client = client(nil) else { return .unreachable }
        let (key, sig, ts) = backupProof("pulshade.backup.get.v1", identity)
        let sealed: Data?
        do { sealed = try await client.backup(key: key, sig: sig, ts: ts) } catch { return .unreachable }
        guard let sealed else { return .none }
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: identity.backupKey),
              let restored = try? JSONDecoder.pulshade.decode(AppData.self, from: plain) else { return .none }
        return .found(restored)
    }

    private func deleteBackup(of identity: Identity) async throws {
        guard let client = client(nil) else { throw LeaveError.offline }
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
            guard let client = client(nil) else { throw LeaveError.offline }
            let plain = try JSONEncoder.pulshade.encode(Self.withoutChats(data, keepingDevices: false))
            let sealed = try AES.GCM.seal(plain, using: identity.backupKey).combined!
            let (key, sig, ts) = backupProof("pulshade.backup.put.v1", identity, body: sealed)
            try await client.putBackup(sealed, key: key, sig: sig, ts: ts)
        } catch {
            startSync()
            throw LeaveError.offline
        }
    }

    /// `label | backup key | ts`, plus the contents' hash for an upload, signed with the backup key.
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
        guard identity != nil, let client = client(nil) else { throw ReportError.unreachable }
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
        ringFor(seconds: 45, else: "No answer")
    }

    func answerCall() {
        guard var current = call, !current.outgoing, current.phase == .ringing,
              let contact = contact(current.peer, in: current.persona) else { return }
        current.phase = .connecting
        call = current
        callTimeout?.cancel()
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
        guard call == nil else {
            // Already on a call: busy.
            enqueue(.callAnswer(id: invite.id, accepted: false), to: sender)
            return
        }
        call = ActiveCall(invite: invite, peer: sender.fingerprint, persona: sender.persona, outgoing: false, phase: .ringing,
                          speaker: Platform.isPhone)
        if data.security.notifications {
            let name = data.security.notificationContent == .hidden ? "PULSHADE" : sender.displayName
            Notifier.shared.post((name, "Incoming call"), conversation: UUID(), sound: data.security.notificationSound)
        }
        ringFor(seconds: 45, else: "Missed call")
    }

    fileprivate func callAnswered(_ id: UUID, accepted: Bool, by sender: Contact) {
        guard var current = call, current.invite.id == id, current.outgoing, current.phase == .ringing,
              current.peer == sender.fingerprint, current.persona == sender.persona else { return }
        callTimeout?.cancel()
        guard accepted else {
            endCall(note: "Declined", tell: false)
            return
        }
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
