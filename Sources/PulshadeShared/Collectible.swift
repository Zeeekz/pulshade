import Foundation
import CryptoKit

/// One numbered copy of a collectible, held by an account. Signed by the relay's issuer key over
/// `"pulshade.collectible.v2" | item | 0 | serial (u32 BE) | holder key`, and the issuer key is named in the collectibles
/// list the Pulshade Admin key signs, so only the relay can make one and nobody can show a copy given to someone else.
public struct Collectible: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var item: String
    /// Which one of its run it is, from #1 to the run's size, given at random.
    public var serial: UInt32
    /// The signing key of the account holding it.
    public var owner: Data
    public var sig: Data

    public init(item: String, serial: UInt32, owner: Data, sig: Data) {
        self.item = item
        self.serial = serial
        self.owner = owner
        self.sig = sig
    }

    public var id: String { "\(item)#\(serial)" }

    public static func signedPart(item: String, serial: UInt32, owner: Data) -> Data {
        Data("pulshade.collectible.v2".utf8) + Data(item.utf8) + Data([0])
            + withUnsafeBytes(of: serial.bigEndian) { Data($0) } + owner
    }

    /// Held by `owner` and signed by `issuer` (the relay's key, as the signed list names it).
    public func isGenuine(for owner: Data, issuer: Data?) -> Bool {
        guard CollectibleList.validID(item), serial > 0, self.owner == owner, let issuer,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: issuer) else { return false }
        return key.isValidSignature(sig, for: Self.signedPart(item: item, serial: serial, owner: owner))
    }

    /// `list` with one entry per item and number, at most `limit`: anything a profile hands over may repeat an entry,
    /// and two entries with the same identity draw unreliably in SwiftUI.
    public static func unique(_ list: [Collectible], limit: Int) -> [Collectible] {
        var seen = Set<String>()
        var out: [Collectible] = []
        for c in list.prefix(limit * 10) where seen.insert(c.id).inserted {
            out.append(c)
            if out.count == limit { break }
        }
        return out
    }

    // MARK: Number badges

    /// What makes a number wanted, best first. Numbers are given at random, so a good one is luck: it can't be picked.
    public enum Badge: Equatable, Sendable {
        case first, topTen, lucky, repeater, straight, round, topTwentyFive, last

        public var name: String {
            switch self {
            case .first: "Number one"
            case .topTen: "Top 10"
            case .lucky: "Lucky 7"
            case .repeater: "Repeater"
            case .straight: "Straight"
            case .round: "Round"
            case .topTwentyFive: "Top 25"
            case .last: "Last one"
            }
        }
    }

    /// The badge `serial` earns in a run of `run`, if any. Pure, so the app, Admin and tests agree.
    public static func badge(of serial: UInt32, run: UInt32) -> Badge? {
        switch serial {
        case 1: return .first
        case 7: return .lucky
        case 2...10: return .topTen
        default: break
        }
        let digits = Array(String(serial)).compactMap(\.wholeNumberValue)
        if digits.count >= 2 {
            if Set(digits).count == 1 { return digits[0] == 7 ? .lucky : .repeater }
            let steps = zip(digits, digits.dropFirst()).map { $1 - $0 }
            if digits.count >= 3, Set(steps).count == 1, steps[0] == 1 || steps[0] == -1 { return .straight }
            if serial >= 50, digits[0] == 1 || digits[0] == 5, digits.dropFirst().allSatisfy({ $0 == 0 }) { return .round }
        }
        if serial <= 25 { return .topTwentyFive }
        if serial == run, run > 1 { return .last }
        return nil
    }
}

/// What a profile shows of its collectibles, as sent to friends inside the encrypted profile: the identity's collector
/// key (which holds its copies on the relay), the identity's signing key's signature over it, the collector key's
/// signature back over the identity's signing key, and the copies. Both signatures are needed: with only the first,
/// anyone who had seen your showcase could vouch for your collector key themselves and pass your copies off as theirs.
public struct Showcase: Codable, Equatable, Sendable {
    public static let limit = 6
    public var collector: Data
    public var cert: Data
    /// The collector key's signature over `bindPart(signingKey)`. Optional only so a showcase from an earlier build of
    /// 23 still decodes; without it nothing is shown.
    public var bind: Data?
    public var copies: [Collectible]

    public init(collector: Data, cert: Data, bind: Data? = nil, copies: [Collectible]) {
        (self.collector, self.cert, self.bind, self.copies) = (collector, cert, bind, copies)
    }

    public static func certPart(_ collector: Data) -> Data { Data("pulshade.collector.cert.v1".utf8) + collector }
    public static func bindPart(_ signingKey: Data) -> Data { Data("pulshade.collector.bind.v1".utf8) + signingKey }

    public static func make(signing: Curve25519.Signing.PrivateKey, collector: Curve25519.Signing.PrivateKey,
                            copies: [Collectible]) throws -> Showcase {
        let collectorKey = collector.publicKey.rawRepresentation
        return Showcase(collector: collectorKey, cert: try signing.signature(for: certPart(collectorKey)),
                        bind: try collector.signature(for: bindPart(signing.publicKey.rawRepresentation)), copies: copies)
    }

    /// A showcase that arrived, kept only in shape: a 32-byte key, a 64-byte certificate, and at most `limit` copies held by
    /// that key with valid ids and signatures of the right size. Nil if nothing's left.
    public static func received(_ showcase: Showcase?) -> Showcase? {
        guard let showcase, showcase.collector.count == 32, showcase.cert.count == 64, showcase.bind?.count == 64 else { return nil }
        let copies = Collectible.unique(showcase.copies.filter {
            $0.owner == showcase.collector && CollectibleList.validID($0.item) && $0.serial > 0 && $0.sig.count == 64
        }, limit: limit)
        return copies.isEmpty ? nil : Showcase(collector: showcase.collector, cert: showcase.cert, bind: showcase.bind, copies: copies)
    }

