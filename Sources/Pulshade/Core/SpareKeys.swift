import Foundation
import CryptoKit

/// Spare keys: new chat keys a friend can start with straight away, without waiting for you to answer.
///
/// Normally new keys take a round trip: one side asks (`deviceHello`), the other's app answers when it next runs.
/// After Detach and logging back in, that meant every chat waited until each friend opened Pulshade.
///
/// So each device makes, for each friend, the first half of a handshake ahead of time (a `PendingHandshake`, kept
/// in its vault) and leaves the public half where only that friend can find it. A friend who has lost their keys
/// takes it and answers it at once (`Handshake.accept`, as if the ask had just arrived), and can write immediately.
/// Their answer (`Payload.spareAccept`) reaches this device whenever it next runs, which finishes its side
/// (`Handshake.complete`). The cryptography is exactly the ordinary handshake's; only the ask was made early.
///
/// Where it's left: the relay's sealed-backup store, under a key worked out from a secret only the two of you share
/// (an exchange between your identity keys), this device's id and whose spare it is. Every read and write is
/// signed with that key, as for a backup, and the card is sealed with another key from the same secret and padded
/// to one size. The relay can't open it or tell whose it is; each slot is read and written on its own connection,
/// so it can't easily tie one device's slots together either. The friend who takes it erases it. Nothing on the
/// relay had to change.
enum SpareSlot {
    struct Keys {
        /// Signs every read, write and removal of the slot. Its public half names the slot.
        var signer: Curve25519.Signing.PrivateKey
        /// Seals the card inside.
        var sealing: SymmetricKey
        var name: Data { signer.publicKey.rawRepresentation }
    }

    /// What a slot holds: the public half of the spare handshake, and when it was made.
    struct Card: Codable, Equatable {
        var request: SessionInit
        var madeAt: Date
    }

    private static let salt = Data("pulshade.spare.v1".utf8)

    /// The slot for one device's spare, for one friend. `issuer` is the signing key of the account that made the
    /// spare and `device` its device id, so each device of each account has its own slot per friend, and your spare
    /// for them never shares a slot with theirs for you. Both sides work out the same keys: the exchange between
    /// the two identity keys is the same from either end, and the relay can make neither.
    static func keys(mine: Curve25519.KeyAgreement.PrivateKey, theirs: Data, issuer: Data, device: Data) -> Keys? {
        guard !device.isEmpty, let them = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs),
              let shared = try? mine.sharedSecretFromKeyAgreement(with: them) else { return nil }
        let ikm = SymmetricKey(data: shared.withUnsafeBytes { Data($0) })
        let context = Data(SHA256.hash(data: salt + issuer + device))
        let signing = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: context, info: Data("pulshade.spare.signing".utf8),
                                             outputByteCount: 32)
        let sealing = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: context, info: Data("pulshade.spare.sealing".utf8),
                                             outputByteCount: 32)
        guard let signer = try? Curve25519.Signing.PrivateKey(rawRepresentation: signing.withUnsafeBytes { Data($0) })
        else { return nil }
        return Keys(signer: signer, sealing: sealing)
    }

    /// The card, padded to the smallest backup size and sealed, so it comes out the size of any small backup.
    static func seal(_ card: Card, with keys: Keys) -> Data? {
        guard let plain = try? JSONEncoder.pulshade.encode(card) else { return nil }
        return try? AES.GCM.seal(padded(plain), using: keys.sealing, authenticating: keys.name).combined
    }

    /// Nil for anything this slot's keys didn't seal.
    static func open(_ blob: Data, with keys: Keys) -> Card? {
        guard blob.count <= 64 * 1024, let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: keys.sealing, authenticating: keys.name),
              let unpadded = unpadded(plain) else { return nil }
        return try? JSONDecoder.pulshade.decode(Card.self, from: unpadded)
    }

    /// The signature the relay's backup store asks for (`label | key | ts`, then the body's hash for a write), so
    /// the slot is read and written exactly as a backup is.
    static func proof(_ label: String, _ keys: Keys, body: Data? = nil) -> (key: Data, sig: Data, ts: UInt64) {
        let ts = UInt64(RelayClock.now.timeIntervalSince1970)
        var message = Data(label.utf8) + keys.name + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
        if let body { message += Data(SHA256.hash(data: body)) }
        return (keys.name, (try? keys.signer.signature(for: message)) ?? Data(), ts)
    }

    /// Every spare comes out one size: a marker, the length, zeros up to 4 KB. (Not a backup's 64 KB: when spares are
    /// read and written gives them away anyway, and the backup store's room is shared with real backups.)
    static func padded(_ plain: Data) -> Data {
        var size = 4 * 1024
        while size < plain.count + 5 { size *= 2 }
        var out = Data([0x01])
        withUnsafeBytes(of: UInt32(plain.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(plain)
        out.append(Data(count: size - out.count))
        return out
    }

    private static func unpadded(_ data: Data) -> Data? {
        guard data.first == 0x01, data.count >= 5 else { return nil }
        let length = data.dropFirst().prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard 5 + length <= data.count else { return nil }
        return data.subdata(in: 5..<(5 + length))
    }
}

/// One spare this device made for a friend, with its secret half. Lives in the vault with the contact (and so in
/// the sealed backup, which already holds chat keys: a spare that was handed out still works after this device is
/// recovered).
struct SpareKey: Codable {
    var handshake: PendingHandshake
    var madeAt = Date()
    /// When the relay last took it. Nil until then: it's offered again until it goes.
    var publishedAt: Date?
    /// When it's replaced with a new one, if nobody has used it by then.
    var replaceAt: Date?
    /// When it was replaced. A replaced spare is still honoured for a while, for a friend who took it just before.
    var retiredAt: Date?

    var card: SpareSlot.Card? {
        guard let ephemeral = handshake.publicEphemeral,
              let kem = try? MLKEM768.PrivateKey(seedRepresentation: handshake.kemSeed, publicKey: nil) else { return nil }
        return SpareSlot.Card(request: SessionInit(ephemeral: ephemeral, kem: kem.publicKey.rawRepresentation), madeAt: madeAt)
    }

    static func make() -> SpareKey? {
        guard let (handshake, _) = try? Handshake.start() else { return nil }
        return SpareKey(handshake: handshake)
    }
}
