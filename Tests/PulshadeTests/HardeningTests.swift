import Testing
import Foundation
import SwiftUI
import CryptoKit
import PulshadeShared
@testable import Pulshade

/// Values that arrive from other people, and files that go wrong, must never crash Pulshade or cost an account.
@MainActor
@Suite struct HardeningTests {
    @Test func aColourNumberFromSomeoneElseNeverPointsOutside() {
        for hostile in [-1, -7, Int.min, Int.max, Signature.colors.count, 0] {
            #expect(Signature.colors.contains(Signature.color(hostile, seed: "x")))
            #expect((0..<Signature.colors.count).contains(hostile.wrapped(Signature.colors.count)))
            _ = StoryPalette.gradient(hostile)
        }
        #expect((-1).wrapped(10) == 9)
        #expect(13.wrapped(10) == 3)
    }

    @Test func theWrongPasscodeCountSurvivesAndBurnClearsIt() {
        FileKeys.inMemory = true
        FileKeys.forgetAttempts()
        #expect(FileKeys.savedAttempts() == 0)
        FileKeys.saveAttempts(7)
        #expect(FileKeys.savedAttempts() == 7, "A relaunch starts from the same count")
        FileKeys.saveAttempts(0)
        #expect(FileKeys.savedAttempts() == 0)
        FileKeys.saveAttempts(3)
        FileKeys.forgetAttempts()
        #expect(FileKeys.savedAttempts() == 0)
    }

    @Test func aDataFileThatCannotBeReadIsAnErrorNotAnEmptyAccount() throws {
        let dir = testDirectory("pulshade-hardening")
        let vault = Vault(directory: dir)
        let identity = Identity.generate()
        #expect(try vault.load(with: identity) == nil, "No file yet: a new account")
        var data = AppData()
        data.profile.name = "Kept"
        try vault.save(data, with: identity)
        #expect(try vault.load(with: identity)?.profile.name == "Kept")

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "vault" }
        #expect(!files.isEmpty)
        for file in files { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path) }
        defer { for file in files { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) } }
        #expect(throws: (any Error).self) { _ = try vault.load(with: identity) }
    }

    @Test func theBackupCarriesNothingUnsentAndNoDisguises() throws {
        let them = Identity.generate()
        var contact = Contact(fingerprint: them.fingerprint, name: "Kai", signingKey: them.card.signing,
                              agreementKey: them.card.agreement, sendID: Mailbox.make().sendID)
        #expect(!contact.devices.isEmpty)
        let written = Message(sender: "me", text: "not sent yet", date: Date(), status: .queued)
        contact.devices[0].pending = [PendingPayload(payload: .receipt(ids: [UUID()], read: nil), message: nil),
                                      PendingPayload(payload: .receipt(ids: [UUID()], read: nil), message: written.id)]
        var data = AppData()
        data.contacts = [contact]
        data.decoySeed = Data(repeating: 7, count: 32)
        data.panicSeed = Data(repeating: 8, count: 32)

        let kept = AppModel.backupContents(of: data)
        #expect(kept.contacts.map(\.name) == ["Kai"], "Contacts themselves come back")
        #expect(kept.contacts[0].devices[0].pending.count == 1, "Only what isn't a message of yours stays queued")
        #expect(kept.contacts[0].devices[0].pending.allSatisfy { $0.message == nil })
        #expect(kept.decoySeed == nil && kept.panicSeed == nil && kept.clipParts.isEmpty)
    }

    @Test func onlyTheAdminKeyMakesAGuardian() throws {
        let admin = Curve25519.Signing.PrivateKey(), relay = Curve25519.Signing.PrivateKey(), owner = Data(repeating: 1, count: 32)
        let forged = try Collectible.make(.guardian, serial: 1, owner: owner, signedBy: relay)
        #expect(!forged.isGenuine(for: owner, adminKey: admin.publicKey.rawRepresentation, petKey: relay.publicKey.rawRepresentation))
        let real = try Collectible.make(.guardian, serial: 1, owner: owner, signedBy: admin)
        #expect(real.isGenuine(for: owner, adminKey: admin.publicKey.rawRepresentation, petKey: relay.publicKey.rawRepresentation))
    }

    @Test func aCallPacketNumberedAtTheLimitIsRefusedNotFatal() {
        var crypto = CallCrypto(key: Data(repeating: 9, count: 32), caller: false)
        let packet = Data([0]) + Data(repeating: 0xFF, count: 8) + Data(repeating: 0, count: 32)
        #expect(crypto.open(packet) == nil)
    }

    @Test func countsReadNaturally() {
        #expect(counted(1, "follower") == "1 follower")
        #expect(counted(0, "follower") == "0 followers")
        #expect(counted(12, "contact") == "12 contacts")
    }
}
