import Testing
import Foundation
@testable import Pulshade

/// The notification helper's pieces, without a relay: the shared envelope crypto, its note, and what counts as a
/// chat message.
@Suite struct LockedDeliveryTests {
    let alice = Identity.generate()
    let bob = Identity.generate()

    @Test func theSharedCoreReadsAndWritesTheSameEnvelopesAsTheApp() throws {
        let payload = Payload.typing(conversation: UUID())
        let blob = try Envelope.seal(payload, from: alice, device: Data([7, 7]), to: bob.recipient)
        let header = try EnvelopeCore.openPQ(blob, agreement: bob.agreementKey, pq: bob.pq, known: { _ in alice.pq.pin }).header
        #expect(try Payload.fromWire(header.body) == payload)
        #expect(LockedDelivery.fingerprint(of: header.signer) == alice.fingerprint)
        #expect(header.device == Data([7, 7]))

        let made = try EnvelopeCore.sealPQ(body: try payload.wire(framed: false), signing: alice.signingKey, agreement: alice.agreementKey,
                                           pq: alice.pq, sign: true, introduce: true, device: Data(), caps: 0, at: Date(), to: bob.recipient)
        let opened = try Envelope.openFull(made, with: bob)
        #expect(opened.payload == payload)
        #expect(opened.signer == alice.signingKey.publicKey.rawRepresentation)
        #expect(opened.introduced == alice.pq.pin)
    }

    @Test func theHandWrittenNoteIsTheAppsCollectedPayload() throws {
        let digests = [Data(repeating: 1, count: 16), Data(repeating: 2, count: 16)]
        #expect(try Payload.fromWire(LockedDelivery.collectedBody(digests)) == .collected(digests: digests))
    }

    @Test func onlyChatMessagesAreConfirmed() throws {
        let ratchet = Payload.ratchet(RatchetMessage(header: RatchetHeader(dh: Data(count: 32), pn: 0, n: 0), ciphertext: Data([1])))
        #expect(LockedDelivery.isChatMessage(try ratchet.wire(framed: false)))
        #expect(LockedDelivery.isChatMessage(try ratchet.wire(framed: true)))
        #expect(!LockedDelivery.isChatMessage(try Payload.typing(conversation: UUID()).wire(framed: false)))
        #expect(!LockedDelivery.isChatMessage(LockedDelivery.collectedBody([Data(count: 16)])))
    }
}
