import Foundation
import CryptoKit

// Web links, Telegram style: `https://<domain>/<name>` for a public group, channel or person, and
// `https://<domain>/i/<code>` for a group's join link, a friend's or channel's invite or a one-time chat. A plain path,
// because apps like WhatsApp strip a `+` or `#` part from links. The server serves the page as a file and keeps no
// logs; the relay never sees the code. Links made before (`/+#code`, `/#code`) still open.
//
// The domain is set once, in project.yml (`PULSHADE_LINK_DOMAIN`), and reaches the app through Info.plist. With none
// set, links stay the `pulshade://` ones. On an iPhone with Pulshade the link opens the app straight away (a universal
// link), so the web server never hears of it; without the app, the browser shows the page that says how to get it,
// and still never sends the code.

enum WebLinks {
    /// Set by tests in place of Info.plist.
    nonisolated(unsafe) static var domainOverride: String?

    /// The links' domain, lower case, or nil when this build has none.
    static var domain: String? {
        let raw = domainOverride ?? (Bundle.main.object(forInfoDictionaryKey: "PulshadeLinkDomain") as? String) ?? ""
        return validDomain(raw)
    }

    static func validDomain(_ raw: String) -> String? {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (4...253).contains(host.count), host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), !host.hasPrefix("-"),
              host.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }) else { return nil }
        return host
    }

    /// A public name's link, or nil without a domain.
    static func name(_ handle: String) -> String? { domain.map { "https://\($0)/\(handle)" } }

    /// A group's join link as people share it.
    static func group(_ code: GroupLinkCode) -> String { domain.map { "https://\($0)/i/\(code.text)" } ?? code.link }

    /// A friend invite or a channel's code as people share it.
    static func invite(_ code: String) -> String { domain.map { "https://\($0)/i/\(code)" } ?? Invite.link(code) }

    /// A one-time chat link as people share it.
    static func chat(_ link: ChatLink) -> String { domain.map { "https://\($0)/i/\(link.text)" } ?? link.link }

    /// A profile link, with a check of the account's key so it only ever opens that account (`DirectoryProfile.link`).
    static func profile(_ handle: String, key: Data? = nil) -> String {
        guard let domain else { return DirectoryProfile.link(handle, key: key) }
        return "https://\(domain)/\(handle)" + (key.map { "?k=" + DirectoryProfile.keyCheck(of: $0) } ?? "")
    }

    /// A short link (`ShortCode`): what's shared now for every code.
    static func short(_ code: ShortCode) -> String { domain.map { "https://\($0)/i/\(code.text)" } ?? "" }

    /// The long web link for a code, whichever kind it is: what's shared when a short link can't be put up.
    static func long(_ code: String) -> String {
        if let group = GroupLinkCode(text: code) { return Self.group(group) }
        if code.lowercased().hasPrefix("pshchat1"), let chat = ChatLink(code) { return Self.chat(chat) }
        return invite(code)
    }

    /// What a long code opens, by its kind.
    static func target(forCode code: String) -> Target? {
        guard !code.isEmpty else { return nil }
        if let group = GroupLinkCode(text: code) { return .group(group) }
        if code.lowercased().hasPrefix("pshchat1"), let chat = ChatLink(code) { return .chat(chat) }
        if Invite(code: code) != nil { return .invite(code) }
        return nil
    }

    enum Target: Equatable {
        /// A public name: a person's @handle, or a group's or channel's name, and the key check a profile link carries.
        case name(String, keyCheck: String?)
        case group(GroupLinkCode)
        /// An invite code: a friend's, or a channel's.
        case invite(String)
        case chat(ChatLink)
        /// A short link, looked up on the relay to find which of the others it is.
        case short(ShortCode)
    }

    /// What a web link opens, or nil if it isn't one of ours.
    static func parse(_ url: URL) -> Target? {
        guard let domain, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host()?.lowercased(), host == domain || host == "www." + domain else { return nil }
        // Read as sent: an escaped slash or plus isn't one.
        let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        func code(_ code: String) -> Target? { url.query == nil ? target(forCode: code) : nil }
        // `pulsh.me/i/<code>`: a short link's 16 letters, or a whole code.
        if parts.count == 2, parts[0] == "i" {
            guard url.fragment == nil, url.query == nil else { return nil }
            if let short = ShortCode(parts[1]) { return .short(short) }
            return code(parts[1])
        }
        // Links made before: `pulsh.me/+#code`, and `pulsh.me/#code` where an app dropped the "+".
        guard parts.count == 1 || (parts.isEmpty && url.fragment?.isEmpty == false) else { return nil }
        let part = parts.first ?? "+"
        if part == "+" { return code(url.fragment(percentEncoded: true) ?? "") }
        guard url.fragment == nil else { return nil }
        // A profile link's only extra: `?k=<key check>`, 16 hex digits.
        var keyCheck: String?
        if let query = url.query(percentEncoded: true) {
            guard query.hasPrefix("k="), case let check = String(query.dropFirst(2)).lowercased(),
                  check.count == 16, check.allSatisfy(\.isHexDigit) else { return nil }
            keyCheck = check
        }
        // Names are lower case; one typed with capitals still finds it.
        guard let handle = DirectoryProfile.validHandle(part), handle == part.lowercased() else { return nil }
        return .name(handle, keyCheck: keyCheck)
    }
}

