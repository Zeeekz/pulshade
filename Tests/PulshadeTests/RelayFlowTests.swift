import Testing
import Foundation
import ImageIO
import CoreGraphics
@testable import Pulshade
import PulshadeShared
import CryptoKit

/// Two identities talking through a real relay. Start one first:
///   cd relay && cargo run --release
/// then run with PULSHADE_RELAY_TEST=1 swift test
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct RelayFlowTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func settle(_ models: AppModel..., rounds: Int = 6) async {
        for _ in 0..<rounds { for m in models { await m.syncOnce() } }
    }

    /// An announcement the admin app signed reaches every account as a chat from @announcements, a forged one
    /// never does, and one taken back goes away.
    @Test func announcementsReachEveryoneAndOnlyGenuineOnes() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        let previous = AppModel.adminKey
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = previous }
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }

        let token = try String(contentsOfFile: try #require(ProcessInfo.processInfo.environment["PULSHADE_TEST_DIR"]) + "/admin.token", encoding: .utf8)
        func operator_(_ action: String, _ arg: String) async throws -> Int {
            var request = URLRequest(url: URL(string: AppData.defaultRelay + "/v1/admin")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Pulshade-Admin-Token")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "arg": arg])
            return (try await URLSession.shared.data(for: request).1 as! HTTPURLResponse).statusCode
        }
        let news = try Announcement.make("Voice notes now show a waveform.", signedBy: admin)
        let forged = try Announcement.make("Send your recovery code to @scammer.", signedBy: Curve25519.Signing.PrivateKey())
        for a in [news, forged] { #expect(try await operator_("announce", String(decoding: JSONEncoder().encode(a), as: UTF8.self)) == 200) }

        for model in [alice, bob] {
            await model.refreshAnnouncements()
            let chat = try #require(model.conversation(Conversation.announcementsID))
            #expect(chat.messages.map(\.text) == ["Voice notes now show a waveform."])
            #expect(chat.messages.first?.sender == Announcement.handle)
            #expect(!model.canPost(in: chat))
            #expect(chat.unread == 1)
        }
        // An app that has the current list is told so, without being sent it again.
        let relay = try #require(alice.client(nil))
        let first = try #require(try await relay.announcements(since: nil))
        #expect(try await relay.announcements(since: first.version) == nil)
        // Asking again adds nothing, and a deleted chat only comes back with something new.
        await alice.refreshAnnouncements()
        #expect(alice.conversation(Conversation.announcementsID)?.messages.count == 1)
        alice.delete(Conversation.announcementsID)
        await alice.refreshAnnouncements()
        #expect(alice.conversation(Conversation.announcementsID) == nil)

        #expect(try await operator_("unannounce", news.id) == 200)
        #expect(try await operator_("unannounce", forged.id) == 200)
        await bob.refreshAnnouncements()
        #expect(bob.conversation(Conversation.announcementsID)?.messages.isEmpty == true, "taken back")
    }

    /// One taken back leaves every device that holds it, however the checks before it overlapped, and the
    /// notification it raised goes with it.
    @Test func aTakenBackAnnouncementLeavesEveryDevice() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        let previous = AppModel.adminKey
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = previous }
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        let token = try String(contentsOfFile: try #require(ProcessInfo.processInfo.environment["PULSHADE_TEST_DIR"]) + "/admin.token", encoding: .utf8)
        func operator_(_ action: String, _ arg: String) async throws -> Int {
            var request = URLRequest(url: URL(string: AppData.defaultRelay + "/v1/admin")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Pulshade-Admin-Token")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "arg": arg])
            return (try await URLSession.shared.data(for: request).1 as! HTTPURLResponse).statusCode
        }
        func announce(_ a: Announcement) async throws { #expect(try await operator_("announce", String(decoding: JSONEncoder().encode(a), as: UTF8.self)) == 200) }
        func texts(_ m: AppModel) -> [String] { m.conversation(Conversation.announcementsID)?.messages.map(\.text) ?? [] }

        let first = try Announcement.make("First test", signedBy: admin)
        try await announce(first)
        for m in [alice, bob] { await m.refreshAnnouncements(); await m.refreshAnnouncements() }
        #expect(texts(alice) == ["First test"] && texts(bob) == ["First test"])

        // Taken back, and something new straight after, while each device's checks overlap.
        #expect(try await operator_("unannounce", first.id) == 200)
        let second = try Announcement.make("Second test", signedBy: admin)
        try await announce(second)
        for m in [alice, bob] {
            async let one: Void = m.refreshAnnouncements()
            async let two: Void = m.refreshAnnouncements()
            _ = await (one, two)
            await m.refreshAnnouncements()
        }
        #expect(texts(alice) == ["Second test"])
        #expect(texts(bob) == ["Second test"])

        #expect(try await operator_("unannounce", second.id) == 200)
        for m in [alice, bob] { await m.refreshAnnouncements() }
        #expect(texts(alice).isEmpty && texts(bob).isEmpty)

        // Locked or closed, the watch raises one notification for something new, and the chat doesn't raise another.
        let third = try Announcement.make("Third test", signedBy: admin)
        try await announce(third)
        #expect(await AnnouncementWatch.check(), "reached the relay with no vault open")
        #expect(AnnouncementWatch.notice([third.id]).isEmpty, "noticed once")
        await alice.refreshAnnouncements()
        #expect(texts(alice) == ["Third test"])
    }

    /// Group members first reach each other through mailboxes made for the group, never the one each uses with
    /// the owner, and move to a private one after the first hello.
    @Test func groupMembersNeverLearnEachOthersMailboxWithTheOwner() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint
        let caraWithAlice = Mailbox.sendID(for: try #require(cara.data.contacts.first { $0.name == "Alice" }?.receiveKey))

        let group = alice.startConversation(kind: .group, title: "Night owls", members: [bobFP, caraFP])
        await settle(alice, bob, cara)
        let caraForBob = try #require(bob.data.contacts.first { $0.fingerprint == caraFP })
        #expect(!caraForBob.devices.isEmpty)
        #expect(!caraForBob.devices.contains { $0.sendID == caraWithAlice }, "Bob never gets Cara's mailbox with Alice")
        #expect(cara.conversation(group.id)?.introsMine.count == 1)

        bob.send("hi all", in: group.id)
        await settle(alice, bob, cara)
        #expect(cara.conversation(group.id)?.messages.map(\.text) == ["hi all"])
        await settle(alice, bob, cara)
        let caraWithBob = Mailbox.sendID(for: try #require(cara.data.contacts.first { $0.fingerprint == bob.identity?.fingerprint }?.receiveKey))
        #expect(bob.data.contacts.first { $0.fingerprint == caraFP }?.devices.map(\.sendID) == [caraWithBob],
                "after hello, Bob writes to a mailbox Cara opened just for him")
        cara.send("hey bob", in: group.id)
        await settle(alice, bob, cara)
        #expect(bob.conversation(group.id)?.messages.map(\.text) == ["hi all", "hey bob"])
    }

    @Test func inviteChatGroupChannelStory() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }

        // Bob accepts Alice's invite; both end up as contacts with real names.
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        #expect(Set(alice.visibleContacts.map(\.name)) == ["Bob", "Cara"])
        #expect(bob.visibleContacts.map(\.name) == ["Alice"])
        #expect(alice.data.invites.isEmpty)

        // Direct message with a delivery receipt.
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let chat = alice.startConversation(kind: .direct, title: "", members: [bobFP])
        alice.send("hey bob", in: chat.id)
        await settle(alice, bob)
        let bobChat = try #require(bob.data.conversations.first { $0.kind == .direct })
        #expect(bobChat.messages.map(\.text) == ["hey bob"])
        #expect(alice.conversation(chat.id)?.messages.first?.status == .delivered)

        // Group: Bob and Cara don't know each other but can talk inside it.
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint
        let group = alice.startConversation(kind: .group, title: "Night owls", members: [bobFP, caraFP])
        await settle(alice, bob, cara)
        let bobGroup = try #require(bob.conversation(group.id))
        #expect(bobGroup.title == "Night owls")
        bob.send("hi all", in: group.id)
        await settle(alice, bob, cara)
        #expect(cara.conversation(group.id)?.messages.map(\.text) == ["hi all"])
        #expect(alice.conversation(group.id)?.messages.map(\.text) == ["hi all"])
        #expect(cara.visibleContacts.map(\.name) == ["Alice"], "Bob stays out of Cara's contacts")

        // Channel: Cara follows, only Alice can post.
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [])
        _ = cara.addContact(code: alice.makeInviteCode(channel: channel.id), nickname: "")
        await settle(alice, cara)
        let caraChannel = try #require(cara.conversation(channel.id))
        #expect(caraChannel.amAdmin == false)
        alice.send("first drop", in: channel.id)
        cara.send("not allowed", in: channel.id)
        await settle(alice, cara)
        #expect(cara.conversation(channel.id)?.messages.map(\.text) == ["first drop"])
        #expect(alice.conversation(channel.id)?.messages.map(\.text) == ["first drop"])

        // Stories and profile changes reach contacts.
        alice.postStory(.text("hello night", palette: 2))
        await settle(alice, bob)
        #expect(bob.friendStories.first?.stories.count == 1)
        alice.updateProfile { $0.name = "Alice ✦" }
        try await Task.sleep(for: .seconds(2))
        await settle(alice, bob)
        #expect(bob.visibleContacts.first?.name == "Alice ✦")
    }

    @Test func reactionsUnsendTimersTypingVoice() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        let chat = try #require(alice.data.conversations.first { $0.kind == .direct })
        let bobChat = { try #require(bob.data.conversations.first { $0.kind == .direct }) }

        // Reactions travel and can be cleared.
        alice.send("react to this", in: chat.id)
        await settle(alice, bob)
        let messageID = try #require(bobChat().messages.last?.id)
        bob.react("🔥", to: messageID, in: try bobChat().id)
        await settle(alice, bob)
        #expect(alice.conversation(chat.id)?.messages.last?.reactions.values.first == "🔥")

        // Unsend removes it on both sides.
        alice.unsend(messageID, in: chat.id)
        await settle(alice, bob)
        #expect(try bobChat().messages.contains { $0.id == messageID } == false)

        // Typing shows up, then a timer turns on for both and messages carry an expiry.
        alice.noteTyping(in: chat.id)
        await settle(alice, bob, rounds: 2)
        #expect(bob.typers(in: try bobChat().id).count == 1)
        alice.setDisappearing(Disappear.fiveMinutes.rawValue, in: chat.id)
        await settle(alice, bob)
        #expect(try bobChat().disappearAfter == Disappear.fiveMinutes.rawValue)
        bob.send("gone soon", in: try bobChat().id)
        await settle(alice, bob)
        let incoming = try #require(alice.conversation(chat.id)?.messages.last { $0.text == "gone soon" })
        #expect(incoming.expiresAt != nil)

        // Voice notes arrive intact.
        let note = VoiceNote(audio: Data.random(40_000), duration: 3.2, levels: [10, 200, 90])
        alice.send("", voice: note, in: chat.id)
        await settle(alice, bob)
        #expect(try bobChat().messages.last?.voice == note)
    }

    @Test func personasStayUnlinked() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }

        // Bob knows Alice's main identity and, separately, her persona "Ghost".
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        let ghost = try #require(alice.createPersona(name: "Ghost"))
        alice.switchPersona(ghost.id)
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)

        let names = Set(bob.visibleContacts.map(\.name))
        #expect(names == ["Alice", "Ghost"])
        let fps = Set(bob.visibleContacts.map(\.fingerprint))
        #expect(fps.count == 2, "Two unrelated identities as far as Bob can tell")

        // Ghost's chat lives under Ghost; the main identity's under main.
        let ghostChat = try #require(alice.sortedConversations.first)
        #expect(ghostChat.persona == ghost.id)
        alice.send("from the ghost", in: ghostChat.id)
        await settle(alice, bob)
        let bobGhostChat = try #require(bob.data.conversations.first { $0.title == "Ghost" })
        #expect(bobGhostChat.messages.map(\.text) == ["from the ghost"])
        alice.switchPersona(nil)
        #expect(alice.sortedConversations.allSatisfy { $0.persona == nil })
    }

    /// Waits for something to become true, checking mailboxes as it goes.
    private func until(_ models: AppModel..., seconds: Double = 8, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnce() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func isLive(_ m: AppModel) -> Bool {
        if case .live = m.call?.phase { return true }
        return false
    }

    @Test func voiceCalls() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        let bobFP = try #require(alice.visibleContacts.first).fingerprint

        // Alice rings, Bob's phone rings, Bob picks up, and both hear each other through the relay.
        alice.startCall(with: bobFP, persona: nil)
        #expect(alice.call?.phase == .ringing && alice.call?.outgoing == true)
        await until(alice, bob) { bob.call?.phase == .ringing }
        #expect(bob.call?.outgoing == false && bob.call?.peer == alice.fingerprint)
        bob.answerCall()
        await until(alice, bob) { isLive(alice) && isLive(bob) }
        #expect(isLive(alice) && isLive(bob))

        alice.callMediaForTests?.sendAudio(Data([1, 2, 3]))
        bob.callMediaForTests?.sendAudio(Data([9, 8]))
        await until(alice, bob, seconds: 3) {
            (bob.callMediaForTests?.received.contains(Data([1, 2, 3])) ?? false)
                && (alice.callMediaForTests?.received.contains(Data([9, 8])) ?? false)
        }
        #expect(bob.callMediaForTests?.received.contains(Data([1, 2, 3])) == true)
        #expect(alice.callMediaForTests?.received.contains(Data([9, 8])) == true)

        // Hanging up ends it for both, with a note in each chat.
        alice.hangUp()
        await until(alice, bob) { bob.call == nil }
        #expect(alice.call == nil && bob.call == nil)
        let note = { (m: AppModel) in m.data.conversations.flatMap(\.messages).filter(\.isSystem).map(\.text) }
        #expect(note(alice).contains { $0.hasPrefix("📞 Outgoing call ·") })
        #expect(note(bob).contains { $0.hasPrefix("📞 Incoming call ·") })

        // Declined.
        alice.startCall(with: bobFP, persona: nil)
        await until(alice, bob) { bob.call?.phase == .ringing }
        bob.declineCall()
        await until(alice, bob) { alice.call == nil }
        #expect(alice.call == nil && note(alice).contains("📞 Declined"))

        // Cancelled before they pick up: a missed call for them.
        alice.startCall(with: bobFP, persona: nil)
        await until(alice, bob) { bob.call?.phase == .ringing }
        alice.hangUp()
        await until(alice, bob) { bob.call == nil }
        #expect(bob.call == nil && note(bob).contains("📞 Missed call"))
    }

    /// The same chat link as twelve digits: the link waits on the relay, sealed, and the first to type them takes it.
    @Test func oneTimeChatCodes() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }

        let link = alice.makeChatLink(lasting: 600)
        let code = try #require(await alice.makeChatCode(for: link))
        #expect(code.display.count == 14)

        guard case let .success(bobChatID) = await bob.joinChatCode(try #require(ChatCode(code.display))) else {
            Issue.record("The code didn't open a chat")
            return
        }
        bob.send("hi from the code", in: bobChatID)
        await settle(alice, bob)
        let aliceChat = try #require(alice.data.conversations.first { alice.isBurner($0.persona) })
        #expect(aliceChat.messages.contains { $0.text == "hi from the code" })

        // Used once, it's gone from the relay.
        guard case .failure(.unknown) = await cara.joinChatCode(code) else {
            Issue.record("A used code opened a chat")
            return
        }
    }

    /// Read receipts: sent when you open the chat, seen only by someone who has them on too, and never in a
    /// one-time chat. Bios reach contacts with the rest of the profile.
    @Test func readReceiptsAndBios() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let chat = alice.startConversation(kind: .direct, title: "", members: [bobFP])

        alice.send("one", in: chat.id)
        await settle(alice, bob)
        #expect(alice.conversation(chat.id)?.messages.last?.status == .delivered)
        let bobChat = try #require(bob.data.conversations.first { $0.kind == .direct })
        bob.markRead(bobChat.id)
        await settle(alice, bob)
        #expect(alice.conversation(chat.id)?.messages.last?.status == .read)

        // Alice turns them off: she no longer sees Bob's.
        alice.updateSecurity { $0.readReceipts = false }
        alice.send("two", in: chat.id)
        await settle(alice, bob)
        bob.markRead(bobChat.id)
        await settle(alice, bob)
        #expect(alice.conversation(chat.id)?.messages.last?.status == .delivered)

        // Bob turns them off: he sends none.
        alice.updateSecurity { $0.readReceipts = true }
        bob.updateSecurity { $0.readReceipts = false }
        alice.send("three", in: chat.id)
        await settle(alice, bob)
        bob.markRead(bobChat.id)
        await settle(alice, bob)
        #expect(alice.conversation(chat.id)?.messages.last?.status == .delivered)

        // A one-time chat never sends them, with the setting on.
        bob.updateSecurity { $0.readReceipts = true }
        let link = alice.makeChatLink(lasting: 600)
        guard case let .chat(bobOneTime) = bob.useScannedCode(link.link) else {
            Issue.record("The link didn't open a chat")
            return
        }
        bob.send("hi", in: bobOneTime)
        await settle(alice, bob)
        let aliceOneTime = try #require(alice.data.conversations.first { alice.isBurner($0.persona) })
        alice.send("seen?", in: aliceOneTime.id)
        await settle(alice, bob)
        bob.markRead(bobOneTime)
        await settle(alice, bob)
        #expect(alice.conversation(aliceOneTime.id)?.messages.last?.status == .delivered)

        // Alice's bio reaches Bob.
        alice.updateProfile { $0.bio = "Find me at https://zeekz.world" }
        // Profile updates go out on their own timer, slower when the whole suite is running: keep checking.
        for _ in 0..<10 where bob.visibleContacts.first(where: { $0.name == "Alice" })?.bio != "Find me at https://zeekz.world" {
            try await Task.sleep(for: .seconds(1))
            await settle(alice, bob)
        }
        #expect(bob.visibleContacts.first { $0.name == "Alice" }?.bio == "Find me at https://zeekz.world")
    }

    @Test func oneTimeChatLinks() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }

        let link = alice.makeChatLink(lasting: 600)
        #expect(ChatLink(link.link) == link, "the link survives being shared")
        #expect(abs(link.endsAt.timeIntervalSinceNow - 600) < 5)

        // Bob taps it: a chat opens straight away, as a throwaway identity that ends when Alice's does.
        guard case let .chat(bobChatID) = bob.useScannedCode(link.link) else {
            Issue.record("The link didn't open a chat")
            return
        }
        let bobChat = try #require(bob.conversation(bobChatID))
        let bobBurner = try #require(bob.burner(bobChat.persona))
        #expect(abs((bobBurner.burnsAt ?? .distantPast).timeIntervalSince(link.endsAt)) < 2)
        #expect(bob.visibleContacts.isEmpty, "nothing joins Bob's real contacts")
        bob.send("hi from the link", in: bobChatID)
        await settle(alice, bob)

        let aliceChat = try #require(alice.data.conversations.first { alice.isBurner($0.persona) })
        #expect(aliceChat.messages.contains { $0.text == "hi from the link" })
        #expect(!aliceChat.title.contains("Bob"), "Alice sees a throwaway name, not Bob")
        #expect(!bobChat.title.contains("Alice"), "Bob sees a throwaway name, not Alice")
        alice.send("hello back", in: aliceChat.id)
        await settle(alice, bob)
        #expect(bob.conversation(bobChatID)?.messages.contains { $0.text == "hello back" } == true)

        // It works once: Cara gets a chat that never connects, and Alice never hears from her.
        _ = cara.useScannedCode(link.link)
        await settle(alice, cara)
        #expect(alice.data.contacts.filter { $0.persona == aliceChat.persona && !$0.hidden }.count == 1)

        // An ended link opens nothing.
        let old = ChatLink(invite: alice.makeInviteCode(), endsAt: Date().addingTimeInterval(-60))
        guard case .expired = bob.useScannedCode(old.link) else {
            Issue.record("An ended link opened a chat")
            return
        }

        // When it ends, it's gone on both sides.
        alice.burn(try #require(aliceChat.persona))
        await settle(alice, bob)
        #expect(!alice.data.conversations.contains { $0.id == aliceChat.id })
        #expect(bob.conversation(bobChatID)?.messages.isEmpty ?? true)
    }

    @Test func burnerChatsBurnOnBothSides() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }

        let burner = alice.createBurner(lasting: 3600)
        _ = try #require(bob.addContact(code: alice.makeInviteCode(persona: .some(burner)), nickname: ""))
        await settle(alice, bob)
        let chat = try #require(alice.data.conversations.first { $0.persona == burner })
        #expect(bob.visibleContacts.first?.name != "Alice", "Bob sees the burner's random name, not Alice")
        alice.send("one time only", in: chat.id)
        await settle(alice, bob)
        #expect(bob.data.conversations.first?.messages.last?.text == "one time only")

        alice.burn(burner)
        await settle(alice, bob)
        #expect(alice.data.personas.isEmpty && alice.data.conversations.isEmpty)
        #expect(bob.data.conversations.isEmpty && bob.visibleContacts.isEmpty)
    }

    @Test func removingAContactForgetsYouOnBothSidesAndEveryDevice() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let phone = try await linkNewDevice(to: alice)
        defer { phone.lock() }
        await settle(alice, phone, bob, cara, rounds: 8)
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint
        let aliceFP = try #require(alice.identity).fingerprint
        let chat = alice.startConversation(kind: .direct, title: "", members: [bobFP])
        alice.send("before", in: chat.id)
        bob.postStory(.text("bob's story", palette: 0))
        await settle(alice, phone, bob)
        #expect(phone.data.conversations.contains { $0.kind == .direct && $0.members == [bobFP] })
        #expect(alice.friendStories.count == 1)

        // Bob goes from Alice's devices, and Alice and the chat go from Bob's.
        alice.removeContact(bobFP, persona: nil)
        await settle(alice, phone, bob)
        #expect(!alice.visibleContacts.contains { $0.fingerprint == bobFP })
        #expect(alice.contact(bobFP) == nil, "nothing shared with Bob, so his keys and mailboxes go too")
        #expect(!alice.data.conversations.contains { $0.members == [bobFP] })
        #expect(alice.friendStories.isEmpty, "his stories go with him")
        #expect(!phone.visibleContacts.contains { $0.fingerprint == bobFP }, "the phone forgets him too")
        #expect(!phone.data.conversations.contains { $0.members == [bobFP] })
        #expect(bob.contact(aliceFP) == nil)
        #expect(bob.data.conversations.isEmpty)

        // Someone you share a group with stays only as a member of it, and the group still works.
        let group = alice.startConversation(kind: .group, title: "Still here", members: [caraFP])
        await settle(alice, phone, cara)
        phone.removeContact(caraFP, persona: nil)
        await settle(alice, phone, cara)
        #expect(!alice.visibleContacts.contains { $0.fingerprint == caraFP })
        #expect(alice.contact(caraFP)?.hidden == true)
        #expect(cara.visibleContacts.isEmpty && cara.contact(aliceFP)?.hidden == true)
        #expect(!cara.data.conversations.contains { $0.kind == .direct })
        cara.send("group still works", in: group.id)
        await settle(alice, phone, cara)
        #expect(alice.conversation(group.id)?.messages.last?.text == "group still works")
    }

    /// A video whose pieces went missing on the way shows as loading, is asked for again, and plays once whole,
    /// whether a piece or the story itself was lost.
    @Test func aVideoMissingPiecesIsAskedForAgainAndArrives() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        let clip = Data((0..<StoryVideo.maxBytes).map { _ in UInt8.random(in: 0...255) })
        alice.postStory(.video(clip, caption: "clip"))
        await settle(alice, bob)
        let id = try #require(alice.myStories.first?.id)
        let pieces = StoryClipPieces.split(clip)
        #expect(pieces.count > 2)

        // Lost on the way: Bob has the story and the first piece only.
        let i = try #require(bob.data.stories.firstIndex { $0.id == id })
        bob.data.stories[i].style = .video(Data(), caption: "clip")
        bob.data.clipParts[id] = ClipParts(author: bob.data.stories[i].author, persona: nil, of: pieces.count, parts: [0: pieces[0]])
        #expect(bob.friendStories.first?.stories.first?.isReady == false, "listed, as loading")
        await settle(alice, bob, rounds: 2)
        #expect(bob.data.stories[i].isReady == false, "nothing is asked for while pieces might still be on their way")

        bob.clipQuiet = 0
        alice.clipQuiet = 0
        await settle(alice, bob)
        await settle(bob, alice)
        #expect(bob.data.stories.first { $0.id == id }?.style == .video(clip, caption: "clip"))
        #expect(bob.data.clipParts[id] == nil)

        // The story itself lost, with some pieces in: asking brings the story back with the rest.
        let author = bob.data.stories[i].author
        bob.data.stories.removeAll { $0.id == id }
        bob.data.clipParts[id] = ClipParts(author: author, persona: nil, of: pieces.count, parts: [1: pieces[1]])
        await settle(bob, alice)
        await settle(bob, alice)
        #expect(bob.data.stories.first { $0.id == id }?.style == .video(clip, caption: "clip"))
    }

    @Test func likingOrReplyingToAStoryMessagesItsAuthor() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        alice.postStory(.image(StoryMediaTests.photo(), caption: "sunset"))
        alice.postStory(.text("hello night", palette: 2))
        await settle(alice, bob)
        let stories = try #require(bob.friendStories.first?.stories)
        let story = try #require(stories.first { if case .image = $0.style { true } else { false } })
        let words = try #require(stories.first { if case .text = $0.style { true } else { false } })

        await bob.answerStory(story, like: true)
        #expect(bob.data.stories.first { $0.id == story.id }?.liked == true)
        await bob.answerStory(story, text: "  lovely  ")
        await bob.answerStory(story, text: "")
        await bob.answerStory(words, text: "nice")
        await settle(alice, bob)

        let chat = try #require(alice.data.conversations.first { $0.kind == .direct })
        let answers = chat.messages.filter { $0.reply?.id == story.id }
        #expect(answers.map(\.text) == ["❤️ Liked your story", "lovely"])
        #expect(answers.allSatisfy { $0.reply?.author == "me" && $0.reply?.snippet == "Photo story: sunset" },
                "they quote Alice's own story")
        // With a small picture of it, on both sides: the story will be gone, the chat won't.
        for m in answers {
            let picture = try #require(m.reply?.picture)
            #expect(picture.count <= ReplyRef.maxPicture && PlatformImage(data: picture) != nil)
        }
        #expect(bob.data.conversations.first { $0.kind == .direct }?.messages.first?.reply?.picture != nil)
        let toWords = try #require(chat.messages.first { $0.reply?.id == words.id })
        #expect(toWords.reply?.snippet == "Story: hello night" && toWords.reply?.picture != nil, "a text story is drawn small")
    }

    @Test func storiesHaveAudiencesLifetimesEditsAndViews() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint

        // Only Bob, for six hours.
        alice.postStory(.text("just bob", palette: 1), audience: .only([bobFP]), lifetime: StoryLifetime.sixHours.rawValue)
        await settle(alice, bob, cara)
        let story = try #require(alice.myStories.first)
        #expect(bob.friendStories.first?.stories.first?.lifetime == StoryLifetime.sixHours.rawValue)
        #expect(cara.friendStories.isEmpty, "Cara isn't in the audience")
        #expect(alice.storyChoice == StoryChoice(audience: .only([bobFP]), lifetime: StoryLifetime.sixHours.rawValue),
                "the next story offers the same choice")

        // Bob views it; the receipt travels through the ratchet back to Alice.
        bob.markSeen(story.id)
        await settle(alice, bob)
        #expect(alice.viewers(of: story.id).map(\.fingerprint) == [bobFP])

        // Edited: new words, everyone but Bob. Bob loses it, Cara gets the new version.
        alice.editStory(story.id, style: .text("not bob", palette: 1), audience: .except([bobFP]), lifetime: StoryLifetime.day.rawValue)
        await settle(alice, bob, cara)
        #expect(bob.friendStories.isEmpty)
        #expect(cara.friendStories.first?.stories.first?.style == .text("not bob", palette: 1))
        #expect(alice.viewers(of: story.id).count == 1, "earlier views stay on the list")

        // Cara with story views off: she sees it, but Alice isn't told.
        cara.updateSecurity { $0.storyViews = false }
        cara.markSeen(story.id)
        await settle(alice, cara)
        #expect(alice.viewers(of: story.id).map(\.fingerprint) == [bobFP])

        // A photo's caption can change; the photo can't.
        let photo = Data([1, 2, 3])
        alice.postStory(.image(photo, caption: "one"), audience: .everyone)
        await settle(alice, bob, cara)
        let photoStory = try #require(alice.myStories.first { if case .image = $0.style { true } else { false } })
        alice.editStory(photoStory.id, style: .image(Data([9]), caption: "two"), audience: .everyone, lifetime: StoryLifetime.day.rawValue)
        await settle(alice, bob)
        #expect(bob.friendStories.first?.stories.first?.style == .image(photo, caption: "two"))

        // A full-size clip travels too, in pieces, and is put back together.
        let clip = Data((0..<StoryVideo.maxBytes).map { _ in UInt8.random(in: 0...255) })
        alice.postStory(.video(clip, caption: "clip"), audience: .everyone)
        await settle(alice, bob, cara)
        #expect(bob.friendStories.first?.stories.contains { $0.style == .video(clip, caption: "clip") } == true)
        // A new caption doesn't send the clip again.
        let clipStory = try #require(alice.myStories.first { if case .video = $0.style { true } else { false } })
        alice.editStory(clipStory.id, style: .video(Data(), caption: "again"), audience: .everyone, lifetime: StoryLifetime.day.rawValue)
        await settle(alice, bob)
        #expect(bob.friendStories.first?.stories.contains { $0.style == .video(clip, caption: "again") } == true)

        // Deleting reaches the people who could see it.
        alice.deleteStory(story.id)
        await settle(alice, bob, cara)
        #expect(!cara.data.stories.contains { $0.id == story.id })
        #expect(cara.data.stories.contains { $0.id == photoStory.id })
    }

    @Test func publicProfileRequestsAcceptAndBlock() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let carol = try await makeUser("Carol")
        defer { for m in [alice, bob, carol] { m.lock() } }
        let handle = "alice_\(Int.random(in: 10000...99999))"

        alice.updateProfile { $0.bio = "night photographer" }
        try await alice.publishProfile(handle: handle)
        #expect(alice.activeProfile.handle == handle)
        // Someone else can't take it.
        await #expect(throws: AppModel.DirectoryError.self) { try await bob.publishProfile(handle: handle) }

        // Bob finds her by exact handle only and sends a request with a note.
        let found = try #require(try await bob.findProfile("@" + handle.uppercased()))
        #expect(found.name == "Alice" && found.bio == "night photographer")
        #expect(try await bob.findProfile("nobody_here_\(Int.random(in: 1...9999))") == nil)
        _ = try #require(bob.sendRequest(to: found, note: "loved your photos"))
        #expect(bob.visibleContacts.isEmpty, "Nothing shows until she accepts")
        await settle(alice, bob)
        let request = try #require(alice.requests.first)
        #expect(request.note == "loved your photos" && request.card.name == "Bob")
        #expect(alice.visibleContacts.isEmpty, "Requests aren't contacts")

        // She accepts: both get a chat, and Bob moves off her public mailbox.
        let publicSendID = found.sendID
        _ = try #require(alice.acceptRequest(request.id))
        await settle(alice, bob)
        let bobsAlice = try #require(bob.visibleContacts.first)
        #expect(bobsAlice.sendID != publicSendID)
        let bobChat = try #require(bob.data.conversations.first)
        bob.send("hey!", in: bobChat.id)
        await settle(alice, bob)
        #expect(alice.data.conversations.first?.messages.last?.text == "hey!")

        // Carol gets blocked; asking again leaves no trace.
        let foundAgain = try #require(try await carol.findProfile(handle))
        carol.sendRequest(to: foundAgain, note: "hi")
        await settle(alice, carol)
        alice.blockRequest(try #require(alice.requests.first).id)
        carol.data.contacts.removeAll()
        carol.sendRequest(to: foundAgain, note: "please")
        await settle(alice, carol)
        #expect(alice.requests.isEmpty)

        // Going private removes the listing.
        await alice.unpublishProfile()
        #expect(try await bob.findProfile(handle) == nil)
    }

    /// One side still has the other as a friend; the other lost them and asks again. They reconnect by
    /// themselves, instead of the request vanishing and each side waiting on the other.
    @Test func aFriendWhoLostYouReconnectsByAskingAgain() async throws {
        let mac = try await makeUser("Mac")
        let phone = try await makeUser("Phone")
        defer { for m in [mac, phone] { m.lock() } }
        let handle = "again_\(Int.random(in: 10000...99999))"
        try await mac.publishProfile(handle: handle)
        let found = try #require(try await phone.findProfile(handle))
        phone.sendRequest(to: found, note: "")
        await settle(mac, phone)
        let first = try #require(mac.requests.first)
        _ = try #require(mac.acceptRequest(first.id))
        await settle(mac, phone)
        let phoneFP = phone.fingerprint
        let i = try #require(mac.data.contacts.firstIndex { $0.fingerprint == phoneFP })
        mac.data.contacts[i].nickname = "My phone"

        // The phone loses the Mac. The Mac still thinks they're friends.
        phone.data.contacts.removeAll { $0.fingerprint == mac.fingerprint }
        phone.data.conversations.removeAll()
        let macChat = try #require(mac.data.conversations.first { $0.kind == .direct })

        phone.sendRequest(to: found, note: "it's me again")
        await settle(mac, phone, rounds: 8)
        #expect(mac.requests.isEmpty, "No request to answer: they're reconnected")
        let peer = try #require(mac.data.contacts.first { $0.fingerprint == phoneFP })
        #expect(peer.nickname == "My phone", "What you set for them is kept")
        #expect(mac.data.conversations.filter { $0.kind == .direct }.count == 1, "The same chat, not a second one")
        let macsMac = try #require(phone.data.contacts.first { $0.fingerprint == mac.fingerprint })
        #expect(!macsMac.awaitingAcceptance, "The phone sees the request accepted")

        mac.send("can you see this?", in: macChat.id)
        await settle(mac, phone)
        let phoneChat = try #require(phone.data.conversations.first { $0.kind == .direct })
        #expect(phoneChat.messages.contains { $0.text == "can you see this?" })
        phone.send("yes", in: phoneChat.id)
        await settle(mac, phone)
        #expect(mac.conversation(macChat.id)?.messages.contains { $0.text == "yes" } == true)
        await mac.unpublishProfile()
    }

    /// A request that waits a while for an answer, while the one who sent it changes their profile, still ends in a
    /// chat that works both ways. The profile update waited on the request's handshake, which was started again after
    /// a minute, so the acceptance that came later answered a handshake the phone no longer had: the phone kept
    /// showing the request as waiting and wrote to the public request mailbox.
    @Test func aRequestAnsweredLateStillOpensAChat() async throws {
        let mac = try await makeUser("Mac")
        let phone = try await makeUser("Phone")
        defer { for m in [mac, phone] { m.lock() } }
        let handle = "late_\(Int.random(in: 10000...99999))"
        try await mac.publishProfile(handle: handle)
        let found = try #require(try await phone.findProfile(handle))
        _ = try #require(phone.sendRequest(to: found, note: "hi from my phone"))
        await settle(mac, phone)
        let request = try #require(mac.requests.first)

        // While it waits, the phone changes its profile, and more than a minute goes by.
        phone.updateProfile { $0.bio = "on the go" }
        try await Task.sleep(for: .seconds(2))
        let macFP = mac.fingerprint
        let i = try #require(phone.data.contacts.firstIndex { $0.fingerprint == macFP })
        let asked = try #require(phone.data.contacts[i].devices[0].handshake?.ephemeral)
        phone.data.contacts[i].devices[0].handshake?.startedAt = Date().addingTimeInterval(-120)
        await settle(mac, phone)
        #expect(phone.data.contacts[i].devices[0].handshake?.ephemeral == asked, "The request's handshake is kept for the answer")

        _ = try #require(mac.acceptRequest(request.id))
        await settle(mac, phone, rounds: 8)
        let phonesMac = try #require(phone.data.contacts.first { $0.fingerprint == macFP })
        #expect(!phonesMac.awaitingAcceptance, "The phone sees the request accepted")
        #expect(phonesMac.sendID != found.sendID, "and writes to the mailbox the Mac opened for it")
        #expect(phonesMac.bio == nil)
        #expect(mac.data.contacts.first { $0.fingerprint == phone.fingerprint }?.bio == "on the go", "The waiting profile arrives")
        let phoneChat = try #require(phone.data.conversations.first { $0.kind == .direct })
        phone.send("can you see this?", in: phoneChat.id)
        await settle(mac, phone)
        let macChat = try #require(mac.data.conversations.first { $0.kind == .direct })
        #expect(mac.conversation(macChat.id)?.messages.contains { $0.text == "can you see this?" } == true)
        mac.send("yes", in: macChat.id)
        await settle(mac, phone)
        #expect(phone.conversation(phoneChat.id)?.messages.contains { $0.text == "yes" } == true)

        // A phone already caught this way (it has a session, but never heard it was accepted) is told again as soon
        // as it writes to the public mailbox, and moves to its own.
        let j = try #require(phone.data.contacts.firstIndex { $0.fingerprint == macFP })
        phone.data.contacts[j].awaitingAcceptance = true
        phone.data.contacts[j].sendID = found.sendID
        phone.send("still there?", in: phoneChat.id)
        await settle(mac, phone)
        #expect(mac.conversation(macChat.id)?.messages.contains { $0.text == "still there?" } == true)
        let healed = try #require(phone.data.contacts.first { $0.fingerprint == macFP })
        #expect(!healed.awaitingAcceptance && healed.sendID != found.sendID)
        await mac.unpublishProfile()
    }

    /// After the passcode, Pulshade waits on a connecting screen until the relay answers.
    @Test func unlockingWaitsForTheRelay() async throws {
        let model = try await makeUser("Waiting")
        defer { model.lock() }
        model.lock()
        #expect(await model.unlock(passcode: "test-passcode"))
        #expect(model.connecting, "Not let in until the relay has answered")
        for _ in 0..<50 where model.connecting { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!model.connecting && model.link == .online)
        model.lock()
        #expect(!model.connecting)
    }

    @Test func deletingAChatDeletesItForEveryone() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)

        // Bob deletes his direct chat with Alice: hers goes too, though they stay contacts.
        let aliceForBob = try #require(bob.visibleContacts.first)
        let bobChat = bob.startConversation(kind: .direct, title: "", members: [aliceForBob.fingerprint])
        bob.send("about to vanish", in: bobChat.id)
        await settle(alice, bob)
        bob.delete(bobChat.id)
        await settle(alice, bob)
        #expect(!alice.data.conversations.contains { $0.kind == .direct && $0.members.contains(bob.fingerprint) })
        #expect(alice.visibleContacts.contains { $0.name == "Bob" })

        // A member deleting a group just leaves it; the owner deleting it removes it for all.
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint
        let group = alice.startConversation(kind: .group, title: "Gone soon", members: [bobFP, caraFP])
        await settle(alice, bob, cara)
        #expect(cara.conversation(group.id) != nil)
        cara.delete(group.id)
        await settle(alice, bob, cara)
        #expect(alice.conversation(group.id)?.members == [bobFP])
        #expect(bob.conversation(group.id) != nil)
        alice.delete(group.id)
        await settle(alice, bob)
        #expect(bob.conversation(group.id) == nil)

        // A follower deleting a channel only unfollows; the owner deleting it removes it for followers.
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [])
        _ = bob.addContact(code: alice.makeInviteCode(channel: channel.id), nickname: "")
        _ = cara.addContact(code: alice.makeInviteCode(channel: channel.id), nickname: "")
        await settle(alice, bob, cara)
        #expect(alice.conversation(channel.id)?.members.count == 2)
        bob.delete(channel.id)
        await settle(alice, bob)
        #expect(alice.conversation(channel.id)?.members.count == 1)
        alice.delete(channel.id)
        await settle(alice, cara)
        #expect(cara.conversation(channel.id) == nil)
    }

    @Test func channelManagementRolesAndReplies() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint

        // Alice makes a channel, describes it and adds both from her contacts.
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [])
        alice.updateDetails(channel.id, title: "Drops", about: "New music on Fridays", avatar: nil)
        alice.addMembers(channel.id, [bobFP, caraFP])
        await settle(alice, bob, cara)
        let bobsView = try #require(bob.conversation(channel.id))
        #expect(bobsView.about == "New music on Fridays")
        #expect(!bob.canPost(in: bobsView), "Followers can't post")

        // Promote Bob: he can post, and Cara accepts his posts.
        alice.setAdmin(channel.id, bobFP, true)
        await settle(alice, bob, cara, rounds: 8)
        #expect(bob.conversation(channel.id).map(bob.canPost(in:)) == true)
        bob.send("admin post", in: channel.id)
        await settle(alice, bob, cara, rounds: 8)
        #expect(cara.conversation(channel.id)?.messages.last?.text == "admin post")

        // Cara can't post even if she tries.
        cara.send("sneaky", in: channel.id)
        await settle(alice, bob, cara)
        #expect(alice.conversation(channel.id)?.messages.contains { $0.text == "sneaky" } == false)

        // Removing Cara takes the channel away from her.
        alice.removeMember(channel.id, caraFP)
        await settle(alice, cara)
        #expect(cara.conversation(channel.id) == nil)

        // Groups: owner-only posting blocks members.
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP])
        await settle(alice, bob)
        alice.setPostPolicy(group.id, .owner)
        await settle(alice, bob)
        #expect(bob.conversation(group.id).map(bob.canPost(in:)) == false)

        // Replies and link previews travel with the message, quoting the right person.
        let chat = try #require(alice.data.conversations.first { $0.kind == .direct && $0.members == [bobFP] })
        alice.send("first", in: chat.id)
        await settle(alice, bob)
        let bobChat = try #require(bob.data.conversations.first { $0.kind == .direct })
        let original = try #require(bobChat.messages.last)
        let preview = LinkPreview(url: "https://example.com/a", title: "Example", site: "example.com", image: nil)
        bob.send("replying https://example.com/a", replyTo: original, preview: preview, in: bobChat.id)
        await settle(alice, bob)
        let reply = try #require(alice.conversation(chat.id)?.messages.last)
        #expect(reply.reply?.author == "me" && reply.reply?.snippet == "first")
        #expect(reply.preview?.title == "Example")
    }

    /// A mod can post when only admins can and take an ordinary member out, but nothing else.
    @Test func modsPostAndRemoveOrdinaryMembersOnly() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint
        let aliceFP = try #require(bob.visibleContacts.first { $0.name == "Alice" }).fingerprint

        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP, caraFP])
        await settle(alice, bob, cara, rounds: 8)
        alice.setPostPolicy(group.id, .admins)
        await settle(alice, bob, cara, rounds: 8)
        #expect(bob.conversation(group.id).map(bob.canPost(in:)) == false)

        // Bob becomes a mod: he sees the tag, can post, and Cara accepts it.
        alice.setMod(group.id, bobFP, true)
        await settle(alice, bob, cara, rounds: 8)
        #expect(bob.conversation(group.id)?.amMod == true)
        #expect(cara.role(of: bobFP, in: try #require(cara.conversation(group.id))) == "Mod")
        bob.send("mod post", in: group.id)
        await settle(alice, bob, cara, rounds: 8)
        #expect(cara.conversation(group.id)?.messages.last?.text == "mod post")

        // He can't appoint anyone, and can't remove the owner.
        bob.setMod(group.id, caraFP, true)
        bob.setAdmin(group.id, caraFP, true)
        bob.removeMember(group.id, aliceFP)
        await settle(alice, bob, cara, rounds: 8)
        #expect(alice.conversation(group.id)?.mods == [bobFP] && alice.conversation(group.id)?.admins.isEmpty == true)
        #expect(alice.conversation(group.id) != nil)

        // He can take Cara out; she loses the group, and Alice's member list drops her.
        bob.removeMember(group.id, caraFP)
        await settle(alice, bob, cara, rounds: 8)
        #expect(cara.conversation(group.id) == nil)
        #expect(alice.conversation(group.id)?.members.contains(caraFP) == false)

        // The owner takes the tag away again.
        alice.setMod(group.id, bobFP, false)
        await settle(alice, bob, rounds: 8)
        #expect(bob.conversation(group.id)?.amMod == false)
        #expect(bob.conversation(group.id).map(bob.canPost(in:)) == false)
    }

    /// Someone who becomes a contact while a story is up gets it too, whichever side scanned the other's invite,
    /// as long as they're in its audience.
    @Test func newContactsGetStoriesAlreadyUp() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        let dan = try await makeUser("Dan")
        defer { for m in [alice, bob, cara, dan] { m.lock() } }
        alice.postStory(.text("already up", palette: 1))
        alice.postStory(.text("nobody yet", palette: 2), audience: .only([]))

        // They scan Alice's invite after she posted.
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        // Alice scans theirs.
        _ = try #require(alice.addContact(code: cara.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara, rounds: 10)
        for viewer in [bob, cara] {
            let seen = viewer.friendStories.flatMap(\.stories).map(\.style)
            #expect(seen == [.text("already up", palette: 1)], "Only the story shared with everyone arrives")
        }

        // And so does one who joins later still.
        _ = try #require(dan.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, dan, rounds: 10)
        #expect(dan.friendStories.flatMap(\.stories).map(\.style) == [.text("already up", palette: 1)])
    }

    /// People you scanned a moment ago, with no chat yet, still get a group you make straight away, and one you
    /// add to it later.
    @Test func groupsReachNewContactsAndLaterAdditions() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        let dan = try await makeUser("Dan")
        defer { for m in [alice, bob, cara, dan] { m.lock() } }
        let b = try #require(alice.addContact(code: bob.makeInviteCode(), nickname: ""))
        let c = try #require(alice.addContact(code: cara.makeInviteCode(), nickname: ""))
        let group = alice.startConversation(kind: .group, title: "Now", members: [b.fingerprint, c.fingerprint])
        await settle(alice, bob, cara, rounds: 12)
        #expect(bob.conversation(group.id)?.members.count == 2)
        #expect(cara.conversation(group.id)?.members.count == 2)

        let d = try #require(alice.addContact(code: dan.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara, dan, rounds: 6)
        alice.addMembers(group.id, [d.fingerprint])
        await settle(alice, bob, cara, dan, rounds: 12)
        #expect(dan.conversation(group.id)?.members.count == 3)
        #expect(bob.conversation(group.id)?.members.count == 3, "Existing members hear about the new one")
    }

    /// A group announcement carries everyone's avatar. With full-size ones it was hundreds of kilobytes, far
    /// bigger than any message, and the one a slow Tor circuit fails to carry; shrunk, it's an ordinary size.
    @Test func groupAnnouncementsStaySmallWithRealAvatars() async throws {
        func picture() throws -> Data {
            let ctx = try #require(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            // Soft overlapping shapes, which compress like a photo does (noise would not shrink when resized).
            for _ in 0..<400 {
                ctx.setFillColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 0.45)
                let size = CGFloat.random(in: 20...200)
                ctx.fillEllipse(in: CGRect(x: .random(in: -50...450), y: .random(in: -50...450), width: size, height: size))
            }
            let data = NSMutableData()
            let dest = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            #expect(CGImageDestinationFinalize(dest))
            return data as Data
        }
        func user(_ name: String) async throws -> AppModel {
            let model = testModel("pulshade-test")
            try await model.create(identity: .generate(), profile: Profile(name: name, avatar: try picture()), passcode: "test-passcode")
            return model
        }
        let alice = try await user("Alice"), bob = try await user("Bob"), cara = try await user("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let full = try picture()
        #expect(full.count > 20_000, "The test picture should be a realistic size")
        let before = Set(alice.data.outbox.map(\.id))
        let group = alice.startConversation(kind: .group, title: "Av", members: alice.visibleContacts.map(\.fingerprint), avatar: full)
        let sizes = alice.data.outbox.filter { !before.contains($0.id) }.map(\.blob.count)
        // Before the shrink the same two announcements were 524,349 bytes each.
        #expect(sizes.count == 2 && sizes.allSatisfy { $0 < 300_000 }, "Announcement sizes: \(sizes)")
        #expect((AppModel.thumbnail(full, side: 96)?.count ?? .max) < full.count / 3)
        #expect(AppModel.thumbnail(Data([1, 2, 3]), side: 96) == Data([1, 2, 3]), "Small ones go as they are")
        #expect(AppModel.thumbnail(Data(count: 20_000), side: 96) == nil, "What isn't a picture isn't sent")
        await settle(alice, bob, cara, rounds: 12)
        #expect(bob.conversation(group.id)?.members.count == 2 && cara.conversation(group.id)?.members.count == 2)
        #expect(bob.conversation(group.id)?.avatar != nil)
    }

    /// A deleted story goes from everyone it was shown to, and each of them remembers it was taken back, so a late
    /// or repeated copy can't bring it back.
    @Test func deletedStoriesGoAndStayGone() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        alice.postStory(.text("here and gone", palette: 1))
        await settle(alice, bob)
        let story = try #require(alice.myStories.first)
        #expect(bob.friendStories.flatMap(\.stories).map(\.id) == [story.id])

        alice.deleteStory(story.id)
        await settle(alice, bob)
        #expect(bob.friendStories.isEmpty && alice.myStories.isEmpty)
        let aliceFP = try #require(bob.visibleContacts.first).fingerprint
        #expect(bob.removedStories["\(aliceFP)|\(story.id)"] != nil, "Bob remembers it was taken back")
        #expect(alice.removedStories["me|\(story.id)"] != nil)
    }

    /// One envelope the relay refuses (too large) at the front of the queue must not hold up the ones behind it.
    @Test func aFailingLargeEnvelopeDoesNotBlockTheQueue() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        // Over what the relay takes, first in line.
        alice.data.outbox.insert(Outgoing(sendID: Data(repeating: 7, count: 32), blob: Data(count: 5 * 1024 * 1024), relay: nil), at: 0)
        let chat = try #require(alice.data.conversations.first { $0.kind == .direct })
        alice.send("not held up", in: chat.id)
        await settle(alice, bob, rounds: 8)
        #expect(bob.data.conversations.first { $0.kind == .direct }?.messages.last?.text == "not held up")
    }

    /// A burst to many mailboxes all goes out, and in order for each.
    @Test func aBurstOfSendsAllArrivesInOrder() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let toBob = try #require(alice.data.conversations.first { $0.kind == .direct && $0.title == "Bob" })
        let toCara = try #require(alice.data.conversations.first { $0.kind == .direct && $0.title == "Cara" })
        for n in 1...5 { alice.send("b\(n)", in: toBob.id); alice.send("c\(n)", in: toCara.id) }
        await settle(alice, bob, cara, rounds: 10)
        let b = bob.data.conversations.first { $0.kind == .direct }?.messages.map(\.text)
        let c = cara.data.conversations.first { $0.kind == .direct }?.messages.map(\.text)
        #expect(b == ["b1", "b2", "b3", "b4", "b5"] && c == ["c1", "c2", "c3", "c4", "c5"])
    }

    /// A mod, or anyone who isn't the owner, can't use a group update to take more than their role allows: not a
    /// version far ahead (which would freeze the group for everyone), not an update that removes no one, not a
    /// new admin or a rename.
    @Test func forgedGroupUpdatesAreRefused() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP, caraFP])
        await settle(alice, bob, cara, rounds: 8)
        alice.setMod(group.id, bobFP, true)
        await settle(alice, bob, cara, rounds: 8)

        let before = try #require(cara.conversation(group.id))
        let bobAtCara = try #require(cara.contact(bobFP, in: nil))
        let bobKey = try #require(alice.contact(bobFP, in: nil)).signingKey
        var forged = alice.info(for: try #require(alice.conversation(group.id)), to: caraFP)
        // A version at the very top, with nothing removed: it would stop every real change from counting.
        forged.version = .max
        cara.joinGroup(forged, from: bobAtCara)
        #expect(cara.conversation(group.id)?.version == before.version)
        // The next version, but nobody taken out.
        forged.version = before.version + 1
        cara.joinGroup(forged, from: bobAtCara)
        #expect(cara.conversation(group.id)?.version == before.version)
        // A mod making himself admin and renaming the group.
        forged.admins = [bobKey]
        forged.title = "Mine now"
        cara.joinGroup(forged, from: bobAtCara)
        #expect(cara.conversation(group.id)?.admins.isEmpty == true && cara.conversation(group.id)?.title == "Crew")

        // The owner's real changes still count after all of that.
        alice.updateDetails(group.id, title: "Crew 2", about: "", avatar: nil)
        await settle(alice, bob, cara, rounds: 8)
        #expect(cara.conversation(group.id)?.title == "Crew 2")

        // An admin can't appoint another admin either: only the owner does.
        alice.setAdmin(group.id, bobFP, true)
        await settle(alice, bob, cara, rounds: 8)
        let caraKey = try #require(alice.contact(caraFP, in: nil)).signingKey
        var appoint = alice.info(for: try #require(alice.conversation(group.id)), to: caraFP)
        appoint.admins = [bobKey, caraKey]
        appoint.version = (cara.conversation(group.id)?.version ?? 0) + 1
        cara.joinGroup(appoint, from: bobAtCara)
        #expect(cara.conversation(group.id)?.admins == [bobFP])
    }

    /// A picture that claims enormous dimensions in a small file isn't opened: it's left out of a group's details.
    @Test func aPictureWithHugeDimensionsIsNotOpened() throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAdTAAAHUwCAAAAABDTKdmAAAy0HRFWHRDb21tZW50AHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHg6hLMQAAAADElEQVR4nGNgoAwAAABAAAG3NHzvAAAAAElFTkSuQmCC"))
        #expect(png.count > 12_000)
        #expect(AppModel.thumbnail(png, side: 96) == nil)
    }

    /// A story says it arrived; one that never did (a relay restart empties what it holds) is sent again, and the
    /// confirmation is what stops it being sent a third time.
    @Test func aStoryThatNeverArrivedIsSentAgainAndConfirmed() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        alice.postStory(.text("lost on the way", palette: 1))
        await settle(alice, bob, rounds: 8)
        let id = try #require(alice.myStories.first).id
        let bobFP = try #require(alice.visibleContacts.first).fingerprint
        #expect(alice.data.stories.first { $0.id == id }?.delivery?.confirmed == [bobFP], "Bob said he has it")

        // Bob's copy goes missing, and Alice hasn't heard from him: it's a few minutes on.
        bob.data.stories.removeAll()
        let i = try #require(alice.data.stories.firstIndex { $0.id == id })
        alice.data.stories[i].delivery = StoryDelivery()
        alice.data.stories[i].date = Date().addingTimeInterval(-300)
        alice.lastResendCheck = .distantPast
        await settle(alice, bob, rounds: 10)
        #expect(bob.friendStories.flatMap(\.stories).map(\.id) == [id], "Sent again")
        #expect(alice.data.stories.first { $0.id == id }?.delivery?.confirmed == [bobFP], "and confirmed again")
        #expect((alice.data.stories.first { $0.id == id }?.delivery?.resends ?? 0) == 1)
    }

    /// Links a second device to `model`'s account through the real relay, like scanning the QR code.
    private func linkNewDevice(to model: AppModel) async throws -> AppModel {
        let code = model.makeLinkCode()
        let linker = DeviceLinker()
        linker.start(code)
        for _ in 0..<20 where model.pendingLink == nil {
            try await Task.sleep(for: .milliseconds(200))
            await model.syncOnce()
        }
        #expect(model.pendingLink?.request.deviceID == linker.deviceID)
        model.approveLink()
        await model.syncOnce()
        for _ in 0..<30 where linker.stage != .received { try await Task.sleep(for: .milliseconds(250)) }
        let bundle = try #require(linker.bundle)
        let device = testModel("pulshade-linked")
        try await device.finishLink(bundle, deviceID: linker.deviceID, selfMailbox: linker.selfMailbox,
                                    relay: linker.relay, passcode: "second-device")
        return device
    }

    @Test func aNewDeviceCanShowTheCodeInstead() async throws {
        let phone = try await makeUser("Phone")
        let bob = try await makeUser("Bob")
        defer { for m in [phone, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: phone.makeInviteCode(), nickname: ""))
        await settle(phone, bob)

        // The new Mac shows a code; the phone scans it and approves.
        let linker = DeviceLinker()
        linker.offer()
        let shown = try #require(linker.joinCode)
        let parsed = try #require(JoinCode(shown))
        #expect(parsed.request.deviceID == linker.deviceID && parsed.request.name == String(deviceDisplayName.prefix(40)))
        #expect(!phone.acceptJoinCode("pshjoin1nonsense") && !phone.acceptJoinCode(phone.makeInviteCode()))
        // The QR holds it as a pulshade:// link, so the Camera app opens Pulshade with it.
        guard case .device = phone.useScannedCode(JoinCode.link(shown)) else {
            Issue.record("The link form wasn't recognised")
            return
        }
        #expect(phone.pendingLink?.request.deviceID == linker.deviceID)
        phone.approveLink()
        await phone.syncOnce()
        for _ in 0..<30 where linker.stage != .received { try await Task.sleep(for: .milliseconds(250)) }
        let bundle = try #require(linker.bundle)

        let mac = testModel("pulshade-joined")
        defer { mac.lock() }
        try await mac.finishLink(bundle, deviceID: linker.deviceID, selfMailbox: linker.selfMailbox,
                                 relay: linker.relay, passcode: "joined-mac")
        #expect(mac.fingerprint == phone.fingerprint)
        await settle(phone, mac, bob, rounds: 8)
        #expect(phone.linkedDevices.count == 1)
        let bobChat = bob.startConversation(kind: .direct, title: "", members: [try #require(bob.visibleContacts.first).fingerprint])
        bob.send("reaches both", in: bobChat.id)
        await settle(phone, mac, bob, rounds: 6)
        #expect(mac.data.conversations.contains { $0.messages.contains { $0.text == "reaches both" } })
    }

    @Test func scanningAFriendsInviteAddsThem() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        guard case .contact = alice.useScannedCode(bob.makeInviteCode()) else {
            Issue.record("The invite wasn't recognised")
            return
        }
        guard case .unknown = alice.useScannedCode("https://example.com/whatever") else {
            Issue.record("A random code was accepted")
            return
        }
        await settle(alice, bob)
        #expect(bob.visibleContacts.contains { $0.name == "Alice" })
    }

    @Test func linkedDevicesShareOneAccount() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)

        // Alice links her phone. It's the same account, and it already knows Bob.
        let phone = try await linkNewDevice(to: alice)
        defer { phone.lock() }
        #expect(phone.fingerprint == alice.fingerprint)
        #expect(phone.visibleContacts.map(\.name) == ["Bob"])
        #expect(alice.linkedDevices.count == 1 && phone.linkedDevices.count == 1)
        await settle(alice, phone, bob, rounds: 8)
        #expect(bob.visibleContacts.first?.devices.count == 2, "Bob now knows both of Alice's devices")

        // Bob's message lands on both of Alice's devices.
        let bobChat = bob.startConversation(kind: .direct, title: "", members: [try #require(bob.visibleContacts.first).fingerprint])
        bob.send("hi alice", in: bobChat.id)
        await settle(alice, phone, bob)
        #expect(alice.data.conversations.first { $0.kind == .direct }?.messages.last?.text == "hi alice")
        #expect(phone.data.conversations.first { $0.kind == .direct }?.messages.last?.text == "hi alice")

        // Sending from the phone reaches Bob as Alice, and shows up on her Mac as hers.
        let phoneChat = try #require(phone.data.conversations.first { $0.kind == .direct })
        phone.send("from my phone", in: phoneChat.id)
        await settle(alice, phone, bob)
        #expect(bob.conversation(bobChat.id)?.messages.last?.text == "from my phone")
        let macCopy = try #require(alice.data.conversations.first { $0.kind == .direct }?.messages.last)
        #expect(macCopy.text == "from my phone" && macCopy.isMine)

        // Reactions made on the Mac show on the phone.
        let bobsMessage = try #require(alice.data.conversations.first { $0.kind == .direct }?.messages.first { $0.text == "hi alice" })
        alice.react("🔥", to: bobsMessage.id, in: try #require(alice.data.conversations.first { $0.kind == .direct }).id)
        await settle(alice, phone)
        #expect(phone.data.conversations.first { $0.kind == .direct }?.messages.first { $0.id == bobsMessage.id }?.reactions["me"] == "🔥")

        // A group made on the Mac appears on the phone, and Bob's group messages reach both.
        let bobFP = try #require(alice.visibleContacts.first).fingerprint
        let group = alice.startConversation(kind: .group, title: "Both devices", members: [bobFP])
        await settle(alice, phone, bob, rounds: 6)
        #expect(phone.conversation(group.id)?.title == "Both devices")
        bob.send("group hello", in: group.id)
        await settle(alice, phone, bob)
        #expect(phone.conversation(group.id)?.messages.last?.text == "group hello")
        #expect(alice.conversation(group.id)?.messages.last?.text == "group hello")

        // A contact added on the phone works from the Mac too.
        _ = try #require(phone.addContact(code: cara.makeInviteCode(), nickname: ""))
        await settle(alice, phone, cara, rounds: 8)
        #expect(alice.visibleContacts.contains { $0.name == "Cara" })
        let caraChat = try #require(cara.data.conversations.first { $0.kind == .direct })
        cara.send("hey both", in: caraChat.id)
        await settle(alice, phone, cara)
        #expect(alice.data.conversations.contains { $0.messages.contains { $0.text == "hey both" } })
        #expect(phone.data.conversations.contains { $0.messages.contains { $0.text == "hey both" } })
    }

    @Test func linkedDevicesShareProfileHandleAndRequests() async throws {
        let mac = try await makeUser("Zeeko")
        let friend = try await makeUser("Friend")
        defer { for m in [mac, friend] { m.lock() } }
        let handle = "zee_\(Int.random(in: 10000...99999))"
        try await mac.publishProfile(handle: handle)

        // The phone arrives with the same handle and reads the same request mailbox.
        let phone = try await linkNewDevice(to: mac)
        defer { phone.lock() }
        await settle(mac, phone, rounds: 6)
        #expect(phone.activeProfile.handle == handle)
        let macInbox = mac.data.invites.first { $0.isPublic }?.receiveKey
        #expect(macInbox != nil && phone.data.invites.first { $0.isPublic }?.receiveKey == macInbox)

        // A new photo, name and colour set on the phone show on the Mac.
        phone.updateProfile {
            $0.avatar = Data([0xFF, 0xD8, 0x01, 0x02])
            $0.name = "Zeeko Z"
            $0.color = 3
        }
        try await Task.sleep(for: .seconds(2))
        await settle(mac, phone)
        #expect(mac.activeProfile.avatar == Data([0xFF, 0xD8, 0x01, 0x02]))
        #expect(mac.activeProfile.name == "Zeeko Z" && mac.activeProfile.color == 3)
        #expect(mac.activeProfile.handle == handle, "The handle survives a profile edit elsewhere")

        // A friend's request shows on both devices, whichever one fetched it.
        let found = try #require(try await friend.findProfile(handle))
        _ = try #require(friend.sendRequest(to: found, note: "it's me"))
        await settle(phone, mac, friend)
        #expect(mac.requests.count == 1 && phone.requests.count == 1)

        // Accepting on the phone clears it on the Mac, and the chat works on both.
        let incoming = try #require(phone.requests.first)
        _ = try #require(phone.acceptRequest(incoming.id))
        await settle(phone, mac, friend, rounds: 10)
        #expect(mac.requests.isEmpty)
        #expect(mac.visibleContacts.map(\.name) == ["Friend"])
        let friendChat = try #require(friend.data.conversations.first { $0.kind == .direct })
        friend.send("hello both", in: friendChat.id)
        await settle(phone, mac, friend)
        #expect(phone.data.conversations.contains { $0.messages.contains { $0.text == "hello both" } })
        #expect(mac.data.conversations.contains { $0.messages.contains { $0.text == "hello both" } })

        // Changing the handle on the phone moves the Mac too, and the old one is let go.
        let newHandle = "zee2_\(Int.random(in: 10000...99999))"
        try await phone.publishProfile(handle: newHandle)
        await settle(mac, phone)
        #expect(mac.activeProfile.handle == newHandle)
        #expect(try await friend.findProfile(handle) == nil)
        await phone.unpublishProfile()
        #expect(try await friend.findProfile(newHandle) == nil, "Tests leave nothing behind in the directory")
    }

    @Test func driftedDevicesSettleOnTheNewestProfile() async throws {
        let mac = try await makeUser("Mac name")
        defer { mac.lock() }
        let phone = try await linkNewDevice(to: mac)
        defer { phone.lock() }
        await settle(mac, phone, rounds: 6)
        // The phone claims its own handle, as an older version of the app allowed.
        try await phone.publishProfile(handle: "drift_\(Int.random(in: 10000...99999))")
        let phoneHandle = try #require(phone.activeProfile.handle)
        await settle(mac, phone)
        #expect(mac.activeProfile.handle == phoneHandle, "The newest change wins on every device")
        mac.updateProfile { $0.bio = "set on the mac" }
        try await Task.sleep(for: .seconds(2))
        await settle(mac, phone)
        #expect(phone.activeProfile.bio == "set on the mac" && phone.activeProfile.handle == phoneHandle)
        await mac.unpublishProfile()
    }

    /// A device on an older version of PULSHADE doesn't know every profile field. It must neither wipe them from a
    /// newer device by sending its own profile back, nor take a profile it can't read in full.
    @Test func anOlderDeviceCantWipeWhatANewerOneHas() async throws {
        let mac = try await makeUser("Mac")
        defer { mac.lock() }
        let phone = try await linkNewDevice(to: mac)
        defer { phone.lock() }
        await settle(mac, phone, rounds: 6)
        phone.profileFormat = AppData.currentFormat - 1

        let link = ProfileLink(kind: .website, value: "https://example.com")
        mac.updateProfile { $0.links = [link]; $0.bio = "from the newer device" }
        try await Task.sleep(for: .seconds(2))
        await settle(mac, phone)
        #expect(phone.profileNeedsUpdate, "it knows a newer profile exists that it can't read")
        #expect(phone.activeProfile.bio != "from the newer device", "and doesn't take it")

        // The older device edits something, which the newer one must not accept over its links.
        phone.updateProfile { $0.bio = "from the older device" }
        try await Task.sleep(for: .seconds(2))
        await settle(mac, phone)
        #expect(mac.activeProfile.links == [link], "the links survive")
        #expect(mac.activeProfile.bio == "from the newer device")

        // Same version on both: edits go both ways, as before.
        phone.profileFormat = AppData.currentFormat
        mac.updateProfile { $0.bio = "settled" }
        try await Task.sleep(for: .seconds(2))
        await settle(mac, phone)
        #expect(phone.activeProfile.bio == "settled" && phone.activeProfile.links == [link])
    }

    @Test func detachingOneDeviceLeavesTheAccountOnTheOthers() async throws {
        let mac = try await makeUser("Mac")
        let bob = try await makeUser("Bob")
        defer { for m in [mac, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: mac.makeInviteCode(), nickname: ""))
        await settle(mac, bob)
        let phone = try await linkNewDevice(to: mac)
        await settle(mac, phone, bob, rounds: 8)
        #expect(bob.visibleContacts.first?.devices.count == 2)

        try await phone.detach(.thisDevice)
        #expect(phone.identity == nil && phone.phase == .welcome)
        await settle(mac, bob)
        #expect(mac.linkedDevices.isEmpty, "The Mac drops the phone from its list")
        #expect(bob.visibleContacts.first?.devices.count == 1, "Bob stops sending to the phone")
        let bobChat = bob.startConversation(kind: .direct, title: "", members: [try #require(bob.visibleContacts.first).fingerprint])
        bob.send("still there?", in: bobChat.id)
        await settle(mac, bob)
        #expect(mac.data.conversations.contains { $0.messages.contains { $0.text == "still there?" } })

        // On its only device, detaching needs the right recovery code.
        let code = mac.recoveryCode
        await #expect(throws: AppModel.LeaveError.self) { try await mac.detach(.thisDevice, recoveryCode: "AAAA BBBB") }
        #expect(mac.identity != nil)
        // Once the phone has gone, the Mac's own entry has no devices left; it must still save and load.
        mac.lock()
        #expect(await mac.unlock(passcode: "test-passcode"))
        #expect(mac.visibleContacts.count == 1, "Nothing is lost on the next unlock")
        #expect(mac.data.conversations.contains { $0.messages.contains { $0.text == "still there?" } })
        try await mac.detach(.thisDevice, recoveryCode: code)
        #expect(mac.identity == nil)
    }

    @Test func burningAnAccountLeavesNoTrace() async throws {
        let zee = try await makeUser("Zee")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [zee, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: zee.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: zee.makeInviteCode(), nickname: ""))
        _ = try #require(bob.addContact(code: cara.makeInviteCode(), nickname: ""))
        await settle(zee, bob, cara, rounds: 8)
        let phone = try await linkNewDevice(to: zee)
        await settle(zee, phone, bob, cara, rounds: 8)

        let zeeFP = zee.fingerprint
        let bobFP = try #require(zee.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(zee.visibleContacts.first { $0.name == "Cara" }).fingerprint
        // A direct chat, a group Zee owns, and Bob's group that Zee talks in.
        let direct = zee.startConversation(kind: .direct, title: "", members: [bobFP])
        zee.send("hi bob", in: direct.id)
        let zeesGroup = zee.startConversation(kind: .group, title: "Zee's", members: [bobFP, caraFP])
        zee.send("my group", in: zeesGroup.id)
        let bobsCara = try #require(bob.visibleContacts.first { $0.name == "Cara" }).fingerprint
        let bobsZee = try #require(bob.visibleContacts.first { $0.name == "Zee" }).fingerprint
        let bobsGroup = bob.startConversation(kind: .group, title: "Bob's", members: [bobsZee, bobsCara])
        await settle(zee, phone, bob, cara, rounds: 8)
        bob.send("bob here", in: bobsGroup.id)
        await settle(zee, bob, cara)
        zee.send("in bob's group", in: bobsGroup.id)
        let bobsMessage = try #require(zee.conversation(bobsGroup.id)?.messages.first { $0.text == "bob here" })
        zee.react("👍", to: bobsMessage.id, in: bobsGroup.id)
        let handle = "erase_\(Int.random(in: 10000...99999))"
        try await zee.publishProfile(handle: handle)
        await settle(zee, phone, bob, cara, rounds: 8)
        #expect(cara.conversation(bobsGroup.id)?.messages.contains { $0.text == "in bob's group" } == true)

        let zeeDir = zee.vault.directory
        try await zee.burn()
        #expect(zee.identity == nil)
        #expect(!FileManager.default.fileExists(atPath: zeeDir.path), "This device keeps nothing")
        #expect(!FileKeys(directory: zeeDir, file: "identity.lock").inUse, "Not even a Keychain item")
        await settle(phone, bob, cara, rounds: 8)

        #expect(phone.identity == nil, "Every linked device wipes itself")
        for friend in [bob, cara] {
            #expect(!friend.data.contacts.contains { $0.fingerprint == zeeFP })
            #expect(friend.conversation(zeesGroup.id) == nil)
            #expect(!friend.data.conversations.contains { $0.kind == .direct && $0.members == [zeeFP] })
            let group = try #require(friend.conversation(bobsGroup.id))
            #expect(!group.messages.contains { $0.sender == zeeFP } && !group.members.contains(zeeFP))
            #expect(group.messages.contains { $0.text == "bob here" || $0.sender == "me" }, "Everyone else's messages stay")
            #expect(group.messages.allSatisfy { $0.reactions[zeeFP] == nil }, "Their reactions go too")
        }
        #expect(try await bob.findProfile(handle) == nil, "The handle is released")
    }

    @Test func yourHandlesShowsTheOnesKeptForYou() async throws {
        let zee = try await makeUser("Zee")
        let cara = try await makeUser("Cara")
        defer { for m in [zee, cara] { m.lock() } }
        let n = Int.random(in: 10000...99999)
        let (first, second) = ("first_\(n)", "second_\(n)")
        try await zee.publishProfile(handle: first)
        try await zee.publishProfile(handle: second)
        #expect(try await zee.heldHandles().map(\.handle) == [first], "the old one is kept, the one in use isn't listed")
        let until = try #require(try await zee.heldHandles().first?.until)
        #expect(until.timeIntervalSinceNow > 89 * 24 * 3600)
        await #expect(throws: AppModel.DirectoryError.held) { try await cara.publishProfile(handle: first) }

        // Using a kept one again swaps the two.
        try await zee.publishProfile(handle: first)
        #expect(zee.activeProfile.handle == first)
        #expect(try await zee.heldHandles().map(\.handle) == [second])

        // Letting go frees the spot at once, but the name cools off before anyone may take it.
        try await zee.letGo(of: second)
        #expect(try await zee.heldHandles().isEmpty)
        await #expect(throws: AppModel.DirectoryError.held) { try await cara.publishProfile(handle: second) }
        await zee.unpublishProfile()
    }

    /// The panic passcode takes the relay's copy of the real account's backup away, with a token that can do nothing
    /// else, and the real account's recovery code then finds nothing.
    @Test func thePanicPasscodeErasesTheRelayBackup() async throws {
        let model = try await makeUser("Real")
        let seed = try #require(model.identity?.seed)
        try await model.setPanic(passcode: "panic-pass-1")
        #expect(await model.saveBackup(), "A backup is on the relay")
        let looker = testModel("pulshade-panic-look")
        defer { looker.lock() }
        guard case .found = await looker.backup(of: try Identity(seed: seed)) else {
            Issue.record("No backup to begin with")
            return
        }
        model.lock()
        #expect(await model.unlock(passcode: "panic-pass-1"), "It looks like an ordinary unlock")
        await model.forgetPendingBackup()
        guard case .none = await looker.backup(of: try Identity(seed: seed)) else {
            Issue.record("The real account's backup is still on the relay")
            return
        }
        #expect(model.data.pendingBackupForget == nil)
        model.lock()
    }

    @Test func detachingTheOnlyDeviceKeepsEverythingButChats() async throws {
        let zee = try await makeUser("Zee")
        let bob = try await makeUser("Bob")
        let cara = try await makeUser("Cara")
        defer { for m in [zee, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: zee.makeInviteCode(), nickname: ""))
        await settle(zee, bob)
        zee.updateProfile { $0.avatar = Data([0xFF, 0xD8, 0x09]); $0.bio = "still me" }
        let handle = "stay_\(Int.random(in: 10000...99999))"
        try await zee.publishProfile(handle: handle)
        let bobFP = try #require(zee.visibleContacts.first).fingerprint
        let chat = zee.startConversation(kind: .direct, title: "", members: [bobFP])
        zee.send("before detaching", in: chat.id)
        let group = zee.startConversation(kind: .group, title: "Still in it", members: [bobFP])
        zee.send("group words", in: group.id)
        await settle(zee, bob)
        let seed = try #require(zee.identity?.seed)

        try await zee.detach(.thisDevice, recoveryCode: zee.recoveryCode)
        #expect(zee.identity == nil && zee.phase == .welcome)
        // Bob writes while Zee is logged out.
        let bobsChat = try #require(bob.data.conversations.first { $0.kind == .direct })
        bob.send("while you were gone", in: bobsChat.id)
        await settle(bob)

        let restored = testModel("pulshade-backup-restore")
        defer { restored.lock() }
        let identity = try Identity(seed: seed)
        guard case let .found(backup) = await restored.backup(of: identity) else {
            Issue.record("Detaching left no backup")
            return
        }
        // Someone else's recovery code finds nothing.
        guard case .none = await restored.backup(of: try #require(cara.identity)) else {
            Issue.record("Found a backup for the wrong account")
            return
        }
        try await restored.restore(seed: seed, passcode: "new-device", from: backup)
        #expect(restored.activeProfile.avatar == Data([0xFF, 0xD8, 0x09]) && restored.activeProfile.bio == "still me")
        #expect(restored.activeProfile.handle == handle)
        #expect(restored.visibleContacts.map(\.fingerprint) == [bobFP])
        #expect(backup.conversations.allSatisfy { $0.kind != .direct && $0.messages.isEmpty }, "No chat comes back")
        #expect(restored.conversation(chat.id) == nil)
        #expect(restored.conversation(group.id)?.title == "Still in it", "Groups you're in stay")
        await settle(restored, bob)
        // What Bob wrote meanwhile still arrives, in a fresh chat.
        let fresh = try #require(restored.data.conversations.first { $0.kind == .direct && $0.members == [bobFP] })
        #expect(fresh.messages.map(\.text) == ["while you were gone"])
        restored.send("back again", in: fresh.id)
        await settle(restored, bob)
        #expect(bob.conversation(bobsChat.id)?.messages.contains { $0.text == "back again" } == true)
        try await Task.sleep(for: .milliseconds(500))
        // The copy stays, and is saved over as things change.
        guard case .found = await restored.backup(of: identity) else {
            Issue.record("The backup was erased after restoring, with backups on")
            return
        }

        // Burning retires the handle: unlisted, and nobody can take it up for three months.
        try await restored.burn()
        await settle(bob)
        #expect(!bob.data.contacts.contains { $0.fingerprint == identity.fingerprint })
        #expect(try await cara.findProfile(handle) == nil)
        await #expect(throws: AppModel.DirectoryError.held) { try await cara.publishProfile(handle: handle) }
        #expect(cara.activeProfile.handle == nil)
    }

    @Test func theBackupIsKeptFreshSoDetachingNeedsNoNetwork() async throws {
        let zee = try await makeUser("Zee")
        let bob = try await makeUser("Bob")
        defer { for m in [zee, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: zee.makeInviteCode(), nickname: ""))
        await settle(zee, bob)
        let bobFP = try #require(zee.visibleContacts.first).fingerprint
        let chat = zee.startConversation(kind: .direct, title: "", members: [bobFP])
        zee.send("never in a backup", in: chat.id)
        // Delivered and receipted first, so nothing about the account changes between the two saves below.
        await settle(zee, bob)
        let seed = try #require(zee.identity?.seed)
        let identity = try Identity(seed: seed)

        #expect(zee.data.backupSavedAt == nil)
        #expect(await zee.saveBackup())
        #expect(zee.data.backupSavedAt != nil && zee.data.backupDigest != nil)
        // Unchanged, so nothing new is sent: the time stays.
        let first = zee.data.backupSavedAt
        #expect(await zee.saveBackup())
        #expect(zee.data.backupSavedAt == first)

        // Detach is the instant wipe: no recovery code, nothing sent. The contacts come back from the relay.
        zee.destroyEverything()
        #expect(zee.identity == nil && zee.phase == .welcome)
        let restored = testModel("pulshade-instant-detach")
        defer { restored.lock() }
        guard case let .found(backup) = await restored.backup(of: identity) else {
            Issue.record("Detaching left nothing to restore")
            return
        }
        #expect(backup.conversations.allSatisfy { $0.kind != .direct && $0.messages.isEmpty }, "No chat comes back")
        try await restored.restore(seed: seed, passcode: "new-device", from: backup)
        #expect(restored.visibleContacts.map(\.fingerprint) == [bobFP])

        // Switching it off erases the copy from the relay; burning does too.
        restored.setKeepBackup(false)
        try await Task.sleep(for: .milliseconds(500))
        guard case .none = await restored.backup(of: identity) else {
            Issue.record("Switching backups off left the copy on the relay")
            return
        }
        #expect(!(await restored.saveBackup()), "off means no upload")
    }

    @Test func aBackupIsPaddedAndOldOnesStillOpen() throws {
        let small = AppModel.padded(Data(repeating: 7, count: 100))
        #expect(small.count == 64 * 1024)
        #expect(AppModel.unpadded(small) == Data(repeating: 7, count: 100))
        let big = AppModel.padded(Data(repeating: 9, count: 70_000))
        #expect(big.count == 128 * 1024)
        #expect(AppModel.unpadded(big).count == 70_000)
        // A backup left by an older build is plain JSON.
        let legacy = Data(#"{"format":4}"#.utf8)
        #expect(AppModel.unpadded(legacy) == legacy)
    }

    @Test func detachingEveryDeviceWipesThemAllAndKeepsTheAccount() async throws {
        let mac = try await makeUser("Mac")
        let bob = try await makeUser("Bob")
        defer { for m in [mac, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: mac.makeInviteCode(), nickname: ""))
        await settle(mac, bob)
        let phone = try await linkNewDevice(to: mac)
        await settle(mac, phone, bob, rounds: 8)
        let seed = try #require(mac.identity?.seed)
        await #expect(throws: AppModel.LeaveError.self) { try await mac.detach(.everyDevice) }
        try await mac.detach(.everyDevice, recoveryCode: mac.recoveryCode)
        #expect(mac.identity == nil)
        await settle(phone, bob, rounds: 8)
        // The phone says goodbye to its contacts before wiping, which takes a moment.
        for _ in 0..<40 where phone.identity != nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(phone.identity == nil, "The phone wipes itself too")
        #expect(bob.visibleContacts.first?.devices.count == 1, "Bob stops sending to the phone")

        let restored = testModel("pulshade-detach-all")
        defer { restored.lock() }
        guard case let .found(backup) = await restored.backup(of: try Identity(seed: seed)) else {
            Issue.record("Detaching every device left no backup")
            return
        }
        #expect(backup.contacts.first { $0.isSelf }?.devices.isEmpty != false, "The wiped devices aren't brought back")
        try await restored.restore(seed: seed, passcode: "again", from: backup)
        #expect(restored.visibleContacts.count == 1)
        try await restored.burn()
    }

    @Test func theLockScreenBurnsOrDetachesWithTheRecoveryCode() async throws {
        let zee = try await makeUser("Zee")
        let bob = try await makeUser("Bob")
        defer { for m in [zee, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: zee.makeInviteCode(), nickname: ""))
        await settle(zee, bob)
        let code = zee.recoveryCode
        let seed = try #require(zee.identity?.seed)
        zee.lock()

        await #expect(throws: AppModel.LeaveError.self) {
            try await zee.leaveFromLock(burning: true, recoveryCode: bob.recoveryCode)
        }
        #expect(zee.identity == nil && zee.phase == .locked, "Someone else's code opens nothing, and it stays locked")

        try await zee.leaveFromLock(burning: false, recoveryCode: code)
        #expect(zee.phase == .welcome)
        guard case .found = await bob.backup(of: try Identity(seed: seed)) else {
            Issue.record("Detaching from the lock screen left no backup")
            return
        }

        // The same from a second account, burned this time.
        let cara = try await makeUser("Cara")
        _ = try #require(bob.addContact(code: cara.makeInviteCode(), nickname: ""))
        await settle(cara, bob)
        let caraFP = cara.fingerprint
        let caraCode = cara.recoveryCode
        cara.lock()
        try await cara.leaveFromLock(burning: true, recoveryCode: caraCode)
        #expect(cara.phase == .welcome)
        await settle(bob)
        #expect(!bob.data.contacts.contains { $0.fingerprint == caraFP })
    }

    @Test func restoringBringsBackThePublicProfile() async throws {
        let original = try await makeUser("Zeeko")
        let friend = try await makeUser("Friend")
        defer { for m in [original, friend] { m.lock() } }
        original.updateProfile {
            $0.avatar = Data([0xFF, 0xD8, 0x07])
            $0.bio = "creator"
            $0.color = 4
        }
        let keep = "keep_\(Int.random(in: 10000...99999))"
        try await original.publishProfile(handle: keep)
        let seed = try #require(original.identity?.seed)

        // A second handle left over from an earlier version, which let each device claim its own.
        let extra = "extra_\(Int.random(in: 10000...99999))"
        try await Task.sleep(for: .milliseconds(5))
        try await #require(original.client(nil)).claim(extra, original.signedEntry(handle: extra, persona: nil))
        original.lock()

        // A fresh device restores from the recovery code and finds both, newest first.
        let restored = testModel("pulshade-restore")
        defer { restored.lock() }
        let found = await restored.publicProfiles(of: try Identity(seed: seed))
        #expect(found.map(\.handle) == [extra, keep])
        // Nobody else can ask on its behalf.
        #expect(await friend.publicProfiles(of: try #require(friend.identity)).isEmpty)

        try await restored.restore(seed: seed, passcode: "new-device")
        let kept = try #require(found.first { $0.handle == keep })
        await restored.adoptRestoredProfile(kept, releasing: found)
        #expect(restored.activeProfile.handle == keep && restored.activeProfile.name == "Zeeko")
        #expect(restored.activeProfile.avatar == Data([0xFF, 0xD8, 0x07]) && restored.activeProfile.bio == "creator")
        #expect(restored.activeProfile.color == 4)
        #expect(try await friend.findProfile(extra) == nil, "The other handle is released")

        // Requests to the kept handle reach the restored device.
        let listed = try #require(try await friend.findProfile(keep))
        _ = try #require(friend.sendRequest(to: listed, note: "found you"))
        await settle(restored, friend)
        #expect(restored.requests.first?.note == "found you")
        await restored.unpublishProfile()
    }

    @Test func linkingCarriesOverHistory() async throws {
        let mac = try await makeUser("Mac")
        let bob = try await makeUser("Bob")
        defer { for m in [mac, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: mac.makeInviteCode(), nickname: ""))
        await settle(mac, bob)
        let bobFP = try #require(mac.visibleContacts.first).fingerprint

        // Months of history, before the phone exists.
        let direct = mac.startConversation(kind: .direct, title: "", members: [bobFP])
        mac.send("first", in: direct.id)
        mac.send("a photo", image: Data(repeating: 0xAB, count: 400_000), in: direct.id)
        await settle(mac, bob)
        let bobsChat = try #require(bob.data.conversations.first { $0.kind == .direct })
        bob.send("reply from bob", in: bobsChat.id)
        await settle(mac, bob)
        let first = try #require(mac.conversation(direct.id)?.messages.first { $0.text == "first" })
        mac.react("🔥", to: first.id, in: direct.id)
        mac.send("quoting", replyTo: first, in: direct.id)
        for i in 0..<5 { mac.send("bulk \(i)", image: Data(repeating: UInt8(i), count: 300_000), in: direct.id) }
        let group = mac.startConversation(kind: .group, title: "Old group", members: [bobFP])
        mac.send("group history", in: group.id)
        mac.togglePin(group.id)
        mac.toggleMute(direct.id)
        mac.postStory(.text("still live", palette: 1))
        await settle(mac, bob)

        let phone = try await linkNewDevice(to: mac)
        defer { phone.lock() }
        await settle(mac, phone, bob, rounds: 10)

        let macMessages = try #require(mac.conversation(direct.id)?.messages)
        let phoneMessages = try #require(phone.conversation(direct.id)?.messages)
        #expect(phoneMessages.map(\.id) == macMessages.map(\.id), "Every message, in order")
        #expect(phoneMessages.first { $0.text == "a photo" }?.image?.count == 400_000)
        #expect(phoneMessages.first { $0.text == "reply from bob" }?.isMine == false)
        #expect(phoneMessages.first { $0.text == "first" }?.reactions["me"] == "🔥")
        #expect(phoneMessages.first { $0.text == "quoting" }?.reply?.id == first.id)
        #expect(phone.conversation(group.id)?.messages.last?.text == "group history")
        #expect(phone.conversation(group.id)?.pinned == true && phone.conversation(direct.id)?.muted == true)
        #expect(phone.myStories.count == 1)
        #expect(phone.unreadTotal == 0, "Old messages don't count as new")
    }

    @Test func oneHandlePerAccount() async throws {
        let me = try await makeUser("Me")
        let friend = try await makeUser("Friend")
        defer { for m in [me, friend] { m.lock() } }
        let first = "one_\(Int.random(in: 10000...99999))"
        let second = "two_\(Int.random(in: 10000...99999))"
        try await me.publishProfile(handle: first)
        try await me.publishProfile(handle: second)
        #expect(try await friend.findProfile(first) == nil, "Claiming a new handle lets go of the old one")

        // A leftover from an older version that's newer than the current handle stays: this device might be the
        // out-of-date one.
        let client = try #require(me.client(nil))
        let leftover = "old_\(Int.random(in: 10000...99999))"
        try await client.claim(leftover, me.signedEntry(handle: leftover, persona: nil))
        await me.releaseLeftoverHandles()
        #expect(try await friend.findProfile(leftover) != nil, "Not when the current handle isn't the newest")

        // Once the current handle is the newest, unlocking clears the leftover.
        try await Task.sleep(for: .milliseconds(5))
        try await client.claim(second, me.signedEntry(handle: second, persona: nil))
        await me.releaseLeftoverHandles()
        #expect(try await friend.findProfile(leftover) == nil)
        #expect(try await friend.findProfile(second) != nil)

        // Going private lets go of every handle.
        try await #require(me.client(nil)).claim(leftover, me.signedEntry(handle: leftover, persona: nil))
        await me.unpublishProfile()
        #expect(try await friend.findProfile(second) == nil)
        #expect(try await friend.findProfile(leftover) == nil)
    }

    /// An operator action with the throwaway relay's admin token, as `pulshade-server` sends it for the admin app.
    private func operate(_ action: String, _ arg: String = "", token: String? = nil) async throws -> (status: Int, body: Any?) {
        let env = ProcessInfo.processInfo.environment
        let dir = try #require(env["PULSHADE_TEST_DIR"]), base = try #require(env["PULSHADE_TEST_RELAY"])
        var request = URLRequest(url: try #require(URL(string: base + "/v1/admin")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let real = try String(contentsOfFile: dir + "/admin.token", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue(token ?? real, forHTTPHeaderField: "x-pulshade-admin-token")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "arg": arg])
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
    }

    /// What's waiting in a mailbox on the throwaway relay.
    private func waiting(in receiveKey: Data) async throws -> [Data] {
        struct Item: Decodable { var blob: String }
        struct Response: Decodable { var items: [Item] }
        let base = try #require(ProcessInfo.processInfo.environment["PULSHADE_TEST_RELAY"])
        var request = URLRequest(url: try #require(URL(string: base + "/v1/fetch")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["keys": [receiveKey.hex], "wait": 0])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Response.self, from: data).items.compactMap { Data(base64Encoded: $0.blob) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_TEST_RELAY"] != nil))
    func reportsAndModeration() async throws {
        let bob = try await makeUser("Bob")
        let carol = try await makeUser("Carol")
        defer { for m in [bob, carol] { m.lock() } }
        // The admin app's keys, and the app built to trust them.
        let admin = Curve25519.Signing.PrivateKey(), reportsKey = Curve25519.KeyAgreement.PrivateKey(), mailbox = Mailbox.make()
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = nil }

        // No app account can run operator actions: only the admin token works.
        #expect(try await operate("stats", token: "a guess").status == 401)
        let spam = "spam_\(Int.random(in: 10000...99999))"
        try await bob.publishProfile(handle: spam)
        let listed = try #require(try await carol.findProfile(spam))

        // Until the admin app publishes its mailbox, or if someone else signs one, nothing is sent.
        var forged = ReportInbox(sendID: mailbox.sendID.base64EncodedString(), agreementKey: reportsKey.publicKey.rawRepresentation.base64EncodedString(),
                                 signingKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
        forged.sig = "bad"
        #expect(try await operate("set-report-inbox", String(decoding: try JSONEncoder().encode(forged), as: UTF8.self)).status == 200)
        await #expect(throws: AppModel.ReportError.self) {
            try await carol.report(subjectKey: listed.signingKey, handle: spam, name: listed.name, reason: "Spam or scams", details: "")
        }
        var inbox = ReportInbox(sendID: mailbox.sendID.base64EncodedString(), agreementKey: reportsKey.publicKey.rawRepresentation.base64EncodedString(),
                                signingKey: admin.publicKey.rawRepresentation.base64EncodedString())
        inbox.sig = try admin.signature(for: ReportInbox.signedPart(inbox)).base64EncodedString()
        #expect(try await operate("set-report-inbox", String(decoding: try JSONEncoder().encode(inbox), as: UTF8.self)).status == 200)

        // Carol reports Bob; only the admin app's key opens it, and it doesn't say it's from Carol.
        try await carol.report(subjectKey: listed.signingKey, handle: spam, name: listed.name,
                               reason: "Spam or scams", details: "sends links to everyone")
        let sealed = try await waiting(in: mailbox.receiveKey)
        #expect(sealed.count == 1)
        let card = try ReportSeal.open(try #require(sealed.first), with: reportsKey)
        #expect(card.reporterHandle == nil && card.subjectHandle == spam && card.subjectKey == listed.signingKey)
        #expect(card.details == "sends links to everyone")
        #expect(throws: (any Error).self) { try ReportSeal.open(sealed[0], with: Curve25519.KeyAgreement.PrivateKey()) }
        let stats = try #require(try await operate("stats").body as? [String: Any])
        #expect((stats["handles"] as? Int ?? 0) >= 1 && stats["reportsSetUp"] as? Bool == true)

        // A banned handle is gone for good, even for its old owner.
        _ = try await operate("ban-handle", spam)
        #expect(try await carol.findProfile(spam) == nil)
        await #expect(throws: AppModel.DirectoryError.self) { try await bob.publishProfile(handle: spam) }

        // A banned account can't list itself under any name until it's unbanned.
        let other = "other_\(Int.random(in: 10000...99999))"
        try await bob.publishProfile(handle: other)
        _ = try await operate("ban-account", other)
        #expect(try await carol.findProfile(other) == nil)
        await #expect(throws: AppModel.DirectoryError.self) { try await bob.publishProfile(handle: "fresh_\(Int.random(in: 10000...99999))") }
        _ = try await operate("unban-account", bob.publicKey)
        try await bob.publishProfile(handle: other)
        #expect(try await carol.findProfile(other) != nil)

        // Service names belong to the creator.
        await #expect(throws: AppModel.DirectoryError.self) { try await bob.publishProfile(handle: "abuse") }
        _ = try await operate("unban-handle", spam)

        // Collectibles: signed by the admin key, numbered, and only the owner can wear one.
        let bobKey = try #require(bob.me(nil)).card.signing
        let given = try #require(try await operate("collectibles").body as? [String: Any])
        let next = UInt32((given["partyhat"] as? Int) ?? 0) + 1
        let first = try Collectible.make(.partyHat, serial: next, owner: bobKey, signedBy: admin)
        #expect(try await operate("give-collectible", String(decoding: try JSONEncoder().encode(first), as: UTF8.self)).status == 200)
        #expect(try await operate("give-collectible", String(decoding: try JSONEncoder().encode(first), as: UTF8.self)).status == 400, "a number is never reused")
        try await bob.refreshCollectibles()
        #expect(bob.activeProfile.collectibles?.contains(first) == true)
        #expect(first.isGenuine(for: bobKey))
        #expect(!first.isGenuine(for: try #require(carol.me(nil)).card.signing), "worn by someone else, it doesn't check out")
        let homemade = try Collectible.make(.partyHat, serial: 999, owner: bobKey, signedBy: .init())
        #expect(!homemade.isGenuine(for: bobKey), "only the admin key makes them")
        try await carol.refreshCollectibles()
        #expect(carol.activeProfile.collectibles?.isEmpty == true)
        bob.wear(first)
        #expect(bob.activeProfile.badge == first)

        // Taken back, it's gone from the owner's app, and stops showing after their name.
        #expect(try await operate("take-collectible", "partyhat \(first.serial)").status == 200)
        try await bob.refreshCollectibles()
        #expect(bob.activeProfile.collectibles?.contains(first) == false && bob.activeProfile.badge == nil)
    }

    /// A giveaway: the operator opens one with a code (only its hash reaches the relay), the first people to enter it
    /// get a place in line, the admin app signs each in order, and it shows up in their app as a genuine collectible.
    @Test func aGiveawayGivesEachCollectibleToTheFirstPeopleToEnterTheCode() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        let previous = AppModel.adminKey
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = previous }
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        let carol = try await makeUser("Carol")
        defer { for m in [alice, bob, carol] { m.lock() } }
        let id = "bonfire-\(UUID().uuidString.prefix(8).lowercased())"
        let now = Int(Date().timeIntervalSince1970)
        let code = "Remember Remember"
        let giveaway: [String: Any] = ["id": id, "item": "bonfire", "hash": Collectible.codeHash(code).base64EncodedString(),
                                       "opens": now - 60, "closes": now + 3600, "max": 2]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: giveaway), as: UTF8.self)
        #expect(try await operate("add-giveaway", json).status == 200)
        #expect(try await operate("add-giveaway", json).status == 400, "the name is taken")
        #expect(!json.contains(code), "only a hash is ever sent")

        // Typed loosely, in order, and a third finds it full.
        let first = try await alice.enterCollectibleCode("remember, remember!")
        guard case let .giveaway(item, place) = first else { Issue.record("expected a giveaway"); return }
        #expect(item == "bonfire" && place == 1)
        guard case let .giveaway(_, again) = try await alice.enterCollectibleCode(code) else { Issue.record("expected a giveaway"); return }
        #expect(again == 1, "entering it twice only says its place")
        guard case let .giveaway(_, second) = try await bob.enterCollectibleCode(code) else { Issue.record("expected a giveaway"); return }
        #expect(second == 2)
        await #expect(throws: RelayClient.GiveawayError.self) { _ = try await carol.enterCollectibleCode(code) }
        await #expect(throws: (any Error).self) { _ = try await carol.enterCollectibleCode("not the code") }

        // The admin app signs them in the order they entered.
        let waiting = try #require(try await operate("giveaways-waiting").body as? [[String: Any]]).filter { $0["giveaway"] as? String == id }
        #expect(waiting.count == 2)
        var owners: [String: Collectible] = [:]
        for row in waiting {
            let key = try #require((row["key"] as? String).flatMap { Data(base64Encoded: $0) })
            let counts = try #require(try await operate("collectibles").body as? [String: Any])
            let serial = UInt32((counts["bonfire"] as? Int) ?? 0) + 1
            let made = try Collectible.make(.bonfire, serial: serial, owner: key, signedBy: admin)
            let grant = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(made))
            let body = String(decoding: try JSONSerialization.data(withJSONObject: ["giveaway": id, "grant": grant]), as: UTF8.self)
            #expect(try await operate("give-giveaway", body).status == 200)
            owners[key.base64EncodedString()] = made
        }
        let aliceKey = try #require(alice.me(nil)).card.signing, bobKey = try #require(bob.me(nil)).card.signing
        #expect(owners[aliceKey.base64EncodedString()]!.serial < owners[bobKey.base64EncodedString()]!.serial, "first in, lowest number")
        #expect(try await operate("giveaways-waiting").status == 200)

        try await alice.refreshCollectibles()
        let mine = try #require(alice.activeProfile.collectibles?.first { $0.item == "bonfire" })
        #expect(mine.isGenuine(for: aliceKey) && mine.kind == .bonfire)
        try await carol.refreshCollectibles()
        #expect(carol.activeProfile.collectibles?.contains { $0.item == "bonfire" } != true)
    }

    /// One backup code covers every collectible an account has, new ones included, and brings them all back to a new
    /// account after the old one burns, with the same numbers, once the admin app signs them over. A code works once,
    /// and only for the account that signs the claim.
    @Test func oneBackupCodeBringsEveryCollectibleBackAfterABurn() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        let previous = AppModel.adminKey
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = previous }
        let old = try await makeUser("Old")
        let reborn = try await makeUser("Reborn")
        let thief = try await makeUser("Thief")
        defer { for m in [reborn, thief] { m.lock() } }
        let oldKey = try #require(old.me(nil)).card.signing
        func give(_ kind: Collectible.Kind, to owner: Data) async throws -> Collectible {
            let given = try #require(try await operate("collectibles").body as? [String: Any])
            let item = try Collectible.make(kind, serial: UInt32((given[kind.rawValue] as? Int) ?? 0) + 1, owner: owner, signedBy: admin)
            #expect(try await operate("give-collectible", String(decoding: try JSONEncoder().encode(item), as: UTF8.self)).status == 200)
            return item
        }

        let hat = try await give(.topHat, to: oldKey)
        let can = try await give(.pulsePop, to: oldKey)
        try await old.refreshCollectibles()
        let first = try #require(old.codeAlert)
        #expect(first.newCode && Set(first.items) == [hat, can], "one new code, covering both")
        let code = try #require(old.collectionCode)
        #expect(Collectible.normalisedCode(code).count == 16)
        old.codeAlert = nil
        try await old.refreshCollectibles()
        #expect(old.codeAlert == nil, "asked once")

        // A later one joins the same code: nothing new to write down.
        let pumpkin = try await give(.pumpkin, to: oldKey)
        try await old.refreshCollectibles()
        let later = try #require(old.codeAlert)
        #expect(!later.newCode && later.items == [pumpkin] && old.collectionCode == code)

        try await old.burn()
        let claimed = try await reborn.claimCollectibles(code: code.lowercased().replacingOccurrences(of: "-", with: " "))
        #expect(Set(claimed.map { "\($0.item)#\($0.serial)" }) == Set([hat, can, pumpkin].map(\.id)), "all of them, with one code")
        await #expect(throws: RelayClient.ClaimError.self) { try await thief.claimCollectibles(code: code) }

        // The admin app signs each over to the account that claimed them.
        let rebornKey = try #require(reborn.me(nil)).card.signing
        let claims = try #require(try await operate("claims").body as? [[String: Any]])
        var moved: [Collectible] = []
        for item in [hat, can, pumpkin] {
            let waiting = try #require(claims.first { $0["item"] as? String == item.item && $0["serial"] as? Int == Int(item.serial) })
            #expect(waiting["to"] as? String == rebornKey.base64EncodedString())
            let signed = try Collectible.make(try #require(item.kind), serial: item.serial, owner: rebornKey, signedBy: admin)
            #expect(try await operate("reissue", String(decoding: try JSONEncoder().encode(signed), as: UTF8.self)).status == 200)
            moved.append(signed)
        }

        try await reborn.refreshCollectibles()
        #expect(Set(reborn.activeProfile.collectibles ?? []) == Set(moved), "same items, same numbers")
        #expect(reborn.codeAlert?.newCode == true && reborn.collectionCode != code, "with a fresh code of its own")
        try await thief.refreshCollectibles()
        #expect(thief.activeProfile.collectibles?.isEmpty == true)

        // A new code replaces the old one for all of them.
        let replaced = try await reborn.makeNewCollectionCode()
        let rebornCode = try #require(reborn.collectionCode)
        #expect(replaced == rebornCode)
    }

    /// Resetting takes every collectible back from everyone, takes the worn one off their name, and the next one given
    /// of each is #1 again.
    @Test func resettingCollectiblesClearsEveryoneAndStartsAtOne() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        let previous = AppModel.adminKey
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = previous }
        let ann = try await makeUser("Ann")
        defer { ann.lock() }
        let key = try #require(ann.me(nil)).card.signing
        let given = try #require(try await operate("collectibles").body as? [String: Any])
        let hat = try Collectible.make(.partyHat, serial: UInt32((given["partyhat"] as? Int) ?? 0) + 1, owner: key, signedBy: admin)
        #expect(try await operate("give-collectible", String(decoding: try JSONEncoder().encode(hat), as: UTF8.self)).status == 200)
        try await ann.refreshCollectibles()
        ann.wear(hat)
        #expect(ann.activeProfile.badge == hat)

        #expect(try await operate("reset-collectibles", "").status == 400, "only when spelled out")
        #expect(try await operate("reset-collectibles", "everyone").status == 200)
        try await ann.refreshCollectibles()
        #expect(ann.activeProfile.collectibles?.isEmpty == true && ann.activeProfile.badge == nil)
        #expect((try await operate("collectibles").body as? [String: Any])?.isEmpty == true)
        let fresh = try Collectible.make(.partyHat, serial: 1, owner: key, signedBy: admin)
        #expect(try await operate("give-collectible", String(decoding: try JSONEncoder().encode(fresh), as: UTF8.self)).status == 200, "#1 again")
    }

    /// The operator can change how many of a collectible there can be. The relay holds to it, never lets it drop below
    /// what's been given out, and tells the app the size of the run so the last number can be marked.
    @Test func theOperatorCanChangeHowManyOfACollectibleThereAre() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        let previous = AppModel.adminKey
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = previous }
        let ann = try await makeUser("Ann")
        defer { ann.lock() }
        let key = try #require(ann.me(nil)).card.signing
        func give(_ serial: UInt32) async throws -> Int {
            let item = try Collectible.make(.pulze, serial: serial, owner: key, signedBy: admin)
            return try await operate("give-collectible", String(decoding: try JSONEncoder().encode(item), as: UTF8.self)).status
        }
        let before = try #require(try await operate("collectibles").body as? [String: Any])
        let start = UInt32((before["greendragon"] as? Int) ?? 0)

        #expect(try await operate("set-collectible-limit", "greendragon \(start + 2)").status == 200)
        let listed = try #require(try await operate("collectible-limits").body as? [String: Any])
        #expect((listed["limits"] as? [String: Any])?["greendragon"] as? Int == Int(start) + 2 && listed["default"] as? Int == 100)
        #expect(try await give(start + 1) == 200)
        #expect(try await give(start + 2) == 200)
        #expect(try await give(start + 3) == 400, "only as many as were set")
        #expect(try await operate("set-collectible-limit", "greendragon \(start + 1)").status == 400, "not below what's given")
        #expect(try await operate("set-collectible-limit", "greendragon 0").status == 400)
        #expect(try await operate("set-collectible-limit", "greendragon abc").status == 400)

        try await ann.refreshCollectibles()
        let mine = try #require(ann.activeProfile.collectibles?.filter { $0.kind == .pulze }.sorted { $0.serial < $1.serial })
        #expect(mine.last?.edition == start + 2 && mine.last?.serial == start + 2, "the app is told how big the run is")
        if start + 2 > 25 { #expect(mine.last?.rarity == .last && mine.first?.rarity == .common) }

        // More: room for the next one, and nobody's number moves.
        #expect(try await operate("set-collectible-limit", "greendragon \(start + 5)").status == 200)
        #expect(try await give(start + 3) == 200)
        #expect(try await operate("set-collectible-limit", "greendragon 100").status == 200, "back to the usual")
        let after = try #require(try await operate("collectible-limits").body as? [String: Any])
        #expect((after["limits"] as? [String: Any])?.isEmpty == true)
    }

    /// Burning one persona deletes it for its contacts and from your devices, while the main identity's contact with the
    /// same person carries on. (Its handles are retired the way Burn retires them; the relay's own tests cover that.)
    @Test func burningOnePersonaLeavesTheRestAlone() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        let persona = try #require(alice.createPersona(name: "Mask"))
        alice.switchPersona(persona.id)
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        #expect(bob.data.contacts.filter { !$0.isSelf && !$0.hidden }.count == 2, "Bob knows Alice and Mask")

        try await alice.burnPersona(persona.id)
        await settle(alice, bob)
        #expect(!alice.data.personas.contains { $0.id == persona.id } && alice.activePersona == nil)
        #expect(!alice.data.contacts.contains { $0.persona == persona.id })
        #expect(bob.data.contacts.filter { !$0.isSelf && !$0.hidden }.map(\.name) == ["Alice"], "Bob forgets only Mask")
        #expect(alice.visibleContacts.map(\.name) == ["Bob"], "the main identity keeps its contact")
    }

    @Test func personasStopAtTheLimit() async throws {
        let me = try await makeUser("Me")
        defer { me.lock() }
        for n in 1...AppModel.personaLimit { #expect(me.createPersona(name: "P\(n)") != nil) }
        #expect(me.createPersona(name: "One too many") == nil && !me.canAddPersona)
        _ = me.createBurner(lasting: 3600)
        #expect(me.personas.count == AppModel.personaLimit, "Burners don't count")
        me.deletePersona(me.personas[0].id)
        #expect(me.canAddPersona, "Burning one frees a place")
    }

    @Test func personasDontShareADeviceID() async throws {
        let me = try await makeUser("Me")
        defer { me.lock() }
        let persona = try #require(me.createPersona(name: "Other"))
        #expect(me.deviceID(for: nil) != me.deviceID(for: persona.id))
        #expect(me.deviceID(for: persona.id) == me.deviceID(for: persona.id), "Stable for each persona")
        let burner = me.createBurner(lasting: 3600)
        #expect(Set([me.deviceID(for: nil), me.deviceID(for: persona.id), me.deviceID(for: burner)]).count == 3)
    }

    @Test func aReplayedSetupMessageIsIgnored() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        let bobFP = try #require(alice.visibleContacts.first).fingerprint
        // An erase sent once and recorded by the relay...
        let blob = try Envelope.seal(.erased, from: try #require(bob.me(nil)), to: try #require(alice.me(nil)).card.agreement)
        let mailbox = try #require(alice.contact(bobFP)?.receiveKey)
        let client = try #require(alice.client(nil))
        try await client.deposit(blob, to: Mailbox.sendID(for: mailbox))
        await alice.syncOnce()
        #expect(alice.contact(bobFP) == nil, "The real one counts")
        // ...and played again after Bob is added back does nothing.
        _ = try #require(alice.addContact(code: bob.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        let again = try #require(alice.contact(bobFP)?.receiveKey)
        try await client.deposit(blob, to: Mailbox.sendID(for: again))
        await alice.syncOnce()
        #expect(alice.contact(bobFP) != nil)
    }

    @Test func onlyTheFirstDeviceToAnswerALinkCodeCounts() async throws {
        let phone = try await makeUser("Phone")
        defer { phone.lock() }
        let code = phone.makeLinkCode()
        let real = DeviceLinker(), intruder = DeviceLinker()
        real.start(code)
        for _ in 0..<20 where phone.pendingLink == nil {
            try await Task.sleep(for: .milliseconds(200))
            await phone.syncOnce()
        }
        intruder.start(code)
        try await Task.sleep(for: .milliseconds(400))
        await phone.syncOnce()
        #expect(phone.pendingLink?.request.deviceID == real.deviceID)
        #expect(phone.pendingLink?.request.checkCode == real.checkCode && real.checkCode != intruder.checkCode)
        // A device code from another app, not the camera, is never used.
        let shown = DeviceLinker()
        shown.offer()
        guard case .refused = phone.useScannedCode(JoinCode.link(try #require(shown.joinCode)), fromLink: true) else {
            Issue.record("A device code from a link was used")
            return
        }
        real.cancel(); intruder.cancel(); shown.cancel()
    }

    /// The anonymity report asks the relay which address it sees; directly, that's this machine.
    @Test func relayToldWhichAddressItSees() async throws {
        let relay = try #require(URL(string: AppData.defaultRelay))
        #expect(await RelayClient(base: relay, lane: "report").seen() == "127.0.0.1")
    }

    /// With random timing on, as in the app: each lane polls on its own, and a message gets through without
    /// anything nudging a sync.
    @Test func lanesPollOnTheirOwn() async throws {
        let alice = testModel("pulshade-test"), bob = testModel("pulshade-test")
        alice.trafficShaping = true
        bob.trafficShaping = true
        try await alice.create(identity: .generate(), profile: Profile(name: "Alice"), passcode: "test-passcode")
        try await bob.create(identity: .generate(), profile: Profile(name: "Bob"), passcode: "test-passcode")
        defer { alice.lock(); bob.lock() }

        let contact = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        let chat = bob.startConversation(kind: .direct, title: "Alice", members: [contact.fingerprint], persona: nil)
        bob.send("over its own lane", in: chat.id)
        let end = Date().addingTimeInterval(30)
        while Date() < end, !alice.data.conversations.contains(where: { $0.messages.contains { $0.text == "over its own lane" } }) {
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(alice.data.conversations.contains { $0.messages.contains { $0.text == "over its own lane" } })
        #expect(!alice.relayUnreachable && !bob.relayUnreachable)
    }
}
