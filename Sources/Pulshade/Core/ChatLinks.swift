import Foundation
import CryptoKit
#if canImport(PulshadeShared)
import PulshadeShared
#endif
#if os(iOS)
import UIKit
#endif

/// A one-time chat link: a throwaway identity's one-use invite plus the moment the chat ends. Whoever
/// opens it joins with a throwaway identity of their own, and both are wiped when the time is up.
struct ChatLink: Equatable {
    var invite: String
    var endsAt: Date

    var text: String {
        // A negative or out-of-range date would trap the conversion; such a link can't be made anyway.
        let seconds = UInt64(max(0, endsAt.timeIntervalSince1970))
        return "pshchat1" + Base32.encode(withUnsafeBytes(of: seconds.bigEndian) { Data($0) } + Data(invite.utf8)).lowercased()
    }

    var link: String { "pulshade://chat/" + text }

    init(invite: String, endsAt: Date) {
        self.invite = invite
        self.endsAt = endsAt
    }

    init?(_ text: String) {
        let clean = scannedPayload(text).lowercased()
        guard clean.hasPrefix("pshchat1"), let raw = Base32.decode(String(clean.dropFirst(8)).uppercased()),
              raw.count > 8 else { return nil }
        let bytes = Data(raw)
        let seconds = bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        // A link decides when its chat ends, and it comes from someone else: keep it within a plausible window
        // (an already-expired one still parses so it can say so; one years away is refused) instead of trusting
        // whatever it claims.
        let now = UInt64(Date().timeIntervalSince1970)
        guard seconds <= now + 8 * 24 * 60 * 60,
              let invite = String(data: bytes.dropFirst(8), encoding: .utf8), Invite(code: invite)?.kind == .contact else { return nil }
        self.invite = invite
        endsAt = Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

/// A one-time chat link as twenty digits to read out or type, so no link has to be sent over another app.
/// The link waits on the relay, sealed, in a mailbox only the digits lead to, and the first device to type
/// them takes it. The digits are stretched slowly, like a passcode, and there are 10^20 of them (about 66 bits), so
/// anyone who can see the sealed link on the relay can't find the digits by trying them offline. Codes of twelve
/// digits (about 40 bits, from apps before this) are no longer used: they could be, with enough hardware.
struct ChatCode: Equatable {
    static let length = 20
    /// The length before, recognised only to say the code is from an older version.
    static let oldLength = 12
    let digits: String

    static func make() -> ChatCode {
        ChatCode(digits: (0..<length).map { _ in String(Int.random(in: 0..<10)) }.joined())
    }

    /// A code from an app that still made twelve digits: its owner needs to update and make a new one.
    static func isOutdated(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)
        return digits.count == oldLength && text.allSatisfy { $0.isNumber || " -".contains($0) }
    }

    private init(digits: String) { self.digits = digits }

    /// Twenty digits, with any spaces or dashes in between.
    init?(_ text: String) {
        let digits = text.filter(\.isNumber)
        guard digits.count == Self.length, text.allSatisfy({ $0.isNumber || " -".contains($0) }) else { return nil }
        self.digits = digits
    }

    /// In groups of four, easy to read out.
    var display: String {
        stride(from: 0, to: digits.count, by: 4).map { i in
            String(digits.dropFirst(i).prefix(4))
        }.joined(separator: " ")
    }

    /// The mailbox and seal behind the digits. Slow on purpose (a fraction of a second): run it off the main thread.
    func keys() -> (receiveKey: Data, seal: SymmetricKey) {
        let master = Vault.stretch(digits, salt: Data("pulshade.chatcode.v2".utf8), iterations: 600_000)
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data(label.utf8), outputByteCount: 32)
        }
        return (derive("pulshade.chatcode.mailbox").withUnsafeBytes { Data($0) }, derive("pulshade.chatcode.seal"))
    }

    /// Every sealed link is the same size, so the relay can't tell anything from it.
    static let sealedSize = 2048

    static func seal(_ link: ChatLink, with key: SymmetricKey) -> Data? {
        let text = Data(link.text.utf8)
        guard text.count <= sealedSize - 2 else { return nil }
        var padded = withUnsafeBytes(of: UInt16(text.count).bigEndian) { Data($0) } + text
        padded.append(Data(count: sealedSize - padded.count))
        return try? ChaChaPoly.seal(padded, using: key).combined
    }

    static func open(_ blob: Data, with key: SymmetricKey) -> ChatLink? {
        guard let box = try? ChaChaPoly.SealedBox(combined: blob), let padded = try? ChaChaPoly.open(box, using: key),
              padded.count >= 2 else { return nil }
        let length = Int(padded[padded.startIndex]) << 8 | Int(padded[padded.startIndex + 1])
        guard length <= padded.count - 2, let text = String(data: padded.dropFirst(2).prefix(length), encoding: .utf8) else { return nil }
        return ChatLink(text)
    }
}

/// A code you made, kept until its chat ends so the sealed link can be taken off the relay if nobody used it.
struct ChatCodeOffer: Codable, Equatable {
    var receiveKey: Data
    var endsAt: Date
}

/// The code inside a scanned pulshade:// link, or the text itself.
func scannedPayload(_ text: String) -> String {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clean.lowercased().hasPrefix("pulshade://"), let last = URL(string: clean)?.lastPathComponent,
          !last.isEmpty, last != "/" else { return clean }
    return last
}
