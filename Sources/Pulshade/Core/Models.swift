import Foundation
import SwiftUI
import CryptoKit
#if canImport(PulshadeShared)
import PulshadeShared
#endif

struct Profile: Codable, Equatable {
    var name: String = ""
    var avatar: Data?
    /// A wide picture behind your avatar, 3:1.
    var banner: Data?
    /// Your signature colour, an index into `Signature.colors`. Others see your messages glow in it.
    var color: Int?
    /// Your public @handle, if this identity is listed in the directory. Nil means private. With more than one
    /// handle in use, this is the main one: the one shown on your profile.
    var handle: String?
    /// Other @handles in use for this identity at the same time (two at most, three with the main one). Each leads
    /// to the same profile and takes chat requests. A handle belongs to the identity whose key claimed it, so it
    /// can't be moved to another persona.
    var moreHandles: [String]?

    /// Every handle in use, the main one first.
    var activeHandles: [String] { (handle.map { [$0] } ?? []) + (moreHandles ?? []).filter { $0 != handle } }
    /// A line about you, shown on your public profile.
    var bio: String?
    /// Links and wallets, each shown as an icon on your profile.
    var links: [ProfileLink]?
    /// Text notes on your profile, public or locked with a password.
    var notes: [ProfileNote]?
    /// The collectibles given to this identity, and the one shown after its name.
    var collectibles: [Collectible]?
    var badge: Collectible?
    /// The backup code for all of this persona's collectibles. Only ever on your own devices: entered in another
    /// account, it brings every one of them back, even after this one burns.
    var collectionCode: String?
    /// Which code each collectible is set to on the relay, by its id ("item#serial"). One that isn't the collection
    /// code yet gets added to it.
    var collectibleCodes: [String: String]?
    /// When any of this last changed, so your devices can agree on the newest version.
    var updatedAt: Date?
    /// The `AppData.currentFormat` of the build that last saved this profile. Devices of one account pass profiles
    /// round, and a build that doesn't know every field would send one back without them, so a profile is only
    /// taken from a device on the same format or newer, never an older one.
    var format: Int?

    var displayName: String { name.isEmpty ? "Anonymous" : name }
}

/// Another identity of yours: its own keys, name and look, unlinkable to the others.
/// A burner is a persona with a self-destruct time.
struct Persona: Codable, Identifiable, Equatable {
    var id = UUID()
    var seed: Data
    var profile: Profile
    /// Burners destroy themselves (keys, contacts, chats) at this moment.
    var burnsAt: Date?
    var createdAt = Date()

    /// Made for a one-time chat link (yours or someone else's). Such chats never send read receipts.
    var oneTimeChat: Bool?

    var isBurner: Bool { burnsAt != nil }
}

/// One of a person's devices, from your side: where to reach it and your encrypted session with it.
struct DeviceLink: Codable {
    /// Their device's id. Empty until we've heard from it (older apps don't send one).
    var id: Data
    /// Where to drop envelopes for this device.
    var sendID: Data
    /// The ratchet once a handshake completes.
    var session: Ratchet?
    /// Our half of a handshake we started and are waiting on.
    var handshake: PendingHandshake?
    /// Things to say once the session can send. Lives in the encrypted vault.
    var pending: [PendingPayload] = []
    /// What the device calls itself (your own linked devices only).
    var name: String?
    /// The device that approved this one opens the session; until it does, don't open a competing one.
    var awaitingHello: Bool?
    /// The handshake behind the current session, so a redelivered copy is recognised and ignored.
    var acceptedHello: Data?
    /// Their app reads framed messages (it said so on what it last sent), so big ones go to it without the base64
    /// bloat. Nil for an app from before, which gets everything the old way.
    var readsFrames: Bool?

    init(id: Data = Data(), sendID: Data) {
        self.id = id
        self.sendID = sendID
    }
}

/// Someone whose keys you hold: one account, with one or more devices. `hidden` peers came from a group
/// or channel roster and aren't in your contacts list. Your own other devices live in a hidden contact
/// with `isSelf` set.
struct Contact: Codable, Identifiable {
    var id: String { fingerprint }
    var fingerprint: String
    /// The name they chose for themselves.
    var name: String = ""
    /// A local name only you see. Wins over `name` when set.
    var nickname: String = ""
    var avatar: Data?
    var banner: Data?
    /// Their chosen signature colour.
    var color: Int?
    /// A line about them, from their profile.
    var bio: String?
    /// Their links and wallets, checked when they arrived.
    var links: [ProfileLink]?
    /// When a wallet address they had already shown last changed. Nil if it never has.
    var walletChangedAt: Date?
    /// Their text notes, checked when they arrived.
    var notes: [ProfileNote]?
    /// Their public @handle, shown only once the directory confirmed it's signed by their key.
    var handle: String?
    /// You checked their safety code in person.
    var verified = false
    /// The collectible they show after their name, checked against the creator key when it arrived.
    var badge: Collectible?
    /// Everything they own, each checked against the creator key and their account when it arrived.
    var collectibles: [Collectible]?
    var signingKey: Data
    var agreementKey: Data
    /// Their devices. The first one is where a new contact starts.
    var devices: [DeviceLink]
    /// The mailbox this device reads their envelopes from (all their devices write to it).
    var receiveKey: Data?
    /// The relay both mailboxes live on. Nil means your default relay.
    var relay: String?
    var hidden = false
    /// Your own linked devices, for keeping them in sync.
    var isSelf = false
    /// You sent them a request that they haven't accepted yet.
    var awaitingAcceptance = false
    /// They asked for your online status (nil: they haven't), and whether you last told them you want theirs.
    var wantsMyPresence: Bool?
    var toldPresence: Bool?
    var addedAt = Date()
    /// Which of your personas knows them. Nil is your main identity.
    var persona: UUID?

