import Foundation
import CryptoKit
import os

// Groups that share one mailbox on the relay (see docs/groups-design.md).
//
// A message is sealed once, with the sender's own chain key for the current *epoch*, and posted once into the group's
// mailbox; every member reads it from there. Each sender device starts its chain from random bytes of its own, and every
// post carries where that chain is, sealed under the epoch's *announce key* for the hour it was posted. The announce key
// moves forward every hour and readers keep only the newest they still need, so whoever takes a member's phone gets the
// chains as they stand and the last hour or two, never what was read before. A new epoch is started whenever someone
// leaves or is removed: they don't get the new key, and can't read what follows. Group keys are handed out sealed with
// X25519 and ML-KEM-768 together, so a recording broken later by a quantum computer opens none of them.
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
    private let root: Data

    init(seed: Data, group: UUID) {
        root = derive(seed, "pulshade.group.member.v1", salt: bytes(group))
        signing = try! .init(rawRepresentation: derive(root, "signing"))
        agreement = try! .init(rawRepresentation: derive(root, "agreement"))
    }

    var publicKey: Data { signing.publicKey.rawRepresentation }
    var fingerprint: String { Identity.fingerprint(of: publicKey) }

    /// The post-quantum half of this account's keys in the group (ML-KEM-768, and ML-DSA-65 for the envelope join answers
    /// travel in). Made from the same root when needed, never stored.
    var pq: PQKeys {
        let kemSeed = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root), info: Data("kem".utf8), outputByteCount: 64)
        return try! PQKeys(kemSeed: kemSeed.withUnsafeBytes { Data($0) }, sigSeed: derive(root, "pq.signing"))
    }

    /// Just the ML-KEM private key (cheaper than `pq`, which also makes the signing key).
    var kem: MLKEM768.PrivateKey {
        let kemSeed = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root), info: Data("kem".utf8), outputByteCount: 64)
        return try! MLKEM768.PrivateKey(seedRepresentation: kemSeed.withUnsafeBytes { Data($0) }, publicKey: nil)
    }
}

/// Sealing a small secret to one member's group keys with X25519 and ML-KEM-768 together: a copy opens only for whoever
/// holds both private keys, and breaking X25519 later (a quantum computer) opens nothing recorded.
enum GroupPQ {
    /// The extra bytes a copy has over the secret it carries: the ML-KEM ciphertext, a nonce and a tag.
    static let overhead = EnvelopeCore.kemCiphertextSize + 12 + 16

