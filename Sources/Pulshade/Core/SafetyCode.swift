import Foundation
import CryptoKit
import SwiftUI

/// The code two people compare in person, made as Signal makes its safety numbers: each person has a fingerprint of
/// their own, worked out from their keys alone, and the code is both of them side by side. Someone in the middle who
/// swaps keys has to make a key whose fingerprint matches the real person's, which a search over keys can't do (about
/// 2^99 tries for the 30 digits each person has, each try 5,200 rounds of SHA-512), rather than make two codes match
/// each other, which a single code made from both people together allowed.
///
/// A person's fingerprint (`fingerprint(of:)`) is SHA-512 iterated 5,200 times over the format version, their account
/// (the fingerprint the app names them by), and their identity keys: the Ed25519 signing key, the X25519 agreement key
/// and a SHA-512 of the ML-KEM-768 and ML-DSA-65 keys. Swapping any of them changes it. The QR code carries both full
/// fingerprints (32 bytes each); the 60 digits are 30 from each.
///
/// Version 4. Versions before it (a single code from both people) never match it: a code from an older app is
/// recognised as such and the person is told the other needs to update (`ScanResult.outdated`).
struct SafetyCode: Equatable {
    /// One side of the code: an account and its identity keys. `pq` is nil while their post-quantum keys aren't known;
    /// a code made then never matches one made with them, and can't mark anyone verified.
    struct Party {
        var account: String
        var signing: Data
        var agreement: Data
        var pq: PQPin? = nil
    }

    static let version: UInt16 = 4
    static let iterations = 5_200
    private static let prefix = "pshv4:"
    /// QR codes from apps before per-person fingerprints.
    private static let oldPrefixes = ["pshv1:", "pshv2:", "pshv3:"]

    /// This device's own fingerprint and the other person's, 32 bytes each.
    let mine: Data
    let theirs: Data

    init(mine: Party, theirs: Party) {
        self.mine = Self.fingerprint(of: mine)
        self.theirs = Self.fingerprint(of: theirs)
    }

    /// A person's own fingerprint: the first 32 bytes of SHA-512 iterated `iterations` times, each round over the round
    /// before and the person's keys (Signal's construction, with all of this app's identity keys in it).
    static func fingerprint(of party: Party) -> Data {
        var keys = Data("pulshade.safety.v4".utf8)
        keys.append(lengthPrefixed(Data(party.account.utf8)))
        keys.append(lengthPrefixed(party.signing))
        keys.append(lengthPrefixed(party.agreement))
        let pq = party.pq.map { Data(SHA512.hash(data: Data("pulshade.safety.pq".utf8) + $0.kem + $0.dsa)) } ?? Data()
        keys.append(lengthPrefixed(pq))
        if let known = memo.value(for: keys) { return known }
        var hash = Data(SHA512.hash(data: withUnsafeBytes(of: version.bigEndian) { Data($0) } + keys))
        for _ in 0..<iterations { hash = Data(SHA512.hash(data: hash + keys)) }
        let out = Data(hash.prefix(32))
        memo.keep(out, for: keys)
        return out
    }

    private static func lengthPrefixed(_ data: Data) -> Data {
        withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) } + data
    }

    /// 30 digits from one fingerprint, in six groups of five: each group is five bytes taken as a number, mod 100,000.
    static func digits(of fingerprint: Data) -> [String] {
        let bytes = Array(fingerprint)
        return (0..<6).map { i in
            let v = bytes[i * 5..<(i * 5 + 5)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return String(format: "%05llu", v % 100_000)
        }
    }

    /// The 60 digits both screens show, in 12 groups: each person's 30, the lower first, so both screens show them in
    /// the same order.
    var digits: [String] {
        let halves = [Self.digits(of: mine), Self.digits(of: theirs)].sorted { $0.joined() < $1.joined() }
        return halves[0] + halves[1]
    }

    /// Both fingerprints in the same order on both screens, for what isn't checked (the emoji and colours).
    private var joined: Data { mine.lexicographicallyPrecedes(theirs) ? mine + theirs : theirs + mine }

    private static let emojiSet = Array("🌙⭐️🔥🌊⚡️🍀🌸🍄🐺🦊🐙🦋🐝🦉🐬🌵🌈❄️🍒🍋🥑🎧🎲🎯🚀🛸⚓️🔮💎🗝🧲🪐🌋🗻🏝🎈🎸🥁🎺🧩🪁🛹🧊🍩🍿🌶🧀🥨🦖🐉🦄🐢🦜🐠🌻🌴🪸🕯💡📡🛰🧭⏳🔔").map(String.init)

    /// Ten emoji for a quick look, made from both fingerprints together: sixty bits, far too few to verify with, so
    /// they never mark anyone verified. Only the QR code or all 60 digits do.
    var emoji: [String] {
        let source = Array(SHA256.hash(data: Data("pulshade.safety.emoji.v4".utf8) + joined))
        let bits = source.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (0..<10).map { Self.emojiSet[Int((bits >> UInt64($0 * 6)) & 63) % Self.emojiSet.count] }
    }

    /// Two colours for the pulse animation, so a mismatch is obvious at a glance.
    var colors: [Color] {
        let bytes = Array(SHA256.hash(data: Data("pulshade.safety.colors.v4".utf8) + joined))
        return [Color(hue: Double(bytes[0]) / 255, saturation: 0.75, brightness: 1),
                Color(hue: Double(bytes[1]) / 255, saturation: 0.8, brightness: 0.95)]
    }

    /// What the QR code carries: the version, then the shower's own fingerprint, then the one they hold for the other.
    var scanText: String { Self.prefix + mine.hex + theirs.hex }

    enum ScanResult: Equatable { case match, mismatch, outdated }

    /// Checks the other person's QR code against this code: theirs must carry their fingerprint as this device has it,
    /// and this device's as they have it.
    func check(scanned text: String) -> ScanResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.oldPrefixes.contains(where: { text.hasPrefix($0) }) { return .outdated }
        guard text.hasPrefix(Self.prefix) else { return .mismatch }
        let body = String(text.dropFirst(Self.prefix.count))
        guard body.count == 128, let bytes = Data(hexString: body) else { return .mismatch }
        return bytes.prefix(32) == theirs && bytes.suffix(32) == mine ? .match : .mismatch
    }

    /// The last few fingerprints worked out: a pulse check's screen is drawn many times, and each is 5,200 rounds.
    private static let memo = Memo()

    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [(Data, Data)] = []

        func value(for keys: Data) -> Data? { lock.withLock { kept.first { $0.0 == keys }?.1 } }

        func keep(_ value: Data, for keys: Data) {
            lock.withLock {
                kept.append((keys, value))
                if kept.count > 8 { kept.removeFirst(kept.count - 8) }
            }
        }
    }
}
