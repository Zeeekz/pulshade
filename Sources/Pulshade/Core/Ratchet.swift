import Foundation
import CryptoKit

enum RatchetError: Error { case notReady, tooManySkipped, decryptFailed, malformed }

struct RatchetHeader: Codable, Equatable {
    /// The sender's current ratchet public key.
    var dh: Data
    /// Messages sent in the sender's previous chain.
    var pn: UInt32
    /// Position in the current chain.
    var n: UInt32
    /// The sender's waiting ML-KEM-768 key, offered on every message until the other side answers it.
    var kem: Data? = nil
    /// An ML-KEM ciphertext answering the other side's offered key. Carried on every message of the chain
    /// whose root it was mixed into.
    var kemCiphertext: Data? = nil

    /// What this message's sender understands. Nil: a build from before the binding. 1: it reads messages whose
    /// ML-KEM fields are authenticated, and this one is still sealed the old way, because the other side may not.
    /// 2: this message is sealed with the ML-KEM fields (and this number) authenticated.
    var v: UInt8? = nil

    /// The old form: the ML-KEM fields stay out of this, so builds from before them still read every message.
    /// An answer is still bound through the root key, so a changed one leaves nothing that opens.
    var bytes: Data { dh + n32(pn) + n32(n) }

    /// The form for `v == 2`: everything above, plus the version and both ML-KEM fields, so a changed offer or
    /// answer fails right here rather than being mixed into the session.
    var boundBytes: Data {
        Data("pulshade.ratchet.bound".utf8) + bytes + Data([v ?? 0])
            + Data(SHA256.hash(data: kem ?? Data())) + Data(SHA256.hash(data: kemCiphertext ?? Data()))
    }

    /// What goes into the message's AEAD, for the form it says it is in.
    var authenticated: Data { (v ?? 0) >= 2 ? boundBytes : bytes }
}

struct RatchetMessage: Codable, Equatable {
    var header: RatchetHeader
    var ciphertext: Data
}

/// The Double Ratchet, as specified by Signal (signal.org/docs/specifications/doubleratchet).
///
/// Every message gets its own key, derived from a chain that only moves forward, and every
/// reply mixes in a fresh X25519 exchange. Used keys are thrown away, so stealing the current
/// state doesn't open earlier messages, and the next fresh exchange locks a thief back out.
///
/// Post-quantum refresh: after 50 messages or a day since the last post-quantum secret, a side offers
/// a fresh ML-KEM-768 key on its messages. The other side's next new chain answers it with a ciphertext,
/// and the shared secret goes into the root key on both sides, alongside that step's X25519. So a thief
/// who later breaks X25519 with a quantum computer is locked out again at the next refresh, not only
/// before the handshake. A build from before this never offers or answers, and simply keeps talking.
/// (Like Apple's PQ3 rather than Signal's triple ratchet, which spreads the keys across many messages.)
struct Ratchet: Codable {
    private var dhs: Data
    private var dhr: Data?
    private var rk: Data
    private var cks: Data?
    private var ckr: Data?
    private var ns: UInt32 = 0
    private var nr: UInt32 = 0
    private var pn: UInt32 = 0
    private var skipped: [Skipped] = []
    /// Bound into every message so it can't be replayed into another pair's session.
    private let ad: Data

    // Post-quantum refresh. All optional, so sessions saved before it load and refresh straight away.
    /// Our offered ML-KEM key, kept until it's answered.
    private var kemSeed: Data?
    private var kemPublic: Data?
    /// The other side's offered key, answered on our next new chain.
    private var kemTheirs: Data?
    /// The last key of theirs we answered, so the same offer on later messages isn't answered twice.
    private var kemAnswered: Data?
    /// Our answer, carried on every message of the current sending chain.
    private var kemCiphertextOut: Data?
    /// When a post-quantum secret last went into the root, and messages since.
    private var pqAt: Date?
    private var pqMessages: UInt32?
    /// Whether the other side's latest message said it reads authenticated ML-KEM fields (`RatchetHeader.v`).
    /// Until it has, everything is sealed the old way; after it, the new way. Sessions saved before this load
    /// as nil and start the old way.
    private var peerBinds: Bool?

    private struct Skipped: Codable {
        var dh: Data
        var n: UInt32
        var key: Data
    }

    static let maxSkip: UInt32 = 1000
    private static let maxStoredSkipped = 2000
    static let pqRefreshMessages: UInt32 = 50
    static let pqRefreshInterval: TimeInterval = 24 * 3600
    /// Tests move the clock.
    nonisolated(unsafe) static var now: () -> Date = Date.init

