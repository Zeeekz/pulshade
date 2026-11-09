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
        .ratchet(RatchetMessage(header: RatchetHeader(dh: .random(32), pn: 0, n: 0, kem: nil, kemCiphertext: nil),
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
        let blob = try Envelope.seal(ratchet(), from: Identity.generate(), to: me.card.agreement)
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
        let blob = try Envelope.seal(ratchet(), from: them, device: Data([9, 9]), to: me.card.agreement)
        let envelope = RelayEnvelope(receiveKey: mailbox.receiveKey, id: 3, blob: blob)
        #expect(model.receive(envelope) == .retry)
    }

    @Test func aGroupMessageIsAnsweredWithAReceipt() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let them = Identity.generate()
        let contact = Contact(fingerprint: them.fingerprint, name: "Them", signingKey: them.card.signing,
                              agreementKey: them.card.agreement, sendID: Mailbox.make().sendID,
                              device: Data([7, 7]))
        var group = Conversation(kind: .group, title: "Group", members: [them.fingerprint])
        group.owner = "me"
        model.data.contacts = [contact]
        model.data.conversations = [group]
        model.data.security.deliveryReceipts = true
        model.data.security.notifications = false

        let id = UUID()
        model.deliver(WireMessage(id: id, conversation: group.id, kind: .group, text: "hello", date: Date()), from: contact)
        model.sendDueReceipts()

        let pending = model.data.contacts[0].devices[0].pending
        #expect(pending.contains {
            if case let .receipt(ids, read) = $0.payload { ids == [id] && read != true } else { false }
        }, "the sender is told the group message arrived, without claiming it was read")
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
                           agreementKey: .random(32), sendID: Mailbox.make().sendID)
        let badBlob = try Envelope.seal(.hello(bad, request), from: them, to: me.card.agreement)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 1, blob: badBlob)) == .junk)

        // The honest card names the key the envelope was actually sealed with.
        let good = PeerCard(name: "Them", avatar: nil, color: nil, signingKey: them.card.signing,
                            agreementKey: them.card.agreement, sendID: Mailbox.make().sendID)
        let goodBlob = try Envelope.seal(.hello(good, request), from: them, to: me.card.agreement)
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
                                                                       kem: nil, kemCiphertext: nil),
                                                  ciphertext: .random(48)))
        let blob = try Envelope.seal(wire, from: them, device: Data([1, 2, 3]), to: me.card.agreement)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 9, blob: blob)) == .handled)
        #expect(!model.recoveredSessions.isEmpty, "the old keys are kept so a late message under them still opens")
    }

    @Test func aGroupMessageWaitsForEveryMember() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let a = Identity.generate(), b = Identity.generate()
        var group = Conversation(kind: .group, title: "Group", members: [a.fingerprint, b.fingerprint])
        group.owner = "me"
        var message = Message(sender: "me", text: "hi", date: Date(), status: .sent)
        message.deliveredTo = []
        group.messages = [message]
        var ca = makeContact(a, device: 1), cb = makeContact(b, device: 2)
        ca.devices[0].readsGroupReceipts = true
        cb.devices[0].readsGroupReceipts = true
        model.data.contacts = [ca, cb]
        model.data.conversations = [group]

        model.noteDelivery(of: message.id, by: a.fingerprint, read: false)
        #expect(model.data.conversations[0].messages[0].status == .sent, "one member isn't the whole group")
        #expect(model.data.conversations[0].messages[0].deliveredTo == [a.fingerprint])
        #expect(model.unconfirmedRecipients(model.data.conversations[0].messages[0],
                                           in: model.data.conversations[0]).map(\.fingerprint) == [b.fingerprint])

        // A receipt from someone outside the group doesn't count.
        model.noteDelivery(of: message.id, by: Identity.generate().fingerprint, read: false)
        #expect(model.data.conversations[0].messages[0].deliveredTo == [a.fingerprint])

        model.noteDelivery(of: message.id, by: b.fingerprint, read: false)
        #expect(model.data.conversations[0].messages[0].status == .delivered, "every member has it now")
    }

    @Test func aGroupMessageDoesNotWaitForOlderBuilds() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let a = Identity.generate(), b = Identity.generate()
        var group = Conversation(kind: .group, title: "Group", members: [a.fingerprint, b.fingerprint])
        group.owner = "me"
        var message = Message(sender: "me", text: "hi", date: Date(), status: .sent)
        message.deliveredTo = []
        group.messages = [message]
        // `a` is on a build from before group receipts; `b` answers them.
        var ca = makeContact(a, device: 1)
        ca.devices[0].readsGroupReceipts = nil
        var cb = makeContact(b, device: 2)
        cb.devices[0].readsGroupReceipts = true
        model.data.contacts = [ca, cb]
        model.data.conversations = [group]

        model.noteDelivery(of: message.id, by: b.fingerprint, read: false)
        #expect(model.data.conversations[0].messages[0].status == .delivered, "the member that answers has it")
        #expect(model.unconfirmedRecipients(model.data.conversations[0].messages[0],
                                           in: model.data.conversations[0]).map(\.fingerprint) == [a.fingerprint],
                "the older build is still sent it, but isn't waited on")
    }

    @Test func anEnvelopeSaysItAnswersGroupMessages() throws {
        let me = Identity.generate(), them = Identity.generate()
        let blob = try Envelope.seal(.typing(conversation: nil), from: them, to: me.card.agreement)
        #expect(try Envelope.openFull(blob, with: me).readsGroupReceipts)
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
        let bare = try Envelope.seal(.message(message), from: them, to: me.card.agreement)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 4, blob: bare)) == .junk)

        // Something this app can act on is finished with, and may be acknowledged.
        let erased = try Envelope.seal(.erased, from: them, to: me.card.agreement)
        #expect(model.receive(RelayEnvelope(receiveKey: mailbox.receiveKey, id: 5, blob: erased)) == .handled)
    }
}
