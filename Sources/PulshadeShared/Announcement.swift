import Foundation
import CryptoKit

/// A message from Pulshade to everyone, shown as a chat from @announcements. Signed by the operator's key over
/// `"pulshade.announcement.v1" | id | 0 | date (u64 BE) | text`, so only the operator can write one and the relay
/// can't change a word of it.
public struct Announcement: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    /// Seconds since 1970.
    public var date: UInt64
    public var sig: String

    public init(id: String, text: String, date: UInt64, sig: String) {
        self.id = id
        self.text = text
        self.date = date
        self.sig = sig
    }

    /// The handle it comes from. The relay keeps it reserved, so no account can claim it.
    public static let handle = "announcements"
    /// Longest announcement, in characters, as the relay allows.
    public static let maxLength = 4000

    public var sentAt: Date { Date(timeIntervalSince1970: TimeInterval(date)) }

    public static func signedPart(id: String, text: String, date: UInt64) -> Data {
        Data("pulshade.announcement.v1".utf8) + Data(id.utf8) + Data([0])
            + withUnsafeBytes(of: date.bigEndian) { Data($0) } + Data(text.utf8)
    }

    /// Written by the operator.
    public static func make(_ text: String, signedBy admin: Curve25519.Signing.PrivateKey, at date: Date = Date()) throws -> Announcement {
        let id = UUID().uuidString, seconds = UInt64(date.timeIntervalSince1970)
        let sig = try admin.signature(for: signedPart(id: id, text: text, date: seconds))
        return Announcement(id: id, text: text, date: seconds, sig: sig.base64EncodedString())
    }

    /// Signed by `adminKey`, the operator's key a build carries.
    public func isGenuine(adminKey: Data?) -> Bool {
        guard let adminKey, UUID(uuidString: id) != nil, let sig = Data(base64Encoded: sig),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: adminKey) else { return false }
        return key.isValidSignature(sig, for: Self.signedPart(id: id, text: text, date: date))
    }
}
