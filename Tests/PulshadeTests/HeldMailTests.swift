import Testing
import Foundation
@testable import Pulshade

/// Held mail is kept for a contact's unconfirmed devices, bounded by bytes across all of them.
@MainActor
@Suite(.serialized) struct HeldMailTests {
    @Test func heldMailIsCappedAtSixteenMebibytesPerContact() async throws {
        let model = testModel("pulshade-held-mail")
        try await model.create(identity: .generate(), profile: Profile(name: "Me"), passcode: "test-passcode")
        defer { model.lock() }

        let them = Identity.generate()
        var contact = Contact(fingerprint: them.fingerprint, name: "Them", signingKey: them.card.signing,
                              agreementKey: them.card.agreement, sendID: Mailbox.make().sendID, device: Data([1]))
        contact.persona = nil
        contact.devices[0].unconfirmed = true
        model.data.contacts = [contact]

        let mebibyte = 1_048_576
        for n in 0..<20 {
            let blob = Data(repeating: UInt8(n + 1), count: mebibyte)
            model.holdDeviceMail(HeldMail(receiveKey: Data(), blob: blob, at: Date()), contact: 0, device: 0)
        }

        let held = model.data.contacts[0].devices[0].heldMail ?? []
        #expect(held.reduce(0) { $0 + $1.blob.count } == AppModel.maxHeldMailBytes)
        #expect(held.count == 16)
        #expect(!held.contains { $0.blob.first == 1 }, "the oldest four went first")
        #expect(held.contains { $0.blob.first == 20 })

        let notes = model.data.conversations.flatMap(\.messages).filter {
            $0.isSystem && $0.text == "Some messages from Them's new device were discarded to free space."
        }
        #expect(notes.count == 1, "one note, not one per envelope")
    }
}
