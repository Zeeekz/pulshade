import Foundation
import CryptoKit

/// Each device's own long-term key pair, next to the account's.
///
/// Every device of an account holds the account's keys, so on their own they can't tell one device from another:
/// someone with a copy of the account (its recovery code, say) could claim to be one of your existing devices and
/// nobody would notice. So each device also has keys of its own, made on it and never sent anywhere: an Ed25519 key and
/// an ML-DSA-65 key, the same pair the account signs with. The account signs the device's public keys (`DeviceKeyCard`),
/// and the device signs every handshake it takes part in (`SessionInit`, `SessionAccept`), so a session is only opened
/// with whoever holds that device's private keys. Both public keys also go into the session's root (see `Handshake`).
///
/// Contacts pin each device's keys the first time they see them (`DeviceLink.keyPin`). A device that later shows other
/// keys under the same id is treated as a new device: announced in the chat, and held when "ask before a friend's new
/// device" is on.
///
/// The keys come from 32 random bytes kept in this device's data file, sealed again with a key only this device's
/// Keychain holds (`Vault.sealDeviceSeed`), and left out of the backup on the relay and everything sent to another device.
/// A data file that turns up anywhere else, or an account restored from its backup, makes new keys: to everyone, a new
/// device. Each persona gets its own pair from them, as it gets its own device id, so two personas can't be matched up
/// by their device keys.
struct DeviceKey {
    let ed: Curve25519.Signing.PrivateKey
    let dsa: MLDSA65.PrivateKey

    init(seed: Data, persona: UUID?) throws {
        let root = SymmetricKey(data: seed)
        let tag = persona?.uuidString ?? "main"
        func derive(_ label: String) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: root, info: Data("\(label)|\(tag)".utf8), outputByteCount: 32)
                .withUnsafeBytes { Data($0) }
        }
        ed = try .init(rawRepresentation: derive("pulshade.device.ed.v1"))
        dsa = try MLDSA65.PrivateKey(seedRepresentation: derive("pulshade.device.dsa.v1"), publicKey: nil)
    }

    var pin: Data { DeviceKeyCard.pin(ed: ed.publicKey.rawRepresentation, dsa: dsa.publicKey.rawRepresentation) }

    /// The public keys, signed by the account for this device id.
    func card(account: Identity, device: Data) throws -> DeviceKeyCard {
        let edPub = ed.publicKey.rawRepresentation, dsaPub = dsa.publicKey.rawRepresentation
        let message = DeviceKeyCard.message(account: account.card.signing, device: device, ed: edPub, dsa: dsaPub)
        return DeviceKeyCard(ed: edPub, dsa: dsaPub, edSig: try account.signingKey.signature(for: message),
                             pqSig: try account.pq.sig.signature(for: message))
    }

    func sign(_ message: Data) throws -> DeviceSignature {
        DeviceSignature(ed: try ed.signature(for: message), pq: try dsa.signature(for: message))
    }
}

/// A device's public keys, signed by its account with both of the account's signing keys.
struct DeviceKeyCard: Codable, Equatable {
    var ed: Data
    var dsa: Data
    var edSig: Data
    var pqSig: Data

    private static let label = Data("pulshade.device.card.v1".utf8)

    static func message(account: Data, device: Data, ed: Data, dsa: Data) -> Data {
        var out = label + account
        withUnsafeBytes(of: UInt32(device.count).bigEndian) { out.append(contentsOf: $0) }
        return out + device + ed + dsa
    }

    /// What a contact keeps of a device's keys: a hash of both public keys.
    static func pin(ed: Data, dsa: Data) -> Data { Data(SHA256.hash(data: Data("pulshade.device.pin.v1".utf8) + ed + dsa)) }
    var pin: Data { Self.pin(ed: ed, dsa: dsa) }

