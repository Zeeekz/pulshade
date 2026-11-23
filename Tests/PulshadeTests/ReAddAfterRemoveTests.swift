import Testing
import Foundation
@testable import Pulshade

/// Removing a friend while keys are still being set up keeps a hidden record holding the notice that tells their app.
/// Adding them back must not let that old notice go out afterwards and undo the new friendship.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct ReAddAfterRemoveTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-readd")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func settle(_ models: AppModel..., rounds: Int = 6) async {
        for _ in 0..<rounds { for m in models { await m.syncOnceFully() } }
    }

    private func until(_ models: AppModel..., seconds: Double = 30, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end {
            for m in models { await m.syncOnceFully() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func backupOf(_ model: AppModel) throws -> AppData {
        try JSONDecoder.pulshade.decode(AppData.self, from: JSONEncoder.pulshade.encode(AppModel.backupContents(of: model.data)))
    }

    /// Zee logs back in, so her keys with Bob need his answer; Bob's app is closed, so they stay unready, and she
    /// removes him then. Returns her restored copy, with the removal notice still waiting inside his hidden record.
    private func removedWhileKeysPending(_ zee: AppModel, _ bob: AppModel, tag: String) async throws -> AppModel {
        _ = try #require(bob.addContact(code: zee.makeInviteCode(), nickname: ""))
        let bobFP = try #require(bob.identity?.fingerprint)
        // Friends on both sides first: under load a few sync rounds may not be enough, and a backup without Bob in it
        // would leave nothing to remove.
        await until(zee, bob, seconds: 60) { zee.contact(bobFP, in: nil)?.devices.first?.session?.canSend == true }
        try #require(zee.contact(bobFP, in: nil)?.devices.first?.session?.canSend == true, "Zee and Bob became friends")
        let seed = try #require(zee.identity?.seed)
        var backup = try backupOf(zee)
        // No spare key from Bob: whether one is up yet depends on timing, and taking it would ready the keys without him.
        for i in backup.contacts.indices { for d in backup.contacts[i].devices.indices { backup.contacts[i].devices[d].takesSpares = nil } }
        // Her old copy is only locked, not burned: a Burn closes every relay connection in the process, which would cut off
        // tests running alongside this one.
        zee.lock()
        bob.lock()
        let restored = testModel("pulshade-readd-\(tag)")
        try await Task.sleep(for: .seconds(1.1))
        try await restored.restore(seed: seed, passcode: "new-device", from: backup)
        await settle(restored, rounds: 3)
        #expect(restored.contact(bobFP)?.devices.first?.session?.canSend != true, "keys still being set up")
        try #require(restored.contact(bobFP, in: nil)?.devices.isEmpty == false, "Bob came back with the backup")
        restored.removeContact(bobFP, persona: nil)
        #expect(restored.contact(bobFP)?.departing != nil, "kept, hidden, with the notice waiting")
        return restored
    }

    private func talks(_ zee: AppModel, _ bob: AppModel) async throws {
        let zeeFP = try #require(zee.identity?.fingerprint), bobFP = try #require(bob.identity?.fingerprint)
        let chat = zee.data.conversations.first { $0.kind == .direct && $0.members == [bobFP] }
            ?? zee.startConversation(kind: .direct, title: "", members: [bobFP])
        zee.send("can you see this", in: chat.id)
        await until(zee, bob, seconds: 40) {
            bob.data.conversations.contains { $0.kind == .direct && $0.messages.contains { $0.text == "can you see this" } }
        }
        #expect(bob.contact(zeeFP) != nil && bob.contact(zeeFP)?.hidden != true, "Bob still has Zee as a friend")
        #expect(bob.data.conversations.contains { $0.kind == .direct && $0.messages.contains { $0.text == "can you see this" } },
                "Bob reads what Zee sends after adding him back")
        #expect(zee.visibleContacts.contains { $0.fingerprint == bobFP }, "and Zee still has Bob")
    }

    /// Zee adds Bob back by his username.
    @Test func addingBackByUsername() async throws {
        let zee = try await makeUser("Zee"), bob = try await makeUser("Bob")
        defer { for m in [zee, bob] { m.lock() } }
        let handle = "bob_\(Int.random(in: 10000...99999))"
        try await bob.publishProfile(handle: handle)
        let restored = try await removedWhileKeysPending(zee, bob, tag: "handle")
        defer { restored.lock() }
        let found = try #require(try await restored.findProfile(handle))
        _ = try #require(restored.sendRequest(to: found, note: "sorry"))
        #expect(await bob.unlock(passcode: "test-passcode"))
        await until(restored, bob, seconds: 40) { !bob.requests.isEmpty }
        let request = try #require(bob.requests.first)
        _ = try #require(bob.acceptRequest(request.id))
        await until(restored, bob, seconds: 40) { !restored.sentRequests.contains { $0.fingerprint == found.fingerprint } }
        try await talks(restored, bob)
    }

    /// Zee adds Bob back with his invite code.
    @Test func addingBackByCode() async throws {
        let zee = try await makeUser("Zee"), bob = try await makeUser("Bob")
        defer { for m in [zee, bob] { m.lock() } }
        let restored = try await removedWhileKeysPending(zee, bob, tag: "code")
        defer { restored.lock() }
        #expect(await bob.unlock(passcode: "test-passcode"))
        _ = try #require(restored.addContact(code: bob.makeInviteCode(), nickname: ""))
        await settle(restored, bob, rounds: 8)
        try await talks(restored, bob)
    }

    /// Bob, who has lost Zee on his side, sends her a request by username and she accepts it.
    @Test func acceptingTheirRequest() async throws {
        let zee = try await makeUser("Zee"), bob = try await makeUser("Bob")
        defer { for m in [zee, bob] { m.lock() } }
        let restored = try await removedWhileKeysPending(zee, bob, tag: "accept")
        defer { restored.lock() }
        let handle = "zee_\(Int.random(in: 10000...99999))"
        try await restored.publishProfile(handle: handle)
        #expect(await bob.unlock(passcode: "test-passcode"))
        let zeeFP = try #require(restored.identity?.fingerprint)
        bob.data.contacts.removeAll { $0.fingerprint == zeeFP }
        bob.data.conversations.removeAll { $0.kind == .direct }
        let found = try #require(try await bob.findProfile(handle))
        _ = try #require(bob.sendRequest(to: found, note: "it's me"))
        await until(restored, bob) { !restored.requests.isEmpty }
        let request = try #require(restored.requests.first)
        _ = try #require(restored.acceptRequest(request.id))
        await settle(restored, bob, rounds: 8)
        try await talks(restored, bob)
    }
}
