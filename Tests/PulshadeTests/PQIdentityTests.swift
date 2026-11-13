import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// Identity and sealed-sender keys are hybrid post-quantum: version 3 envelopes mix an ML-KEM-768 secret into both
/// layers, non-ratchet payloads carry an ML-DSA signature next to the Ed25519 binding, and nothing classical-only
/// is read once a sender's post-quantum keys are known (or at all, apart from the introduction that carries them).
@Suite struct PQIdentityTests {
    let alice = Identity.generate()
    let bob = Identity.generate()

    private func ratchet() -> Payload {
        .ratchet(RatchetMessage(header: RatchetHeader(dh: Data(repeating: 7, count: 32), pn: 0, n: 1), ciphertext: Data([1, 2, 3])))
    }

    private func control() -> Payload { .erased }

    // MARK: Keys

    @Test func postQuantumKeysComeFromTheSeedAndTheOldKeysAreUntouched() throws {
        let seed = Data((0..<32).map(UInt8.init))
        let a = try Identity(seed: seed), b = try Identity(seed: seed)
        #expect(a.pq.pin == b.pq.pin && a.pq.kemSeed == b.pq.kemSeed && a.pq.sigSeed == b.pq.sigSeed)
        #expect(a.pq.pin.isWellFormed && a.pq.kemSeed.count == 64 && a.pq.sigSeed.count == 32)
        #expect(a.pq.pin != alice.pq.pin)
        // The account is the same account: the classical keys, and so the fingerprint, come out as they always did.
        #expect(a.fingerprint == Identity.fingerprint(of: a.card.signing))
        let root = SymmetricKey(data: seed)
        let signing = HKDF<SHA256>.deriveKey(inputKeyMaterial: root, info: Data("pulshade.signing".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
        #expect(try Curve25519.Signing.PrivateKey(rawRepresentation: signing).publicKey.rawRepresentation == a.card.signing)
        // A recovery code gives the same post-quantum keys back.
        let recovered = try Identity(seed: try #require(Identity.seed(fromRecoveryCode: a.recoveryCode)))
        #expect(recovered.pq.pin == a.pq.pin && recovered.card.signing == a.card.signing)
    }

    @Test func aCardNeedsBothSignaturesAndTheKeysItWasMadeFor() throws {
        let card = alice.pqCard
        let pin = alice.pq.pin
        #expect(card.verified(signer: alice.card.signing, agreement: alice.card.agreement) == pin)
        #expect(card.verified(signer: bob.card.signing, agreement: alice.card.agreement) == nil, "someone else's signing key")
        #expect(card.verified(signer: alice.card.signing, agreement: bob.card.agreement) == nil, "someone else's agreement key")
        var noEd = card; noEd.edSig = bob.pqCard.edSig
        #expect(noEd.verified(signer: alice.card.signing, agreement: alice.card.agreement) == nil, "the Ed25519 signature must verify")
        var noPQ = card; noPQ.pqSig = bob.pqCard.pqSig
        #expect(noPQ.verified(signer: alice.card.signing, agreement: alice.card.agreement) == nil, "the ML-DSA signature must verify")
        var swapped = card; swapped.kem = bob.pq.pin.kem
        #expect(swapped.verified(signer: alice.card.signing, agreement: alice.card.agreement) == nil, "keys swapped under the signatures")
        var short = card; short.dsa = Data(short.dsa.dropLast())
        #expect(short.verified(signer: alice.card.signing, agreement: alice.card.agreement) == nil)
    }

    // MARK: Envelopes

    @Test func aPostQuantumEnvelopeRoundTripsAndRevealsNothingOutside() throws {
        let blob = try Envelope.seal(control(), from: alice, device: Data([4]), to: bob.recipient, introduce: true)
        #expect(blob.first == 3)
        #expect(blob.range(of: alice.card.signing) == nil && blob.range(of: alice.card.agreement) == nil)
        let opened = try Envelope.openFull(blob, with: bob)
        #expect(opened.payload == control() && opened.signer == alice.card.signing && opened.device == Data([4]))
        #expect(opened.agreement == alice.card.agreement && opened.postQuantum && opened.readsPostQuantum)
        #expect(opened.introduced == alice.pq.pin, "the card inside is what pins the sender")
        // Once pinned the card is not needed, and the envelope is smaller by it.
        let pinned = try Envelope.seal(control(), from: alice, device: Data([4]), to: bob.recipient)
        let again = try Envelope.openFull(pinned, with: bob, known: { _ in alice.pq.pin })
        #expect(again.payload == control() && again.introduced == nil)
        #expect(pinned.count <= blob.count)
    }

    @Test func ratchetMessagesStayInTheirBucketAndOthersGrowByTheKemCiphertextOnly() throws {
        let short = try Envelope.seal(ratchet(), from: alice, to: bob.recipient)
        let longer = try Envelope.seal(.ratchet(RatchetMessage(header: RatchetHeader(dh: Data(count: 32), pn: 0, n: 0),
                                                              ciphertext: Data(repeating: 1, count: 900))), from: alice, to: bob.recipient)
        #expect(short.count == longer.count, "padding buckets are unchanged")
        #expect(short.count == 1 + 32 + 1_088 + 2_048 + 28, "2 KB bucket, plus the fixed 1121 bytes in front")
        let signed = try Envelope.seal(control(), from: alice, to: bob.recipient)
        #expect(signed.count == 1 + 32 + 1_088 + 8_192 + 28, "a signature (3309 bytes) takes a control message into the 8 KB bucket")
    }

    @Test func breakingX25519AloneOpensNothing() throws {
        // A recorder who later breaks X25519 has bob's agreement key but not his ML-KEM key.
        let blob = try Envelope.seal(ratchet(), from: alice, to: bob.recipient)
        let stolenX = bob.agreementKey
        #expect(throws: (any Error).self) { try EnvelopeCore.openPQ(blob, agreement: stolenX, pq: alice.pq, known: { _ in nil }) }
        #expect(try EnvelopeCore.openPQ(blob, agreement: stolenX, pq: bob.pq, known: { _ in nil }).header.signer == alice.card.signing)
        // Sealing to someone's X25519 key with another person's ML-KEM key can't be opened by the real owner.
        let mixed = EnvelopeRecipient(agreement: bob.card.agreement, pq: alice.pq.pin)
        let odd = try Envelope.seal(ratchet(), from: alice, to: mixed)
        #expect(throws: (any Error).self) { try Envelope.openFull(odd, with: bob) }
    }

    @Test func tamperingWithAnyPartIsDetected() throws {
        let blob = try Envelope.seal(control(), from: alice, to: bob.recipient, introduce: true)
        for position in [5, 40, 600, blob.count / 2, blob.count - 3] {
            var broken = blob
            broken[position] ^= 0x01
            #expect(throws: (any Error).self) { try Envelope.openFull(broken, with: bob) }
        }
    }

    @Test func aForgerWithBothClassicalKeysStillNeedsTheMLDSAKey() throws {
        // Alice's X25519 and Ed25519 private keys are broken; her ML-DSA key is not. The forger seals as "alice" with keys of
        // their own for the post-quantum half.
        let forger = Identity.generate()
        let forgedPQ = forger.pq
        let blob = try EnvelopeCore.sealPQ(body: try control().wire(framed: false), signing: alice.signingKey, agreement: alice.agreementKey,
                                           pq: forgedPQ, sign: true, introduce: false, device: Data(), caps: 255, at: Date(), to: bob.recipient)
        // Bob has Alice pinned: the signature is checked against her key, and fails.
        #expect(throws: (any Error).self) { try Envelope.openFull(blob, with: bob, known: { _ in alice.pq.pin }) }
        // With the forger's own card in it, a card for a pinned account must be the pinned keys.
        let withCard = try EnvelopeCore.sealPQ(body: try control().wire(framed: false), signing: alice.signingKey, agreement: alice.agreementKey,
                                               pq: forgedPQ, sign: true, introduce: true, device: Data(), caps: 255, at: Date(), to: bob.recipient)
        #expect(throws: (any Error).self) { try Envelope.openFull(withCard, with: bob, known: { _ in alice.pq.pin }) }
        // Unpinned, Bob can't tell, as with any first contact: that is the one trust-on-first-use step.
        #expect(try Envelope.openFull(withCard, with: bob).introduced == forgedPQ.pin)
        // A control message with no signature at all is refused, whoever sealed it.
        let unsigned = try EnvelopeCore.sealPQ(body: try control().wire(framed: false), signing: alice.signingKey, agreement: alice.agreementKey,
                                               pq: alice.pq, sign: false, introduce: true, device: Data(), caps: 255, at: Date(), to: bob.recipient)
        #expect(throws: (any Error).self) { try Envelope.openFull(unsigned, with: bob, known: { _ in alice.pq.pin }) }
        // But a ratchet message needs none: its session authenticates it.
        let session = try EnvelopeCore.sealPQ(body: try ratchet().wire(framed: false), signing: alice.signingKey, agreement: alice.agreementKey,
                                              pq: alice.pq, sign: false, introduce: false, device: Data(), caps: 255, at: Date(), to: bob.recipient)
        #expect(try Envelope.openFull(session, with: bob, known: { _ in alice.pq.pin }).payload == ratchet())
    }

    @Test func aSignatureIsForOneEnvelopeOnly() throws {
        // Replaying a recorded signed envelope's signature inside another envelope to Bob doesn't verify.
        let a = try Envelope.seal(control(), from: alice, to: bob.recipient, introduce: true)
        #expect(try Envelope.openFull(a, with: bob, known: { _ in alice.pq.pin }).payload == .erased)
        let other = Identity.generate()
        let b = try Envelope.seal(control(), from: alice, to: other.recipient, introduce: true)
        #expect(throws: (any Error).self) { try Envelope.openFull(b, with: bob) }
    }

    // MARK: Classical envelopes

    private func classical(_ payload: Payload, from sender: Identity, to receiver: Identity) throws -> Data {
        try EnvelopeCore.seal(body: try payload.wire(framed: false), framed: false, signing: sender.signingKey, agreement: sender.agreementKey,
                              device: Data(), caps: 127, at: Date(), to: receiver.card.agreement)
    }

    private func introduction(from sender: Identity) throws -> Payload { .pqIntro(sender.pqCard) }

    @Test func anOldAppsEnvelopeIsRefusedByNameOnceTheKeysAreKnownOrNot() throws {
        let old = try classical(ratchet(), from: alice, to: bob)
        for known: PQPin? in [nil, alice.pq.pin] {
            do {
                _ = try Envelope.openFull(old, with: bob, known: { _ in known })
                Issue.record("a classical ratchet message was read")
            } catch let EnvelopeRefusal.classical(signer, _) {
                #expect(signer == alice.card.signing, "the refusal names who it was from")
            }
        }
    }

    @Test func theOneClassicalEnvelopeLeftIsAnIntroductionFromSomeoneNotPinned() throws {
        let intro = try classical(try introduction(from: alice), from: alice, to: bob)
        let opened = try Envelope.openFull(intro, with: bob)
        #expect(opened.introduced == alice.pq.pin && !opened.postQuantum)
        // Pinned, the same introduction (their exact card) is still read, for a contact that lost our keys or another of their
        // devices that hasn't been told them: it pins nothing and the app only answers it with its own card.
        let again = try Envelope.openFull(intro, with: bob, known: { _ in alice.pq.pin })
        #expect(again.introduced == nil && !again.postQuantum && again.payload.introducedCard?.verified(signer: alice.card.signing, agreement: alice.card.agreement) == alice.pq.pin)
        // But a classical control message from a pinned contact is a downgrade and refused, and so is an introduction with other keys.
        #expect(throws: EnvelopeRefusal.self) { try Envelope.openFull(try classical(control(), from: alice, to: bob), with: bob, known: { _ in alice.pq.pin }) }
        #expect(throws: EnvelopeRefusal.self) { try Envelope.openFull(try classical(.pqIntro(Identity.generate().pqCard), from: alice, to: bob), with: bob, known: { _ in alice.pq.pin }) }
        // A card that isn't theirs (or has been altered) doesn't make it an introduction.
        let wrong = try classical(.pqIntro(bob.pqCard), from: alice, to: bob)
        #expect(throws: EnvelopeRefusal.self) { try Envelope.openFull(wrong, with: bob) }
        var altered = alice.pqCard; altered.kem = bob.pq.pin.kem
        #expect(throws: EnvelopeRefusal.self) { try Envelope.openFull(try classical(.pqIntro(altered), from: alice, to: bob), with: bob) }
        // Hello and request carry the card inside the contact card; without it they are refused too.
        let (_, hello) = try Handshake.start()
        let card = PeerCard(name: "A", signingKey: alice.card.signing, agreementKey: alice.card.agreement, sendID: Data(count: 32), pq: alice.pqCard)
        #expect(try Envelope.openFull(try classical(.hello(card, hello), from: alice, to: bob), with: bob).introduced == alice.pq.pin)
        var bare = card; bare.pq = nil
        #expect(throws: EnvelopeRefusal.self) { try Envelope.openFull(try classical(.hello(bare, hello), from: alice, to: bob), with: bob) }
        // Anything else (a message, an erase notice) is refused even from someone unpinned.
        #expect(throws: EnvelopeRefusal.self) { try Envelope.openFull(try classical(control(), from: alice, to: bob), with: bob) }
    }

    @Test func theContactRecordKeepsPinsAndReadsOlderRecords() throws {
        var contact = Contact(fingerprint: alice.fingerprint, name: "A", signingKey: alice.card.signing, agreementKey: alice.card.agreement, sendID: Data(count: 32))
        contact.pq = alice.pq.pin
        contact.pqCardSent = true
        let json = try JSONEncoder.pulshade.encode(contact)
        let back = try JSONDecoder.pulshade.decode(Contact.self, from: json)
        #expect(back.pq == alice.pq.pin && back.pqCardSent == true)
        // A record saved before post-quantum keys has none of the new fields and reads as it did.
        var object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        for key in ["pq", "pqCardSent", "tooOld"] { object[key] = nil }
        let old = try JSONDecoder.pulshade.decode(Contact.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.pq == nil && old.pqCardSent == nil && old.fingerprint == contact.fingerprint && old.signingKey == contact.signingKey)
    }

    @Test func theHelperBundleOfAnOlderAppReadsWithNoPostQuantumKeys() throws {
        let bundle = HelperBundle(signing: alice.signingKey.rawRepresentation, agreement: alice.agreementKey.rawRepresentation,
                                  pqKem: alice.pq.kemSeed, pqSig: alice.pq.sigSeed, device: Data([1]), relay: "http://127.0.0.1:1", friends: [:])
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(bundle)) as? [String: Any])
        object["pqKem"] = nil; object["pqSig"] = nil
        let old = try JSONDecoder().decode(HelperBundle.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.pqKem == nil)
        // With no keys the helper confirms nothing rather than falling back to a classical note.
        let mail = LockedDelivery.Mail(receiveKey: Data(count: 32), blob: Data(count: 4_000))
        #expect(LockedDelivery.notes(for: [mail], bundle: old, confirmed: []).isEmpty)
    }
}
