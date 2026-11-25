import Testing
import Foundation
@testable import Pulshade

/// Each friend's mailbox moves every week, and nothing sent to the old one is missed. Needs a throwaway relay
/// (scripts/test.sh starts one).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct MailboxMoveTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-move")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func until(_ models: [AppModel], seconds: Double = 20, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnceFully() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func aMovedMailboxIsFollowedAndTheOldOneIsReadUntilDone() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob")
        defer { alice.lock(); bob.lock() }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await until([alice, bob]) { alice.visibleContacts.contains { $0.name == "Bob" } && bob.visibleContacts.contains { $0.name == "Alice" } }
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let chat = alice.startConversation(kind: .direct, title: "", members: [bobFP])
        alice.send("hi", in: chat.id)
        await until([alice, bob]) { bob.data.conversations.contains { $0.messages.contains { $0.text == "hi" } } }
        let theirs = try #require(bob.data.conversations.first { $0.kind == .direct })
        bob.send("hey", in: theirs.id)
        await until([alice, bob]) { alice.conversation(chat.id)?.messages.contains { $0.text == "hey" } == true }

        let i = try #require(alice.data.contacts.firstIndex { $0.fingerprint == bobFP })
        let old = try #require(alice.data.contacts[i].receiveKey)
        // The relay gives the fresh mailbox the old one's standing only for a mailbox that has been collected from, and once.
        let relay = RelayClient(base: try #require(URL(string: AppData.defaultRelay)))
        #expect(await relay.moveMailbox(from: Mailbox.make().receiveKey, to: Mailbox.make().receiveKey) == false,
                "a made-up mailbox has no standing to pass on")
        // A week on: the mailbox moves.
        alice.data.contacts[i].mailboxSince = Date().addingTimeInterval(-AppModel.mailboxLife - 1)
        for move in alice.tendMailboxes() { await move.value }
        let fresh = try #require(alice.data.contacts[i].receiveKey)
        #expect(fresh != old)
        #expect(alice.data.contacts[i].formerMailboxes == [FormerMailbox(key: old, until: nil)], "the old one is still read")
        #expect(alice.currentLanes().values.contains { $0.contains(old) } && alice.currentLanes().values.contains { $0.contains(fresh) })
        // Not again until Bob's devices have followed.
        alice.data.contacts[i].mailboxSince = Date().addingTimeInterval(-AppModel.mailboxLife - 1)
        for move in alice.tendMailboxes() { await move.value }
        #expect(alice.data.contacts[i].receiveKey == fresh)
        alice.data.contacts[i].mailboxSince = Date()

        await until([alice, bob]) {
            bob.data.contacts.first { $0.fingerprint == alice.identity?.fingerprint }?.devices.first?.sendID == Mailbox.sendID(for: fresh)
        }
        #expect(bob.data.contacts.first { $0.fingerprint == alice.identity?.fingerprint }?.devices.first?.sendID == Mailbox.sendID(for: fresh),
                "Bob writes to the new mailbox")
        bob.send("after the move", in: theirs.id)
        await until([alice, bob]) { alice.conversation(chat.id)?.messages.contains { $0.text == "after the move" } == true }
        #expect(alice.conversation(chat.id)?.messages.contains { $0.text == "after the move" } == true)
        let former = try #require(alice.data.contacts[i].formerMailboxes?.first)
        #expect(former.until != nil, "every device of Bob's has written to the new one: the old one goes when its mail has run out")
        alice.tendMailboxes(now: Date().addingTimeInterval(AppModel.formerMailboxLife + 60))
        // Its mail has run out: the first mailbox is let go of (and by now the next week's move has come round).
        #expect(alice.data.contacts[i].formerMailboxes?.contains { $0.key == old } != true)
        #expect(!alice.currentLanes().values.contains { $0.contains(old) })
        #expect(await relay.moveMailbox(from: old, to: Mailbox.make().receiveKey) == false, "a mailbox is moved from only once")
    }
}
