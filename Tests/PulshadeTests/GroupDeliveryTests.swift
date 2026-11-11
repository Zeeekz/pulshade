import Testing
import Foundation
@testable import Pulshade

/// Posts in a group that shares one mailbox that must not get lost: posted again if the mailbox never gives them back,
/// asked for again by a member who was away longer than the relay keeps mail, and kept no longer than their message.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct GroupDeliveryTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-delivery")
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

    /// Alice, Bob and Cara in one shared group.
    private func group() async throws -> (AppModel, AppModel, AppModel, UUID) {
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
        let made = alice.startConversation(kind: .group, title: "Night owls", members: [bobFP, caraFP])
        await until([alice, bob, cara]) {
            bob.conversation(made.id)?.shared?.joining == false && cara.conversation(made.id)?.shared?.joining == false
                && alice.conversation(made.id)?.members.count == 2
        }
        return (alice, bob, cara, made.id)
    }

    @Test func newEpochsKeepMailForThreeDays() async throws {
        let (alice, bob, cara, id) = try await group()
        defer { for m in [alice, bob, cara] { m.lock() } }
        #expect(alice.conversation(id)?.shared?.current?.days == 3)
        #expect(bob.conversation(id)?.shared?.current?.days == 3)
    }

    @Test func aPostTheMailboxNeverGaveBackIsPostedAgainAndNobodySeesItTwice() async throws {
        let (alice, bob, cara, id) = try await group()
        defer { for m in [alice, bob, cara] { m.lock() } }
        bob.send("is anyone there", in: id)
        await until([alice, bob, cara]) {
            cara.conversation(id)?.messages.contains { $0.text == "is anyone there" } == true
                && bob.conversation(id)?.shared?.kept?.contains { $0.seen } == true
        }
        let before = try #require(bob.conversation(id)?.shared?.kept?.first { $0.chat })
        #expect(before.seen, "read back from the mailbox, so nothing to post again")
        #expect(before.tries == 0)

        // The relay lost it: as if it never came back, long enough ago, and the mailbox has been read since.
        var shared = try #require(bob.conversation(id)?.shared)
        let j = try #require(shared.kept?.firstIndex { $0.id == before.id })
        shared.kept?[j].seen = false
        shared.kept?[j].lastTry = Date().addingTimeInterval(-3600)
        bob.data.conversations[try #require(bob.data.conversations.firstIndex { $0.id == id })].shared = shared
        await until([alice, bob, cara]) { bob.conversation(id)?.shared?.kept?.first { $0.id == before.id }?.tries == 1 }
        let after = try #require(bob.conversation(id)?.shared?.kept?.first { $0.id == before.id })
        #expect(after.tries == 1, "posted again once")
        #expect(after.blob == before.blob, "the very same sealed bytes, so no key is used twice")
        await settle(alice, bob, cara)
        #expect(after.index == before.index)
        #expect(cara.conversation(id)?.messages.filter { $0.text == "is anyone there" }.count == 1, "a copy someone already has is ignored")
        #expect(alice.conversation(id)?.messages.filter { $0.text == "is anyone there" }.count == 1)
    }

    @Test func aMemberWhoWasAwayLongerThanTheRelayKeepsMailGetsWhatTheyMissed() async throws {
        let (alice, bob, cara, id) = try await group()
        defer { for m in [alice, bob, cara] { m.lock() } }
        // Cara is away. Bob says something, and by the time Cara is back the relay would have let it go: her place in the
        // mailbox is after it, and she last read it five days ago.
        bob.send("while you were gone", in: id)
        await until([bob]) { bob.conversation(id)?.shared?.kept?.contains { $0.chat && $0.seen } == true }
        let epoch = try #require(bob.conversation(id)?.shared?.current?.number)
        let at = try #require(bob.conversation(id)?.shared?.cursors[String(epoch)])
        let c = try #require(cara.data.conversations.firstIndex { $0.id == id })
        cara.data.conversations[c].shared?.cursors[String(epoch)] = at
        cara.data.conversations[c].shared?.lastFetch = Date().addingTimeInterval(-5 * 86_400)
        #expect(cara.conversation(id)?.messages.contains { $0.text == "while you were gone" } != true)

        await until([alice, bob, cara]) { cara.conversation(id)?.messages.contains { $0.text == "while you were gone" } == true }
        #expect(cara.conversation(id)?.messages.filter { $0.text == "while you were gone" }.count == 1,
                "she asked, Bob's phone posted it again, and she has it")
        #expect(cara.conversation(id)?.shared?.catchUpSince == nil)
    }

    @Test func aKeptPostGoesWithItsMessage() async throws {
        let (alice, bob, cara, id) = try await group()
        defer { for m in [alice, bob, cara] { m.lock() } }
        bob.send("oops", in: id)
        await until([alice, bob, cara]) { cara.conversation(id)?.messages.contains { $0.text == "oops" } == true }
        let mine = try #require(bob.conversation(id)?.messages.last { $0.text == "oops" })
        #expect(bob.conversation(id)?.shared?.kept?.contains { $0.about == mine.id } == true)
        bob.unsend(mine.id, in: id)
        await settle(alice, bob, cara)
        #expect(bob.conversation(id)?.shared?.kept?.contains { $0.about == mine.id } != true, "an unsent message isn't kept to be posted again")
    }
}
