import Foundation
import CryptoKit

enum EnvelopeError: Error { case malformed, badSignature }

/// Sealed sender envelopes.
///
/// Outside: a fresh X25519 key per message and ChaCha20-Poly1305 ciphertext, so the
/// relay sees random bytes of a few fixed sizes and nothing about who sent them.
/// Inside: the sender's agreement key, then the payload sealed again with a key that mixes in an
/// exchange between the sender's and recipient's identity keys. Only the sender could have made it,
/// so the recipient knows who it's from, but the recipient could have made it too, so it proves
/// nothing to anyone else: there's no signature over what was said.
enum Envelope {
    private static let version: UInt8 = 2
    private static let outerInfo = Data("pulshade.envelope.v2.outer".utf8)
    private static let innerInfo = Data("pulshade.envelope.v2.inner".utf8)
    private static let bindLabel = Data("pulshade.keys.v1".utf8)
    private static let buckets = [2_048, 8_192, 32_768, 131_072, 524_288, 2_097_152]

    private struct Inner: Codable {
        /// The sender's signing key, so the recipient knows which account this is.
        var from: Data
        /// The signing key's signature over the agreement key: "these two keys are the same person". It says
        /// nothing about this message, and is the same every time.
        var bind: Data
        var body: Data
        /// Which of the sender's devices sent it.
        var device: Data?
        /// When it was sealed, in whole seconds, so an old envelope can't be replayed later.
        var at: UInt64
    }

    /// Opened envelope: the payload, who sent it, from which of their devices, and when.
    struct Opened {
        var payload: Payload
        var signer: Data
        var device: Data
        var sentAt: Date
    }

    static func seal(_ payload: Payload, from me: Identity, device: Data = Data(), to agreementKey: Data) throws -> Data {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementKey)
        let sender = me.agreementKey.publicKey.rawRepresentation
        let inner = Inner(from: me.signingKey.publicKey.rawRepresentation, bind: try binding(me), body: try JSONEncoder.pulshade.encode(payload),
                          device: device.isEmpty ? nil : device, at: UInt64(RelayClock.now.timeIntervalSince1970))

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralRaw = ephemeral.publicKey.rawRepresentation
        let outerSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let staticSecret = try me.agreementKey.sharedSecretFromKeyAgreement(with: recipient)
        let innerKey = deriveInner(outerSecret, staticSecret, ephemeral: ephemeralRaw, recipient: agreementKey, sender: sender)
        let sealedInner = try ChaChaPoly.seal(JSONEncoder().encode(inner), using: innerKey).combined

        let outerKey = deriveOuter(outerSecret, ephemeral: ephemeralRaw, recipient: agreementKey)
        let sealed = try ChaChaPoly.seal(pad(sender + sealedInner), using: outerKey)
        return Data([version]) + ephemeralRaw + sealed.combined
    }

    /// Returns the payload and the sender's signing key.
    static func open(_ blob: Data, with me: Identity) throws -> (Payload, Data) {
        let opened = try openFull(blob, with: me)
        return (opened.payload, opened.signer)
    }

    static func openFull(_ blob: Data, with me: Identity) throws -> Opened {
        guard blob.count > 33 + 28, blob.first == version else { throw EnvelopeError.malformed }
        let ephemeralRaw = Data(blob.dropFirst().prefix(32))
        let mine = me.agreementKey.publicKey.rawRepresentation
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralRaw)
        let outerSecret = try me.agreementKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let outer = try unpad(ChaChaPoly.open(ChaChaPoly.SealedBox(combined: blob.dropFirst(33)),
                                              using: deriveOuter(outerSecret, ephemeral: ephemeralRaw, recipient: mine)))
        guard outer.count > 32 else { throw EnvelopeError.malformed }
        let sender = Data(outer.prefix(32))
        let staticSecret = try me.agreementKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: sender))
        let innerKey = deriveInner(outerSecret, staticSecret, ephemeral: ephemeralRaw, recipient: mine, sender: sender)
        guard let plain = try? ChaChaPoly.open(ChaChaPoly.SealedBox(combined: outer.dropFirst(32)), using: innerKey)
        else { throw EnvelopeError.badSignature }
        let inner = try JSONDecoder().decode(Inner.self, from: plain)

        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: inner.from)
        guard signer.isValidSignature(inner.bind, for: bindLabel + sender) else { throw EnvelopeError.badSignature }
        return Opened(payload: try JSONDecoder.pulshade.decode(Payload.self, from: inner.body), signer: inner.from,
                      device: inner.device ?? Data(), sentAt: Date(timeIntervalSince1970: TimeInterval(inner.at)))
    }

    /// Ties an identity's agreement key to its signing key.
    private static func binding(_ me: Identity) throws -> Data {
        try me.signingKey.signature(for: bindLabel + me.agreementKey.publicKey.rawRepresentation)
    }

    private static func deriveOuter(_ secret: SharedSecret, ephemeral: Data, recipient: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral + recipient, sharedInfo: outerInfo, outputByteCount: 32)
    }

    private static func deriveInner(_ ephemeralSecret: SharedSecret, _ staticSecret: SharedSecret, ephemeral: Data,
                                    recipient: Data, sender: Data) -> SymmetricKey {
        let ikm = ephemeralSecret.withUnsafeBytes { Data($0) } + staticSecret.withUnsafeBytes { Data($0) }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: ephemeral + recipient + sender,
                                      info: innerInfo, outputByteCount: 32)
    }

    /// Length prefix, then zeros up to the next bucket size.
    private static func pad(_ data: Data) -> Data {
        let needed = data.count + 4
        let size = buckets.first { $0 >= needed } ?? ((needed + 1_048_575) / 1_048_576) * 1_048_576
        var out = Data(capacity: size)
        withUnsafeBytes(of: UInt32(data.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(data)
        out.append(Data(count: size - out.count))
        return out
    }

    private static func unpad(_ data: Data) throws -> Data {
        guard data.count >= 4 else { throw EnvelopeError.malformed }
        let length = data.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length <= data.count - 4 else { throw EnvelopeError.malformed }
        return Data(data.dropFirst(4).prefix(length))
    }

    static func paddedSize(of count: Int) -> Int {
        buckets.first { $0 >= count + 4 } ?? 0
    }
}
