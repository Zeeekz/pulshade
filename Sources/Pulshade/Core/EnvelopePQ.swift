import Foundation
import CryptoKit

/// The post-quantum half of an identity: an ML-KEM-768 key that envelopes are sealed to, next to the X25519 agreement
/// key, and an ML-DSA-65 key that signs next to the Ed25519 one. Both come from the identity's seed (see `Identity`), so
/// a recovered, linked or reinstalled copy of the account has the same ones, and nothing new needs storing or backing up.
struct PQKeys {
    let kem: MLKEM768.PrivateKey
    let sig: MLDSA65.PrivateKey

    init(kemSeed: Data, sigSeed: Data) throws {
        kem = try MLKEM768.PrivateKey(seedRepresentation: kemSeed, publicKey: nil)
        sig = try MLDSA65.PrivateKey(seedRepresentation: sigSeed, publicKey: nil)
    }

    var kemSeed: Data { kem.seedRepresentation }
    var sigSeed: Data { sig.seedRepresentation }
    var pin: PQPin { PQPin(kem: kem.publicKey.rawRepresentation, dsa: sig.publicKey.rawRepresentation) }
}

/// Someone's post-quantum public keys, as a contact record keeps them. Once a contact has one, nothing from them is
/// accepted without it: it is how a downgrade to the classical envelope is refused.
struct PQPin: Codable, Equatable {
    var kem: Data
    var dsa: Data

    /// A short commitment to these keys that fits in an invite and a safety code: SHA-256 over a domain label and both public
    /// keys (their sizes are fixed, so the join is unambiguous), cut to 16 bytes. An invite carries it, so the first card from
    /// the person who made it is held to it; the safety code covers it, so a pulse check compares these keys too.
    var commitment: Data {
        Data(SHA256.hash(data: Data("pulshade.pq.commit.v1".utf8) + kem + dsa).prefix(Self.commitmentSize))
    }
    static let commitmentSize = 16

    static let kemSize = 1_184
    static let dsaSize = 1_952
    var isWellFormed: Bool {
        kem.count == Self.kemSize && dsa.count == Self.dsaSize
            && (try? MLKEM768.PublicKey(rawRepresentation: kem)) != nil && (try? MLDSA65.PublicKey(rawRepresentation: dsa)) != nil
    }
}

/// How an identity's post-quantum keys are introduced: both public keys, with a signature from the Ed25519 key and one from
/// the ML-DSA key over them and over the X25519 key. A card counts only if both signatures verify, and only for the signing
/// and agreement keys the envelope it came in was sealed with.
struct PQCard: Codable, Equatable {
    var kem: Data
    var dsa: Data
    var edSig: Data
    var pqSig: Data

    static let sigSize = 3_309
    private static let label = Data("pulshade.pq.card.v1".utf8)

    private static func message(signer: Data, agreement: Data, kem: Data, dsa: Data) -> Data {
        label + signer + agreement + kem + dsa
    }

    static func make(signing: Curve25519.Signing.PrivateKey, agreement: Data, keys: PQKeys) throws -> PQCard {
        let pin = keys.pin
        let message = message(signer: signing.publicKey.rawRepresentation, agreement: agreement, kem: pin.kem, dsa: pin.dsa)
        return PQCard(kem: pin.kem, dsa: pin.dsa, edSig: try signing.signature(for: message), pqSig: try keys.sig.signature(for: message))
    }

    func verified(signer: Data, agreement: Data) -> PQPin? {
        let pin = PQPin(kem: kem, dsa: dsa)
        guard pin.isWellFormed, pqSig.count == Self.sigSize,
              let ed = try? Curve25519.Signing.PublicKey(rawRepresentation: signer),
              let pq = try? MLDSA65.PublicKey(rawRepresentation: dsa) else { return nil }
        let message = Self.message(signer: signer, agreement: agreement, kem: kem, dsa: dsa)
        return ed.isValidSignature(edSig, for: message) && pq.isValidSignature(pqSig, for: message) ? pin : nil
    }
}

/// Who an envelope is for: the X25519 key it has always been sealed to, and the ML-KEM key it is now sealed to as well.
struct EnvelopeRecipient {
    var agreement: Data
    var pq: PQPin
}

/// What was refused, so the app can tell the person: a classical-only envelope from someone who is known to have
/// post-quantum keys (a downgrade), or from an app that has none (too old).
enum EnvelopeRefusal: Error { case classical(signer: Data, sentAt: Date) }

