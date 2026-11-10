import Foundation
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// One device: its id and the mailbox it reads.
struct DeviceCard: Codable, Equatable {
    var id: Data
    var sendID: Data
    /// What the device calls itself, for your own linked devices.
    var name: String?
}

/// How to reach someone: their public keys and the send id of a mailbox they read.
struct PeerCard: Codable, Equatable {
    var name: String
    var avatar: Data?
    var color: Int?
    var signingKey: Data
    var agreementKey: Data
    var sendID: Data
    /// The relay `sendID` lives on, when it says one (only ever Pulshade's own in the official app).
    var relay: String?
    /// The device `sendID` belongs to.
    var device: Data?
    /// All their devices, when known (in group rosters).
    var devices: [DeviceCard]?

    /// Every device this card describes.
    var allDevices: [DeviceCard] {
        if let devices, !devices.isEmpty { return devices }
        return [DeviceCard(id: device ?? Data(), sendID: sendID)]
    }
}

struct WireMessage: Codable, Equatable {
    var id: UUID
    /// Nil for one-to-one chats; the shared id for groups and channels.
    var conversation: UUID?
    var kind: ConversationKind
    var text: String
    var image: Data?
    var voice: VoiceNote?
    var date: Date
    /// Seconds until it disappears, if the chat has a timer.
    var expiresIn: TimeInterval?
    /// The quoted message; `author` is a fingerprint, never "me".
    var reply: ReplyRef?
    var preview: LinkPreview?
    /// Set on a video: its clip follows in pieces (`storyPart`, under this message's id), and `image` is a still
    /// from it. Apps from before chat videos leave this out and show the still as a photo.
    var clip: ClipInfo?
    /// A collectible the sender shows. Older apps see only `text`, which says what it is.
    var collectible: Collectible?
    /// A note of the sender's profile, as a card (no words in it). Older apps see only `text`.
    var note: NoteCard?
    /// People @-mentioned in a group message. Older apps ignore it and just show the "@Name" text.
    var mentions: [Mention]?
    /// A file on the relay (see `Attachment`). Apps from before it ignore it and show `text`, which names the file.
    var attachment: Attachment?
}

/// What a message says about the video that follows it.
struct ClipInfo: Codable, Equatable {
    var seconds: Double
}

struct GroupInfo: Codable, Equatable {
    var id: UUID
    var kind: ConversationKind
    var title: String
    var avatar: Data?
    /// The people the recipient should know about, minus the sender and the recipient. In a channel,
    /// followers only get the admins; admins get everyone.
    var roster: [PeerCard]
    var about: String?
    /// Signing key of the owner.
    var owner: Data?
    /// Signing keys of the admins besides the owner.
    var admins: [Data]?
    /// Signing keys of the moderators. Absent from apps that don't know the role.
    var mods: [Data]?
    var postPolicy: PostPolicy?
    var version: Int?
    /// The recipient's own introduction mailboxes, by device id (hex). Only the recipient gets these keys; the
    /// other members only get where to write.
    var intros: [String: Data]?
}

/// Everything that can travel inside an envelope.
///
/// Only the session setup cases travel bare. Everything people actually say goes inside
/// `.ratchet`, so it gets a fresh key per message.
extension Payload {
    /// The payload as it travels. `framed` (only for someone whose app says it reads frames, see `Envelope.reads`)
    /// sends the one big field of a ratchet message or a video piece raw, after the rest as JSON; everything else,
    /// and everything for an older app, is plain JSON as before.
    func wire(framed: Bool) throws -> Data {
        if framed {
            switch self {
            case let .ratchet(message) where !message.ciphertext.isEmpty:
                let rest = Payload.ratchet(RatchetMessage(header: message.header, ciphertext: Data()))
                return Frame.join(try JSONEncoder.pulshade.encode(rest), message.ciphertext)
            case let .storyPart(id, index, of, bytes) where !bytes.isEmpty:
                return Frame.join(try JSONEncoder.pulshade.encode(Payload.storyPart(id: id, index: index, of: of, bytes: Data())), bytes)
            default: break
            }
        }
        return try JSONEncoder.pulshade.encode(self)
    }

    /// Reads either form.
    static func fromWire(_ data: Data) throws -> Payload {
        guard data.first == Frame.mark else { return try JSONDecoder.pulshade.decode(Payload.self, from: data) }
        guard let (header, tail) = Frame.split(data) else { throw EnvelopeError.malformed }
        switch try JSONDecoder.pulshade.decode(Payload.self, from: header) {
        case let .ratchet(message): return .ratchet(RatchetMessage(header: message.header, ciphertext: tail))
        case let .storyPart(id, index, of, _): return .storyPart(id: id, index: index, of: of, bytes: tail)
        default: throw EnvelopeError.malformed
        }
    }
}

