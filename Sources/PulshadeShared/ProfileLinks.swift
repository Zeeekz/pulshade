import Foundation
import CryptoKit

/// One thing on a profile that shows up as an icon: a link to a social account or site, or a crypto wallet address.
/// Leave a field empty and it has no icon. The value is always stored in its checked, canonical form.
public struct ProfileLink: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var kind: ProfileLinkKind
    /// A web address (`https://...`) for links, the address itself for wallets, an npub for Nostr.
    public var value: String
    /// Only for `.custom`: what the link is called. Shown next to the real domain.
    public var label: String?

    public var id: String { kind.rawValue + (kind == .custom ? ":" + value : "") }

    public init(kind: ProfileLinkKind, value: String, label: String? = nil) {
        self.kind = kind
        self.value = value
        self.label = label
    }

    /// Never fails on one odd entry: a kind this version doesn't know becomes `.unknown` and is dropped later,
    /// so a newer app's profile still opens in an older one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(ProfileLinkKind.self, forKey: .kind)) ?? .unknown
        value = (try? c.decode(String.self, forKey: .value)) ?? ""
        label = try? c.decodeIfPresent(String.self, forKey: .label)
    }

    private enum CodingKeys: String, CodingKey { case kind, value, label }

    /// Checks and cleans what someone typed. Nil means it isn't acceptable for that kind.
    public static func make(_ kind: ProfileLinkKind, from raw: String, label: String? = nil) -> ProfileLink? {
        guard raw.utf8.count <= 1200, let value = kind.normalize(raw) else { return nil }
        if kind == .custom {
            guard let label = ProfileLinkKind.cleanLabel(label ?? ""), !label.isEmpty else { return nil }
            return ProfileLink(kind: kind, value: value, label: label)
        }
        return ProfileLink(kind: kind, value: value)
    }

    /// The link's web address, if tapping it should open one. Wallets and Nostr keys are shown instead.
    public var url: URL? { kind.opensURL ? URL(string: value) : nil }

    /// The domain a link really goes to, shown next to a custom label so it can't pass for somewhere else.
    public var domain: String? { url?.host() }

    /// The line under a link's name: `@octocat`, `@name@instance.social`, a domain, or a shortened address.
    public var subtitle: String {
        guard kind.opensURL, let url = url else { return shortValue }
        let host = url.host() ?? ""
        let last = url.pathComponents.last { $0 != "/" } ?? ""
        let name = last.hasPrefix("@") ? String(last.dropFirst()) : last
        switch kind {
        case .x, .instagram, .youtube, .tiktok, .github, .telegram, .twitch: return name.isEmpty ? host : "@" + name
        case .mastodon: return name.isEmpty ? host : "@\(name)@\(host)"
        default: return host
        }
    }

    /// A short form for an icon's hover text: `bc1qw5...kv8f3t4`.
    public var shortValue: String {
        guard !kind.opensURL, value.count > 16 else { return domain ?? value }
        return value.prefix(8) + "..." + value.suffix(6)
    }

    /// Keeps a list safe to store or send: valid entries only, one per kind (custom links may repeat), at most `limit`.
    public static func cleaned(_ links: [ProfileLink]?, limit: Int = maxCount) -> [ProfileLink] {
        var seen = Set<String>(), out: [ProfileLink] = []
        for link in (links ?? []).prefix(limit * 2) {
            guard let again = make(link.kind, from: link.value, label: link.label), seen.insert(again.id).inserted else { continue }
            out.append(again)
            if out.count == limit { break }
        }
        return out
    }

    public static let maxCount = 24
}

public enum ProfileLinkKind: String, Codable, CaseIterable, Sendable {
    // Links
    case website, x, instagram, youtube, tiktok, github, telegram, discord, nostr, mastodon, linkedin, twitch, custom
    // Wallets
    case bitcoin, monero, ethereum, litecoin, solana, lightning
    /// A kind from a newer version of the app. Never shown, never saved.
    case unknown

    public static var allCases: [ProfileLinkKind] { [.website, .x, .instagram, .youtube, .tiktok, .github, .telegram, .discord, .nostr,
        .mastodon, .linkedin, .twitch, .custom, .bitcoin, .monero, .ethereum, .litecoin, .solana, .lightning] }

