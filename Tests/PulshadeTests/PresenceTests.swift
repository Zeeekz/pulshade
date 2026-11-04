import Testing
import Foundation
@testable import Pulshade

/// Online status between two identities through a real relay (see RelayFlowTests for how to start one).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct PresenceTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        model.presenceAlwaysActive = true
        return model
    }

    private func settle(_ models: AppModel..., seconds: Int = 4) async {
        for _ in 0..<seconds {
            for m in models { await m.syncOnce() }
            try? await Task.sleep(for: .seconds(1))
        }
        for m in models { await m.syncOnce() }
    }

    @Test func statusShowsOnlyWhenBothSidesShowTheirs() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, seconds: 1)
        let aliceFP = alice.fingerprint, bobFP = bob.fingerprint

        // Off by default: nothing is shown either way.
        #expect(!alice.data.security.onlineStatus)
        await settle(alice, bob)
        #expect(!alice.isOnline(bobFP) && !bob.isOnline(aliceFP))

        // Only Bob turns it on: he sends nothing to Alice, who asked for nothing, and sees nothing of hers.
        bob.updateSecurity { $0.onlineStatus = true }
        await settle(alice, bob)
        #expect(!alice.isOnline(bobFP) && !bob.isOnline(aliceFP))

        // Both on: each sees the other.
        alice.updateSecurity { $0.onlineStatus = true }
        await settle(alice, bob, seconds: 6)
        #expect(alice.isOnline(bobFP) && bob.isOnline(aliceFP))

        // Bob turns it off: Alice stops seeing him, and he stops seeing her.
        bob.updateSecurity { $0.onlineStatus = false }
        await settle(alice, bob)
        #expect(!alice.isOnline(bobFP) && !bob.isOnline(aliceFP))
    }

    @Test func blockedContactsAreNeverShownOnline() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, seconds: 1)
        for m in [alice, bob] { m.updateSecurity { $0.onlineStatus = true } }
        await settle(alice, bob, seconds: 6)
        let bobFP = bob.fingerprint
        #expect(alice.isOnline(bobFP))
        alice.data.blocked.append(bobFP)
        #expect(!alice.isOnline(bobFP))
    }
}

@Suite struct PresenceWireTests {
    @Test func presenceAndRequestsRoundTripAndAreEphemeral() throws {
        for payload in [Payload.presence(online: true), .presence(online: false), .wantsPresence(true)] {
            let back = try JSONDecoder.pulshade.decode(Payload.self, from: try JSONEncoder.pulshade.encode(payload))
            #expect(back == payload)
        }
        #expect(Payload.presence(online: true).isEphemeral)
        #expect(Payload.typing(conversation: nil).isEphemeral)
        #expect(!Payload.wantsPresence(true).isEphemeral)
    }

    @Test func oldContactsWithoutPresenceFieldsStillLoad() throws {
        var contact = Contact(fingerprint: "ab", signingKey: Data([1]), agreementKey: Data([2]), sendID: Data([3]))
        contact.wantsMyPresence = true
        let data = try JSONEncoder.pulshade.encode(contact)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "wantsMyPresence")
        json.removeValue(forKey: "toldPresence")
        let old = try JSONDecoder.pulshade.decode(Contact.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.wantsMyPresence == nil && old.toldPresence == nil)
    }
}