    /// One member's copy of `secret`, made with the one-off key `ephemeral`; also the X25519 secret, for a tag to file it
    /// under. Nil when the card's keys are no good.
    static func seal(_ secret: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey, to member: MemberCard, context: Data) -> (shared: Data, box: Data)? {
        guard let kemKey = member.kem, let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: member.agreementKey),
              let x = try? ephemeral.sharedSecretFromKeyAgreement(with: theirs),
              let encapsulation = try? MLKEM768.PublicKey(rawRepresentation: kemKey).encapsulate() else { return nil }
        let shared = x.withUnsafeBytes { Data($0) }
        let kemSecret = encapsulation.sharedSecret.withUnsafeBytes { Data($0) }
        let key = wrapKey(shared, kemSecret, ephemeral: ephemeral.publicKey.rawRepresentation, ciphertext: encapsulation.encapsulated,
                          member: member.signingKey, context: context)
        guard let box = try? ChaChaPoly.seal(secret, using: key).combined else { return nil }
        return (shared, encapsulation.encapsulated + box)
    }

    /// The X25519 secret between `ephemeral` and this member, to find their copy's tag before opening it.
    static func shared(ephemeral: Data, keys: GroupMemberKeys) -> Data? {
        guard let eph = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeral),
              let x = try? keys.agreement.sharedSecretFromKeyAgreement(with: eph) else { return nil }
        return x.withUnsafeBytes { Data($0) }
    }

    static func open(_ copy: Data, ephemeral: Data, shared: Data, keys: GroupMemberKeys, kem: MLKEM768.PrivateKey, context: Data) -> Data? {
        let n = EnvelopeCore.kemCiphertextSize
        guard copy.count > overhead else { return nil }
        let ciphertext = Data(copy.prefix(n))
        guard let kemSecret = try? kem.decapsulate(ciphertext).withUnsafeBytes({ Data($0) }),
              let box = try? ChaChaPoly.SealedBox(combined: copy.dropFirst(n)) else { return nil }
        let key = wrapKey(shared, kemSecret, ephemeral: ephemeral, ciphertext: ciphertext, member: keys.publicKey, context: context)
        return try? ChaChaPoly.open(box, using: key)
    }

    private static func wrapKey(_ shared: Data, _ kemSecret: Data, ephemeral: Data, ciphertext: Data, member: Data, context: Data) -> SymmetricKey {
        SymmetricKey(data: derive(shared + kemSecret, "pulshade.group.pq-wrap.v1", salt: context + ephemeral + Data(SHA256.hash(data: ciphertext)) + member))
    }
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
    /// The announce key for hour `hour` (hours since 1970): it seals where each sender's chain is, in every post of that
    /// hour. Random when the epoch is made and handed out with its key, not worked out from it; moved forward one HKDF step
    /// an hour (`announceKey(at:)`) and, once this device has read everything from an hour on, kept only from there
    /// (`advance(to:)`). So the epoch key opens the mailbox and the outer layer, and nothing said in it.
    var announce: Data? = nil
    var hour: Int? = nil

    /// Well-formed as received: a number in range, a whole key and an announce key.
    var isValid: Bool {
        groupNumberRange.contains(number) && key.count == 32 && (1...7).contains(days) && announce?.count == 32
            && (hour.map { $0 > 0 && $0 < Int(Int32.max) } ?? false)
    }

    /// The hour a post made now belongs to.
    static func hourNow(_ date: Date = RelayClock.now) -> Int { Int(max(0, date.timeIntervalSince1970) / 3_600) }

    /// How far ahead of the one held an announce key is worked out (a post that says it is from further on is not read).
    static let maxHoursAhead = 24 * 40

    /// The announce key for hour `h`, worked out forward from the one held. Nil for an hour before it (that key is gone,
    /// on purpose) or too far ahead.
    func announceKey(at h: Int) -> Data? {
        // A channel's staff mailbox (number 0) has no epoch to hand out: its announce keys come from its key, hour by hour.
        if number == 0 { return derive(key, "pulshade.group.staff-announce.v1", salt: be32(UInt32(truncatingIfNeeded: h))) }
        guard var a = announce, let held = hour, h >= held, h - held <= Self.maxHoursAhead else { return nil }
        for _ in held..<h { a = derive(a, "pulshade.group.announce.next.v1") }
        return a
    }

    /// Moves the announce key on to hour `h`, forgetting the ones before.
    mutating func advance(to h: Int) {
        guard number != 0, let held = hour, h > held, let next = announceKey(at: min(h, held + Self.maxHoursAhead)) else { return }
        announce = next
        hour = min(h, held + Self.maxHoursAhead)
    }

    /// How long the relay keeps a group's mail, in days: the most it takes (7), so a member whose phone was off over a
    /// long weekend still gets every post and photo (build 16; it was 3 from build 14). It holds mail even after
    /// everyone has read it (it mustn't learn who has); a member away longer asks the others for what they missed
    /// (`Payload.groupCatchUp`), which carries text but little else.
    static let defaultDays = 7

    static func fresh(number: Int, days: Int = defaultDays) -> GroupEpoch {
        GroupEpoch(number: number, key: .random(32), days: min(max(days, 1), 7), started: Date(), announce: .random(32), hour: hourNow())
    }

    /// The mailbox this epoch's mail goes to. A new epoch means a new mailbox, so the relay can't line the two up by it.
    var receiveKey: Data { derive(key, "pulshade.group.mailbox.v1") }
    /// A check of the key that the signed settings carry, so a key handed over (in an invite, a new epoch, or from
    /// another of your devices) is only used if it is the one the group's settings name.
    var check: Data { derive(key, "pulshade.group.epoch-check.v1") }
    var sendID: Data { Mailbox.sendID(for: receiveKey) }
    fileprivate var outerKey: SymmetricKey { SymmetricKey(data: derive(key, "pulshade.group.outer.v2")) }
}

/// A member's sending chain: each message takes the next key, and the chain moves on, so a key once used can't be
/// worked out again from what's kept. Each sender device starts one from random bytes in each epoch (`fresh`).
struct SenderChain: Codable, Equatable {
    var key: Data
    var index: UInt32

    static func fresh() -> SenderChain { SenderChain(key: .random(32), index: 0) }

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
    /// The member's ML-KEM-768 key in this group (1,184 bytes), which group keys are sealed to next to `agreementKey`.
    /// Every card has one: a card without is not taken.
    var kem: Data?

    var fingerprint: String { Identity.fingerprint(of: signingKey) }

    private static func signable(group: UUID, signingKey: Data, agreementKey: Data, kem: Data?, name: String, avatarHash: Data?, color: Int?) -> Data {
        var d = Data("pulshade.group.card.v3".utf8)
        d += bytes(group) + signingKey + agreementKey + Data(SHA256.hash(data: kem ?? Data()))
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
        signingKey == other.signingKey && agreementKey == other.agreementKey && kem == other.kem && name == other.name
            && avatarHash == other.avatarHash && color == other.color
    }

    static func make(_ keys: GroupMemberKeys, group: UUID, name: String, avatar: Data?, color: Int?) -> MemberCard {
        let name = String(name.prefix(64))
        let avatar = avatar.flatMap { $0.count <= maxAvatar ? $0 : nil }
        let hash = avatar.map { Data(SHA256.hash(data: $0)) }
        let kem = keys.kem.publicKey.rawRepresentation
        let message = signable(group: group, signingKey: keys.publicKey, agreementKey: keys.agreement.publicKey.rawRepresentation,
                               kem: kem, name: name, avatarHash: hash, color: color)
        return MemberCard(signingKey: keys.publicKey, agreementKey: keys.agreement.publicKey.rawRepresentation, name: name,
                          avatar: avatar, avatarHash: hash, color: color, signature: (try? keys.signing.signature(for: message)) ?? Data(),
                          kem: kem)
    }

