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

    @Test func theSendSoundIsQuietShortAndTheSameEveryTime() {
        let first = SendSound.samples()
        #expect(first == SendSound.samples())
        #expect(first.count == Int(SendSound.seconds * Double(SendSound.sampleRate)))
        let peak = first.map { abs(Int($0)) }.max() ?? 0
        #expect(peak > 5_000 && peak <= Int(0.31 * Double(Int16.max)), "audible but quiet: \(peak)")
        #expect(first.last == 0, "ends in silence, no click")
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

    @Test func theBackupHoldsNoChatKeysExceptForAContactStillWaiting() throws {
        let them = Identity.generate(), me = Identity.generate()
        func ratchet() throws -> Ratchet {
            let (pending, request) = try Handshake.start()
            let (_, answer) = try Handshake.accept(request, me: them, initiatorAgreement: me.card.agreement)
            return try Handshake.complete(pending, answer, me: me, responderAgreement: them.card.agreement)
        }
        var known = Contact(fingerprint: them.fingerprint, name: "Kai", signingKey: them.card.signing,
                            agreementKey: them.card.agreement, sendID: Mailbox.make().sendID)
        known.devices[0].session = try ratchet()
        known.devices[0].handshake = try Handshake.start().0
        known.devices[0].earlierAsks = [try Handshake.start().0]
        known.devices[0].acceptedHello = Data.random(32)
        known.devices[0].acceptedHelloAt = Date()
        var waiting = Contact(fingerprint: Identity.generate().fingerprint, name: "Sam", signingKey: them.card.signing,
                              agreementKey: them.card.agreement, sendID: Mailbox.make().sendID)
        waiting.awaitingAcceptance = true
        waiting.devices[0].handshake = try Handshake.start().0
        var data = AppData()
        data.contacts = [known, waiting]

        let kept = AppModel.backupContents(of: data)
        let device = kept.contacts[0].devices[0]
        #expect(kept.contacts.map(\.name) == ["Kai", "Sam"], "Contacts still come back")
        #expect(device.session == nil && device.handshake == nil && device.earlierAsks == nil)
        #expect(device.acceptedHello == nil && device.acceptedHelloAt == nil)
        #expect(kept.contacts[1].devices[0].handshake != nil, "Only an ask nobody has accepted yet can't be started again")
        let text = String(decoding: try JSONEncoder.pulshade.encode(kept), as: UTF8.self)
        #expect(!text.contains("\"rk\"") && !text.contains("\"cks\"") && !text.contains("\"dhs\""), "No ratchet state in the file")
        let before = String(decoding: try JSONEncoder.pulshade.encode(data), as: UTF8.self)
        #expect(before.contains("\"rk\""), "the check above can tell a ratchet when one is there")
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

    @Test func anExistingAccountIsNeverOverwrittenByALinkOrRestore() throws {
        let vault = Vault(directory: testDirectory("pulshade-hardening"))
        try vault.create(.generate(), passcode: "real-pass")
        #expect(throws: VaultError.self) { try vault.create(.generate(), passcode: "other-pass") }
        #expect(throws: Never.self) { try vault.create(.generate(), passcode: "other-pass", replacing: true) }
    }

    @Test func aNoTraceWipeTakesEveryProfileWithIt() throws {
        let dir = testDirectory("pulshade-hardening")
        let vault = Vault(directory: dir)
        try vault.create(.generate(), passcode: "real-pass")
        let nested = dir.appendingPathComponent("profiles/second", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("left behind".utf8).write(to: nested.appendingPathComponent("data-abc.vault"))
        vault.destroy(leavingNoTrace: true)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func maximumPrivacyTurnsOffEveryOutboundLever() {
        let s = SecuritySettings.strictest
        #expect(!s.notifications && !s.pushWake && !s.pushRequests && !s.deliveryReceipts && !s.readReceipts)
        #expect(!s.typingIndicators && !s.onlineStatus && !s.linkPreviews && !s.allowForwarding && s.lockedDelivery == false)
        var adopted = SecuritySettings()
        adopted.adopt(s)
        #expect(!adopted.notifications && !adopted.pushWake && !adopted.pushRequests && !adopted.allowForwarding)
        #expect(adopted.lockedDelivery == false)
    }

    @Test func collectingWhileLockedIsOffUnlessChosenByHand() throws {
        #expect(SecuritySettings().lockedDeliveryChosen == false)
        // A vault written when it was automatic (nothing saved) comes back off, even on the fast connection.
        var fast = SecuritySettings()
        fast.tor = false
        let old = try JSONDecoder().decode(SecuritySettings.self, from: try JSONEncoder().encode(fast))
        #expect(old.lockedDelivery == nil && old.lockedDeliveryChosen == false)
        // Someone who turned it on keeps it, and someone who turned it off keeps that.
        var chosen = fast
        chosen.lockedDeliveryChosen = true
        let on = try JSONDecoder().decode(SecuritySettings.self, from: try JSONEncoder().encode(chosen))
        #expect(on.lockedDeliveryChosen == true)
        chosen.lockedDeliveryChosen = false
        let off = try JSONDecoder().decode(SecuritySettings.self, from: try JSONEncoder().encode(chosen))
        #expect(off.lockedDeliveryChosen == false)
        #expect(LockedDeliveryWarning.confirm.contains("pretend to be you"))
    }
}
