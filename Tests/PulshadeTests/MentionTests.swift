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

/// A picture glows, and opens the story when tapped, only while someone has a story you haven't watched.
@MainActor
@Suite struct UnwatchedStoryTests {
    @Test func onlyUnwatchedLiveStoriesOfThatPersonCount() {
        let model = testModel("pulshade-test")
        let old = Story(author: "k", style: .text("a", palette: 0), date: Date().addingTimeInterval(-60), seen: true)
        let fresh = Story(author: "k", style: .text("b", palette: 0), date: Date())
        model.data.contacts = [Contact(fingerprint: "k", signingKey: Data(), agreementKey: Data(), sendID: Data())]
        model.data.stories = [old, fresh]
        let reel = model.unwatchedReel(of: "k")
        #expect(reel?.stories.map(\.id) == [old.id, fresh.id] && reel?.start == 1, "plays from the first one not watched")
        #expect(model.unwatchedReel(of: "someone-else") == nil && model.unwatchedReel(of: "me") == nil && model.unwatchedReel(of: "") == nil)

        // Someone you only share a group with: their stories aren't shown.
        model.data.contacts[0].hidden = true
        #expect(model.unwatchedReel(of: "k") == nil && model.friendStories.isEmpty, "not a friend")
        model.data.contacts[0].hidden = false

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

/// The ringing a caller hears while waiting.
@Suite struct RingbackTests {
    @Test func isQuietLoopsCleanlyAndIsTheSameEveryTime() {
        let a = Ringback.samples()
        #expect(a.count == Int(Ringback.cycle * Ringback.sampleRate))
        #expect(a == Ringback.samples(), "made the same way every time")
        let peak = a.map(abs).max() ?? 0
        #expect(abs(Double(peak) - Ringback.level) < 0.001 && Ringback.level <= 0.3, "quiet")
        // Round to round, the loop's two ends sit close together, so it doesn't click.
        #expect(abs(a[0] - a[a.count - 1]) < 0.02)
        let loudest = stride(from: 0, to: a.count, by: 4_800).map { start in a[start..<min(start + 4_800, a.count)].map(abs).max() ?? 0 }
        #expect(loudest.max()! > 0.2 && loudest.min()! < 0.12, "swells, then fades before the next round")
    }

    @Test func wavHasTheRightHeader() {
        let wav = Ringback.wav()
        #expect(wav.prefix(4) == Data("RIFF".utf8) && wav.count == 44 + Int(Ringback.cycle * Ringback.sampleRate) * 2)
        if let path = ProcessInfo.processInfo.environment["PULSHADE_RINGBACK_WAV"] { try? wav.write(to: URL(fileURLWithPath: path)) }
    }
}
