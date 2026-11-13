import Testing
import Foundation
@testable import Pulshade

/// Groups that share one mailbox, end to end through a real relay (see scripts/test.sh): making one, joining,
/// talking, and a removal that starts a new epoch.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct SharedGroupFlowTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-shared")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func settle(_ models: AppModel..., rounds: Int = 6) async {
        for _ in 0..<rounds { for m in models { await m.syncOnce() } }
    }

    private func until(_ models: [AppModel], seconds: Double = 15, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnce() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Alice knows Bob and Cara; they don't know each other.
    private func trio() async throws -> (AppModel, AppModel, AppModel, String, String) {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob"), cara = try await makeUser("Cara")
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        // Everyone has heard from everyone's app (and so knows it takes part) once a message has gone each way.
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint
        for fp in [bobFP, caraFP] {
            let chat = alice.startConversation(kind: .direct, title: "", members: [fp])
            alice.send("hi", in: chat.id)
        }
        await settle(alice, bob, cara)
        for m in [bob, cara] {
            if let chat = m.data.conversations.first(where: { $0.kind == .direct }) { m.send("hey", in: chat.id) }
        }
        await settle(alice, bob, cara)
        return (alice, bob, cara, bobFP, caraFP)
    }

    @Test func aSharedGroupIsMadeJoinedAndTalkedIn() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        #expect(alice.membersNeedingUpdate([bobFP, caraFP], persona: nil, kind: .group).isEmpty)

        let group = alice.startConversation(kind: .group, title: "Night owls", members: [bobFP, caraFP])
        #expect(group.shared != nil, "everyone's app can, so it shares one mailbox")
        await until([alice, bob, cara]) {
            alice.conversation(group.id)?.members.count == 2
                && bob.conversation(group.id)?.members.count == 2 && cara.conversation(group.id)?.members.count == 2
                && bob.conversation(group.id)?.shared?.joining == false && cara.conversation(group.id)?.shared?.joining == false
        }
        let bobGroup = try #require(bob.conversation(group.id))
        #expect(bobGroup.title == "Night owls" && bobGroup.members.count == 2 && bobGroup.owner != "me")
        // Bob and Cara never became contacts of each other with anywhere to write: only names.
        let caraForBob = try #require(bob.data.contacts.first { $0.name == "Cara" })
        #expect(caraForBob.hidden && caraForBob.devices.isEmpty)
        #expect(caraForBob.signingKey != cara.identity?.signingKey.publicKey.rawRepresentation, "a key made for this group alone")

        bob.send("hi all", in: group.id)
        await until([alice, bob, cara]) { cara.conversation(group.id)?.messages.contains { $0.text == "hi all" } == true }
        #expect(cara.conversation(group.id)?.messages.filter { !$0.isSystem }.map(\.text) == ["hi all"])
        #expect(bob.conversation(group.id)?.messages.first?.status == .sent)
        cara.send("hey bob", in: group.id)
        await until([alice, bob, cara]) { bob.conversation(group.id)?.messages.count == 2 && alice.conversation(group.id)?.messages.count == 2 }
        #expect(bob.conversation(group.id)?.messages.map(\.text) == ["hi all", "hey bob"])
        #expect(alice.conversation(group.id)?.messages.filter { !$0.isSystem }.map(\.text) == ["hi all", "hey bob"])
        // Who said it shows by name.
        let fromCara = try #require(bob.conversation(group.id)?.messages.last)
        #expect(bob.displayName(fromCara.sender) == "Cara")

        // Reactions and unsends go through the mailbox too.
        let first = try #require(cara.conversation(group.id)?.messages.first)
        cara.react("🔥", to: first.id, in: group.id)
        await until([alice, bob, cara]) { bob.conversation(group.id)?.messages.first?.reactions.values.contains("🔥") == true }
        #expect(bob.conversation(group.id)?.messages.first?.reactions.values.contains("🔥") == true)
        let mine = try #require(cara.conversation(group.id)?.messages.last)
        cara.unsend(mine.id, in: group.id)
        await until([alice, bob, cara]) { alice.conversation(group.id)?.messages.count == 1 }
        #expect(alice.conversation(group.id)?.messages.filter { !$0.isSystem }.map(\.text) == ["hi all"])

        // Details changed by the owner reach everyone; a plain member can't change them.
        alice.updateDetails(group.id, title: "Early birds", about: "", avatar: nil)
        await until([alice, bob, cara]) { bob.conversation(group.id)?.title == "Early birds" }
        #expect(cara.conversation(group.id)?.title == "Early birds")
        bob.updateDetails(group.id, title: "Mine now", about: "", avatar: nil)
        await settle(alice, bob, cara)
        #expect(alice.conversation(group.id)?.title == "Early birds")
    }

    /// The phone makes a group with the laptop and a friend who don't know each other. The friend joins at once and
    /// chats with the phone; the laptop's app is closed and catches up later. The laptop and the friend must still read
    /// each other, whichever order things happen in.
    @Test(arguments: [false, true])
    func aMemberWhoJoinsLateStillReadsAndIsRead(_ laptopWritesFirst: Bool) async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Late", members: [bobFP, caraFP])
        #expect(group.shared != nil)
        // Only the phone and the friend are open.
        await until([alice, cara]) { cara.conversation(group.id)?.shared?.joining == false }
        alice.send("phone 1", in: group.id)
        cara.send("friend 1", in: group.id)
        await until([alice, cara]) { alice.conversation(group.id)?.messages.contains { $0.text == "friend 1" } == true }
        // The laptop opens Pulshade.
        await until([alice, bob, cara]) {
            bob.conversation(group.id)?.shared?.joining == false
                && cara.conversation(group.id)?.members.count == 2 && alice.conversation(group.id)?.members.count == 2
        }
        #expect(bob.conversation(group.id)?.shared?.joining == false, "the laptop got in")
        if laptopWritesFirst {
            bob.send("laptop 1", in: group.id)
            await until([alice, bob, cara]) { cara.conversation(group.id)?.messages.contains { $0.text == "laptop 1" } == true }
            cara.send("friend 2", in: group.id)
        } else {
            cara.send("friend 2", in: group.id)
            await until([alice, bob, cara]) { bob.conversation(group.id)?.messages.contains { $0.text == "friend 2" } == true }
            bob.send("laptop 1", in: group.id)
        }
        await until([alice, bob, cara]) {
            cara.conversation(group.id)?.messages.contains { $0.text == "laptop 1" } == true
                && bob.conversation(group.id)?.messages.contains { $0.text == "friend 2" } == true
                && alice.conversation(group.id)?.messages.contains { $0.text == "laptop 1" } == true
        }
        let epochs = [alice, bob, cara].map { $0.conversation(group.id)?.shared?.current?.number ?? -1 }
        #expect(cara.conversation(group.id)?.messages.contains { $0.text == "laptop 1" } == true, "the friend reads the laptop (epochs \(epochs))")
        #expect(bob.conversation(group.id)?.messages.contains { $0.text == "friend 2" } == true, "the laptop reads the friend (epochs \(epochs))")
        #expect(alice.conversation(group.id)?.messages.contains { $0.text == "laptop 1" } == true)
    }

    /// An epoch's key opens everything said in it, so an admin's phone starts a new one, with everyone still in, once the
    /// current one is long (or old) and something was said; a quiet group keeps its epoch. A member who was taken out
    /// afterwards reads nothing in the new ones.
    @Test func anEpochRotatesByCountAndAgeAndATakenOutMemberStaysOut() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let savedChats = AppModel.epochMaxChats, savedRetry = AppModel.rotationRetry
        defer { AppModel.epochMaxChats = savedChats; AppModel.rotationRetry = savedRetry }
        let group = alice.startConversation(kind: .group, title: "Rotate", members: [bobFP, caraFP])
        await until([alice, bob, cara]) { cara.conversation(group.id)?.shared?.joining == false && bob.conversation(group.id)?.shared?.joining == false }
        let first = try #require(alice.conversation(group.id)?.shared?.current?.number)

        // Quiet: nothing said, so even an old epoch is left alone.
        let ai = try #require(alice.data.conversations.firstIndex { $0.id == group.id })
        func setStarted(_ date: Date) {
            var shared = alice.data.conversations[ai].shared!
            shared.epochs[shared.epochs.count - 1].started = date
            alice.data.conversations[ai].shared = shared
        }
        setStarted(Date().addingTimeInterval(-30 * 86_400))
        alice.data.conversations[ai].shared?.chatInEpoch = false
        alice.tendSharedGroups()
        #expect(alice.conversation(group.id)?.shared?.current?.number == first)

        // Said enough: a new epoch by count.
        AppModel.epochMaxChats = 3
        AppModel.rotationRetry = 0
        for text in ["one", "two", "three"] { bob.send(text, in: group.id) }
        await until([alice, bob, cara]) { alice.conversation(group.id)?.messages.contains { $0.text == "three" } == true
            && cara.conversation(group.id)?.messages.contains { $0.text == "three" } == true }
        setStarted(Date())
        alice.tendSharedGroups()
        await until([alice, bob, cara]) { [alice, bob, cara].allSatisfy { $0.conversation(group.id)?.shared?.current?.number == first + 1 } }
        for m in [alice, bob, cara] { #expect(m.conversation(group.id)?.shared?.current?.number == first + 1) }
        #expect(alice.conversation(group.id)?.shared?.chatsInEpoch == nil, "The count starts again")

        // Everyone reads in the new epoch, and mail still on its way from the old one opens too.
        cara.send("after", in: group.id)
        await until([alice, bob, cara]) { bob.conversation(group.id)?.messages.contains { $0.text == "after" } == true }
        #expect(bob.conversation(group.id)?.messages.contains { $0.text == "after" } == true)

        // Cara is taken out: a newer epoch, which she doesn't get.
        AppModel.epochMaxChats = 1_000
        let removed = try #require(alice.conversation(group.id)?.members.first { alice.displayName($0) == "Cara" })
        alice.removeSharedMember(removed, at: ai)
        await until([alice, bob]) { bob.conversation(group.id)?.shared?.current?.number == first + 2 }
        bob.send("secret after removal", in: group.id)
        await until([alice, bob, cara], seconds: 6) { cara.conversation(group.id)?.messages.contains { $0.text == "secret after removal" } == true }
        #expect(cara.conversation(group.id)?.messages.contains { $0.text == "secret after removal" } != true)
        #expect(alice.conversation(group.id)?.messages.contains { $0.text == "secret after removal" } == true)
    }

    /// A member's phone never got a new epoch's key (it was away, or the hand-out went astray). It asks again on its own
    /// and an admin's phone sends it; nobody has to add anyone again.
    @Test func aMemberWhoMissedAKeyGetsItBackOnTheirOwn() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Keys", members: [bobFP, caraFP])
        await until([alice, bob, cara]) { cara.conversation(group.id)?.shared?.joining == false && bob.conversation(group.id)?.shared?.joining == false }
        bob.send("chat", in: group.id)
        await until([alice, bob, cara]) { cara.conversation(group.id)?.messages.contains { $0.text == "chat" } == true }
        let before = try #require(cara.conversation(group.id)?.shared?.current?.number)

        // A new epoch starts (as when someone is added after a chat); Cara reads the settings but loses the key.
        alice.startNewEpoch(group.id)
        await until([alice, bob]) { bob.conversation(group.id)?.shared?.current?.number == before + 1 }
        let ci = try #require(cara.data.conversations.firstIndex { $0.id == group.id })
        await until([cara]) { cara.data.conversations[ci].shared?.candidates.contains { $0.number == before + 1 } == true
            || cara.data.conversations[ci].shared?.current?.number == before + 1 }
        // Undo what the key did on Cara's phone: back to the old epoch, the new settings waiting for a key.
        var held = try #require(cara.data.conversations[ci].shared)
        if let newer = held.current, newer.number == before + 1 {
            let settings = held.settings
            held.epochs.removeAll { $0.number == before + 1 }
            held.candidates.removeAll()
            held.settings = try #require(held.previous)
            held.pendingSettings = settings
            held.missedKey = true
            cara.data.conversations[ci].shared = held
        } else {
            held.candidates.removeAll()
            cara.data.conversations[ci].shared = held
        }
        #expect(cara.conversation(group.id)?.shared?.current?.number == before)

        bob.send("in the new epoch", in: group.id)
        // Cara's phone asks, Alice's phone answers.
        cara.tendSharedGroups()
        await until([alice, bob, cara], seconds: 25) {
            cara.conversation(group.id)?.messages.contains { $0.text == "in the new epoch" } == true
        }
        #expect(cara.conversation(group.id)?.shared?.current?.number == before + 1, "Cara has the new key")
        #expect(cara.conversation(group.id)?.messages.contains { $0.text == "in the new epoch" } == true)
    }

    /// Two people who only share a group become friends from it: one taps the other's name and asks, the other accepts,
    /// and each then has the other as a friend, with nobody else in the group able to read the invite.
    @Test func groupMembersBecomeFriendsFromTheGroup() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Meet", members: [bobFP, caraFP])
        await until([alice, bob, cara]) {
            bob.conversation(group.id)?.members.count == 2 && cara.conversation(group.id)?.members.count == 2
                && bob.conversation(group.id)?.shared?.joining == false && cara.conversation(group.id)?.shared?.joining == false
        }
        let bobGroup = try #require(bob.conversation(group.id))
        let caraInBob = try #require(bobGroup.members.first { bob.displayName($0) == "Cara" })
        #expect(bob.friendState(of: caraInBob, in: bobGroup) == .canAsk)
        bob.addFriend(caraInBob, in: group.id, note: "hi from the group")
        #expect(bob.friendState(of: caraInBob, in: bobGroup) == .asked)
        await until([alice, bob, cara]) { cara.groupFriendInvites.count == 1 }
        let invite = try #require(cara.groupFriendInvites.first)
        #expect(invite.name == "Bob" && invite.note == "hi from the group" && invite.groupTitle == "Meet")
        #expect(alice.groupFriendInvites.isEmpty, "only Cara could open it")

        cara.acceptFriendInvite(invite.id)
        let bobAccount = try #require(bob.me(nil)?.fingerprint)
        let caraAccount = try #require(cara.me(nil)?.fingerprint)
        await until([alice, bob, cara]) {
            bob.data.contacts.contains { $0.fingerprint == caraAccount && !$0.hidden }
                && cara.data.contacts.contains { $0.fingerprint == bobAccount && !$0.hidden && !$0.awaitingAcceptance }
        }
        #expect(bob.data.contacts.contains { $0.fingerprint == caraAccount && !$0.hidden }, "Bob has Cara as a friend")
        #expect(cara.data.contacts.contains { $0.fingerprint == bobAccount && !$0.hidden }, "Cara has Bob as a friend")
        #expect(cara.groupFriendInvites.isEmpty)
    }

    /// Adding someone shows at once, to everyone, as in other apps: before their app has answered, the group says who was
    /// added and the admin sees them as invited; the invite asks to wake their phone; and they're in once it runs.
    @Test func addingSomeoneShowsAtOnceAndWakesTheirPhone() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Now", members: [bobFP])
        await until([alice, bob]) { bob.conversation(group.id)?.shared?.joining == false && alice.conversation(group.id)?.members.count == 1 }
        alice.addMembers(group.id, [caraFP])
        let aliceGroup = try #require(alice.conversation(group.id))
        #expect(alice.contactsInvited(to: aliceGroup) == [caraFP], "shown as invited straight away")
        #expect(aliceGroup.messages.contains { $0.isSystem && $0.text == "You added Cara" })
        #expect(alice.data.outbox.contains { $0.wakes == true }, "the invite asks the relay to wake her phone")
        // Bob hears about it before Cara's app has done anything.
        await until([alice, bob]) { bob.conversation(group.id)?.messages.contains { $0.isSystem && $0.text == "Alice added Cara" } == true }
        #expect(bob.conversation(group.id)?.messages.contains { $0.isSystem && $0.text == "Alice added Cara" } == true)
        // Cara's app runs: she's in, and no longer listed as invited.
        await until([alice, bob, cara]) { cara.conversation(group.id)?.shared?.joining == false && alice.conversation(group.id)?.members.count == 2 }
        #expect(cara.conversation(group.id)?.shared?.joining == false)
        #expect(alice.conversation(group.id).map { alice.contactsInvited(to: $0) }?.isEmpty == true)
    }

    /// A new group is always the new format. Someone whose app can't take part is refused with their name, and nothing is kept
    /// to add them later; once their app says it can, they are added like anyone else.
    @Test func someoneOnAnOlderAppIsRefusedUntilTheyUpdate() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        // Alice's phone thinks Cara's app is from before groups that share a mailbox.
        let ci = try #require(alice.data.contacts.firstIndex { $0.fingerprint == caraFP })
        for d in alice.data.contacts[ci].devices.indices { alice.data.contacts[ci].devices[d].readsSharedGroups = nil }
        #expect(alice.membersNeedingUpdate([bobFP, caraFP], persona: nil, kind: .group) == [caraFP])
        #expect(alice.needsUpdateMessage([caraFP]) == "Cara needs to update Pulshade first.")
        let group = alice.startConversation(kind: .group, title: "New", members: [bobFP, caraFP])
        #expect(group.shared != nil, "never the old format")
        let aliceGroup = try #require(alice.conversation(group.id))
        #expect(alice.contactsInvited(to: aliceGroup) == [bobFP], "Cara is not invited")
        #expect(alice.addMembers(group.id, [caraFP]) == [caraFP], "refused, and told who")
        await settle(alice, bob, cara)
        #expect(cara.conversation(group.id) == nil, "nothing reached her")
        // Cara "updates": her app's next message says it can.
        let caraChat = try #require(cara.data.conversations.first { $0.kind == .direct })
        cara.send("updated", in: caraChat.id)
        await settle(alice, bob, cara)
        #expect(alice.membersNeedingUpdate([caraFP], persona: nil, kind: .group).isEmpty)
        #expect(alice.addMembers(group.id, [caraFP]).isEmpty)
        await until([alice, bob, cara]) { cara.conversation(group.id)?.shared?.joining == false && bob.conversation(group.id)?.shared?.joining == false }
        #expect(cara.conversation(group.id)?.shared?.joining == false, "in once her app could")
    }

    @Test func someoneTakenOutCantReadWhatFollows() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP, caraFP])
        await until([alice, bob, cara]) { alice.conversation(group.id)?.members.count == 2 && cara.conversation(group.id)?.shared?.joining == false
            && bob.conversation(group.id)?.shared?.joining == false && bob.conversation(group.id)?.members.count == 2 }
        let caraInGroup = try #require(alice.conversation(group.id)?.members.first { alice.displayName($0) == "Cara" })
        let before = try #require(alice.conversation(group.id)?.shared?.current?.number)

        alice.removeMember(group.id, caraInGroup)
        #expect(alice.conversation(group.id)?.shared?.current?.number == before + 1, "a new epoch")
        await until([alice, bob, cara]) { cara.conversation(group.id)?.shared?.gone == true && bob.conversation(group.id)?.shared?.current?.number == before + 1 }
        #expect(cara.conversation(group.id)?.shared?.gone == true)
        #expect(cara.conversation(group.id)?.shared?.epochs.map(\.number) == [before], "Cara never got the new key")
        #expect(bob.conversation(group.id)?.members.count == 1)

        bob.send("just us now", in: group.id)
        await until([alice, bob, cara]) { alice.conversation(group.id)?.messages.contains { $0.text == "just us now" } == true }
        #expect(alice.conversation(group.id)?.messages.contains { $0.text == "just us now" } == true)
        await settle(alice, bob, cara)
        #expect(cara.conversation(group.id)?.messages.contains { $0.text == "just us now" } == false)
        #expect(!cara.canPost(in: try #require(cara.conversation(group.id))))
    }

    @Test func aLaterNewcomerJoinsAndLeavingTakesThemOut() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP])
        await until([alice, bob]) { bob.conversation(group.id)?.shared?.joining == false }
        bob.send("before cara", in: group.id)
        await until([alice, bob]) { alice.conversation(group.id)?.messages.count == 1 }

        alice.addMembers(group.id, [caraFP])
        await until([alice, bob, cara]) { cara.conversation(group.id)?.shared?.joining == false && bob.conversation(group.id)?.members.count == 2 }
        #expect(cara.conversation(group.id)?.messages.isEmpty == true, "nothing from before she joined")
        bob.send("welcome", in: group.id)
        await until([alice, bob, cara]) { cara.conversation(group.id)?.messages.contains { $0.text == "welcome" } == true }
        #expect(cara.conversation(group.id)?.messages.map(\.text) == ["welcome"])

        // Leaving: the owner's device takes her out with a new epoch.
        let epoch = try #require(alice.conversation(group.id)?.shared?.current?.number)
        cara.delete(group.id)
        await until([alice, bob, cara]) { alice.conversation(group.id)?.members.count == 1 && bob.conversation(group.id)?.members.count == 1 }
        #expect(alice.conversation(group.id)?.shared?.current?.number == epoch + 1)
        #expect(bob.conversation(group.id)?.shared?.current?.number == epoch + 1)
    }

    /// The owner deleting a group removes it for everyone; a member deleting it only leaves.
    @Test func theOwnerDeletingAGroupRemovesItForEveryone() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Gone soon", members: [bobFP, caraFP])
        await until([alice, bob, cara]) { bob.conversation(group.id)?.shared?.joining == false && cara.conversation(group.id)?.shared?.joining == false }
        alice.delete(group.id)
        #expect(alice.conversation(group.id) == nil)
        await until([alice, bob, cara]) { bob.conversation(group.id) == nil && cara.conversation(group.id) == nil }
        #expect(bob.conversation(group.id) == nil && cara.conversation(group.id) == nil)
    }

    /// Someone added after the group was made, and people already in it, see each other's messages both ways,
    /// including a member who isn't the owner and a newcomer who isn't anyone's friend but the owner's.
    @Test func membersAddedLaterAndEarlierHearEachOther() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP])
        await until([alice, bob]) { bob.conversation(group.id)?.shared?.joining == false }

        alice.addMembers(group.id, [caraFP])
        await until([alice, bob, cara]) { cara.conversation(group.id)?.shared?.joining == false && bob.conversation(group.id)?.members.count == 2 }
        cara.send("hi from cara", in: group.id)
        await until([alice, bob, cara]) { bob.conversation(group.id)?.messages.contains { $0.text == "hi from cara" } == true
            && alice.conversation(group.id)?.messages.contains { $0.text == "hi from cara" } == true }
        #expect(bob.conversation(group.id)?.messages.contains { $0.text == "hi from cara" } == true, "Bob sees the newcomer")
        #expect(alice.conversation(group.id)?.messages.contains { $0.text == "hi from cara" } == true, "the owner sees the newcomer")
        bob.send("hi from bob", in: group.id)
        await until([alice, bob, cara]) { cara.conversation(group.id)?.messages.contains { $0.text == "hi from bob" } == true }
        #expect(cara.conversation(group.id)?.messages.contains { $0.text == "hi from bob" } == true, "the newcomer sees Bob")
        alice.send("hi from alice", in: group.id)
        await until([alice, bob, cara]) { cara.conversation(group.id)?.messages.contains { $0.text == "hi from alice" } == true
            && bob.conversation(group.id)?.messages.contains { $0.text == "hi from alice" } == true }
        #expect(cara.conversation(group.id)?.messages.contains { $0.text == "hi from alice" } == true)
        if let fromCara = bob.conversation(group.id)?.messages.first(where: { $0.text == "hi from cara" }) {
            #expect(bob.displayName(fromCara.sender) == "Cara")
        }
    }

    /// Friends who have only just been added, with no chat yet, then a third added to the group afterwards.
    @Test func freshFriendsAddedLaterHearEachOther() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob"), cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP])
        await until([alice, bob]) { bob.conversation(group.id) != nil && bob.conversation(group.id)?.shared?.joining != true }
        alice.addMembers(group.id, [caraFP])
        await until([alice, bob, cara]) { cara.conversation(group.id) != nil && cara.conversation(group.id)?.shared?.joining != true
            && bob.conversation(group.id)?.members.count == 2 }
        #expect(cara.conversation(group.id) != nil, "Cara is in the group (shared: \(group.shared != nil))")
        cara.send("fresh hi from cara", in: group.id)
        await until([alice, bob, cara], seconds: 25) { bob.conversation(group.id)?.messages.contains { $0.text == "fresh hi from cara" } == true }
        #expect(bob.conversation(group.id)?.messages.contains { $0.text == "fresh hi from cara" } == true, "Bob sees the newcomer")
        bob.send("fresh hi from bob", in: group.id)
        await until([alice, bob, cara], seconds: 25) { cara.conversation(group.id)?.messages.contains { $0.text == "fresh hi from bob" } == true }
        #expect(cara.conversation(group.id)?.messages.contains { $0.text == "fresh hi from bob" } == true, "the newcomer sees Bob")
    }

    /// Locking and reopening between adding someone and talking changes nothing.
    @Test func addedLaterStillHearEachOtherAfterReopening() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP])
        await until([alice, bob]) { bob.conversation(group.id)?.shared?.joining == false }
        bob.send("first", in: group.id)
        await until([alice, bob]) { alice.conversation(group.id)?.messages.count == 1 }
        alice.addMembers(group.id, [caraFP])
        await until([alice, bob, cara]) { cara.conversation(group.id)?.shared?.joining == false && bob.conversation(group.id)?.members.count == 2 }
        for m in [alice, bob, cara] {
            m.lock()
            #expect(await m.unlock(passcode: "test-passcode"))
        }
        cara.send("after reopening", in: group.id)
        await until([alice, bob, cara]) { bob.conversation(group.id)?.messages.contains { $0.text == "after reopening" } == true }
        #expect(bob.conversation(group.id)?.messages.contains { $0.text == "after reopening" } == true, "Bob sees the newcomer")
        bob.send("back at you", in: group.id)
        await until([alice, bob, cara]) { cara.conversation(group.id)?.messages.contains { $0.text == "back at you" } == true }
        #expect(cara.conversation(group.id)?.messages.contains { $0.text == "back at you" } == true, "the newcomer sees Bob")
    }

    private func linkNewDevice(to model: AppModel) async throws -> AppModel {
        let code = model.makeLinkCode()
        let linker = DeviceLinker()
        linker.start(code)
        for _ in 0..<20 where model.pendingLink == nil {
            try await Task.sleep(for: .milliseconds(200))
            await model.syncOnce()
        }
        model.approveLink()
        await model.syncOnce()
        for _ in 0..<30 where linker.stage != .confirming { try await Task.sleep(for: .milliseconds(250)) }
        // The account isn't taken until the digits match what the approving device shows.
        #expect(linker.senderConfirms && linker.confirmation != nil && linker.confirmation == model.linkConfirmation)
        linker.confirm()
        #expect(linker.stage == .received)
        let bundle = try #require(linker.bundle)
        let device = testModel("pulshade-shared-linked")
        try await device.finishLink(bundle, deviceID: linker.deviceID, selfMailbox: linker.selfMailbox,
                                    relay: linker.relay, passcode: "second-device")
        return device
    }

    /// Two devices of one account are one member, each with a chain of its own: both read and both post, and a
    /// group made after linking reaches the second device too.
    @Test func linkedDevicesShareTheMemberButNotTheChain() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        let bobsMac = try await linkNewDevice(to: bob)
        defer { for m in [alice, bob, cara, bobsMac] { m.lock() } }
        await settle(alice, bob, cara, bobsMac)
        // Alice hears from the new device, so she knows its app takes part too.
        await until([alice, bob, cara, bobsMac]) { bobsMac.data.conversations.contains { $0.kind == .direct } }
        let chat = try #require(bobsMac.data.conversations.first { $0.kind == .direct })
        bobsMac.send("my mac", in: chat.id)
        await until([alice, bob, cara, bobsMac]) { alice.membersNeedingUpdate([bobFP, caraFP], persona: nil, kind: .group).isEmpty }
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP, caraFP])
        #expect(group.shared != nil)
        await until([alice, bob, cara, bobsMac]) { bobsMac.conversation(group.id)?.shared?.joining == false
            && cara.conversation(group.id)?.shared?.joining == false }
        #expect(bobsMac.conversation(group.id)?.shared != nil, "the other device learnt the group from the phone")

        cara.send("one", in: group.id)
        await until([alice, bob, cara, bobsMac]) { bobsMac.conversation(group.id)?.messages.count == 1 && bob.conversation(group.id)?.messages.count == 1 }
        #expect(bobsMac.conversation(group.id)?.messages.map(\.text) == ["one"])

        bob.send("from the phone", in: group.id)
        await until([alice, bob, cara, bobsMac]) { cara.conversation(group.id)?.messages.count == 2 }
        bobsMac.send("from the mac", in: group.id)
        await until([alice, bob, cara, bobsMac]) { cara.conversation(group.id)?.messages.count == 3 && bob.conversation(group.id)?.messages.count == 3 }
        #expect(cara.conversation(group.id)?.messages.map(\.text) == ["one", "from the phone", "from the mac"])
        let senders = Set(cara.conversation(group.id)?.messages.dropFirst().map(\.sender) ?? [])
        #expect(senders.count == 1, "both devices are the same member")
        #expect(bob.conversation(group.id)?.messages.last?.sender == "me")
        let tags = [bob, bobsMac].compactMap { $0.conversation(group.id)?.shared?.myTag }
        #expect(tags.count == 2 && tags[0] != tags[1], "each device its own chain")
    }

    /// Someone in the group (or once in it) who is also your friend can't rewrite it for you with a forged invite:
    /// making themselves admin, or moving you to an epoch of their own.
    @Test func aForgedInviteCantTakeTheGroupOver() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP, caraFP])
        await until([alice, bob, cara]) { bob.conversation(group.id)?.members.count == 2 && bob.conversation(group.id)?.shared?.joining == false
            && cara.conversation(group.id)?.shared?.joining == false }
        let held = try #require(bob.conversation(group.id)?.shared)
        // Cara builds settings with the real owner and herself as admin, signs them with her group key, and sends them to
        // Bob as an invite with an epoch of her own. (Bob knows her only inside the group, so she uses Alice's chat path:
        // the check must hold whoever it comes from.)
        let caraKeys = try #require(cara.memberKeys(nil, group: group.id))
        var forged = held.settings
        forged.admins = [caraKeys.publicKey]
        forged.version = held.settings.version + 50
        forged.epoch = held.settings.epoch + 1
        forged.sign(with: caraKeys)
        let aliceAsBobSees = try #require(bob.visibleContacts.first { $0.name == "Alice" })
        bob.acceptGroupInvite(GroupInvite(settings: forged, epoch: GroupEpoch.fresh(number: forged.epoch)), from: aliceAsBobSees)
        let after = try #require(bob.conversation(group.id)?.shared)
        #expect(after.settings == held.settings && after.epochs == held.epochs, "nothing taken")
        // Nor numbers out of range.
        var wild = held.settings
        wild.version = Int.max
        wild.sign(with: caraKeys)
        bob.acceptGroupInvite(GroupInvite(settings: wild, epoch: GroupEpoch(number: -1, key: .random(32), started: Date())), from: aliceAsBobSees)
        #expect(bob.conversation(group.id)?.shared?.settings == held.settings)
    }

    /// Alice owns a group with Bob as an admin and Cara and Dan in it; Bob takes Cara out at the same moment Alice takes
    /// Dan out. Every device ends up on the same settings and key, and both removals stick.
    @Test func twoAdminsRemovingAtOnceEndUpAgreeing() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        let dan = try await makeUser("Dan"), eve = try await makeUser("Eve")
        defer { for m in [alice, bob, cara, dan, eve] { m.lock() } }
        var fps: [String] = []
        for (m, name) in [(dan, "Dan"), (eve, "Eve")] {
            _ = try #require(m.addContact(code: alice.makeInviteCode(), nickname: ""))
            await settle(alice, m)
            let fp = try #require(alice.visibleContacts.first { $0.name == name }).fingerprint
            let chat = alice.startConversation(kind: .direct, title: "", members: [fp])
            alice.send("hi", in: chat.id)
            await settle(alice, m)
            if let back = m.data.conversations.first(where: { $0.kind == .direct }) { m.send("hey", in: back.id) }
            await settle(alice, m)
            fps.append(fp)
        }
        let danFP = fps[0], eveFP = fps[1]
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP, caraFP, danFP, eveFP])
        let everyone = [alice, bob, cara, dan, eve]
        await until(everyone) { everyone.dropFirst().allSatisfy { $0.conversation(group.id)?.members.count == 4 } }
        let bobMember = try #require(alice.conversation(group.id)?.members.first { alice.displayName($0) == "Bob" })
        alice.setAdmin(group.id, bobMember, true)
        await until(everyone) { bob.conversation(group.id)?.amAdmin == true }
        let caraMember = try #require(bob.conversation(group.id)?.members.first { bob.displayName($0) == "Cara" })
        let danMember = try #require(alice.conversation(group.id)?.members.first { alice.displayName($0) == "Dan" })

        // At once: neither has seen the other's change.
        bob.removeMember(group.id, caraMember)
        alice.removeMember(group.id, danMember)
        let stayers = [alice, bob, eve]
        await until(everyone, seconds: 30) {
            let views = stayers.compactMap { $0.conversation(group.id)?.shared }
            return views.count == 3 && views.allSatisfy { $0.settings == views[0].settings && $0.current?.key == views[0].current?.key }
                && views[0].settings.members.count == 3
        }
        let e = try #require(eve.conversation(group.id)?.shared)
        let a = try #require(alice.conversation(group.id)?.shared), b = try #require(bob.conversation(group.id)?.shared)
        #expect(a.settings == b.settings, "the same settings everywhere")
        #expect(a.current?.key == b.current?.key, "the same key everywhere")
        #expect(e.settings == a.settings && e.current?.key == a.current?.key, "an ordinary member who stays agrees too")
        #expect(a.settings.members.count == 3, "both removals stuck")
        #expect(cara.conversation(group.id)?.shared?.gone == true && dan.conversation(group.id)?.shared?.gone == true)
        bob.send("just us", in: group.id)
        await until(everyone) { alice.conversation(group.id)?.messages.contains { $0.text == "just us" } == true
            && eve.conversation(group.id)?.messages.contains { $0.text == "just us" } == true }
        #expect(eve.conversation(group.id)?.messages.contains { $0.text == "just us" } == true)
        #expect(alice.conversation(group.id)?.messages.contains { $0.text == "just us" } == true)
        await settle(alice, bob, cara, dan)
        #expect(cara.conversation(group.id)?.messages.contains { $0.text == "just us" } != true)
        #expect(dan.conversation(group.id)?.messages.contains { $0.text == "just us" } != true)
    }

    /// An invite that's taken back (or runs out) moves the group to a new key, so whoever was invited and never joined
    /// stops reading.
    @Test func aTakenBackInviteStopsTheInviteeReading() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP])
        await until([alice, bob]) { bob.conversation(group.id)?.shared?.joining == false }
        // Cara's app gets the invite but never answers (she's left out of syncing on purpose here).
        alice.addMembers(group.id, [caraFP])
        await until([alice, bob]) { alice.conversation(group.id)?.shared?.invited[caraFP] != nil }
        let given = try #require(alice.conversation(group.id)?.shared?.current?.number)
        alice.cancelInvite(caraFP, in: group.id)
        #expect(alice.conversation(group.id)?.shared?.invited.isEmpty == true)
        #expect(alice.conversation(group.id)?.shared?.current?.number == given + 1, "a new key")
        await until([alice, bob]) { bob.conversation(group.id)?.shared?.current?.number == given + 1 }
        #expect(bob.conversation(group.id)?.shared?.current?.number == given + 1)
    }

    /// Pictures aren't in the settings but still reach everyone, and only the one the member's card names is shown.
    @Test func membersPicturesArrive() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        cara.updateProfile { $0.avatar = Data(repeating: 1, count: 3_000) }
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP, caraFP])
        await until([alice, bob, cara]) {
            bob.data.contacts.first { $0.name == "Cara" && $0.hidden }?.avatar != nil
        }
        let caraForBob = try #require(bob.data.contacts.first { $0.name == "Cara" && $0.hidden })
        #expect(caraForBob.avatar != nil)
        #expect(bob.conversation(group.id)?.shared?.settings.members.allSatisfy { $0.avatar == nil } == true)
    }

    /// A big photo or voice note in a shared group goes to the relay once and the mailbox carries only a preview and a
    /// pointer; everyone in the group still gets the whole thing.
    @Test func bigPhotosAndVoiceNotesInASharedGroupGoViaTheBlobStore() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP, caraFP])
        await until([alice, bob, cara]) {
            bob.conversation(group.id)?.shared?.joining == false && cara.conversation(group.id)?.shared?.joining == false
        }
        let photo = RelayFlowTests.bigPhoto()
        #expect(photo.count > AppModel.mediaInline)
        alice.send("sunset", image: photo, in: group.id)
        await until([alice, bob, cara], seconds: 30) {
            bob.conversation(group.id)?.messages.last?.image == photo && cara.conversation(group.id)?.messages.last?.image == photo
        }
        #expect(bob.conversation(group.id)?.messages.last?.image == photo)
        #expect(cara.conversation(group.id)?.messages.last?.image == photo)
        #expect(bob.conversation(group.id)?.messages.last?.text == "sunset")
        let pointer = try #require(alice.conversation(group.id)?.messages.last?.attachment, "it went to the relay as a file")
        #expect(pointer.kind == .photo)
        let relay = RelayClient(base: try #require(URL(string: AppData.defaultRelay)), lane: "group-media-check")
        #expect(try await relay.blobHead(pointer.id) != nil, "one sealed copy is there for the group")

        let note = VoiceNote(audio: Data.random(90_000), duration: 22, levels: [10, 200, 90])
        bob.send("", voice: note, in: group.id)
        await until([alice, bob, cara], seconds: 30) {
            alice.conversation(group.id)?.messages.last?.voice?.audio == note.audio
                && cara.conversation(group.id)?.messages.last?.voice?.audio == note.audio
        }
        #expect(alice.conversation(group.id)?.messages.last?.voice?.audio == note.audio)
        #expect(cara.conversation(group.id)?.messages.last?.voice?.audio == note.audio)
    }

    /// A member who missed several versions catches up on the newest the owner signed.
    @Test func aMemberWhoMissedVersionsCatchesUpOnTheOwners() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP, caraFP])
        await until([alice, bob, cara]) { cara.conversation(group.id)?.members.count == 2 && bob.conversation(group.id)?.members.count == 2 }
        // Cara is away while two changes are made: her cursor is moved past them (seq numbers are microseconds).
        alice.updateDetails(group.id, title: "One", about: "", avatar: nil)
        alice.updateDetails(group.id, title: "Two", about: "", avatar: nil)
        await settle(alice, bob)
        #expect(bob.conversation(group.id)?.title == "Two")
        if let i = cara.data.conversations.firstIndex(where: { $0.id == group.id }), let n = cara.data.conversations[i].shared?.current?.number {
            cara.data.conversations[i].shared?.cursors[String(n)] = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        }
        // Bob, an admin now, makes a change Cara can't take without the ones she missed; the owner's device signs it
        // again, and that one she can.
        let bobMember = try #require(alice.conversation(group.id)?.members.first { alice.displayName($0) == "Bob" })
        alice.setAdmin(group.id, bobMember, true)
        await until([alice, bob]) { bob.conversation(group.id)?.amAdmin == true }
        if let i = cara.data.conversations.firstIndex(where: { $0.id == group.id }), let n = cara.data.conversations[i].shared?.current?.number {
            cara.data.conversations[i].shared?.cursors[String(n)] = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        }
        #expect(cara.conversation(group.id)?.title == "Crew")
        bob.updateDetails(group.id, title: "Three", about: "", avatar: nil)
        await until([alice, bob, cara]) { cara.conversation(group.id)?.title == "Three" }
        #expect(cara.conversation(group.id)?.title == "Three")
        #expect(cara.conversation(group.id)?.shared?.settings.signer == alice.memberKeys(nil, group: group.id)?.publicKey,
                "caught up on the owner's copy")
    }
}
