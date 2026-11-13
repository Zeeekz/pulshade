import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// What happens to an envelope after it is taken from the relay: what is finished with, what is junk, and what
/// must be left there for another try.
@MainActor
@Suite(.serialized) struct DeliveryTests {
    private func makeModel() async throws -> AppModel {
        let model = testModel("pulshade-delivery")
        try await model.create(identity: .generate(), profile: Profile(name: "Me"), passcode: "test-passcode")
        return model
    }

    private func makeContact(_ them: Identity, device: UInt8) -> Contact {
        Contact(fingerprint: them.fingerprint, name: "Them", signingKey: them.card.signing,
                agreementKey: them.card.agreement, sendID: Mailbox.make().sendID, device: Data([device]))
    }

    /// A mailbox the main persona reads, and a contact with one real device.
    @discardableResult
    private func seed(_ model: AppModel, mailbox: Mailbox) -> (them: Identity, contact: Contact) {
        let them = Identity.generate()
        var contact = Contact(fingerprint: them.fingerprint, name: "Them", signingKey: them.card.signing,
                              agreementKey: them.card.agreement, sendID: Mailbox.make().sendID,
                              receiveKey: mailbox.receiveKey, device: Data([1, 2, 3]))
        contact.persona = nil
        model.data.contacts = [contact]
        return (them, contact)
    }

    private func ratchet() -> Payload {
        .ratchet(RatchetMessage(header: RatchetHeader(dh: .random(32), pn: 0, n: 0),
                                ciphertext: .random(48)))
    }