    public var isWallet: Bool {
        switch self {
        case .bitcoin, .monero, .ethereum, .litecoin, .solana, .lightning: true
        default: false
        }
    }

    public static var links: [ProfileLinkKind] { allCases.filter { !$0.isWallet } }
    public static var wallets: [ProfileLinkKind] { allCases.filter(\.isWallet) }

    public var title: String {
        switch self {
        case .website: "Website"
        case .x: "X"
        case .instagram: "Instagram"
        case .youtube: "YouTube"
        case .tiktok: "TikTok"
        case .github: "GitHub"
        case .telegram: "Telegram"
        case .discord: "Discord"
        case .nostr: "Nostr"
        case .mastodon: "Mastodon"
        case .linkedin: "LinkedIn"
        case .twitch: "Twitch"
        case .custom: "Custom link"
        case .bitcoin: "Bitcoin"
        case .monero: "Monero"
        case .ethereum: "Ethereum"
        case .litecoin: "Litecoin"
        case .solana: "Solana"
        case .lightning: "Lightning"
        case .unknown: "Unknown"
        }
    }

    /// A built-in system symbol for the icon, so the app ships no brand artwork and loads nothing from the network.
    public var symbol: String {
        switch self {
        case .website: "globe"
        case .x: "xmark"
        case .instagram: "camera"
        case .youtube: "play.rectangle.fill"
        case .tiktok: "music.note"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .telegram: "paperplane.fill"
        case .discord: "bubble.left.and.bubble.right.fill"
        case .nostr: "key.horizontal.fill"
        case .mastodon: "text.bubble.fill"
        case .linkedin: "briefcase.fill"
        case .twitch: "tv"
        case .custom: "link"
        case .bitcoin: "bitcoinsign"
        case .monero: "m.circle.fill"
        case .ethereum: "diamond.fill"
        case .litecoin: "l.circle.fill"
        case .solana: "s.circle.fill"
        case .lightning: "bolt.fill"
        case .unknown: "questionmark"
        }
    }

    /// Whether tapping it opens a web page (after asking), or shows a value to copy.
    public var opensURL: Bool { !isWallet && self != .nostr && self != .unknown }

    /// What the field asks for.
    public var prompt: String {
        switch self {
        case .website, .custom: "https://example.com"
        case .mastodon: "@name@instance.social"
        case .nostr: "npub1..."
        case .bitcoin: "bc1... or 1... or 3..."
        case .monero: "4... or 8..."
        case .ethereum: "0x..."
        case .litecoin: "ltc1... or L... or M..."
        case .solana: "Address"
        case .lightning: "name@wallet.com"
        case .unknown: ""
        default: "Username or link"
        }
    }

    // MARK: Checking

    /// The canonical value for what someone typed, or nil if it isn't valid for this kind.
    public func normalize(_ raw: String) -> String? {
        guard let text = Self.clean(raw) else { return nil }
        switch self {
        case .website, .custom: return Self.httpsURL(text, hosts: nil)
        case .x: return Self.social(text, hosts: ["x.com", "twitter.com"], base: "https://x.com/")
        case .instagram: return Self.social(text, hosts: ["instagram.com"], base: "https://instagram.com/")
        case .youtube: return Self.social(text, hosts: ["youtube.com", "youtu.be"], base: "https://youtube.com/@")
        case .tiktok: return Self.social(text, hosts: ["tiktok.com"], base: "https://tiktok.com/@")
        case .github: return Self.social(text, hosts: ["github.com"], base: "https://github.com/")
        case .telegram: return Self.social(text, hosts: ["t.me", "telegram.me"], base: "https://t.me/")
        case .discord: return Self.httpsURL(text, hosts: ["discord.gg", "discord.com"])
        case .linkedin: return Self.httpsURL(text, hosts: ["linkedin.com"])
        case .twitch: return Self.social(text, hosts: ["twitch.tv"], base: "https://twitch.tv/")
        case .mastodon: return Self.mastodon(text)
        case .nostr:
            // NIP-19: lowercase, plain Bech32 (not Bech32m), 63 characters.
            return text == text.lowercased() && text.count == 63 && WalletCheck.bech32(text, hrps: ["npub"], allowM: false) ? text : nil
        case .unknown: return nil
        case .bitcoin: return WalletCheck.bitcoin(text) ? text : nil
        case .litecoin: return WalletCheck.litecoin(text) ? text : nil
        case .monero: return WalletCheck.monero(text) ? text : nil
        case .ethereum: return WalletCheck.ethereum(text) ? text : nil
        case .solana: return WalletCheck.solana(text) ? text : nil
        case .lightning: return WalletCheck.lightningAddress(text)
        }
    }

