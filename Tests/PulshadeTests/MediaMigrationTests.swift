import Testing
import Foundation
@testable import Pulshade

/// Inline media in an old vault moves into the sealed pool all at once, or not at all.
@MainActor
@Suite(.serialized) struct MediaMigrationTests {
    private func makeModel() async throws -> AppModel {
        let model = testModel("pulshade-media-migration")
        try await model.create(identity: .generate(), profile: Profile(name: "Me"), passcode: "test-passcode")
        return model
    }

    private func seed(_ model: AppModel) -> Contact {
        let them = Identity.generate()
        var contact = Contact(fingerprint: them.fingerprint, name: "Them", signingKey: them.card.signing,
                              agreementKey: them.card.agreement, sendID: Mailbox.make().sendID, device: Data([1]))
        contact.persona = nil
        model.data.contacts = [contact]
        let photo = Data(repeating: 3, count: 120_000)
        let clip = Data(repeating: 4, count: 150_000)
        let sound = Data(repeating: 5, count: 80_000)
        var convo = Conversation(kind: .direct, title: "Them", members: [contact.fingerprint])
        var message = Message(sender: contact.fingerprint, text: "old media", image: photo,
                              voice: VoiceNote(audio: sound, duration: 1, levels: []))
        message.video = clip
        convo.messages = [message]
        model.data.conversations = [convo]
        model.data.stories = [Story(id: UUID(), author: contact.fingerprint,
                                    style: .image(Data(repeating: 6, count: 90_000), caption: "old story"))]
        model.rebuildReceivedMedia()
        return contact
    }

    @Test func inlineMediaMovesIntoThePoolInOneGo() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        _ = seed(model)
        let before = model.receivedMediaBytes

        model.migrateInlineMedia()

        let message = try #require(model.data.conversations.first?.messages.first)
        #expect(message.image?.isEmpty != false && message.imageFile != nil)
        #expect(message.video?.isEmpty != false && message.videoFile != nil)
        #expect(message.voice?.audio.isEmpty == true && message.voice?.audioFile != nil)
        #expect(model.imageData(for: message)?.count == 120_000)
        #expect(model.videoData(for: message)?.count == 150_000)
        #expect(model.voiceAudio(for: message)?.count == 80_000)

        let story = try #require(model.data.stories.first)
        #expect(story.mediaFile != nil)
        if case let .image(data, _) = story.style { #expect(data.isEmpty) } else { Issue.record("not a photo story") }
        #expect(model.storyData(for: story)?.count == 90_000)
        // In the pool each item counts at its padded size on disk.
        #expect(before > 0)
        #expect(model.receivedMediaBytes == [120_000, 150_000, 80_000, 90_000].reduce(0) { $0 + MediaPool.sealedSize(ofPlain: $1) })
    }

    @Test func aFailedSealLeavesTheOldInlineDataIntact() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        _ = seed(model)
        // A plain file where the pool's folder should be makes every seal fail.
        let blocked = model.vault.directory.appendingPathComponent("media")
        #expect(FileManager.default.createFile(atPath: blocked.path, contents: Data([1])))

        model.migrateInlineMedia()

        let message = try #require(model.data.conversations.first?.messages.first)
        #expect(message.image?.count == 120_000, "old bytes are still there")
        #expect(message.imageFile == nil)
        #expect(message.video?.count == 150_000)
        #expect(message.voice?.audio.count == 80_000)
        let story = try #require(model.data.stories.first)
        #expect(story.mediaFile == nil)
        if case let .image(data, _) = story.style { #expect(data.count == 90_000) } else { Issue.record("not a photo story") }
    }
}
