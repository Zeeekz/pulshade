import Foundation
import CryptoKit
import os

// Groups that share one mailbox on the relay (see docs/groups-design.md).
//
// A message is sealed once, with the sender's own chain key for the current *epoch*, and posted once into the group's
// mailbox; every member reads it from there. Each sender device starts its chain from random bytes of its own, and hands
// where it starts to each other member device over a pairwise session (`GroupPeer`: the same post-quantum Double Ratchet
// 1:1 chats use, set up between the two members' group keys and carried in the group's mailbox). Readers keep only each
// chain's next position and forget every key once used, so whoever takes a member's phone opens nothing it already read.
// A new epoch is started whenever someone
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

/// This account's keys in one group: made from the account's seed, the group's id and the account's group secret
/// (`AppData.groupSecret`), so every device of the account (and a recovered one) has the same, and they are tied to
/// nothing outside the group. The group secret is random, held only by the account's linked devices, and replaced when
/// one is unlinked, so a device that was taken out can't work out the keys the account moves to. An empty secret is
/// the seed alone, as accounts had before they first made one.
struct GroupMemberKeys {
    let signing: Curve25519.Signing.PrivateKey
    let agreement: Curve25519.KeyAgreement.PrivateKey
    private let root: Data

    init(seed: Data, group: UUID, secret: Data? = nil) {
        if let secret, !secret.isEmpty {
            root = derive(seed, "pulshade.group.member.v2", salt: bytes(group) + secret)
        } else {
            root = derive(seed, "pulshade.group.member.v1", salt: bytes(group))
        }
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

    /// Well-formed as received: a number in range and a whole key.
    var isValid: Bool { groupNumberRange.contains(number) && key.count == 32 && (1...7).contains(days) }

    /// How long the relay keeps a group's mail, in days: the most it takes (7), so a member whose phone was off over a
    /// long weekend still gets every post and photo (build 16; it was 3 from build 14). It holds mail even after
    /// everyone has read it (it mustn't learn who has); a member away longer asks the others for what they missed
    /// (`Payload.groupCatchUp`), which carries text but little else.
    static let defaultDays = 7

    static func fresh(number: Int, days: Int = defaultDays) -> GroupEpoch {
        GroupEpoch(number: number, key: .random(32), days: min(max(days, 1), 7), started: Date())
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
        // Never trap on an exhausted counter. 2^32 messages on one chain is unreachable in practice.
        (hmac(key, 1), SenderChain(key: hmac(key, 2), index: index == .max ? index : index + 1))
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

    /// Orders two versions with the same number and the same signer (two of one account's devices changed the group at
    /// once): the lower hash. Only ever between versions one key signed, so nobody gains by trying again for a lower one.
    var tieBreak: Data { Data(SHA256.hash(data: signable())) }

    /// Where a member stands in these settings when two versions made from them compete: the owner first, then the admins
    /// in the order the owner listed them, then the mods, then everyone else in the order of their cards. Signing again
    /// changes nothing here, so nobody can try until they win.
    func seniority(of key: Data) -> Int {
        if key == owner { return 0 }
        if let i = admins.firstIndex(of: key) { return 1 + i }
        if let i = mods.firstIndex(of: key) { return 1 + admins.count + i }
        if let i = members.firstIndex(where: { $0.signingKey == key }) { return 1 + admins.count + mods.count + i }
        return Int.max
    }

    /// How two competing versions with the same number, both made from `base`, are settled.
    enum Contest: Equatable {
        case wins, loses
        /// Both move the same member to new keys, but to different ones: two devices hold that member's old keys and
        /// each claims the place (one is likely a device their account unlinked). Neither is taken.
        case dispute(old: Data, keys: [Data])
    }

    /// Which of this version and `other` (same number, both made from `base`) every member keeps. The signer who stands
    /// higher in `base` wins (`seniority`). Between two versions one key signed: a move to new keys beats any other
    /// change (so a device that still holds the old keys can't hold the account back on them), two moves to the same new
    /// key are the same account's devices and the lower hash wins, and two moves to different new keys are a dispute.
    func contest(_ other: GroupSettings, base: GroupSettings) -> Contest {
        guard signer == other.signer else {
            return base.seniority(of: signer) < base.seniority(of: other.signer) ? .wins : .loses
        }
        switch (base.renewal(to: self), base.renewal(to: other)) {
        case let (mine?, theirs?) where mine.new != theirs.new:
            return .dispute(old: mine.old, keys: [mine.old, mine.new, theirs.new])
        case (.some, nil): return .wins
        case (nil, .some): return .loses
        default: return tieBreak.lexicographicallyPrecedes(other.tieBreak) ? .wins : .loses
        }
    }

    /// The key this version gives `old`'s place to, when that isn't `taken`, judged without the version it was made from:
    /// signed by `old`, numbered `version`, with neither `old` nor `taken` in it, and genuine. Used against a move of
    /// `old`'s place to `taken` already seen (`SharedGroup.renewals`): the other key it names, or an empty key when it
    /// names none this device can tell apart. Nil when it isn't such a version (the same move again included).
    func movesPlace(of old: Data, at version: Int, otherThan taken: Data, from held: GroupSettings) -> Data? {
        guard signer == old, self.version == version, group == held.group, !isMember(old), !isMember(taken),
              signatureIsValid, wellFormed() else { return nil }
        let added = members.map(\.signingKey).filter { !held.isMember($0) }
        return added.count == 1 ? added[0] : Data()
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

    /// A member moving to new group keys (their account unlinked a device): `next` puts a card under a new key in place
    /// of the signer's own, hands the signer's roles to it, and starts a new epoch, so whoever holds only the old keys
    /// gets nothing from then on. Nothing else may change. The old and the new key, or nil if `next` isn't that.
    func renewal(to next: GroupSettings) -> (old: Data, new: Data)? {
        let who = next.signer
        guard isMember(who), !next.isMember(who), next.epoch == epoch + 1 else { return nil }
        let added = next.members.filter { !isMember($0.signingKey) }
        guard added.count == 1, let card = added.first else { return nil }
        let new = card.signingKey
        func swap(_ key: Data) -> Data { key == who ? new : key }
        var expected = self
        expected.members = members.map { $0.signingKey == who ? card : $0 }
        expected.owner = swap(owner)
        expected.admins = admins.map(swap)
        expected.mods = mods.map(swap)
        expected.version = next.version
        expected.epoch = next.epoch
        expected.epochCheck = next.epochCheck
        expected.signer = next.signer
        expected.signature = next.signature
        return expected == next ? (who, new) : nil
    }

    /// Whether `next`'s signer is allowed the change from this version to it. Says nothing of the signature.
    private func allowsChange(to next: GroupSettings) -> Bool {
        let who = next.signer
        // Any member may move to new keys of their own, roles and all.
        if renewal(to: next) != nil { return true }
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

/// A new epoch's key, sealed to each remaining member's group keys (X25519 and ML-KEM-768 together), so
/// whoever was taken out (who can still read the old epoch's mail) can't open it, even with a quantum computer later.
///
/// In a channel the copies are filed under a short tag worked out from each reader's own key instead of the key itself,
/// and padded with copies nobody can open up to a power of two, so followers can't list each other from it and learn
/// only roughly how many there are.
struct GroupRekey: Codable, Equatable {
    var group: UUID
    var epoch: Int
    var days: Int
    /// The one-off public key the copies were sealed with.
    var ephemeral: Data
    /// Each member's copy, by the member's signing key (hex), or by their tag (hex) when `tagged`.
    var sealed: [String: Data]
    /// Filed by tag, with padding (channels).
    var tagged: Bool?

    /// Copies a tagged rekey holds at least, and the most it may hold.
    static let minTagged = 8
    static let maxTagged = 1_024
    /// What a copy carries: the epoch key.
    static let copySize = 32 + GroupPQ.overhead

    static func make(_ epoch: GroupEpoch, group: UUID, for members: [MemberCard], tagged: Bool = false) -> GroupRekey {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let secret = epoch.key
        let context = Self.context(group: group, epoch: epoch.number)
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
        return GroupRekey(group: group, epoch: epoch.number, days: epoch.days, ephemeral: eph.publicKey.rawRepresentation,
                          sealed: sealed, tagged: tagged ? true : nil)
    }

    /// This member's copy, opened.
    func open(with keys: GroupMemberKeys) -> GroupEpoch? {
        guard let shared = GroupPQ.shared(ephemeral: ephemeral, keys: keys) else { return nil }
        let name = tagged == true ? Self.tag(shared, group: group, epoch: epoch).hex : keys.publicKey.hex
        guard let box = sealed[name], box.count == Self.copySize,
              let raw = GroupPQ.open(box, ephemeral: ephemeral, shared: shared, keys: keys, kem: keys.kem,
                                     context: Self.context(group: group, epoch: epoch)),
              raw.count == 32 else { return nil }
        return GroupEpoch(number: epoch, key: raw, days: min(max(days, 1), 7), started: Date())
    }

    /// Whether the number of copies is one a rekey may have (so a huge one can't be used to fill someone's phone).
    var isReasonable: Bool { tagged == true ? sealed.count <= Self.maxTagged : sealed.count <= GroupSettings.maxMembers }

    private static func context(group: UUID, epoch: Int) -> Data {
        Data("pulshade.group.rekey.v3".utf8) + bytes(group) + be32(UInt32(truncatingIfNeeded: epoch))
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
        // The body is padded to a power of two before sealing. The floor is large enough that every roster a small
        // group makes (a few member cards, each carrying an ML-KEM key) lands in the same bucket: otherwise the
        // relay could tell a one-member follower list from a three-member one by its size.
        var padded = plain
        var target = 8_192
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
/// Inside the epoch's outer layer: the sender's member key, device tag, message number and signature, then the message
/// sealed with that number's key from the sender device's chain. A reader learns where a chain starts only over its
/// pairwise session with the sender device (`GroupPeer`), never from the post.
///
/// A *direct* post (number `directIndex`) carries no chain message: its body is a `Payload.groupDirect`, items each meant
/// for one member device and sealed by the session with it, so anyone holding the epoch key can open the outer layer and
/// find their own items, before they follow the sender's chain.
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

        /// A direct post: its inner part is not sealed with a chain key (see `GroupSeal`).
        var isDirect: Bool { index == GroupSeal.directIndex }
    }

    static let deviceLength = 8
    /// The message number direct posts carry; no chain gets that far.
    static let directIndex = UInt32.max
    private static let head = 32 + deviceLength + 4 + 64

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
        Data("pulshade.group.msg.v3".utf8) + bytes(group) + be32(UInt32(truncatingIfNeeded: epoch)) + device + be32(index) + Data(SHA256.hash(data: inner))
    }

    private static func wrap(_ inner: Data, index: UInt32, group: UUID, epoch: GroupEpoch, keys: GroupMemberKeys, device: Data) throws -> Data {
        let signature = try keys.signing.signature(for: signed(group: group, epoch: epoch.number, device: device, index: index, inner: inner))
        let body = keys.publicKey + device + be32(index) + signature + inner
        return try ChaChaPoly.seal(EnvelopeCore.padded(body), using: epoch.outerKey).combined
    }

    /// Seals `payload` as message `chain.index` of `keys`' chain, and moves the chain on.
    static func seal(_ payload: Data, group: UUID, epoch: GroupEpoch, keys: GroupMemberKeys, device: Data,
                     chain: inout SenderChain) throws -> Data {
        guard chain.index < directIndex else { throw Failure.malformed }
        let device = deviceTag(device)
        let (messageKey, next) = chain.step()
        let inner = try ChaChaPoly.seal(payload, using: SymmetricKey(data: messageKey)).combined
        let blob = try wrap(inner, index: chain.index, group: group, epoch: epoch, keys: keys, device: device)
        chain = next
        return blob
    }

    /// Seals a direct post (`Payload.groupDirect`, whose items are already sealed one by one): signed, under the outer
    /// layer only.
    static func sealDirect(_ payload: Data, group: UUID, epoch: GroupEpoch, keys: GroupMemberKeys, device: Data) throws -> Data {
        try wrap(payload, index: directIndex, group: group, epoch: epoch, keys: keys, device: deviceTag(device))
    }

    /// Opens the outer layer and checks the sender's signature. Whether the sender is a member, and opening the inner
    /// layer, is up to the caller, who holds the chains.
    static func outer(_ blob: Data, group: UUID, epoch: GroupEpoch) throws -> Outer {
        guard let box = try? ChaChaPoly.SealedBox(combined: blob), let padded = try? ChaChaPoly.open(box, using: epoch.outerKey),
              let body = EnvelopeCore.unpadded(padded), body.count > head else { throw Failure.malformed }
        let b = Data(body)
        let sender = Data(b.prefix(32))
        let device = Data(b.dropFirst(32).prefix(deviceLength))
        let index = b.dropFirst(32 + deviceLength).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let signature = Data(b.dropFirst(36 + deviceLength).prefix(64))
        let inner = Data(b.dropFirst(head))
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

/// What a member keeps to read others in one group: each sender device's chain where it has got to, and keys for
/// messages skipped over (arrived out of order), so each one opens once and the key is then forgotten. A chain is only
/// ever started from what its sender device handed over (`start`), never worked out from the epoch key.
struct GroupReader: Codable, Equatable {
    /// "epoch|sender hex|device hex" → the chain's next position.
    var chains: [String: SenderChain] = [:]
    /// "epoch|sender hex|device hex|index" → that message's key.
    var skipped: [String: Data] = [:]
    /// "epoch|sender hex|device hex" → the first position this device was given: a post from before it was never
    /// readable here (ask for it), one from after it and before the chain's position has been read (or skipped).
    var starts: [String: UInt32]? = [:]
    /// "epoch|sender hex|device hex" → posts from before `starts` whose keys were filled in later from a chain handed over
    /// again: each counts as read once used, so a copy posted again isn't opened twice, while the others from back then
    /// can still be asked for.
    var filled: [String: Set<UInt32>]?
    /// Chains passed on by someone other than the device they belong to (a channel's follower gets staff chains from the
    /// staff member who invited it), until a post that device signed opens with one: only then is it known to be that
    /// device's. One that doesn't open such a post is dropped (`dropUnproven`) and asked for again, so nobody passing
    /// chains on can plant one of their own making that keeps the real one out.
    var unproven: Set<String>?

    static let maxSkip: UInt32 = 2_000
    /// Most keys kept for one sender's skipped messages, and in all.
    static let maxSkippedPerSender = 1_000
    static let maxSkipped = 20_000
    /// Most devices (chains) one member may post from in one epoch.
    static let maxDevicesPerSender = 16
    /// Most posting devices followed in one epoch, all members together.
    static let maxChainsPerEpoch = 2_000

    enum Lookup: Equatable {
        case key(Data)
        /// No key for it here: the sender device's chain isn't followed, or not from that far back. Hold it and ask.
        case missing
        /// Already opened (or skipped and let go): a copy, dropped.
        case used
    }

    static func id(epoch: Int, sender: Data, device: Data) -> String { "\(epoch)|\(sender.hex)|\(device.hex)" }

    /// Whether this sender device's chain is followed already.
    func follows(epoch: Int, sender: Data, device: Data) -> Bool { chains[Self.id(epoch: epoch, sender: sender, device: device)] != nil }

    /// The key for `index` of `sender`'s chain in `epoch`, used up (it can't be had twice).
    mutating func messageKey(epoch: Int, sender: Data, device: Data, index: UInt32) -> Lookup {
        let id = Self.id(epoch: epoch, sender: sender, device: device)
        if let key = skipped.removeValue(forKey: "\(id)|\(index)") { return .key(key) }
        guard var chain = chains[id] else { return .missing }
        if index < chain.index {
            return index < (starts?[id] ?? 0) && filled?[id]?.contains(index) != true ? .missing : .used
        }
        guard index - chain.index <= Self.maxSkip else { return .missing }
        while chain.index < index {
            let (key, next) = chain.step()
            skipped["\(id)|\(chain.index)"] = key
            chain = next
        }
        let (key, next) = chain.step()
        chains[id] = next
        trim(id: id, senderPrefix: "\(epoch)|\(sender.hex)|", index: index)
        return .key(key)
    }

    /// A chain position handed over by its sender device (or, in a channel, passed on by staff). A chain not followed yet
    /// starts there. One followed already gains only keys for `wanted` (posts held here, unread) from before its position;
    /// nothing else is kept, so no key of a post already read is ever made again. True if anything was taken.
    @discardableResult
    mutating func start(epoch: Int, sender: Data, device: Data, chain given: SenderChain, wanted: [UInt32] = [], proven: Bool = true) -> Bool {
        guard given.key.count == 32, given.index < GroupSeal.directIndex else { return false }
        let id = Self.id(epoch: epoch, sender: sender, device: device)
        if starts == nil { starts = [:] }
        // A chain from its own device replaces one passed on that no post has proved yet.
        if proven, unproven?.contains(id) == true { drop(id) }
        if let held = chains[id] {
            // Nothing proved is extended from a source that proves nothing either.
            if !proven, unproven?.contains(id) == true { return false }
            // Far further on than this device could step to: the chain goes on from there (what lies between is lost).
            if given.index > held.index, given.index - held.index > Self.maxSkip {
                chains[id] = given
                return true
            }
            guard given.index < held.index else { return false }
            let floor = starts?[id] ?? 0
            var chain = given
            var took = false
            for index in Set(wanted).sorted() where index >= given.index && index < held.index && index < floor
                && index - given.index <= Self.maxSkip && skipped["\(id)|\(index)"] == nil && filled?[id]?.contains(index) != true {
                while chain.index < index { chain = chain.step().next }
                skipped["\(id)|\(index)"] = chain.step().messageKey
                filled = filled ?? [:]
                filled?[id, default: []].insert(index)
                took = true
            }
            return took
        }
        let senderPrefix = "\(epoch)|\(sender.hex)|"
        if chains.keys.count(where: { $0.hasPrefix(senderPrefix) }) >= Self.maxDevicesPerSender { return false }
        if chains.keys.count(where: { $0.hasPrefix("\(epoch)|") }) >= Self.maxChainsPerEpoch { return false }
        chains[id] = given
        starts?[id] = given.index
        if !proven { unproven = (unproven ?? []).union([id]) }
        return true
    }

    /// A post from this sender device opened: its chain is that device's.
    mutating func proved(epoch: Int, sender: Data, device: Data) {
        guard unproven?.isEmpty == false else { return }
        unproven?.remove(Self.id(epoch: epoch, sender: sender, device: device))
        if unproven?.isEmpty == true { unproven = nil }
    }

    /// A post this sender device signed didn't open with a chain that was passed on and not yet proved: the chain isn't
    /// that device's, and goes (with its skipped keys), so the real one can be taken. True if it went.
    mutating func dropUnproven(epoch: Int, sender: Data, device: Data) -> Bool {
        let id = Self.id(epoch: epoch, sender: sender, device: device)
        guard unproven?.contains(id) == true else { return false }
        drop(id)
        return true
    }

    private mutating func drop(_ id: String) {
        chains[id] = nil
        starts?[id] = nil
        filled?[id] = nil
        skipped = skipped.filter { !$0.key.hasPrefix(id + "|") }
        unproven?.remove(id)
        if unproven?.isEmpty == true { unproven = nil }
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
        starts = starts?.filter { !$0.key.hasPrefix("\(epoch)|") }
        filled = filled?.filter { !$0.key.hasPrefix("\(epoch)|") }
        unproven = unproven?.filter { !$0.hasPrefix("\(epoch)|") }
    }

    /// Forgets everything about epochs before `epoch`. Only for epochs no longer read: while one is, what was opened in
    /// it must be remembered, so an old envelope posted again isn't taken a second time.
    mutating func drop(before epoch: Int) {
        let keep = { (k: String) in (Int(k.split(separator: "|").first ?? "") ?? 0) >= epoch }
        chains = chains.filter { keep($0.key) }
        skipped = skipped.filter { keep($0.key) }
        starts = starts?.filter { keep($0.key) }
        filled = filled?.filter { keep($0.key) }
        unproven = unproven?.filter(keep)
    }
}

// MARK: - Pairwise sessions between member devices

/// One sender device's chain at a position, handed to one reader device. Who it belongs to is said here, but a reader
/// takes it in a group only over its session with that very device (and in a channel only from the staff member who
/// invited it): a wrong key opens nothing, and every post is signed by its sender anyway.
struct GroupChainKey: Codable, Equatable {
    var epoch: Int
    var sender: Data
    var device: Data
    var index: UInt32
    var key: Data

    var chain: SenderChain { SenderChain(key: key, index: index) }
    var isValid: Bool { (0..<Int(Int32.max)).contains(epoch) && sender.count == 32 && device.count == GroupSeal.deviceLength && key.count == 32 && index < GroupSeal.directIndex }
}

/// "Hand me your chain in `epoch` from message `index` on": a reader holding a post it can't open.
struct GroupChainWant: Codable, Equatable, Hashable {
    var epoch: Int
    var sender: Data
    var device: Data
    var index: UInt32

    var chainID: String { GroupReader.id(epoch: epoch, sender: sender, device: device) }
    var isValid: Bool { (0..<Int(Int32.max)).contains(epoch) && sender.count == 32 && device.count == GroupSeal.deviceLength && index < GroupSeal.directIndex }
}

/// What travels over a pairwise session: chain positions, and asks for them.
struct GroupDirectBody: Codable, Equatable {
    var keys: [GroupChainKey]?
    var wants: [GroupChainWant]?

    static let maxEach = 64
}

/// One item of a direct post, for one member device (`to`, `device`): a session being asked for (`hello`, with what is
/// wanted, which is no secret, alongside), the answer to one (`accept` and the first message on it), or a message on a
/// session that is open.
struct GroupDirect: Codable, Equatable {
    var to: Data
    var device: Data
    var hello: SessionInit?
    var wants: [GroupChainWant]?
    var accept: SessionAccept?
    var message: RatchetMessage?

    /// Most items one direct post may carry.
    static let maxItems = 1_200
    /// Most items of one post meant for this device that are looked at (all from the one device that posted it), and of
    /// those, only the first ask for a session.
    static let maxForOneDevice = 64
}

/// This device's pairwise session with one device of one member (another member's, or another of this account's own),
/// in one group. It is the Double Ratchet 1:1 chats use, with its sparse post-quantum ratchet, opened by the same
/// exchange (`GroupHandshake`) between the two members' group keys: fresh X25519 and ML-KEM-768 keys on both sides, thrown
/// away once it opens. So what goes over it can't be opened again from either phone later.
struct GroupPeer: Codable, Equatable {
    var member: Data
    var device: Data
    var session: Ratchet?
    /// This device asked for a session (`hello`) and waits for the answer.
    var pending: PendingHandshake?
    /// Their asks this device has answered (their one-off keys), so one posted again isn't answered twice.
    var answered: [Data] = []
    /// What waits for the session to open: chain positions to hand over.
    var queued: [GroupChainKey]?
    var used = Date()
    /// When this device last had to start over (a message that didn't open), so it isn't done on every post.
    var resetAt: Date?
    /// The lowest position of this device's own chain in each epoch (by number, as text) this device hands that device:
    /// where it was first given it, and, once that device has shown it got it, where this device's chain was then. So
    /// whoever takes that device can't ask for what it has already read.
    var floor: [String: UInt32]?
    /// Epochs whose chain this device handed that device that it hasn't shown it got yet (by sending anything that opens
    /// on the session since).
    var unconfirmed: [String]?
    /// When the session opened (the relay's time on the post that opened it): an ask for a new one from before is not
    /// taken while it works.
    var openedAt: Date?
    /// When a message from that device last didn't open here: its ask for a new session is taken then.
    var failedAt: Date?
    /// The epoch this device first met that one in, so a member can't make up device after device.
    var metIn: Int?

    static func id(member: Data, device: Data) -> String { "\(member.hex)|\(device.hex)" }

    /// Told apart by who, the state of the ask, and when the session was last used (every message moves that on).
    static func == (a: GroupPeer, b: GroupPeer) -> Bool {
        a.member == b.member && a.device == b.device && a.used == b.used && a.answered == b.answered && a.queued == b.queued
            && a.resetAt == b.resetAt && a.pending?.ephemeral == b.pending?.ephemeral && (a.session == nil) == (b.session == nil)
            && a.floor == b.floor && a.unconfirmed == b.unconfirmed && a.openedAt == b.openedAt && a.failedAt == b.failedAt
    }

    /// Most sessions one group keeps: past it, the ones unused longest go.
    static let maxPerGroup = 3_000
    /// Most devices of one member met for the first time in one epoch.
    static let maxNewPerMember = 16
    /// How long after a message from a device didn't open its ask for a new session is taken, though one is open.
    static let failedWindow: TimeInterval = 86_400
    /// An ask that got no answer is made again after this long.
    static let helloRetry: TimeInterval = 600
}

/// The exchange that opens a `GroupPeer` session: `Handshake`'s, between two members' keys in one group and two devices,
/// all of which go into the root and the session's bound data.
enum GroupHandshake {
    private static let info = Data("pulshade.group.handshake.v1".utf8)

    static func start() throws -> (PendingHandshake, SessionInit) { try Handshake.start() }

    /// The answering side: it can write at once.
    static func accept(_ request: SessionInit, group: UUID, me: GroupMemberKeys, myDevice: Data, them: MemberCard,
                       theirDevice: Data) throws -> (Ratchet, SessionAccept) {
        let theirEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.ephemeral)
        let theirIdentity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: them.agreementKey)
        let encapsulation = try MLKEM768.PublicKey(rawRepresentation: request.kem).encapsulate()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ikm = try raw(me.agreement.sharedSecretFromKeyAgreement(with: theirEphemeral))
            + raw(ephemeral.sharedSecretFromKeyAgreement(with: theirIdentity))
            + raw(ephemeral.sharedSecretFromKeyAgreement(with: theirEphemeral))
            + encapsulation.sharedSecret.withUnsafeBytes { Data($0) }
        let parties = binding(group: group, initiator: them.signingKey, initiatorDevice: theirDevice, responder: me.publicKey, responderDevice: myDevice)
        let root = root(ikm, request.ephemeral + ephemeral.publicKey.rawRepresentation + request.kem + encapsulation.encapsulated, parties)
        let ratchet = try Ratchet.sender(root: root, theirRatchet: request.ephemeral, ad: info + parties)
        return (ratchet, SessionAccept(replyTo: request.ephemeral, ephemeral: ephemeral.publicKey.rawRepresentation,
                                       kemCiphertext: encapsulation.encapsulated))
    }

    /// The asking side, once the answer comes.
    static func complete(_ pending: PendingHandshake, _ answer: SessionAccept, group: UUID, me: GroupMemberKeys, myDevice: Data,
                         them: MemberCard, theirDevice: Data) throws -> Ratchet {
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: pending.ephemeral)
        let kem = try MLKEM768.PrivateKey(seedRepresentation: pending.kemSeed, publicKey: nil)
        let theirEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: answer.ephemeral)
        let theirIdentity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: them.agreementKey)
        let pq = try kem.decapsulate(answer.kemCiphertext)
        let ikm = try raw(ephemeral.sharedSecretFromKeyAgreement(with: theirIdentity))
            + raw(me.agreement.sharedSecretFromKeyAgreement(with: theirEphemeral))
            + raw(ephemeral.sharedSecretFromKeyAgreement(with: theirEphemeral))
            + pq.withUnsafeBytes { Data($0) }
        let parties = binding(group: group, initiator: me.publicKey, initiatorDevice: myDevice, responder: them.signingKey, responderDevice: theirDevice)
        let root = root(ikm, ephemeral.publicKey.rawRepresentation + answer.ephemeral + kem.publicKey.rawRepresentation + answer.kemCiphertext, parties)
        return Ratchet.receiver(root: root, ourRatchet: ephemeral, ad: info + parties)
    }

    private static func binding(group: UUID, initiator: Data, initiatorDevice: Data, responder: Data, responderDevice: Data) -> Data {
        bytes(group) + initiator + GroupSeal.deviceTag(initiatorDevice) + responder + GroupSeal.deviceTag(responderDevice)
    }

    private static func root(_ ikm: Data, _ transcript: Data, _ parties: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: Data(SHA256.hash(data: transcript + parties)),
                               info: info, outputByteCount: 32)
    }

