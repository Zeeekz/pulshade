import Foundation
import CryptoKit

enum EnvelopeError: Error { case malformed, badSignature }

/// The envelope's crypto on raw keys and raw payload bytes, with nothing else from the app: the notification
/// helper builds with this alone (no Tor, no chats). `Envelope` is the app's way in. See `Envelope` for the design.
enum EnvelopeCore {
    private static let version: UInt8 = 2
    private static let outerInfo = Data("pulshade.envelope.v2.outer".utf8)
    private static let innerInfo = Data("pulshade.envelope.v2.inner".utf8)
    static let bindLabel = Data("pulshade.keys.v1".utf8)
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
        /// What the sender's app can read, as bits (see `Envelope.reads`). Older apps leave it out and ignore it.
        var caps: UInt8?
    }

    /// An opened envelope before its payload is read: who sent it, from which device, when, and the payload's bytes.
    struct Header {
        var signer: Data
        var agreement: Data
        var device: Data
        var sentAt: Date
        var caps: UInt8
        var body: Data
    }

    /// The signing key's signature over an agreement key: "these two keys are the same person". Envelopes carry it,
    /// and so do invites, so neither can pair one account's signing key with someone else's agreement key.
    static func bind(signing: Curve25519.Signing.PrivateKey, agreement: Data) throws -> Data {
        try signing.signature(for: bindLabel + agreement)
    }

    static func bindIsValid(_ bind: Data, signing: Data, agreement: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signing) else { return false }
        return key.isValidSignature(bind, for: bindLabel + agreement)
    }

    static func seal(body: Data, framed: Bool, signing: Curve25519.Signing.PrivateKey,
                     agreement: Curve25519.KeyAgreement.PrivateKey, device: Data, caps: UInt8, at: Date,
                     to agreementKey: Data) throws -> Data {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementKey)
        let sender = agreement.publicKey.rawRepresentation
        let bind = try signing.signature(for: bindLabel + sender)
        let inner = Inner(from: signing.publicKey.rawRepresentation, bind: bind, body: framed ? Data() : body,
                          device: device.isEmpty ? nil : device, at: UInt64(max(0, at.timeIntervalSince1970)), caps: caps)
        let innerPlain = framed ? Frame.join(try JSONEncoder().encode(inner), body) : try JSONEncoder().encode(inner)

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralRaw = ephemeral.publicKey.rawRepresentation
        let outerSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let staticSecret = try agreement.sharedSecretFromKeyAgreement(with: recipient)
        let innerKey = deriveInner(outerSecret, staticSecret, ephemeral: ephemeralRaw, recipient: agreementKey, sender: sender)
        let sealedInner = try ChaChaPoly.seal(innerPlain, using: innerKey).combined

        let outerKey = deriveOuter(outerSecret, ephemeral: ephemeralRaw, recipient: agreementKey)
        let sealed = try ChaChaPoly.seal(pad(sender + sealedInner), using: outerKey)
        return Data([version]) + ephemeralRaw + sealed.combined
    }

    static func open(_ blob: Data, agreement: Curve25519.KeyAgreement.PrivateKey) throws -> Header {
        guard blob.count > 33 + 28, blob.first == version else { throw EnvelopeError.malformed }
        let ephemeralRaw = Data(blob.dropFirst().prefix(32))
        let mine = agreement.publicKey.rawRepresentation
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralRaw)
        let outerSecret = try agreement.sharedSecretFromKeyAgreement(with: ephemeral)
        let outer = try unpad(ChaChaPoly.open(ChaChaPoly.SealedBox(combined: blob.dropFirst(33)),
                                              using: deriveOuter(outerSecret, ephemeral: ephemeralRaw, recipient: mine)))
        guard outer.count > 32 else { throw EnvelopeError.malformed }
        let sender = Data(outer.prefix(32))
        let staticSecret = try agreement.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: sender))
        let innerKey = deriveInner(outerSecret, staticSecret, ephemeral: ephemeralRaw, recipient: mine, sender: sender)
        guard let plain = try? ChaChaPoly.open(ChaChaPoly.SealedBox(combined: outer.dropFirst(32)), using: innerKey)
        else { throw EnvelopeError.badSignature }
        var inner: Inner
        if plain.first == Frame.mark {
            guard let (header, tail) = Frame.split(plain) else { throw EnvelopeError.malformed }
            inner = try JSONDecoder().decode(Inner.self, from: header)
            inner.body = tail
        } else {
            inner = try JSONDecoder().decode(Inner.self, from: plain)
        }

        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: inner.from)
        guard signer.isValidSignature(inner.bind, for: bindLabel + sender) else { throw EnvelopeError.badSignature }
        return Header(signer: inner.from, agreement: sender, device: inner.device ?? Data(),
                      sentAt: Date(timeIntervalSince1970: TimeInterval(inner.at)), caps: inner.caps ?? 0, body: inner.body)
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

    /// The same padding, for group envelopes (see `GroupSeal`).
    static func padded(_ data: Data) -> Data { pad(data) }
    static func unpadded(_ data: Data) -> Data? { try? unpad(data) }
}

/// A short description followed by raw bytes: `0`, the description's length (4 bytes, big-endian), the description,
/// then the bytes. JSON never starts with a zero byte, so a reader can tell this from plain JSON at a glance.
///
/// Bytes inside JSON are written as base64, a third bigger each time, and a video piece sat inside three layers of
/// it (the piece in its payload, the ciphertext in the ratchet message, that in the envelope): 1 MB went up as 3 MiB.
/// Framed, the bytes ride along as they are.
enum Frame {
    static let mark: UInt8 = 0

    static func join(_ header: Data, _ tail: Data) -> Data {
        var out = Data(capacity: 5 + header.count + tail.count)
        out.append(mark)
        withUnsafeBytes(of: UInt32(header.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(header)
        out.append(tail)
        return out
    }

    static func split(_ data: Data) -> (header: Data, tail: Data)? {
        let bytes = Data(data)
        guard bytes.count >= 5, bytes[0] == mark else { return nil }
        let length = bytes[1..<5].reduce(0) { $0 << 8 | Int($1) }
        guard length <= bytes.count - 5 else { return nil }
        return (Data(bytes[5..<(5 + length)]), Data(bytes[(5 + length)...]))
    }
}