/// Envelope version 3. Same shape as `EnvelopeCore`'s, with the post-quantum secret mixed in at both layers:
///
///   `3`, ephemeral X25519 key (32), ML-KEM ciphertext (1088), then ChaCha20-Poly1305 over the padded
///   (sender's agreement key + the inner box).
///
/// The outer key comes from DH(ephemeral, recipient) and the ML-KEM secret together, the inner key from those and the
/// sender-recipient DH: breaking X25519 later opens nothing recorded, and a forger needs both. The inner layer is a frame:
/// a small JSON header, then the raw bytes (an ML-DSA signature if the header says there is one, then the payload).
///
/// Anything that isn't a ratchet message (key setup, erase notices, delivery notes) carries an ML-DSA signature over the
/// whole transcript, checked with the key the sender is pinned to or the card inside the envelope. Ratchet messages
/// are authenticated by their session, whose root is post-quantum already, and stay at their usual size.
extension EnvelopeCore {
    static let versionPQ: UInt8 = 3
    private static let outerInfoPQ = Data("pulshade.envelope.v3.outer".utf8)
    private static let innerInfoPQ = Data("pulshade.envelope.v3.inner".utf8)
    private static let sigLabel = Data("pulshade.envelope.v3.sig".utf8)
    static let kemCiphertextSize = 1_088

    private struct InnerPQ: Codable {
        var from: Data
        var bind: Data
        var device: Data?
        var at: UInt64
        var caps: UInt8?
        /// The tail starts with an ML-DSA signature.
        var signed: Bool?
        /// The sender's post-quantum keys, for a recipient that hasn't got them yet.
        var card: PQCard?
    }

    struct HeaderPQ {
        var header: Header
        /// An ML-DSA signature over this envelope checked out against the sender's keys.
        var signed: Bool
        /// The sender's keys, when they weren't known and the envelope's card (both signatures verified) introduced them.
        var introduced: PQPin?
    }

    static func sealPQ(body: Data, signing: Curve25519.Signing.PrivateKey, agreement: Curve25519.KeyAgreement.PrivateKey,
                       pq: PQKeys, sign: Bool, introduce: Bool, device: Data, caps: UInt8, at: Date,
                       to recipient: EnvelopeRecipient) throws -> Data {
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.agreement)
        let encapsulation = try MLKEM768.PublicKey(rawRepresentation: recipient.pq.kem).encapsulate()
        let kemSecret = encapsulation.sharedSecret.withUnsafeBytes { Data($0) }
        let kemCiphertext = encapsulation.encapsulated
        let sender = agreement.publicKey.rawRepresentation
        let stamp = UInt64(max(0, at.timeIntervalSince1970))
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralRaw = ephemeral.publicKey.rawRepresentation

        var tail = Data()
        if sign {
            let transcript = signedTranscript(ephemeral: ephemeralRaw, kemCiphertext: kemCiphertext, recipient: recipient.agreement,
                                              sender: sender, at: stamp, device: device, body: body)
            tail = try pq.sig.signature(for: transcript)
        }
        let inner = InnerPQ(from: signing.publicKey.rawRepresentation, bind: try signing.signature(for: bindLabel + sender),
                            device: device.isEmpty ? nil : device, at: stamp, caps: caps, signed: sign ? true : nil,
                            card: introduce ? try PQCard.make(signing: signing, agreement: sender, keys: pq) : nil)
        let innerPlain = Frame.join(try JSONEncoder().encode(inner), tail + body)

