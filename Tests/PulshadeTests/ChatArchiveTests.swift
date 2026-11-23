import Testing
import Foundation
@testable import Pulshade

/// Archiving chats, and doing things to several at once from the chat list.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct ChatArchiveTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        model.data.security.keepBackup = false
        return model
    }

    private func until(_ models: [AppModel], seconds: Double = 30, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnceFully() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// An archived chat comes back to the list with its next message; a muted one stays archived.
    @Test func aNewMessageBringsAnArchivedChatBackUnlessItsMuted() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await until([alice, bob]) { !alice.visibleContacts.isEmpty && !bob.visibleContacts.isEmpty }
        let aliceForBob = try #require(bob.visibleContacts.first)
        let bobChat = bob.startConversation(kind: .direct, title: "", members: [aliceForBob.fingerprint])
        bob.send("one", in: bobChat.id)
        await until([alice, bob]) { alice.data.conversations.contains { $0.kind == .direct && $0.messages.contains { $0.text == "one" } } }
        let chat = try #require(alice.data.conversations.first { $0.kind == .direct && $0.messages.contains { $0.text == "one" } })

        alice.setArchived([chat.id], true)
        #expect(alice.archivedConversations.map(\.id) == [chat.id])
        bob.send("two", in: bobChat.id)
        await until([alice, bob]) { alice.conversation(chat.id)?.messages.contains { $0.text == "two" } == true }
        #expect(alice.conversation(chat.id)?.archived == false, "back in the list with the new message")

        alice.setArchived([chat.id], true)
        alice.setMuted([chat.id], true)
        bob.send("three", in: bobChat.id)
        await until([alice, bob]) { alice.conversation(chat.id)?.messages.contains { $0.text == "three" } == true }
        #expect(alice.conversation(chat.id)?.archived == true, "muted: it stays archived")
        #expect(alice.conversation(chat.id)?.unread ?? 0 > 0)
    }

    /// Pinning, muting, reading and archiving several chats at once, and archiving surviving a save.
    @Test func severalChatsAtOnce() async throws {
        let alice = try await makeUser("Alice")
        defer { alice.lock() }
        let a = alice.startConversation(kind: .broadcast, title: "A", members: [])
        let b = alice.startConversation(kind: .broadcast, title: "B", members: [])
        let c = alice.startConversation(kind: .broadcast, title: "C", members: [])
        alice.setPinned([a.id, b.id], true)
        alice.setMuted([b.id, c.id], true)
        alice.setArchived([c.id], true)
        #expect(alice.conversation(a.id)?.pinned == true && alice.conversation(b.id)?.pinned == true && alice.conversation(c.id)?.pinned == false)
        #expect(alice.conversation(a.id)?.muted == false && alice.conversation(b.id)?.muted == true && alice.conversation(c.id)?.muted == true)
        #expect(alice.archivedConversations.map(\.id) == [c.id])

        let saved = try JSONEncoder().encode(try #require(alice.conversation(c.id)))
        #expect(try JSONDecoder().decode(Conversation.self, from: saved).archived)
        let plain = try JSONEncoder().encode(try #require(alice.conversation(a.id)))
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("archived"), "left out while off, as before")

        alice.delete([a.id, b.id])
        #expect(alice.conversation(a.id) == nil && alice.conversation(b.id) == nil && alice.conversation(c.id) != nil)
    }

    /// What deleting several chats at once says.
    @Test func deletingSeveralSaysWhatHappensToEach() {
        var mine = Conversation(kind: .group, title: "Mine", members: ["x"])
        mine.owner = "me"
        var theirs = Conversation(kind: .group, title: "Theirs", members: ["x"])
        theirs.owner = "x"
        let direct = Conversation(kind: .direct, title: "Bob", members: ["x"])
        let warning = Conversation.deleteWarning([mine, theirs, direct])
        #expect(warning.title == "Delete 3 chats?")
        #expect(warning.detail.contains("both sides") && warning.detail.contains("deleted for everyone") && warning.detail.contains("you leave"))
        #expect(Conversation.deleteWarning([direct]).title == direct.deleteWarning.title)
    }
}
