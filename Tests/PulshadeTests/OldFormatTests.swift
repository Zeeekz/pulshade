import Testing
import Foundation
import CryptoKit
import PulshadeShared
@testable import Pulshade

/// Groups and channels used to send each member a copy of everything. That format is gone: one saved from before stays
/// on the device, readable and closed, and nothing is sent in it or read for it. Announcements is not a group on the
/// wire and carries on as before.
@MainActor
@Suite(.serialized) struct OldFormatTests {
    private func makeModel() async throws -> AppModel {
        let model = testModel("pulshade-old-format")
        try await model.create(identity: .generate(), profile: Profile(name: "Me"), passcode: "test-passcode")
        return model
    }

    private func oldGroup(members: [String], kind: ConversationKind = .group) -> Conversation {
        var group = Conversation(kind: kind, title: "Old crew", members: members)
        group.owner = "me"
        group.admins = []
        group.version = 4
        group.messages = [Message(sender: "me", text: "from before", date: Date().addingTimeInterval(-3_600), status: .delivered),
                          Message(sender: members.first ?? "x", text: "an answer", date: Date().addingTimeInterval(-3_000), status: .delivered)]
        return group
    }

    private func member(_ model: AppModel) -> Contact {
        let them = Identity.generate()
        var contact = Contact(fingerprint: them.fingerprint, name: "Them", signingKey: them.card.signing,
                              agreementKey: them.card.agreement, sendID: Mailbox.make().sendID, device: Data([7, 7]))
        contact.persona = nil
        model.data.contacts = [contact]
        return contact
    }