    /// Where a new contact starts: their first device's mailbox.
    var sendID: Data {
        get { devices.first?.sendID ?? Data() }
        set {
            if devices.isEmpty { devices = [DeviceLink(sendID: newValue)] } else { devices[0].sendID = newValue }
        }
    }

    init(fingerprint: String, name: String = "", nickname: String = "", avatar: Data? = nil, signingKey: Data,
         agreementKey: Data, sendID: Data, receiveKey: Data? = nil, hidden: Bool = false, device: Data = Data()) {
        self.fingerprint = fingerprint
        self.name = name
        self.nickname = nickname
        self.avatar = avatar
        self.signingKey = signingKey
        self.agreementKey = agreementKey
        devices = [DeviceLink(id: device, sendID: sendID)]
        self.receiveKey = receiveKey
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case fingerprint, name, nickname, avatar, banner, color, bio, links, walletChangedAt, notes, handle, verified, badge, collectibles, signingKey, agreementKey, devices, receiveKey, relay
        case hidden, isSelf, awaitingAcceptance, addedAt, persona, wantsMyPresence, toldPresence
        // Single-device fields from before linked devices.
        case sendID, session, handshake, pending
    }

    /// Tolerates fields added after a vault was written, so upgrades don't drop contacts.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        signingKey = try c.decode(Data.self, forKey: .signingKey)
        agreementKey = try c.decode(Data.self, forKey: .agreementKey)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        avatar = try c.decodeIfPresent(Data.self, forKey: .avatar)
        banner = try c.decodeIfPresent(Data.self, forKey: .banner)
        color = try c.decodeIfPresent(Int.self, forKey: .color)
        bio = try c.decodeIfPresent(String.self, forKey: .bio)
        links = try? c.decodeIfPresent([ProfileLink].self, forKey: .links)
        walletChangedAt = try? c.decodeIfPresent(Date.self, forKey: .walletChangedAt)
        notes = try? c.decodeIfPresent([ProfileNote].self, forKey: .notes)
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        badge = try? c.decodeIfPresent(Collectible.self, forKey: .badge)
        collectibles = try? c.decodeIfPresent([Collectible].self, forKey: .collectibles)
        receiveKey = try c.decodeIfPresent(Data.self, forKey: .receiveKey)
        relay = try c.decodeIfPresent(String.self, forKey: .relay)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        awaitingAcceptance = try c.decodeIfPresent(Bool.self, forKey: .awaitingAcceptance) ?? false
        persona = try c.decodeIfPresent(UUID.self, forKey: .persona)
        wantsMyPresence = try c.decodeIfPresent(Bool.self, forKey: .wantsMyPresence)
        toldPresence = try c.decodeIfPresent(Bool.self, forKey: .toldPresence)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        // Your own entry has no devices once the last linked one leaves; anyone else always has one.
        if let devices = try? c.decodeIfPresent([DeviceLink].self, forKey: .devices), !devices.isEmpty || isSelf {
            self.devices = devices
        } else {
            var link = DeviceLink(sendID: try c.decode(Data.self, forKey: .sendID))
            link.session = try? c.decodeIfPresent(Ratchet.self, forKey: .session)
            link.handshake = try? c.decodeIfPresent(PendingHandshake.self, forKey: .handshake)
            link.pending = (try? c.decodeIfPresent([PendingPayload].self, forKey: .pending)) ?? []
            devices = [link]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(name, forKey: .name)
        try c.encode(nickname, forKey: .nickname)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encodeIfPresent(banner, forKey: .banner)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(bio, forKey: .bio)
        try c.encodeIfPresent(links, forKey: .links)
        try c.encodeIfPresent(walletChangedAt, forKey: .walletChangedAt)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(handle, forKey: .handle)
        try c.encode(verified, forKey: .verified)
        try c.encodeIfPresent(badge, forKey: .badge)
        try c.encodeIfPresent(collectibles, forKey: .collectibles)
        try c.encode(signingKey, forKey: .signingKey)
        try c.encode(agreementKey, forKey: .agreementKey)
        try c.encode(devices, forKey: .devices)
        try c.encodeIfPresent(receiveKey, forKey: .receiveKey)
        try c.encodeIfPresent(relay, forKey: .relay)
        try c.encode(hidden, forKey: .hidden)
        try c.encode(isSelf, forKey: .isSelf)
        try c.encode(awaitingAcceptance, forKey: .awaitingAcceptance)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(persona, forKey: .persona)
        try c.encodeIfPresent(wantsMyPresence, forKey: .wantsMyPresence)
        try c.encodeIfPresent(toldPresence, forKey: .toldPresence)
    }

    var displayName: String {
        if !nickname.isEmpty { return nickname }
        return name.isEmpty ? "Anonymous" : name
    }
}

/// An invite you handed out and are waiting on. Contact invites are used once;
/// channel invites stay open for anyone who has them.
struct OpenInvite: Codable, Identifiable {
    var id: Data { receiveKey }
    var receiveKey: Data
    var channel: UUID?
    var createdAt = Date()
    /// The persona this invite introduces. Nil is your main identity.
    var persona: UUID?
    /// The relay its mailbox lives on. Nil means your default relay.
    var relay: String?
    /// The mailbox behind a public profile: reusable, and hellos arriving on it become requests.
    var isPublic = false
    /// When a public mailbox that's been replaced stops being read. Until then, requests already sent to it still arrive.
    var retiresAt: Date?

    init(receiveKey: Data, channel: UUID? = nil, persona: UUID? = nil, relay: String? = nil, isPublic: Bool = false) {
        self.receiveKey = receiveKey
        self.channel = channel
        self.persona = persona
        self.relay = relay
        self.isPublic = isPublic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        receiveKey = try c.decode(Data.self, forKey: .receiveKey)
        channel = try c.decodeIfPresent(UUID.self, forKey: .channel)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        persona = try c.decodeIfPresent(UUID.self, forKey: .persona)
        relay = try c.decodeIfPresent(String.self, forKey: .relay)
        isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic) ?? false
        retiresAt = try c.decodeIfPresent(Date.self, forKey: .retiresAt)
    }
}

