import Testing
import Foundation
@testable import Pulshade

/// New received media is kept in the sealed pool; the vault holds only a reference.
@MainActor
@Suite(.serialized) struct MediaFileBackedTests {
    private func makeModel() async throws -> AppModel {
        let model = testModel("pulshade-media-backed")
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

    @Test func aReceivedPhotoAndVoiceNoteAreFilesNotVaultBytes() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let them = makeContact()
        model.data.contacts = [them]
        let photo = StoryMediaTests.photo()

        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "", image: photo,
                                  date: Date()), from: them)
        let picture = try #require(model.data.conversations.first?.messages.last)
        #expect(picture.image == nil && picture.imageFile != nil)
        #expect(model.imageData(for: picture) == photo)

        let sound = Data.random(AppModel.mediaInline + 4_000)
        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "", voice: VoiceNote(audio: sound, duration: 1, levels: []),
                                  date: Date()), from: them)
        let voice = try #require(model.data.conversations.first?.messages.last)
        #expect(voice.voice?.audio.isEmpty == true && voice.voice?.audioFile != nil)
        #expect(model.voiceAudio(for: voice) == sound)
    }

    @Test func aReceivedStoryPictureIsAFile() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let them = makeContact()
        model.data.contacts = [them]
        let photo = StoryMediaTests.photo()
        let storyID = UUID()

        model.receiveForTests(.story(id: storyID, style: .image(photo, caption: "here"),
                                     date: Date(), lasts: 3_600), from: them)

        let story = try #require(model.data.stories.first { $0.id == storyID })
        #expect(story.mediaFile != nil)
        if case let .image(data, _) = story.style { #expect(data.isEmpty) } else { Issue.record("not a photo story") }
        #expect(model.storyData(for: story) == photo)
    }

    @Test func deletingTheChatMakesItsSealedFileUnreadable() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let them = makeContact()
        model.data.contacts = [them]
        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "", image: StoryMediaTests.photo(),
                                  date: Date()), from: them)
        let message = try #require(model.data.conversations.first?.messages.last)
        let ref = try #require(message.imageFile)
        let convo = try #require(model.data.conversations.first)

        model.delete(convo.id)

        let pool = MediaPool(directory: model.vault.directory)
        var threw = false
        do { _ = try pool.load(ref) } catch { threw = true }
        #expect(threw, "the deleted item's key no longer opens its file")
    }

    @Test func aMissingFileReadsAsNothing() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let them = makeContact()
        model.data.contacts = [them]
        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "", image: StoryMediaTests.photo(),
                                  date: Date()), from: them)
        // Reload so the decoded-media cache cannot hide the missing file.
        model.save()
        model.lock()
        #expect(await model.unlock(passcode: "test-passcode"))
        let message = try #require(model.data.conversations.first?.messages.last)
        let ref = try #require(message.imageFile)
        try? FileManager.default.removeItem(at: model.vault.directory.appendingPathComponent("media").appendingPathComponent(ref.name))
        #expect(model.imageData(for: message) == nil)
    }

    @Test func tinyItemsCountAtTheirSizeOnDisk() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let them = makeContact()
        model.data.contacts = [them]
        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "", voice: VoiceNote(audio: Data.random(2_000), duration: 1, levels: []),
                                  date: Date()), from: them)
        let message = try #require(model.data.conversations.first?.messages.last)
        #expect(message.voice?.audioFile != nil)
        #expect(AppModel.mediaBytes(message) >= 65_536, "a flood of tiny items can't outgrow the budget on disk")
    }

    @Test func anUnsentPhotoIsOverwrittenAndBecomesFiller() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let them = makeContact()
        model.data.contacts = [them]
        let id = UUID()
        model.deliver(WireMessage(id: id, conversation: nil, kind: .direct, text: "", image: StoryMediaTests.photo(),
                                  date: Date()), from: them)
        model.save()
        let ref = try #require(model.data.conversations.first?.messages.last?.imageFile)
        let url = model.vault.directory.appendingPathComponent("media").appendingPathComponent(ref.name)
        let before = try Data(contentsOf: url)

        model.receiveForTests(.unsend(ids: [id]), from: them)
        model.save()

        #expect(model.data.conversations.first?.messages.contains { $0.id == id } != true)
        let after = try Data(contentsOf: url)
        #expect(after.count == before.count && after != before, "same file, same size, new bytes")
        #expect(model.data.mediaFillers?.contains(ref.name) == true, "kept as this account's own filler")
        var threw = false
        do { _ = try MediaPool(directory: model.vault.directory).load(ref) } catch { threw = true }
        #expect(threw)
    }

    @Test func panicLeavesNoMediaPoolBehind() async throws {
        let model = try await makeModel()
        let them = makeContact()
        model.data.contacts = [them]
        model.deliver(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "", image: StoryMediaTests.photo(),
                                  date: Date()), from: them)
        model.save()
        let media = model.vault.directory.appendingPathComponent("media")
        #expect(FileManager.default.fileExists(atPath: media.path))
        try await model.setPanic(passcode: "panic-passcode")
        model.lock()

        #expect(await model.unlock(passcode: "panic-passcode"))
        defer { model.lock() }
        #expect(model.data.conversations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: media.path), "an empty account beside a full pool would give it away")
    }

    @Test func aNameThePoolNeverMadeIsNeverOpenedOrOverwritten() throws {
        let dir = testDirectory("pulshade-media-names")
        let pool = MediaPool(directory: dir)
        _ = try pool.store(Data.random(100_000))
        let outside = dir.appendingPathComponent("identity.lock")
        try Data("keep".utf8).write(to: outside)
        let bad = MediaFileRef(name: "../identity.lock", key: Data(count: 32), size: 4, sha256: Data())
        #expect(throws: (any Error).self) { try pool.load(bad) }
        try pool.delete(bad)
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
        #expect(!MediaPool.isValidName("../x") && !MediaPool.isValidName("ABCDEF0123456789ABCDEF0123456789"))
    }
}
