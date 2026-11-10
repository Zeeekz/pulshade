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

    static func fresh(number: Int, days: Int = 7) -> GroupEpoch {
        GroupEpoch(number: number, key: .random(32), days: min(max(days, 1), 7), started: Date())
    }

    /// The mailbox this epoch's mail goes to. A new epoch means a new mailbox, so the relay can't line the two up by it.
    var receiveKey: Data { derive(key, "pulshade.group.mailbox.v1") }
    var sendID: Data { Mailbox.sendID(for: receiveKey) }
    fileprivate var outerKey: SymmetricKey { SymmetricKey(data: derive(key, "pulshade.group.outer.v1")) }

    /// Where a member's chain starts in this epoch.
    func chainStart(for member: Data) -> SenderChain {
        SenderChain(key: derive(key, "pulshade.group.chain.v1", salt: member), index: 0)
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
    var avatar: Data?
    var color: Int?
    var signature: Data

    var fingerprint: String { Identity.fingerprint(of: signingKey) }

    private static func signable(group: UUID, signingKey: Data, agreementKey: Data, name: String, avatar: Data?, color: Int?) -> Data {
        var d = Data("pulshade.group.card.v1".utf8)
        d += bytes(group) + signingKey + agreementKey
        d += Data(SHA256.hash(data: Data(name.utf8))) + Data(SHA256.hash(data: avatar ?? Data()))
        d += be32(UInt32(truncatingIfNeeded: color ?? -1))
        return d
    }

    static func make(_ keys: GroupMemberKeys, group: UUID, name: String, avatar: Data?, color: Int?) -> MemberCard {
        let name = String(name.prefix(64))
        let message = signable(group: group, signingKey: keys.publicKey, agreementKey: keys.agreement.publicKey.rawRepresentation,
                               name: name, avatar: avatar, color: color)
        return MemberCard(signingKey: keys.publicKey, agreementKey: keys.agreement.publicKey.rawRepresentation, name: name,
                          avatar: avatar, color: color, signature: (try? keys.signing.signature(for: message)) ?? Data())
    }

    func verified(group: UUID) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey), agreementKey.count == 32,
              name.count <= 64 else { return false }
        return key.isValidSignature(signature, for: Self.signable(group: group, signingKey: signingKey, agreementKey: agreementKey,
                                                                  name: name, avatar: avatar, color: color))
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
        return Set(keys).count == keys.count && keys.contains(owner) && members.allSatisfy { $0.verified(group: group) }
            && admins.allSatisfy(keys.contains) && mods.allSatisfy(keys.contains) && members.count <= Self.maxMembers
            && title.count <= 100 && (about?.count ?? 0) <= 500
    }

    static let maxMembers = 5_000

    /// Whether `next` may replace this version: signed by its signer, numbered one on, well-formed, for the same group,
    /// and every change in it is one its signer may make.
    func accepts(_ next: GroupSettings) -> Bool {
        guard next.group == group, next.kind == kind, next.version == version + 1, next.signatureIsValid, next.wellFormed(),
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
        SymmetricKey(data: derive(shared, "pulshade.group.rekey.v1", salt: bytes(group) + be32(UInt32(epoch)) + member))
    }
}

/// A group envelope as posted to the mailbox, and opened from it.
enum GroupSeal {
    enum Failure: Error { case malformed, badSignature }

    /// The outside of an envelope, once the epoch's outer key has opened it: who says they sent it, which message of
    /// theirs it is, and the rest still sealed with that message's key.
    struct Outer {
        var sender: Data
        var index: UInt32
        var inner: Data
        var signature: Data
    }

    private static func signed(group: UUID, epoch: Int, index: UInt32, inner: Data) -> Data {
        Data("pulshade.group.msg.v1".utf8) + bytes(group) + be32(UInt32(epoch)) + be32(index) + Data(SHA256.hash(data: inner))
    }

