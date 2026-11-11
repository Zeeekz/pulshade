import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// Join links for groups that share one mailbox, end to end through a real relay (see scripts/test.sh): someone nobody in
/// the group knows reads a link's preview, asks, and is let in (or waits for a yes, or is turned down).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct JoinLinkFlowTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-joinlink")
        model.sharedGroupsEnabled = true
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func settle(_ models: AppModel..., rounds: Int = 6) async {
        for _ in 0..<rounds { for m in models { await m.syncOnce() } }
    }

    /// Syncs and reads join mailboxes until `done`, or for `seconds`.
    private func until(_ models: [AppModel], seconds: Double = 20, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models {
                await m.syncOnce()
                m.tendJoinLinks(force: true)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func preview(_ who: AppModel, _ code: GroupLinkCode) async -> GroupPreview? {
        for _ in 0..<40 {
            if let found = await who.previewGroup(code) { return found }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    /// Alice owns a shared group with Bob in it; Dana knows neither.
    private func group() async throws -> (AppModel, AppModel, AppModel, Conversation) {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob"), dana = try await makeUser("Dana")
        let b = try #require(alice.addContact(code: bob.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        let chat = alice.startConversation(kind: .direct, title: "", members: [b.fingerprint])
        alice.send("hi", in: chat.id)
        await settle(alice, bob)
        if let back = bob.data.conversations.first(where: { $0.kind == .direct }) { bob.send("hey", in: back.id) }
        await settle(alice, bob)
        let group = alice.startConversation(kind: .group, title: "Night owls", members: [b.fingerprint])
        #expect(group.shared != nil)
        await until([alice, bob]) { bob.conversation(group.id)?.shared?.joining == false }
        return (alice, bob, dana, group)
    }

    @Test func someoneWithAnOpenLinkSeesThePreviewJoinsAndTalks() async throws {
        let (alice, bob, dana, group) = try await group()
        defer { for m in [alice, bob, dana] { m.lock() } }
        bob.send("before dana", in: group.id)
        await until([alice, bob]) { alice.conversation(group.id)?.messages.contains { $0.text == "before dana" } == true }

        let link = try #require(alice.makeJoinLink(in: group.id, label: "Friends", approval: false))
        await until([alice, bob]) { bob.joinLinks(group.id)?.links.count == 1 }
        #expect(bob.joinLinks(group.id)?.link(link.id) == link, "every member holds the links")
        #expect(bob.makeJoinLink(in: group.id, label: "Mine", approval: false) == nil, "only admins make links")

        let code = try #require(GroupLinkCode(link.code.link))
        let seen = try #require(await preview(dana, code))
        #expect(seen.title == "Night owls" && seen.members == 2 && !seen.approval)

        dana.askToJoin(seen, persona: nil)
        await until([alice, bob, dana]) {
            dana.conversation(group.id)?.shared?.joining == false && bob.conversation(group.id)?.members.count == 2
        }
        let danaGroup = try #require(dana.conversation(group.id))
        #expect(danaGroup.members.count == 2 && danaGroup.title == "Night owls")
        #expect(dana.data.joinAsks.isEmpty, "answered")
        #expect(!danaGroup.messages.contains { $0.text == "before dana" }, "a newcomer can't read what was said before")
        #expect(alice.joinLinks(group.id)?.link(link.id)?.used == 1)
        // Nobody learnt anyone's account: Dana is known to the group by a key made for it.
        let danaForBob = try #require(bob.data.contacts.first { $0.name == "Dana" })
        #expect(danaForBob.hidden && danaForBob.signingKey != dana.identity?.signingKey.publicKey.rawRepresentation)

        dana.send("hi all", in: group.id)
        await until([alice, bob, dana]) { bob.conversation(group.id)?.messages.contains { $0.text == "hi all" } == true }
        #expect(bob.conversation(group.id)?.messages.contains { $0.text == "hi all" } == true)
        bob.send("welcome", in: group.id)
        await until([alice, bob, dana]) { dana.conversation(group.id)?.messages.contains { $0.text == "welcome" } == true }
        #expect(dana.conversation(group.id)?.messages.contains { $0.text == "welcome" } == true)
    }

    @Test func aLinkThatNeedsApprovalWaitsForAnAdmin() async throws {
        let (alice, bob, dana, group) = try await group()
        let erin = try await makeUser("Erin")
        defer { for m in [alice, bob, dana, erin] { m.lock() } }
        let link = try #require(alice.makeJoinLink(in: group.id, label: "", approval: true))
        let seen = try #require(await preview(dana, link.code))
        #expect(seen.approval)

        dana.askToJoin(seen, note: "Bob told me about it", persona: nil)
        erin.askToJoin(try #require(await preview(erin, link.code)), persona: nil)
        await until([alice, dana, erin]) { alice.heldJoins(group.id).count == 2 }
        let held = alice.heldJoins(group.id)
        #expect(held.count == 2)
        #expect(held.first { $0.request.card.name == "Dana" }?.request.note == "Bob told me about it")
        #expect(dana.conversation(group.id) == nil, "not in until someone says yes")

        let danaKey = try #require(held.first { $0.request.card.name == "Dana" }?.id)
        let erinKey = try #require(held.first { $0.request.card.name == "Erin" }?.id)
        alice.approveJoin(danaKey, in: group.id)
        alice.declineJoin(erinKey, in: group.id)
        await until([alice, bob, dana, erin]) {
            dana.conversation(group.id)?.shared?.joining == false && erin.data.joinAsks.first?.declined == true
        }
        #expect(dana.conversation(group.id)?.shared?.joining == false)
        #expect(erin.data.joinAsks.first?.declined == true && erin.conversation(group.id) == nil)
        await until([alice]) { alice.heldJoins(group.id).isEmpty }
        #expect(alice.heldJoins(group.id).isEmpty, "both let go of on the relay")
    }

    @Test func bansUseLimitsAndResetsAreKept() async throws {
        let (alice, bob, dana, group) = try await group()
        let erin = try await makeUser("Erin")
        defer { for m in [alice, bob, dana, erin] { m.lock() } }
        let link = try #require(alice.makeJoinLink(in: group.id, label: "One", approval: false, limit: 1))
        dana.askToJoin(try #require(await preview(dana, link.code)), persona: nil)
        await until([alice, dana]) { dana.conversation(group.id)?.shared?.joining == false }
        #expect(dana.conversation(group.id)?.shared?.joining == false)

        // Used up: the next person is turned down, and the preview stops being offered once it's rewritten.
        erin.askToJoin(try #require(await preview(erin, link.code)), persona: nil)
        await until([alice, erin]) { erin.data.joinAsks.first?.declined == true }
        #expect(erin.data.joinAsks.first?.declined == true)

        // Dana is banned: out, and turned down when she asks again through another link.
        let danaFP = try #require(alice.conversation(group.id)?.members.first { alice.displayName($0) == "Dana" })
        alice.banMember(danaFP, in: group.id)
        await until([alice, bob, dana]) { dana.conversation(group.id)?.shared?.gone == true }
        #expect(dana.conversation(group.id)?.shared?.gone == true)
        let open = try #require(alice.makeJoinLink(in: group.id, label: "Open", approval: false))
        dana.cancelJoinAsk(dana.data.joinAsks.first?.id ?? UUID())
        dana.askToJoin(try #require(await preview(dana, open.code)), persona: nil)
        await until([alice, dana]) { dana.data.joinAsks.first?.declined == true }
        #expect(dana.data.joinAsks.first?.declined == true)
        #expect(alice.conversation(group.id)?.shared?.settings.members.count == 2)

        // Reset: the old link's preview is gone, the new one works.
        alice.resetJoinLink(open.id, in: group.id)
        let fresh = try #require(alice.joinLinks(group.id)?.link(open.id))
        #expect(fresh.secret != open.secret)
        var gone = false
        for _ in 0..<40 where !gone {
            gone = await erin.previewGroup(open.code) == nil
            try? await Task.sleep(for: .milliseconds(150))
        }
        #expect(gone, "the old link stops working")
        #expect(await preview(erin, fresh.code) != nil)
    }
}

/// Links, previews and requests on their own, without a relay.
struct JoinLinkTests {
    @Test func aLinkReadsBackAndOnlyItsMakersPreviewPasses() throws {
        let group = UUID()
        let admin = GroupMemberKeys(seed: .random(32), group: group)
        let other = GroupMemberKeys(seed: .random(32), group: group)
        let link = JoinLink.make(label: "x", approval: false, expires: nil, limit: nil, creator: admin.publicKey)
        let code = try #require(GroupLinkCode(link.code.link))
        #expect(code == link.code)
        #expect(GroupLinkCode("pulshade://invite/abc") == nil && GroupLinkCode(link.code.text) == nil, "only a group link")

        var preview = GroupPreview(group: group, link: link.id, title: "T", about: nil, avatar: nil, members: 3, approval: false,
                                   expires: nil, requestKey: try #require(link.requestPublicKey), mailbox: .random(32), made: wholeSecond(Date()))
        preview.sign(with: admin)
        #expect(preview.verified(by: code))
        var forged = preview
        forged.title = "Something else"
        #expect(!forged.verified(by: code), "changed after signing")
        var impostor = preview
        impostor.sign(with: other)
        #expect(!impostor.verified(by: code), "signed by someone the link doesn't name")

        let slot = try #require(JoinSlot.keys(link.secret))
        let sealed = try #require(JoinSlot.seal(preview, with: slot))
        #expect(sealed.count > 32 * 1024 && sealed.count < 33 * 1024, "every preview one size")
        #expect(JoinSlot.open(sealed, with: slot) == preview)
        let wrong = try #require(JoinSlot.keys(.random(32)))
        #expect(JoinSlot.open(sealed, with: wrong) == nil)
    }

    @Test func aRequestOpensOnlyWithTheLinksKeyAndSaysWhoSealedIt() throws {
        let group = UUID()
        let joiner = GroupMemberKeys(seed: .random(32), group: group)
        let link = JoinLink.make(label: "", approval: true, expires: nil, limit: nil, creator: Data.random(32))
        let card = MemberCard.make(joiner, group: group, name: "Dana", avatar: nil, color: nil)
        let request = JoinRequest(group: group, link: link.id, card: card, reply: .random(32), note: "hi", at: Date())
        let requestKey = try #require(link.requestPublicKey)
        let blob = try #require(JoinSeal.seal(.request(request), from: joiner, to: requestKey))
        let opened = try #require(JoinSeal.open(blob, with: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: link.requestKey)))
        guard case let .request(got) = opened.mail else { Issue.record("not a request"); return }
        #expect(got.card == card && got.note == "hi" && got.reply == request.reply && got.link == link.id)
        #expect(opened.signer == joiner.publicKey && opened.agreement == card.agreementKey)
        #expect(JoinSeal.open(blob, with: Curve25519.KeyAgreement.PrivateKey()) == nil)
    }

    @Test func linksAreSignedAndOnlyWellFormedOnesPass() throws {
        let group = UUID()
        let admin = GroupMemberKeys(seed: .random(32), group: group)
        var links = GroupLinks(group: group, version: 1, links: [.make(label: "a", approval: false, expires: nil, limit: 5, creator: admin.publicKey)])
        links.sign(with: admin)
        #expect(links.signatureIsValid && links.wellFormed)
        var changed = links
        changed.links[0].used = 99
        #expect(!changed.signatureIsValid)
        var tooMany = links
        tooMany.links = (0...GroupLinks.maxLinks).map { _ in .make(label: "", approval: false, expires: nil, limit: nil, creator: admin.publicKey) }
        tooMany.sign(with: admin)
        #expect(!tooMany.wellFormed)
        let used = JoinLink.make(label: "", approval: false, expires: nil, limit: 1, creator: admin.publicKey)
        var full = used
        full.used = 1
        #expect(used.isOpen() && !full.isOpen())
        let late = JoinLink.make(label: "", approval: false, expires: Date().addingTimeInterval(-1), limit: nil, creator: admin.publicKey)
        #expect(!late.isOpen())
    }
}
