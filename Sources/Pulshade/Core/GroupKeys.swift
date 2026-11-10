import Foundation
import CryptoKit

// Groups that share one mailbox on the relay (see docs/groups-design.md).
//
// A message is sealed once, with the sender's own chain key for the current *epoch*, and posted once into the group's
// mailbox; every member reads it from there. Everyone who holds the epoch key can work out every member's chain, so a
// new epoch is started whenever someone leaves or is removed: they don't get the new key, and can't read what follows.
// Each member signs as a key made for this group alone, so two groups can't tell they share someone, and nobody in a
// group can pass a message off as another member's.

private func derive(_ key: Data, _ label: String, salt: Data = Data()) -> Data {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: salt, info: Data(label.utf8), outputByteCount: 32)
        .withUnsafeBytes { Data($0) }
}

private func hmac(_ key: Data, _ byte: UInt8) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data([byte]), using: SymmetricKey(data: key)))
}

private func bytes(_ uuid: UUID) -> Data {
    withUnsafeBytes(of: uuid.uuid) { Data($0) }
}

private func be32(_ n: UInt32) -> Data { withUnsafeBytes(of: n.bigEndian) { Data($0) } }

/// Epoch and version numbers that arrive from others are only taken in this range, so nothing can overflow on them.
let groupNumberRange = 1..<Int(Int32.max)

/// This account's keys in one group: made from the account's seed and the group's id, so every device of the account
/// (and a recovered one) has the same, and they are tied to nothing outside the group.
struct GroupMemberKeys {
    let signing: Curve25519.Signing.PrivateKey
    let agreement: Curve25519.KeyAgreement.PrivateKey

    init(seed: Data, group: UUID) {
        let root = derive(seed, "pulshade.group.member.v1", salt: bytes(group))
        signing = try! .init(rawRepresentation: derive(root, "signing"))
        agreement = try! .init(rawRepresentation: derive(root, "agreement"))
    }

    var publicKey: Data { signing.publicKey.rawRepresentation }
    var fingerprint: String { Identity.fingerprint(of: publicKey) }
}

/// One period of a group's keys. Everything the group says in it is sealed with keys that come from `key`.
struct GroupEpoch: Codable, Equatable {
    var number: Int
    var key: Data
    /// How long the relay keeps the group's mail, in days (1 to 7).
    var days: Int = 7
    var started: Date
    /// Whose new-epoch hand-out this came in (a candidate's), so one member can't crowd out another's.
    var from: Data? = nil

    /// Well-formed as received: a number in range and a whole key.
    var isValid: Bool { groupNumberRange.contains(number) && key.count == 32 && (1...7).contains(days) }

    static func fresh(number: Int, days: Int = 7) -> GroupEpoch {
        GroupEpoch(number: number, key: .random(32), days: min(max(days, 1), 7), started: Date())
    }

    /// The mailbox this epoch's mail goes to. A new epoch means a new mailbox, so the relay can't line the two up by it.
    var receiveKey: Data { derive(key, "pulshade.group.mailbox.v1") }
    /// A check of the key that the signed settings carry, so a key handed over (in an invite, a new epoch, or from
    /// another of your devices) is only used if it is the one the group's settings name.
    var check: Data { derive(key, "pulshade.group.epoch-check.v1") }
    var sendID: Data { Mailbox.sendID(for: receiveKey) }
    fileprivate var outerKey: SymmetricKey { SymmetricKey(data: derive(key, "pulshade.group.outer.v1")) }

    /// Where a member's chain starts in this epoch, on one of their devices (each device of an account has its own
    /// chain, so two never use the same key).
    func chainStart(for member: Data, device: Data) -> SenderChain {
        SenderChain(key: derive(key, "pulshade.group.chain.v1", salt: member + device), index: 0)
    }
}

/// A member's sending chain: each message takes the next key, and the chain moves on, so a key once used can't be
/// worked out again from what's kept.
struct SenderChain: Codable, Equatable {
    var key: Data
    var index: UInt32

    /// The key for message `index`, and the chain after it.
    func step() -> (messageKey: Data, next: SenderChain) {
        (hmac(key, 1), SenderChain(key: hmac(key, 2), index: index + 1))
    }
}

/// What a member says about themselves in a group: the keys they use there and the name they show. Signed by those
/// keys, so whoever passes the card on (an admin) can include it or leave it out, but not change it.
struct MemberCard: Codable, Equatable {
    var signingKey: Data
    var agreementKey: Data
    var name: String
    /// The picture itself travels only in the member's own card posts; the settings carry the card without it, and
    /// the hash (which is signed) says which picture belongs.
    var avatar: Data?
    var avatarHash: Data?
    var color: Int?
    var signature: Data

