import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

/// A Pulshade identity is nothing more than 32 random bytes kept on this device.
/// No phone number, no email, no username: every key is derived from the seed.
struct Identity {
    let seed: Data
    let signingKey: Curve25519.Signing.PrivateKey
    let agreementKey: Curve25519.KeyAgreement.PrivateKey
    /// Encrypts the local database. Never leaves the device.
    let storageKey: SymmetricKey

    static func generate() -> Identity {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        precondition(status == errSecSuccess, "System random generator failed")
        return try! Identity(seed: bytes)
    }

    init(seed: Data) throws {
        guard seed.count == 32 else { throw VaultError.corrupt }
        self.seed = seed
        let root = SymmetricKey(data: seed)
        signingKey = try .init(rawRepresentation: Self.derive(root, "pulshade.signing"))
        agreementKey = try .init(rawRepresentation: Self.derive(root, "pulshade.agreement"))
        storageKey = SymmetricKey(data: Self.derive(root, "pulshade.storage"))
    }

    /// Signs for the account's sealed backup on the relay. Tied to nothing else, so the backup can't be linked to you.
    var backupSigningKey: Curve25519.Signing.PrivateKey {
        try! .init(rawRepresentation: Self.derive(SymmetricKey(data: seed), "pulshade.backup.signing"))
    }

    /// Seals the backup left on the relay at log out. Only the recovery code can make it.
    var backupKey: SymmetricKey { SymmetricKey(data: Self.derive(SymmetricKey(data: seed), "pulshade.backup.sealing")) }

    /// The mailbox behind a public @handle, worked out from the seed: every copy of the account (linked, recovered or
    /// reinstalled) reads the same one, so none can list a mailbox the others never see. Each handle has its own, so
    /// two handles can't be tied together by it.
    func publicInboxKey(handle: String) -> Data {
        Self.derive(SymmetricKey(data: seed), "pulshade.public-inbox.v1|\(handle.lowercased())")
    }

    /// The post-quantum keys (ML-KEM-768 for envelopes, ML-DSA-65 for signatures), worked out from the seed like every other
    /// key here: the same account on every device and after every recovery, with nothing extra to store, back up or wipe.
    var pq: PQKeys {
        let root = SymmetricKey(data: seed)
        let kemSeed = HKDF<SHA256>.deriveKey(inputKeyMaterial: root, info: Data("pulshade.pq.envelope.kem.v1".utf8), outputByteCount: 64)
        return try! PQKeys(kemSeed: kemSeed.withUnsafeBytes { Data($0) }, sigSeed: Self.derive(root, "pulshade.pq.signing.v1"))
    }

    /// The keys an envelope to this account is sealed to.
    var recipient: EnvelopeRecipient { EnvelopeRecipient(agreement: card.agreement, pq: pq.pin) }

    /// This account's post-quantum keys, signed by both signing keys (see `PQCard`).
    var pqCard: PQCard { try! PQCard.make(signing: signingKey, agreement: card.agreement, keys: pq) }

