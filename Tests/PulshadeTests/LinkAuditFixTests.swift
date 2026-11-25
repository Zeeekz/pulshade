import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// Fixes from the review of links and invites (2026-11-22), without a relay.
struct LinkAuditFixTests {
    private func preview(_ link: JoinLink, group: UUID, by keys: GroupMemberKeys, made: Date = Date(), slot: Data?) -> GroupPreview {
        var p = GroupPreview(group: group, link: link.id, title: "T", about: nil, avatar: nil, members: 3, approval: false, expires: nil,
                             requestKey: link.requestPublic, mailbox: link.mailboxSendID, owner: keys.publicKey, admins: [],
                             made: wholeSecond(made))
        p.slot = slot
        p.sign(with: keys)
        return p
    }

    /// A preview someone kept (an admin since taken out, say) and puts back stops working a week after it was made.
    @Test func anOldPreviewIsNotTaken() throws {
        let group = UUID()
        let owner = GroupMemberKeys(seed: .random(32), group: group)
        let (link, _) = try #require(JoinLink.make(label: "", approval: false, expires: nil, limit: nil, creator: owner.publicKey))
        let code = link.code(owner: owner.publicKey)
        #expect(preview(link, group: group, by: owner, slot: JoinSlot.tag(link.secret)).verified(by: code))
        let old = preview(link, group: group, by: owner, made: Date().addingTimeInterval(-GroupPreview.life - 60), slot: JoinSlot.tag(link.secret))
        #expect(!old.verified(by: code), "past its time")
        let ahead = preview(link, group: group, by: owner, made: Date().addingTimeInterval(3 * 86_400), slot: JoinSlot.tag(link.secret))
        #expect(!ahead.verified(by: code), "dated days ahead to last longer")
    }