    /// The copies that can be shown for the account with `signingKey`: the certificate is theirs, the collector key
    /// signed their signing key back, and each copy was signed by `issuer` for that collector key.
    public func genuine(for signingKey: Data, issuer: Data?) -> [Collectible] {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey),
              key.isValidSignature(cert, for: Self.certPart(collector)),
              let bind, let collectorKey = try? Curve25519.Signing.PublicKey(rawRepresentation: collector),
              collectorKey.isValidSignature(bind, for: Self.bindPart(signingKey)) else { return [] }
        return Collectible.unique(copies.filter { $0.isGenuine(for: collector, issuer: issuer) }, limit: Self.limit)
    }
}

/// How rare an item is: its run's size, as the list says, sorted rarest first for display.
public enum CollectibleTier: String, Codable, CaseIterable, Comparable, Sendable {
    case common, uncommon, rare, epic, legendary, mythic

    public var name: String { rawValue.capitalized }

    public static func < (a: CollectibleTier, b: CollectibleTier) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// The collectibles list: every item, signed by the Pulshade Admin key over
/// `"pulshade.catalog.v2" | 0 | SHA-256(manifest)`. Pictures come from the relay by hash and are checked against it.
public struct CollectibleList: Codable, Equatable, Sendable {
    public static let format: UInt64 = 2
    public static let maxManifest = 256 * 1024
    public static let maxItems = 300
    public static let maxVideo = 512 * 1024
    public static let maxStill = 128 * 1024

    public struct File: Codable, Equatable, Hashable, Sendable {
        public var sha256: String
        public var bytes: Int

        public init(sha256: String, bytes: Int) {
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var blurb: String
        public var tier: CollectibleTier
        public var run: UInt32
        public var giftable: Bool
        /// A season or date it belongs to ("Winter 2026"), if any.
        public var season: String?
        public var video: File
        public var still: File

        public init(id: String, name: String, blurb: String, tier: CollectibleTier, run: UInt32, giftable: Bool,
                    season: String? = nil, video: File, still: File) {
            (self.id, self.name, self.blurb, self.tier, self.run, self.giftable) = (id, name, blurb, tier, run, giftable)
            (self.season, self.video, self.still) = (season, video, still)
        }
    }

    public var format: UInt64
    public var version: UInt64
    /// The relay's issuer key (base64): it signs every copy.
    public var issuer: String
    public var items: [Item]

    public init(format: UInt64 = CollectibleList.format, version: UInt64, issuer: String, items: [Item]) {
        (self.format, self.version, self.issuer, self.items) = (format, version, issuer, items)
    }

    public var issuerKey: Data? { Data(base64Encoded: issuer) }

    public func item(_ id: String) -> Item? { items.first { $0.id == id } }

    public static func validID(_ id: String) -> Bool {
        (1...32).contains(id.count) && id.allSatisfy { ($0.isASCII && $0.isLowercase) || $0.isASCII && $0.isNumber }
    }

    static func validSHA(_ sha: String) -> Bool {
        sha.count == 64 && sha.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The list as the relay hands it out: the manifest's exact bytes and the admin signature, both base64.
    public struct Signed: Codable, Equatable, Sendable {
        public var manifest: String
        public var sig: String

        public init(manifest: String, sig: String) {
            self.manifest = manifest
            self.sig = sig
        }

        public static func signedPart(_ manifest: Data) -> Data {
            Data("pulshade.catalog.v2".utf8) + Data([0]) + Data(SHA256.hash(data: manifest))
        }

        /// The list, if signed by `adminKey` and well formed. Anything else is nil: a phone only believes Pulshade's list.
        public func open(adminKey: Data?) -> CollectibleList? {
            guard let adminKey, manifest.count <= (CollectibleList.maxManifest / 3 + 1) * 4,
                  let raw = Data(base64Encoded: manifest), raw.count <= CollectibleList.maxManifest,
                  let sig = Data(base64Encoded: sig),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: adminKey),
                  key.isValidSignature(sig, for: Self.signedPart(raw)),
                  let list = try? JSONDecoder().decode(CollectibleList.self, from: raw),
                  list.isWellFormed else { return nil }
            return list
        }

        /// Made by the admin app.
        public static func make(_ list: CollectibleList, signedBy admin: Curve25519.Signing.PrivateKey) throws -> Signed {
            let raw = try JSONEncoder().encode(list)
            let sig = try admin.signature(for: signedPart(raw))
            return Signed(manifest: raw.base64EncodedString(), sig: sig.base64EncodedString())
        }
    }

    public var isWellFormed: Bool {
        guard format == Self.format, items.count <= Self.maxItems, let key = issuerKey, key.count == 32 else { return false }
        var ids = Set<String>()
        for item in items {
            guard Self.validID(item.id), ids.insert(item.id).inserted, item.run >= 1, item.name.count <= 60, item.blurb.count <= 400,
                  Self.validSHA(item.video.sha256), (1...Self.maxVideo).contains(item.video.bytes),
                  Self.validSHA(item.still.sha256), (1...Self.maxStill).contains(item.still.bytes) else { return false }
        }
        return true
    }

    /// Whether `data` is the picture `file` names.
    public static func matches(_ data: Data, _ file: File) -> Bool {
        data.count == file.bytes && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == file.sha256
    }
}