    var fingerprint: String { Identity.fingerprint(of: signingKey) }

    private static func signable(group: UUID, signingKey: Data, agreementKey: Data, name: String, avatarHash: Data?, color: Int?) -> Data {
        var d = Data("pulshade.group.card.v2".utf8)
        d += bytes(group) + signingKey + agreementKey
        d += Data(SHA256.hash(data: Data(name.utf8))) + (avatarHash ?? Data(count: 32))
        d += be32(UInt32(truncatingIfNeeded: color ?? -1))
        return d
    }

    /// A card's picture is a small thumbnail.
    static let maxAvatar = 16 * 1024

    /// The card as the settings carry it: everything but the picture.
    var withoutAvatar: MemberCard {
        var c = self
        c.avatar = nil
        return c
    }

    /// The same card, picture and signature aside (signatures differ each time a card is signed).
    func sameCard(as other: MemberCard) -> Bool {
        signingKey == other.signingKey && agreementKey == other.agreementKey && name == other.name
            && avatarHash == other.avatarHash && color == other.color
    }

    static func make(_ keys: GroupMemberKeys, group: UUID, name: String, avatar: Data?, color: Int?) -> MemberCard {
        let name = String(name.prefix(64))
        let avatar = avatar.flatMap { $0.count <= maxAvatar ? $0 : nil }
        let hash = avatar.map { Data(SHA256.hash(data: $0)) }
        let message = signable(group: group, signingKey: keys.publicKey, agreementKey: keys.agreement.publicKey.rawRepresentation,
                               name: name, avatarHash: hash, color: color)
        return MemberCard(signingKey: keys.publicKey, agreementKey: keys.agreement.publicKey.rawRepresentation, name: name,
                          avatar: avatar, avatarHash: hash, color: color, signature: (try? keys.signing.signature(for: message)) ?? Data())
    }

    func verified(group: UUID) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey), agreementKey.count == 32,
              name.count <= 64, name.utf8.count <= 256, (avatar?.count ?? 0) <= Self.maxAvatar, avatarHash.map({ $0.count == 32 }) ?? true else { return false }
        // A picture, when it comes, must be the one the signed hash names.
        if let avatar, avatarHash != Data(SHA256.hash(data: avatar)) { return false }
        return key.isValidSignature(signature, for: Self.signable(group: group, signingKey: signingKey, agreementKey: agreementKey,
                                                                  name: name, avatarHash: avatarHash, color: color))
    }
}

/// Everything about a group: its look, who is in it, who may do what, and which epoch it is in. One signed document,
/// numbered: every member keeps the newest and accepts a new one only from someone allowed to make that change.
struct GroupSettings: Codable, Equatable {
    var group: UUID
    var kind: ConversationKind
    var version: Int
    var epoch: Int
    var title: String
    var about: String?
    var avatar: Data?
    /// Member keys (signing), not fingerprints of accounts.
    var owner: Data
    var admins: [Data] = []
    var mods: [Data] = []
    var postPolicy: PostPolicy = .everyone
    var disappearAfter: TimeInterval?
    var members: [MemberCard]
    /// The check of the current epoch's key (`GroupEpoch.check`).
    var epochCheck: Data?
    /// Who signed this version, and the signature.
    var signer = Data()
    var signature = Data()

    func signable() -> Data {
        var copy = self
        copy.signature = Data()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dataEncodingStrategy = .base64
        return Data("pulshade.group.settings.v1".utf8) + ((try? encoder.encode(copy)) ?? Data())
    }

    mutating func sign(with keys: GroupMemberKeys) {
        signer = keys.publicKey
        signature = (try? keys.signing.signature(for: signable())) ?? Data()
    }