/// A QR link this device is showing, for a new device to scan.
struct LinkOffer: Codable, Identifiable {
    var id: Data { receiveKey }
    /// The mailbox the new device writes its request to.
    var receiveKey: Data
    /// Shared with the new device through the QR code only; proves it saw the code.
    var secret: Data
    var createdAt = Date()
    /// A device that answered and is waiting for you to confirm.
    var request: LinkRequest?
    /// Where to send the account when the new device's own code was scanned. Nil means your relay.
    var relay: String?
}

/// What a new device sends after scanning: who it is and where to send the account.
struct LinkRequest: Codable, Equatable {
    var deviceID: Data
    var name: String
    /// The new device's temporary key for receiving the account.
    var ephemeral: Data
    /// Where to drop the encrypted account bundle.
    var bundleSendID: Data
    /// The new device's mailbox for messages from your other devices.
    var selfSendID: Data
}

/// Someone who found your public profile and wants to talk. Nothing is set up until you accept.

struct FriendRequest: Codable, Identifiable, Equatable {
    var id = UUID()
    var fingerprint: String
    var card: PeerCard
    var handshake: SessionInit
    var note: String
    var receivedAt = Date()
    /// Which of your personas they asked for.
    var persona: UUID?
    /// The device that asked.
    var device: Data?
}

enum ConversationKind: String, Codable, CaseIterable, Identifiable {
    case direct, group, channel, broadcast
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .direct: "person.fill"
        case .group: "person.3.fill"
        case .channel: "megaphone.fill"
        case .broadcast: "dot.radiowaves.left.and.right"
        }
    }

    var label: String {
        switch self {
        case .direct: "Chat"
        case .group: "Group"
        case .channel: "Channel"
        case .broadcast: "Broadcast"
        }
    }
}

enum MessageStatus: String, Codable {
    /// Sealed and waiting on this Mac until the relay takes it.
    case queued
    /// The relay has it.
    case sent
    /// The recipient's device opened it.
    case delivered
    /// The recipient has seen it in the open chat.
    case read

    var symbol: String {
        switch self {
        case .queued: "clock"
        case .sent: "checkmark"
        case .delivered: "checkmark.circle"
        case .read: "checkmark.circle.fill"
        }
    }

    /// How far along it is. A message only ever moves forward, whatever order receipts arrive in.
    var rank: Int {
        switch self {
        case .queued: 0
        case .sent: 1
        case .delivered: 2
        case .read: 3
        }
    }
}

/// Where a message you sent has got to, as ticks: a clock while it waits, one tick once the relay has it, two once
/// it reached them, and two in colour once they've read it. Takes its colour from where it sits, except when read.
struct StatusTicks: View {
    var status: MessageStatus
    /// The size of a tick.
    var size: CGFloat = 10

    /// Bright enough to stand out on a coloured bubble and on a dark chat list alike.
    static let readColour = Color(red: 0.36, green: 0.92, blue: 0.62)

    var body: some View {
        ticks
            .font(.system(size: size, weight: status == .read ? .heavy : .semibold))
            .modifier(ReadColour(read: status == .read))
            .accessibilityLabel(label)
    }

    @ViewBuilder private var ticks: some View {
        switch status {
        case .queued: Image(systemName: "clock")
        case .sent: Image(systemName: "checkmark")
        case .delivered, .read:
            ZStack(alignment: .leading) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark").offset(x: size * 0.45)
            }
            .frame(width: size * 1.6, alignment: .leading)
        }
    }

    private var label: String {
        switch status {
        case .queued: "Waiting to send"
        case .sent: "Sent"
        case .delivered: "Delivered"
        case .read: "Read"
        }
    }

    private struct ReadColour: ViewModifier {
        var read: Bool
        func body(content: Content) -> some View {
            if read { content.foregroundStyle(StatusTicks.readColour) } else { content }
        }
    }
}

/// A recorded voice note. Lives only in memory and in the encrypted vault, never as a loose file.
struct VoiceNote: Codable, Equatable {
    var audio: Data
    var duration: TimeInterval
    /// 0...255 loudness samples for drawing the waveform.
    var levels: [UInt8]
}

/// The message a reply quotes: enough to show it even if the original has gone.
struct ReplyRef: Codable, Equatable {
    var id: UUID
    /// Who wrote the quoted message: a fingerprint, or "me".
    var author: String
    var snippet: String
    /// A small picture of what's quoted, for a story liked or replied to (it's gone by the time anyone scrolls
    /// back). Builds from before it show the words alone.
    var picture: Data? = nil

    /// Pictures bigger than this, or that aren't pictures, are left off what arrives.
    static let maxPicture = 48_000
}

/// A link preview, built on the sender's Mac and sent inside the encrypted message,
/// so whoever receives it never contacts the website.
struct LinkPreview: Codable, Equatable {
    var url: String
    var title: String?
    var site: String?
    var image: Data?
}

