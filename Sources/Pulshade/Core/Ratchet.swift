import Foundation
import CryptoKit

enum RatchetError: Error { case notReady, tooManySkipped, decryptFailed, malformed, peerTooOld }

struct RatchetHeader: Codable, Equatable {
    /// The one form of header this build speaks (`v`). A message in any other form comes from an older build, which this
    /// build refuses (`RatchetError.peerTooOld`).
    static let version: UInt8 = 4

    /// The sender's current ratchet public key.
    var dh: Data
    /// Messages sent in the sender's previous chain.
    var pn: UInt32
    /// Position in the current chain.
    var n: UInt32
    /// `RatchetHeader.version`. Nil on a message from a build before it (and on the filler that wakes a phone).
    var v: UInt8? = nil
    /// Chunks of the sparse post-quantum ratchet, one after another (see `Ratchet`): always at least one, and more only
    /// where the message had room for them inside the padding it would have had anyway.
    var pq: Data? = nil
    /// "This chain's root has the secret of my offer of this epoch mixed in": the receiver answered that offer, so it holds
    /// the secret already.
    var pm: UInt32? = nil

    /// What goes into the message's AEAD: the position fields, the version and everything post-quantum, so a changed
    /// chunk or flag fails right here rather than being mixed into the session.
    var authenticated: Data {
        var out = Data("pulshade.ratchet.bound.v4".utf8)
        out.append(dh)
        out.append(n32(pn))
        out.append(n32(n))
        out.append(v ?? 0)
        out.append(contentsOf: SHA256.hash(data: pq ?? Data()))
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
/// ML-KEM key (1,184 bytes) or ciphertext (1,088) is too big to add to every message, so it is cut into chunks of 96
/// bytes and erasure coded (`ChunkCode`): any 13 different chunks of a key (12 of a ciphertext) rebuild it, in any
/// order, whichever messages were lost, repeated or late. Every message carries at least one chunk, in a field that is
/// always there. Envelopes are padded to fixed sizes anyway, so where a message leaves room in its padding it carries
/// as many more chunks as fit there (a short text, about seven): the envelope is the same size it would have been
/// without them, and nothing about its size says whether a post-quantum exchange is going on.
///
/// Two exchanges run at once, one offered by each side. For one of them: the offerer's messages carry chunks of its
/// key; the other side rebuilds it, encapsulates, keeps the secret, and its messages carry chunks of the ciphertext;
/// the offerer rebuilds that and decapsulates. Now both sides hold the secret, so the offerer mixes it into the root
/// key of its next new sending chain (right away, if it has not sent on its current one yet) and says so in `pm` on
/// every message of that chain; the other side mixes in the same secret when it steps to that chain. No message ever
/// waits on a chunk: the side that needs the secret to read is always the one that made it. A lost, late or repeated
/// message at worst delays the next exchange.
///
/// Any message the other side sends moves the exchange on, delivery receipts and typing notes included, and the secret
/// goes in on the first new chain after it, so a stream that is mostly one way still refreshes. A thief who later
/// breaks X25519 with a quantum computer is locked out again at the next completed exchange: a handful of short
/// messages each way.
struct Ratchet: Codable {
    private var dhs: Data
    private var dhr: Data?
    private var rk: Data
    /// The sending chain. Nil after a step until the first message on it: it is derived then, so a post-quantum secret
    /// that arrived in between can still go into it.
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
    /// The epoch of our offer that went into the root of our current sending chain, said in every message of it.
    private var sendMix: UInt32?
    /// When a post-quantum secret last went into the root.
    private var pqAt: Date?
    /// Messages this side has sent since then, and when it last sent one. Nil in a session saved before they were kept,
    /// which starts counting now.
    private var sentSincePQ: UInt32?
    private var lastSentAt: Date?

    private struct Skipped: Codable {
        var dh: Data
        var n: UInt32
        var key: Data
        /// When the key was kept. Nil for one kept by a build before it was said: the first tidy-up stamps it, so it goes
        /// `skippedLifetime` after that.
        var at: Date?
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
        /// What we decapsulated, with what it came from, waiting for our next new sending chain.
        var offerSecret: Data?
        var offerTranscript: Data?

        var takeEpoch: UInt32 = 1
        var takeParts: [Part] = []
        /// Our ciphertext, with its digest, while it is being sent.
        var takeBlob: Data?
        var takeNext: UInt32 = 0
        /// What we encapsulated, kept until the other side's chain says it went in.
        var takeSecret: Data?
        var takeTranscript: Data?
        /// The digest of the key we answered, so the same key arriving again isn't answered twice and a different one
        /// (the offerer started over) is.
        var takeKey: Data?
        /// Which exchange's chunk goes next, when both have something to say.
        var turn = false
    }

    static let maxSkip: UInt32 = 1000
    private static let maxStoredSkipped = 2000
    /// A key kept for a message that never came is dropped after this long, so a message held back somewhere (by the
    /// relay, say) can't be opened with a device seized long after it was sent.
    static let skippedLifetime: TimeInterval = 30 * 86_400
    /// Keys are kept for the receiving chains of at most this many of the other side's ratchet keys, the newest: a late
    /// message on any older chain can't be read. As libsignal keeps a handful of old receiving chains.
    static let maxSkippedChains = 5
    /// The post-quantum ratchet counts as stalled once this side has sent `pqStallMessages` messages without a new
    /// post-quantum secret going into the root, or `pqStallSoonMessages` of them with the newest sent `pqStallAge` or more
    /// after the last secret went in (see `postQuantumStalled`). In a working chat a secret goes in every few messages
    /// each way, so either means the exchange is stuck; a chat that was only quiet for a while is not.
    static let pqStallMessages: UInt32 = 200
    static let pqStallSoonMessages: UInt32 = 20
    static let pqStallAge: TimeInterval = 7 * 86_400
    /// Tests move the clock.
    #if DEBUG
    /// Tests set this; a shipped build reads the clock directly and holds no mutable global here.
    nonisolated(unsafe) static var now: () -> Date = Date.init
    #else
    static let now: () -> Date = Date.init
    #endif

    private init(dhs: Data, dhr: Data?, rk: Data, cks: Data?, ad: Data) {
        self.dhs = dhs
        self.dhr = dhr
        self.rk = rk
        self.cks = cks
        self.ad = ad
        // The handshake itself was post-quantum.
        pqAt = Self.now()
        sentSincePQ = 0
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

    var canSend: Bool { cks != nil || dhr != nil }

    /// Completed post-quantum epochs, for tests: ours offered and mixed in, theirs answered and mixed in.
    var postQuantumEpochs: (offered: UInt32, answered: UInt32) {
        let q = pq ?? PQState()
        return (q.offerEpoch - 1, q.takeEpoch - 1)
    }

    /// Whether the sparse post-quantum ratchet has stopped moving while this side keeps sending (see `pqStallMessages`).
    /// The app then opens a fresh handshake, whose root is post-quantum again (see `AppModel.refreshStalledPostQuantum`),
    /// as SPQR starts over when its epochs stop moving. A session nobody writes on never counts as stalled.
    var postQuantumStalled: Bool {
        let sent = sentSincePQ ?? 0
        if sent >= Self.pqStallMessages { return true }
        guard sent >= Self.pqStallSoonMessages, let at = pqAt, let last = lastSentAt else { return false }
        return last.timeIntervalSince(at) >= Self.pqStallAge
    }

    /// Keys for skipped messages, for tests.
    var skippedCount: Int { skipped.count }

    /// Whether any kept key for a skipped message is due to go (or has no time yet), so a caller only writes when
    /// `dropExpiredSkipped` would change something.
    func hasExpiredSkipped(now: Date = Ratchet.now()) -> Bool {
        skipped.contains { $0.at.map { now.timeIntervalSince($0) >= Self.skippedLifetime } ?? true }
    }

    /// Drops the kept keys of skipped messages older than `skippedLifetime`, and gives a time to any kept before times
    /// were noted.
    mutating func dropExpiredSkipped(now: Date = Ratchet.now()) {
        guard !skipped.isEmpty else { return }
        for k in skipped.indices where skipped[k].at == nil { skipped[k].at = now }
        skipped.removeAll { now.timeIntervalSince($0.at ?? now) >= Self.skippedLifetime }
    }

    /// Encrypts the next message. `fit`, when given, says for a message how big its envelope will be and how many bytes
    /// of padding it has left: the message then carries as many more post-quantum chunks as fit in that padding, and its
    /// envelope stays exactly the size it would have been with one.
    mutating func encrypt(_ plaintext: Data, fit: ((RatchetMessage) -> (size: Int, room: Int))? = nil) throws -> RatchetMessage {
        try startSendingChain()
        guard let ck = cks else { throw RatchetError.notReady }
        var base = pq ?? PQState()
        if base.offerSecret == nil && base.offerSeed == nil { base.offerSeed = try MLKEM768.PrivateKey().seedRepresentation }
        let offer = try base.offerSecret == nil ? base.offerSeed.map { seed -> Data in
            let key = try MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil).publicKey.rawRepresentation
            return key + Self.digest(key)
        } : nil
        let (next, mk) = Self.kdfChain(ck)
        let dhPublic = try Self.publicKey(dhs)

        func build(_ slots: Int) throws -> (RatchetMessage, PQState) {
            var q = base
            let chunks = Self.chunks(&q, offer: offer, slots: slots)
            let header = RatchetHeader(dh: dhPublic, pn: pn, n: ns, v: RatchetHeader.version, pq: chunks, pm: sendMix)
            let sealed = try Self.seal(plaintext, key: mk, ad: ad + header.authenticated)
            return (RatchetMessage(header: header, ciphertext: sealed), q)
        }

        var (message, q) = try build(1)
        if let fit {
            let first = fit(message)
            // Each chunk more is 102 bytes, a little over 136 once written out.
            var extra = min(Self.maxChunks - 1, max(0, first.room) / 140)
            while extra > 0 {
                let (bigger, state) = try build(1 + extra)
                let now = fit(bigger)
                if now.size == first.size && now.room >= 0 {
                    (message, q) = (bigger, state)
                    break
                }
                extra -= 1
            }
        }
        cks = next
        pq = q
        ns += 1
        if pqAt == nil { pqAt = Self.now() }
        sentSincePQ = (sentSincePQ ?? 0) &+ 1
        lastSentAt = Self.now()
        dropExpiredSkipped()
        return message
    }

    /// Works on a copy, so a forged or garbled message never damages the real state.
    mutating func decrypt(_ message: RatchetMessage) throws -> Data {
        guard message.header.dh.count == 32 else { throw RatchetError.malformed }
        guard message.header.v == RatchetHeader.version else { throw RatchetError.peerTooOld }
        var s = self
        s.dropExpiredSkipped()
        if let plain = try s.openSkipped(message) {
            s.absorbChunks(message.header)
            self = s
            return plain
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
        let plain = try Self.open(message.ciphertext, key: mk, ad: ad + message.header.authenticated)
        // Only a message that opened is believed about its chunks.
        s.absorbChunks(message.header)
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
        // Subtracting rather than adding to an attacker-influenced counter, so a huge `n` can't overflow.
        if n > nr, n - nr > Self.maxSkip { throw RatchetError.tooManySkipped }
        var ck = start
        let now = Self.now()
        while nr < n {
            let (next, mk) = Self.kdfChain(ck)
            skipped.append(Skipped(dh: dhr ?? Data(), n: nr, key: mk, at: now))
            ck = next
            nr += 1
        }
        ckr = ck
        if skipped.count > Self.maxStoredSkipped { skipped.removeFirst(skipped.count - Self.maxStoredSkipped) }
        // Only the newest few chains keep keys: entries are in the order they were kept, so the chains whose last key
        // was kept longest ago go first.
        var chains: [Data] = []
        for entry in skipped.reversed() where !chains.contains(entry.dh) { chains.append(entry.dh) }
        if chains.count > Self.maxSkippedChains {
            let kept = Set(chains.prefix(Self.maxSkippedChains))
            skipped.removeAll { !kept.contains($0.dh) }
        }
    }

    /// A new ratchet key from the other side: derive a fresh receiving chain, and make a fresh key for the sending chain,
    /// which is derived when the first message goes on it (`startSendingChain`). The receiving chain carries a
    /// post-quantum secret if the other side mixed in its offer that we answered.
    private mutating func step(_ header: RatchetHeader) throws {
        let theirs = header.dh
        var q = pq ?? PQState()
        // A sending chain still waiting to be derived was never used, so the other side can't have stepped past it: it is
        // simply dropped, and a secret that would have gone into it goes into the next one.
        pn = ns
        ns = 0
        nr = 0
        dhr = theirs
        let ours = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhs)
        var receiving = try Self.dh(ours, theirs)
        if let epoch = header.pm {
            // They mixed in the secret of the ciphertext we sent them. We made it, so we always have it.
            guard epoch == q.takeEpoch, let secret = q.takeSecret, let transcript = q.takeTranscript else {
                throw RatchetError.decryptFailed
            }
            receiving += Self.pqInput(secret, transcript: transcript, epoch: epoch)
            q.takeEpoch &+= 1
            q.takeParts = []
            q.takeBlob = nil
            q.takeNext = 0
            q.takeSecret = nil
            q.takeTranscript = nil
            q.takeKey = nil
            pqAt = Self.now()
            sentSincePQ = 0
        }
        (rk, ckr) = Self.kdfRoot(rk, receiving)
        pq = q
        dhs = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        cks = nil
        sendMix = nil
    }

    /// Derives the sending chain after a step, with the secret of our offer in it if we hold one by now.
    private mutating func startSendingChain() throws {
        guard cks == nil, let theirs = dhr else { return }
        var q = pq ?? PQState()
        var sending = try Self.dh(try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhs), theirs)
        sendMix = nil
        if let secret = q.offerSecret, let transcript = q.offerTranscript {
            sending += Self.pqInput(secret, transcript: transcript, epoch: q.offerEpoch)
            sendMix = q.offerEpoch
            q.offerEpoch &+= 1
            q.offerSeed = nil
            q.offerNext = 0
            q.offerParts = []
            q.offerSecret = nil
            q.offerTranscript = nil
            pqAt = Self.now()
            sentSincePQ = 0
        }
        pq = q
        (rk, cks) = Self.kdfRoot(rk, sending)
    }

    // MARK: Sparse post-quantum exchange

    /// Chunk on the wire: kind (0 a piece of an offered key, 1 a piece of an answer, 2 filler), epoch, chunk number, bytes.
    private static let chunkLength = 1 + 4 + 1 + ChunkCode.size
    /// The most chunks one message carries: enough for a whole key and a whole answer.
    private static var maxChunks: Int { ChunkCode.blocks(for: offerLength) + ChunkCode.blocks(for: answerLength) }

    private static func pack(kind: UInt8, epoch: UInt32, number: Int, bytes: Data) -> Data {
        Data([kind]) + n32(epoch) + Data([UInt8(number)]) + bytes
    }

    /// The chunks this message carries, at most `slots` and at least one, so the field is always there. Each exchange
    /// sends fresh chunk numbers, taking turns, and no more in one message than it takes to rebuild it.
    private static func chunks(_ q: inout PQState, offer: Data?, slots: Int) -> Data {
        var out = Data()
        var offerLeft = offer == nil ? 0 : ChunkCode.blocks(for: offerLength)
        var answerLeft = q.takeBlob == nil ? 0 : ChunkCode.blocks(for: answerLength)
        var used = 0
        while used < slots, offerLeft + answerLeft > 0 {
            if let offer, offerLeft > 0, answerLeft == 0 || !q.turn {
                q.turn = true
                let number = Int(q.offerNext % UInt32(ChunkCode.numbers))
                q.offerNext += 1
                offerLeft -= 1
                out += pack(kind: 0, epoch: q.offerEpoch, number: number, bytes: ChunkCode.chunk(offer, number: number))
            } else if let blob = q.takeBlob {
                q.turn = false
                let number = Int(q.takeNext % UInt32(ChunkCode.numbers))
                q.takeNext += 1
                answerLeft -= 1
                out += pack(kind: 1, epoch: q.takeEpoch, number: number, bytes: ChunkCode.chunk(blob, number: number))
            } else {
                break
            }
            used += 1
        }
        if out.isEmpty { out = pack(kind: 2, epoch: 0, number: 0, bytes: .random(ChunkCode.size)) }
        return out
    }

    /// Collects the chunks a message carried. One that is for another epoch, or is not what it should be, is just ignored.
    private mutating func absorbChunks(_ header: RatchetHeader) {
        guard let raw = header.pq, !raw.isEmpty, raw.count % Self.chunkLength == 0 else { return }
        let all = Data(raw)
        for i in 0..<min(all.count / Self.chunkLength, Self.maxChunks) {
            absorbChunk(Data(all[(i * Self.chunkLength)..<((i + 1) * Self.chunkLength)]))
        }
    }

    private mutating func absorbChunk(_ bytes: Data) {
        let kind = bytes[0]
        let epoch = bytes[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let number = bytes[5]
        let body = Data(bytes.suffix(ChunkCode.size))
        guard Int(number) < ChunkCode.numbers else { return }
        var q = pq ?? PQState()
        switch kind {
        case 0:
            // A piece of their key, for us to answer. Still taken after we answered: if the key they offer now is a different
            // one (our answer didn't match theirs, so they started over with a fresh key), it is answered again. Until it
            // has, they never mix in this epoch, so replacing our secret can't leave a message unreadable.
            guard epoch == q.takeEpoch else { return }
            if !q.takeParts.contains(where: { $0.n == number }) { q.takeParts.append(Part(n: number, bytes: body)) }
            if q.takeParts.count >= ChunkCode.blocks(for: Self.offerLength) {
                let parts = Dictionary(uniqueKeysWithValues: q.takeParts.map { (Int($0.n), $0.bytes) })
                q.takeParts = []
                guard let whole = ChunkCode.decode(parts, length: Self.offerLength),
                      Self.digest(whole.prefix(Self.keyLength)) == whole.suffix(32) else {
                    // Pieces that don't fit together: start collecting again.
                    pq = q
                    return
                }
                let keyDigest = Self.digest(whole.prefix(Self.keyLength))
                guard keyDigest != q.takeKey,
                      let key = try? MLKEM768.PublicKey(rawRepresentation: whole.prefix(Self.keyLength)),
                      let sealed = try? key.encapsulate() else {
                    pq = q
                    return
                }
                let ciphertext = sealed.encapsulated
                q.takeSecret = sealed.sharedSecret.withUnsafeBytes { Data($0) }
                q.takeTranscript = Data(SHA256.hash(data: whole.prefix(Self.keyLength) + ciphertext))
                q.takeKey = keyDigest
                // The answer names the key it answers, so the offerer can tell it answers the key it holds.
                let answer = ciphertext + keyDigest
                q.takeBlob = answer + Self.digest(answer)
                q.takeNext = 0
            }
        case 1:
            // A piece of their answer to our key.
            guard epoch == q.offerEpoch, q.offerSecret == nil, let seed = q.offerSeed else { return }
            if !q.offerParts.contains(where: { $0.n == number }) { q.offerParts.append(Part(n: number, bytes: body)) }
            if q.offerParts.count >= ChunkCode.blocks(for: Self.answerLength) {
                let parts = Dictionary(uniqueKeysWithValues: q.offerParts.map { (Int($0.n), $0.bytes) })
                guard let whole = ChunkCode.decode(parts, length: Self.answerLength),
                      Self.digest(whole.prefix(Self.ciphertextLength + 32)) == whole.suffix(32),
                      let kem = try? MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil) else {
                    q.offerParts = []
                    pq = q
                    return
                }
                // An answer to some other key than the one we offer: thrown away, and our key goes on being offered. The other
                // side answers again once it rebuilds a key that isn't the one it answered (`takeKey`). A fresh key here
                // would let stale chunks of the wrong answer, still on their way, throw each new key away in turn.
                let answered = whole.dropFirst(Self.ciphertextLength).prefix(32)
                guard Data(answered) == Self.digest(kem.publicKey.rawRepresentation),
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

    /// An ML-KEM-768 public key and its digest; a ciphertext, the digest of the key it answers, and the digest of both.
    private static let keyLength = 1184
    private static let ciphertextLength = 1088
    private static let offerLength = keyLength + 32
    private static let answerLength = ciphertextLength + 32 + 32

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