    var signatureIsValid: Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signer) else { return false }
        return key.isValidSignature(signature, for: signable())
    }

    func card(_ key: Data) -> MemberCard? { members.first { $0.signingKey == key } }
    func isMember(_ key: Data) -> Bool { card(key) != nil }
    func isAdmin(_ key: Data) -> Bool { key == owner || admins.contains(key) }

    func canPost(_ key: Data) -> Bool {
        guard isMember(key) else { return false }
        switch postPolicy {
        case .everyone: return kind != .channel || isAdmin(key)
        case .admins: return isAdmin(key) || (kind == .group && mods.contains(key))
        case .owner: return key == owner
        }
    }

    /// Whether every card is genuine, the roles name members, and there's no more than one card per key.
    func wellFormed() -> Bool {
        let keys = members.map(\.signingKey)
        guard groupNumberRange.contains(version), groupNumberRange.contains(epoch), (avatar?.count ?? 0) <= 64 * 1024,
              epochCheck?.count == 32, members.allSatisfy({ $0.avatar == nil }) else { return false }
        return Set(keys).count == keys.count && keys.contains(owner) && members.allSatisfy { $0.verified(group: group) }
            && admins.allSatisfy(keys.contains) && mods.allSatisfy(keys.contains) && members.count <= Self.maxMembers
            && title.count <= 100 && (about?.count ?? 0) <= 500 && title.utf8.count <= 400 && (about?.utf8.count ?? 0) <= 2_000
    }

    static let maxMembers = 5_000

    /// Orders two versions with the same number that compete (two admins changed the group at once): every member
    /// keeps the one with the lower hash, so they all end up on the same one.
    var tieBreak: Data { Data(SHA256.hash(data: signable())) }

    /// Which of two competing versions with the same number every member keeps: one the owner signed beats one anyone
    /// else signed (so an admin can't overturn the owner by trying until their hash comes out lower); otherwise the
    /// lower hash.
    func winsOver(_ other: GroupSettings) -> Bool {
        let mine = signer == owner, theirs = other.signer == other.owner
        if mine != theirs { return mine }
        return tieBreak.lexicographicallyPrecedes(other.tieBreak)
    }

    /// Whether these settings, posted to the mailbox, fit the relay's largest group envelope once sealed and padded.
    var fitsInMailbox: Bool {
        guard let payload = try? Payload.groupSettings(self).wire(framed: false) else { return false }
        return GroupSeal.fits(payload: payload.count)
    }

    /// A version further on than the next, signed by the owner: the owner may change anything (but who owns it), so a
    /// member who missed versions in between can catch up on it.
    func acceptsJump(_ next: GroupSettings) -> Bool {
        groupNumberRange.contains(next.version) && next.group == group && next.kind == kind && next.version > version
            && next.signer == owner && next.owner == owner && next.epoch >= epoch && next.signatureIsValid && next.wellFormed()
    }

    /// Whether `next` may replace this version: signed by its signer, numbered one on, well-formed, for the same group,
    /// and every change in it is one its signer may make.
    func accepts(_ next: GroupSettings) -> Bool {
        guard groupNumberRange.contains(next.version), next.group == group, next.kind == kind, next.version == version + 1, next.signatureIsValid, next.wellFormed(),
              next.epoch == epoch || next.epoch == epoch + 1, isMember(next.signer) else { return false }
        let who = next.signer
        // Judged by the roles in the version it changes, not the one it brings.
        if who == owner { return next.owner == owner }
        let removed = Set(members.map(\.signingKey)).subtracting(next.members.map(\.signingKey))
        let added = Set(next.members.map(\.signingKey)).subtracting(members.map(\.signingKey))
        let rolesSame = next.owner == owner && next.admins == admins && next.mods == mods && next.postPolicy == postPolicy
        if admins.contains(who) {
            // Admins add and remove ordinary members and change the look and the timer; roles stay the owner's, and
            // nobody's card is changed by anyone but its owner.
            let touchesStaff = removed.contains { $0 == owner || admins.contains($0) }
            let cardsKept = next.members.allSatisfy { card in self.card(card.signingKey).map { $0 == card } ?? true }
            return rolesSame && !touchesStaff && cardsKept
        }
        if kind == .group, mods.contains(who) {
            // Mods take ordinary members out, and nothing else.
            var expected = self
            expected.members.removeAll { removed.contains($0.signingKey) }
            expected.version = next.version
            expected.epoch = next.epoch
            expected.epochCheck = next.epochCheck
            expected.signer = next.signer
            expected.signature = next.signature
            return added.isEmpty && !removed.isEmpty && removed.allSatisfy { !isAdmin($0) && !mods.contains($0) } && expected == next
        }
        // A member may only update their own card (a new name or picture).
        var expected = self
        if let i = expected.members.firstIndex(where: { $0.signingKey == who }), let theirs = next.card(who) {
            expected.members[i] = theirs
        }
        expected.version = next.version
        expected.signer = next.signer
        expected.signature = next.signature
        return expected == next
    }
}

