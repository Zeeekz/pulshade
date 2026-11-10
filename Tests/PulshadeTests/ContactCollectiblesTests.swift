import Testing
import Foundation
import CryptoKit
@testable import Pulshade
@testable import PulshadeShared

struct ContactCollectiblesTests {
    private let item = Collectible(item: "partyhat", serial: 7, owner: Data(repeating: 1, count: 32), sig: Data(repeating: 2, count: 64))

    @Test func theListTravelsInAProfileAndOldOnesStillOpen() throws {
        let sent = Payload.profile(name: "Ann", avatar: nil, color: nil, collectibles: [item])
        let back = try JSONDecoder.pulshade.decode(Payload.self, from: JSONEncoder.pulshade.encode(sent))
        #expect(back == sent)
        let old = try JSONEncoder.pulshade.encode(Payload.profile(name: "Ann", avatar: nil, color: nil))
        #expect(try JSONDecoder.pulshade.decode(Payload.self, from: old) == .profile(name: "Ann", avatar: nil, color: nil))
    }

    @Test func aContactKeepsWhatTheyOwn() throws {
        var contact = Contact(fingerprint: "ab", signingKey: Data([1]), agreementKey: Data([2]), sendID: Data([3]))
        contact.collectibles = [item]
        let again = try JSONDecoder.pulshade.decode(Contact.self, from: JSONEncoder.pulshade.encode(contact))
        #expect(again.collectibles == [item])
    }

    @MainActor @Test func sharingSendsOnlyTheListAndCapsIt() {
        var profile = Profile()
        profile.collectionCode = "SECRET-BACKUP-CODE"
        #expect(AppModel.sharedCollectibles(profile) == nil)
        profile.collectibles = (1...60).map { Collectible(item: "partyhat", serial: UInt32($0), owner: item.owner, sig: item.sig) }
        #expect(AppModel.sharedCollectibles(profile)?.count == 40)
    }
}

/// A collection travelling to a contact through a real relay: only what the admin key signed for that account arrives.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct ContactCollectiblesDeliveryTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    /// Checks mailboxes until `done`, or for at most `seconds`.
    private func settle(_ models: AppModel..., seconds: Double, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnce() }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    @Test func aContactSeesOnlyWhatIsGenuine() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        await AdminKeyGate.shared.acquire()
        let saved = AppModel.adminKey
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = saved; Task { await AdminKeyGate.shared.release() } }
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, seconds: 30) {
            alice.visibleContacts.first?.devices.first?.session?.canSend == true && bob.visibleContacts.first?.name == "Alice"
        }
        let aliceKey = try #require(alice.me(nil)?.card.signing)

        let real = try Collectible.make(.pumpkin, serial: 3, owner: aliceKey, signedBy: admin)
        let forged = try Collectible.make(.topHat, serial: 1, owner: aliceKey, signedBy: Curve25519.Signing.PrivateKey())
        let someoneElses = try Collectible.make(.partyHat, serial: 2, owner: Data(repeating: 9, count: 32), signedBy: admin)
        alice.updateProfile { $0.collectibles = [real, forged, someoneElses] }
        await settle(alice, bob, seconds: 30) { bob.contact(alice.fingerprint)?.collectibles != nil }
        #expect(bob.contact(alice.fingerprint)?.collectibles == [real])
    }
}