    private init(dhs: Data, dhr: Data?, rk: Data, cks: Data?, ad: Data) {
        self.dhs = dhs
        self.dhr = dhr
        self.rk = rk
        self.cks = cks
        self.ad = ad
        // The handshake itself was post-quantum.
        pqAt = Self.now()
        pqMessages = 0
    }

    /// The side that already knows the other's ratchet key, and so can send first.
    static func sender(root: SymmetricKey, theirRatchet: Data, ad: Data) throws -> Ratchet {
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let (rk, cks) = kdfRoot(root.bytes, try dh(mine, theirRatchet))
        return Ratchet(dhs: mine.rawRepresentation, dhr: theirRatchet, rk: rk, cks: cks, ad: ad)
    }

    /// The side whose ratchet key the other already has. It can send once the first message arrives.
    static func receiver(root: SymmetricKey, ourRatchet: Curve25519.KeyAgreement.PrivateKey, ad: Data) -> Ratchet {
        Ratchet(dhs: ourRatchet.rawRepresentation, dhr: nil, rk: root.bytes, cks: nil, ad: ad)
    }

    var canSend: Bool { cks != nil }

    /// When a post-quantum secret last went into this session's root.
    var postQuantumAt: Date? { pqAt }

    private var pqDue: Bool {
        guard let pqAt else { return true }
        return (pqMessages ?? 0) >= Self.pqRefreshMessages || Self.now().timeIntervalSince(pqAt) >= Self.pqRefreshInterval
    }

    mutating func encrypt(_ plaintext: Data) throws -> RatchetMessage {
        guard let ck = cks else { throw RatchetError.notReady }
        if kemSeed == nil, pqDue {
            let kem = try MLKEM768.PrivateKey()
            kemSeed = kem.seedRepresentation
            kemPublic = kem.publicKey.rawRepresentation
        }
        let (next, mk) = Self.kdfChain(ck)
        cks = next
        let header = RatchetHeader(dh: try Self.publicKey(dhs), pn: pn, n: ns, kem: kemPublic, kemCiphertext: kemCiphertextOut,
                                   v: peerBinds == true ? 2 : 1)
        ns += 1
        pqMessages = (pqMessages ?? 0) + 1
        return RatchetMessage(header: header, ciphertext: try Self.seal(plaintext, key: mk, ad: ad + header.authenticated))
    }

    /// Works on a copy, so a forged or garbled message never damages the real state.
    mutating func decrypt(_ message: RatchetMessage) throws -> Data {
        guard message.header.dh.count == 32 else { throw RatchetError.malformed }
        var s = self
        if let plain = try s.openSkipped(message) {
            self = s
            return plain
        }
        // Only offers on the newest chain count: an offer on an older, late message may already be answered.
        if let offer = message.header.kem, (try? MLKEM768.PublicKey(rawRepresentation: offer)) != nil,
           offer != s.kemAnswered, offer != s.kemTheirs {
            s.kemTheirs = offer
        }
        if message.header.dh != s.dhr {
            try s.skip(until: message.header.pn)
            try s.step(message.header)
        }
        try s.skip(until: message.header.n)
        guard let ck = s.ckr else { throw RatchetError.decryptFailed }
        let (next, mk) = Self.kdfChain(ck)
        s.ckr = next
        s.nr += 1
        s.pqMessages = (s.pqMessages ?? 0) + 1
        let plain = try Self.open(message.ciphertext, key: mk, ad: ad + message.header.authenticated)
        // Only a message that opened counts, and only the newest chain's: a late one from before the other side
        // updated says nothing about it now.
        s.peerBinds = (message.header.v ?? 0) >= 1
        self = s
        return plain
    }

    // MARK: Steps

    private mutating func openSkipped(_ message: RatchetMessage) throws -> Data? {
        guard let i = skipped.firstIndex(where: { $0.dh == message.header.dh && $0.n == message.header.n }) else { return nil }
        let key = skipped.remove(at: i).key
        return try Self.open(message.ciphertext, key: key, ad: ad + message.header.authenticated)
    }

