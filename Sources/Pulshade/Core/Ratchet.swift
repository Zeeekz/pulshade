import Foundation
import CryptoKit

enum RatchetError: Error { case notReady, tooManySkipped, decryptFailed, malformed, peerTooOld }

struct RatchetHeader: Codable, Equatable {
    /// The one form of header this build speaks (`v`). A message in any other form comes from a build from before the
    /// sparse post-quantum ratchet, which this build refuses (`RatchetError.peerTooOld`).
    static let version: UInt8 = 3

    /// The sender's current ratchet public key.
    var dh: Data
    /// Messages sent in the sender's previous chain.
    var pn: UInt32
    /// Position in the current chain.
    var n: UInt32
    /// `RatchetHeader.version`. Nil on a message from a build before it (and on the filler that wakes a phone).
    var v: UInt8? = nil
    /// One chunk of the sparse post-quantum ratchet, in every message and always the same size (see `Ratchet`).
    var pq: Data? = nil
    /// "I hold the secret of my own offer of this epoch": the other side may mix it into its next new chain.
    var pd: UInt32? = nil
    /// "This chain's root has the secret of your offer of this epoch mixed in."
    var pm: UInt32? = nil

    /// What goes into the message's AEAD: the position fields, the version and everything post-quantum, so a changed
    /// chunk or flag fails right here rather than being mixed into the session.
    var authenticated: Data {
        var out = Data("pulshade.ratchet.bound.v3".utf8)
        out.append(dh)
        out.append(n32(pn))
        out.append(n32(n))
        out.append(v ?? 0)
        out.append(contentsOf: SHA256.hash(data: pq ?? Data()))
        out.append(pd == nil ? 0 : 1)
        out.append(n32(pd ?? 0))
        out.append(pm == nil ? 0 : 1)
        out.append(n32(pm ?? 0))
        return out
    }
}

struct RatchetMessage: Codable, Equatable {
    var header: RatchetHeader
    var ciphertext: Data
}

