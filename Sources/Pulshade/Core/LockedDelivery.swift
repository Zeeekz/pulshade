import Foundation
import CryptoKit

/// Two ticks while the phone is locked, the way other messengers do it: when a message push arrives, iOS runs
/// Pulshade's notification helper for a few seconds even if the phone is locked or the app was swiped away. The
/// helper collects the new mail without taking it off the relay (the app still collects it properly later), opens
/// only the envelope to see which friend and device each one is from, and tells each of them "this device has it"
/// by naming the envelopes they sent. Their app turns that into a second tick.
///
/// It never opens a message: the chat keys and the messages stay locked until Pulshade is opened. What it needs is
/// in `HelperBundle`, which the app keeps up to date in a Keychain item readable after the phone's first unlock.
/// Shared by the app, its tests and the helper, so nothing here touches Tor, the vault or the chats.
struct HelperBundle: Codable, Equatable {
    struct Device: Codable, Equatable {
        var id: Data
        var sendID: Data
    }

    struct Friend: Codable, Equatable {
        /// Their identity agreement key, which seals the note to them.
        var agreementKey: Data
        /// The mailbox this phone reads them on: mail from anyone else in it isn't theirs.
        var receiveKey: Data
        var devices: [Device]
    }

    /// This account's signing and agreement keys (raw), the two an envelope needs. Not the seed: no recovery code,
    /// no storage key, nothing that opens the vault or a chat.
    var signing: Data
    var agreement: Data
    /// This device's id, so their app knows which device has it.
    var device: Data
    /// The relay, reached directly: the helper can't run Tor.
    var relay: String
    /// Friends by fingerprint.
    var friends: [String: Friend]
    /// Whether to send friends their second tick: off when delivery receipts are off, and then the helper only
    /// collects short mail. Nil (a bundle written before this was added) means yes.
    var confirms: Bool? = nil

    var receiveKeys: [Data] { friends.values.map(\.receiveKey) }
}

enum LockedDelivery {
    /// An envelope as fetched from the relay, with the mailbox it was in.
    struct Mail {
        var receiveKey: Data
        var blob: Data
    }

    /// An envelope as fetched, with what's needed to take it off the relay later.
    struct Fetched {
        var mail: Mail
        var id: UInt64
        var deposited: Date?
    }

    /// Puts the short ones into the phone's inbox, as many as there's room for, and returns those: only they may come
    /// off the relay, and only after this. Big ones (photos, videos, story pieces) are left for Pulshade.
    static func keepShortMail(_ fetched: [Fetched], now: Date = Date()) -> [Fetched] {
        var room = HelperStore.inboxLimit - HelperStore.inboxCount
        var kept: [Fetched] = []
        for item in fetched where item.mail.blob.count <= shortMail && room > 0 {
            let entry = HelperStore.InboxItem(receiveKey: item.mail.receiveKey, blob: item.mail.blob,
                                              deposited: item.deposited, collected: now)
            if HelperStore.keep(entry) { kept.append(item); room -= 1 }
        }
        return kept
    }

    /// A note to one of a friend's devices naming the envelopes of theirs that reached this one.
    struct Note {
        var sendID: Data
        var blob: Data
        var digests: [Data]
    }

    /// The biggest envelope the helper takes off the relay into the phone's inbox: the relay's own line between a
    /// message and a photo or story piece. Bigger ones wait for Pulshade.
    static let shortMail = 64 * 1024

    /// How an envelope is named, by both sides: the first 16 bytes of the SHA-256 of the envelope exactly as it sat
    /// on the relay. The sender works it out when the relay takes it; this phone when it collects it.
    static func digest(of blob: Data) -> Data { Data(SHA256.hash(data: blob).prefix(16)) }

    /// Same as `Identity.fingerprint(of:)`, without needing the rest of `Identity`.
    static func fingerprint(of signingKey: Data) -> String {
        SHA256.hash(data: signingKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The notes to send for this mail: one per friend's device that sent chat messages here and hasn't heard about
    /// them yet. Anything else (an unknown sender, a key setup, something already confirmed) is left alone.
    static func notes(for mail: [Mail], bundle: HelperBundle, confirmed: Set<Data>, now: Date = Date()) -> [Note] {
        guard bundle.confirms != false, let agreement = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bundle.agreement),
              let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: bundle.signing) else { return [] }
        var byDevice: [Data: (friend: HelperBundle.Friend, digests: [Data])] = [:]
        var order: [Data] = []
        for item in mail {
            let digest = digest(of: item.blob)
            guard !confirmed.contains(digest), let header = try? EnvelopeCore.open(item.blob, agreement: agreement),
                  let friend = bundle.friends[fingerprint(of: header.signer)], friend.receiveKey == item.receiveKey,
                  friend.agreementKey == header.agreement, isChatMessage(header.body) else { continue }
            // Their device by the id it gave; an app too old to give one has only the one device.
            let device = friend.devices.first { !header.device.isEmpty && $0.id == header.device }
                ?? (header.device.isEmpty && friend.devices.count == 1 ? friend.devices.first : nil)
            guard let device else { continue }
            if byDevice[device.sendID] == nil { order.append(device.sendID) }
            byDevice[device.sendID, default: (friend, [])].digests.append(digest)
        }
        return order.compactMap { sendID in
            guard let entry = byDevice[sendID],
                  let blob = try? EnvelopeCore.seal(body: collectedBody(entry.digests), framed: false, signing: signing,
                                                    agreement: agreement, device: bundle.device, caps: 0, at: now,
                                                    to: entry.friend.agreementKey) else { return nil }
            return Note(sendID: sendID, blob: blob, digests: entry.digests)
        }
    }

    /// Whether a payload is something sent within a chat (a ratchet message), the only kind worth a note. A frame
    /// only ever carries a ratchet message or a story piece.
    static func isChatMessage(_ body: Data) -> Bool {
        if body.first == Frame.mark { return true }
        return body.starts(with: Data(#"{"ratchet""#.utf8))
    }

    /// `Payload.collected(digests:)` as it travels, written by hand so the helper needs no more of the app.
    static func collectedBody(_ digests: [Data]) -> Data {
        let json: [String: Any] = ["collected": ["digests": digests.map { $0.base64EncodedString() }]]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }
}
