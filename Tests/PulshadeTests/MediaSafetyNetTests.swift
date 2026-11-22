import Testing
import Foundation
@testable import Pulshade

/// The memory-only ceiling on received media: text always survives, own media never counts, nothing is deleted.
@MainActor
@Suite(.serialized) struct MediaSafetyNetTests {
    private func makeModel() async throws -> AppModel {
        let model = testModel("pulshade-media-net")
        try await model.create(identity: .generate(), profile: Profile(name: "Me"), passcode: "test-passcode")
        return model
    }

    private func makeContact() -> Contact {
        let them = Identity.generate()
        var contact = Contact(fingerprint: them.fingerprint, name: "Them", signingKey: them.card.signing,
                              agreementKey: them.card.agreement, sendID: Mailbox.make().sendID, device: Data([1]))
        contact.persona = nil
        return contact
    }

    @Test func newMediaIsDroppedButTextAndExistingMediaSurvive() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let them = makeContact()
        model.data.contacts = [them]

        let existing = Data(count: 92 * 1024 * 1024)
        var convo = Conversation(kind: .direct, title: "Them", members: [them.fingerprint])
        convo.messages = [Message(sender: them.fingerprint, text: "already here", image: existing)]
        model.data.conversations = [convo]
        model.rebuildReceivedMedia()
        let before = model.receivedMediaBytes

        let voice = VoiceNote(audio: Data(count: 5 * 1024 * 1024), duration: 1, levels: [])
        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "keep these words", voice: voice,
                                  date: Date()), from: them)

        let arrived = try #require(model.data.conversations[0].messages.last)
        #expect(arrived.text == "keep these words")
        #expect(arrived.mediaDropped == true)
        #expect(arrived.voice?.audio.isEmpty == true)
        #expect(model.receivedMediaBytes == before, "nothing new was stored")
        #expect(model.data.conversations[0].messages.first?.image?.count == existing.count, "nothing existing was deleted")

        // Delete the chat that held the 92 MiB. The next arrival must count from the data, not the stale total.
        model.delete(model.data.conversations[0].id)
        #expect(model.data.conversations.isEmpty)
        let afterDelete = VoiceNote(audio: Data(count: 5 * 1024 * 1024), duration: 1, levels: [])
        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "after delete", voice: afterDelete,
                                  date: Date()), from: them)
        let stored = try #require(model.data.conversations.first?.messages.last)
        #expect(stored.voice?.audio.count == afterDelete.audio.count)
        #expect(stored.mediaDropped != true, "room again without locking")
        #expect(model.receivedMediaBytes == afterDelete.audio.count)
    }

    @Test func aStoryUpdateRecountsAfterMediaIsDeleted() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let them = makeContact()
        model.data.contacts = [them]

        var convo = Conversation(kind: .direct, title: "Them", members: [them.fingerprint])
        convo.messages = [Message(sender: them.fingerprint, text: "big", image: Data(count: 92 * 1024 * 1024))]
        model.data.conversations = [convo]
        let storyID = UUID()
        model.data.stories = [Story(id: storyID, author: them.fingerprint, style: .text("old", palette: 0), persona: nil)]
        model.rebuildReceivedMedia()
        #expect(model.receivedMediaBytes == 92 * 1024 * 1024)

        // The chat goes, so the next decision must count 0, not the stale 92 MiB.
        model.delete(convo.id)
        #expect(model.data.conversations.isEmpty)

        let replacement = Data(count: 6 * 1024 * 1024)
        model.receiveForTests(.story(id: storyID, style: .image(replacement, caption: "new"),
                                     date: Date(), lasts: 3600), from: them)

        let story = try #require(model.data.stories.first { $0.id == storyID })
        guard case let .image(data, _) = story.style else { Issue.record("story did not update"); return }
        #expect(data.count == replacement.count)
        #expect(story.mediaDropped != true, "the update was not refused for a stale total")
        #expect(model.receivedMediaBytes == replacement.count)
    }

    @Test func ownAndSyncedMediaNeverCount() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let media = Data(count: 1_048_576)
        var convo = Conversation(kind: .direct, title: "Me", members: [])
        convo.messages = [Message(sender: "me", text: "mine", image: media)]
        model.data.conversations = [convo]
        model.data.stories = [Story(author: "me", style: .image(media, caption: ""))]
        model.rebuildReceivedMedia()
        #expect(model.receivedMediaBytes == 0)
    }

    @Test func theCountIsRebuiltTheSameAfterLockAndUnlock() async throws {
        let model = try await makeModel()
        let them = makeContact()
        model.data.contacts = [them]
        let media = Data(count: 1_048_576)
        var convo = Conversation(kind: .direct, title: "Them", members: [them.fingerprint])
        convo.messages = [Message(sender: them.fingerprint, text: "theirs", image: media)]
        model.data.conversations = [convo]
        model.rebuildReceivedMedia()
        let before = model.receivedMediaBytes
        #expect(before == media.count)

        model.save()
        model.lock()
        #expect(await model.unlock(passcode: "test-passcode"))
        #expect(model.receivedMediaBytes == before)
        model.lock()
    }
}
