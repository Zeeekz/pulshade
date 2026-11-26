import Testing
import Foundation
@testable import Pulshade

/// Someone found by username can be messaged straight away: their chat waits under Message requests on the other phone,
/// and adding to contacts is a choice. End to end through a real relay (see scripts/test.sh).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct MessageRequestTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-msgreq")
        model.requestsFromSearchForTests = false
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

    private func settle(_ models: AppModel..., rounds: Int = 6) async {
        for _ in 0..<rounds { for m in models { await m.syncOnceFully() } }
    }

    /// Bob finds Alice and writes. Her phone opens it as a message request (no read receipt, not a contact on either
    /// side); her reply takes it into her chats; either can add the other to contacts.
    @Test func searchingOpensAChatThatWaitsAsARequest() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        let handle = "alice_\(Int.random(in: 10000...99999))"
        try await alice.publishProfile(handle: handle)
        let found = try #require(try await bob.findProfile(handle))

        let chat = try #require(bob.startChat(with: found, addToContacts: false))
        bob.send("hi, saw your photos", in: chat.id)
        #expect(bob.visibleContacts.isEmpty, "not in Bob's contacts")
        await until([alice, bob]) { alice.messageRequests.first?.messages.contains { $0.text == "hi, saw your photos" } == true }
        let request = try #require(alice.messageRequests.first)
        #expect(request.messages.contains { $0.text == "hi, saw your photos" }, "what he wrote arrives once her app opened the chat")
        #expect(alice.requests.isEmpty, "no request to accept")
        #expect(alice.visibleContacts.isEmpty, "and not in her contacts")
        #expect(alice.isStranger(in: request))
        await settle(alice, bob)
        #expect(bob.conversation(chat.id)?.messages.first { $0.text == "hi, saw your photos" }?.status != .read, "no read receipt from a request")

        // Her reply takes it into her chats, and reaches him.
        alice.send("thanks!", in: request.id)
        #expect(alice.conversation(request.id)?.isRequest == nil)
        await until([alice, bob]) { bob.conversation(chat.id)?.messages.contains { $0.text == "thanks!" } == true }
        #expect(bob.conversation(chat.id)?.messages.contains { $0.text == "thanks!" } == true)

        // Either can add the other to contacts.
        alice.addToContacts(request.members[0], persona: nil)
        #expect(alice.visibleContacts.map(\.name) == ["Bob"])
        #expect(bob.visibleContacts.isEmpty, "his side is his own choice")
    }

    /// With "Only people I accept", someone found by username sends a request first, as before.
    @Test func contactsOnlyKeepsTheRequest() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        alice.updateSecurity { $0.messagesFrom = .contacts }
        let handle = "alice_\(Int.random(in: 10000...99999))"
        try await alice.publishProfile(handle: handle)
        let found = try #require(try await bob.findProfile(handle))
        let chat = try #require(bob.startChat(with: found, addToContacts: true))
        bob.send("hello?", in: chat.id)
        await until([alice, bob]) { !alice.requests.isEmpty }
        #expect(alice.messageRequests.isEmpty && alice.requests.count == 1, "a request to accept, no chat")
        let asked = try #require(alice.requests.first)
        _ = try #require(alice.acceptRequest(asked.id))
        await until([alice, bob]) { alice.data.conversations.contains { $0.kind == .direct && $0.messages.contains { $0.text == "hello?" } } }
        #expect(alice.data.conversations.contains { $0.kind == .direct && $0.messages.contains { $0.text == "hello?" } }, "what he wrote waited and came")
        #expect(bob.visibleContacts.map(\.name) == ["Alice"], "he chose to add her")
    }
}
