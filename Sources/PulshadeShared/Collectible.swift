import Foundation
import CryptoKit

/// Something the operator gave an account, which it can show after its name. Signed by the Pulshade Admin key over
/// `"pulshade.collectible.v1" | item | 0 | serial (u32 BE) | owner key`, so only the admin app can make one, and
/// checked against the owner, so nobody can wear one given to someone else.
public struct Collectible: Codable, Equatable, Hashable, Identifiable {
    public var item: String
    /// Which one of its kind it is: #1 was the first given out.
    public var serial: UInt32
    /// The signing key of the account it was given to.
    public var owner: Data
    public var sig: Data
    /// How many of this kind there are, as the relay said when it was fetched. Not signed, and only used to tell which
    /// number is the last: it isn't part of what makes two collectibles the same one.
    public var edition: UInt32?

    public init(item: String, serial: UInt32, owner: Data, sig: Data, edition: UInt32? = nil) {
        self.item = item
        self.serial = serial
        self.owner = owner
        self.sig = sig
        self.edition = edition
    }

    public static func == (a: Collectible, b: Collectible) -> Bool {
        a.item == b.item && a.serial == b.serial && a.owner == b.owner && a.sig == b.sig
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(item)
        hasher.combine(serial)
        hasher.combine(owner)
        hasher.combine(sig)
    }

    public var id: String { "\(item)#\(serial)" }

    /// How rare its number makes it. The first ten are the ones people brag about, and the last of a run is the end of
    /// it. Only the number decides, so it can't be faked or bought.
    public enum Rarity: Equatable {
        case legendary, rare, last, common

        public var name: String? {
            switch self {
            case .legendary: "Top 10"
            case .rare: "Top 25"
            case .last: "Last one"
            case .common: nil
            }
        }
    }

    public var rarity: Rarity {
        switch serial {
        case 1...10: .legendary
        case 11...25: .rare
        case edition ?? Self.defaultLimit: .last
        default: .common
        }
    }
    /// How many of each there are unless the operator has said otherwise: #1 to #100.
    public static let defaultLimit: UInt32 = 100
    public var kind: Kind? { Kind(rawValue: item) }

    public enum Kind: String, CaseIterable, Identifiable {
        case partyHat = "partyhat"
        case pumpkin = "pumpkin"
        case topHat = "tophat"
        case pulsePop = "pulsepop"
        case bonfire = "bonfire"
        case christmasTree = "christmastree"
        /// Its id is still `greendragon`, from before it was renamed, so any already given out keep counting.
        case pulze = "greendragon"
        case guardian = "guardian"
        /// The rare dragon: one in seven of the eggs that hatch Pulze.
        case goldPulze = "golddragon"

        public var id: String { rawValue }
        public var name: String {
            switch self {
            case .partyHat: "Party Hat"
            case .pumpkin: "Halloween Pumpkin"
            case .topHat: "Top Hat"
            case .pulsePop: "Pulse Pop"
            case .bonfire: "Bonfire Night"
            case .christmasTree: "Christmas Tree"
            case .pulze: "Pulze The Dragon"
            case .guardian: "Guardian"
            case .goldPulze: "Golden Pulze The Dragon"
            }
        }
        /// What sort of thing it is, so the Collectibles tab can keep pets together.
        public enum Category: CaseIterable {
            case items, pets
        }

        public var category: Category { self == .pulze || self == .goldPulze ? .pets : .items }
        /// Whether it can be opened to look at from every side.
        /// Every collectible opens in 3D: the dragon in its own modelled viewer, the rest as solid objects.
        public var has3DView: Bool { true }

        /// Whether a backup code can move it to another account. A Guardian is earned by whoever wears it, so it can't.
        public var transferable: Bool { self != .guardian }

        public var blurb: String {
            switch self {
            case .partyHat: "A folded paper crown. The first PULSHADE collectible."
            case .pumpkin: "A carved pumpkin, lit from inside."
            case .topHat: "A top hat that never settles on a colour."
            case .pulsePop: "A can of Pulse Pop that won't stay shut."
            case .bonfire: "A roaring bonfire with fireworks bursting overhead. Remember, remember."
            case .christmasTree: "A Christmas tree with twinkling lights and snow drifting down. Hush now."
            case .pulze: "A dark blue dragon, crackling with electricity."
            case .guardian: "Awarded to the people who keep Pulshade safe. Earned, never passed on."
            case .goldPulze: "A rare golden dragon, crackling with sparks. Hatched from a dragon egg, and not often."
            }
        }
    }

    public static func signedPart(item: String, serial: UInt32, owner: Data) -> Data {
        Data("pulshade.collectible.v1".utf8) + Data(item.utf8) + Data([0])
            + withUnsafeBytes(of: serial.bigEndian) { Data($0) } + owner
    }

    /// Made by the admin app for `owner`.
    public static func make(_ kind: Kind, serial: UInt32, owner: Data, signedBy admin: Curve25519.Signing.PrivateKey) throws -> Collectible {
        let sig = try admin.signature(for: signedPart(item: kind.rawValue, serial: serial, owner: owner))
        return Collectible(item: kind.rawValue, serial: serial, owner: owner, sig: sig)
    }

    /// Given to `owner`, signed by `adminKey` (the Pulshade Admin key a build carries) or `petKey` (the relay's, for
    /// hatched and gifted ones), and an item this build knows how to show.
    public func isGenuine(for owner: Data, adminKey: Data?, petKey: Data? = nil) -> Bool {
        guard kind != nil, self.owner == owner else { return false }
        let message = Self.signedPart(item: item, serial: serial, owner: owner)
        return [adminKey, petKey].contains { raw in
            guard let raw, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return key.isValidSignature(sig, for: message)
        }
    }
}
