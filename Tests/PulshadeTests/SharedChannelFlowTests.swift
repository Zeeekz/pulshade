import Testing
import Foundation
@testable import Pulshade

/// Channels that share one mailbox, end to end through a real relay (see scripts/test.sh): followers hold the channel's key
/// but are in nobody's list, the staff keep a hidden roster to rekey from, and an older channel moves over by itself.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct SharedChannelFlowTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-channel")
        model.sharedGroupsEnabled = true
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func settle(_ models: AppModel..., rounds: Int = 6) async {
        for _ in 0..<rounds { for m in models { await m.syncOnce() } }
    }

    private func until(_ models: [AppModel], seconds: Double = 20, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnce() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Alice knows Bob and Cara and their apps are known to take part; Bob and Cara don't know each other.
    private func trio() async throws -> (AppModel, AppModel, AppModel, String, String) {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob"), cara = try await makeUser("Cara")
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint
        for fp in [bobFP, caraFP] {
            let chat = alice.startConversation(kind: .direct, title: "", members: [fp])
            alice.send("hi", in: chat.id)
        }
        await settle(alice, bob, cara)
        for m in [bob, cara] {
            if let chat = m.data.conversations.first(where: { $0.kind == .direct }) { m.send("hey", in: chat.id) }
        }
        await settle(alice, bob, cara)
        return (alice, bob, cara, bobFP, caraFP)
    }

    private func joined(_ id: UUID, _ models: AppModel...) -> Bool {
        models.allSatisfy { $0.conversation(id)?.shared != nil }
    }

    @Test func followersReadOneMailboxAndNeverSeeEachOther() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [bobFP, caraFP])
        #expect(channel.shared?.settings.kind == .channel && channel.shared?.settings.postPolicy == .admins)
        await until([alice, bob, cara]) { joined(channel.id, bob, cara) && alice.conversation(channel.id)?.shared?.roster?.live.count == 2 }
        #expect(alice.conversation(channel.id)?.shared?.roster?.live.count == 2, "both are in the staff's roster")
        #expect(alice.conversation(channel.id)?.shared?.settings.members.count == 1, "and not in the settings")

        alice.send("first drop", in: channel.id)
        await until([alice, bob, cara]) {
            bob.conversation(channel.id)?.messages.last?.text == "first drop" && cara.conversation(channel.id)?.messages.last?.text == "first drop"
        }
        #expect(bob.conversation(channel.id)?.messages.last?.text == "first drop")
        #expect(cara.conversation(channel.id)?.messages.last?.text == "first drop")

        // Bob holds nothing about Cara: not in the settings he holds, not among his contacts, not in the roster.
        let bobs = try #require(bob.conversation(channel.id))
        #expect(bobs.shared?.settings.members.count == 1 && bobs.shared?.roster == nil)
        #expect(bobs.members.count == 1, "only the owner")
        #expect(!bob.data.contacts.contains { $0.name == "Cara" })
        #expect(!bob.canPost(in: bobs))

        // A follower's attempt to post goes nowhere.
        bob.send("sneaky", in: channel.id)
        await settle(alice, bob, cara)
        #expect(alice.conversation(channel.id)?.messages.contains { $0.text == "sneaky" } == false)
        #expect(cara.conversation(channel.id)?.messages.contains { $0.text == "sneaky" } == false)

        // The roster lives in a mailbox only staff have the key to: a follower has no such key, and so no way to read or
        // even find it, and sees nothing of followers joining.
        #expect(alice.conversation(channel.id)?.shared?.staffEpoch != nil)
        #expect(bob.conversation(channel.id)?.shared?.staffKey == nil && bob.conversation(channel.id)?.shared?.staffEpoch == nil)
        #expect(bob.conversation(channel.id)?.shared?.heldMail?.isEmpty ?? true)

        // The owner sees the followers she invited, by the accounts she knows them as.
        #expect(Set(alice.conversation(channel.id)?.members ?? []) == [bobFP, caraFP])
    }

    @Test func aFollowerTakenOutCantReadWhatFollows() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [bobFP, caraFP])
        await until([alice, bob, cara]) { joined(channel.id, bob, cara) && alice.conversation(channel.id)?.shared?.roster?.live.count == 2 }
        alice.send("before", in: channel.id)
        await until([alice, bob, cara]) { bob.conversation(channel.id)?.messages.count == 1 && cara.conversation(channel.id)?.messages.count == 1 }
        let epochBefore = try #require(alice.conversation(channel.id)?.shared?.settings.epoch)

        alice.removeMember(channel.id, bobFP)
        #expect(alice.conversation(channel.id)?.shared?.settings.epoch == epochBefore + 1, "a new key they don't get")
        #expect(alice.conversation(channel.id)?.shared?.roster?.live.count == 1)
        alice.send("after", in: channel.id)
        await until([alice, bob, cara]) { cara.conversation(channel.id)?.messages.last?.text == "after" }
        await settle(alice, bob, cara)
        #expect(cara.conversation(channel.id)?.messages.last?.text == "after", "the others carry on")
        #expect(cara.conversation(channel.id)?.shared?.settings.epoch == epochBefore + 1)
        #expect(bob.conversation(channel.id)?.messages.map(\.text) == ["before"], "and he reads nothing more")
        #expect(bob.conversation(channel.id)?.shared?.epochs.map(\.number) == [epochBefore], "the new key never reached him")
    }

    @Test func aFollowerMadeAdminPostsAndTheStaffShareOneRoster() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [bobFP])
        await until([alice, bob]) { joined(channel.id, bob) && alice.conversation(channel.id)?.shared?.roster?.live.count == 1 }

        alice.setAdmin(channel.id, bobFP, true)
        await until([alice, bob, cara]) { bob.conversation(channel.id).map(bob.canPost(in:)) == true }
        #expect(bob.conversation(channel.id).map(bob.canPost(in:)) == true, "he answered with a card and is staff now")
        #expect(alice.conversation(channel.id)?.shared?.roster?.live.isEmpty == true, "and is no longer a follower")

        // Cara follows later; both staff end up with her in their roster, and she isn't in the settings.
        alice.addMembers(channel.id, [caraFP])
        await until([alice, bob, cara]) {
            bob.conversation(channel.id)?.shared?.roster?.live.count == 1 && joined(channel.id, cara)
        }
        let key = try #require(bob.conversation(channel.id)?.shared?.roster?.live.first?.signingKey)
        #expect(alice.conversation(channel.id)?.shared?.roster?.live.first?.signingKey == key)
        bob.send("admin post", in: channel.id)
        await until([alice, bob, cara]) { cara.conversation(channel.id)?.messages.last?.text == "admin post" }
        #expect(cara.conversation(channel.id)?.messages.last?.text == "admin post")
        #expect(cara.conversation(channel.id)?.shared?.settings.members.count == 2, "only the two staff are named")

        // Bob, who never met Cara as a contact, can still take her out: the new key goes to the rest of the roster.
        let epoch = try #require(bob.conversation(channel.id)?.shared?.settings.epoch)
        bob.removeFollower(key, in: channel.id)
        #expect(bob.conversation(channel.id)?.shared?.settings.epoch == epoch + 1)
        await until([alice, bob, cara]) { alice.conversation(channel.id)?.shared?.settings.epoch == epoch + 1 }
        #expect(alice.conversation(channel.id)?.shared?.settings.epoch == epoch + 1)
        bob.send("after", in: channel.id)
        await settle(alice, bob, cara)
        #expect(alice.conversation(channel.id)?.messages.last?.text == "after")
        #expect(cara.conversation(channel.id)?.messages.last?.text == "admin post")
    }

    @Test func anOlderChannelMovesOverByItselfAndHidesItsFollowers() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        alice.sharedChannelsEnabled = false
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [bobFP, caraFP])
        #expect(channel.shared == nil, "made the old way")
        alice.send("old drop", in: channel.id)
        await until([alice, bob, cara]) { bob.conversation(channel.id)?.messages.count == 1 && cara.conversation(channel.id)?.messages.count == 1 }
        #expect(bob.conversation(channel.id)?.shared == nil, "the old way")

        alice.sharedChannelsEnabled = true
        alice.moveGroupsOver()
        await until([alice, bob, cara]) { joined(channel.id, bob, cara) }
        #expect(alice.conversation(channel.id)?.shared?.settings.members.count == 1)
        #expect(bob.conversation(channel.id)?.members.count == 1, "now only the owner is listed")
        #expect(bob.conversation(channel.id)?.messages.first?.text == "old drop", "the history stays")
        alice.send("new drop", in: channel.id)
        await until([alice, bob, cara]) {
            bob.conversation(channel.id)?.messages.last?.text == "new drop" && cara.conversation(channel.id)?.messages.last?.text == "new drop"
        }
        #expect(bob.conversation(channel.id)?.messages.last?.text == "new drop")
        #expect(cara.conversation(channel.id)?.messages.last?.text == "new drop")
    }

    @Test func anAdminLetGoLosesTheRosterMailbox() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [bobFP])
        await until([alice, bob]) { joined(channel.id, bob) && alice.conversation(channel.id)?.shared?.roster?.live.count == 1 }
        alice.setAdmin(channel.id, bobFP, true)
        await until([alice, bob]) { bob.conversation(channel.id)?.shared?.staffKey != nil && bob.conversation(channel.id).map(bob.canPost(in:)) == true }
        let before = try #require(alice.conversation(channel.id)?.shared?.staffKey)
        #expect(bob.conversation(channel.id)?.shared?.staffKey == before, "the owner gave him the key with the ask")

        // Once he's staff, Alice's list shows him by his card for the channel.
        let bobAsStaff = try #require(alice.conversation(channel.id)?.admins.first)
        alice.setAdmin(channel.id, bobAsStaff, false)
        let after = try #require(alice.conversation(channel.id)?.shared?.staffKey)
        #expect(after != before, "a new key, so the old one opens nothing")
        alice.addMembers(channel.id, [caraFP])
        await until([alice, bob, cara]) { joined(channel.id, cara) && alice.conversation(channel.id)?.shared?.roster?.live.count == 1 }
        await settle(alice, bob, cara)
        #expect(bob.conversation(channel.id)?.shared?.roster?.live.isEmpty ?? true, "he never hears of the follower who came after")
    }
}