    private static func raw(_ secret: SharedSecret) -> Data { secret.withUnsafeBytes { Data($0) } }
}

/// Sent over a 1:1 chat to someone being added: everything they need to read and write in the group from now on.
/// Whoever adds someone to a group starts a new epoch first, so a newcomer reads from when they joined, not what the
/// group said before (in a channel, only once something was said; followers get staff chains from where they came in).
struct GroupInvite: Codable, Equatable {
    var settings: GroupSettings
    var epoch: GroupEpoch
    /// In a channel: the owner wants this follower as staff, so they answer with a card with their name instead of the
    /// nameless one a follower gives. Apps from before ignore it.
    var staff: Bool?
    /// With `staff`: the key of the staff-only mailbox the follower roster is kept in (see `SharedGroup.staffEpoch`).
    var staffKey: Data?
    /// In a channel: a tag made from the channel's code mailbox (`Invite.codeTag`), so someone who followed a code knows
    /// this invite is for the channel that code was for, and not another of the same person's. Nil from apps before it,
    /// and from staff whose device doesn't hold the code; such an invite waits for a yes. Apps from before ignore it.
    var code: Data?
    /// In a channel: the staff member's word that the account sending this invite is theirs (`StaffVouch`). A channel
    /// this account doesn't follow yet is only taken from an invite that carries one naming its sender, so nobody but staff
    /// becomes the account the channel is followed through. Apps from before send none, and their invites are refused.
    var vouch: StaffVouch?
}

