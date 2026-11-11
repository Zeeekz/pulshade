import Foundation
import CryptoKit

// Join links for groups that share one mailbox (stage C of docs/groups-design.md).
//
// A link holds one secret and an 8-byte check of the member key of the admin who made it. The secret names a slot in
// the relay's sealed-backup store (the same store spare keys use, so the relay needed no change) and opens what is in
// it: the group's preview, signed by that admin's group key. The preview says where to send a request to join (an
// ordinary mailbox) and the key to seal it to. The request carries the newcomer's card for this group alone and a fresh
// mailbox for the answer. An admin's phone that reads it adds them (an open link) or shows it to the admins (a link that
// needs approval), and answers with what the newcomer needs to read the group. Nobody involved learns anyone's account.
//
// The links themselves (and the group's bans) are a document of their own, signed by an admin and posted into the
// group's mailbox like the settings. They are kept out of `GroupSettings` so apps from before links, which sign and
// check the settings as they know them, keep accepting new versions.

private func derive(_ key: Data, _ label: String) -> Data {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: Data("pulshade.join.v1".utf8),
                           info: Data(label.utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
}

private func canonical<T: Encodable>(_ value: T, _ label: String) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dataEncodingStrategy = .base64
    encoder.dateEncodingStrategy = .secondsSince1970
    return Data(label.utf8) + ((try? encoder.encode(value)) ?? Data())
}

/// A date to the whole second. Dates in signed documents are kept to whole seconds, so they come back from JSON exactly
/// and the signature still checks.
func wholeSecond(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

/// The first 8 bytes of a member key's hash: what a link says about who made it.
func joinCheck(_ memberKey: Data) -> Data { Data(SHA256.hash(data: memberKey).prefix(8)) }

/// One way into a group. Everything in it is known to every member (it travels in `GroupLinks`); only admins act on it.
struct JoinLink: Codable, Equatable, Identifiable {
    var id: UUID
    var label: String
    var made: Date
    /// After this, requests through it are turned down.
    var expires: Date?
    /// How many people may join through it.
    var limit: Int?
    var used: Int = 0
    /// Requests wait for an admin to say yes, instead of being let in by the first admin's phone that reads them.
    var approval: Bool
    /// In the link: names the preview's slot and opens it.
    var secret: Data
    /// The private half of the key requests are sealed to.
    var requestKey: Data
    /// Where requests go: the receive key of an ordinary mailbox.
    var mailbox: Data
    /// The member key of the admin who made it, which signs its preview.
    var creator: Data

    static func make(label: String, approval: Bool, expires: Date?, limit: Int?, creator: Data) -> JoinLink {
        JoinLink(id: UUID(), label: String(label.prefix(40)), made: wholeSecond(Date()), expires: expires.map(wholeSecond), limit: limit.map { max(1, $0) },
                 approval: approval, secret: .random(32), requestKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                 mailbox: .random(32), creator: creator)
    }

    /// The same link with new secrets: every copy of the old one stops working.
    func reset() -> JoinLink {
        var next = self
        next.secret = .random(32)
        next.requestKey = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        next.mailbox = .random(32)
        return next
    }

    var code: GroupLinkCode { GroupLinkCode(secret: secret, check: joinCheck(creator)) }
    var requestPublicKey: Data? { (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: requestKey))?.publicKey.rawRepresentation }

    func isOpen(at now: Date = Date()) -> Bool {
        (expires.map { $0 > now } ?? true) && (limit.map { used < $0 } ?? true)
    }

    var wellFormed: Bool {
        secret.count == 32 && requestKey.count == 32 && mailbox.count == 32 && creator.count == 32 && label.count <= 40
            && (limit.map { (1...100_000).contains($0) } ?? true) && (0...1_000_000).contains(used)
    }
}

/// What the link holds, as text: `pulshade://group/<secret and check, base64url>`.
struct GroupLinkCode: Equatable {
    var secret: Data
    var check: Data

    var text: String { (secret + check).base64URL }
    var link: String { "pulshade://group/" + text }

    init(secret: Data, check: Data) {
        self.secret = secret
        self.check = check
    }