    // MARK: Text helpers

    /// Characters that can make text look like something else: controls, bidirectional overrides, zero-width marks.
    static let hidden: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2060, 0xFEFF, 0x00AD, 0x061C,
                                              0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

    public static func hasHidden(_ s: String) -> Bool {
        let bad: Set<Unicode.GeneralCategory> = [.control, .format, .unassigned, .privateUse, .surrogate, .lineSeparator, .paragraphSeparator]
        return s.unicodeScalars.contains {
            bad.contains($0.properties.generalCategory) || hidden.contains($0.value) || $0.properties.isVariationSelector
                || $0.properties.isDefaultIgnorableCodePoint || $0.properties.isBidiControl
        }
    }

    /// Trims, and refuses anything too long or containing hidden characters.
    static func clean(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...300).contains(text.count), !hasHidden(text), !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }

    /// A custom link's name: plain text, at most 30 characters.
    public static func cleanLabel(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 30, !hasHidden(text) else { return nil }
        return text
    }

    /// `https` only: no other scheme, no `user@` in front of the host, no port, and, when `hosts` is given, only
    /// those domains or their subdomains. The host is lowercased and must be plain ASCII letters, digits and dashes.
    static func httpsURL(_ text: String, hosts: [String]?) -> String? {
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased(), isPlainHost(host) else { return nil }
        if let hosts, !hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return nil }
        var clean = parts
        clean.scheme = "https"
        clean.host = host
        clean.fragment = nil
        return clean.string
    }

    public static func isPlainHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // The last part must be a real ending (has a letter): "192.168.0.1" and "0x7f.0.0.1" are not names.
        guard let last = labels.last, last.contains(where: \.isLetter), !last.hasPrefix("0x") else { return false }
        return labels.count >= 2 && host.count <= 253 && labels.allSatisfy {
            (1...63).contains($0.count) && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// A username (`@name` or `name`) turned into the network's address, or a link on that network.
    static func social(_ text: String, hosts: [String], base: String) -> String? {
        if text.lowercased().hasPrefix("https://") { return httpsURL(text, hosts: hosts) }
        let name = text.hasPrefix("@") ? String(text.dropFirst()) : text
        guard (1...40).contains(name.count),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-") })
        else { return nil }
        return base + name
    }

    /// `@name@instance.social` or a profile link on any instance.
    static func mastodon(_ text: String) -> String? {
        if text.lowercased().hasPrefix("https://") { return httpsURL(text, hosts: nil) }
        let pieces = text.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].isEmpty, !pieces[1].isEmpty,
              pieces[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        guard isPlainHost(pieces[2].lowercased()) else { return nil }
        return httpsURL("https://" + pieces[2] + "/@" + pieces[1], hosts: nil)
    }
}

/// Address checks for each coin. They catch typos and wrong-network addresses; they can't say the address is yours.
public enum WalletCheck {
    // MARK: Bitcoin and Litecoin

    public static func bitcoin(_ s: String) -> Bool {
        bech32(s.lowercased() == s || s.uppercased() == s ? s.lowercased() : "", hrps: ["bc"], segwitOnly: true)
            || base58Check(s, versions: [0x00, 0x05])
    }

    public static func litecoin(_ s: String) -> Bool {
        bech32(s.lowercased() == s || s.uppercased() == s ? s.lowercased() : "", hrps: ["ltc"], segwitOnly: true)
            || base58Check(s, versions: [0x30, 0x32])
    }

    // MARK: Ethereum