enum Payload: Codable, Equatable {
    /// First message on a new invite: "this is me, write back here, and here's a handshake".
    case hello(PeerCard, SessionInit)
    /// A friend request to a public profile: like hello, with a note, and nothing happens until accepted.
    case request(PeerCard, SessionInit, note: String)
    case sessionInit(SessionInit)
    /// A device introducing itself and opening a session: "I'm this device of the account you know; reach me here".
    case deviceHello(DeviceCard, SessionInit)
    case sessionAccept(SessionAccept)
    /// "I took the spare key you left for me (see `SpareSlot`), and here's my answer; I'm this device, reach me here."
    /// The answer opens the session on your side: the sender is already writing on it. Older apps can't read it.
    case spareAccept(DeviceCard, SessionAccept)
    case ratchet(RatchetMessage)

    /// `handle` is only a claim: the receiver checks it against the directory before showing it.
    /// `badge` too: the receiver checks it against the creator key.
    case profile(name: String, avatar: Data?, color: Int?, banner: Data? = nil, bio: String? = nil, handle: String? = nil,
                 badge: Collectible? = nil, links: [ProfileLink]? = nil, collectibles: [Collectible]? = nil,
                 notes: [ProfileNote]? = nil)
    case message(WireMessage)
    /// The messages reached the device (`read` nil or false), or were seen in the open chat. Older apps ignore
    /// `read`, so a read receipt still counts as delivered there.
    case receipt(ids: [UUID], read: Bool? = nil)
    case group(GroupInfo)
    /// Over a 1:1 chat: you're being added to a group that shares one mailbox (see `GroupInvite`). Only sent to apps
    /// that said they take part in those.
    case groupInvite(GroupInvite)
    /// Over a 1:1 chat, the answer to an invite: the card the newcomer will use in that group.
    case groupJoin(group: UUID, card: MemberCard)
    /// In a group's mailbox: a new version of its settings.
    case groupSettings(GroupSettings)
    /// In a group's mailbox: the next epoch's key, sealed to each member who stays.
    case groupRekey(GroupRekey)
    /// In a group's mailbox: a member's own card with their picture (the settings carry it without).
    case memberCard(MemberCard)
    /// A story, or a new version of one already sent (same id, edited text or lifetime). `lasts` is in seconds;
    /// older apps leave it out, meaning a day.
    case story(id: UUID, style: StoryStyle, date: Date, lasts: TimeInterval? = nil)
    case storyRemoved(id: UUID)
    /// Every story the sender had up is taken back, when their device was wiped (Detach) and doesn't remember which
    /// they were. Builds from before can't read it and leave it, so their copies run out with the day.
    case storiesCleared
    /// The sender viewed this story of yours. The author's app answers every one with `storyViewedAck`, so a
    /// viewer that gets no answer can try again.
    case storyViewed(id: UUID)
    /// The author's app has dealt with a view of this story, whether or not it recorded one: nothing more is owed.
    case storyViewedAck(id: UUID)
    /// The sender has this story of yours, whole (a video: with its clip), so you needn't send it again. Sent only
    /// with delivery receipts on. Apps from before this never send it, and are sent a story a few times instead.
    case storyReceived(id: UUID)
    /// One piece of a video story's clip (the story itself, sent first, has an empty clip). Pieces are small enough
    /// for one relay message each, and the receiver puts them together once all `of` have arrived.
    case storyPart(id: UUID, index: Int, of: Int, bytes: Data)
    /// "Your video stopped arriving": the pieces still missing (nil for all of them), asked of whoever posted it.
    /// They send the story again with those pieces. Builds from before it can't read it and leave it.
    case storyWant(id: UUID, parts: [Int]?)
    /// A video's clip (a story's, or a chat video's, under the same id as `storyPart`) kept sealed on the relay: fetch it
    /// from there instead of waiting for pieces. Only sent to apps that said they read files (`Envelope.reads`).
    case clipBlob(id: UUID, clip: Attachment)
    /// Delete for everyone: the sender takes their own messages back.
    case unsend(ids: [UUID])
    /// Nil emoji clears your reaction.
    case reaction(message: UUID, emoji: String?)
    /// "I'm typing" in a direct chat (nil) or a group. Never stored.
    case typing(conversation: UUID?)
    /// "I'm here" about once a minute while the sender has Pulshade open, and "I've gone" when they leave. Never stored.
    case presence(online: Bool)
    /// "Send me your online status" (true) or "don't" (false). Presence only goes to contacts who asked for it,
    /// so an app that doesn't know it is never sent it.
    case wantsPresence(Bool)
    /// Turns the disappearing timer on (seconds) or off (nil) for a direct chat (nil) or group.
    case disappearing(conversation: UUID?, seconds: TimeInterval?)
    /// Forget the sender and your chat with them: their burner self-destructed, or they removed you as a contact.
    case burn
    /// "Request accepted: from now on, write to this mailbox instead of my public one."
    case accepted(sendID: Data)
    /// "You reached this device of mine through a group introduction: write to it here from now on."
    case moved(DeviceCard)
    /// Between your own devices only: keep each other up to date.
    case sync(SyncEvent)
    /// The sender deleted this chat (nil for your direct chat with them). For groups and channels
    /// it only counts from the owner.
    case chatDeleted(conversation: UUID?)
    /// The sender left a group or channel.
    case left(conversation: UUID)
    /// An admin removed you from a group or channel.
    case removed(conversation: UUID)
    /// The sender logged out of the device this came from: stop sending to it.
    case deviceRemoved
    /// The sender erased their account: forget them completely, with everything they ever sent.
    case erased
    /// An abuse report, sent only to the operator's report mailbox.
    case report(ReportCard)
    /// Ringing: where to meet on the relay and the key for the audio.
    case callOffer(CallInvite)
    /// Picked up, or declined (or busy).
    case callAnswer(id: UUID, accepted: Bool)
    /// Hung up, or stopped ringing.
    case callEnd(id: UUID)
    /// From a friend's notification helper while their phone is locked: "this device has these envelopes of yours",
    /// each named by `LockedDelivery.digest(of:)`. Sent outside the chat's keys, which the helper never holds, so it
    /// can't say which message: the sender's app knows from the envelope. Older apps can't read it and drop it.
    case collected(digests: [Data])

