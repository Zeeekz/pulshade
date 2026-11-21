import Testing
import Foundation
@testable import Pulshade

/// A quote's author is taken from what this device already holds, never from the sender's claim.
@MainActor
@Suite(.serialized) struct QuoteAuthorTests {
    private func makeModel() async throws -> AppModel {
        let model = testModel("pulshade-quote-author")
        try await model.create(identity: .generate(), profile: Profile(name: "Me"), passcode: "test-passcode")
        return model
    }

    private func makeContact(_ name: String = "Them") -> (Identity, Contact) {
        let them = Identity.generate()
        var contact = Contact(fingerprint: them.fingerprint, name: name, signingKey: them.card.signing,
                              agreementKey: them.card.agreement, sendID: Mailbox.make().sendID, device: Data([1, 2, 3]))
        contact.persona = nil
        return (them, contact)
    }

    /// Delivers one ordinary message, which creates the direct chat, and returns its index.
    private func openDirectChat(_ model: AppModel, with contact: Contact) throws -> Int {
        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "hello", date: Date()), from: contact)
        return try #require(model.data.conversations.firstIndex { $0.kind == .direct && $0.members.contains(contact.fingerprint) })
    }

    @Test func aForgedMeQuoteShowsNoAuthor() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let (_, them) = makeContact()
        model.data.contacts = [them]
        let i = try openDirectChat(model, with: them)

        let quoted = UUID()
        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "look", date: Date(),
                                  reply: ReplyRef(id: quoted, author: "me", snippet: "not my words")), from: them)

        #expect(model.data.conversations[i].messages.last?.reply?.author == "")
    }

    @Test func aForgedFingerprintQuoteShowsNoAuthor() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let (_, them) = makeContact()
        model.data.contacts = [them]
        let i = try openDirectChat(model, with: them)
        let myFingerprint = try #require(model.identity).fingerprint

        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "look", date: Date(),
                                  reply: ReplyRef(id: UUID(), author: myFingerprint, snippet: "not my words")), from: them)

        #expect(model.data.conversations[i].messages.last?.reply?.author == "")
    }

    @Test func aQuoteOfMyRealMessageStaysMine() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let (_, them) = makeContact()
        model.data.contacts = [them]
        let i = try openDirectChat(model, with: them)
        let myID = UUID()
        model.data.conversations[i].messages.append(Message(id: myID, sender: "me", text: "my words"))

        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "reply", date: Date(),
                                  reply: ReplyRef(id: myID, author: "me", snippet: "my words")), from: them)

        #expect(model.data.conversations[i].messages.last?.reply?.author == "me")
    }

    @Test func aLikeOnMyStoryStillNamesMe() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let (_, them) = makeContact()
        model.data.contacts = [them]
        let i = try openDirectChat(model, with: them)
        let storyID = UUID()
        model.data.stories = [Story(id: storyID, author: "me", style: .text("my story", palette: 0))]

        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "❤️ Liked your story", date: Date(),
                                  reply: ReplyRef(id: storyID, author: them.fingerprint, snippet: "my story")), from: them)

        #expect(model.data.conversations[i].messages.last?.reply?.author == "me")
    }

    @Test func aQuoteOfAnUnknownIdShowsNoAuthor() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let (_, them) = makeContact()
        model.data.contacts = [them]
        let i = try openDirectChat(model, with: them)

        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "reply", date: Date(),
                                  reply: ReplyRef(id: UUID(), author: "someone else", snippet: "gone")), from: them)

        #expect(model.data.conversations[i].messages.last?.reply?.author == "")
    }

    @Test func aGroupQuoteOfAKnownMemberNamesThatMember() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let (_, alice) = makeContact("Alice")
        let (_, bob) = makeContact("Bob")
        model.data.contacts = [alice, bob]
        let groupID = UUID()
        var group = Conversation(id: groupID, kind: .group, title: "Group",
                                 members: [alice.fingerprint, bob.fingerprint])
        // `deliver` only reads groups in the shared-mailbox format; the quote lookup is what this test exercises.
        let settings = GroupSettings(group: groupID, kind: .group, version: 0, epoch: 0, title: "Group", about: nil,
                                     avatar: nil, owner: Data(), admins: [], mods: [], postPolicy: .everyone,
                                     disappearAfter: nil, members: [], epochCheck: nil, signer: Data(), signature: Data())
        group.shared = SharedGroup(settings: settings, epochs: [])
        model.data.conversations = [group]
        let aliceMessage = UUID()
        model.data.conversations[0].messages.append(Message(id: aliceMessage, sender: alice.fingerprint, text: "Alice's words"))

        model.deliver(WireMessage(id: UUID(), conversation: groupID, kind: .group, text: "quoting Alice", date: Date(),
                                  reply: ReplyRef(id: aliceMessage, author: "me", snippet: "Alice's words")), from: bob)

        #expect(model.data.conversations[0].messages.last?.reply?.author == alice.fingerprint)
    }
}