struct Message: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Fingerprint of the sender, "me", or "system" for timeline notes.
    var sender: String
    var text: String
    var image: Data?
    var voice: VoiceNote?
    var date = Date()
    var status: MessageStatus = .queued
    /// When it disappears from every device, if the chat has a timer.
    var expiresAt: Date?
    /// Who reacted with what: fingerprint or "me" → emoji.
    var reactions: [String: String] = [:]
    var reply: ReplyRef?
    var preview: LinkPreview?
    /// A video's clip. Nil when the message isn't a video; empty while its pieces are still arriving (`image` is a
    /// still from it meanwhile).
    var video: Data?
    /// How long the video runs.
    var clipSeconds: Double?

    var isVideo: Bool { video != nil }
    var isMine: Bool { sender == "me" }
    var isSystem: Bool { sender == "system" }

    init(id: UUID = UUID(), sender: String, text: String, image: Data? = nil, voice: VoiceNote? = nil, date: Date = Date(),
         status: MessageStatus = .queued, expiresAt: Date? = nil, reply: ReplyRef? = nil, preview: LinkPreview? = nil) {
        self.reply = reply
        self.preview = preview
        self.id = id
        self.sender = sender
        self.text = text
        self.image = image
        self.voice = voice
        self.date = date
        self.status = status
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sender = try c.decode(String.self, forKey: .sender)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        image = try c.decodeIfPresent(Data.self, forKey: .image)
        voice = try c.decodeIfPresent(VoiceNote.self, forKey: .voice)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        status = try c.decodeIfPresent(MessageStatus.self, forKey: .status) ?? .sent
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        reactions = try c.decodeIfPresent([String: String].self, forKey: .reactions) ?? [:]
        reply = try? c.decodeIfPresent(ReplyRef.self, forKey: .reply)
        preview = try? c.decodeIfPresent(LinkPreview.self, forKey: .preview)
        video = try? c.decodeIfPresent(Data.self, forKey: .video)
        clipSeconds = try? c.decodeIfPresent(Double.self, forKey: .clipSeconds)
    }
}

/// Disappearing-message timers on offer.
enum Disappear: TimeInterval, CaseIterable, Identifiable {
    case fiveMinutes = 300, hour = 3600, day = 86_400, week = 604_800
    var id: TimeInterval { rawValue }

    var short: String {
        switch self {
        case .fiveMinutes: "5m"
        case .hour: "1h"
        case .day: "1d"
        case .week: "1w"
        }
    }

    static func short(_ seconds: TimeInterval?) -> String {
        seconds.flatMap(Disappear.init(rawValue:))?.short ?? "Off"
    }
}

/// Who may post in a group or channel.
enum PostPolicy: String, Codable, CaseIterable, Identifiable {
    case everyone, admins, owner
    var id: String { rawValue }

    var label: String {
        switch self {
        case .everyone: "Everyone"
        case .admins: "Admins"
        case .owner: "Owner only"
        }
    }
}

/// A mailbox a group's owner or admin made for one of your devices, so other members can first reach you
/// without learning the mailbox you use with them.
struct IntroMailbox: Codable, Equatable {
    var receiveKey: Data
    var relay: String?
}

struct Conversation: Codable, Identifiable, Equatable {
    /// Most people a group, broadcast or channel's owner can add. Every message goes out as one envelope per member.
    static let maxMembers = 300

    var id = UUID()
    var kind: ConversationKind
    var title: String
    var avatar: Data?
    /// Fingerprints of everyone else in it. In a channel you run, the followers and admins; in one you
    /// follow, just the people who can post.
    var members: [String]
    var messages: [Message] = []
    var createdAt = Date()
    var pinned = false
    var muted = false
    var unread = 0
    /// Disappearing-message timer in seconds, or nil for off.
    var disappearAfter: TimeInterval?
    /// Which of your personas this chat belongs to. Nil is your main identity.
    var persona: UUID?
    /// The description shown on a group or channel.
    var about: String?
    /// Who created it: a fingerprint, or "me".
    var owner = "me"
    /// Admins besides the owner: fingerprints, and "me" if you're one.
    var admins: [String] = []
    /// Moderators in a group: fingerprints, and "me" if you're one. They can post when only admins can, and take
    /// ordinary members out, nothing else.
    var mods: [String] = []
    var postPolicy: PostPolicy = .everyone
    /// Bumped on every change to details or membership, so stale updates are ignored.
    var version = 0
    /// As an owner or admin: the introduction mailbox made for each member's device (by fingerprint, then device
    /// id), which the other members are given instead of the mailbox that member uses with you.
    var introsMade: [String: [String: Data]] = [:]
    /// As a member: the introduction mailboxes made for this device, where other members first say hello.
    var introsMine: [IntroMailbox] = []

    init(id: UUID = UUID(), kind: ConversationKind, title: String, avatar: Data? = nil, members: [String],
         messages: [Message] = [], pinned: Bool = false, unread: Int = 0, disappearAfter: TimeInterval? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.avatar = avatar
        self.members = members
        self.messages = messages
        self.pinned = pinned
        self.unread = unread
        self.disappearAfter = disappearAfter
        postPolicy = kind == .channel ? .admins : .everyone
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, avatar, members, messages, createdAt, pinned, muted, unread, disappearAfter, persona
        case about, owner, admins, mods, postPolicy, version, isOwner, introsMade, introsMine
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ConversationKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        avatar = try c.decodeIfPresent(Data.self, forKey: .avatar)
        members = try c.decode([String].self, forKey: .members)
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        disappearAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .disappearAfter)
        persona = try c.decodeIfPresent(UUID.self, forKey: .persona)
        about = try c.decodeIfPresent(String.self, forKey: .about)
        admins = try c.decodeIfPresent([String].self, forKey: .admins) ?? []
        mods = try c.decodeIfPresent([String].self, forKey: .mods) ?? []
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        introsMade = try c.decodeIfPresent([String: [String: Data]].self, forKey: .introsMade) ?? [:]
        introsMine = try c.decodeIfPresent([IntroMailbox].self, forKey: .introsMine) ?? []
        if let owner = try c.decodeIfPresent(String.self, forKey: .owner) {
            self.owner = owner
            postPolicy = (try? c.decodeIfPresent(PostPolicy.self, forKey: .postPolicy)) ?? .everyone
        } else {
            // Saved before roles existed: channels you followed had their owner as the only member.
            let ownedByMe = try c.decodeIfPresent(Bool.self, forKey: .isOwner) ?? true
            owner = kind == .channel && !ownedByMe ? (members.first ?? "") : "me"
            postPolicy = kind == .channel ? .admins : .everyone
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encode(members, forKey: .members)
        try c.encode(messages, forKey: .messages)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(muted, forKey: .muted)
        try c.encode(unread, forKey: .unread)
        try c.encodeIfPresent(disappearAfter, forKey: .disappearAfter)
        try c.encodeIfPresent(persona, forKey: .persona)
        try c.encodeIfPresent(about, forKey: .about)
        try c.encode(owner, forKey: .owner)
        try c.encode(admins, forKey: .admins)
        if !mods.isEmpty { try c.encode(mods, forKey: .mods) }
        try c.encode(postPolicy, forKey: .postPolicy)
        try c.encode(version, forKey: .version)
        if !introsMade.isEmpty { try c.encode(introsMade, forKey: .introsMade) }
        if !introsMine.isEmpty { try c.encode(introsMine, forKey: .introsMine) }
    }

