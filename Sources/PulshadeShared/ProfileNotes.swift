import Foundation
import CryptoKit

/// A piece of text on a profile, read by tapping it. Public notes are plain text for anyone who opens the profile.
/// A locked note is encrypted on the owner's device with a password only they and the people they tell know: no
/// server, and not Pulshade, ever has the password or the words. A note can instead be for chosen contacts only: plain
/// text that is sent just to them, over their own encrypted chats, so none of them needs a password.
public struct ProfileNote: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Always readable, even on a locked note, so people know what they'd be unlocking.
    public var title: String
    /// The words, on a public note.
    public var text: String?
    /// The encrypted words, on a locked note (see `NoteSeal`).
    public var sealed: Data?
    /// Fingerprints of the contacts who may read this note, on the owner's devices only. Nil means everyone who sees the
    /// profile (a public or locked note); a list means only those contacts are sent it. Never sent to anyone.
    public var sharedWith: [String]?
    /// Set on a note someone received that was sent to them alone, so it can say so. Only a label: it grants nothing.
    public var restricted: Bool?

    public var isLocked: Bool { sealed != nil }
    /// Sent to chosen contacts only.
    public var isRestricted: Bool { sharedWith != nil || restricted == true }

    public static let maxCount = 8
    public static let maxTitle = 60
    public static let maxText = 8000
    /// Total size of everything sent for notes on one profile.
    public static let maxTotalBytes = 64 * 1024

    public init(id: String, title: String, text: String? = nil, sealed: Data? = nil, sharedWith: [String]? = nil,
                restricted: Bool? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.sealed = sealed
        self.sharedWith = sharedWith
        self.restricted = restricted
    }

    /// Never fails on one odd entry, so a newer app's profile still opens in an older one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        sealed = try? c.decodeIfPresent(Data.self, forKey: .sealed)
        sharedWith = try? c.decodeIfPresent([String].self, forKey: .sharedWith)
        restricted = try? c.decodeIfPresent(Bool.self, forKey: .restricted)
    }

    private enum CodingKeys: String, CodingKey { case id, title, text, sealed, sharedWith, restricted }

    public static func newID() -> String { (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    /// A short line under the title: how big it is, or that it's locked.
    public var subtitle: String {
        if isLocked { return "Locked with a password" }
        let words = (text ?? "").split { $0.isWhitespace }.count
        let size = words == 1 ? "1 word" : "\(words) words"
        if restricted == true { return "Just for you · \(size)" }
        if let sharedWith { return sharedWith.count == 1 ? "1 contact · \(size)" : "\(sharedWith.count) contacts · \(size)" }
        return size
    }

    // MARK: Cleaning what's typed or received

    /// Plain text with nothing that could disguise it: no control characters except new lines and tabs, no hidden or
    /// direction-changing marks. Nil if it's empty or too long.
    public static func cleanText(_ raw: String) -> String? {
        let kept = raw.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            return !ProfileLinkKind.hasHidden(String(scalar))
        }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxText else { return nil }
        return text
    }

    public static func cleanTitle(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...maxTitle).contains(t.count), !ProfileLinkKind.hasHidden(t), !t.contains("\n") else { return nil }
        return t
    }

    /// Makes a public note, or nil if the title or text isn't acceptable.
    public static func publicNote(id: String = newID(), title: String, text: String) -> ProfileNote? {
        guard let title = cleanTitle(title), let text = cleanText(text) else { return nil }
        return ProfileNote(id: id, title: title, text: text)
    }

    /// Makes a note that only the chosen contacts are sent. Plain text: they read it without a password, because nobody
    /// else is ever sent it. Nil if the title or text isn't acceptable or nobody is chosen.
    public static func contactsNote(id: String = newID(), title: String, text: String, contacts: [String]) -> ProfileNote? {
        guard let title = cleanTitle(title), let text = cleanText(text) else { return nil }
        let chosen = cleanAudience(contacts)
        guard !chosen.isEmpty else { return nil }
        return ProfileNote(id: id, title: title, text: text, sharedWith: chosen)
    }

    /// Fingerprints only (32 hex characters), once each, in order, and no more than the app has room for.
    public static func cleanAudience(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { $0.count == 32 && $0.allSatisfy(\.isHexDigit) && seen.insert($0).inserted }.prefix(maxAudience).map { $0 }
    }
    public static let maxAudience = 500

    /// Makes a locked note: the text is encrypted with the password, which must pass `NoteSeal.passwordProblem`.
    /// Slow on purpose (it is what makes guessing passwords slow), so call it off the main thread.
    public static func lockedNote(id: String = newID(), title: String, text: String, password: String,
                                  logN: Int = NoteSeal.logN) -> ProfileNote? {
        guard let title = cleanTitle(title), let text = cleanText(text), NoteSeal.passwordProblem(password) == nil,
              let sealed = NoteSeal.seal(text, password: password, aad: NoteSeal.aad(id: id, title: title), logN: logN) else { return nil }
        return ProfileNote(id: id, title: title, sealed: sealed)
    }

    /// The words of a locked note, if the password is right. Slow on purpose: call it off the main thread.
    public func open(password: String) -> String? {
        guard let sealed else { return text }
        return NoteSeal.open(sealed, password: password, aad: NoteSeal.aad(id: id, title: title))
    }

    /// Valid notes only, within the limits, one per id. Run on everything sent and everything received. Who a note is
    /// for is the owner's own business, so it is kept only when `keepAudience` is true (the owner's profile, and the
    /// owner's other devices); everywhere else it is dropped, and a note can't claim to be restricted without a list.
    public static func cleaned(_ notes: [ProfileNote]?, keepAudience: Bool = false) -> [ProfileNote] {
        var seen = Set<String>(), out: [ProfileNote] = [], bytes = 0
        for note in (notes ?? []).prefix(maxCount * 2) {
            guard note.id.count == 16, note.id.allSatisfy(\.isHexDigit), let title = cleanTitle(note.title), seen.insert(note.id).inserted
            else { continue }
            var clean = ProfileNote(id: note.id, title: title)
            if keepAudience, let list = note.sharedWith {
                let chosen = cleanAudience(list)
                guard !chosen.isEmpty, note.sealed == nil else { continue }
                clean.sharedWith = chosen
            } else if !keepAudience, note.restricted == true, note.sealed == nil {
                clean.restricted = true
            }
            if let sealed = note.sealed {
                guard note.text == nil, NoteSeal.looksSealed(sealed) else { continue }
                clean.sealed = sealed
                bytes += sealed.count
            } else {
                guard let text = note.text, let t = cleanText(text) else { continue }
                clean.text = t
                bytes += t.utf8.count
            }
            bytes += title.utf8.count
            guard bytes <= maxTotalBytes else { break }
            out.append(clean)
            if out.count == maxCount { break }
        }
        return out
    }
}