    @Test func anEnvelopeThatCannotBeOpenedIsJunk() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let mailbox = Mailbox.make()
        seed(model, mailbox: mailbox)
        let envelope = RelayEnvelope(receiveKey: mailbox.receiveKey, id: 1, blob: Data(repeating: 0, count: 128))
        #expect(model.receive(envelope) == .junk)
    }

    @Test func aMessageFromAnUnknownContactIsKeptForLater() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let me = try #require(model.identity)
        let mailbox = Mailbox.make()
        seed(model, mailbox: mailbox)
        let blob = try Envelope.seal(ratchet(), from: Identity.generate(), to: me.recipient)
        let envelope = RelayEnvelope(receiveKey: mailbox.receiveKey, id: 2, blob: blob)
        #expect(model.receive(envelope) == .retry)
    }

    @Test func aMessageFromADeviceWeHaveNotMetIsKeptForLater() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let me = try #require(model.identity)
        let mailbox = Mailbox.make()
        let (them, _) = seed(model, mailbox: mailbox)
        // It names a device the contact doesn't list and there's no blank slot to adopt it into.
        let blob = try Envelope.seal(ratchet(), from: them, device: Data([9, 9]), to: me.recipient)
        let envelope = RelayEnvelope(receiveKey: mailbox.receiveKey, id: 3, blob: blob)
        #expect(model.receive(envelope) == .retry)
    }

    @Test func aHelloCannotClaimADifferentAgreementKey() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let me = try #require(model.identity)
        let mailbox = Mailbox.make()
        model.data.invites = [OpenInvite(receiveKey: mailbox.receiveKey)]
        let them = Identity.generate()
        let (_, request) = try Handshake.start()

        // A card pairing their signing key with a different agreement key is not the pair they proved.
        let bad = PeerCard(name: "Them", avatar: nil, color: nil, signingKey: them.card.signing,
                           agreementKey: .random(32), sendID: Mailbox.make().sendID, pq: them.pqCard)
        let badBlob = try Envelope.sealIntroduction(.hello(bad, request), from: them, to: me.card.agreement)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 1, blob: badBlob)) == .junk)

        // The honest card names the key the envelope was actually sealed with.
        let good = PeerCard(name: "Them", avatar: nil, color: nil, signingKey: them.card.signing,
                            agreementKey: them.card.agreement, sendID: Mailbox.make().sendID, pq: them.pqCard)
        let goodBlob = try Envelope.sealIntroduction(.hello(good, request), from: them, to: me.card.agreement)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 2, blob: goodBlob)) == .handled)
    }

    @Test func aRepairedSessionKeepsItsOldKeysForLateMessages() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let me = try #require(model.identity)
        let mailbox = Mailbox.make()
        let (them, _) = seed(model, mailbox: mailbox)
        // A session this chat was using when the two sides drifted apart.
        let old = Ratchet.receiver(root: SymmetricKey(data: Data.random(32)),
                                   ourRatchet: Curve25519.KeyAgreement.PrivateKey(), ad: Data("test-chat".utf8))
        model.data.contacts[0].devices[0].session = old

        // A message that can't open starts a repair, which must keep the old keys in memory.
        let wire = Payload.ratchet(RatchetMessage(header: RatchetHeader(dh: .random(32), pn: 0, n: 0,
                                                                       v: RatchetHeader.version),
                                                  ciphertext: .random(48)))
        let blob = try Envelope.seal(wire, from: them, device: Data([1, 2, 3]), to: me.recipient)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 9, blob: blob)) == .handled)
        #expect(!model.recoveredSessions.isEmpty, "the old keys are kept so a late message under them still opens")
    }

    /// A friend still on a build from before the sparse post-quantum ratchet: its envelopes don't say bit 7 and its
    /// ratchet messages aren't version 3. Refused, by name, without starting new keys over it.
    @Test func aBuildFromBeforeThePostQuantumRatchetIsRefusedByName() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let me = try #require(model.identity)
        let mailbox = Mailbox.make()
        let (them, contact) = seed(model, mailbox: mailbox)
        let old = Payload.ratchet(RatchetMessage(header: RatchetHeader(dh: .random(32), pn: 0, n: 0), ciphertext: .random(48)))
        // A build that old can only send classical (version 2) envelopes, which are refused outright (and the chat says whose app
        // has to update: see PQIdentityFlowTests). This is the other gate: an envelope that is post-quantum but whose caps lack
        // bit 7, so its device is marked and nothing is sent to it.
        let classical = try EnvelopeCore.seal(body: old.wire(framed: false), framed: false, signing: them.signingKey,
                                              agreement: them.agreementKey, device: Data([1, 2, 3]), caps: 127, at: RelayClock.now,
                                              to: me.card.agreement)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 100, blob: classical)) == .junk)
        let blob = try EnvelopeCore.sealPQ(body: old.wire(framed: false), signing: them.signingKey, agreement: them.agreementKey,
                                           pq: them.pq, sign: false, introduce: true, device: Data([1, 2, 3]), caps: 127,
                                           at: RelayClock.now, to: me.recipient)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 1, blob: blob)) == .handled)
        #expect(model.data.contacts[0].devices[0].needsUpdate == true)
        #expect(model.data.contacts[0].devices[0].handshake == nil, "No new keys are started over it")
        #expect(model.friendsNeedingUpdate(persona: nil) == [contact.fingerprint])
        let chat = model.startConversation(kind: .direct, title: "", members: [contact.fingerprint])
        #expect(model.peerNeedingUpdate(in: chat) == "Them" && !model.canPost(in: chat), "The chat says so and closes the composer")

        // Nothing is sent to it meanwhile: what is said waits.
        model.data.contacts[0].devices[0].session = try Ratchet.sender(
            root: SymmetricKey(data: Data.random(32)), theirRatchet: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            ad: Data("x".utf8))
        let sorted = JSONEncoder()
        sorted.outputFormatting = .sortedKeys   // the keys of a struct otherwise come out in a different order each time
        let before = try sorted.encode(model.data.contacts[0].devices[0].session)
        model.send("hello", in: chat.id)
        #expect(try sorted.encode(model.data.contacts[0].devices[0].session) == before, "nothing was encrypted for it")

        // Once its app updates, whatever it sends next says so and lets it back in.
        let newer = try Envelope.seal(.typing(conversation: nil), from: them, device: Data([1, 2, 3]), to: me.recipient)
        _ = model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 2, blob: newer))
        #expect(model.data.contacts[0].devices[0].needsUpdate == nil)
        #expect(model.peerNeedingUpdate(in: chat) == nil)
    }

    /// Saved data from the build before (format 19, with the old refresh fields in a ratchet session) opens in place,
    /// keeps everything, and the session keeps working.
    @Test func dataSavedBeforeThePostQuantumRatchetMigratesInPlace() async throws {
        let a = Identity.generate(), b = Identity.generate()
        let (pending, request) = try Handshake.start()
        var (bob, answer) = try Handshake.accept(request, me: b, initiatorAgreement: a.card.agreement)
        var alice = try Handshake.complete(pending, answer, me: a, responderAgreement: b.card.agreement)
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))

        var data = AppData()
        var contact = makeContact(b, device: 1)
        contact.devices[0].session = alice
        data.contacts = [contact]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder.pulshade.encode(data)) as! [String: Any]
        json["format"] = 19
        var contacts = json["contacts"] as! [[String: Any]]
        var devices = contacts[0]["devices"] as! [[String: Any]]
        var session = devices[0]["session"] as! [String: Any]
        session.removeValue(forKey: "pq")
        session["kemSeed"] = Data(repeating: 1, count: 64).base64EncodedString()
        session["pqMessages"] = 3
        session["peerBinds"] = true
        devices[0]["session"] = session
        contacts[0]["devices"] = devices
        json["contacts"] = contacts
        let opened = try JSONDecoder.pulshade.decode(AppData.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(opened.format == AppData.currentFormat && opened.contacts.count == 1)
        var restored = try #require(opened.contacts[0].devices[0].session)
        let sent = try restored.encrypt(Data("still here".utf8))
        #expect(String(decoding: try bob.decrypt(sent), as: UTF8.self) == "still here")
        // A build from before can't open what this one saves (it refuses a newer format rather than lose what it can't read).
        var newer = json
        newer["format"] = AppData.currentFormat + 1
        #expect(throws: (any Error).self) { _ = try JSONDecoder.pulshade.decode(AppData.self, from: JSONSerialization.data(withJSONObject: newer)) }
    }

    /// The notification helper's note says caps 0 (it knows nothing of what the app reads). That must not mark the friend's
    /// device as needing an update, or lose what it was known to read.
    @Test func aHelpersNoteDoesNotMarkTheDeviceAsNeedingAnUpdate() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let me = try #require(model.identity)
        let mailbox = Mailbox.make()
        let (them, _) = seed(model, mailbox: mailbox)
        model.data.contacts[0].devices[0].readsFrames = true
        let note = try EnvelopeCore.sealPQ(body: LockedDelivery.collectedBody([Data(repeating: 1, count: 16)]), signing: them.signingKey,
                                           agreement: them.agreementKey, pq: them.pq, sign: true, introduce: true, device: Data([1, 2, 3]),
                                           caps: 0, at: RelayClock.now, to: me.recipient)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 1, blob: note)) == .handled)
        #expect(model.data.contacts[0].devices[0].needsUpdate == nil)
        #expect(model.data.contacts[0].devices[0].readsFrames == true)
    }

    @Test func anEnvelopeSaysItAnswersGroupMessages() throws {
        let me = Identity.generate(), them = Identity.generate()
        let blob = try Envelope.seal(.typing(conversation: nil), from: them, to: me.recipient, introduce: true)
        #expect(try Envelope.openFull(blob, with: me).readsGroupReceipts)
    }

    @Test func aVideoStoryStaysUploadingWhileItsClipIsOnItsWay() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let them = Identity.generate()
        var contact = makeContact(them, device: 1)
        // This friend's app reads files kept on the relay, so the story's clip goes up there first.
        contact.devices[0].readsAttachments = true
        contact.persona = nil
        model.data.contacts = [contact]

        model.postStory(.video(Data(repeating: 7, count: 4_000), caption: ""), audience: .everyone)
        let story = try #require(model.data.stories.first)
        // The little story copies can go at once; the clip is still on its way, so the upload isn't over.
        #expect(model.isUploading(story.id), "the clip upload counts as part of the story")
        #expect(model.data.stories[0].delivery?.uploaded != true)
    }

    @Test func waitingForTheWritePutsItOnDisk() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let identity = try #require(model.identity)
        model.data.profile.name = "Written"
        model.save()
        await model.settleSavesAsync()
        #expect(try model.vault.load(with: identity)?.profile.name == "Written")
    }

    @Test func aFileMessageSentAgainKeepsItsAttachment() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let attachment = Attachment(id: Data.random(16).hex, key: .random(32), size: 2_048, kind: .file,
                                    name: "report.pdf", type: "application/pdf", sha256: .random(32),
                                    secret: .random(32), expires: Date().addingTimeInterval(3_600))
        var message = Message(sender: "me", text: "", date: Date(), status: .sent)
        message.attachment = attachment
        let convo = Conversation(kind: .direct, title: "Them", members: ["them"])

        let wire = model.wireForResend(message, in: convo)
        #expect(wire.attachment == attachment, "the retry still points at the file")
        #expect(wire.conversation == nil)
        #expect(wire.text == "")
    }

    @Test func aBareMessageIsNotActedOnButAnEraseIs() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let me = try #require(model.identity)
        let mailbox = Mailbox.make()
        let (them, _) = seed(model, mailbox: mailbox)
        // A message never travels outside a session; one that does here is junk.
        let message = WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "x", date: Date())
        let bare = try Envelope.seal(.message(message), from: them, to: me.recipient, introduce: true)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 4, blob: bare)) == .junk)

        // Something this app can act on is finished with, and may be acknowledged.
        let erased = try Envelope.seal(.erased, from: them, to: me.recipient, introduce: true)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 5, blob: erased)) == .handled)
    }

    // MARK: SEC-105

    /// A stranger's envelopes (anyone can seal one to a public key) leave nothing in the replay table, and one kept for
    /// a contact not yet added is still there to be read when it is.
    @Test func anUnknownSendersEnvelopeIsNotRememberedUntilItsSenderIsKnown() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let me = try #require(model.identity)
        let mailbox = Mailbox.make()
        seed(model, mailbox: mailbox)
        let before = model.seenEnvelopeCount
        let stranger = Identity.generate()
        let message = WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "x", date: Date())
        for n in 0..<20 {
            let blob = try Envelope.seal(.message(message), from: stranger, to: me.recipient, introduce: true)
            _ = model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: UInt64(n), blob: blob))
        }
        let hello = try Envelope.seal(.erased, from: stranger, to: me.recipient, introduce: true)
        _ = model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 99, blob: hello))
        #expect(model.seenEnvelopeCount == before, "nothing from someone this account doesn't know is written down")
        // A contact's own envelope still counts once, and a repeat of it is refused.
        let (them, _) = seed(model, mailbox: Mailbox.make())
        let known = try Envelope.seal(.erased, from: them, to: me.recipient, introduce: true)
        let mine = model.data.contacts.first { $0.fingerprint == them.fingerprint }?.receiveKey ?? mailbox.receiveKey
        #expect(model.receive(RelayEnvelope(receiveKey: mine, id: 200, blob: known)) == .handled)
        #expect(model.seenEnvelopeCount == before + 1)
        #expect(model.receive(RelayEnvelope(receiveKey: mine, id: 201, blob: known)) == .junk)
    }

    @Test func theReplayTableIsCapped() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let me = try #require(model.identity)
        let mailbox = Mailbox.make()
        let (them, _) = seed(model, mailbox: mailbox)
        model.maxSeenEnvelopes = 10
        for n in 0..<40 {
            let message = WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "x", date: Date())
            let blob = try Envelope.seal(.message(message), from: them, to: me.recipient, introduce: true)
            _ = model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: UInt64(n), blob: blob))
        }
        #expect(model.seenEnvelopeCount > 0 && model.seenEnvelopeCount <= 10)
    }
}