    private static func derive(_ root: SymmetricKey, _ label: String) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: root, info: Data(label.utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    /// Short hash of the public signing key. Doubles as the safety number and the artwork seed.
    var fingerprint: String { Self.fingerprint(of: signingKey.publicKey.rawRepresentation) }

    static func fingerprint(of signingKey: Data) -> String {
        SHA256.hash(data: signingKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Recovery code

    /// The seed written as 14 groups of 4 characters, ending in a checksum group.
    var recoveryCode: String {
        let body = Base32.encode(seed)
        let check = Base32.encode(Data(SHA256.hash(data: seed).prefix(3))).prefix(4)
        return (body + check).chunked(4).joined(separator: " ")
    }

    static func seed(fromRecoveryCode code: String) -> Data? {
        let clean = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard clean.count == 56 else { return nil }
        guard let seed = Base32.decode(String(clean.prefix(52))), seed.count >= 32 else { return nil }
        let trimmed = seed.prefix(32)
        let check = Base32.encode(Data(SHA256.hash(data: trimmed).prefix(3))).prefix(4)
        return clean.suffix(4) == check ? Data(trimmed) : nil
    }

    var card: (signing: Data, agreement: Data) {
        (signingKey.publicKey.rawRepresentation, agreementKey.publicKey.rawRepresentation)
    }
}

/// An invite carries only public keys and the send id of a brand-new mailbox.
/// Each contact invite works once, so two contacts can't compare invites to link you.
struct Invite: Equatable {
    enum Kind: UInt8 { case contact = 1, channel = 2 }

    let kind: Kind
    let signingKey: Data
    let agreementKey: Data
    /// The signing key's signature over the agreement key and `pqHash` (see `bindMessage`), so neither can be swapped by
    /// someone who only changes a code. Checked when a code is read: a code without a valid one isn't an invite.
    let bind: Data
    /// A commitment to the post-quantum keys of whoever made the invite (`PQPin.commitment`). The first post-quantum card
    /// that comes from them is accepted only if its keys match, so those keys don't rest on trust in whatever arrives first.
    let pqHash: Data
    let sendID: Data
    /// The relay this invite's mailbox lives on. Nil means "use your default relay"; the official app refuses any but its own.
    let relay: String?

    /// "psh3" carries the post-quantum commitment and a signature over it. "psh2" (signed, no commitment) and "psh1" (unsigned),
    /// from apps before it, aren't accepted (see `isOutdated`).
    private static let prefix = "psh3"
    private static let oldPrefixes = ["psh1", "psh2"]

    var code: String {
        let tail = relay.map { Data($0.utf8) } ?? Data()
        return Self.prefix + Base32.encode(Data([kind.rawValue]) + signingKey + agreementKey + bind + pqHash + sendID + tail).lowercased()
    }

    init(kind: Kind, signingKey: Data, agreementKey: Data, bind: Data, pqHash: Data, sendID: Data, relay: String? = nil) {
        self.kind = kind
        self.signingKey = signingKey
        self.agreementKey = agreementKey
        self.bind = bind
        self.pqHash = pqHash
        self.sendID = sendID
        self.relay = relay
    }

    /// What an invite's signing key signs: the agreement key and the post-quantum commitment, under a label of their own so
    /// the signature can't be taken from (or used as) the one envelopes carry.
    static func bindMessage(agreement: Data, pqHash: Data) -> Data {
        Data("pulshade.invite.bind.v2".utf8) + agreement + pqHash
    }

    static func bindIsValid(_ bind: Data, signing: Data, agreement: Data, pqHash: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signing) else { return false }
        return key.isValidSignature(bind, for: bindMessage(agreement: agreement, pqHash: pqHash))
    }

    /// An invite from this account, signed.
    init(kind: Kind, identity: Identity, sendID: Data, relay: String? = nil) throws {
        let card = identity.card
        let pqHash = identity.pq.pin.commitment
        self.init(kind: kind, signingKey: card.signing, agreementKey: card.agreement,
                  bind: try identity.signingKey.signature(for: Self.bindMessage(agreement: card.agreement, pqHash: pqHash)),
                  pqHash: pqHash, sendID: sendID, relay: relay)
    }

    /// A code from an app whose invites don't carry the post-quantum commitment: the person who made it needs to update
    /// and send a new one.
    static func isOutdated(_ code: String) -> Bool {
        let text = scannedPayload(code).lowercased()
        return oldPrefixes.contains { text.hasPrefix($0) }
    }

    static let outdatedNotice = "This invite is from an older version of PULSHADE. Ask them to update the app and send you a new one."

    /// Only http(s) addresses, so an invite can't point the app anywhere strange, and plain http only on this
    /// machine or your own network: anywhere else, someone on the way could read the mailbox keys a fetch carries.
    static func validRelay(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 200,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        // Plain http only where nobody in between can read it: your own network, or an onion service,
        // which Tor encrypts end to end.
        if scheme == "http" && !isLocal(host) && !host.hasSuffix(".onion") { return nil }
        return text
    }

    /// The official app talks to Pulshade's own relays only, the one it was built for. Anyone can build the code
    /// with a relay of their own, but an invite, profile or code naming one isn't used here. Development builds
    /// take any valid relay, for tests and a relay on your own Mac.
    #if DEBUG
    nonisolated(unsafe) static var officialRelaysOnly = false
    #else
    static let officialRelaysOnly = true
    #endif

    /// A relay address this app will use: valid, and in the official app one of Pulshade's own.
    static func allowedRelay(_ text: String?) -> String? {
        guard let relay = validRelay(text) else { return nil }
        return !officialRelaysOnly || isPulshadeRelay(relay) ? relay : nil
    }

    /// The address to connect to: Pulshade's own relay by its onion address over Tor, or by its direct one
    /// with Tor off (when it has one). Any other relay as it is.
    static func route(_ relay: String, overTor: Bool) -> String {
        guard isPulshadeRelay(relay), let direct = AppData.directRelay else { return relay }
        return overTor ? AppData.defaultRelay : direct
    }

    /// The built-in relay, by its onion address or its direct one.
    static func isPulshadeRelay(_ relay: String) -> Bool {
        func plain(_ s: String) -> String {
            var out = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while out.hasSuffix("/") { out.removeLast() }
            return out
        }
        return [AppData.defaultRelay, AppData.directRelay].compactMap { $0 }.map(plain).contains(plain(relay))
    }

    /// This machine, a private network address, or a name that only means something on your network.
    /// Addresses are parsed rather than pattern-matched, so loopback and private space can't be reached
    /// through another spelling (IPv4-mapped IPv6, `127.1`, `0x7f.0.0.1`, a bare integer, and so on).
    static func isLocal(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if bare == "localhost" || bare.hasSuffix(".local") { return true }
        if !bare.contains(".") && !bare.contains(":") { return true }
        // IPv6, including IPv4-mapped addresses such as `::ffff:127.0.0.1`.
        var v6 = in6_addr()
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes.allSatisfy({ $0 == 0 }) { return true }
            if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isLocalIPv4(bytes[12], bytes[13], bytes[14], bytes[15])
            }
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return true }
            if bytes[0] & 0xfe == 0xfc { return true }
            return false
        }
        // IPv4, through `inet_aton` so the legacy forms Apple's resolver accepts are caught too.
        var v4 = in_addr()
        if inet_aton(bare, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            return isLocalIPv4(bytes[0], bytes[1], bytes[2], bytes[3])
        }
        return false
    }

    private static func isLocalIPv4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
        switch (a, b) {
        case (0, _), (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true  // carrier-grade NAT, also used by private overlay networks
        default: return false
        }
    }

    /// As a link, so the phone's own Camera app and other apps open it in Pulshade.
    static func link(_ code: String) -> String { "pulshade://invite/" + code }

    init?(code: String) {
        let clean = scannedPayload(code).lowercased()
        guard clean.hasPrefix(Self.prefix), let raw = Base32.decode(String(clean.dropFirst(4)).uppercased()),
              raw.count >= 177, let kind = Kind(rawValue: raw[raw.startIndex]) else { return nil }
        self.kind = kind
        signingKey = Data(raw.dropFirst(1).prefix(32))
        agreementKey = Data(raw.dropFirst(33).prefix(32))
        bind = Data(raw.dropFirst(65).prefix(64))
        pqHash = Data(raw.dropFirst(129).prefix(PQPin.commitmentSize))
        sendID = Data(raw.dropFirst(145).prefix(32))
        if raw.count > 177 {
            // An invite naming a relay that isn't Pulshade's own can't be used.
            guard let named = Self.allowedRelay(String(data: Data(raw.dropFirst(177)), encoding: .utf8)) else { return nil }
            relay = named
        } else {
            relay = nil
        }
        guard (try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey)) != nil,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementKey)) != nil,
              Self.bindIsValid(bind, signing: signingKey, agreement: agreementKey, pqHash: pqHash) else { return nil }
    }

    var fingerprint: String { Identity.fingerprint(of: signingKey) }
}

// MARK: - Helpers

enum Base32 {
    // Crockford alphabet: no I, L, O or U, so codes are easy to read back.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let lookup: [Character: UInt8] = {
        var map = [Character: UInt8]()
        for (i, c) in alphabet.enumerated() { map[c] = UInt8(i) }
        map["O"] = 0; map["I"] = 1; map["L"] = 1
        return map
    }()

    static func encode(_ data: Data) -> String {
        var out = ""
        var buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    static func decode(_ string: String) -> Data? {
        var out = Data()
        var buffer = 0, bits = 0
        for c in string {
            guard let v = lookup[c] else { return nil }
            buffer = (buffer << 5) | Int(v)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }
}

extension Data {
    static func random(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        // Key material must never silently become a run of zeros.
        precondition(status == errSecSuccess, "System random generator failed")
        return bytes
    }
}

extension String {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map {
            let start = index(startIndex, offsetBy: $0)
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            return String(self[start..<end])
        }
    }
}