    var lastActivity: Date { messages.last?.date ?? createdAt }

    var amOwner: Bool { owner == "me" }
    var amAdmin: Bool { amOwner || admins.contains("me") }

    func isAdmin(_ fingerprint: String) -> Bool { owner == fingerprint || admins.contains(fingerprint) }
    var amMod: Bool { mods.contains("me") }

    /// Whether `actor` may take `target` out. The owner can't be removed; the owner removes anyone else, admins
    /// remove anyone who isn't an admin, and mods (groups only) remove only ordinary members.
    func canRemove(_ target: String, by actor: String) -> Bool {
        guard target != owner, target != actor else { return false }
        if actor == owner { return true }
        if admins.contains(actor) { return !isAdmin(target) }
        if kind == .group, mods.contains(actor) { return !isAdmin(target) && !mods.contains(target) }
        return false
    }

    func canPost(_ fingerprint: String) -> Bool {
        switch postPolicy {
        case .everyone: true
        case .admins: isAdmin(fingerprint) || mods.contains(fingerprint)
        case .owner: owner == fingerprint
        }
    }

    /// The chat Pulshade's announcements arrive in. The same id everywhere, so linked devices agree on it.
    static let announcementsID = UUID(uuidString: "A770C3E5-0000-4000-8000-000000000001")!
    var isAnnouncements: Bool { id == Self.announcementsID }

    static func announcements() -> Conversation {
        var c = Conversation(id: announcementsID, kind: .channel, title: "Announcements", members: [])
        c.owner = Announcement.handle
        c.postPolicy = .owner
        c.about = "News from PULSHADE, for everyone. Only PULSHADE can post here."
        return c
    }

    /// What deleting this chat does, in plain words. Only the owner can delete a group or
    /// channel for everyone; anyone else leaves it.
    var deleteWarning: (title: String, detail: String) {
        switch kind {
        case .direct: ("Delete this chat for both of you?", "It disappears from their side too. This can't be undone.")
        case .group where amOwner: ("Delete this group for everyone?", "Every member loses it. This can't be undone.")
        case .group: ("Leave this group?", "It's removed from your Mac and the others are told you left.")
        case .channel where amOwner: ("Delete this channel for everyone?", "Every follower loses it. This can't be undone.")
        case .channel where isAnnouncements: ("Delete Announcements?", "It comes back with the next announcement.")
        case .channel: ("Leave this channel?", "The channel stays for everyone else.")
        case .broadcast: ("Delete this broadcast list?", "Messages already sent stay in each person's chat with you.")
        }
    }
}

enum StoryStyle: Codable, Equatable {
    case text(String, palette: Int)
    case image(Data, caption: String)
    /// A short H.264 clip (MP4 bytes), with its look already baked in.
    case video(Data, caption: String)
}

/// Who sees a story you post. Fingerprints of the persona's contacts.
enum StoryAudience: Codable, Equatable, Hashable {
    case everyone
    case only([String])
    case except([String])

    func includes(_ fingerprint: String) -> Bool {
        switch self {
        case .everyone: true
        case let .only(list): list.contains(fingerprint)
        case let .except(list): !list.contains(fingerprint)
        }
    }

    var people: [String] {
        switch self {
        case .everyone: []
        case let .only(list), let .except(list): list
        }
    }
}

/// How long a story stays up.
enum StoryLifetime: TimeInterval, CaseIterable, Identifiable {
    case sixHours = 21_600, twelveHours = 43_200, day = 86_400, twoDays = 172_800
    var id: TimeInterval { rawValue }

    var label: String {
        switch self {
        case .sixHours: "6 hours"
        case .twelveHours: "12 hours"
        case .day: "24 hours"
        case .twoDays: "48 hours"
        }
    }
}

/// What you last chose for a story, offered again for the next one.
struct StoryChoice: Codable, Equatable {
    var audience: StoryAudience = .everyone
    var lifetime: TimeInterval = StoryLifetime.day.rawValue
}

/// Where sending one of your stories stands, kept on the device that posted it: who has said they have it, and how
/// many times it's been sent again since. A build that doesn't know this field simply doesn't keep it.
/// Someone a story is still to be queued for.
struct StoryTarget: Codable, Equatable {
    var fingerprint: String
    var persona: UUID?
    var withClip: Bool
}

struct StoryDelivery: Codable, Equatable {
    var confirmed: [String] = []
    var resends = 0
    var last: Date?
    /// Every copy sealed for the story has been handed to the relay once. Sending it again later, to someone who
    /// hasn't confirmed, isn't the story uploading.
    var uploaded: Bool?
    /// The people it hasn't been queued for yet (it's queued for a few at a time). Saved, so a story that was still
    /// going out when Pulshade was closed carries on from here the next time it's open. Nil once everyone is queued.
    var left: [StoryTarget]?
}