    /// Seals `payload` as message `chain.index` of `keys`' chain, and moves the chain on.
    static func seal(_ payload: Data, group: UUID, epoch: GroupEpoch, keys: GroupMemberKeys, chain: inout SenderChain) throws -> Data {
        let (messageKey, next) = chain.step()
        let inner = try ChaChaPoly.seal(payload, using: SymmetricKey(data: messageKey)).combined
        let signature = try keys.signing.signature(for: signed(group: group, epoch: epoch.number, index: chain.index, inner: inner))
        var body = keys.publicKey + be32(chain.index) + signature
        body += inner
        chain = next
        return try ChaChaPoly.seal(EnvelopeCore.padded(body), using: epoch.outerKey).combined
    }

    /// Opens the outer layer and checks the sender's signature. Whether the sender is a member, and opening the inner
    /// layer, is up to the caller, who holds the chains.
    static func outer(_ blob: Data, group: UUID, epoch: GroupEpoch) throws -> Outer {
        guard let box = try? ChaChaPoly.SealedBox(combined: blob), let padded = try? ChaChaPoly.open(box, using: epoch.outerKey),
              let body = EnvelopeCore.unpadded(padded), body.count > 32 + 4 + 64 + 28 else { throw Failure.malformed }
        let sender = Data(body.prefix(32))
        let index = body.dropFirst(32).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let signature = Data(body.dropFirst(36).prefix(64))
        let inner = Data(body.dropFirst(100))
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: sender),
              key.isValidSignature(signature, for: signed(group: group, epoch: epoch.number, index: index, inner: inner)) else {
            throw Failure.badSignature
        }
        return Outer(sender: sender, index: index, inner: inner, signature: signature)
    }

    static func inner(_ outer: Outer, messageKey: Data) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: outer.inner) else { return nil }
        return try? ChaChaPoly.open(box, using: SymmetricKey(data: messageKey))
    }
}

/// What a member keeps to read others in one group: each sender's chain where it has got to, and keys for messages
/// skipped over (arrived out of order), so each one opens once and the key is then forgotten.
struct GroupReader: Codable, Equatable {
    /// "epoch|sender hex" → the chain's next position.
    var chains: [String: SenderChain] = [:]
    /// "epoch|sender hex|index" → that message's key.
    var skipped: [String: Data] = [:]

    static let maxSkip: UInt32 = 2_000
    static let maxSkipped = 5_000

    /// The key for `index` of `sender`'s chain in `epoch`, used up (it can't be had twice). Nil for a message already
    /// opened, or one too far ahead.
    mutating func messageKey(epoch: GroupEpoch, sender: Data, index: UInt32) -> Data? {
        let id = "\(epoch.number)|\(sender.hex)"
        if let key = skipped.removeValue(forKey: "\(id)|\(index)") { return key }
        var chain = chains[id] ?? epoch.chainStart(for: sender)
        guard index >= chain.index, index - chain.index <= Self.maxSkip else { return nil }
        while chain.index < index {
            let (key, next) = chain.step()
            skipped["\(id)|\(chain.index)"] = key
            chain = next
        }
        let (key, next) = chain.step()
        chains[id] = next
        if skipped.count > Self.maxSkipped {
            // The oldest gaps are least likely ever to fill.
            for k in skipped.keys.sorted().prefix(skipped.count - Self.maxSkipped) { skipped[k] = nil }
        }
        return key
    }

    /// Forgets everything about epochs before `epoch`.
    mutating func drop(before epoch: Int) {
        let keep = { (k: String) in (Int(k.split(separator: "|").first ?? "") ?? 0) >= epoch }
        chains = chains.filter { keep($0.key) }
        skipped = skipped.filter { keep($0.key) }
    }
}

/// Sent over a 1:1 chat to someone being added: everything they need to read and write in the group from now on.
/// Whoever adds someone starts a new epoch first (or uses one they started minutes ago), so a newcomer can read from
/// about when they joined, not what the group said before.
struct GroupInvite: Codable, Equatable {
    var settings: GroupSettings
    var epoch: GroupEpoch
}