    func verified(group: UUID) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey), agreementKey.count == 32,
              let kem, kem.count == PQPin.kemSize, name.count <= 64, name.utf8.count <= 256, (avatar?.count ?? 0) <= Self.maxAvatar, avatarHash.map({ $0.count == 32 }) ?? true else { return false }
        // A picture, when it comes, must be the one the signed hash names.
        if let avatar, avatarHash != Data(SHA256.hash(data: avatar)) { return false }
        let signed = Self.signable(group: group, signingKey: signingKey, agreementKey: agreementKey, kem: kem,
                                   name: name, avatarHash: avatarHash, color: color)
        // A big group's settings carry every card, and each new version brings them all again: a card that has already
        // checked out (same bytes, same signature) isn't checked twice. Only passes are remembered, in memory only.
        let digest = Data(SHA256.hash(data: signed + signature))
        if Self.checked.withLock({ $0.contains(digest) }) { return true }
        guard key.isValidSignature(signature, for: signed), (try? MLKEM768.PublicKey(rawRepresentation: kem)) != nil else { return false }
        Self.checked.withLock {
            if $0.count >= 20_000 { $0.removeAll() }
            $0.insert(digest)
        }
        return true
    }

    private static let checked = OSAllocatedUnfairLock(initialState: Set<Data>())
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

    /// Every card carries an ML-KEM key (about 1.6 KB in the settings), so the settings of a group this size still fit one
    /// envelope; `fitsInMailbox` has the last word.
    static let maxMembers = 1_000

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
        // The cheap checks first (numbers, signer's place and role, what changed), the signature and the cards, which
        // cost a signature check each, only for a version that could be accepted at all.
        guard groupNumberRange.contains(next.version), next.group == group, next.kind == kind, next.version == version + 1,
              next.epoch == epoch || next.epoch == epoch + 1, isMember(next.signer), allowsChange(to: next) else { return false }
        return next.signatureIsValid && next.wellFormed()
    }

    /// Whether `next`'s signer is allowed the change from this version to it. Says nothing of the signature.
    private func allowsChange(to next: GroupSettings) -> Bool {
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

/// A new epoch's key and announce key, sealed to each remaining member's group keys (X25519 and ML-KEM-768 together), so
/// whoever was taken out (who can still read the old epoch's mail) can't open it, even with a quantum computer later.
///
/// In a channel the copies are filed under a short tag worked out from each reader's own key instead of the key itself,
/// and padded with copies nobody can open up to a power of two, so followers can't list each other from it and learn
/// only roughly how many there are.
struct GroupRekey: Codable, Equatable {
    var group: UUID
    var epoch: Int
    var days: Int
    /// The hour the announce key in the copies is for.
    var hour: Int
    /// The one-off public key the copies were sealed with.
    var ephemeral: Data
    /// Each member's copy, by the member's signing key (hex), or by their tag (hex) when `tagged`.
    var sealed: [String: Data]
    /// Filed by tag, with padding (channels).
    var tagged: Bool?

    /// Copies a tagged rekey holds at least, and the most it may hold.
    static let minTagged = 8
    static let maxTagged = 1_024
    /// What a copy carries: the epoch key and the announce key.
    static let copySize = 64 + GroupPQ.overhead

    static func make(_ epoch: GroupEpoch, group: UUID, for members: [MemberCard], tagged: Bool = false) -> GroupRekey {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let hour = epoch.hour ?? GroupEpoch.hourNow()
        let secret = epoch.key + (epoch.announce ?? Data(count: 32))
        let context = Self.context(group: group, epoch: epoch.number, hour: hour)
        var sealed: [String: Data] = [:]
        for member in members {
            guard let (shared, box) = GroupPQ.seal(secret, ephemeral: eph, to: member, context: context) else { continue }
            let name = tagged ? Self.tag(shared, group: group, epoch: epoch.number).hex : member.signingKey.hex
            sealed[name] = box
        }
        if tagged {
            var size = minTagged
            while size < sealed.count, size < maxTagged { size *= 2 }
            // Same length as a real copy, so none stands out.
            while sealed.count < size { sealed[Data.random(8).hex] = Data.random(copySize) }
        }
        return GroupRekey(group: group, epoch: epoch.number, days: epoch.days, hour: hour, ephemeral: eph.publicKey.rawRepresentation,
                          sealed: sealed, tagged: tagged ? true : nil)
    }

    /// This member's copy, opened.
    func open(with keys: GroupMemberKeys) -> GroupEpoch? {
        guard hour > 0, hour < Int(Int32.max), let shared = GroupPQ.shared(ephemeral: ephemeral, keys: keys) else { return nil }
        let name = tagged == true ? Self.tag(shared, group: group, epoch: epoch).hex : keys.publicKey.hex
        guard let box = sealed[name], box.count == Self.copySize,
              let raw = GroupPQ.open(box, ephemeral: ephemeral, shared: shared, keys: keys, kem: keys.kem,
                                     context: Self.context(group: group, epoch: epoch, hour: hour)),
              raw.count == 64 else { return nil }
        return GroupEpoch(number: epoch, key: Data(raw.prefix(32)), days: min(max(days, 1), 7), started: Date(),
                          announce: Data(raw.suffix(32)), hour: hour)
    }

    /// Whether the number of copies is one a rekey may have (so a huge one can't be used to fill someone's phone).
    var isReasonable: Bool { tagged == true ? sealed.count <= Self.maxTagged : sealed.count <= GroupSettings.maxMembers }

    private static func context(group: UUID, epoch: Int, hour: Int) -> Data {
        Data("pulshade.group.rekey.v2".utf8) + bytes(group) + be32(UInt32(truncatingIfNeeded: epoch)) + be32(UInt32(truncatingIfNeeded: hour))
    }

    /// The eight bytes a reader's copy is filed under: only the reader (and whoever sealed it) can work them out.
    private static func tag(_ shared: Data, group: UUID, epoch: Int) -> Data {
        Data(derive(shared, "pulshade.group.rekey.tag.v1", salt: bytes(group) + be32(UInt32(truncatingIfNeeded: epoch))).prefix(8))
    }
}

/// The people following a channel, kept by its staff and hidden from everyone else: the staff need them to hand each a new
/// epoch's key when someone is taken out. One document, posted in the channel's mailbox, that only a staff member can open:
/// the list is sealed under a random key, and that key is sealed to each staff member's group key. A copy is padded to a
/// power of two, so the size tells followers little more than "roughly this many".
///
/// Admins merge what they get: an entry stays unless a later removal names it (`removed`), so two admins adding at once
/// both end up in.
struct GroupRoster: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var card: MemberCard
        var added: Date
    }
    struct Gone: Codable, Equatable {
        var key: Data
        var at: Date
    }
    struct Body: Codable, Equatable {
        var entries: [Entry]
        var removed: [Gone]

        /// Each follower's card carries an ML-KEM key, so a roster this long still fits one envelope once padded.
        static let maxEntries = 500
        static let maxRemoved = 500

        /// The people in it now: added, and not taken out since.
        var live: [MemberCard] {
            entries.filter { entry in !removed.contains { $0.key == entry.card.signingKey && $0.at >= entry.added } }.map(\.card)
        }

        /// This and `other`, together: the newest entry for each person, and every removal; removals older than the entry
        /// they name are let go, and so are the oldest when there are too many.
        func merged(with other: Body, group: UUID) -> Body {
            // Nothing is dated further on than a few minutes from now, so no one can make an entry or a removal that nothing
            // later could ever beat.
            let latest = Date().addingTimeInterval(300)
            var byKey: [Data: Entry] = [:]
            for var entry in entries + other.entries where entry.card.verified(group: group) {
                entry.added = min(entry.added, latest)
                if let held = byKey[entry.card.signingKey], held.added >= entry.added { continue }
                byKey[entry.card.signingKey] = entry
            }
            var gone: [Data: Gone] = [:]
            for var g in removed + other.removed {
                g.at = min(g.at, latest)
                if let held = gone[g.key], held.at >= g.at { continue }
                gone[g.key] = g
            }
            // Someone taken out stays out (their removal is kept against older copies) but isn't kept as an entry, so the
            // cap counts only people who are in; the oldest stay if there are too many.
            let live = byKey.values.filter { entry in !(gone[entry.card.signingKey].map { $0.at >= entry.added } ?? false) }
            let keptGone = gone.values.sorted { ($0.at, $0.key.hex) > ($1.at, $1.key.hex) }
            let ordered = live.sorted { ($0.added, $0.card.signingKey.hex) < ($1.added, $1.card.signingKey.hex) }
            return Body(entries: Array(ordered.prefix(Self.maxEntries)), removed: Array(keptGone.prefix(Self.maxRemoved)))
        }
    }

    var group: UUID
    var epoch: Int
    /// The one-off public key the roster key was sealed with.
    var ephemeral: Data
    /// The roster key, sealed to each staff member under their tag, padded.
    var keys: [String: Data]
    /// The body, sealed under the roster key.
    var box: Data
    var signer: Data
    var signature: Data

    private func signable() -> Data {
        var d = Data("pulshade.group.roster.v1".utf8) + bytes(group) + be32(UInt32(truncatingIfNeeded: epoch)) + ephemeral
        for name in keys.keys.sorted() { d += Data(name.utf8) + Data(SHA256.hash(data: keys[name] ?? Data())) }
        return d + Data(SHA256.hash(data: box))
    }

    var signatureIsValid: Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signer) else { return false }
        return key.isValidSignature(signature, for: signable())
    }

    /// The biggest sealed body a roster may have, in bytes (about 5,000 entries).
    static let maxBox = 2_000_000

    var isReasonable: Bool { keys.count <= 4_096 && box.count <= Self.maxBox }

    /// A roster for `staff` to read, signed by `keys`.
    static func make(_ body: Body, group: UUID, epoch: Int, staff: [MemberCard], keys: GroupMemberKeys) -> GroupRoster? {
        guard let plain = try? JSONEncoder.pulshade.encode(body) else { return nil }
        let rosterKey = SymmetricKey(size: .bits256)
        let eph = Curve25519.KeyAgreement.PrivateKey()
        var sealedKeys: [String: Data] = [:]
        let secretBytes = rosterKey.withUnsafeBytes { Data($0) }
        for member in staff {
            guard let (shared, box) = GroupPQ.seal(secretBytes, ephemeral: eph, to: member, context: Self.context(group)) else { continue }
            sealedKeys[Self.tag(shared, group: group).hex] = box
        }
        var size = 4
        while size < sealedKeys.count { size *= 2 }
        while sealedKeys.count < size { sealedKeys[Data.random(8).hex] = Data.random(32 + GroupPQ.overhead) }
        // The body is padded to a power of two (at least 1 KiB) before sealing.
        var padded = plain
        var target = 1_024
        while target < padded.count + 4 { target *= 2 }
        padded = be32(UInt32(plain.count)) + plain + Data(count: target - plain.count - 4)
        guard let box = try? ChaChaPoly.seal(padded, using: rosterKey).combined else { return nil }
        var roster = GroupRoster(group: group, epoch: epoch, ephemeral: eph.publicKey.rawRepresentation, keys: sealedKeys, box: box,
                                 signer: keys.publicKey, signature: Data())
        roster.signature = (try? keys.signing.signature(for: roster.signable())) ?? Data()
        return roster
    }

    /// The list, if this staff member has a copy of the key.
    func open(with keys: GroupMemberKeys) -> Body? {
        guard isReasonable, let secret = GroupPQ.shared(ephemeral: ephemeral, keys: keys),
              let copy = self.keys[Self.tag(secret, group: group).hex],
              let rosterKey = GroupPQ.open(copy, ephemeral: ephemeral, shared: secret, keys: keys, kem: keys.kem, context: Self.context(group)),
              rosterKey.count == 32, let sealedBox = try? ChaChaPoly.SealedBox(combined: box),
              let padded = try? ChaChaPoly.open(sealedBox, using: SymmetricKey(data: rosterKey)), padded.count >= 4 else { return nil }
        let n = padded.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard n <= padded.count - 4, let body = try? JSONDecoder.pulshade.decode(Body.self, from: padded.dropFirst(4).prefix(n)),
              body.entries.count <= Body.maxEntries, body.removed.count <= Body.maxRemoved else { return nil }
        return body
    }

    private static func context(_ group: UUID) -> Data { Data("pulshade.group.roster.wrap.v2".utf8) + bytes(group) }

    private static func tag(_ shared: Data, group: UUID) -> Data {
        Data(derive(shared, "pulshade.group.roster.tag.v1", salt: bytes(group)).prefix(8))
    }
}