extension ProfileNote {
    /// What one contact is sent: every note meant for everyone, plus the ones this contact was chosen for (marked so
    /// they can tell). With no fingerprint, as for the public listing, only the notes for everyone. The list of
    /// chosen contacts is never included.
    public static func notes(_ notes: [ProfileNote]?, sentTo fingerprint: String?) -> [ProfileNote]? {
        let mine: [ProfileNote] = cleaned(notes, keepAudience: true).compactMap { note in
            guard let chosen = note.sharedWith else { return note }
            guard let fingerprint, chosen.contains(fingerprint) else { return nil }
            var sent = note
            sent.sharedWith = nil
            sent.restricted = true
            return sent
        }
        return mine.isEmpty ? nil : mine
    }
}

/// Encrypting text with a password: scrypt (memory-hard, so guessing is slow even on graphics cards) makes the key,
/// ChaCha20-Poly1305 seals the words. The title and note id are bound in, so a sealed note can't be moved under another
/// title. The text is padded so its length gives little away.
///
/// A locked note can be copied by anyone who can see the profile and guessed at on their own computer, so the password
/// has to be strong: it is checked, and a random one is offered.
public enum NoteSeal {
    static let version: UInt8 = 1
    /// scrypt cost: 2^17 blocks of 1 KiB (128 MiB) per guess, about a fifth of a second on a Mac.
    public static let logN = 17
    static let r = 8, p = 1

    public static func aad(id: String, title: String) -> Data { Data("pulshade.note.v1|\(id)|\(title)".utf8) }

