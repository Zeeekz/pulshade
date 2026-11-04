import Foundation
import CryptoKit

/// Opens a ratchet session between two identities, mixing classic and post-quantum secrets.
///
/// The initiator sends a fresh X25519 key and a fresh ML-KEM-768 key. The responder answers with
/// its own fresh X25519 key and an ML-KEM ciphertext. The session root comes from:
///
///   DH(initiator ephemeral, responder identity)   proves the responder is who they claim
///   DH(initiator identity, responder ephemeral)   proves the initiator is who they claim
///   DH(initiator ephemeral, responder ephemeral)  forward secrecy: both halves are thrown away
///   ML-KEM shared secret                          resists a future quantum computer
///
/// Recording the handshake and later stealing both identity keys, or breaking X25519 with a quantum
/// computer, still isn't enough to recover the root.
struct SessionInit: Codable, Equatable {
    var ephemeral: Data
    var kem: Data
}

struct SessionAccept: Codable, Equatable {
    /// The initiator ephemeral this answers, so stale or crossed handshakes are ignored.
    var replyTo: Data
    var ephemeral: Data
    var kemCiphertext: Data
}

/// The initiator's secrets while it waits for an answer. Deleted once the session opens.
struct PendingHandshake: Codable {
    var ephemeral: Data
    var kemSeed: Data
    var startedAt = Date()

    var publicEphemeral: Data? {
        try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ephemeral).publicKey.rawRepresentation
    }
}

enum Handshake {
    private static let info = Data("pulshade.handshake.v1".utf8)

    static func start() throws -> (PendingHandshake, SessionInit) {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let kem = try MLKEM768.PrivateKey()
        return (PendingHandshake(ephemeral: ephemeral.rawRepresentation, kemSeed: kem.seedRepresentation),
                SessionInit(ephemeral: ephemeral.publicKey.rawRepresentation, kem: kem.publicKey.rawRepresentation))
    }

    /// Responder side. The responder speaks first, using the initiator's ephemeral as its first ratchet key.
    static func accept(_ request: SessionInit, me: Identity, initiatorAgreement: Data) throws -> (Ratchet, SessionAccept) {
        let theirEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.ephemeral)
        let theirIdentity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: initiatorAgreement)
        let encapsulation = try MLKEM768.PublicKey(rawRepresentation: request.kem).encapsulate()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()

        let ikm = try raw(me.agreementKey.sharedSecretFromKeyAgreement(with: theirEphemeral))
            + raw(ephemeral.sharedSecretFromKeyAgreement(with: theirIdentity))
            + raw(ephemeral.sharedSecretFromKeyAgreement(with: theirEphemeral))
            + encapsulation.sharedSecret.withUnsafeBytes { Data($0) }
        let root = deriveRoot(ikm, initiatorEphemeral: request.ephemeral, responderEphemeral: ephemeral.publicKey.rawRepresentation,
                              kem: request.kem, ciphertext: encapsulation.encapsulated)
        let ad = associatedData(initiator: initiatorAgreement, responder: me.card.agreement)
        let ratchet = try Ratchet.sender(root: root, theirRatchet: request.ephemeral, ad: ad)
        return (ratchet, SessionAccept(replyTo: request.ephemeral, ephemeral: ephemeral.publicKey.rawRepresentation,
                                       kemCiphertext: encapsulation.encapsulated))
    }

    /// Initiator side, once the answer arrives.
    static func complete(_ pending: PendingHandshake, _ answer: SessionAccept, me: Identity, responderAgreement: Data) throws -> Ratchet {
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: pending.ephemeral)
        let kem = try MLKEM768.PrivateKey(seedRepresentation: pending.kemSeed, publicKey: nil)
        let theirEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: answer.ephemeral)
        let theirIdentity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: responderAgreement)
        let pq = try kem.decapsulate(answer.kemCiphertext)

        let ikm = try raw(ephemeral.sharedSecretFromKeyAgreement(with: theirIdentity))
            + raw(me.agreementKey.sharedSecretFromKeyAgreement(with: theirEphemeral))
            + raw(ephemeral.sharedSecretFromKeyAgreement(with: theirEphemeral))
            + pq.withUnsafeBytes { Data($0) }
        let root = deriveRoot(ikm, initiatorEphemeral: ephemeral.publicKey.rawRepresentation, responderEphemeral: answer.ephemeral,
                              kem: kem.publicKey.rawRepresentation, ciphertext: answer.kemCiphertext)
        let ad = associatedData(initiator: me.card.agreement, responder: responderAgreement)
        return Ratchet.receiver(root: root, ourRatchet: ephemeral, ad: ad)
    }

    private static func deriveRoot(_ ikm: Data, initiatorEphemeral: Data, responderEphemeral: Data,
                                   kem: Data, ciphertext: Data) -> SymmetricKey {
        // Salting with the whole public transcript ties the root to this exact exchange.
        let transcript = Data(SHA256.hash(data: initiatorEphemeral + responderEphemeral + kem + ciphertext))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: transcript, info: info, outputByteCount: 32)
    }

    private static func associatedData(initiator: Data, responder: Data) -> Data {
        info + initiator + responder
    }

    private static func raw(_ secret: SharedSecret) -> Data {
        secret.withUnsafeBytes { Data($0) }
    }
}