/// A group envelope as posted to the mailbox, and opened from it.
///
/// Inside the epoch's outer layer: the sender's member key, device tag, message number and signature, then the hour and
/// the *announcement* (where the sender's chain is at this message, sealed under that hour's announce key), then the
/// message sealed with its own key. A reader who already follows this sender's chain ignores the announcement; one who
/// doesn't starts the chain from it. The announcement isn't signed: a wrong one gives a key that doesn't open the
/// message, and nothing is kept from it.
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
        /// The hour the announcement is sealed for, and the announcement.
        var hour: Int
        var announcement: Data
    }

    static let deviceLength = 8
    /// A sealed chain key: nonce, 32 bytes, tag.
    static let announcementLength = 12 + 32 + 16
    private static let head = 32 + deviceLength + 4 + 64 + 4 + announcementLength

    /// The largest padded body a group envelope may have: the relay takes up to 2 MiB plus a little for the seal.
    static let maxPadded = 2_097_152

    /// Whether a payload this many bytes long fits one group envelope once sealed, signed and padded.
    static func fits(payload: Int) -> Bool {
        let body = head + payload + 28
        let padded = EnvelopeCore.paddedSize(of: body)
        return padded > 0 && padded <= maxPadded
    }

    /// The tag a device signs its group messages with: the first bytes of its id, or zeros for an empty id.
    static func deviceTag(_ id: Data) -> Data {
        Data(id.prefix(deviceLength)) + Data(count: max(0, deviceLength - id.count))
    }

    private static func signed(group: UUID, epoch: Int, device: Data, index: UInt32, inner: Data) -> Data {
        Data("pulshade.group.msg.v2".utf8) + bytes(group) + be32(UInt32(truncatingIfNeeded: epoch)) + device + be32(index) + Data(SHA256.hash(data: inner))
    }

    private static func announceSeal(_ announceKey: Data, sender: Data, device: Data, index: UInt32) -> SymmetricKey {
        SymmetricKey(data: derive(announceKey, "pulshade.group.announcement.v1", salt: sender + device + be32(index)))
    }

    /// The announcement for message `index` of a chain whose key there is `chainKey`, for hour `hour`.
    private static func announcement(_ chainKey: Data, epoch: GroupEpoch, hour: Int, sender: Data, device: Data, index: UInt32) -> Data? {
        guard let a = epoch.announceKey(at: hour) else { return nil }
        return try? ChaChaPoly.seal(chainKey, using: announceSeal(a, sender: sender, device: device, index: index)).combined
    }

    /// Seals `payload` as message `chain.index` of `keys`' chain, and moves the chain on. Also gives back the chain key it
    /// was sealed at, so the announcement can be made again for a later hour if the post waits (`reannounce`).
    static func seal(_ payload: Data, group: UUID, epoch: GroupEpoch, keys: GroupMemberKeys, device: Data,
                     chain: inout SenderChain) throws -> (blob: Data, chainKey: Data) {
        let device = deviceTag(device)
        let used = chain
        let (messageKey, next) = chain.step()
        let inner = try ChaChaPoly.seal(payload, using: SymmetricKey(data: messageKey)).combined
        let signature = try keys.signing.signature(for: signed(group: group, epoch: epoch.number, device: device, index: chain.index, inner: inner))
        let hour = GroupEpoch.hourNow()
        guard let note = announcement(used.key, epoch: epoch, hour: hour, sender: keys.publicKey, device: device, index: used.index)
        else { throw Failure.malformed }
        var body = keys.publicKey + device + be32(chain.index) + signature + be32(UInt32(truncatingIfNeeded: hour)) + note
        body += inner
        chain = next
        return (try ChaChaPoly.seal(EnvelopeCore.padded(body), using: epoch.outerKey).combined, used.key)
    }

    /// The same post with its announcement made again for the hour it is now (it waited to be sent), so readers who have
    /// already let go of the hour it was sealed in can still start the sender's chain from it.
    static func reannounce(_ blob: Data, group: UUID, epoch: GroupEpoch, chainKey: Data) -> Data? {
        guard let outer = try? outer(blob, group: group, epoch: epoch) else { return nil }
        let hour = GroupEpoch.hourNow()
        guard outer.hour != hour else { return blob }
        guard let note = announcement(chainKey, epoch: epoch, hour: hour, sender: outer.sender, device: outer.device, index: outer.index)
        else { return nil }
        var body = outer.sender + outer.device + be32(outer.index) + outer.signature + be32(UInt32(truncatingIfNeeded: hour)) + note
        body += outer.inner
        return try? ChaChaPoly.seal(EnvelopeCore.padded(body), using: epoch.outerKey).combined
    }

    /// Opens the outer layer and checks the sender's signature. Whether the sender is a member, and opening the inner
    /// layer, is up to the caller, who holds the chains.
    static func outer(_ blob: Data, group: UUID, epoch: GroupEpoch) throws -> Outer {
        guard let box = try? ChaChaPoly.SealedBox(combined: blob), let padded = try? ChaChaPoly.open(box, using: epoch.outerKey),
              let body = EnvelopeCore.unpadded(padded), body.count > head + 28 else { throw Failure.malformed }
        let b = Data(body)
        let sender = Data(b.prefix(32))
        let device = Data(b.dropFirst(32).prefix(deviceLength))
        let index = b.dropFirst(32 + deviceLength).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let signature = Data(b.dropFirst(36 + deviceLength).prefix(64))
        let hour = b.dropFirst(100 + deviceLength).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let note = Data(b.dropFirst(104 + deviceLength).prefix(announcementLength))
        let inner = Data(b.dropFirst(head))
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: sender),
              key.isValidSignature(signature, for: signed(group: group, epoch: epoch.number, device: device, index: index, inner: inner)) else {
            throw Failure.badSignature
        }
        return Outer(sender: sender, device: device, index: index, inner: inner, signature: signature, hour: Int(hour), announcement: note)
    }

    /// The chain key the announcement says, if this device still holds the announce key for its hour.
    static func announced(_ outer: Outer, epoch: GroupEpoch) -> Data? {
        guard let a = epoch.announceKey(at: outer.hour), let box = try? ChaChaPoly.SealedBox(combined: outer.announcement),
              let key = try? ChaChaPoly.open(box, using: announceSeal(a, sender: outer.sender, device: outer.device, index: outer.index)),
              key.count == 32 else { return nil }
        return key
    }

    static func inner(_ outer: Outer, messageKey: Data) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: outer.inner) else { return nil }
        return try? ChaChaPoly.open(box, using: SymmetricKey(data: messageKey))
    }
}

