import Testing
import Foundation
@testable import Pulshade

/// Storage usage is grouped by chat and stories, and clearing one scope leaves text and other scopes alone.
@MainActor
@Suite(.serialized) struct StorageSettingsTests {
    private func makeModel() async throws -> AppModel {
        let model = testModel("pulshade-storage-settings")
        try await model.create(identity: .generate(), profile: Profile(name: "Me"), passcode: "test-passcode")
        return model
    }

    private func makeContact(_ name: String) -> Contact {
        let them = Identity.generate()
        var contact = Contact(fingerprint: them.fingerprint, name: name, signingKey: them.card.signing,
                              agreementKey: them.card.agreement, sendID: Mailbox.make().sendID, device: Data([1]))
        contact.persona = nil
        return contact
    }

    @Test func usageIsPerChatAndStoriesAndClearingOneLeavesText() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let alice = makeContact("Alice")
        let bob = makeContact("Bob")
        model.data.contacts = [alice, bob]

        var chatA = Conversation(kind: .direct, title: "Alice", members: [alice.fingerprint])
        chatA.messages = [Message(sender: alice.fingerprint, text: "keep this", image: Data(count: 1_000_000))]
        var chatB = Conversation(kind: .direct, title: "Bob", members: [bob.fingerprint])
        chatB.messages = [Message(sender: bob.fingerprint, text: "theirs", image: Data(count: 500_000))]
        model.data.conversations = [chatA, chatB]
        let story = Story(id: UUID(), author: alice.fingerprint, style: .image(Data(count: 250_000), caption: "story"))
        let textStory = Story(id: UUID(), author: alice.fingerprint, style: .text("words only", palette: 0))
        model.data.stories = [story, textStory]
        model.rebuildReceivedMedia()

        let usage = model.mediaUsage()
        #expect(usage.contains { $0.id == "c:\(chatA.id.uuidString)" && $0.bytes == 1_000_000 })
        #expect(usage.contains { $0.id == "c:\(chatB.id.uuidString)" && $0.bytes == 500_000 })
        #expect(usage.contains { $0.id == "s:\(alice.fingerprint)|main" && $0.bytes == 250_000 })

        model.clearMedia(scopeID: "c:\(chatA.id.uuidString)")
        #expect(model.data.conversations[0].messages[0].text == "keep this")
        #expect(model.data.conversations[0].messages[0].image == nil)
        #expect(model.data.conversations[0].messages[0].mediaGone == true)
        #expect(model.data.conversations[1].messages[0].image?.count == 500_000, "other chats are untouched")
        #expect(model.data.stories.count == 2, "stories are untouched")

        model.clearMedia(scopeID: "s:\(alice.fingerprint)|main")
        if case let .image(data, _) = model.data.stories[0].style { #expect(data.isEmpty) } else { Issue.record("not a photo") }
        if case let .text(text, _) = model.data.stories[1].style { #expect(text == "words only") } else { Issue.record("text story lost") }
        #expect(model.receivedMediaBytes == 500_000)
    }
}
