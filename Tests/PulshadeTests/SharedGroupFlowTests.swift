import Testing
import Foundation
@testable import Pulshade

/// Groups that share one mailbox, end to end through a real relay (see scripts/test.sh): making one, joining,
/// talking, a removal that starts a new epoch, and moving an old group over.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct SharedGroupFlowTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-shared")
        model.sharedGroupsEnabled = true
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
        #expect(alice.canShareMailbox([bobFP, caraFP], persona: nil, kind: .group))

        let group = alice.startConversation(kind: .group, title: "Night owls", members: [bobFP, caraFP])
        #expect(group.shared != nil, "everyone's app can, so it shares one mailbox")
        await until([alice, bob, cara]) {
            alice.conversation(group.id)?.members.count == 2
                && bob.conversation(group.id)?.members.count == 2 && cara.conversation(group.id)?.members.count == 2
                && bob.conversation(group.id)?.shared?.joining == false && cara.conversation(group.id)?.shared?.joining == false
        }
        let bobGroup = try #require(bob.conversation(group.id))
        #expect(bobGroup.title == "Night owls" && bobGroup.members.count == 2 && bobGroup.owner != "me")
        #expect(bobGroup.introsMine.isEmpty, "no introduction mailboxes")
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
        #expect(alice.conversation(group.id)?.messages.map(\.text) == ["hi all", "hey bob"])
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
        #expect(alice.conversation(group.id)?.messages.map(\.text) == ["hi all"])

        // Details changed by the owner reach everyone; a plain member can't change them.
        alice.updateDetails(group.id, title: "Early birds", about: "", avatar: nil)
        await until([alice, bob, cara]) { bob.conversation(group.id)?.title == "Early birds" }
        #expect(cara.conversation(group.id)?.title == "Early birds")
        bob.updateDetails(group.id, title: "Mine now", about: "", avatar: nil)
        await settle(alice, bob, cara)
        #expect(alice.conversation(group.id)?.title == "Early birds")
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

    @Test func theOwnerMovesAnOldGroupOver() async throws {
        let (alice, bob, cara, bobFP, caraFP) = try await trio()
        defer { for m in [alice, bob, cara] { m.lock() } }
        // Made the old way.
        for m in [alice, bob, cara] { m.sharedGroupsEnabled = false }
        let group = alice.startConversation(kind: .group, title: "Old crew", members: [bobFP, caraFP])
        #expect(group.shared == nil)
        await settle(alice, bob, cara)
        bob.send("old way", in: group.id)
        await until([alice, bob, cara]) { cara.conversation(group.id)?.messages.count == 1 }
        for m in [alice, bob, cara] { m.sharedGroupsEnabled = true }

        #expect(alice.canUpgrade(try #require(alice.conversation(group.id))))
        alice.upgradeToSharedMailbox(group.id)
        await until([alice, bob, cara]) { alice.conversation(group.id)?.members.count == 2
            && bob.conversation(group.id)?.shared?.joining == false && cara.conversation(group.id)?.shared?.joining == false }
        #expect(bob.conversation(group.id)?.shared != nil && cara.conversation(group.id)?.shared != nil)
        #expect(bob.conversation(group.id)?.messages.map(\.text) == ["old way"], "history stays")
        cara.send("new way", in: group.id)
        await until([alice, bob, cara]) { bob.conversation(group.id)?.messages.count == 2 }
        #expect(bob.conversation(group.id)?.messages.map(\.text) == ["old way", "new way"])
        #expect(!bob.canUpgrade(try #require(bob.conversation(group.id))), "only the owner moves it")
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
        for _ in 0..<30 where linker.stage != .received { try await Task.sleep(for: .milliseconds(250)) }
        let bundle = try #require(linker.bundle)
        let device = testModel("pulshade-shared-linked")
        device.sharedGroupsEnabled = true
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
        await until([alice, bob, cara, bobsMac]) { alice.canShareMailbox([bobFP, caraFP], persona: nil, kind: .group) }
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
        let dan = try await makeUser("Dan")
        defer { for m in [alice, bob, cara, dan] { m.lock() } }
        _ = try #require(dan.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, dan)
        let danFP = try #require(alice.visibleContacts.first { $0.name == "Dan" }).fingerprint
        let chat = alice.startConversation(kind: .direct, title: "", members: [danFP])
        alice.send("hi", in: chat.id)
        await settle(alice, dan)
        if let back = dan.data.conversations.first(where: { $0.kind == .direct }) { dan.send("hey", in: back.id) }
        await settle(alice, dan)
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP, caraFP, danFP])
        let everyone = [alice, bob, cara, dan]
        await until(everyone) { everyone.dropFirst().allSatisfy { $0.conversation(group.id)?.members.count == 3 } }
        let bobMember = try #require(alice.conversation(group.id)?.members.first { alice.displayName($0) == "Bob" })
        alice.setAdmin(group.id, bobMember, true)
        await until(everyone) { bob.conversation(group.id)?.amAdmin == true }
        let caraMember = try #require(bob.conversation(group.id)?.members.first { bob.displayName($0) == "Cara" })
        let danMember = try #require(alice.conversation(group.id)?.members.first { alice.displayName($0) == "Dan" })

        // At once: neither has seen the other's change.
        bob.removeMember(group.id, caraMember)
        alice.removeMember(group.id, danMember)
        let stayers = [alice, bob]
        await until(everyone, seconds: 30) {
            let views = stayers.compactMap { $0.conversation(group.id)?.shared }
            return views.count == 2 && views[0].settings == views[1].settings && views[0].current?.key == views[1].current?.key
                && views[0].settings.members.count == 2
        }
        let a = try #require(alice.conversation(group.id)?.shared), b = try #require(bob.conversation(group.id)?.shared)
        #expect(a.settings == b.settings, "the same settings everywhere")
        #expect(a.current?.key == b.current?.key, "the same key everywhere")
        #expect(a.settings.members.count == 2, "both removals stuck")
        #expect(cara.conversation(group.id)?.shared?.gone == true && dan.conversation(group.id)?.shared?.gone == true)
        bob.send("just us", in: group.id)
        await until(everyone) { alice.conversation(group.id)?.messages.contains { $0.text == "just us" } == true }
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
        cara.sharedGroupsEnabled = false
        alice.addMembers(group.id, [caraFP])
        await until([alice, bob, cara]) { alice.conversation(group.id)?.shared?.invited[caraFP] != nil }
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