    /// Keeps keys for messages that haven't arrived yet, so they can still be read out of order.
    private mutating func skip(until n: UInt32) throws {
        guard let start = ckr else { return }
        guard n <= nr + Self.maxSkip else { throw RatchetError.tooManySkipped }
        var ck = start
        while nr < n {
            let (next, mk) = Self.kdfChain(ck)
            skipped.append(Skipped(dh: dhr ?? Data(), n: nr, key: mk))
            ck = next
            nr += 1
        }
        ckr = ck
        if skipped.count > Self.maxStoredSkipped { skipped.removeFirst(skipped.count - Self.maxStoredSkipped) }
    }

    /// A new ratchet key from the other side: derive a fresh receiving chain, then a fresh sending one.
    /// Either can carry a post-quantum secret: theirs if they answered our offer, ours if we answer theirs.
    private mutating func step(_ header: RatchetHeader) throws {
        let theirs = header.dh
        pn = ns
        ns = 0
        nr = 0
        dhr = theirs
        let ours = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhs)
        var receiving = try Self.dh(ours, theirs)
        if let ciphertext = header.kemCiphertext {
            // An answer to our offer. Without the key it answers, nothing in this chain can open.
            guard let seed = kemSeed, let offered = kemPublic else { throw RatchetError.decryptFailed }
            let kem = try MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil)
            let secret = try kem.decapsulate(ciphertext).withUnsafeBytes { Data($0) }
            receiving += Self.pqInput(secret, offered: offered, ciphertext: ciphertext)
            kemSeed = nil
            kemPublic = nil
            pqRefreshed()
        }
        (rk, ckr) = Self.kdfRoot(rk, receiving)

        let fresh = Curve25519.KeyAgreement.PrivateKey()
        dhs = fresh.rawRepresentation
        var sending = try Self.dh(fresh, theirs)
        kemCiphertextOut = nil
        if let offer = kemTheirs {
            let encapsulation = try MLKEM768.PublicKey(rawRepresentation: offer).encapsulate()
            let secret = encapsulation.sharedSecret.withUnsafeBytes { Data($0) }
            sending += Self.pqInput(secret, offered: offer, ciphertext: encapsulation.encapsulated)
            kemCiphertextOut = encapsulation.encapsulated
            kemAnswered = offer
            kemTheirs = nil
            pqRefreshed()
        }
        (rk, cks) = Self.kdfRoot(rk, sending)
    }

    private mutating func pqRefreshed() {
        pqAt = Self.now()
        pqMessages = 0
    }

    /// The shared secret, bound to the exact key and ciphertext it came from.
    private static func pqInput(_ secret: Data, offered: Data, ciphertext: Data) -> Data {
        secret + Data(SHA256.hash(data: offered + ciphertext))
    }

    // MARK: Primitives

    private static let rootInfo = Data("pulshade.ratchet.root".utf8)
    private static let messageInfo = Data("pulshade.ratchet.message".utf8)

    private static func dh(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Data) throws -> Data {
        let secret = try mine.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs))
        return secret.withUnsafeBytes { Data($0) }
    }

    private static func publicKey(_ raw: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw).publicKey.rawRepresentation
    }

    private static func kdfRoot(_ rk: Data, _ dhOut: Data) -> (Data, Data) {
        let out = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: dhOut), salt: rk,
                                         info: rootInfo, outputByteCount: 64).bytes
        return (out.prefix(32), out.suffix(32))
    }

    private static func kdfChain(_ ck: Data) -> (next: Data, message: Data) {
        let key = SymmetricKey(data: ck)
        let mk = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: key))
        let next = Data(HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: key))
        return (next, mk)
    }

    /// Message key → cipher key and nonce. Each message key is used exactly once.
    private static func cipher(_ mk: Data) -> (SymmetricKey, ChaChaPoly.Nonce) {
        let out = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: mk), salt: Data(count: 32),
                                         info: messageInfo, outputByteCount: 44).bytes
        return (SymmetricKey(data: out.prefix(32)), try! ChaChaPoly.Nonce(data: out.suffix(12)))
    }

    private static func seal(_ plain: Data, key mk: Data, ad: Data) throws -> Data {
        let (key, nonce) = cipher(mk)
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce, authenticating: ad)
        return Data(box.ciphertext) + box.tag
    }

    private static func open(_ data: Data, key mk: Data, ad: Data) throws -> Data {
        guard data.count >= 16 else { throw RatchetError.malformed }
        let (key, nonce) = cipher(mk)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16))
        do { return try ChaChaPoly.open(box, using: key, authenticating: ad) } catch { throw RatchetError.decryptFailed }
    }
}

private func n32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

extension SymmetricKey {
    var bytes: Data { withUnsafeBytes { Data($0) } }
}