extension GroupLinkCode {
    /// From the code alone, as it follows `+` in a web link.
    init?(text: String) {
        self.init("group/" + text)
    }
}

/// A group's or channel's public name, as the directory lists it. The relay keeps it like any handle and never looks
/// inside. It is signed by a key made for that name alone (`nameKey`), so it isn't counted against anyone's three
/// handles and says nothing about whose it is beyond what its link already says; `anchor` vouches for that key:
/// - a group's owner, under the key used in that group only. The join link's check names the same key, so a name can
///   only ever point to a link of the group whose owner made it.
/// - a channel's admin, under their account key, which the channel's code is signed with too.
/// It has no `name` or `sendID`, so apps from before public names don't take it for a person's profile, and the relay
/// doesn't take it for a mailbox.
/// It also carries what the web page for the name shows (`Shown`): the title, description, picture and, for a group, how
/// many are in it. All of it is public, as the name is; the relay reads only these to draw the page.
struct PublicNameCard: Codable, Equatable {
    enum Kind: String, Codable { case group, channel }
    var kind: Kind
    var handle: String
    /// What the name opens: a `GroupLinkCode.text`, or a channel's invite code.
    var code: String
    var anchor: Data
    var nameKey: Data
    /// `anchor`'s signature over `"pulshade.name.v1" | kind | 0 | handle | 0 | nameKey`.
    var endorsement: Data
    var title: String?
    var about: String?
    /// A small JPEG (or a picture already small), at most `maxPicture` bytes.
    var picture: Data?
    /// A group's size. Channels don't say how many follow them.
    var members: Int?

    static let maxTitle = 100, maxAbout = 500, maxPicture = 64 * 1024

    /// What the name's web page shows.
    struct Shown: Equatable {
        var title: String?
        var about: String?
        var picture: Data?
        var members: Int?

        /// Cut to what a card may carry.
        var trimmed: Shown {
            Shown(title: title.map { String($0.prefix(PublicNameCard.maxTitle)) }, about: about.map { String($0.prefix(PublicNameCard.maxAbout)) },
                  picture: picture.flatMap { $0.count <= PublicNameCard.maxPicture ? $0 : nil }, members: members.map { max(0, $0) })
        }

        /// Changes when anything shown does, to tell when the name needs listing again.
        var digest: Data {
            var d = Data((title ?? "").utf8) + Data([0]) + Data((about ?? "").utf8) + Data([0])
            d += picture ?? Data()
            withUnsafeBytes(of: Int64(members ?? -1).bigEndian) { d.append(contentsOf: $0) }
            return Data(SHA256.hash(data: d))
        }
    }

    static func endorsed(_ kind: Kind, handle: String, nameKey: Data) -> Data {
        Data("pulshade.name.v1".utf8) + Data(kind.rawValue.utf8) + Data([0]) + Data(handle.utf8) + Data([0]) + nameKey
    }

