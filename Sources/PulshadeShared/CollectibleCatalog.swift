import Foundation
import CryptoKit
import ImageIO

/// Collectibles added after a build shipped. The relay serves one list, signed by the Pulshade Admin key over
/// `"pulshade.catalog.v1" | 0 | SHA-256(manifest bytes)`, and each item's picture as an animated PNG named by its
/// SHA-256. The app checks the signature over the exact bytes before reading a word of them, and every picture's hash
/// against the list before handing it to ImageIO, so nothing the admin app didn't sign is ever decoded. The relay can
/// hold the list back or serve an older one (apps keep the highest `version` they have seen), but can't change it.
///
/// It's data only: names, words and pictures. How a collectible behaves (wearing it, gifting it, backup codes) is the
/// same for every item and stays in the app.
public struct CollectibleCatalog: Codable, Equatable, Sendable {
    /// What this build reads. A later build may add another; items in a format a build doesn't know aren't listed.
    public static let currentFormat = 1

    public var format: Int
    /// Only ever goes up. An app refuses a list older than one it already has.
    public var version: UInt64
    /// Seconds since 1970.
    public var issued: UInt64
    public var items: [Item]

    public init(format: Int = CollectibleCatalog.currentFormat, version: UInt64, issued: UInt64, items: [Item]) {
        self.format = format
        self.version = version
        self.issued = issued
        self.items = items
    }

    public struct Item: Codable, Equatable, Hashable, Sendable, Identifiable {
        /// The item string collectibles carry: 1 to 32 lowercase letters and digits, as the relay allows, and never one a
        /// build already has its own drawing for.
        public var id: String
        public var name: String
        public var blurb: String
        public var category: Category
        /// Whether a backup code or a gift can move it to another account. False makes it earned, like the Guardian.
        public var transferable: Bool
        public var art: Art

        public init(id: String, name: String, blurb: String, category: Category, transferable: Bool, art: Art) {
            self.id = id
            self.name = name
            self.blurb = blurb
            self.category = category
            self.transferable = transferable
            self.art = art
        }
    }

    public enum Category: String, Codable, Sendable {
        case items, pets

        public var kindCategory: Collectible.Kind.Category { self == .pets ? .pets : .items }
    }

    /// An animated PNG (a plain PNG is one frame), played round every `loop` seconds.
    public struct Art: Codable, Equatable, Hashable, Sendable {
        /// Lowercase hex of the file's SHA-256: also its name on the relay.
        public var sha256: String
        public var bytes: Int
        public var width: Int
        public var height: Int
        public var frames: Int
        /// Seconds for one time round. Ignored for one frame.
        public var loop: Double

        public init(sha256: String, bytes: Int, width: Int, height: Int, frames: Int, loop: Double) {
            self.sha256 = sha256
            self.bytes = bytes
            self.width = width
            self.height = height
            self.frames = frames
            self.loop = loop
        }
    }

    /// What the relay hands out: the manifest's exact bytes and the signature over them, both base64.
    public struct Signed: Codable, Equatable, Sendable {
        public var manifest: String
        public var sig: String

        public init(manifest: String, sig: String) {
            self.manifest = manifest
            self.sig = sig
        }
    }

    // MARK: Limits

    /// Kept small enough that every app can fetch every picture whenever the list changes, over Tor too, and that the
    /// relay never holds more than a few megabytes of it. The relay checks the same numbers.
    public enum Limits {
        public static let manifestBytes = 64 * 1024
        public static let items = 60
        public static let artBytes = 512 * 1024
        public static let totalArtBytes = 6 * 1024 * 1024
        public static let side = 512
        public static let frames = 72
        public static let nameLength = 40
        public static let blurbLength = 240
        public static let loop: ClosedRange<Double> = 0.5...30
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case tooBig, badSignature, unreadable, unknownFormat, invalid(String)

        public var description: String {
            switch self {
            case .tooBig: "The list is too big"
            case .badSignature: "The list isn't signed by the Pulshade Admin key"
            case .unreadable: "The list can't be read"
            case .unknownFormat: "The list is in a format this build doesn't know"
            case .invalid(let why): why
            }
        }
    }

    // MARK: Signing

    public static func signedPart(_ manifest: Data) -> Data {
        Data("pulshade.catalog.v1".utf8) + Data([0]) + Data(SHA256.hash(data: manifest))
    }

    /// The list as the admin app publishes it: checked first, then encoded once, and those exact bytes signed.
    public func sign(with admin: Curve25519.Signing.PrivateKey) throws -> Signed {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifest = try encoder.encode(self)
        guard manifest.count <= Limits.manifestBytes else { throw Problem.tooBig }
        let sig = try admin.signature(for: Self.signedPart(manifest))
        return Signed(manifest: manifest.base64EncodedString(), sig: sig.base64EncodedString())
    }