struct Story: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Fingerprint of the author, or "me".
    var author: String
    var style: StoryStyle
    var date = Date()
    var seen = false
    /// Which of your personas posted or received it.
    var persona: UUID?
    /// Seconds it stays up. Nil is a day, as before lifetimes could be chosen.
    var lifetime: TimeInterval?
    /// Your own stories only: who it was shared with. Nil is everyone.
    var audience: StoryAudience?
    /// Your own stories only: who viewed it, and when.
    var viewers: [String: Date]?
    /// Someone else's story only: you've liked it.
    var liked: Bool?

    var expires: Date { date.addingTimeInterval(lifetime ?? StoryLifetime.day.rawValue) }
    var isLive: Bool { expires > Date() }
    var shownTo: StoryAudience { audience ?? .everyone }
    /// Your own stories only, on the device that posted it: whether contacts have it yet.
    var delivery: StoryDelivery?

    /// Whether it can ride along in a device sync, which fits a story only as small as a photo.
    var isSyncable: Bool {
        if case .video = style { return false }
        return true
    }

    /// A video story is only shown once its whole clip has arrived.
    var isReady: Bool {
        if case let .video(clip, _) = style { return !clip.isEmpty }
        return true
    }
}

/// The pieces of a clip that have arrived so far, waiting for the rest.
struct ClipParts: Codable {
    var author: String
    var persona: UUID?
    var date = Date()
    var of: Int
    var parts: [Int: Data] = [:]
    var isComplete: Bool { parts.count == of }
}

struct PendingPayload: Codable {
    var payload: Payload
    var message: UUID?
}

/// A sealed envelope waiting to go out. Kept in the vault so restarts don't lose it.
struct Outgoing: Codable, Identifiable {
    var id = UUID()
    var sendID: Data
    var blob: Data
    /// Which relay to drop it at. Nil means your default relay.
    var relay: String?
    /// The local message this envelope carries, so its tick can update.
    var message: UUID?
    /// A signal that's worthless late (see `Payload.isEphemeral`): dropped if it can't be sent.
    var ephemeral: Bool?
    /// The story this carries, so its upload can show progress.
    var story: UUID?
    /// The connection it's sent on. Each persona sends on its own, as it reads on its own, so the relay can't tell
    /// from one connection that two personas are the same person. Nil is the main persona's.
    var lane: String?
    /// This starts a call, so the relay rings the other phone instead of showing a banner. Nil for anything else.
    var rings: Bool?
    /// When it was queued, for the Network page. Nil for those queued by builds from before.
    var queued: Date? = Date()

    /// The sending lane for a persona (nil is the main one).
    static func lane(for persona: UUID?) -> String {
        persona.map { "send|" + $0.uuidString } ?? "send"
    }
}

/// How much a notification reveals. macOS keeps notifications outside our encryption, so less is safer.
enum NotificationContent: String, Codable, CaseIterable, Identifiable {
    case hidden, name, full
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hidden: "Hidden"
        case .name: "Name"
        case .full: "Message"
        }
    }
}

struct SecuritySettings: Codable, Equatable {
    /// Minutes of inactivity before locking. 0 means never.
    var autoLockMinutes = 5
    /// Hide the window from screenshots and screen recording.
    var blockCapture = true
    /// Blur chats whenever Pulshade isn't the front app.
    var blurWhenInactive = true
    var notifications = true
    var notificationContent: NotificationContent = .hidden
    var notificationSound = true
    /// The sound of a new message, when sound is on.
    var messageTone: MessageTone = .standard
    /// Let the relay wake this iPhone through Apple when mail arrives, so a locked phone hears about it. On with
    /// notifications, as in any messenger: without it a locked iPhone hears about nothing. Apple learns that the
    /// device was woken and when, and the relay holds its push token; anyone who'd rather not turns it off.
    var pushWake = true
    /// Whether `pushWake` was set by hand. It used to be off by default, so everyone from then saved "off"
    /// without choosing it: only a choice made by hand is kept.
    var pushWakeChosen = false
    /// Build a preview when you send a link. Off by default: building one visits the website from your own
    /// connection. Received previews never contact the website.
    var linkPreviews = false
    /// Tell people when their messages reach you.
    var deliveryReceipts = true
    /// Tell people when you've seen their messages, and see when they've seen yours. Never in one-time chats.
    var readReceipts = true
    /// Show people when you're typing, and see when they are.
    var typingIndicators = true
    /// Show people when you have Pulshade open, and see when they do. Off by default: the relay can tell when
    /// the signals go out, even though it can't read them.
    var onlineStatus = false
    /// Tell people when you've viewed their story, and see who viewed yours. Never from a one-time chat.
    var storyViews = true
    /// Pulse icon with an unread count in the menu bar.
    var menuBarIcon = true
    /// Reach the relay over Tor, so it never sees your IP address. On, unless this build's relay is on your own
    /// network, which Tor can't reach.
    var tor = SecuritySettings.torByDefault
    /// When Tor was last switched on, and whether it's been on since the account was made: what the warning
    /// about switching it off can truthfully say.
    var torSince: Date?
    var torFromStart = false
    /// Keep a sealed copy of your profile, contacts, groups, handles and settings (never chats) on the relay, so Detach
    /// can be an instant wipe and your recovery code still brings them back. The relay can't open it.
    var keepBackup = true

    /// A new account's settings.
    init() {
        torSince = tor ? Date() : nil
        torFromStart = tor
    }

    static var torByDefault: Bool {
        !(URL(string: AppData.defaultRelay)?.host().map(Invite.isLocal) ?? true)
    }

