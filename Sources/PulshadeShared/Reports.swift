import Foundation
import CryptoKit

/// Someone reporting another account. The subject's key lets the operator act on the account itself.
public struct ReportCard: Codable, Equatable, Sendable {
    public var subjectKey: Data
    public var subjectHandle: String?
    public var subjectName: String
    public var reason: String
    public var details: String
    public var reporterHandle: String?

    public init(subjectKey: Data, subjectHandle: String?, subjectName: String, reason: String, details: String,
                reporterHandle: String?) {
        self.subjectKey = subjectKey
        self.subjectHandle = subjectHandle
        self.subjectName = subjectName
        self.reason = reason
        self.details = details
        self.reporterHandle = reporterHandle
    }
}

/// Where reports go: the operator's mailbox, published through the relay.
public struct ReportInbox: Codable, Equatable, Sendable {
    public var sendID: String
    public var agreementKey: String
    public var signingKey: String
    /// The admin key's signature over the rest, so a relay can't swap in a mailbox of its own.
    public var sig: String?

    public init(sendID: String, agreementKey: String, signingKey: String, sig: String? = nil) {
        self.sendID = sendID
        self.agreementKey = agreementKey
        self.signingKey = signingKey
        self.sig = sig
    }

    public static func signedPart(_ inbox: ReportInbox) -> Data {
        Data("pulshade.inbox.v1".utf8) + Data(inbox.sendID.utf8) + Data([0]) + Data(inbox.agreementKey.utf8) + Data([0])
            + Data(inbox.signingKey.utf8)
    }

    /// Published by the operator whose key this build carries.
    public func isGenuine(adminKey: Data?) -> Bool {
        guard let adminKey, Data(base64Encoded: signingKey) == adminKey,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: adminKey),
              let sig = sig.flatMap({ Data(base64Encoded: $0) }) else { return false }
        return key.isValidSignature(sig, for: Self.signedPart(self))
    }
}

/// A report sealed to the operator's reports key from a throwaway key, so only the operator can open it and
/// nothing in it says who sent it. `"pulshade.report.v2" | throwaway X25519 key | ChaChaPoly box`, the box holding
/// the length and the report padded to whole KiB, so its size says little about what it says.
public enum ReportSeal {
    static let label = Data("pulshade.report.v2".utf8)

    public enum Failure: Error { case notAReport, unreadable }

    public static func seal(_ card: ReportCard, to recipient: Data) throws -> Data {
        let them = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient)
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let key = try mine.sharedSecretFromKeyAgreement(with: them)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: mine.publicKey.rawRepresentation + recipient, sharedInfo: label, outputByteCount: 32)
        let plain = try JSONEncoder().encode(card)
        var framed = withUnsafeBytes(of: UInt32(plain.count).bigEndian) { Data($0) } + plain
        framed += Data(count: (framed.count + 1023) / 1024 * 1024 - framed.count)
        return label + mine.publicKey.rawRepresentation + (try ChaChaPoly.seal(framed, using: key)).combined
    }

    public static func open(_ blob: Data, with mine: Curve25519.KeyAgreement.PrivateKey) throws -> ReportCard {
        let blob = Data(blob)
        guard blob.count > label.count + 32, blob.prefix(label.count) == label else { throw Failure.notAReport }
        let theirs = blob.dropFirst(label.count).prefix(32)
        let them = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs)
        let key = try mine.sharedSecretFromKeyAgreement(with: them)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(theirs) + mine.publicKey.rawRepresentation, sharedInfo: label, outputByteCount: 32)
        let framed = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: blob.dropFirst(label.count + 32)), using: key)
        guard framed.count >= 4 else { throw Failure.unreadable }
        let length = Int(framed.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
        guard framed.count >= 4 + length else { throw Failure.unreadable }
        return try JSONDecoder().decode(ReportCard.self, from: framed.dropFirst(4).prefix(length))
    }
}