    /// From a link (`pulshade://group/…` or `group/…`).
    init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("pulshade://group/") || text.lowercased().hasPrefix("group/"),
              let range = text.range(of: "group/", options: [.caseInsensitive]),
              let raw = Data(base64URL: String(text[range.upperBound...])), raw.count == 40 else { return nil }
        secret = Data(raw.prefix(32))
        check = Data(raw.suffix(8))
    }
}

/// A join link opened from outside the app or scanned, waiting to be shown.
struct OpenedGroupLink: Identifiable, Equatable {
    let id = UUID()
    var code: GroupLinkCode
}

/// A group's links and bans, as one signed document. Only an admin's version is taken.
struct GroupLinks: Codable, Equatable {
    var group: UUID
    var version: Int
    var links: [JoinLink] = []
    /// Member keys whose requests are turned down.
    var bans: [Data] = []
    var signer = Data()
    var signature = Data()

    static let maxLinks = 20
    static let maxBans = 2_000

    func signable() -> Data {
        var copy = self
        copy.signature = Data()
        return canonical(copy, "pulshade.group.links.v1")
    }

    mutating func sign(with keys: GroupMemberKeys) {
        signer = keys.publicKey
        signature = (try? keys.signing.signature(for: signable())) ?? Data()
    }

    var signatureIsValid: Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signer) else { return false }
        return key.isValidSignature(signature, for: signable())
    }

    var wellFormed: Bool {
        groupNumberRange.contains(version) && links.count <= Self.maxLinks && bans.count <= Self.maxBans
            && links.allSatisfy(\.wellFormed) && Set(links.map(\.id)).count == links.count && bans.allSatisfy { $0.count == 32 }
    }

    var tieBreak: Data { Data(SHA256.hash(data: signable())) }

    func link(_ id: UUID) -> JoinLink? { links.first { $0.id == id } }
}

/// What someone with a link sees before joining. Signed by the admin who made the link; the link checks it's theirs.
struct GroupPreview: Codable, Equatable {
    var group: UUID
    var link: UUID
    var title: String
    var about: String?
    var avatar: Data?
    var members: Int
    var approval: Bool
    var expires: Date?
    /// The public key requests are sealed to, and the send id of the mailbox they go to.
    var requestKey: Data
    var mailbox: Data
    var made: Date
    var signer = Data()
    var signature = Data()

    func signable() -> Data {
        var copy = self
        copy.signature = Data()
        return canonical(copy, "pulshade.group.preview.v1")
    }

    mutating func sign(with keys: GroupMemberKeys) {
        signer = keys.publicKey
        signature = (try? keys.signing.signature(for: signable())) ?? Data()
    }

    /// Genuine and from the admin the link names, well-formed, and not past its date.
    func verified(by code: GroupLinkCode, now: Date = Date()) -> Bool {
        guard joinCheck(signer) == code.check, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signer),
              key.isValidSignature(signature, for: signable()) else { return false }
        return requestKey.count == 32 && mailbox.count == 32 && title.count <= 100 && (about?.count ?? 0) <= 500
            && (avatar?.count ?? 0) <= 32 * 1024 && (0...GroupSettings.maxMembers).contains(members) && (expires.map { $0 > now } ?? true)
    }

    /// What changes the preview (everything but when it was made and the signature), to tell when it needs writing again.
    var contentHash: Data {
        var copy = self
        copy.made = Date(timeIntervalSince1970: 0)
        copy.signer = Data()
        copy.signature = Data()
        return Data(SHA256.hash(data: canonical(copy, "")))
    }
}

/// Asking to join: the newcomer's card for this group, where to answer, and an optional note for the admins.
struct JoinRequest: Codable, Equatable {
    var group: UUID
    var link: UUID
    var card: MemberCard
    /// Send id of the mailbox the answer goes to.
    var reply: Data
    var note: String?
    var at: Date

    var wellFormed: Bool {
        reply.count == 32 && (note?.count ?? 0) <= 200 && (card.avatar?.count ?? 0) <= 16 * 1024 && card.name.count <= 100
    }
}