/// A staff member's signature, with their group key in the channel, over the channel and the signing key of the account
/// sending an invite: that account is the staff member. Someone who forwards an invite they were sent can't make one that
/// names their own account, and one naming the staff member's account doesn't match who sent it.
struct StaffVouch: Codable, Equatable {
    var key: Data
    var signature: Data

    private static func message(group: UUID, account: Data) -> Data {
        Data("pulshade.channel.vouch.v1".utf8) + bytes(group) + account
    }

    static func make(_ keys: GroupMemberKeys, group: UUID, account: Data) -> StaffVouch? {
        guard let signature = try? keys.signing.signature(for: message(group: group, account: account)) else { return nil }
        return StaffVouch(key: keys.publicKey, signature: signature)
    }

    /// Made by someone the settings name as staff, for this channel and this account.
    func checks(_ settings: GroupSettings, account: Data) -> Bool {
        guard settings.isAdmin(key), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return pub.isValidSignature(signature, for: Self.message(group: settings.group, account: account))
    }
}

/// A post waiting to go into a group's mailbox, already sealed (its chain has moved on, so it must go as it is).
/// A post of a group that is gone from this device, still to reach the group's mailbox (`AppData.partingPosts`).
struct PartingPost: Codable, Equatable {
    var post: GroupOutgoing
    /// The persona the group was under, whose connection it goes on.
    var persona: UUID?
    /// Whether this device had posted to that mailbox before, so the relay knows it and no proof of work is needed.
    var known: Bool
}

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
    /// Who posted it, and from which device, so no one member's posts crowd out the others'.
    var from: Data?
    var device: Data?
    /// Held for want of a chain (not because its sender isn't listed yet).
    var chain: Bool?

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
    /// Where this device's chain in each epoch began, kept while the epoch is read, to answer a member device that asks
    /// for a post of this device's it can't open (`GroupChainWant`). Opens only what this device itself said.
    var chainStarts: [String: SenderChain]?
    /// This device's pairwise sessions with other member devices, by `GroupPeer.id`.
    var peers: [String: GroupPeer]?
    /// Chains this device asked for, by `GroupChainWant.chainID`, and when (asked again ten minutes on).
    var chainAsked: [String: Date]?
    /// As staff of a channel: followers who asked this device for another staff device's chain, by chain id, then by
    /// account, with the position each wants. Passed on once the chain comes, then let go.
    var followerWants: [String: [String: UInt32]]?
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
    /// As a follower newly let in: the channel's earlier posts the inviter may still hand over (`takeChannelHistory`).
    var historyWindow: ChannelHistoryWindow?
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
    /// As staff of a channel: where each staff device's chain was (by `GroupReader.id`) when this device let a follower
    /// in, by the follower's account fingerprint. Nothing from before goes to them.
    var admittedAt: [String: [String: UInt32]]?
    /// The account's group secret this group's keys are still made with (`AppData.groupSecret` from before it was
    /// replaced; empty for the seed alone), until the settings move this account to keys made with the current one
    /// (`GroupSettings.renewal`). Nil: the current one.
    var memberSecret: Data?
    /// The tag this device signs its posts with: random, made the first time it posts, and never copied to another
    /// device (a backup or a newly linked device makes its own), so no two ever use the same chain.
    var myTag: Data?
    /// Someone has said something in the current epoch (as far as this device has read). A channel's newcomer is then
    /// given a new epoch; a group's always gets one.
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
    /// Posts from someone the settings held here don't list yet (the settings that add them are still on the way), or
    /// from a sender device whose chain hasn't been handed over yet (asked for meanwhile): read again once what they need
    /// arrives, instead of being lost.
    var heldMail: [HeldGroupMail]?
    /// This device's own recent posts, kept until read back (see `KeptPost`).
    var kept: [KeptPost]?
    /// The last time this device read the group's mailbox to the end.
    var lastFetch: Date?
    /// Set when this device was away longer than the relay keeps mail: the time it last read, to ask members for what it missed.
    var catchUpSince: Date?
    var catchUpAsked: Date?
    /// Moves to new keys this device took (`GroupSettings.renewal`): whose old key, the key it moved to, and in which
    /// version. A later version from the same old key that gives the place to another key shows that two devices hold
    /// those old keys (`disputed`). The newest `RenewalMark.kept`.
    var renewals: [RenewalMark]?
    /// Member keys two devices fought over (one member's old key and both new keys it was moved to): nothing they sign
    /// or post is taken until an admin adds them again (a version from someone else that brings the key in anew).
    var disputed: [Data]?
    /// The group secret this device's own move to new keys was made from, kept until the group has settled on it: if a
    /// competing change wins instead, this device goes back to the keys the group still lists, and moves again later.
    var renewing: Data?
    /// Settings that move this account's own place to keys this device can't make, and when they came (see
    /// `AppModel.settleForeignMoves`).
    var foreignMove: GroupSettings?
    var foreignMoveAt: Date?
    /// Who brought each member in, by their group key (in hex): the signer of the version this device took that added
    /// them, or, for a member who moved to new keys, whoever brought in the key they moved from. Kept for those still
    /// listed. A dispute over a member's keys holds back everyone those keys brought in too (`broughtIn`).
    var addedBy: [String: Data]?

    /// Notes who `next`, taken in place of `base`, brought in.
    mutating func noteAdded(from base: GroupSettings, to next: GroupSettings) {
        var by = addedBy ?? [:]
        if let (old, new) = base.renewal(to: next) {
            by[new.hex] = by[old.hex]
        } else {
            for card in next.members where !base.isMember(card.signingKey) { by[card.signingKey.hex] = next.signer }
        }
        let listed = Set(next.members.map(\.signingKey.hex))
        by = by.filter { listed.contains($0.key) }
        addedBy = by.isEmpty ? nil : by
    }

    /// `keys`, every key they moved to since (`renewals`), and every member any of those brought in, and so on: all that
    /// came in under keys nobody can vouch for.
    func broughtIn(under keys: [Data]) -> Set<Data> {
        var found = Set(keys.filter { !$0.isEmpty })
        while true {
            let before = found.count
            for mark in renewals ?? [] where found.contains(mark.old) { found.insert(mark.new) }
            for card in settings.members where addedBy?[card.signingKey.hex].map(found.contains) == true { found.insert(card.signingKey) }
            if found.count == before { return found }
        }
    }

    /// The key holding `key`'s place now: `key` itself, or the newest key it moved to (`renewals`).
    func holder(of key: Data) -> Data {
        var key = key
        for _ in 0..<RenewalMark.kept {
            guard let mark = renewals?.last(where: { $0.old == key }), mark.new != key else { break }
            key = mark.new
        }
        return key
    }

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

/// A member's move to new keys, as one device took it (`SharedGroup.renewals`).
struct RenewalMark: Codable, Equatable {
    var old: Data
    var new: Data
    var version: Int

    static let kept = 64
}
