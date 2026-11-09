import Testing
import Foundation
@testable import Pulshade

/// What happens to an envelope after it is taken from the relay: what is finished with, what is junk, and what
/// must be left there for another try.
@MainActor
@Suite struct DeliveryTests {
    private func makeModel() async throws -> AppModel {
        let model = testModel("pulshade-delivery")
        try await model.create(identity: .generate(), profile: Profile(name: "Me"), passcode: "test-passcode")
        return model
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