    /// Signals that are worthless late: only the newest one waiting for a mailbox is kept, and one that fails
    /// to send is dropped, not retried.
    var isEphemeral: Bool {
        switch self {
        case .typing, .presence: true
        default: false
        }
    }

    /// For a signal, the kind the relay may replace with the next one like it: only the newest "typing" or "I'm here"
    /// is worth holding for a device that isn't collecting.
    var collapseKind: String? {
        switch self {
        case .typing: "typing"
        case .presence: "presence"
        default: nil
        }
    }

    /// Whether this starts a call, which rings the other phone like a phone call.
    var rings: Bool {
        if case .callOffer = self { true } else { false }
    }

    /// The story this carries, so its upload can be followed.
    var storyID: UUID? {
        switch self {
        case let .story(id, _, _, _): id
        case let .storyPart(id, _, _, _): id
        default: nil
        }
    }

    /// The story whose view this reports, so one still waiting on an answer can be told from one already sent.
    var storyViewID: UUID? {
        if case let .storyViewed(id) = self { return id }
        return nil
    }

    /// Setup messages are sealed to the identity key directly; the rest need a session.
    var isSetup: Bool {
        switch self {
        case .hello, .request, .sessionInit, .deviceHello, .sessionAccept, .spareAccept, .ratchet: true
        default: false
        }
    }
}

/// What a public profile says. Signed by the identity's Ed25519 key and stored, opaque, by the relay.
struct DirectoryProfile: Codable, Equatable {
    var handle: String
    var name: String
    var bio: String
    var avatar: Data?
    var banner: Data? = nil
    var color: Int?
    var signingKey: Data
    var agreementKey: Data
    /// The public request mailbox.
    var sendID: Data
    var relay: String?
    /// Links and wallets this profile shows as icons. Checked again by whoever reads them.
    var links: [ProfileLink]? = nil
    /// Text notes this profile shows, public or locked with a password. Checked again by whoever reads them.
    var notes: [ProfileNote]? = nil
    /// Shown after the name once it checks out against the creator key and this profile's key.
    var badge: Collectible? = nil

    var fingerprint: String { Identity.fingerprint(of: signingKey) }

    /// Short handles and brand names can only be claimed by the creator's key, which the relay enforces.
    static let reservedNames: Set<String> = ["zeekz", "pulshade", "official", "admin", "support", "help", "team", "security",
                                             "abuse", "report", "safety", "moderation"]
    /// Handles that mean "I want to report someone": searching one opens the report form.
    static let reportHandles: Set<String> = ["abuse", "report", "safety", "moderation"]
    static func isReserved(_ handle: String) -> Bool { handle.count < 3 || reservedNames.contains(handle) }
    var isCreator: Bool { Self.isReserved(handle) }

