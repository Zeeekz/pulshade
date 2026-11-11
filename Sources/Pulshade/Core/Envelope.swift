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
    static let reads: UInt8 = 63

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
        var readsFrames: Bool { caps & 1 == 1 }
        var readsAttachments: Bool { caps & 2 == 2 }
        var readsGroupReceipts: Bool { caps & 4 == 4 }
        var takesSpares: Bool { caps & 8 == 8 }
        var readsSharedGroups: Bool { caps & 16 == 16 }
        var readsMediaBlobs: Bool { caps & 32 == 32 }
    }

    /// `framed` sends the payload and the inside of the envelope in frames, without the base64 that makes a big
    /// message nearly twice its size. Only for a recipient whose app reads them: an older one can't open it.
    static func seal(_ payload: Payload, from me: Identity, device: Data = Data(), to agreementKey: Data, framed: Bool = false) throws -> Data {
        try EnvelopeCore.seal(body: try payload.wire(framed: framed), framed: framed, signing: me.signingKey,
                              agreement: me.agreementKey, device: device, caps: reads, at: RelayClock.now, to: agreementKey)
    }

    /// Returns the payload and the sender's signing key.
    static func open(_ blob: Data, with me: Identity) throws -> (Payload, Data) {
        let opened = try openFull(blob, with: me)
        return (opened.payload, opened.signer)
    }

    static func openFull(_ blob: Data, with me: Identity) throws -> Opened {
        let header = try EnvelopeCore.open(blob, agreement: me.agreementKey)
        return Opened(payload: try Payload.fromWire(header.body), signer: header.signer, agreement: header.agreement,
                      device: header.device, sentAt: header.sentAt, caps: header.caps)
    }

    static func paddedSize(of count: Int) -> Int { EnvelopeCore.paddedSize(of: count) }
}
