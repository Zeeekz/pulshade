import Foundation
import CryptoKit

/// Sealed sender envelopes.
///
/// Outside: a fresh X25519 key per message and ChaCha20-Poly1305 ciphertext, so the
/// relay sees random bytes of a few fixed sizes and nothing about who sent them.
/// Inside: the sender's agreement key, then the payload sealed again with a key that mixes in an
/// exchange between the sender's and recipient's identity keys. Only the sender could have made it,
/// so the recipient knows who it's from, but the recipient could have made it too, so it proves
/// nothing to anyone else: there's no signature over what was said.
///
/// The crypto itself is in `EnvelopeCore`, which the notification helper shares; this adds the app's payloads.
enum Envelope {
    /// What this app tells everyone it can read. Bit 0: framed messages (`Frame`), which carry big fields raw.
    /// Bit 1: files kept on the relay (`Attachment`). Bit 2: it answers group messages with a receipt, so a group
    /// tick can wait for it. Builds from before that never do, and aren't waited on. Bit 3: it takes and answers
    /// spare keys (`SpareSlot`), so its friends leave it one. Bit 4: it takes part in groups that share one mailbox
    /// (`GroupSettings`), so a group can be made that way only once everyone in it says so. Bit 5: photos, voice notes
    /// and photo stories can come as a pointer to a sealed copy on the relay (`Payload.clipBlob`), after a message or
    /// story that holds only a tiny preview. Builds from before get them inside the message, as always.
    /// Bit 6: it takes part in channels that share one mailbox, as a follower (hidden from the other followers) or as staff
    /// (`GroupRoster`, a tagged `GroupRekey`).
    /// Bit 7: this build's generation: envelopes are version 3 (identity keys with ML-KEM and ML-DSA halves, `PQKeys`) and its
    /// chats use the sparse post-quantum ratchet (`RatchetHeader.version` 3). Nothing older is read from a peer without it:
    /// it is refused and told to update.
    static let reads: UInt8 = 255

    /// Opened envelope: the payload, who sent it, from which of their devices, and when.
    struct Opened {
        var payload: Payload
        var signer: Data
        /// The sender's agreement key, the one the sealing used and the signing key's binding covers. A card
        /// inside the payload that names any other agreement key isn't the one that proved these keys are theirs.
        var agreement: Data
        var device: Data
        var sentAt: Date
        /// What the sender's app says it can read (0 from apps before this).
        var caps: UInt8 = 0
        /// The sender's post-quantum keys, when this envelope introduced them (they weren't pinned yet) and both signatures on
        /// their card verified. The app pins them.
        var introduced: PQPin?
        /// It arrived as a version 3 envelope, sealed to this account's ML-KEM key.
        var postQuantum = false
        var readsFrames: Bool { caps & 1 == 1 }
        var readsAttachments: Bool { caps & 2 == 2 }
        var readsGroupReceipts: Bool { caps & 4 == 4 }
        var takesSpares: Bool { caps & 8 == 8 }
        var readsSharedGroups: Bool { caps & 16 == 16 }
        var readsMediaBlobs: Bool { caps & 32 == 32 }
        var readsChannels: Bool { caps & 64 == 64 }
        var readsPostQuantumRatchet: Bool { caps & 128 == 128 }
        /// Seals to and opens post-quantum envelopes (identity keys with an ML-KEM key and an ML-DSA key).
        var readsPostQuantum: Bool { caps & 128 == 128 }
    }

    /// Seals to someone whose post-quantum keys are known: version 3 (see `EnvelopeCore.sealPQ`). `framed` sends the
    /// payload's big fields raw, without the base64 that makes a big message nearly twice its size. Anything but a ratchet
    /// message is signed with ML-DSA as well, and `introduce` puts this account's post-quantum keys in the envelope for a
    /// recipient that hasn't got them.
    static func seal(_ payload: Payload, from me: Identity, device: Data = Data(), to recipient: EnvelopeRecipient, framed: Bool = false,
                     introduce: Bool = false) throws -> Data {
        try EnvelopeCore.sealPQ(body: try payload.wire(framed: framed), signing: me.signingKey, agreement: me.agreementKey, pq: me.pq,
                                sign: !payload.isRatchet, introduce: introduce, device: device, caps: reads, at: RelayClock.now,
                                to: recipient)
    }

    /// Seals to someone whose post-quantum keys aren't known yet, the one way left to a classical envelope: only for the
    /// payloads that carry this account's post-quantum card (`Payload.carriesPQCard`), which is what lets everything after
    /// them be sealed properly. What it hides from a recorder who breaks X25519 later is the one envelope's sender and contents.
    static func sealIntroduction(_ payload: Payload, from me: Identity, device: Data = Data(), to agreementKey: Data) throws -> Data {
        precondition(payload.carriesPQCard)
        return try EnvelopeCore.seal(body: try payload.wire(framed: false), framed: false, signing: me.signingKey,
                                     agreement: me.agreementKey, device: device, caps: reads, at: RelayClock.now, to: agreementKey)
    }

    /// Returns the payload and the sender's signing key.
    static func open(_ blob: Data, with me: Identity) throws -> (Payload, Data) {
        let opened = try openFull(blob, with: me)
        return (opened.payload, opened.signer)
    }

    /// `known` gives the post-quantum keys a signer is pinned to. Refuses (`EnvelopeRefusal`) every classical envelope
    /// except an introduction from someone not pinned whose card checks out (or, from someone pinned, a request with exactly
    /// their pinned card), and every envelope without a signature that is
    /// not a ratchet message.
    static func openFull(_ blob: Data, with me: Identity, known: (Data) -> PQPin? = { _ in nil }) throws -> Opened {
        if blob.first == EnvelopeCore.versionPQ {
            let opened = try EnvelopeCore.openPQ(blob, agreement: me.agreementKey, pq: me.pq, known: known)
            let payload = try Payload.fromWire(opened.header.body)
            guard payload.isRatchet || opened.signed else { throw EnvelopeError.badSignature }
            let h = opened.header
            return Opened(payload: payload, signer: h.signer, agreement: h.agreement, device: h.device, sentAt: h.sentAt, caps: h.caps,
                          introduced: opened.introduced, postQuantum: true)
        }
        let header = try EnvelopeCore.open(blob, agreement: me.agreementKey)
        let payload = try Payload.fromWire(header.body)
        guard let pin = payload.introducedCard?.verified(signer: header.signer, agreement: header.agreement)
        else { throw EnvelopeRefusal.classical(signer: header.signer, sentAt: header.sentAt) }
        // Someone already pinned may send a request this way, for the one case where they lost our keys (a reinstall without
        // the backup): the card must be the pinned keys, and the app never acts on it by itself (it waits to be accepted).
        // The same goes for a plain introduction (they lost our keys, or this is another of their devices that hasn't been told
        // yet): it changes nothing but being answered with ours. Anything else classical from them is a downgrade.
        if let pinned = known(header.signer) {
            guard pinned == pin, payload.isRequest || payload.isIntroduction else { throw EnvelopeRefusal.classical(signer: header.signer, sentAt: header.sentAt) }
            return Opened(payload: payload, signer: header.signer, agreement: header.agreement, device: header.device,
                          sentAt: header.sentAt, caps: header.caps)
        }
        return Opened(payload: payload, signer: header.signer, agreement: header.agreement, device: header.device,
                      sentAt: header.sentAt, caps: header.caps, introduced: pin)
    }

    static func paddedSize(of count: Int) -> Int { EnvelopeCore.paddedSize(of: count) }
}