/// A new epoch's key, sealed to each remaining member's group key, so whoever was taken out (who can still read the
/// old epoch's mail) can't open it.
struct GroupRekey: Codable, Equatable {
    var group: UUID
    var epoch: Int
    var days: Int
    /// The one-off public key the copies were sealed with.
    var ephemeral: Data
    /// Each member's copy, by the member's signing key (hex).
    var sealed: [String: Data]

    static func make(_ epoch: GroupEpoch, group: UUID, for members: [MemberCard]) -> GroupRekey {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        var sealed: [String: Data] = [:]
        for member in members {
            guard let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: member.agreementKey),
                  let shared = try? eph.sharedSecretFromKeyAgreement(with: theirs) else { continue }
            let key = Self.wrapKey(shared.withUnsafeBytes { Data($0) }, group: group, epoch: epoch.number, member: member.signingKey)
            sealed[member.signingKey.hex] = try? ChaChaPoly.seal(epoch.key, using: key).combined
        }
        return GroupRekey(group: group, epoch: epoch.number, days: epoch.days, ephemeral: eph.publicKey.rawRepresentation, sealed: sealed)
    }

    /// This member's copy, opened.
    func open(with keys: GroupMemberKeys) -> GroupEpoch? {
        guard let box = sealed[keys.publicKey.hex], let eph = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeral),
              let shared = try? keys.agreement.sharedSecretFromKeyAgreement(with: eph) else { return nil }
        let key = Self.wrapKey(shared.withUnsafeBytes { Data($0) }, group: group, epoch: epoch, member: keys.publicKey)
        guard let sealedBox = try? ChaChaPoly.SealedBox(combined: box), let raw = try? ChaChaPoly.open(sealedBox, using: key),
              raw.count == 32 else { return nil }
        return GroupEpoch(number: epoch, key: raw, days: min(max(days, 1), 7), started: Date())
    }

    private static func wrapKey(_ shared: Data, group: UUID, epoch: Int, member: Data) -> SymmetricKey {
        SymmetricKey(data: derive(shared, "pulshade.group.rekey.v1", salt: bytes(group) + be32(UInt32(truncatingIfNeeded: epoch)) + member))
    }
}

/// A group envelope as posted to the mailbox, and opened from it.
enum GroupSeal {
    enum Failure: Error { case malformed, badSignature }

    /// The outside of an envelope, once the epoch's outer key has opened it: who says they sent it, which message of
    /// theirs it is, and the rest still sealed with that message's key.
    struct Outer {
        var sender: Data
        /// Which of the sender's devices (8 bytes): each has its own chain.
        var device: Data
        var index: UInt32
        var inner: Data
        var signature: Data
    }

    static let deviceLength = 8

    /// The largest padded body a group envelope may have: the relay takes up to 2 MiB plus a little for the seal.
    static let maxPadded = 2_097_152

    /// Whether a payload this many bytes long fits one group envelope once sealed, signed and padded.
    static func fits(payload: Int) -> Bool {
        let body = 32 + deviceLength + 4 + 64 + payload + 28
        let padded = EnvelopeCore.paddedSize(of: body)
        return padded > 0 && padded <= maxPadded
    }

    /// The tag a device signs its group messages with: the first bytes of its id, or zeros for an empty id.
    static func deviceTag(_ id: Data) -> Data {
        Data(id.prefix(deviceLength)) + Data(count: max(0, deviceLength - id.count))
    }

    private static func signed(group: UUID, epoch: Int, device: Data, index: UInt32, inner: Data) -> Data {
        Data("pulshade.group.msg.v1".utf8) + bytes(group) + be32(UInt32(truncatingIfNeeded: epoch)) + device + be32(index) + Data(SHA256.hash(data: inner))
    }

    /// Seals `payload` as message `chain.index` of `keys`' chain, and moves the chain on.
    static func seal(_ payload: Data, group: UUID, epoch: GroupEpoch, keys: GroupMemberKeys, device: Data,
                     chain: inout SenderChain) throws -> Data {
        let device = deviceTag(device)
        let (messageKey, next) = chain.step()
        let inner = try ChaChaPoly.seal(payload, using: SymmetricKey(data: messageKey)).combined
        let signature = try keys.signing.signature(for: signed(group: group, epoch: epoch.number, device: device, index: chain.index, inner: inner))
        var body = keys.publicKey + device + be32(chain.index) + signature
        body += inner
        chain = next
        return try ChaChaPoly.seal(EnvelopeCore.padded(body), using: epoch.outerKey).combined
    }