    /// `0x` and 40 hex digits. All lowercase or all uppercase is accepted; mixed case must pass the EIP-55 checksum.
    public static func ethereum(_ s: String) -> Bool {
        guard s.hasPrefix("0x"), s.count == 42 else { return false }
        let hex = String(s.dropFirst(2))
        guard hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return false }
        if hex == hex.lowercased() || hex == hex.uppercased() { return true }
        return eip55(hex.lowercased()) == hex
    }

    public static func eip55(_ lowerHex: String) -> String {
        let hash = Keccak.hash256(Array(lowerHex.utf8))
        var out = ""
        for (i, ch) in lowerHex.enumerated() {
            let nibble = i % 2 == 0 ? hash[i / 2] >> 4 : hash[i / 2] & 0x0f
            out.append(ch.isLetter && nibble >= 8 ? Character(ch.uppercased()) : ch)
        }
        return out
    }

    // MARK: Solana

    /// A Solana address is 32 bytes in base58.
    public static func solana(_ s: String) -> Bool {
        (32...44).contains(s.count) && base58Decode(s)?.count == 32
    }

    // MARK: Lightning address

    /// `name@domain`, like an email address; returned lowercased.
    public static func lightningAddress(_ s: String) -> String? {
        let pieces = s.lowercased().split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2, (1...64).contains(pieces[0].count),
              pieces[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-+".contains($0)) }),
              ProfileLinkKind.isPlainHost(String(pieces[1])) else { return nil }
        return pieces.joined(separator: "@")
    }

    // MARK: Monero

    /// A mainnet address: standard (starts 4), subaddress (starts 8) or integrated, with its Keccak checksum.
    public static func monero(_ s: String) -> Bool {
        guard s.count == 95 || s.count == 106, let raw = moneroDecode(s), raw.count == (s.count == 95 ? 69 : 77),
              [18, 19, 42].contains(raw[0]), (raw[0] == 19) == (s.count == 106) else { return false }
        let body = raw.dropLast(4)
        return Array(Keccak.hash256(Array(body)).prefix(4)) == Array(raw.suffix(4))
    }

    private static let encodedBlockSizes = [0, 2, 3, 5, 6, 7, 9, 10, 11]

    /// Monero's base58 works in 8-byte blocks that each become 11 characters.
    static func moneroDecode(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < chars.count {
            let size = min(11, chars.count - i)
            guard let bytes = encodedBlockSizes.firstIndex(of: size) else { return nil }
            var value: UInt64 = 0
            for c in chars[i..<i + size] {
                guard let digit = alphabetIndex[c] else { return nil }
                let (m, o1) = value.multipliedReportingOverflow(by: 58)
                let (a, o2) = m.addingReportingOverflow(UInt64(digit))
                if o1 || o2 { return nil }
                value = a
            }
            if bytes < 8, value >> (8 * UInt64(bytes)) != 0 { return nil }
            for b in (0..<bytes).reversed() { out.append(UInt8((value >> (8 * UInt64(b))) & 0xff)) }
            i += size
        }
        return out
    }

    // MARK: Base58

    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    private static let alphabetIndex: [UInt8: UInt8] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) })

    static func base58Decode(_ s: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        for c in s.utf8 {
            guard let digit = alphabetIndex[c] else { return nil }
            var carry = Int(digit)
            for i in stride(from: bytes.count - 1, through: 0, by: -1) {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 { bytes.insert(UInt8(carry & 0xff), at: 0); carry >>= 8 }
        }
        return Array(repeating: 0, count: s.utf8.prefix { $0 == alphabet[0] }.count) + bytes
    }

    /// Bitcoin-style base58 with a version byte and a double-SHA-256 checksum; 25 bytes in all.
    static func base58Check(_ s: String, versions: [UInt8]) -> Bool {
        guard (26...35).contains(s.count), let raw = base58Decode(s), raw.count == 25, versions.contains(raw[0]) else { return false }
        let check = SHA256.hash(data: Data(SHA256.hash(data: raw.prefix(21))))
        return Array(check.prefix(4)) == Array(raw.suffix(4))
    }

    // MARK: Bech32

    private static let bech32Chars = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 where (top >> UInt32(i)) & 1 == 1 { chk ^= gen[i] }
        }
        return chk
    }

    /// Whether `s` (lowercase) is a Bech32 or Bech32m string with one of the given prefixes and a good checksum.
    /// With `segwitOnly`, it must also be a Bitcoin-style witness address: version 0 as Bech32, 1 and up as Bech32m.
    static func bech32(_ s: String, hrps: [String], segwitOnly: Bool = false, allowM: Bool = true) -> Bool {
        guard let sep = s.lastIndex(of: "1"), s.count <= (segwitOnly ? 90 : 200) else { return false }
        let hrp = String(s[..<sep]), data = s[s.index(after: sep)...]
        guard hrps.contains(hrp), data.count >= 6 else { return false }
        var values: [UInt8] = []
        for c in data {
            guard let i = bech32Chars.firstIndex(of: c) else { return false }
            values.append(UInt8(i))
        }
        let expanded = hrp.utf8.map { $0 >> 5 } + [0] + hrp.utf8.map { $0 & 31 }
        let sum = polymod(expanded + values)
        if segwitOnly {
            guard let version = values.first, version <= 16, sum == (version == 0 ? 1 : 0x2bc830a3),
                  let program = convertBits(Array(values[1..<values.count - 6]), from: 5, to: 8) else { return false }
            // BIP-141: 2 to 40 bytes; version 0 is exactly a 20-byte key hash or a 32-byte script hash.
            return (2...40).contains(program.count) && (version != 0 || program.count == 20 || program.count == 32)
        }
        return sum == 1 || (allowM && sum == 0x2bc830a3)
    }

    /// Regroups bits (5 to 8 for a witness program). Nil if the leftover padding is more than 4 bits or not zero.
    private static func convertBits(_ data: [UInt8], from: Int, to: Int) -> [UInt8]? {
        var acc = 0, bits = 0
        var out: [UInt8] = []
        for v in data {
            acc = (acc << from) | Int(v)
            bits += from
            while bits >= to { bits -= to; out.append(UInt8((acc >> bits) & ((1 << to) - 1))) }
            acc &= (1 << bits) - 1
        }
        guard bits < from, acc == 0 else { return nil }
        return out
    }
}

