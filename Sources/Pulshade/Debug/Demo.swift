#if DEBUG
import Foundation

/// `PULSHADE_DEMO=1` opens a throwaway, unlocked identity full of sample chats so
/// the UI can be reviewed without a passcode. Debug builds only; never touches the real vault.
extension AppModel {
    static var demoRequested: Bool { ProcessInfo.processInfo.environment["PULSHADE_DEMO"] == "1" }

    static func demo() -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulshade-demo-\(UUID().uuidString)")
        let model = AppModel(vault: Vault(directory: dir), watchSystem: false)
        model.loadDemo()
        return model
    }

    private func loadDemo() {
        var d = AppData()
        d.profile = Profile(name: "Nova")
        d.relay = "http://127.0.0.1:1" // nothing listens here: demo stays offline
        // Screenshots of the demo are the point, so it doesn't hide itself.
        d.security.blockCapture = false
        d.security.blurWhenInactive = false
        d.security.autoLockMinutes = 0
        // PULSHADE_DEMO_THEME=light|dark|pulse picks the theme.
        d.theme = ProcessInfo.processInfo.environment["PULSHADE_DEMO_THEME"] ?? d.theme
        let names = ["Kai", "Rune", "Sable", "Juno", "Wren", "Ash"]
        let people = names.map { name -> Contact in
            let id = Identity.generate()
            return Contact(fingerprint: id.fingerprint, name: name, signingKey: id.card.signing,
                           agreementKey: id.card.agreement, sendID: Mailbox.make().sendID, receiveKey: Mailbox.make().receiveKey)
        }
        d.contacts = people
        d.contacts[0].bio = "Night drives, film cameras. Portfolio at https://example.com"
        d.contacts[0].handle = "kai_nights"
        d.contacts[0].color = 2
        let now = Date()
        func msg(_ who: Int?, _ text: String, _ minutesAgo: Double, _ status: MessageStatus = .delivered) -> Message {
            Message(sender: who.map { people[$0].fingerprint } ?? "me", text: text,
                    date: now.addingTimeInterval(-minutesAgo * 60), status: status)
        }
        d.conversations = [
            Conversation(kind: .direct, title: "Kai", members: [people[0].fingerprint], messages: [
                msg(0, "you up?", 190), msg(nil, "always 🌙", 188), msg(0, "found a spot with no cameras for the shoot", 120),
                msg(0, "sending the pin later", 119), msg(nil, "perfect. bring the film camera", 30),
                msg(nil, "and the long lens", 29, .sent), msg(0, "deal ✦", 2),
            ], unread: 1, disappearAfter: Disappear.day.rawValue),
            Conversation(kind: .group, title: "Night Owls", members: [people[1].fingerprint, people[2].fingerprint, people[3].fingerprint], messages: [
                msg(1, "who's coming saturday", 300), msg(2, "me + juno", 290), msg(3, "yes!!", 289),
                msg(nil, "I'll bring speakers", 200), msg(1, "legend", 199), msg(2, "dark mode only party", 12),
            ], pinned: true, unread: 3),
            Conversation(kind: .channel, title: "Drops", members: [people[4].fingerprint, people[5].fingerprint], messages: [
                msg(nil, "New tracks every Friday. Only here.", 2000), msg(nil, "Vol. 3 is live", 60),
            ]),
            Conversation(kind: .broadcast, title: "Crew", members: Array(people.prefix(4).map(\.fingerprint)), messages: [
                msg(nil, "Meet at 9. Bring nothing with your name on it.", 600, .sent),
            ]),
            Conversation(kind: .direct, title: "Wren", members: [people[4].fingerprint], messages: [
                msg(4, "thanks for the invite", 3000), msg(nil, "anytime", 2990),
            ]),
        ]
        // Reactions, a timer note, a voice note and a big emoji in Kai's chat.
        d.conversations[0].messages[1].reactions = [people[0].fingerprint: "🔥"]
        d.conversations[0].messages[4].reactions = [people[0].fingerprint: "❤️", "me": "❤️"]
        d.conversations[0].messages.insert(Message(sender: "system", text: "⏱ 1d", date: now.addingTimeInterval(-25 * 60),
                                                   status: .delivered), at: 5)
        let levels: [UInt8] = (0..<48).map { UInt8(40 + abs(sin(Double($0) / 3)) * 200) }
        d.conversations[0].messages.append(Message(sender: people[0].fingerprint, text: "",
                                                   voice: VoiceNote(audio: Data(), duration: 14, levels: levels),
                                                   date: now.addingTimeInterval(-60), status: .delivered,
                                                   expiresAt: now.addingTimeInterval(86_000)))
        d.conversations[0].messages.append(msg(nil, "🌙✨", 0.5))
        // A persona, a burner chat and a verified contact.
        d.personas.append(Persona(seed: Identity.generate().seed, profile: Profile(name: "Ghost", color: 3)))
        let burnerPersona = Persona(seed: Identity.generate().seed, profile: Profile(name: "Drift 4821", color: 5),
                                    burnsAt: now.addingTimeInterval(5 * 3600 + 1234))
        d.personas.append(burnerPersona)
        let stranger = Identity.generate()
        var strangerContact = Contact(fingerprint: stranger.fingerprint, name: "Haze 7710", signingKey: stranger.card.signing,
                                      agreementKey: stranger.card.agreement, sendID: Mailbox.make().sendID)
        strangerContact.persona = burnerPersona.id
        strangerContact.color = 6
        d.contacts.append(strangerContact)
        var burnerChat = Conversation(kind: .direct, title: "Haze 7710", members: [stranger.fingerprint], messages: [
            Message(sender: stranger.fingerprint, text: "still selling the synth?", date: now.addingTimeInterval(-900), status: .delivered),
            msg(nil, "yep, can meet tomorrow", 14),
        ])
        burnerChat.persona = burnerPersona.id
        d.conversations.insert(burnerChat, at: 1)
        d.contacts[0].verified = true
        d.contacts[0].color = 0
        d.contacts[2].color = 4
        d.profile.color = 2
        d.profile.handle = "nova"
        d.profile.bio = "night drives & film cameras"
        // Two people asking to chat.
        for (name, note, color) in [("Lumen", "saw your shots from the rooftop, insane", 1), ("Vex", "", 7)] {
            let them = Identity.generate()
            let (_, hello) = try! Handshake.start()
            d.requests.append(FriendRequest(fingerprint: them.fingerprint,
                                            card: PeerCard(name: name, avatar: nil, color: color, signingKey: them.card.signing,
                                                           agreementKey: them.card.agreement, sendID: Mailbox.make().sendID),
                                            handshake: hello, note: note, receivedAt: now.addingTimeInterval(-Double.random(in: 60...4000))))
        }
        d.stories = [
            Story(author: "me", style: .text("late drive", palette: 0), date: now.addingTimeInterval(-3600)),
            Story(author: people[0].fingerprint, style: .text("rooftop tonight?", palette: 1), date: now.addingTimeInterval(-1200)),
            Story(author: people[2].fingerprint, style: .text("new era", palette: 4), date: now.addingTimeInterval(-600)),
            Story(author: people[3].fingerprint, style: .text("✦✦✦", palette: 3), date: now.addingTimeInterval(-300)),
        ]
        loadPreview(identity: .generate(), data: d)
    }
}
#endif