    /// Opens the outer layer and checks the sender's signature. Whether the sender is a member, and opening the inner
    /// layer, is up to the caller, who holds the chains.
    static func outer(_ blob: Data, group: UUID, epoch: GroupEpoch) throws -> Outer {
        guard let box = try? ChaChaPoly.SealedBox(combined: blob), let padded = try? ChaChaPoly.open(box, using: epoch.outerKey),
              let body = EnvelopeCore.unpadded(padded), body.count > 32 + deviceLength + 4 + 64 + 28 else { throw Failure.malformed }
        let sender = Data(body.prefix(32))
        let device = Data(body.dropFirst(32).prefix(deviceLength))
        let index = body.dropFirst(32 + deviceLength).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let signature = Data(body.dropFirst(36 + deviceLength).prefix(64))
        let inner = Data(body.dropFirst(100 + deviceLength))
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: sender),
              key.isValidSignature(signature, for: signed(group: group, epoch: epoch.number, device: device, index: index, inner: inner)) else {
            throw Failure.badSignature
        }
        return Outer(sender: sender, device: device, index: index, inner: inner, signature: signature)
    }

    static func inner(_ outer: Outer, messageKey: Data) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: outer.inner) else { return nil }
        return try? ChaChaPoly.open(box, using: SymmetricKey(data: messageKey))
    }
}

/// What a member keeps to read others in one group: each sender's chain where it has got to, and keys for messages
/// skipped over (arrived out of order), so each one opens once and the key is then forgotten.
struct GroupReader: Codable, Equatable {
    /// "epoch|sender hex|device hex" → the chain's next position.
    var chains: [String: SenderChain] = [:]
    /// "epoch|sender hex|device hex|index" → that message's key.
    var skipped: [String: Data] = [:]

    static let maxSkip: UInt32 = 2_000
    /// Most keys kept for one sender's skipped messages, and in all.
    static let maxSkippedPerSender = 1_000
    static let maxSkipped = 20_000
    /// Most devices (chains) one member may post from in one epoch.
    static let maxDevicesPerSender = 16

    /// The key for `index` of `sender`'s chain in `epoch`, used up (it can't be had twice). Nil for a message already
    /// opened, or one too far ahead.
    mutating func messageKey(epoch: GroupEpoch, sender: Data, device: Data, index: UInt32) -> Data? {
        let id = "\(epoch.number)|\(sender.hex)|\(device.hex)"
        if let key = skipped.removeValue(forKey: "\(id)|\(index)") { return key }
        let senderPrefix = "\(epoch.number)|\(sender.hex)|"
        if chains[id] == nil, chains.keys.count(where: { $0.hasPrefix(senderPrefix) }) >= Self.maxDevicesPerSender { return nil }
        var chain = chains[id] ?? epoch.chainStart(for: sender, device: device)
        guard index >= chain.index, index - chain.index <= Self.maxSkip else { return nil }
        while chain.index < index {
            let (key, next) = chain.step()
            skipped["\(id)|\(chain.index)"] = key
            chain = next
        }
        let (key, next) = chain.step()
        chains[id] = next
        // A sender who skips a lot only pushes out their own oldest gaps, never anyone else's. Only looked at when this
        // message skipped some and there could be too many: an ordinary message costs nothing here.
        guard skipped.count > Self.maxSkippedPerSender, index > 0, skipped["\(id)|\(index - 1)"] != nil else { return key }
        let theirs = skipped.keys.filter { $0.hasPrefix(senderPrefix) }
        let cap = skipped.count > Self.maxSkipped ? 0 : Self.maxSkippedPerSender
        if theirs.count > cap {
            let oldest = theirs.sorted { (UInt32($0.split(separator: "|").last ?? "") ?? 0) < (UInt32($1.split(separator: "|").last ?? "") ?? 0) }
            for k in oldest.prefix(theirs.count - cap) { skipped[k] = nil }
        }
        return key
    }

    /// Forgets everything about one epoch (its key was replaced by the one the group settled on).
    mutating func forget(epoch: Int) {
        chains = chains.filter { !$0.key.hasPrefix("\(epoch)|") }
        skipped = skipped.filter { !$0.key.hasPrefix("\(epoch)|") }
    }

