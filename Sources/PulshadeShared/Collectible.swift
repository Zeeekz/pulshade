import Foundation
import CryptoKit

/// Something the operator gave an account, which it can show after its name. Signed by the Pulshade Admin key over
/// `"pulshade.collectible.v1" | item | 0 | serial (u32 BE) | owner key`, so only the admin app can make one, and
/// checked against the owner, so nobody can wear one given to someone else.
public struct Collectible: Codable, Equatable, Hashable, Identifiable {
    public var item: String
    /// Which one of its kind it is, from #1 to the end of its run. Hatched ones get a random free number.
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

    /// What makes its number wanted, best first. Low numbers are the ones people brag about, then numbers with a
    /// pattern, then the end of the run. Numbers are given at random when an egg hatches, so a good one is luck: it can't
    /// be faked or bought, only traded.
    public enum Rarity: Equatable {
        /// #1.
        case first
        /// #2 to #10.
        case topTen
        /// A number with a pattern: lucky 7, the same digit over and over, a run like 123, or a round number.
        case special(Pattern)
        /// #11 to #25.
        case topTwentyFive
        /// The final number of the run.
        case last
        case common

        public enum Pattern: Equatable {
            case lucky, repeated, run, round
        }

        public var name: String? {
            switch self {
            case .first: "Number one"
            case .topTen: "Top 10"
            case .special(.lucky): "Lucky 7"
            case .special(.repeated): "Repeater"
            case .special(.run): "Straight"
            case .special(.round): "Round"
            case .topTwentyFive: "Top 25"
            case .last: "Last one"
            case .common: nil
            }
        }
    }

    public var rarity: Rarity { Self.rarity(of: serial, edition: edition ?? Self.defaultLimit) }

    /// How wanted `serial` is in a run of `edition`. Pure, so the app, Admin and tests agree.
    public static func rarity(of serial: UInt32, edition: UInt32) -> Rarity {
        switch serial {
        case 1: return .first
        case 2...10: return serial == 7 ? .special(.lucky) : .topTen
        default: break
        }
        if let pattern = pattern(of: serial) { return .special(pattern) }
        if serial <= 25 { return .topTwentyFive }
        if serial == edition { return .last }
        return .common
    }

    /// The pattern a number of two digits or more has, if any: 77 and 777 are lucky, 11, 222 and 4444 repeat, 123,
    /// 234, 1234 and 321 run, and 50, 100, 500 and 1000 are round.
    public static func pattern(of serial: UInt32) -> Rarity.Pattern? {
        let digits = Array(String(serial)).compactMap { $0.wholeNumberValue }
        guard digits.count >= 2 else { return serial == 7 ? .lucky : nil }
        if Set(digits).count == 1 { return digits[0] == 7 ? .lucky : .repeated }
        let steps = zip(digits, digits.dropFirst()).map { $1 - $0 }
        if digits.count >= 3, Set(steps).count == 1, steps[0] == 1 || steps[0] == -1 { return .run }
        if serial >= 50, digits[0] == 1 || digits[0] == 5, digits.dropFirst().allSatisfy({ $0 == 0 }) { return .round }
        return nil
    }

    /// How many of each there are unless the operator has said otherwise: #1 to #100.
    public static let defaultLimit: UInt32 = 100

    /// What sort of thing it is, so the Collectibles tab can keep pets together.
    public enum Category: CaseIterable {
        case items, pets
    }

    /// The Guardian: given only to moderators, and earned, so never passed on.
    public static let guardian = "guardian"

    /// The collectibles the first builds drew themselves, which could always be gifted or moved with a backup code. Kept
    /// so one of them is still taken as genuine before the collectibles list has arrived; the list says the same.
    public static let classicTransferable: Set<String> = [
        "partyhat", "pumpkin", "tophat", "pulsepop", "bonfire", "christmastree", "bitcoin", "greendragon", "golddragon",
    ]

    public static func signedPart(item: String, serial: UInt32, owner: Data) -> Data {
        Data("pulshade.collectible.v1".utf8) + Data(item.utf8) + Data([0])
            + withUnsafeBytes(of: serial.bigEndian) { Data($0) } + owner
    }

    /// Made by the admin app for `owner`.
    public static func make(item: String, serial: UInt32, owner: Data, signedBy admin: Curve25519.Signing.PrivateKey) throws -> Collectible {
        let sig = try admin.signature(for: signedPart(item: item, serial: serial, owner: owner))
        return Collectible(item: item, serial: serial, owner: owner, sig: sig)
    }

    /// `list` with one entry per item and number, at most `limit` entries. Anything a profile or the relay hands over may
    /// repeat an entry, or carry two signatures for the same number (the admin key's and the relay's): two entries sharing
    /// an identity are duplicate IDs, which SwiftUI draws unreliably (a display glitch and a runtime warning).
    public static func unique(_ list: [Collectible], limit: Int = 40) -> [Collectible] {
        var seen = Set<String>()
        var out: [Collectible] = []
        for collectible in list.prefix(limit * 10) {
            guard seen.insert(collectible.id).inserted else { continue }
            out.append(collectible)
            if out.count == limit { break }
        }
        return out
    }

    /// Given to `owner`, signed by `adminKey` (the Pulshade Admin key a build carries) or `petKey` (the relay's, for
    /// hatched and gifted ones). Every item comes from the collectibles list and shows a placeholder until the list
    /// arrives. `transferable` is what the list says of it; without the list only the classic ones count as movable,
    /// and anything else takes the admin key only.
    public func isGenuine(for owner: Data, adminKey: Data?, petKey: Data? = nil, transferable: Bool? = nil) -> Bool {
        guard CollectibleCatalog.validID(item), self.owner == owner else { return false }
        let message = Self.signedPart(item: item, serial: serial, owner: owner)
        // The relay's key only counts for what can be hatched or passed on. A Guardian is the admin key's alone.
        let movable = item != Self.guardian && (transferable ?? Self.classicTransferable.contains(item))
        return [adminKey, movable ? petKey : nil].contains { raw in
            guard let raw, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return key.isValidSignature(sig, for: message)
        }
    }
}