/// What a member keeps to read others in one group: each sender's chain where it has got to, and keys for messages
/// skipped over (arrived out of order), so each one opens once and the key is then forgotten. A chain is only ever
/// started from a post's announcement (never worked out from the epoch key), and only once that post has opened with it.
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
    /// Most posting devices followed in one epoch, all members together: past it, posts from further devices are not
    /// read (a group this big has a few hundred people who talk, at most).
    static let maxChainsPerEpoch = 2_000

    /// Whether this sender device's chain is followed already.
    func follows(epoch: Int, sender: Data, device: Data) -> Bool { chains["\(epoch)|\(sender.hex)|\(device.hex)"] != nil }

    /// The key for `index` of `sender`'s chain in `epoch`, used up (it can't be had twice). Nil for a message already
    /// opened, or one too far ahead. A chain not followed yet (or so far behind that catching up would cost too much)
    /// starts from `announced`, the chain key the post's announcement gives, but only if `opens` says the key it gives
    /// opens the post.
    mutating func messageKey(epoch: Int, sender: Data, device: Data, index: UInt32, announced: Data?, opens: (Data) -> Bool) -> Data? {
        let id = "\(epoch)|\(sender.hex)|\(device.hex)"
        if let key = skipped.removeValue(forKey: "\(id)|\(index)") { return key }
        let senderPrefix = "\(epoch)|\(sender.hex)|"
        if var chain = chains[id] {
            guard index >= chain.index else { return nil }
            if index - chain.index <= Self.maxSkip {
                while chain.index < index {
                    let (key, next) = chain.step()
                    skipped["\(id)|\(chain.index)"] = key
                    chain = next
                }
                let (key, next) = chain.step()
                chains[id] = next
                trim(id: id, senderPrefix: senderPrefix, index: index)
                return key
            }
        } else {
            if chains.keys.count(where: { $0.hasPrefix(senderPrefix) }) >= Self.maxDevicesPerSender { return nil }
            if chains.keys.count(where: { $0.hasPrefix("\(epoch)|") }) >= Self.maxChainsPerEpoch { return nil }
        }
        guard let announced, announced.count == 32 else { return nil }
        let (key, next) = SenderChain(key: announced, index: index).step()
        guard opens(key) else { return nil }
        chains[id] = next
        return key
    }

    /// A sender who skips a lot only pushes out their own oldest gaps, never anyone else's. Only looked at when this
    /// message skipped some and there could be too many: an ordinary message costs nothing here.
    private mutating func trim(id: String, senderPrefix: String, index: UInt32) {
        guard skipped.count > Self.maxSkippedPerSender, index > 0, skipped["\(id)|\(index - 1)"] != nil else { return }
        let theirs = skipped.keys.filter { $0.hasPrefix(senderPrefix) }
        let cap = skipped.count > Self.maxSkipped ? 0 : Self.maxSkippedPerSender
        if theirs.count > cap {
            let oldest = theirs.sorted { (UInt32($0.split(separator: "|").last ?? "") ?? 0) < (UInt32($1.split(separator: "|").last ?? "") ?? 0) }
            for k in oldest.prefix(theirs.count - cap) { skipped[k] = nil }
        }
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
    /// In a channel: the owner wants this follower as staff, so they answer with a card with their name instead of the
    /// nameless one a follower gives. Apps from before ignore it.
    var staff: Bool?
    /// With `staff`: the key of the staff-only mailbox the follower roster is kept in (see `SharedGroup.staffEpoch`).
    var staffKey: Data?
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
    /// The epoch it is posted in.
    var epoch: Int?
    /// This is the same sealed post sent again, because it never came back from the mailbox (`KeptPost.id`).
    var keeps: UUID?
    /// The message it carries, so the kept copy goes when the message does.
    var about: UUID?
    /// Said by people (not housekeeping): worth sending again to a member who was away.
    var catchUp: Bool?
    /// Sent again for a member who was away: nothing to record, the original is already kept.
    var replay: Bool?
    /// The chain key the post was sealed at, until it has gone: if it waits past the hour, its announcement is made again
    /// for the hour it goes in (`GroupSeal.reannounce`). Opens only this post (the chain has moved on).
    var chainKey: Data?
}