    /// What an older build saved for a group: introduction mailboxes and all. Every field it had is still read, and the ones
    /// nothing uses any more are ignored, so the account opens and the history is there.
    @Test func aGroupSavedInTheOldFormatStillOpens() throws {
        let group = oldGroup(members: ["fp-a", "fp-b"])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder.pulshade.encode(group)) as? [String: Any])
        json["introsMade"] = ["fp-a": ["": Data(repeating: 1, count: 32).base64EncodedString()]]
        json["introsMine"] = [["receiveKey": Data(repeating: 2, count: 32).base64EncodedString()]]
        json["mods"] = ["fp-b"]
        let opened = try JSONDecoder.pulshade.decode(Conversation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(opened.isOldFormat)
        #expect(opened.members == ["fp-a", "fp-b"] && opened.mods == ["fp-b"] && opened.version == 4 && opened.owner == "me")
        #expect(opened.messages.map(\.text) == ["from before", "an answer"], "its past messages are all still there")

        // Inside a whole account, and again after a save and a load.
        var data = AppData()
        data.conversations = [opened, .announcements()]
        let again = try JSONDecoder.pulshade.decode(AppData.self, from: JSONEncoder.pulshade.encode(data))
        #expect(again.conversations.map(\.id) == data.conversations.map(\.id))
        #expect(again.conversations[0].messages.count == 2 && again.conversations[0].isOldFormat && !again.conversations[1].isOldFormat)
    }

    @Test func anOldGroupSurvivesLockAndUnlockAndCannotBeUsed() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let contact = member(model)
        let group = oldGroup(members: [contact.fingerprint])
        let channel = oldGroup(members: [contact.fingerprint], kind: .channel)
        model.data.conversations = [group, channel]
        model.save()
        await model.settleSavesAsync()
        model.lock()
        #expect(await model.unlock(passcode: "test-passcode"))

        for id in [group.id, channel.id] {
            let kept = try #require(model.conversation(id))
            #expect(kept.isOldFormat && kept.messages.map(\.text) == ["from before", "an answer"], "history is kept")
            #expect(!model.canPost(in: kept), "but nothing can be written")
            let before = model.data.outbox.count
            model.send("anyone there?", in: id)
            model.noteTyping(in: id)
            model.setDisappearing(Disappear.fiveMinutes.rawValue, in: id)
            model.addMembers(id, [contact.fingerprint])
            model.updateDetails(id, title: "Renamed", about: "x", avatar: nil)
            model.setPostPolicy(id, .owner)
            let after = try #require(model.conversation(id))
            #expect(after.messages.count == 2 && after.title == "Old crew" && after.disappearAfter == nil && after.postPolicy == kept.postPolicy)
            #expect(model.data.outbox.count == before)
            #expect(model.data.contacts[0].devices[0].pending.isEmpty, "not one byte goes to a member")
        }
    }

    @Test func nothingIsReadForAnOldGroup() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let contact = member(model)
        let group = oldGroup(members: [contact.fingerprint])
        model.data.conversations = [group]
        model.data.security.notifications = false

        // A message addressed to the group, from a member, the way an old fan-out would bring it.
        let wire = WireMessage(id: UUID(), conversation: group.id, kind: .group, text: "still sending", date: Date())
        model.deliver(wire, from: contact)
        #expect(model.conversation(group.id)?.messages.count == 2, "not added")
        #expect(model.data.conversations.count == 1, "and no other chat was made for it")
        #expect(model.unreadTotal == 0)

        // The same person's direct chat is untouched by all this.
        let direct = WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "hello", date: Date())
        model.deliver(direct, from: contact)
        #expect(model.data.conversations.contains { $0.kind == .direct && $0.messages.map(\.text) == ["hello"] })
        #expect(model.conversation(group.id)?.messages.count == 2)
    }

    @Test func aGroupOrChannelIsNeverSyncedInTheOldFormat() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let card = ConversationCard(id: UUID(), kind: .group, title: "From my other device", avatar: nil, about: nil, owner: "me", admins: [],
                                    postPolicy: .everyone, version: 1, members: ["x"], persona: nil, disappearAfter: nil)
        model.applySync(.conversation(card))
        var channel = card
        channel.id = UUID()
        channel.kind = .channel
        model.applySync(.conversation(channel))
        #expect(model.data.conversations.isEmpty, "no group is made in a format nothing reads")
    }

    @Test func anOldGroupDoesntHoldBackAGroupThatSharesItsId() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let contact = member(model)
        let group = oldGroup(members: [contact.fingerprint])
        model.data.conversations = [group]
        // The owner's phone invites this one into a mailbox group of the same id: it isn't taken over the old copy.
        let owner = GroupMemberKeys(seed: Data(repeating: 9, count: 32), group: group.id)
        let epoch = GroupEpoch.fresh(number: 1)
        var settings = GroupSettings(group: group.id, kind: .group, version: 1, epoch: 1, title: "Old crew", owner: owner.publicKey,
                                     members: [MemberCard.make(owner, group: group.id, name: "Them", avatar: nil, color: nil)],
                                     epochCheck: epoch.check)
        settings.sign(with: owner)
        model.acceptGroupInvite(GroupInvite(settings: settings, epoch: epoch), from: contact)
        let kept = try #require(model.conversation(group.id))
        #expect(kept.shared == nil && kept.isOldFormat && kept.messages.count == 2, "the old copy is left as it was")
    }

    /// Announcements is a channel with no members that the relay fills in. It is not a group, so it is neither closed nor
    /// kept out: it shows what Pulshade announces, takes back what is taken back, and is saved and opened like any chat.
    @Test func announcementsIsNotAnOldGroupAndStillUpdates() async throws {
        await AdminKeyGate.shared.acquire()
        let admin = Curve25519.Signing.PrivateKey()
        let previous = AppModel.adminKey
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = previous; Task { await AdminKeyGate.shared.release() } }
        let model = try await makeModel()
        defer { model.lock() }
        #expect(!Conversation.announcements().isOldFormat && Conversation.announcements().kind == .channel && Conversation.announcements().members.isEmpty)

        let first = try Announcement.make("News one", signedBy: admin)
        model.applyAnnouncements([first])
        let chat = try #require(model.conversation(Conversation.announcementsID))
        #expect(chat.messages.map(\.text) == ["News one"] && !chat.isOldFormat && chat.shared == nil)
        #expect(!model.canPost(in: chat), "only the admin key posts there, as before")

        // Saved, closed and opened again, it is still there and still updates.
        model.save()
        await model.settleSavesAsync()
        model.lock()
        #expect(await model.unlock(passcode: "test-passcode"))
        #expect(model.conversation(Conversation.announcementsID)?.messages.map(\.text) == ["News one"])
        let second = try Announcement.make("News two", signedBy: admin)
        model.applyAnnouncements([first, second])
        #expect(model.conversation(Conversation.announcementsID)?.messages.map(\.text) == ["News one", "News two"])
        // Taken back by the admin app: gone.
        model.applyAnnouncements([second])
        #expect(model.conversation(Conversation.announcementsID)?.messages.map(\.text) == ["News two"])
    }
}