    // MARK: Passwords

    private static let common: Set<String> = ["password1234", "passwordpassword", "123456789012", "1234567890123", "qwertyuiop12",
        "qwertyuiopasdf", "iloveyou1234", "letmein12345", "administrator", "abcdefghijkl", "aaaaaaaaaaaa", "welcome12345"]

    /// Why a password isn't good enough, or nil if it is: at least 12 characters, not a common one, not mostly one
    /// character.
    public static func passwordProblem(_ password: String) -> String? {
        let p = password.precomposedStringWithCompatibilityMapping
        guard p.count >= 12 else { return "Use at least 12 characters. Anyone who can see this note can try passwords on it." }
        guard Set(p).count >= 6 else { return "That has too few different characters." }
        guard !common.contains(p.lowercased()) else { return "That is a very common password." }
        return nil
    }

    /// A random password worth about 100 bits, in groups so it's easy to copy: `kx7m-q2tf-hn8c-wb4r-zd9p`.
    public static func generatePassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return (0..<5).map { _ in String((0..<4).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }) }.joined(separator: "-")
    }

    // MARK: Sealing

    /// `version, logN, r, p, salt (16), nonce + sealed text + tag`.
    public static func seal(_ text: String, password: String, aad: Data, logN: Int = NoteSeal.logN) -> Data? {
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess,
              let key = deriveKey(password, salt: salt, logN: logN) else { return nil }
        let words = Array(text.utf8)
        var padded = [UInt8](repeating: 0, count: 4)
        padded.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(words.count).bigEndian, as: UInt32.self) }
        padded += words
        padded += [UInt8](repeating: 0, count: (512 - padded.count % 512) % 512)
        guard let box = try? ChaChaPoly.seal(padded, using: key, authenticating: aad) else { return nil }
        return Data([version, UInt8(logN), UInt8(r), UInt8(p)]) + Data(salt) + box.combined
    }

    /// The text, or nil for a wrong password, a changed title, or anything that has been tampered with.
    public static func open(_ blob: Data, password: String, aad: Data) -> String? {
        guard looksSealed(blob) else { return nil }
        let b = Array(blob)
        guard let key = deriveKey(password, salt: Array(b[4..<20]), logN: Int(b[1])),
              let box = try? ChaChaPoly.SealedBox(combined: Data(b[20...])),
              let padded = try? ChaChaPoly.open(box, using: key, authenticating: aad), padded.count >= 4 else { return nil }
        let length = Int(UInt32(bigEndian: padded.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard length <= padded.count - 4 else { return nil }
        return String(data: padded.dropFirst(4).prefix(length), encoding: .utf8)
    }

    /// The right shape and cost settings. Costs outside this range are refused, so a note someone sends can't make
    /// your device spend a lot of memory or time.
    public static func looksSealed(_ blob: Data) -> Bool {
        let b = Array(blob.prefix(4))
        return blob.count >= 4 + 16 + 12 + 16 + 512 && blob.count <= 40 * 1024 && b[0] == version
            && (14...17).contains(Int(b[1])) && Int(b[2]) == r && Int(b[3]) == p
    }

    static func deriveKey(_ password: String, salt: [UInt8], logN: Int) -> SymmetricKey? {
        let pw = Array(password.precomposedStringWithCompatibilityMapping.utf8)
        guard let key = Scrypt.derive(password: pw, salt: salt, n: 1 << logN, r: r, p: p, length: 32) else { return nil }
        return SymmetricKey(data: key)
    }
}

/// scrypt (RFC 7914), written out so the app needs no outside code for it.
public enum Scrypt {
    public static func derive(password: [UInt8], salt: [UInt8], n: Int, r: Int, p: Int, length: Int) -> [UInt8]? {
        guard n > 1, n & (n - 1) == 0, r > 0, p > 0, n <= 1 << 20, r <= 16, p <= 16 else { return nil }
        let blockWords = 32 * r
        var b = pbkdf2(password: password, salt: salt, length: p * 128 * r)
        let v = UnsafeMutablePointer<UInt32>.allocate(capacity: n * blockWords)
        let x = UnsafeMutablePointer<UInt32>.allocate(capacity: blockWords)
        let y = UnsafeMutablePointer<UInt32>.allocate(capacity: blockWords)
        let t = UnsafeMutablePointer<UInt32>.allocate(capacity: 16)
        defer {
            // The big table held key material: wipe it before giving the memory back.
            v.update(repeating: 0, count: n * blockWords)
            x.update(repeating: 0, count: blockWords); y.update(repeating: 0, count: blockWords)
            v.deallocate(); x.deallocate(); y.deallocate(); t.deallocate()
        }
        for i in 0..<p {
            b.withUnsafeMutableBytes { raw in
                let words = raw.baseAddress!.advanced(by: i * 128 * r).assumingMemoryBound(to: UInt32.self)
                for k in 0..<blockWords { x[k] = UInt32(littleEndian: words[k]) }
                for j in 0..<n {
                    (v + j * blockWords).update(from: x, count: blockWords)
                    blockMix(x, y, t, r)
                }
                for _ in 0..<n {
                    let j = Int(x[(2 * r - 1) * 16]) & (n - 1)
                    let vj = v + j * blockWords
                    for k in 0..<blockWords { x[k] ^= vj[k] }
                    blockMix(x, y, t, r)
                }
                for k in 0..<blockWords { words[k] = x[k].littleEndian }
            }
        }
        return pbkdf2(password: password, salt: b, length: length)
    }

    /// PBKDF2-HMAC-SHA256 with one round, which is all scrypt asks for.
    private static func pbkdf2(password: [UInt8], salt: [UInt8], length: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var out: [UInt8] = []
        var block: UInt32 = 1
        while out.count < length {
            var message = salt
            withUnsafeBytes(of: block.bigEndian) { message += $0 }
            out += Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
            block += 1
        }
        return Array(out.prefix(length))
    }

    @inline(__always) private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { x << n | x >> (32 - n) }

    private static func salsa8(_ b: UnsafeMutablePointer<UInt32>) {
        var x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7]
        var x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15]
        for _ in 0..<4 {
            x4 ^= rotl(x0 &+ x12, 7); x8 ^= rotl(x4 &+ x0, 9); x12 ^= rotl(x8 &+ x4, 13); x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7); x13 ^= rotl(x9 &+ x5, 9); x1 ^= rotl(x13 &+ x9, 13); x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7); x2 ^= rotl(x14 &+ x10, 9); x6 ^= rotl(x2 &+ x14, 13); x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7); x7 ^= rotl(x3 &+ x15, 9); x11 ^= rotl(x7 &+ x3, 13); x15 ^= rotl(x11 &+ x7, 18)
            x1 ^= rotl(x0 &+ x3, 7); x2 ^= rotl(x1 &+ x0, 9); x3 ^= rotl(x2 &+ x1, 13); x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7); x7 ^= rotl(x6 &+ x5, 9); x4 ^= rotl(x7 &+ x6, 13); x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7); x8 ^= rotl(x11 &+ x10, 9); x9 ^= rotl(x8 &+ x11, 13); x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9); x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
        }
        b[0] &+= x0; b[1] &+= x1; b[2] &+= x2; b[3] &+= x3; b[4] &+= x4; b[5] &+= x5; b[6] &+= x6; b[7] &+= x7
        b[8] &+= x8; b[9] &+= x9; b[10] &+= x10; b[11] &+= x11; b[12] &+= x12; b[13] &+= x13; b[14] &+= x14; b[15] &+= x15
    }

    /// `b` is 2r blocks of 16 words; `y` is the same size, for scratch; `x` is 16 words of scratch.
    private static func blockMix(_ b: UnsafeMutablePointer<UInt32>, _ y: UnsafeMutablePointer<UInt32>,
                                 _ x: UnsafeMutablePointer<UInt32>, _ r: Int) {
        x.update(from: b + (2 * r - 1) * 16, count: 16)
        for i in 0..<2 * r {
            for k in 0..<16 { x[k] ^= b[i * 16 + k] }
            salsa8(x)
            (y + i * 16).update(from: x, count: 16)
        }
        for i in 0..<r {
            (b + i * 16).update(from: y + (2 * i) * 16, count: 16)
            (b + (r + i) * 16).update(from: y + (2 * i + 1) * 16, count: 16)
        }
    }
}