/// The Double Ratchet, as specified by Signal (signal.org/docs/specifications/doubleratchet), with a sparse
/// post-quantum ratchet running alongside it.
///
/// Every message gets its own key, derived from a chain that only moves forward, and every
/// reply mixes in a fresh X25519 exchange. Used keys are thrown away, so stealing the current
/// state doesn't open earlier messages, and the next fresh exchange locks a thief back out.
///
/// Sparse post-quantum ratchet: each side keeps making fresh ML-KEM-768 keys and offering them, in pieces. An
/// ML-KEM key (1,184 bytes) or ciphertext (1,088) is far too big for the 2 KiB envelope next to a short message,
/// so it is cut into chunks of 96 bytes and erasure coded (`ChunkCode`): every message carries exactly one chunk,
/// in a field that is always there and always the same size, and any 13 different chunks of a key (12 of a
/// ciphertext) rebuild it, in any order, whichever messages were lost. Nothing about a message's size says
/// whether a post-quantum exchange is going on.
///
/// Two exchanges run at once, one offered by each side. For one of them: the offerer's messages carry chunks of its
/// key; the other side rebuilds it, encapsulates, and its messages carry chunks of the ciphertext; the offerer
/// rebuilds that and decapsulates, and says so in `pd` on every message from then on. Only once the other side has
/// seen that does it mix the secret into the root key of its next new chain, and say so in `pm` on every message of
/// that chain; the offerer, seeing `pm`, mixes the same secret in on its side of the same step. Then both start the
/// next epoch. A secret is never used before the other side holds it, so no message waits on a chunk, and nothing
/// in this needs more than the existing chain keys: a lost or late message is handled exactly as before.
///
/// A thief who later breaks X25519 with a quantum computer is locked out again at the next completed epoch (about
/// 25 messages each way), not once every fifty messages or a day, and not only before the handshake.
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

    /// The post-quantum ratchet's state. Nil in a session saved before it, which starts it on its next message.
    private var pq: PQState?
    /// The epoch of the other side's offer that went into the root of our current sending chain, said in every
    /// message of it.
    private var sendMix: UInt32?
    /// When a post-quantum secret last went into the root.
    private var pqAt: Date?

    private struct Skipped: Codable {
        var dh: Data
        var n: UInt32
        var key: Data
    }

    private struct Part: Codable {
        var n: UInt8
        var bytes: Data
    }

    /// One side's two exchanges. "Offer": we make the key and the other side answers. "Take": they make it and we answer.
    private struct PQState: Codable {
        var offerEpoch: UInt32 = 1
        var offerSeed: Data?
        var offerNext: UInt32 = 0
        var offerParts: [Part] = []
        /// What we decapsulated, with what it came from, waiting for the other side to mix it in.
        var offerSecret: Data?
        var offerTranscript: Data?

        var takeEpoch: UInt32 = 1
        var takeParts: [Part] = []
        /// Our ciphertext, with its digest, while it is being sent.
        var takeBlob: Data?
        var takeNext: UInt32 = 0
        var takeSecret: Data?
        var takeTranscript: Data?
        /// The other side said it holds this epoch's secret, so it can go into our next new chain.
        var takeAcked = false
        /// Which exchange's chunk goes next, when both have something to say.
        var turn = false
    }

    static let maxSkip: UInt32 = 1000
    private static let maxStoredSkipped = 2000
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

    /// Completed post-quantum epochs, for tests: ours offered and mixed in, theirs answered and mixed in.
    var postQuantumEpochs: (offered: UInt32, answered: UInt32) {
        let q = pq ?? PQState()
        return (q.offerEpoch - 1, q.takeEpoch - 1)
    }

    mutating func encrypt(_ plaintext: Data) throws -> RatchetMessage {
        guard let ck = cks else { throw RatchetError.notReady }
        var q = pq ?? PQState()
        let chunk = try Self.nextChunk(&q)
        let (next, mk) = Self.kdfChain(ck)
        let header = RatchetHeader(dh: try Self.publicKey(dhs), pn: pn, n: ns, v: RatchetHeader.version, pq: chunk,
                                   pd: q.offerSecret == nil ? nil : q.offerEpoch, pm: sendMix)
        let sealed = try Self.seal(plaintext, key: mk, ad: ad + header.authenticated)
        cks = next
        pq = q
        ns += 1
        return RatchetMessage(header: header, ciphertext: sealed)
    }

    /// Works on a copy, so a forged or garbled message never damages the real state.
    mutating func decrypt(_ message: RatchetMessage) throws -> Data {
        guard message.header.dh.count == 32 else { throw RatchetError.malformed }
        guard message.header.v == RatchetHeader.version else { throw RatchetError.peerTooOld }
        var s = self
        if let plain = try s.openSkipped(message) {
            s.absorbAck(message.header)
            s.absorbChunk(message.header)
            self = s
            return plain
        }
        // The other side's word that it holds a secret counts before the step below, which may mix ours in.
        s.absorbAck(message.header)
        if message.header.dh != s.dhr {
            try s.skip(until: message.header.pn)
            try s.step(message.header)
        }
        try s.skip(until: message.header.n)
        guard let ck = s.ckr else { throw RatchetError.decryptFailed }
        let (next, mk) = Self.kdfChain(ck)
        s.ckr = next
        s.nr += 1
        let plain = try Self.open(message.ciphertext, key: mk, ad: ad + message.header.authenticated)
        // Only a message that opened is believed about its chunk.
        s.absorbChunk(message.header)
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
    /// Either can carry a post-quantum secret: theirs if they mixed in our offer, ours if we mix in theirs.
    private mutating func step(_ header: RatchetHeader) throws {
        let theirs = header.dh
        var q = pq ?? PQState()
        pn = ns
        ns = 0
        nr = 0
        dhr = theirs
        let ours = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhs)
        var receiving = try Self.dh(ours, theirs)
        if let epoch = header.pm {
            // They mixed in our offer. Without the secret it names, nothing in this chain can open.
            guard epoch == q.offerEpoch, let secret = q.offerSecret, let transcript = q.offerTranscript else {
                throw RatchetError.decryptFailed
            }
            receiving += Self.pqInput(secret, transcript: transcript, epoch: epoch)
            q.offerEpoch += 1
            q.offerSeed = nil
            q.offerNext = 0
            q.offerParts = []
            q.offerSecret = nil
            q.offerTranscript = nil
            pqAt = Self.now()
        }
        (rk, ckr) = Self.kdfRoot(rk, receiving)

        let fresh = Curve25519.KeyAgreement.PrivateKey()
        dhs = fresh.rawRepresentation
        var sending = try Self.dh(fresh, theirs)
        sendMix = nil
        if q.takeAcked, let secret = q.takeSecret, let transcript = q.takeTranscript {
            sending += Self.pqInput(secret, transcript: transcript, epoch: q.takeEpoch)
            sendMix = q.takeEpoch
            q.takeEpoch += 1
            q.takeParts = []
            q.takeBlob = nil
            q.takeNext = 0
            q.takeSecret = nil
            q.takeTranscript = nil
            q.takeAcked = false
            pqAt = Self.now()
        }
        pq = q
        (rk, cks) = Self.kdfRoot(rk, sending)
    }

    // MARK: Sparse post-quantum exchange

    /// Chunk on the wire: kind (0 a piece of an offered key, 1 a piece of an answer, 2 filler), epoch, chunk number, bytes.
    private static let chunkLength = 1 + 4 + 1 + ChunkCode.size

    private static func pack(kind: UInt8, epoch: UInt32, number: Int, bytes: Data) -> Data {
        Data([kind]) + n32(epoch) + Data([UInt8(number)]) + bytes
    }

    /// The chunk this message carries. Always one, so the size never says anything.
    private static func nextChunk(_ q: inout PQState) throws -> Data {
        let offering = q.offerSecret == nil
        let answering = q.takeBlob != nil
        if offering && (!answering || q.turn) {
            q.turn = false
            if q.offerSeed == nil { q.offerSeed = try MLKEM768.PrivateKey().seedRepresentation }
            let key = try MLKEM768.PrivateKey(seedRepresentation: q.offerSeed!, publicKey: nil).publicKey.rawRepresentation
            let number = Int(q.offerNext % UInt32(ChunkCode.numbers))
            q.offerNext += 1
            return pack(kind: 0, epoch: q.offerEpoch, number: number, bytes: ChunkCode.chunk(key + digest(key), number: number))
        }
        if let blob = q.takeBlob {
            q.turn = true
            let number = Int(q.takeNext % UInt32(ChunkCode.numbers))
            q.takeNext += 1
            return pack(kind: 1, epoch: q.takeEpoch, number: number, bytes: ChunkCode.chunk(blob, number: number))
        }
        return pack(kind: 2, epoch: 0, number: 0, bytes: .random(ChunkCode.size))
    }

    /// "They hold this epoch's secret" lets ours go into the next new chain.
    private mutating func absorbAck(_ header: RatchetHeader) {
        guard var q = pq, let epoch = header.pd, epoch == q.takeEpoch, q.takeSecret != nil, !q.takeAcked else { return }
        q.takeAcked = true
        pq = q
    }

    /// Collects the chunk a message carried. A chunk that is for another epoch, or is not what it should be, is just ignored.
    private mutating func absorbChunk(_ header: RatchetHeader) {
        guard let raw = header.pq, raw.count == Self.chunkLength else { return }
        let bytes = Data(raw)
        let kind = bytes[bytes.startIndex]
        let epoch = bytes[(bytes.startIndex + 1)..<(bytes.startIndex + 5)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let number = bytes[bytes.startIndex + 5]
        let body = Data(bytes.suffix(ChunkCode.size))
        guard Int(number) < ChunkCode.numbers else { return }
        var q = pq ?? PQState()
        switch kind {
        case 0:
            // A piece of their key, for us to answer.
            guard epoch == q.takeEpoch, q.takeSecret == nil else { return }
            if !q.takeParts.contains(where: { $0.n == number }) { q.takeParts.append(Part(n: number, bytes: body)) }
            if q.takeParts.count >= ChunkCode.blocks(for: Self.offerLength) {
                let parts = Dictionary(uniqueKeysWithValues: q.takeParts.map { (Int($0.n), $0.bytes) })
                guard let whole = ChunkCode.decode(parts, length: Self.offerLength),
                      Self.digest(whole.prefix(Self.keyLength)) == whole.suffix(32),
                      let key = try? MLKEM768.PublicKey(rawRepresentation: whole.prefix(Self.keyLength)),
                      let sealed = try? key.encapsulate() else {
                    // Pieces that don't fit together: start collecting again.
                    q.takeParts = []
                    pq = q
                    return
                }
                let ciphertext = sealed.encapsulated
                q.takeSecret = sealed.sharedSecret.withUnsafeBytes { Data($0) }
                q.takeTranscript = Data(SHA256.hash(data: whole.prefix(Self.keyLength) + ciphertext))
                q.takeBlob = ciphertext + Self.digest(ciphertext)
                q.takeParts = []
                q.takeNext = 0
            }
        case 1:
            // A piece of their answer to our key.
            guard epoch == q.offerEpoch, q.offerSecret == nil, let seed = q.offerSeed else { return }
            if !q.offerParts.contains(where: { $0.n == number }) { q.offerParts.append(Part(n: number, bytes: body)) }
            if q.offerParts.count >= ChunkCode.blocks(for: Self.answerLength) {
                let parts = Dictionary(uniqueKeysWithValues: q.offerParts.map { (Int($0.n), $0.bytes) })
                guard let whole = ChunkCode.decode(parts, length: Self.answerLength),
                      Self.digest(whole.prefix(Self.ciphertextLength)) == whole.suffix(32),
                      let kem = try? MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil),
                      let secret = try? kem.decapsulate(whole.prefix(Self.ciphertextLength)) else {
                    q.offerParts = []
                    pq = q
                    return
                }
                q.offerSecret = secret.withUnsafeBytes { Data($0) }
                q.offerTranscript = Data(SHA256.hash(data: kem.publicKey.rawRepresentation + whole.prefix(Self.ciphertextLength)))
                q.offerParts = []
            }
        default:
            return
        }
        pq = q
    }

    /// An ML-KEM-768 public key and its digest; a ciphertext and its digest.
    private static let keyLength = 1184
    private static let ciphertextLength = 1088
    private static let offerLength = keyLength + 32
    private static let answerLength = ciphertextLength + 32

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: Data("pulshade.pqr.digest".utf8) + data))
    }

    /// The shared secret, bound to the exact key and ciphertext it came from and to the epoch.
    private static func pqInput(_ secret: Data, transcript: Data, epoch: UInt32) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: transcript,
                               info: Data("pulshade.pqr.mix".utf8) + n32(epoch), outputByteCount: 32).bytes
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