/// A post this device made, kept (sealed, as posted) until it has read it back from the mailbox, which shows the relay
/// holds it for every member. If it doesn't come back (the relay lost mail) the same bytes are posted again. Posts people
/// made are also kept for a while longer, so a member who was away longer than the relay keeps mail can ask for them again.
/// Lives only in the device's own encrypted data, and goes with the message it carries.
struct KeptPost: Codable, Equatable {
    var id = UUID()
    var epoch: Int
    var index: UInt32
    var sendID: Data
    var days: Int
    var blob: Data
    var about: UUID?
    var at = Date()
    var lastTry = Date()
    /// How many times it has been posted again.
    var tries = 0
    var seen = false
    /// Said by people, so also kept for catching up.
    var chat: Bool

    static let maxCount = 200
    static let maxBytes = 2 * 1024 * 1024
    /// Bigger than this is not kept (a group's settings; they catch up another way).
    static let maxBlob = 256 * 1024
    /// How long posts people made are kept for catching up, and housekeeping ones for waiting to be read back.
    static let keepFor: TimeInterval = 14 * 86_400
    static let housekeepingFor: TimeInterval = 86_400
    static let maxTries = 6
    /// How long to wait for a post to come back before posting it again, after it has been posted again `tries` times.
    static func gap(_ tries: Int) -> TimeInterval { [120, 600, 3_600, 21_600, 21_600, 43_200][min(max(tries, 0), 5)] }
}