    /// Opens what the relay handed out: the signature is checked over the exact bytes before they are parsed, then
    /// every item is checked against the limits. Anything wrong refuses the whole list.
    public static func open(_ signed: Signed, adminKey: Data?) throws -> CollectibleCatalog {
        guard let adminKey, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: adminKey) else { throw Problem.badSignature }
        // Base64 is 4/3 of the bytes: refuse an oversized string before decoding it.
        guard signed.manifest.utf8.count <= (Limits.manifestBytes / 3 + 1) * 4, signed.sig.utf8.count <= 128 else { throw Problem.tooBig }
        guard let manifest = Data(base64Encoded: signed.manifest), let sig = Data(base64Encoded: signed.sig) else { throw Problem.unreadable }
        guard manifest.count <= Limits.manifestBytes else { throw Problem.tooBig }
        guard key.isValidSignature(sig, for: signedPart(manifest)) else { throw Problem.badSignature }
        struct Head: Decodable { var format: Int }
        guard let head = try? JSONDecoder().decode(Head.self, from: manifest) else { throw Problem.unreadable }
        guard head.format == currentFormat else { throw Problem.unknownFormat }
        guard var catalog = try? JSONDecoder().decode(CollectibleCatalog.self, from: manifest) else { throw Problem.unreadable }
        // An item a later build draws itself is that build's, not the list's: left out rather than refusing the list.
        catalog.items.removeAll { builtInIDs.contains($0.id) }
        try catalog.validate()
        return catalog
    }

    /// Ids the build draws itself. A list can't take one over.
    public static var builtInIDs: Set<String> { Set(Collectible.Kind.allCases.map(\.rawValue)) }

    public static func validID(_ id: String) -> Bool {
        (1...32).contains(id.utf8.count) && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Checks every rule a list has to keep. The admin app runs it before signing, and apps after the signature.
    public func validate() throws {
        guard format == Self.currentFormat else { throw Problem.unknownFormat }
        guard items.count <= Limits.items else { throw Problem.invalid("A list holds \(Limits.items) collectibles at most") }
        var seen = Set<String>(), hashes = Set<String>(), total = 0
        for item in items {
            guard Self.validID(item.id) else { throw Problem.invalid("“\(item.id)” isn't a valid id: 1 to 32 lowercase letters and digits") }
            guard !Self.builtInIDs.contains(item.id) else { throw Problem.invalid("“\(item.id)” is already a built-in collectible") }
            guard seen.insert(item.id).inserted else { throw Problem.invalid("“\(item.id)” is listed twice") }
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name == item.name, item.name.count <= Limits.nameLength,
                  !item.name.contains(where: { $0.isNewline }) else {
                throw Problem.invalid("“\(item.id)” needs a name of 1 to \(Limits.nameLength) characters on one line")
            }
            guard item.blurb.count <= Limits.blurbLength else { throw Problem.invalid("“\(item.id)”'s words are \(Limits.blurbLength) characters at most") }
            let art = item.art
            guard Self.validHash(art.sha256) else {
                throw Problem.invalid("“\(item.id)”'s picture has no valid hash")
            }
            guard (1...Limits.artBytes).contains(art.bytes) else { throw Problem.invalid("“\(item.id)”'s picture is over \(Limits.artBytes / 1024) KB") }
            guard (1...Limits.side).contains(art.width), (1...Limits.side).contains(art.height) else {
                throw Problem.invalid("“\(item.id)”'s picture is over \(Limits.side)×\(Limits.side)")
            }
            guard (1...Limits.frames).contains(art.frames) else { throw Problem.invalid("“\(item.id)”'s picture has over \(Limits.frames) frames") }
            guard art.frames == 1 || Limits.loop.contains(art.loop) else {
                throw Problem.invalid("“\(item.id)”'s animation has to take \(Limits.loop.lowerBound) to \(Limits.loop.upperBound) seconds")
            }
            // Two items may share one picture; it's fetched and counted once.
            if hashes.insert(art.sha256).inserted { total += art.bytes }
        }
        guard total <= Limits.totalArtBytes else { throw Problem.invalid("The pictures together are over \(Limits.totalArtBytes / 1024 / 1024) MB") }
    }

    public func item(_ id: String) -> Item? { items.first { $0.id == id } }

    /// 64 lowercase ASCII hex digits.
    public static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Every picture the list names, once each.
    public var artHashes: [String] {
        var seen = Set<String>()
        return items.map(\.art.sha256).filter { seen.insert($0).inserted }
    }

    // MARK: Pictures

    /// Checks a fetched picture against what the signed list says, the hash first, so ImageIO only ever reads bytes the
    /// admin app signed, and then that the file really is the size and length the list promised (the limits are what
    /// keep decoding it cheap).
    public static func checkArt(_ data: Data, against art: Art) throws {
        guard data.count == art.bytes, data.count <= Limits.artBytes else { throw Problem.invalid("A picture isn't the size the list says") }
        guard Self.hex(SHA256.hash(data: data)) == art.sha256 else { throw Problem.invalid("A picture doesn't match the list") }
        guard let facts = artFacts(data) else { throw Problem.invalid("A picture can't be read") }
        guard facts.width == art.width, facts.height == art.height, facts.frames == art.frames else {
            throw Problem.invalid("A picture isn't what the list says")
        }
    }

    /// A PNG's size and frame count, read from its header without decoding any frame.
    public static func artFacts(_ data: Data) -> (width: Int, height: Int, frames: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, type == "public.png" else { return nil }
        let frames = CGImageSourceGetCount(source)
        guard frames >= 1, let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height, frames)
    }

    /// An animated PNG of `frames` played evenly over `loop` seconds, round and round (one frame makes a plain PNG), and
    /// the facts the list records about it. What Pulshade Admin publishes.
    public static func makeArt(frames: [CGImage], loop: Double) -> (data: Data, art: Art)? {
        guard let first = frames.first, frames.count <= Limits.frames,
              frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, frames.count, nil) else { return nil }
        if frames.count > 1 {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        }
        let delay = frames.count > 1 ? loop / Double(frames.count) : 0
        for frame in frames {
            let props: [CFString: Any] = frames.count > 1
                ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay, kCGImagePropertyAPNGUnclampedDelayTime: delay]] : [:]
            CGImageDestinationAddImage(destination, frame, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        let data = out as Data
        let art = Art(sha256: hex(SHA256.hash(data: data)), bytes: data.count, width: first.width, height: first.height,
                      frames: frames.count, loop: frames.count > 1 ? loop : 0)
        return (data, art)
    }

    public static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