    /// A preview names the link secret it was made for: the same owner's preview for another link, or for this link
    /// before its keys were renewed, doesn't pass in this slot. One from an app before this has none and still passes.
    @Test func aPreviewOnlyPassesForItsOwnLinkSecret() throws {
        let group = UUID()
        let owner = GroupMemberKeys(seed: .random(32), group: group)
        let (link, _) = try #require(JoinLink.make(label: "", approval: false, expires: nil, limit: nil, creator: owner.publicKey))
        let (renewed, _) = try #require(link.reset())
        let code = renewed.code(owner: owner.publicKey)
        #expect(preview(renewed, group: group, by: owner, slot: JoinSlot.tag(renewed.secret)).verified(by: code))
        #expect(!preview(renewed, group: group, by: owner, slot: JoinSlot.tag(link.secret)).verified(by: code), "made for the old secret")
        let soon = GroupPreview.untaggedUntil.addingTimeInterval(-10 * 86_400)
        let untagged = preview(renewed, group: group, by: owner, made: soon, slot: nil)
        #expect(untagged.verified(by: code, now: soon.addingTimeInterval(3600)), "an older app's preview, while such apps are around")
        #expect(!untagged.verified(by: code, now: soon.addingTimeInterval(5 * 86_400)), "only for a few days after it was made")
        let late = GroupPreview.untaggedUntil.addingTimeInterval(3600)
        #expect(!preview(renewed, group: group, by: owner, made: late, slot: nil).verified(by: code, now: late.addingTimeInterval(60)),
                "and not at all once they're gone")
        var stripped = preview(renewed, group: group, by: owner, made: soon, slot: JoinSlot.tag(renewed.secret))
        stripped.slot = nil
        stripped.slotSignature = nil
        #expect(!stripped.verified(by: code, now: soon.addingTimeInterval(5 * 86_400)), "a tag taken off leaves it short-lived")
    }

    /// A preview as an app from before this reads it: without `slot` or `slotSignature`, and checking `signature` over
    /// what it knows, the way it always has.
    private struct OldPreview: Codable {
        var group: UUID
        var link: UUID
        var title: String
        var about: String?
        var avatar: Data?
        var members: Int
        var approval: Bool
        var expires: Date?
        var requestKey: Data
        var mailbox: Data
        var owner: Data
        var admins: [Data]
        var made: Date
        var signer = Data()
        var signature = Data()

        func signatureIsValid() -> Bool {
            var copy = self
            copy.signature = Data()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dataEncodingStrategy = .base64
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let body = try? encoder.encode(copy), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signer) else { return false }
            return key.isValidSignature(signature, for: Data("pulshade.group.preview.v2".utf8) + body)
        }
    }

    /// Friends on older builds still open links: the preview's own signature is over what their app knows. And the tag
    /// for the link secret can't be dropped or swapped without its second signature failing on this one.
    @Test func olderAppsStillTakeAPreviewWithATag() throws {
        let group = UUID()
        let owner = GroupMemberKeys(seed: .random(32), group: group)
        let (link, _) = try #require(JoinLink.make(label: "", approval: false, expires: nil, limit: nil, creator: owner.publicKey))
        let code = link.code(owner: owner.publicKey)
        let fresh = preview(link, group: group, by: owner, slot: JoinSlot.tag(link.secret))
        #expect(fresh.slotSignature != nil && fresh.verified(by: code))
        let old = try JSONDecoder.pulshade.decode(OldPreview.self, from: JSONEncoder.pulshade.encode(fresh))
        #expect(old.signatureIsValid(), "an app from before checks it as it always has")

        var unsigned = fresh
        unsigned.slotSignature = nil
        #expect(!unsigned.verified(by: code), "a tag without its signature")
        var swapped = fresh
        swapped.slot = JoinSlot.tag(.random(32))
        #expect(!swapped.verified(by: code), "a tag put in by someone else")
    }

    /// A link is fetched for a preview only once it's whole: pasted, or typed with something after it.
    @Test func aLinkStillBeingTypedIsNotFinished() {
        #expect(!LinkPreviews.linkIsFinished(in: "look https://exa"))
        #expect(!LinkPreviews.linkIsFinished(in: "https://example.com/page"))
        #expect(LinkPreviews.linkIsFinished(in: "https://example.com/page "))
        #expect(LinkPreviews.linkIsFinished(in: "https://example.com\nmore"))
        #expect(!LinkPreviews.linkIsFinished(in: "no link here "))
        #expect(!LinkPreviews.linkIsFinished(in: "https://www.example."), "a full stop straight after is still typing")
    }
}