        let outerSecret = try ephemeral.sharedSecretFromKeyAgreement(with: theirs)
        let staticSecret = try agreement.sharedSecretFromKeyAgreement(with: theirs)
        let salt = ephemeralRaw + recipient.agreement + kemCiphertext
        let innerKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw(outerSecret) + raw(staticSecret) + kemSecret),
                                              salt: salt + sender, info: innerInfoPQ, outputByteCount: 32)
        let outerKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw(outerSecret) + kemSecret),
                                              salt: salt, info: outerInfoPQ, outputByteCount: 32)
        let sealedInner = try ChaChaPoly.seal(innerPlain, using: innerKey).combined
        let sealed = try ChaChaPoly.seal(padded(sender + sealedInner), using: outerKey)
        return Data([versionPQ]) + ephemeralRaw + kemCiphertext + sealed.combined
    }

    /// `known` gives the keys a signer is pinned to, if any.
    static func openPQ(_ blob: Data, agreement: Curve25519.KeyAgreement.PrivateKey, pq: PQKeys,
                       known: (Data) -> PQPin?) throws -> HeaderPQ {
        let prefix = 1 + 32 + kemCiphertextSize
        guard blob.count > prefix + 28, blob.first == versionPQ else { throw EnvelopeError.malformed }
        let bytes = Data(blob)
        let ephemeralRaw = bytes[1..<33]
        let kemCiphertext = Data(bytes[33..<prefix])
        let mine = agreement.publicKey.rawRepresentation
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralRaw)
        let kemSecret = try pq.kem.decapsulate(kemCiphertext).withUnsafeBytes { Data($0) }
        let outerSecret = try agreement.sharedSecretFromKeyAgreement(with: ephemeral)
        let salt = Data(ephemeralRaw) + mine + kemCiphertext
        let outerKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw(outerSecret) + kemSecret),
                                              salt: salt, info: outerInfoPQ, outputByteCount: 32)
        guard let outer = unpadded(try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: bytes[prefix...]), using: outerKey))
        else { throw EnvelopeError.malformed }
        guard outer.count > 32 else { throw EnvelopeError.malformed }
        let sender = Data(outer.prefix(32))
        let staticSecret = try agreement.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: sender))
        let innerKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw(outerSecret) + raw(staticSecret) + kemSecret),
                                              salt: salt + sender, info: innerInfoPQ, outputByteCount: 32)
        guard let plain = try? ChaChaPoly.open(ChaChaPoly.SealedBox(combined: outer.dropFirst(32)), using: innerKey),
              let (headerBytes, tail) = Frame.split(plain) else { throw EnvelopeError.badSignature }
        let inner = try JSONDecoder().decode(InnerPQ.self, from: headerBytes)
        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: inner.from)
        guard signer.isValidSignature(inner.bind, for: bindLabel + sender) else { throw EnvelopeError.badSignature }

        var body = tail
        var signed = false
        var introduced: PQPin?
        if inner.signed == true {
            guard tail.count >= PQCard.sigSize else { throw EnvelopeError.malformed }
            let signature = Data(tail.prefix(PQCard.sigSize))
            body = Data(tail.dropFirst(PQCard.sigSize))
            let pinned = known(inner.from)
            var pin = pinned
            if let card = inner.card {
                // A card for someone already pinned must be the same keys; for anyone else it must verify.
                guard let verified = card.verified(signer: inner.from, agreement: sender), pinned == nil || pinned == verified
                else { throw EnvelopeError.badSignature }
                if pinned == nil { pin = verified; introduced = verified }
            }
            guard let pin, let key = try? MLDSA65.PublicKey(rawRepresentation: pin.dsa),
                  key.isValidSignature(signature, for: signedTranscript(ephemeral: Data(ephemeralRaw), kemCiphertext: kemCiphertext,
                                                                       recipient: mine, sender: sender, at: inner.at,
                                                                       device: inner.device ?? Data(), body: body))
            else { throw EnvelopeError.badSignature }
            signed = true
        } else if let card = inner.card {
            // A card on a ratchet message: taken the same way, and only for someone not pinned yet.
            if known(inner.from) == nil, let verified = card.verified(signer: inner.from, agreement: sender) { introduced = verified }
        }
        return HeaderPQ(header: Header(signer: inner.from, agreement: sender, device: inner.device ?? Data(),
                                       sentAt: Date(timeIntervalSince1970: TimeInterval(inner.at)), caps: inner.caps ?? 0, body: body),
                        signed: signed, introduced: introduced)
    }

    private static func signedTranscript(ephemeral: Data, kemCiphertext: Data, recipient: Data, sender: Data, at: UInt64,
                                         device: Data, body: Data) -> Data {
        var out = sigLabel + ephemeral + Data(SHA256.hash(data: kemCiphertext)) + recipient + sender
        withUnsafeBytes(of: at.bigEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(device.count).bigEndian) { out.append(contentsOf: $0) }
        return out + device + Data(SHA256.hash(data: body))
    }

    private static func raw(_ secret: SharedSecret) -> Data { secret.withUnsafeBytes { Data($0) } }
}