    /// Tolerates settings added after a vault was written.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SecuritySettings()
        autoLockMinutes = try c.decodeIfPresent(Int.self, forKey: .autoLockMinutes) ?? d.autoLockMinutes
        blockCapture = try c.decodeIfPresent(Bool.self, forKey: .blockCapture) ?? d.blockCapture
        blurWhenInactive = try c.decodeIfPresent(Bool.self, forKey: .blurWhenInactive) ?? d.blurWhenInactive
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? d.notifications
        notificationContent = (try? c.decodeIfPresent(NotificationContent.self, forKey: .notificationContent)) ?? d.notificationContent
        notificationSound = try c.decodeIfPresent(Bool.self, forKey: .notificationSound) ?? d.notificationSound
        messageTone = (try? c.decodeIfPresent(MessageTone.self, forKey: .messageTone)) ?? d.messageTone
        pushWakeChosen = try c.decodeIfPresent(Bool.self, forKey: .pushWakeChosen) ?? false
        pushWake = pushWakeChosen ? (try c.decodeIfPresent(Bool.self, forKey: .pushWake) ?? d.pushWake) : d.pushWake
        linkPreviews = try c.decodeIfPresent(Bool.self, forKey: .linkPreviews) ?? d.linkPreviews
        menuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .menuBarIcon) ?? d.menuBarIcon
        deliveryReceipts = try c.decodeIfPresent(Bool.self, forKey: .deliveryReceipts) ?? d.deliveryReceipts
        readReceipts = try c.decodeIfPresent(Bool.self, forKey: .readReceipts) ?? d.readReceipts
        typingIndicators = try c.decodeIfPresent(Bool.self, forKey: .typingIndicators) ?? d.typingIndicators
        onlineStatus = try c.decodeIfPresent(Bool.self, forKey: .onlineStatus) ?? d.onlineStatus
        storyViews = try c.decodeIfPresent(Bool.self, forKey: .storyViews) ?? d.storyViews
        tor = try c.decodeIfPresent(Bool.self, forKey: .tor) ?? d.tor
        torSince = try c.decodeIfPresent(Date.self, forKey: .torSince)
        torFromStart = try c.decodeIfPresent(Bool.self, forKey: .torFromStart) ?? false
        keepBackup = try c.decodeIfPresent(Bool.self, forKey: .keepBackup) ?? d.keepBackup
    }
}

/// What a decoy's settings say it has set up. Nothing behind it is real.
struct Facade: Codable, Equatable {
    var decoy = false
    var panic = false
}

struct AppData: Codable {
    /// Which shape this data was saved in. Bumped whenever a field is added, so a build that doesn't know the newest
    /// fields refuses the data instead of opening it, dropping them and saving it back without. Data from before
    /// this was written has none, which reads as 0.
    var format = AppData.currentFormat
    /// The newest shape this build understands. Raise it, and update `AppDataFormatTests`, with any change to what
    /// `AppData`, `Profile` or `Contact` save.
    /// 4: a profile note can list the contacts it is for.
    /// 5: a sealed backup is kept on the relay, and when it was last saved.
    /// 7: a profile can have more than one @handle in use; messages can be videos; a device says if it reads frames.
    static let currentFormat = 7
    var profile = Profile()
    var contacts: [Contact] = []
    var invites: [OpenInvite] = []
    var conversations: [Conversation] = []
    var stories: [Story] = []
    var outbox: [Outgoing] = []
    var theme: String = Theme.dark.id
    var relay = AppData.defaultRelay
    /// A relay to put in new invites, from builds that had crew relays. Only ever used if it's an allowed one.
    var inviteRelay: String?
    var security = SecuritySettings()
    /// The decoy identity's seed, kept here (inside the real vault) so it can be removed cleanly later.
    /// This device's id, sent with every envelope so people can tell your devices apart.
    var deviceID = Data.random(16)
    /// Links you're offering to new devices, waiting for them to scan.
    var linkOffers: [LinkOffer] = []
    /// Chat codes you made whose chats haven't ended yet.
    var chatCodes: [ChatCodeOffer] = []
    var personas: [Persona] = []
    var requests: [FriendRequest] = []
    /// Fingerprints whose requests are dropped without a trace.
    var blocked: [String] = []
    /// The names people had when you blocked them, so the blocked list can show who they are.
    var blockedNames: [String: String] = [:]
    /// The persona you're currently acting as. Nil is your main identity.
    var activePersona: UUID?
    var decoySeed: Data?
    /// The identity the panic passcode opens, kept so it can be removed cleanly.
    var panicSeed: Data?
    /// Only in the panic passcode's landing account: the public key a relay backup is filed under, to erase it with
    /// the delete-only token (see `forgetToken`). Kept until the relay has answered, then dropped.
    var pendingBackupForget: Data?
    /// Inside a decoy: the decoy and panic passcodes it pretends to have.
    var facade = Facade()
    /// Hashes of envelopes that came outside a ratchet session, so a replayed one is ignored.
    var seenEnvelopes: [String: Date] = [:]
    /// Leftover handles from older versions have been looked for. Done once, not at every unlock.
    var handlesTidied = false
    /// Which profile fields have been sent to contacts once since they started travelling with profiles: 1 bios,
    /// 2 @handles. Before, contacts only had them after an edit.
    var profileShared = 0
    /// The audience and lifetime last chosen for a story, by persona ("main" for your main identity).
    var storyChoices: [String: StoryChoice] = [:]
    /// Video clips still arriving, by story.
    var clipParts: [UUID: ClipParts] = [:]
    /// Announcements already shown, so one deleted here doesn't come back.
    var announcementsSeen: [String] = []
    /// When the sealed backup on the relay was last saved, and a hash of what it held (without these two fields),
    /// so an unchanged account isn't uploaded again. Neither is ever in the backup itself.
    var backupSavedAt: Date?
    var backupDigest: Data?
    init() {}