    /// Forgets everything about epochs before `epoch`. Only for epochs no longer read: while one is, what was opened in
    /// it must be remembered, so an old envelope posted again isn't taken a second time.
    mutating func drop(before epoch: Int) {
        let keep = { (k: String) in (Int(k.split(separator: "|").first ?? "") ?? 0) >= epoch }
        chains = chains.filter { keep($0.key) }
        skipped = skipped.filter { keep($0.key) }
    }
}

/// Sent over a 1:1 chat to someone being added: everything they need to read and write in the group from now on.
/// Whoever adds someone starts a new epoch first if anything has been said in the current one, so a newcomer reads
/// from when they joined, not what the group said before.
struct GroupInvite: Codable, Equatable {
    var settings: GroupSettings
    var epoch: GroupEpoch
}

/// A post waiting to go into a group's mailbox, already sealed (its chain has moved on, so it must go as it is).
struct GroupOutgoing: Codable, Equatable {
    var id = UUID()
    var sendID: Data
    var days: Int
    var blob: Data
    /// The message it carries, so its tick can say "sent" once it's on the relay.
    var message: UUID?
    /// Worth waking phones for (a message), or not (a reaction, typing).
    var wake: Bool
    /// Only worth sending soon (typing): dropped rather than retried later.
    var ephemeral: Bool
    var queued = Date()
}

/// What this device keeps about a group that shares one mailbox.
struct SharedGroup: Codable, Equatable {
    var settings: GroupSettings
    /// The epochs this device knows, oldest first. Earlier ones are kept for a while for mail that was late.
    var epochs: [GroupEpoch]
    /// This device's sending chain in each epoch, by epoch number (as text, for the vault's JSON).
    var chains: [String: SenderChain] = [:]
    var reader = GroupReader()
    /// The newest envelope read from each epoch's mailbox.
    var cursors: [String: UInt64] = [:]
    var outbox: [GroupOutgoing] = []
    /// Added but not yet in the settings: this device can read, but not post, until an admin puts its card in.
    var joining = false
    /// Taken out (or the group was ended): nothing more is read or sent.
    var gone = false
    /// As an admin: people invited over a 1:1 chat whose card hasn't come back yet, by account fingerprint.
    var invited: [String: Date] = [:]
    /// As an admin: who joined through this device, by account fingerprint, as which member. Only on this device:
    /// nobody else in the group learns who a member is outside it.
    var knownAs: [String: String] = [:]
    /// The tag this device signs its posts with: random, made the first time it posts, and never copied to another
    /// device (a backup or a newly linked device makes its own), so no two ever use the same chain.
    var myTag: Data?
    /// Someone has said something in the current epoch (as far as this device has read). A newcomer is then given a
    /// new epoch, so they can't read it; several joining in a quiet spell share one.
    var chatInEpoch = false
    /// Epoch keys handed out (a new epoch's) but not yet named by settings this device took. Kept until settings with
    /// the matching check arrive; two admins starting one at once leave two here, and the settings decide.
    var candidates: [GroupEpoch] = []
    /// The version before the one held, to judge a competing version of the same number against.
    var previous: GroupSettings?
    /// As an admin: people this device took out (by group key, in hex), and when; watched for ten minutes, and done
    /// again if another admin's competing change won and they're back in.
    var wantRemoved: [String: Date] = [:]
    /// As an admin: the epoch each invite went out in, by account fingerprint.
    var invitedEpoch: [String: Int] = [:]
    /// A new epoch's key never reached this device (it was away longer than the relay keeps mail): it needs adding
    /// again.
    var missedKey = false
    /// The epoch this device last posted its card (with its picture) in.
    var cardPostedEpoch: Int?
    /// Mailboxes this device has posted to (hex send ids), so only its first post to each carries a proof of work.
    var postedTo: Set<String> = []
    /// Settings that name an epoch whose key hasn't arrived yet, taken once it does.
    var pendingSettings: GroupSettings?

    /// The epoch the settings name (the one everything is posted in).
    var current: GroupEpoch? { epochs.last { $0.number == settings.epoch && $0.check == settings.epochCheck } ?? epochs.last }

    func epoch(_ number: Int) -> GroupEpoch? { epochs.last { $0.number == number } }

    /// Epochs still worth reading: the current one, and each earlier one until a week after the next began (the relay
    /// keeps nothing longer).
    var readable: [GroupEpoch] {
        let cutoff = Date().addingTimeInterval(-8 * 86_400)
        return epochs.indices.filter { i in i == epochs.count - 1 || epochs[i + 1].started > cutoff }.map { epochs[$0] }
    }
}
