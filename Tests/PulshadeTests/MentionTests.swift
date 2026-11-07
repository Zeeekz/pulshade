import Testing
import Foundation
@testable import Pulshade

@MainActor
@Suite struct MentionTests {
    @Test func locatesEachPickedNameWhereItStands() {
        let text = "hey @Nova and @Kai Lee, ask @Nova"
        let found = Mention.locate([("n", "Nova"), ("k", "Kai Lee")], in: text)
        #expect(found.map(\.fingerprint) == ["n", "k", "n"])
        let ns = text as NSString
        #expect(found.map { ns.substring(with: NSRange(location: $0.start, length: $0.length)) } == ["@Nova", "@Kai Lee", "@Nova"])
    }

    @Test func editedAwayOrPartOfAnotherWordIsNotAMention() {
        #expect(Mention.locate([("n", "Nova")], in: "hey Nova").isEmpty)
        #expect(Mention.locate([("n", "Nova")], in: "hey @Novak").isEmpty)
        #expect(Mention.locate([("n", "Nova")], in: "mail me@Nova.com").isEmpty)
    }

    @Test func offsetsCountEmojiTheWayNSStringDoes() {
        let text = "🎉 @Nova"
        let found = Mention.locate([("n", "Nova")], in: text)
        #expect(found.count == 1)
        #expect(Mention.cleaned(found, in: text) == found)
    }

    @Test func receivedMentionsAreKeptOnlyWhereTheyFit() {
        let text = "hi @Nova"
        let good = Mention(fingerprint: "n", start: 3, length: 5)
        #expect(Mention.cleaned([good], in: text) == [good])
        #expect(Mention.cleaned([Mention(fingerprint: "n", start: 4, length: 4)], in: text).isEmpty, "doesn't start on an @")
        #expect(Mention.cleaned([Mention(fingerprint: "n", start: 3, length: 50)], in: text).isEmpty, "runs past the end")
        #expect(Mention.cleaned([Mention(fingerprint: "n", start: -1, length: 5)], in: text).isEmpty)
        #expect(Mention.cleaned([Mention(fingerprint: "", start: 3, length: 5)], in: text).isEmpty)
        #expect(Mention.cleaned([good, Mention(fingerprint: "x", start: 4, length: 3)], in: text) == [good], "no overlaps")
        let many = (0..<50).map { Mention(fingerprint: "n", start: $0 * 3, length: 2) }
        #expect(Mention.cleaned(many, in: String(repeating: "@a ", count: 50)).count == Mention.maxPerMessage)
    }

    @Test func oldMessagesAndOldAppsStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","sender":"k","text":"hi"}"#
        let message = try JSONDecoder().decode(Message.self, from: Data(old.utf8))
        #expect(message.mentions.isEmpty && !message.mentionsMe)
        var mine = Message(sender: "k", text: "hi @Me")
        mine.mentions = [Mention(fingerprint: "me", start: 3, length: 3)]
        let again = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(mine))
        #expect(again.mentionsMe)
    }

    @Test func notificationsSayYouWereMentionedOnlyWhenTheSettingShowsMore() {
        let group = Conversation(kind: .group, title: "Night Owls", members: ["k"])
        var m = Message(sender: "k", text: "@Me lunch?")
        m.mentions = [Mention(fingerprint: "me", start: 0, length: 3)]
        #expect(Notifier.content(for: m, in: group, sender: "Kai", style: .hidden).body == "New message")
        #expect(Notifier.content(for: m, in: group, sender: "Kai", style: .name).body == "Mentioned you")
        #expect(Notifier.content(for: m, in: group, sender: "Kai", style: .full).body == "Kai mentioned you: @Me lunch?")
        m.mentions = []
        #expect(Notifier.content(for: m, in: group, sender: "Kai", style: .full).body == "Kai: @Me lunch?")
    }
}

/// Needs a relay, like the other flow tests: `scripts/test.sh` starts one.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct MentionFlowTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func settle(_ models: AppModel..., rounds: Int = 6) async {
        for _ in 0..<rounds { for m in models { await m.syncOnce() } }
    }

    /// Alice knows Bob and Cara; Bob and Cara only share the group. Alice can mention either of them, Bob sees it
    /// is him, Cara sees it names someone else, and Bob can't mention Cara because she isn't his contact.
    @Test func mentionsReachTheRightPeopleAndOnlyContactsCanBeMentioned() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint
        let group = alice.startConversation(kind: .group, title: "Night owls", members: [bobFP, caraFP])
        await settle(alice, bob, cara)

        #expect(Set(alice.mentionable(in: try #require(alice.conversation(group.id))).map(\.name)) == ["Bob", "Cara"])
        alice.send("hey @Bob, ask @Bob", mentioning: [(bobFP, "Bob")], in: group.id)
        await settle(alice, bob, cara)
        let atBob = try #require(bob.conversation(group.id)?.messages.last)
        #expect(atBob.mentionsMe && atBob.mentions.count == 2)
        let atCara = try #require(cara.conversation(group.id)?.messages.last)
        #expect(!atCara.mentionsMe && atCara.mentions.map(\.fingerprint) == [bobFP, bobFP])

        // Cara has no contact called Bob, so nothing is offered and a forced mention is dropped.
        let caraGroup = try #require(cara.conversation(group.id))
        #expect(cara.mentionable(in: caraGroup).map(\.name) == ["Alice"])
        cara.send("hi @Bob", mentioning: [(bobFP, "Bob")], in: group.id)
        await settle(alice, bob, cara)
        let plain = try #require(bob.conversation(group.id)?.messages.last)
        #expect(plain.text == "hi @Bob" && plain.mentions.isEmpty && !plain.mentionsMe)
    }
}

/// A picture glows, and opens the story when tapped, only while someone has a story you haven't watched.
@MainActor
@Suite struct UnwatchedStoryTests {
    @Test func onlyUnwatchedLiveStoriesOfThatPersonCount() {
        let model = testModel("pulshade-test")
        let old = Story(author: "k", style: .text("a", palette: 0), date: Date().addingTimeInterval(-60), seen: true)
        let fresh = Story(author: "k", style: .text("b", palette: 0), date: Date())
        model.data.stories = [old, fresh]
        let reel = model.unwatchedReel(of: "k")
        #expect(reel?.stories.map(\.id) == [old.id, fresh.id] && reel?.start == 1, "plays from the first one not watched")
        #expect(model.unwatchedReel(of: "someone-else") == nil && model.unwatchedReel(of: "me") == nil && model.unwatchedReel(of: "") == nil)

        model.data.stories[1].seen = true
        #expect(model.unwatchedReel(of: "k") == nil, "watched: the picture goes back to its normal tap")

        let other = Story(author: "k", style: .text("c", palette: 0), persona: UUID())
        model.data.stories = [other]
        #expect(model.unwatchedReel(of: "k") == nil, "another persona's story doesn't count")
        let expired = Story(author: "k", style: .text("d", palette: 0), date: Date().addingTimeInterval(-200_000))
        model.data.stories = [expired]
        #expect(model.unwatchedReel(of: "k") == nil)
    }
}