/// A group post kept to read again later: which epoch's mailbox it came from, and the envelope.
struct HeldGroupMail: Codable, Equatable {
    var epoch: Int
    var seq: UInt64
    var blob: Data
    var at: Date

    static let max = 100
    /// All that is kept for one group, in bytes.
    static let maxBytes = 4 * 1024 * 1024
}

/// What this device keeps about a group that shares one mailbox.
struct SharedGroup: Codable, Equatable {
    var settings: GroupSettings
    /// The epochs this device knows, oldest first. Earlier ones are kept until a week after the next began, for mail
    /// that was late, then erased (`AppModel.tendSharedGroups`).
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
    /// In a channel, as staff: the people following it, as this device last knew them (merged from what the other staff
    /// post). Never on a follower's device, and never in the channel's settings.
    var roster: GroupRoster.Body?
    /// The epoch this device last posted the roster in, so each new epoch's mailbox has one for staff who join late.
    var rosterEpoch: Int?
    /// In a channel, the key of its staff-only mailbox: the owner makes it, and gives it to each admin over the chat they
    /// were asked in. Followers never have it, so the roster is posted where they can't read, and not in the channel's own
    /// mailbox where they would see every join and leave happen.
    var staffKey: Data?
    /// The account the channel's first invite came from: the only one whose later invites may give or change `staffKey`.
    var ownerAccount: String?
    /// After a follower was taken out: the epoch then, until a newer one exists without them (tried again until it does).
    var rekeyAfter: Int?
    var rekeyTried: Date?
    /// After followers left: the time the one new epoch for all of them is made (leaves close together share it).
    var rekeyDue: Date?
    /// As staff of a channel: people who followed through its code and are waiting to be let in (an hourly limit was
    /// reached), by account fingerprint.
    var joinWaiting: [String]?
    /// As the owner of a channel: followers asked to become staff, by account fingerprint, until they answer.
    var staffInvited: [String: Date]?
    /// The staff the roster was last sealed to, so a new admin gets a copy.
    var rosterStaff: [Data]?
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
    /// How many chat posts this device has seen in the current epoch (its own and others'), for a new epoch by count.
    var chatsInEpoch: Int?
    /// When an admin device last tried to start a new epoch because the current one had grown old or long.
    var rotationTried: Date?
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
    /// The group's join links and bans, as the newest admin-signed version says.
    var links: GroupLinks?
    /// As an admin: requests through links that need approval, as last read from their mailboxes.
    var held: [HeldJoin]?
    /// As the admin who made a link: when its preview was last written, by link id.
    var previews: [String: PreviewMark]?
    /// The epoch the links were last posted in by this device.
    var linksEpoch: Int?
    /// As an admin: each link's keys, by link id, opened from the copy sealed to this account. Only on admins' devices.
    var linkSecrets: [String: LinkSecrets]?
    /// As the owner: the admins the links' keys were last sealed to (so a new admin gets a copy), and everyone any version
    /// since the last reset was sealed to (so the links get new keys once one of them isn't an admin any more).
    var linksSealedTo: [Data]?
    var linksExposed: [Data]?
    /// As an admin: requests already dealt with (hash of the envelope), so the relay can't replay one to add someone again.
    var handledJoins: [Data]?
    /// When this device last asked for a key it missed (`Payload.groupKeyWanted`).
    var keyAskedAt: Date?
    /// When this device last asked the admin who invited it for the current key over their 1:1 chat.
    var inviterAskedAt: Date?
    /// Posts from someone the settings held here don't list yet (the settings that add them are still on the way):
    /// read again once they arrive, instead of being lost.
    var heldMail: [HeldGroupMail]?
    /// This device's own recent posts, kept until read back (see `KeptPost`).
    var kept: [KeptPost]?
    /// The last time this device read the group's mailbox to the end.
    var lastFetch: Date?
    /// Set when this device was away longer than the relay keeps mail: the time it last read, to ask members for what it missed.
    var catchUpSince: Date?
    var catchUpAsked: Date?

    /// The epoch the settings name (the one everything is posted in).
    var current: GroupEpoch? { epochs.last { $0.number == settings.epoch && $0.check == settings.epochCheck } ?? epochs.last }

    func epoch(_ number: Int) -> GroupEpoch? { number == 0 ? staffEpoch : epochs.last { $0.number == number } }

    /// The staff-only mailbox as an epoch of its own (number 0, which no real epoch has): nothing in a channel's mailbox
    /// can be told from the key alone, so it is a mailbox no follower can find. Never in `epochs` or `readable`.
    var staffEpoch: GroupEpoch? {
        guard settings.kind == .channel, let key = staffKey, key.count == 32 else { return nil }
        return GroupEpoch(number: 0, key: key, days: 7, started: .distantPast)
    }

    /// Epochs still worth reading: the current one, and each earlier one until a week after the next began (the relay
    /// keeps nothing longer).
    var readable: [GroupEpoch] {
        let cutoff = Date().addingTimeInterval(-8 * 86_400)
        return epochs.indices.filter { i in i == epochs.count - 1 || epochs[i + 1].started > cutoff }.map { epochs[$0] }
    }
}
