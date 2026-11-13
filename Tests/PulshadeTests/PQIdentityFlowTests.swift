import Testing
import Foundation
@testable import Pulshade

/// Post-quantum identity keys through a real relay: two accounts pin each other's keys, everything after the first
/// envelope is version 3, accounts and chats from before the keys existed move over in place, and an old app is refused.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct PQIdentityFlowTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func settle(_ models: AppModel..., rounds: Int = 6) async {
        for _ in 0..<rounds { for m in models { await m.syncOnce() } }
    }

    private func connected() async throws -> (alice: AppModel, bob: AppModel) {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)
        return (alice, bob)
    }

    @Test func newAccountsPinEachOthersKeysAndOnlyTheIntroductionIsClassical() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        final class Seen: @unchecked Sendable { var alice: [UInt8] = [], bob: [UInt8] = [] }
        let seen = Seen()
        alice.envelopeTap = { seen.alice.append($0.blob.first ?? 0) }
        bob.envelopeTap = { seen.bob.append($0.blob.first ?? 0) }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob)

        let aliceID = try #require(alice.me(nil)), bobID = try #require(bob.me(nil))
        #expect(alice.contact(bob.fingerprint)?.name == "Bob" && bob.contact(alice.fingerprint)?.name == "Alice", "profiles arrive")
        #expect(alice.contact(bob.fingerprint)?.pq == bobID.pq.pin)
        #expect(bob.contact(alice.fingerprint)?.pq == aliceID.pq.pin)
        // Alice got Bob's hello in a classical envelope (the invite carries no post-quantum key to seal to); everything
        // else, both ways, is version 3.
        #expect(seen.alice.filter { $0 == 2 }.count == 1 && seen.alice.first == 2)
        #expect(seen.bob.allSatisfy { $0 == 3 } && !seen.bob.isEmpty)
        #expect(seen.alice.dropFirst().allSatisfy { $0 == 3 })

        let chat = alice.startConversation(kind: .direct, title: "", members: [bob.fingerprint])
        alice.send("hey bob", in: chat.id)
        await settle(alice, bob)
        #expect(bob.data.conversations.first { $0.kind == .direct }?.messages.map(\.text) == ["hey bob"])
        #expect(alice.conversation(chat.id)?.messages.first?.status == .delivered)
        #expect(seen.bob.allSatisfy { $0 == 3 })
    }

    @Test func contactsFromBeforeTheKeysMoveOverWithTheirChatsIntact() async throws {
        let (alice, bob) = try await connected()
        defer { for m in [alice, bob] { m.lock() } }
        let chat = alice.startConversation(kind: .direct, title: "", members: [bob.fingerprint])
        alice.send("before the update", in: chat.id)
        await settle(alice, bob)
        let aliceKeys = try #require(alice.contact(bob.fingerprint)).agreementKey
        let ids = (alice.fingerprint, bob.fingerprint)

        // Both sides as an older app left them: sessions and chats there, no post-quantum keys known, none sent.
        for m in [alice, bob] {
            for i in m.data.contacts.indices { m.data.contacts[i].pq = nil; m.data.contacts[i].pqCardSent = nil }
        }
        // A message written before they've met again is held, never sent classically (the only classical envelope is the
        // introduction), and not lost.
        let held = Seen2()
        bob.envelopeTap = { held.versions.append($0.blob.first ?? 0) }
        alice.send("while unpinned", in: chat.id)
        #expect(held.versions.isEmpty)
        alice.introducePQToContacts()
        bob.introducePQToContacts()
        await settle(alice, bob, rounds: 10)
        #expect(alice.contact(bob.fingerprint)?.pq == bob.me(nil)?.pq.pin)
        #expect(bob.contact(alice.fingerprint)?.pq == alice.me(nil)?.pq.pin)
        #expect(bob.data.conversations.first { $0.kind == .direct }?.messages.map(\.text) == ["before the update", "while unpinned"])
        #expect(held.versions.filter { $0 == 2 }.count == 1, "one classical envelope (Alice's introduction), and the message came after it")
        // The same accounts and the same contact records, not new ones.
        #expect(alice.fingerprint == ids.0 && bob.fingerprint == ids.1 && alice.visibleContacts.count == 1)
        #expect(alice.contact(bob.fingerprint)?.agreementKey == aliceKeys)
        #expect(alice.conversation(chat.id)?.messages.map(\.text).prefix(2) == ["before the update", "while unpinned"])
        // And from then on it all is version 3.
        let seen = Seen2()
        bob.envelopeTap = { seen.versions.append($0.blob.first ?? 0) }
        alice.send("after", in: chat.id)
        await settle(alice, bob)
        #expect(seen.versions.allSatisfy { $0 == 3 } && !seen.versions.isEmpty)
        #expect(bob.data.conversations.first { $0.kind == .direct }?.messages.last?.text == "after")
    }

    private final class Seen2: @unchecked Sendable { var versions: [UInt8] = [] }

    @Test func aContactWhoseAppIsTooOldIsRefusedByNameAndNothingIsRead() async throws {
        let (alice, bob) = try await connected()
        defer { for m in [alice, bob] { m.lock() } }
        let aliceID = try #require(alice.me(nil)), bobID = try #require(bob.me(nil))
        let mailbox = try #require(alice.contact(bob.fingerprint)?.receiveKey)
        let chat = alice.startConversation(kind: .direct, title: "", members: [bob.fingerprint])
        // A ratchet message as an app from before would seal it: classical envelope.
        let old = try EnvelopeCore.seal(body: Payload.typing(conversation: nil).wire(framed: false), framed: false,
                                        signing: bobID.signingKey, agreement: bobID.agreementKey, device: Data(), caps: 127, at: Date(),
                                        to: aliceID.card.agreement)
        #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: 901, blob: old)) == .junk)
        #expect(alice.contact(bob.fingerprint)?.tooOld != nil)
        let said = alice.conversation(chat.id)?.messages.map(\.text) ?? []
        #expect(said.contains { $0.contains("Bob") && $0.contains("update Pulshade") })
        // Told once, not again for each envelope.
        #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: 902, blob: old)) == .junk)
        #expect(alice.conversation(chat.id)?.messages.filter { $0.text.contains("update Pulshade") }.count == 1)

        // A real post-quantum envelope from them clears it.
        let bobChat = bob.startConversation(kind: .direct, title: "", members: [alice.fingerprint])
        bob.send("hello again", in: bobChat.id)
        for _ in 0..<10 where alice.contact(bob.fingerprint)?.tooOld != nil { await settle(alice, bob, rounds: 2) }
        #expect(alice.contact(bob.fingerprint)?.tooOld == nil)
    }

    @Test func aPinnedContactCannotBeDowngradedToClassical() async throws {
        let (alice, bob) = try await connected()
        defer { for m in [alice, bob] { m.lock() } }
        let aliceID = try #require(alice.me(nil)), bobID = try #require(bob.me(nil))
        let mailbox = try #require(alice.contact(bob.fingerprint)?.receiveKey)
        let pinned = try #require(alice.contact(bob.fingerprint)?.pq)
        // Someone who broke X25519 and Ed25519 and holds Bob's classical keys forges an erase notice in a classical envelope.
        let erase = try EnvelopeCore.seal(body: Payload.erased.wire(framed: false), framed: false, signing: bobID.signingKey,
                                          agreement: bobID.agreementKey, device: Data(), caps: 127, at: Date(), to: aliceID.card.agreement)
        #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: 950, blob: erase)) == .junk)
        // A classical introduction naming the pinned keys changes nothing but being answered; one naming other keys is junk.
        let intro = try EnvelopeCore.seal(body: Payload.pqIntro(bobID.pqCard).wire(framed: false), framed: false, signing: bobID.signingKey,
                                          agreement: bobID.agreementKey, device: Data(), caps: 127, at: Date(), to: aliceID.card.agreement)
        #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: 952, blob: intro)) == .handled)
        #expect(alice.contact(bob.fingerprint)?.pq == pinned)
        let other = try EnvelopeCore.seal(body: Payload.pqIntro(Identity.generate().pqCard).wire(framed: false), framed: false, signing: bobID.signingKey,
                                          agreement: bobID.agreementKey, device: Data(), caps: 127, at: Date(), to: aliceID.card.agreement)
        #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: 953, blob: other)) == .junk)
        // And a version 3 erase notice signed with keys that aren't Bob's ML-DSA key.
        let forger = Identity.generate()
        let v3 = try EnvelopeCore.sealPQ(body: Payload.erased.wire(framed: false), signing: bobID.signingKey, agreement: bobID.agreementKey,
                                         pq: forger.pq, sign: true, introduce: true, device: Data(), caps: 255, at: Date(), to: aliceID.recipient)
        #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: 951, blob: v3)) == .junk)
        #expect(alice.contact(bob.fingerprint) != nil, "Bob was not erased")
        #expect(alice.contact(bob.fingerprint)?.pq == pinned, "and the pin is unchanged")
    }

    @Test func theKeysSurviveLockingRecoveryAndTheBackup() async throws {
        let alice = try await makeUser("Alice")
        defer { alice.lock() }
        let me = try #require(alice.me(nil))
        let seed = me.seed
        let recovered = try Identity(seed: seed)
        #expect(recovered.pq.pin == me.pq.pin && recovered.fingerprint == me.fingerprint)
        // A contact's pin travels in the backup that recovery restores.
        var contact = Contact(fingerprint: "ab", name: "X", signingKey: Data(count: 32), agreementKey: Data(count: 32), sendID: Data(count: 32))
        contact.pq = me.pq.pin
        let encoded = try JSONEncoder.pulshade.encode(contact)
        #expect(try JSONDecoder.pulshade.decode(Contact.self, from: encoded).pq == me.pq.pin)
    }

    private func classicalEnvelope(_ payload: Payload, from sender: Identity, to receiver: Identity, at date: Date) throws -> Data {
        try EnvelopeCore.seal(body: payload.wire(framed: false), framed: false, signing: sender.signingKey, agreement: sender.agreementKey,
                              device: Data(), caps: 127, at: date, to: receiver.card.agreement)
    }

    /// SEC-202: an old classical envelope, replayed, says nothing about the sender's app.
    @Test func aReplayedOldClassicalEnvelopeDoesNotMarkAFriendAsTooOld() async throws {
        let (alice, bob) = try await connected()
        defer { for m in [alice, bob] { m.lock() } }
        let aliceID = try #require(alice.me(nil)), bobID = try #require(bob.me(nil))
        let mailbox = try #require(alice.contact(bob.fingerprint)?.receiveKey)
        let chat = alice.startConversation(kind: .direct, title: "", members: [bob.fingerprint])
        let before = alice.conversation(chat.id)?.messages.count ?? 0
        let ancient = Date().addingTimeInterval(-AppModel.replayWindow - 3600)
        let old = try classicalEnvelope(Payload.typing(conversation: nil), from: bobID, to: aliceID, at: ancient)
        #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: 1001, blob: old)) == .junk)
        #expect(alice.contact(bob.fingerprint)?.tooOld == nil, "an old one is dropped")
        #expect(alice.conversation(chat.id)?.messages.count == before)
        // The same kind of envelope made now is still refused by name.
        let fresh = try classicalEnvelope(Payload.typing(conversation: nil), from: bobID, to: aliceID, at: Date())
        #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: 1002, blob: fresh)) == .junk)
        #expect(alice.contact(bob.fingerprint)?.tooOld != nil)
    }

    /// SEC-202: a replayed classical introduction is not answered again, and answers are spaced out per contact.
    @Test func aReplayedClassicalIntroductionIsAnsweredAtMostOncePerContactForAWhile() async throws {
        let (alice, bob) = try await connected()
        defer { for m in [alice, bob] { m.lock() } }
        let aliceID = try #require(alice.me(nil)), bobID = try #require(bob.me(nil))
        let mailbox = try #require(alice.contact(bob.fingerprint)?.receiveKey)
        await settle(alice, bob)
        let ancient = Date().addingTimeInterval(-AppModel.replayWindow - 3600)
        let stale = try classicalEnvelope(.pqIntro(bobID.pqCard), from: bobID, to: aliceID, at: ancient)
        var outbox = alice.data.outbox.count
        #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: 1010, blob: stale)) == .junk, "too old to act on")
        #expect(alice.data.outbox.count == outbox)

        let intro = try classicalEnvelope(.pqIntro(bobID.pqCard), from: bobID, to: aliceID, at: Date())
        #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: 1011, blob: intro)) == .handled)
        #expect(alice.data.outbox.count == outbox + 1, "the first one is answered")
        outbox = alice.data.outbox.count
        // The very same envelope again (the relay, or a copy someone kept): counted once.
        for id in 1012...1016 { #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: UInt64(id), blob: intro)) == .junk) }
        #expect(alice.data.outbox.count == outbox)
        // A different fresh one straight after: handled, but not answered again.
        let another = try classicalEnvelope(.pqIntro(bobID.pqCard), from: bobID, to: aliceID, at: Date().addingTimeInterval(-5))
        #expect(alice.receive(RelayEnvelope(receiveKey: mailbox, id: 1020, blob: another)) == .handled)
        #expect(alice.data.outbox.count == outbox, "answers are spaced out")
    }

    /// SEC-205: the first card from someone who made the invite you used is held to the invite's commitment.
    @Test func theFirstCardIsHeldToWhatTheInviteCommittedTo() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        let aliceID = try #require(alice.me(nil)), bobID = try #require(bob.me(nil))
        let contact = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        #expect(contact.pqCommit == aliceID.pq.pin.commitment && contact.pq == nil)
        let mailbox = try #require(bob.contact(alice.fingerprint)?.receiveKey)
        // Alice's classical keys (as someone who broke them would have) with post-quantum keys of the attacker's own, in an
        // introduction whose card both of those keys signed: valid in every way but the invite's commitment.
        let attacker = Identity.generate()
        let forgedCard = try PQCard.make(signing: aliceID.signingKey, agreement: aliceID.card.agreement, keys: attacker.pq)
        let forged = try EnvelopeCore.sealPQ(body: Payload.pqIntro(forgedCard).wire(framed: false), signing: aliceID.signingKey,
                                             agreement: aliceID.agreementKey, pq: attacker.pq, sign: true, introduce: true, device: Data(),
                                             caps: 255, at: Date(), to: bobID.recipient)
        #expect(bob.receive(RelayEnvelope(receiveKey: mailbox, id: 2001, blob: forged)) == .junk)
        #expect(bob.contact(alice.fingerprint)?.pq == nil, "nothing is pinned that the invite didn't commit to")
        // The real thing still goes through.
        await settle(alice, bob)
        #expect(bob.contact(alice.fingerprint)?.pq == aliceID.pq.pin)
        #expect(alice.contact(bob.fingerprint)?.pq == bobID.pq.pin)
    }

    /// An invite for a signing key whose post-quantum keys are already pinned must commit to those same keys.
    @Test func anInviteThatContradictsKeysAlreadyPinnedIsRefused() async throws {
        let (alice, bob) = try await connected()
        defer { for m in [alice, bob] { m.lock() } }
        let aliceID = try #require(alice.me(nil))
        let other = Identity.generate()
        let wrong = Invite(kind: .channel, signingKey: aliceID.card.signing, agreementKey: aliceID.card.agreement,
                           bind: try aliceID.signingKey.signature(for: Invite.bindMessage(agreement: aliceID.card.agreement, pqHash: other.pq.pin.commitment)),
                           pqHash: other.pq.pin.commitment, sendID: Mailbox.make().sendID)
        #expect(bob.addContact(code: wrong.code, nickname: "") == nil)
        #expect(bob.contact(alice.fingerprint)?.pq == aliceID.pq.pin)
    }
}