    var card: PeerCard {
        PeerCard(name: name, avatar: avatar, color: color, signingKey: signingKey, agreementKey: agreementKey,
                 sendID: sendID, relay: relay)
    }

    /// The link that opens this handle's profile in Pulshade, for a website's button: `pulshade://u/<handle>`.
    /// With the owner's key it ends `?k=<key check>`, so the link only ever opens that account's profile.
    static func link(_ handle: String, key: Data? = nil) -> String {
        "pulshade://u/" + handle + (key.map { "?k=" + keyCheck(of: $0) } ?? "")
    }

    /// The start of the key's fingerprint: too long to find another key that shares it.
    static func keyCheck(of key: Data) -> String { String(Identity.fingerprint(of: key).prefix(16)) }

    /// Whether this profile is the account a link's key check names.
    func matches(keyCheck: String) -> Bool { Self.keyCheck(of: signingKey) == keyCheck }

    /// The handle in a profile link and its key check, if it has one, or nil if it isn't a profile link.
    static func handle(fromLink url: URL) -> (handle: String, keyCheck: String?)? {
        guard url.scheme?.lowercased() == "pulshade", url.host()?.lowercased() == "u", url.pathComponents.count == 2,
              let handle = validHandle(url.lastPathComponent) else { return nil }
        let check = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "k" }?.value?.lowercased()
        return (handle, check)
    }

    static func validHandle(_ raw: String) -> String? {
        let handle = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
        guard (1...24).contains(handle.count), handle.allSatisfy({ $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" })
        else { return nil }
        return handle
    }
}

// MARK: - Keeping your own devices in sync

/// Which conversation something happened in: a shared group or channel id, or the direct chat with someone.
struct ConvoRef: Codable, Equatable {
    var shared: UUID?
    var peer: String?
    var persona: UUID?
}

/// Everything one of your devices knows about a contact, minus its own mailboxes and sessions.
struct ContactCard: Codable, Equatable {
    var fingerprint: String
    var name: String
    var nickname: String
    var avatar: Data?
    var banner: Data? = nil
    var color: Int?
    var verified: Bool
    var signingKey: Data
    var agreementKey: Data
    var devices: [DeviceCard]
    var relay: String?
    var hidden: Bool
    var awaitingAcceptance: Bool
    var persona: UUID?
}

/// A group, channel or list as your other devices should know it (without its messages).
struct ConversationCard: Codable, Equatable {
    var id: UUID
    var kind: ConversationKind
    var title: String
    var avatar: Data?
    var about: String?
    var owner: String
    var admins: [String]
    var postPolicy: PostPolicy
    var version: Int
    var members: [String]
    var persona: UUID?
    var disappearAfter: TimeInterval?
    var pinned: Bool? = nil
    var muted: Bool? = nil
    var mods: [String]? = nil
}

/// What one of your devices tells the others when you act on it.
enum SyncEvent: Codable, Equatable {
    /// The first message on a new session between two of your devices.
    case hello
    /// A group that shares one mailbox, as this account is in it: its settings and the epochs' keys. Only between your
    /// own devices, which share the group key (it comes from the account's seed), each with a chain of its own.
    case sharedGroup(persona: UUID?, settings: GroupSettings, epochs: [GroupEpoch])
    case sent(ConvoRef, WireMessage)
    case reaction(message: UUID, emoji: String?)
    case unsend(ids: [UUID])
    case deleted(ConvoRef)
    case disappearing(ConvoRef, seconds: TimeInterval?)
    case contact(ContactCard)
    case conversation(ConversationCard)
    case profile(persona: UUID?, Profile)
    case persona(Persona)
    case personaDeleted(UUID)
    case story(Story)
    case storyRemoved(UUID)
    /// A contact was removed on another device: forget them here too.
    case contactRemoved(fingerprint: String, persona: UUID?)
    case blocked(String)
    case read(ConvoRef)
    /// The mailbox behind a persona's public @handle, shared so every device receives requests. Nil when unlisted.
    case publicInvite(persona: UUID?, receiveKey: Data?, relay: String?)
    /// A friend request one device received, so the others show it too.
    case requestReceived(FriendRequest)
    /// A request was accepted, declined or blocked on another device.
    case requestResolved(fingerprint: String, persona: UUID?)
    /// One of your devices logged out.
    case deviceLoggedOut(Data)
    /// The account was burned: wipe this device too, leaving no trace.
    case accountErased
    /// The account was detached from every device: say goodbye to contacts, then wipe this device.
    case accountDetached
    /// Past messages from one chat, sent to a newly linked device in pieces.
    case history(conversation: UUID, messages: [Message])
    /// A call was answered or declined on one of your devices: the others stop ringing.
    case callHandled(UUID)
}