    /// The relay new identities use. A build can set `PulshadeRelay` in its Info.plist (the iPhone
    /// build points at the relay on your Mac); otherwise it's a relay on this machine.
    /// The same relay's ordinary https address, used when Tor is off. Nil until the relay has one, and while it
    /// hasn't, Tor can't be switched off: an onion address can only be reached over Tor.
    static var directRelay: String? {
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["PULSHADE_TEST_RELAY_DIRECT"] { return Invite.validRelay(test) }
        #endif
        guard let configured = Bundle.main.object(forInfoDictionaryKey: "PulshadeRelayDirect") as? String,
              let relay = Invite.validRelay(configured), let url = URL(string: relay), !Tor.isOnion(url) else { return nil }
        return relay
    }

    static var defaultRelay: String {
        #if DEBUG
        // Tests run against their own throwaway relay, never the real one.
        if let test = Invite.validRelay(ProcessInfo.processInfo.environment["PULSHADE_TEST_RELAY"]) { return test }
        #endif
        let configured = Bundle.main.object(forInfoDictionaryKey: "PulshadeRelay") as? String
        return Invite.validRelay(configured) ?? "http://127.0.0.1:7878"
    }

    /// Tolerates fields added after a vault was written.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Saved by a newer build: leave it exactly as it is rather than lose what this one can't read.
        let written = try c.decodeIfPresent(Int.self, forKey: .format) ?? 0
        guard written <= Self.currentFormat else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "Saved by a newer version of PULSHADE")
        }
        format = Self.currentFormat
        profile = try c.decodeIfPresent(Profile.self, forKey: .profile) ?? Profile()
        contacts = try c.decodeIfPresent([Contact].self, forKey: .contacts) ?? []
        invites = try c.decodeIfPresent([OpenInvite].self, forKey: .invites) ?? []
        conversations = try c.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        stories = try c.decodeIfPresent([Story].self, forKey: .stories) ?? []
        outbox = try c.decodeIfPresent([Outgoing].self, forKey: .outbox) ?? []
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? Theme.dark.id
        relay = try c.decodeIfPresent(String.self, forKey: .relay) ?? AppData.defaultRelay
        inviteRelay = try c.decodeIfPresent(String.self, forKey: .inviteRelay)
        security = try c.decodeIfPresent(SecuritySettings.self, forKey: .security) ?? SecuritySettings()
        decoySeed = try c.decodeIfPresent(Data.self, forKey: .decoySeed)
        deviceID = try c.decodeIfPresent(Data.self, forKey: .deviceID) ?? .random(16)
        linkOffers = (try? c.decodeIfPresent([LinkOffer].self, forKey: .linkOffers)) ?? []
        chatCodes = (try? c.decodeIfPresent([ChatCodeOffer].self, forKey: .chatCodes)) ?? []
        personas = try c.decodeIfPresent([Persona].self, forKey: .personas) ?? []
        requests = (try? c.decodeIfPresent([FriendRequest].self, forKey: .requests)) ?? []
        blocked = try c.decodeIfPresent([String].self, forKey: .blocked) ?? []
        blockedNames = (try? c.decodeIfPresent([String: String].self, forKey: .blockedNames)) ?? [:]
        activePersona = try c.decodeIfPresent(UUID.self, forKey: .activePersona)
        panicSeed = try c.decodeIfPresent(Data.self, forKey: .panicSeed)
        pendingBackupForget = try c.decodeIfPresent(Data.self, forKey: .pendingBackupForget)
        facade = (try? c.decodeIfPresent(Facade.self, forKey: .facade)) ?? Facade()
        seenEnvelopes = (try? c.decodeIfPresent([String: Date].self, forKey: .seenEnvelopes)) ?? [:]
        handlesTidied = (try? c.decodeIfPresent(Bool.self, forKey: .handlesTidied)) ?? false
        profileShared = (try? c.decodeIfPresent(Int.self, forKey: .profileShared)) ?? 0
        storyChoices = (try? c.decodeIfPresent([String: StoryChoice].self, forKey: .storyChoices)) ?? [:]
        clipParts = (try? c.decodeIfPresent([UUID: ClipParts].self, forKey: .clipParts)) ?? [:]
        announcementsSeen = (try? c.decodeIfPresent([String].self, forKey: .announcementsSeen)) ?? []
        backupSavedAt = try? c.decodeIfPresent(Date.self, forKey: .backupSavedAt)
        backupDigest = try? c.decodeIfPresent(Data.self, forKey: .backupDigest)
    }
}

extension Announcement {
    /// Signed by the Pulshade Admin key this build carries.
    @MainActor var isGenuine: Bool { isGenuine(adminKey: AppModel.adminKey) }
}

extension Collectible {
    /// Letters and digits nobody misreads: no I, L, O or U.
    private static let codeAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// A fresh backup code: 80 random bits, as XXXX-XXXX-XXXX-XXXX.
    static func newBackupCode() -> String {
        let chars = (0..<16).map { _ in codeAlphabet[Int.random(in: 0..<codeAlphabet.count)] }
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// A code as typed: capitals, no spaces or dashes, and O, I and L read as the digits they look like. The relay
    /// does the same.
    static func normalisedCode(_ code: String) -> String {
        String(code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.map { c -> Character in
            switch c { case "O": "0"; case "I", "L": "1"; default: c }
        })
    }

    static func codeHash(_ code: String) -> Data { Data(SHA256.hash(data: Data(normalisedCode(code).utf8))) }

    /// Signed by the Pulshade Admin key this build carries, for the account with `owner`'s key.
    @MainActor func isGenuine(for owner: Data) -> Bool {
        isGenuine(for: owner, adminKey: AppModel.adminKey, petKey: AppModel.petKey)
    }
}