/// Keccak-256, the original (pre-SHA-3) padding that Ethereum and Monero use. CryptoKit doesn't have it.
enum Keccak {
    private static let round: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000, 0x000000000000808b, 0x0000000080000001,
        0x8000000080008081, 0x8000000000008009, 0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
        0x000000000000800a, 0x800000008000000a, 0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    private static let rotations = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44]
    private static let lanes = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1]

    private static func rotl(_ x: UInt64, _ n: Int) -> UInt64 { x << UInt64(n) | x >> UInt64(64 - n) }

    private static func permute(_ s: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        for r in 0..<24 {
            for x in 0..<5 { c[x] = s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20] }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
                for y in stride(from: 0, to: 25, by: 5) { s[y + x] ^= d }
            }
            var t = s[1]
            for i in 0..<24 {
                let j = lanes[i], keep = s[j]
                s[j] = rotl(t, rotations[i])
                t = keep
            }
            for y in stride(from: 0, to: 25, by: 5) {
                let row = Array(s[y..<y + 5])
                for x in 0..<5 { s[y + x] = row[x] ^ (~row[(x + 1) % 5] & row[(x + 2) % 5]) }
            }
            s[0] ^= round[r]
        }
    }

    static func hash256(_ input: [UInt8]) -> [UInt8] {
        let rate = 136
        var message = input
        message.append(0x01)
        while message.count % rate != 0 { message.append(0) }
        message[message.count - 1] |= 0x80
        var state = [UInt64](repeating: 0, count: 25)
        for block in stride(from: 0, to: message.count, by: rate) {
            for lane in 0..<rate / 8 {
                var word: UInt64 = 0
                for b in 0..<8 { word |= UInt64(message[block + lane * 8 + b]) << UInt64(8 * b) }
                state[lane] ^= word
            }
            permute(&state)
        }
        return (0..<32).map { UInt8((state[$0 / 8] >> UInt64(8 * ($0 % 8))) & 0xff) }
    }
}