    /// The key a name is signed with, made from the anchor's key and the conversation, so it's the same on every
    /// device of the account and after a restore, and nothing has to be kept.
    static func nameKey(anchor: Curve25519.Signing.PrivateKey, kind: Kind, conversation: UUID) -> Curve25519.Signing.PrivateKey {
        var info = Data(kind.rawValue.utf8)
        withUnsafeBytes(of: conversation.uuid) { info.append(contentsOf: $0) }
        let raw = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: anchor.rawRepresentation),
                                         salt: Data("pulshade.name.key.v1".utf8), info: info, outputByteCount: 32)
        return try! .init(rawRepresentation: raw.withUnsafeBytes { Data($0) })
    }

    static func make(_ kind: Kind, handle: String, code: String, anchor: Curve25519.Signing.PrivateKey,
                     conversation: UUID, shown: Shown = Shown()) throws -> (PublicNameCard, Curve25519.Signing.PrivateKey) {
        let key = nameKey(anchor: anchor, kind: kind, conversation: conversation)
        let nameKey = key.publicKey.rawRepresentation
        let endorsement = try anchor.signature(for: endorsed(kind, handle: handle, nameKey: nameKey))
        let shown = shown.trimmed
        return (PublicNameCard(kind: kind, handle: handle, code: code, anchor: anchor.publicKey.rawRepresentation,
                               nameKey: nameKey, endorsement: endorsement, title: shown.title, about: shown.about,
                               picture: shown.picture, members: kind == .group ? shown.members : nil), key)
    }

    /// The directory entry for this name, signed with its own key.
    func entry(signedWith key: Curve25519.Signing.PrivateKey, updated: UInt64) throws -> RelayClient.DirectoryEntry {
        let blob = try JSONEncoder.pulshade.encode(self)
        let sig = try key.signature(for: Self.listed(handle, updated, blob))
        return .init(key: nameKey.base64EncodedString(), blob: blob.base64EncodedString(), sig: sig.base64EncodedString(), updated: updated)
    }

    static func listed(_ handle: String, _ updated: UInt64, _ blob: Data) -> Data {
        Data("pulshade.dir.v1".utf8) + Data(handle.utf8) + withUnsafeBytes(of: updated.bigEndian) { Data($0) } + blob
    }

    /// The card in a directory entry, if it's a public name for this handle, signed by its name key, vouched for by its
    /// anchor, and pointing only at a link of that anchor's own group or channel.
    static func verified(_ entry: RelayClient.DirectoryEntry, handle: String) -> PublicNameCard? {
        guard let blob = Data(base64Encoded: entry.blob), let sig = Data(base64Encoded: entry.sig),
              let card = try? JSONDecoder.pulshade.decode(PublicNameCard.self, from: blob),
              card.handle == handle, Data(base64Encoded: entry.key) == card.nameKey,
              let nameKey = try? Curve25519.Signing.PublicKey(rawRepresentation: card.nameKey),
              nameKey.isValidSignature(sig, for: listed(handle, entry.updated, blob)),
              let anchor = try? Curve25519.Signing.PublicKey(rawRepresentation: card.anchor),
              anchor.isValidSignature(card.endorsement, for: endorsed(card.kind, handle: handle, nameKey: card.nameKey)),
              (card.title?.count ?? 0) <= maxTitle, (card.about?.count ?? 0) <= maxAbout, (card.picture?.count ?? 0) <= maxPicture
        else { return nil }
        switch card.kind {
        case .group:
            guard let code = GroupLinkCode(text: card.code), code.check == joinCheck(card.anchor) else { return nil }
        case .channel:
            guard let invite = Invite(code: card.code), invite.kind == .channel, invite.signingKey == card.anchor else { return nil }
        }
        return card
    }
}

/// A public name this device claimed for one of its groups or channels.
struct PublicName: Codable, Equatable {
    var conversation: UUID
    var handle: String
    /// For a group: the join link the name opens, made for it.
    var link: UUID?
    /// The private half of the name's key, so it can still be let go of once the conversation, or the account's say in
    /// it, is gone. Kept like everything else this device saves.
    var key: Data?
    /// `Shown.digest` of what the name last listed, so it's listed again when the group's title or picture changes.
    var shown: Data?
}

/// A name waiting for the relay to let go of it.
struct NameRelease: Codable, Equatable {
    var handle: String
    var key: Data
}