/// The same fixes end to end through a real relay (see scripts/test.sh).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct LinkAuditFixFlowTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-linkfix")
        model.acceptsInvitesForTests = false
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func until(_ models: [AppModel], seconds: Double = 20, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnceFully() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func settle(_ models: AppModel..., rounds: Int = 6) async {
        for _ in 0..<rounds { for m in models { await m.syncOnceFully() } }
    }

    /// `a` adds `b` as a friend, and both have a chat that works both ways.
    private func befriend(_ a: AppModel, _ b: AppModel) async throws -> (aSeesB: String, bSeesA: String) {
        let aName = a.data.profile.name, bName = b.data.profile.name
        _ = try #require(b.addContact(code: a.makeInviteCode(), nickname: ""))
        // Both sides, not only the first: under load the second can be a sync behind.
        await until([a, b]) { a.visibleContacts.contains { $0.name == bName } && b.visibleContacts.contains { $0.name == aName } }
        let bFP = try #require(a.visibleContacts.first { $0.name == bName }).fingerprint
        let aFP = try #require(b.visibleContacts.first { $0.name == aName }).fingerprint
        let chat = a.startConversation(kind: .direct, title: "", members: [bFP])
        a.send("hi", in: chat.id)
        await until([a, b]) { b.data.conversations.contains { $0.kind == .direct && $0.messages.contains { $0.text == "hi" } } }
        if let theirs = b.data.conversations.first(where: { $0.kind == .direct }) { b.send("hey", in: theirs.id) }
        await until([a, b]) { a.conversation(chat.id)?.messages.contains { $0.text == "hey" } == true }
        return (bFP, aFP)
    }

    /// SEC-008: a follower forwarding a channel's invite to their own friend gets nowhere: the invite carries a staff
    /// member's word for the account that sent it (`StaffVouch`), and a forwarded one names someone else, or nobody. The
    /// friend joins nothing, is asked nothing, and the follower never becomes the one the channel is followed through.
    @Test func aForwardedChannelInviteIsRefused() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob"), dave = try await makeUser("Dave")
        defer { for m in [alice, bob, dave] { m.lock() } }
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [])
        _ = try #require(bob.addContact(code: alice.makeInviteCode(channel: channel.id), nickname: ""))
        await until([alice, bob]) { bob.conversation(channel.id)?.shared != nil }
        #expect(bob.conversation(channel.id)?.shared != nil, "following through the code is taken without asking")
        #expect(bob.data.groupOffers.isEmpty)

        let (_, daveSeesBob) = try await befriend(bob, dave)
        let daveFP = try #require(bob.visibleContacts.first { $0.name == "Dave" })
        let held = try #require(bob.conversation(channel.id)?.shared)
        // Alice's own word, as her invites carry it, forwarded by Bob: it names Alice's account, not Bob's.
        let real = try #require(alice.vouchedInviteForTests(channel.id, code: nil))
        #expect(real.vouch != nil)
        bob.sendForTests(.groupInvite(real), to: daveFP)
        // Bob's own word: he isn't staff.
        var forged = real
        forged.vouch = StaffVouch.make(try #require(bob.memberKeys(nil, group: channel.id)), group: channel.id,
                                       account: try #require(bob.me(nil)).card.signing)
        bob.sendForTests(.groupInvite(forged), to: daveFP)
        // None at all, as an app from before sends.
        bob.sendForTests(.groupInvite(GroupInvite(settings: held.settings, epoch: try #require(held.current))), to: daveFP)
        await until([bob, dave]) { dave.data.conversations.contains { $0.messages.contains { $0.text.contains("too old") } } }
        #expect(dave.conversation(channel.id) == nil && dave.data.groupOffers.isEmpty, "nothing joined, nothing asked")
        #expect(dave.contact(daveSeesBob, in: nil) != nil)
    }

    /// A friend adding you to a group puts it in your invites, not your chats: nothing is joined and no card goes back
    /// until you say yes. Then you're in, as before.
    @Test func aGroupInviteWaitsForAYes() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        let (bobFP, aliceFP) = try await befriend(alice, bob)
        let group = alice.startConversation(kind: .group, title: "Crew", members: [bobFP])
        await until([alice, bob]) { !bob.data.groupOffers.isEmpty }
        #expect(bob.conversation(group.id) == nil, "nothing joined yet")
        let offer = try #require(bob.groupOffers.first)
        #expect(offer.from == aliceFP && offer.title == "Crew")
        await settle(alice, bob)
        #expect(alice.conversation(group.id)?.shared?.settings.members.count == 1, "no card went back")

        bob.acceptGroupOffer(offer.id)
        await until([alice, bob]) { bob.conversation(group.id)?.shared?.joining == false }
        #expect(bob.conversation(group.id)?.shared?.joining == false, "in, once he said yes")
        alice.send("welcome", in: group.id)
        await until([alice, bob]) { bob.conversation(group.id)?.messages.contains { $0.text == "welcome" } == true }
        #expect(bob.conversation(group.id)?.messages.contains { $0.text == "welcome" } == true)
    }

    /// Following a friend's own channel leaves the friend as they were: the same devices, the same mailbox and a chat
    /// that still works both ways.
    @Test func followingAFriendsChannelKeepsTheFriendship() async throws {
        let alice = try await makeUser("Alice"), cara = try await makeUser("Cara")
        defer { for m in [alice, cara] { m.lock() } }
        let (caraFP, aliceFP) = try await befriend(alice, cara)
        let before = try #require(cara.contact(aliceFP, in: nil))
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [])
        _ = try #require(cara.addContact(code: alice.makeInviteCode(channel: channel.id), nickname: ""))
        await until([alice, cara], seconds: 30) { alice.conversation(channel.id)?.shared?.roster?.live.count == 1 }
        alice.send("first drop", in: channel.id)
        await until([alice, cara], seconds: 30) { cara.conversation(channel.id)?.messages.last?.text == "first drop" }
        #expect(cara.conversation(channel.id)?.messages.last?.text == "first drop", "she follows")
        let after = try #require(cara.contact(aliceFP, in: nil))
        #expect(after.receiveKey == before.receiveKey && after.devices.map(\.sendID) == before.devices.map(\.sendID))
        #expect(!after.hidden && after.nickname == before.nickname)

        let chat = try #require(alice.data.conversations.first { $0.kind == .direct && $0.members == [caraFP] })
        alice.send("still here?", in: chat.id)
        await until([alice, cara]) { cara.data.conversations.contains { $0.kind == .direct && $0.messages.contains { $0.text == "still here?" } } }
        let theirs = try #require(cara.data.conversations.first { $0.kind == .direct })
        cara.send("yes", in: theirs.id)
        await until([alice, cara]) { alice.conversation(chat.id)?.messages.contains { $0.text == "yes" } == true }
        #expect(alice.conversation(chat.id)?.messages.contains { $0.text == "yes" } == true, "the chat works both ways")

        // Following her code let one channel in without asking; the next one from Alice waits for a yes.
        let next = alice.startConversation(kind: .channel, title: "More", members: [caraFP])
        await until([alice, cara]) { !cara.data.groupOffers.isEmpty }
        #expect(cara.conversation(next.id) == nil && cara.groupOffers.first?.title == "More")
    }

    /// Strangers saying hello on a channel's code are kept without their pictures, and only up to a limit per channel.
    /// Past it, the one who said hello first and never got in makes way: throwaway accounts that never answer their
    /// invite can't keep newcomers out.
    @Test func strangersOnAChannelCodeAreCapped() async throws {
        let alice = try await makeUser("Alice")
        alice.maxCodeStrangers = 2
        var strangers: [AppModel] = []
        defer { for m in [alice] + strangers { m.lock() } }
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [])
        let code = alice.makeInviteCode(channel: channel.id)
        var seen: [String] = []
        for n in 0..<3 {
            let s = try await makeUser("S\(n)")
            s.updateProfile { $0.avatar = Data(repeating: 7, count: 20_000) }
            _ = try #require(s.addContact(code: code, nickname: ""))
            strangers.append(s)
            // Each says hello once and then never answers the invite that comes back.
            await s.syncOnce()
            await until([alice]) { alice.data.contacts.filter { $0.viaCode == channel.id }.count > seen.count || seen.count == 2 }
            await alice.syncOnce()
            let now = alice.data.contacts.filter { $0.viaCode == channel.id }
            #expect(now.allSatisfy { $0.avatar == nil && $0.hidden }, "no pictures kept")
            seen = now.map(\.fingerprint)
        }
        let kept = alice.data.contacts.filter { $0.viaCode == channel.id }
        #expect(kept.count == 2, "never more than the limit")
        #expect(kept.contains { $0.name == "S2" } && !kept.contains { $0.name == "S0" }, "the newest is in, the first who never answered made way")
    }

    /// Someone who said hello on your channel's code, and whose own channel you then follow, is someone you depend on:
    /// never let go as a stranger, or their channel would stop opening.
    @Test func aStrangerWhoseChannelYouFollowIsKept() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob")
        alice.channelAdmitsPerHour = 0
        defer { for m in [alice, bob] { m.lock() } }
        let mine = alice.startConversation(kind: .channel, title: "Drops", members: [])
        _ = try #require(bob.addContact(code: alice.makeInviteCode(channel: mine.id), nickname: ""))
        await until([alice, bob]) { alice.data.contacts.contains { $0.viaCode == mine.id } }
        let stranger = try #require(alice.data.contacts.first { $0.viaCode == mine.id })
        let theirs = bob.startConversation(kind: .channel, title: "Bob's", members: [])
        _ = try #require(alice.addContact(code: bob.makeInviteCode(channel: theirs.id), nickname: ""))
        await until([alice, bob]) { alice.conversation(theirs.id)?.shared != nil }
        #expect(alice.conversation(theirs.id)?.shared?.ownerAccount == stranger.fingerprint)
        #expect(alice.contact(stranger.fingerprint, in: nil)?.viaCode == nil, "no longer a stranger from the code")
    }

    /// Following a code lets in only that code's channel without asking. Another channel of the same person's, sent
    /// while the follow is fresh, isn't taken: with another code's tag it isn't even asked about, and with the followed
    /// code's own tag (the code names Drops, not it) it waits for a yes. A code from an older app names no channel, and an
    /// invite with no tag can't say which code it's for: both are asked about by the channel's name.
    @Test func aFollowedCodeOnlyLetsItsOwnChannelIn() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob"), cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        let drops = alice.startConversation(kind: .channel, title: "Drops", members: [])
        let other = alice.startConversation(kind: .channel, title: "Other", members: [])
        let otherCode = try #require(Invite(code: alice.makeInviteCode(channel: other.id)))
        let dropsCode = try #require(Invite(code: alice.makeInviteCode(channel: drops.id)))
        #expect(dropsCode.channel == Invite.channelCommit(drops.id) && otherCode.channel == Invite.channelCommit(other.id))
        let aliceOnBob = try #require(bob.addContact(code: dropsCode.code, nickname: ""))
        #expect(aliceOnBob.hidden)

        // Alice's other channel, before her app has even read Bob's hello: not taken, not even asked about.
        bob.acceptGroupInvite(try #require(alice.vouchedInviteForTests(other.id, code: otherCode.codeTag)), from: aliceOnBob)
        #expect(bob.conversation(other.id) == nil && bob.data.groupOffers.isEmpty, "not the channel he followed")
        // Nor with the tag of the code he did follow: that code names Drops. Asked about instead.
        bob.acceptGroupInvite(try #require(alice.vouchedInviteForTests(other.id, code: dropsCode.codeTag)), from: aliceOnBob)
        #expect(bob.conversation(other.id) == nil && bob.groupOffers.map(\.title) == ["Other"], "asked, not taken")
        bob.declineGroupOffer(try #require(bob.groupOffers.first).id)

        // A code from an older app names no channel: its channel's invite, tag and all, is asked about by name.
        let third = cara.startConversation(kind: .channel, title: "Third", members: [])
        let newCode = try #require(Invite(code: cara.makeInviteCode(channel: third.id)))
        let oldCode = try Invite(kind: .channel, identity: try #require(cara.identity), sendID: newCode.sendID, relay: newCode.relay)
        #expect(oldCode.channel == nil && Invite(code: oldCode.code)?.channel == nil)
        let caraOnBob = try #require(bob.addContact(code: oldCode.code, nickname: ""))
        bob.acceptGroupInvite(try #require(cara.vouchedInviteForTests(third.id, code: oldCode.codeTag)), from: caraOnBob)
        #expect(bob.conversation(third.id) == nil && bob.groupOffers.first?.title == "Third", "asked, by the channel's name")
        bob.acceptGroupOffer(try #require(bob.groupOffers.first).id)
        #expect(bob.conversation(third.id)?.shared != nil, "in, once he said yes")

        // The channel he followed comes in without asking, as Alice's app lets him in.
        await until([alice, bob, cara], seconds: 30) { bob.conversation(drops.id)?.shared != nil }
        #expect(bob.conversation(drops.id)?.shared != nil && bob.data.groupOffers.isEmpty, "his follow lets Drops in")
        #expect(bob.conversation(other.id) == nil, "and only Drops")
    }

    /// Two of one person's codes followed, and an invite that carries no tag: it is asked about and uses no follow up, so
    /// the other code's channel still comes in without asking. A tag that isn't one is ignored.
    @Test func anUntaggedInviteDoesntUseUpAnotherCodesFollow() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        let a = alice.startConversation(kind: .channel, title: "A", members: [])
        let b = alice.startConversation(kind: .channel, title: "B", members: [])
        _ = try #require(bob.addContact(code: alice.makeInviteCode(channel: a.id), nickname: ""))
        let codeB = try #require(Invite(code: alice.makeInviteCode(channel: b.id)))
        let aliceOnBob = try #require(bob.addContact(code: codeB.code, nickname: ""))

        bob.acceptGroupInvite(try #require(alice.vouchedInviteForTests(a.id, code: nil)), from: aliceOnBob)
        #expect(bob.conversation(a.id) == nil && bob.groupOffers.map(\.title) == ["A"], "asked about")
        bob.acceptGroupInvite(try #require(alice.vouchedInviteForTests(b.id, code: Data(codeB.codeTag.prefix(8)))), from: aliceOnBob)
        #expect(bob.conversation(b.id) == nil, "a cut-short tag is no tag of B's")
        bob.acceptGroupInvite(try #require(alice.vouchedInviteForTests(b.id, code: codeB.codeTag)), from: aliceOnBob)
        #expect(bob.conversation(b.id)?.shared != nil, "B's own invite still comes in without asking")
    }

    /// Two channels of the same stranger followed through their codes, one after the other: both let you in, and
    /// both keep working.
    @Test func followingTwoCodesOfOneStrangerLetsBothIn() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        let a = alice.startConversation(kind: .channel, title: "A", members: [])
        let b = alice.startConversation(kind: .channel, title: "B", members: [])
        _ = try #require(bob.addContact(code: alice.makeInviteCode(channel: a.id), nickname: ""))
        await until([alice, bob], seconds: 30) { bob.conversation(a.id)?.shared != nil }
        #expect(bob.conversation(a.id)?.shared != nil, "follows A")
        _ = try #require(bob.addContact(code: alice.makeInviteCode(channel: b.id), nickname: ""))
        await until([alice, bob], seconds: 30) { bob.conversation(b.id)?.shared != nil }
        #expect(bob.conversation(b.id)?.shared != nil, "follows B too")
        alice.send("in A", in: a.id)
        alice.send("in B", in: b.id)
        await until([alice, bob], seconds: 30) {
            bob.conversation(a.id)?.messages.last?.text == "in A" && bob.conversation(b.id)?.messages.last?.text == "in B"
        }
        #expect(bob.conversation(a.id)?.messages.last?.text == "in A", "A still works")
        #expect(bob.conversation(b.id)?.messages.last?.text == "in B", "B works")
    }

    /// The same, with both codes followed before Alice's app has read either hello.
    @Test func followingTwoCodesOfOneStrangerAtOnceLetsBothIn() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        let a = alice.startConversation(kind: .channel, title: "A", members: [])
        let b = alice.startConversation(kind: .channel, title: "B", members: [])
        _ = try #require(bob.addContact(code: alice.makeInviteCode(channel: a.id), nickname: ""))
        _ = try #require(bob.addContact(code: alice.makeInviteCode(channel: b.id), nickname: ""))
        await until([alice, bob], seconds: 30) { bob.conversation(a.id)?.shared != nil && bob.conversation(b.id)?.shared != nil }
        #expect(bob.conversation(a.id)?.shared != nil, "follows A")
        #expect(bob.conversation(b.id)?.shared != nil, "follows B")
    }

    /// A new channel from someone known only through a channel's code is dropped: no channel, no invite, no banner.
    @Test func aHiddenContactCantSendChannelInvites() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [])
        _ = try #require(bob.addContact(code: alice.makeInviteCode(channel: channel.id), nickname: ""))
        await until([alice, bob]) { bob.conversation(channel.id)?.shared != nil }
        let other = alice.startConversation(kind: .channel, title: "Other", members: [])
        let bobOnAlice = try #require(alice.data.contacts.first { $0.name == "Bob" })
        let held = try #require(alice.conversation(other.id)?.shared)
        alice.sendForTests(.groupInvite(GroupInvite(settings: held.settings, epoch: try #require(held.current))), to: bobOnAlice)
        await settle(alice, bob)
        #expect(bob.conversation(other.id) == nil && bob.data.groupOffers.isEmpty, "dropped")
    }
}
