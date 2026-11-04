import Testing
import Foundation
import CryptoKit
import PulshadeShared

/// What the app and Pulshade Admin both rely on: sealed reports, signed collectibles and the reports mailbox.
struct SharedTests {
    private let card = ReportCard(subjectKey: Data(repeating: 7, count: 32), subjectHandle: "nova", subjectName: "Nova",
                                  reason: "Spam or scams", details: "sends links to everyone", reporterHandle: nil)

    @Test func onlyTheReportsKeyOpensAReport() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let sealed = try ReportSeal.seal(card, to: key.publicKey.rawRepresentation)
        #expect(try ReportSeal.open(sealed, with: key) == card)
        #expect(throws: (any Error).self) { try ReportSeal.open(sealed, with: Curve25519.KeyAgreement.PrivateKey()) }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        #expect(throws: (any Error).self) { try ReportSeal.open(tampered, with: key) }
    }

    @Test func reportSizesGiveLittleAway() throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        var long = card
        long.details = String(repeating: "x", count: 600)
        #expect(try ReportSeal.seal(card, to: key).count == ReportSeal.seal(long, to: key).count)
    }

    @Test func collectiblesCountOnlyFromTheAdminKeyForTheirOwner() throws {
        let admin = Curve25519.Signing.PrivateKey(), owner = Data(repeating: 1, count: 32)
        let hat = try Collectible.make(.pumpkin, serial: 3, owner: owner, signedBy: admin)
        let adminKey = admin.publicKey.rawRepresentation
        #expect(hat.isGenuine(for: owner, adminKey: adminKey))
        #expect(!hat.isGenuine(for: Data(repeating: 2, count: 32), adminKey: adminKey))
        #expect(!hat.isGenuine(for: owner, adminKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        #expect(!hat.isGenuine(for: owner, adminKey: nil), "a build without the admin key trusts none")
        var renumbered = hat
        renumbered.serial = 1
        #expect(!renumbered.isGenuine(for: owner, adminKey: adminKey))
    }

    @Test func petsCountFromTheRelayKeyToo() throws {
        let admin = Curve25519.Signing.PrivateKey(), relay = Curve25519.Signing.PrivateKey(), owner = Data(repeating: 1, count: 32)
        let pet = try Collectible.make(.goldPulze, serial: 2, owner: owner, signedBy: relay)
        #expect(pet.isGenuine(for: owner, adminKey: admin.publicKey.rawRepresentation, petKey: relay.publicKey.rawRepresentation))
        #expect(!pet.isGenuine(for: owner, adminKey: admin.publicKey.rawRepresentation), "a build without the relay key trusts none")
        #expect(!pet.isGenuine(for: Data(repeating: 2, count: 32), adminKey: nil, petKey: relay.publicKey.rawRepresentation))
        #expect(pet.kind?.category == .pets)
    }

    @Test func announcementsCountOnlyFromTheAdminKeyAndUnchanged() throws {
        let admin = Curve25519.Signing.PrivateKey(), adminKey = admin.publicKey.rawRepresentation
        let news = try Announcement.make("Calls are here.", signedBy: admin)
        #expect(news.isGenuine(adminKey: adminKey))
        #expect(!news.isGenuine(adminKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        #expect(!news.isGenuine(adminKey: nil), "a build without the admin key trusts none")
        var edited = news
        edited.text = "Calls are gone."
        #expect(!edited.isGenuine(adminKey: adminKey), "the relay can't change a word")
        var redated = news
        redated.date += 1
        #expect(!redated.isGenuine(adminKey: adminKey))
    }

    @Test func theReportsMailboxMustBeSignedByTheAdminKey() throws {
        let admin = Curve25519.Signing.PrivateKey()
        var inbox = ReportInbox(sendID: "c2VuZA==", agreementKey: "YWdyZWU=", signingKey: admin.publicKey.rawRepresentation.base64EncodedString())
        inbox.sig = try admin.signature(for: ReportInbox.signedPart(inbox)).base64EncodedString()
        #expect(inbox.isGenuine(adminKey: admin.publicKey.rawRepresentation))
        #expect(!inbox.isGenuine(adminKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        var moved = inbox
        moved.sendID = "ZWxzZXdoZXJl"
        #expect(!moved.isGenuine(adminKey: admin.publicKey.rawRepresentation), "a relay can't point reports elsewhere")
    }
}