/// What travels through join and answer mailboxes, sealed with `EnvelopeCore` from one group key to another.
enum JoinMail: Codable, Equatable {
    case request(JoinRequest)
    /// You're in: the settings that name you and the epoch they're in.
    case admitted(GroupInvite)
    case declined(group: UUID)
}

/// A request to join waiting for an admin's yes, as this device last read it from the link's mailbox.
struct HeldJoin: Codable, Equatable, Identifiable {
    var request: JoinRequest
    /// Where it waits on the relay, to let go of it once someone decides.
    var envelope: UInt64
    var seen: Date

    var id: Data { request.card.signingKey }
}

/// When this device last wrote a link's preview, and what it said.
struct PreviewMark: Codable, Equatable {
    var hash: Data
    var at: Date
}

/// A request of yours to join a group, until it's answered.
struct JoinAsk: Codable, Equatable, Identifiable {
    var id = UUID()
    var group: UUID
    var persona: UUID?
    var title: String
    var avatar: Data?
    var approval: Bool
    /// Where the answer comes: the receive key of a mailbox made for it.
    var reply: Data
    /// The sealed request and where it goes, kept until it has gone.
    var request: Data
    var mailbox: Data
    var sent = false
    var asked = Date()
    var declined = false

    static let life: TimeInterval = 7 * 86_400
}

/// The slot a link's preview lives in: a slot in the relay's sealed-backup store whose keys come from the link's secret.
enum JoinSlot {
    static func keys(_ secret: Data) -> SpareSlot.Keys? {
        guard secret.count == 32, let signer = try? Curve25519.Signing.PrivateKey(rawRepresentation: derive(secret, "slot.signing"))
        else { return nil }
        return SpareSlot.Keys(signer: signer, sealing: SymmetricKey(data: derive(secret, "slot.sealing")))
    }

    /// Padded to 32 KB (or the next power of two), so every preview is one size.
    static func seal(_ preview: GroupPreview, with keys: SpareSlot.Keys) -> Data? {
        guard let plain = try? JSONEncoder.pulshade.encode(preview) else { return nil }
        var size = 32 * 1024
        while size < plain.count + 5 { size *= 2 }
        var padded = Data([0x01])
        withUnsafeBytes(of: UInt32(plain.count).bigEndian) { padded.append(contentsOf: $0) }
        padded.append(plain)
        padded.append(Data(count: size - padded.count))
        return try? AES.GCM.seal(padded, using: keys.sealing, authenticating: keys.name).combined
    }

    static func open(_ blob: Data, with keys: SpareSlot.Keys) -> GroupPreview? {
        guard blob.count <= 256 * 1024, let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: keys.sealing, authenticating: keys.name),
              plain.first == 0x01, plain.count >= 5 else { return nil }
        let length = plain.dropFirst().prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard 5 + length <= plain.count else { return nil }
        return try? JSONDecoder.pulshade.decode(GroupPreview.self, from: plain.subdata(in: 5..<(5 + length)))
    }
}

enum JoinSeal {
    /// Seals a join mail from one group key to another (the receiver's group agreement key, or a link's request key).
    static func seal(_ mail: JoinMail, from keys: GroupMemberKeys, to agreementKey: Data) -> Data? {
        guard let body = try? JSONEncoder.pulshade.encode(mail) else { return nil }
        return try? EnvelopeCore.seal(body: body, framed: false, signing: keys.signing, agreement: keys.agreement, device: Data(),
                                      caps: 0, at: RelayClock.now, to: agreementKey)
    }

    /// Opens one, saying which group key sealed it.
    static func open(_ blob: Data, with agreement: Curve25519.KeyAgreement.PrivateKey) -> (mail: JoinMail, signer: Data, agreement: Data, at: Date)? {
        guard blob.count <= 256 * 1024, let header = try? EnvelopeCore.open(blob, agreement: agreement),
              let mail = try? JSONDecoder.pulshade.decode(JoinMail.self, from: header.body) else { return nil }
        return (mail, header.signer, header.agreement, header.sentAt)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