    /// Signed by this account for this device id: by its Ed25519 key, and by its ML-DSA key.
    func isSigned(by account: Data, accountPQ: PQPin, device: Data) -> Bool {
        guard ed.count == 32, dsa.count == PQPin.dsaSize, !device.isEmpty,
              let accountEd = try? Curve25519.Signing.PublicKey(rawRepresentation: account),
              let accountDSA = try? MLDSA65.PublicKey(rawRepresentation: accountPQ.dsa) else { return false }
        let message = Self.message(account: account, device: device, ed: ed, dsa: dsa)
        return accountEd.isValidSignature(edSig, for: message) && accountDSA.isValidSignature(pqSig, for: message)
    }

    /// Made by this device's private keys: both signatures check out.
    func checks(_ signature: DeviceSignature, for message: Data) -> Bool {
        guard let edKey = try? Curve25519.Signing.PublicKey(rawRepresentation: ed),
              let dsaKey = try? MLDSA65.PublicKey(rawRepresentation: dsa) else { return false }
        return edKey.isValidSignature(signature.ed, for: message) && dsaKey.isValidSignature(signature.pq, for: message)
    }
}

/// A device's signature with both its keys.
struct DeviceSignature: Codable, Equatable {
    var ed: Data
    var pq: Data
}

/// Who a handshake is between, as the device signatures cover it: the two accounts and the signing device's id.
struct HandshakeParties {
    /// The account whose device signs.
    var from: Data
    /// The account it's for.
    var to: Data
    /// The signing device's id, as `to` knows it.
    var device: Data
}

extension Handshake {
    private static func header(_ label: String, _ parties: HandshakeParties) -> Data {
        var out = Data(label.utf8) + parties.from + parties.to
        withUnsafeBytes(of: UInt32(parties.device.count).bigEndian) { out.append(contentsOf: $0) }
        return out + parties.device
    }

    static func initMessage(_ request: SessionInit, _ parties: HandshakeParties, card: DeviceKeyCard) -> Data {
        header("pulshade.handshake.init.v2", parties) + card.pin + request.ephemeral + Data(SHA256.hash(data: request.kem))
    }

    /// Covers the ask it answers, and the asking device's keys, so the answer is tied to both devices.
    static func acceptMessage(_ answer: SessionAccept, _ parties: HandshakeParties, card: DeviceKeyCard, askKem: Data,
                              askerPin: Data) -> Data {
        header("pulshade.handshake.accept.v2", parties) + card.pin + askerPin + answer.replyTo + Data(SHA256.hash(data: askKem))
            + answer.ephemeral + Data(SHA256.hash(data: answer.kemCiphertext))
    }

    /// Puts this device's card on an ask and signs it.
    static func signed(_ request: SessionInit, by key: DeviceKey, card: DeviceKeyCard, _ parties: HandshakeParties) throws -> SessionInit {
        var out = request
        out.device = card
        out.sig = try key.sign(initMessage(request, parties, card: card))
        return out
    }

    static func signed(_ answer: SessionAccept, by key: DeviceKey, card: DeviceKeyCard, _ parties: HandshakeParties,
                       askKem: Data, askerPin: Data) throws -> SessionAccept {
        var out = answer
        out.device = card
        out.sig = try key.sign(acceptMessage(answer, parties, card: card, askKem: askKem, askerPin: askerPin))
        return out
    }

    /// The asking device's pin, if its ask carries a card the account signed for that device and the device's own
    /// signature over the ask. Nil means the ask isn't taken.
    static func devicePin(of request: SessionInit, _ parties: HandshakeParties, accountPQ: PQPin) -> Data? {
        guard let card = request.device, let sig = request.sig,
              card.isSigned(by: parties.from, accountPQ: accountPQ, device: parties.device),
              card.checks(sig, for: initMessage(request, parties, card: card)) else { return nil }
        return card.pin
    }

    static func devicePin(of answer: SessionAccept, _ parties: HandshakeParties, accountPQ: PQPin, askKem: Data,
                          askerPin: Data) -> Data? {
        guard let card = answer.device, let sig = answer.sig,
              card.isSigned(by: parties.from, accountPQ: accountPQ, device: parties.device),
              card.checks(sig, for: acceptMessage(answer, parties, card: card, askKem: askKem, askerPin: askerPin)) else { return nil }
        return card.pin
    }
}
