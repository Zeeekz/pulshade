import Testing
import Foundation
@testable import Pulshade

@MainActor
@Suite struct NotifierTests {
    let direct = Conversation(kind: .direct, title: "Kai", members: ["k"])
    let group = Conversation(kind: .group, title: "Night Owls", members: ["k", "r"])

    @Test func hiddenRevealsNothing() {
        let m = Message(sender: "k", text: "meet at 9")
        let c = Notifier.content(for: m, in: direct, sender: "Kai", style: .hidden)
        #expect(c.title == "PULSHADE" && c.body == "New message")
    }

    @Test func nameShowsOnlyWho() {
        let m = Message(sender: "k", text: "meet at 9")
        let c = Notifier.content(for: m, in: group, sender: "Kai", style: .name)
        #expect(c.title == "Night Owls" && c.body == "New message")
    }

    @Test func fullShowsMessageWithSenderInGroups() {
        let text = Notifier.content(for: Message(sender: "k", text: "meet at 9"), in: group, sender: "Kai", style: .full)
        #expect(text.body == "Kai: meet at 9")
        let voice = Message(sender: "k", text: "", voice: VoiceNote(audio: Data(), duration: 2, levels: []))
        #expect(Notifier.content(for: voice, in: direct, sender: "Kai", style: .full).body == "🎤 Voice note")
    }

    @Test func oldSettingsStillDecode() throws {
        let old = #"{"autoLockMinutes":15,"blockCapture":false,"blurWhenInactive":true}"#
        let s = try JSONDecoder().decode(SecuritySettings.self, from: Data(old.utf8))
        #expect(s.autoLockMinutes == 15 && !s.blockCapture)
        #expect(s.notifications && s.notificationContent == .hidden && s.menuBarIcon)
    }
}
