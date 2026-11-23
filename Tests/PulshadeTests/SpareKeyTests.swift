import Foundation
import CryptoKit
import Testing
@testable import Pulshade

/// Spare keys (`SpareSlot`): the slot both friends work out, what the relay sees, and the session they open.
struct SpareKeyTests {
    /// Both friends work out the same slot from their own side, and each device's spare has its own.
    @Test func bothSidesFindTheSameSlotAndNoOneElseDoes() throws {
        let alice = Identity.generate(), bob = Identity.generate(), eve = Identity.generate()
        let bobDevice = Data(repeating: 7, count: 16)
        let bobSigning = bob.signingKey.publicKey.rawRepresentation
        // Bob leaves it; Alice looks for it.
        let left = try #require(SpareSlot.keys(mine: bob.agreementKey, theirs: alice.agreementKey.publicKey.rawRepresentation,
                                               issuer: bobSigning, device: bobDevice))
        let looked = try #require(SpareSlot.keys(mine: alice.agreementKey, theirs: bob.agreementKey.publicKey.rawRepresentation,
                                                 issuer: bobSigning, device: bobDevice))
        #expect(left.name == looked.name)
        // Someone else who knows both public keys can't make it.
        let guessed = try #require(SpareSlot.keys(mine: eve.agreementKey, theirs: bob.agreementKey.publicKey.rawRepresentation,
                                                  issuer: bobSigning, device: bobDevice))
        #expect(guessed.name != left.name)
        // Another of Bob's devices, and Alice's spare for Bob, each have their own slot.
        let otherDevice = try #require(SpareSlot.keys(mine: bob.agreementKey, theirs: alice.agreementKey.publicKey.rawRepresentation,
                                                      issuer: bobSigning, device: Data(repeating: 8, count: 16)))
        let alicesForBob = try #require(SpareSlot.keys(mine: alice.agreementKey, theirs: bob.agreementKey.publicKey.rawRepresentation,
                                                       issuer: alice.signingKey.publicKey.rawRepresentation, device: bobDevice))
        #expect(Set([left.name, otherDevice.name, alicesForBob.name]).count == 3)
        // A device with no id has no slot.
        #expect(SpareSlot.keys(mine: bob.agreementKey, theirs: alice.agreementKey.publicKey.rawRepresentation,
                               issuer: bobSigning, device: Data()) == nil)
    }

    /// Each of a device's spares for a friend has its own slot, both sides agree on each, and the first is the slot
    /// builds before had, so their apps still find it.
    @Test func eachSpareHasItsOwnSlotAndTheFirstIsTheOldOne() throws {
        let alice = Identity.generate(), bob = Identity.generate()
        let device = Data(repeating: 5, count: 16), issuer = bob.signingKey.publicKey.rawRepresentation
        var names: [Data] = []
        for slot in SpareSlot.Slot.allCases {
            let left = try #require(SpareSlot.keys(mine: bob.agreementKey, theirs: alice.agreementKey.publicKey.rawRepresentation,
                                                   issuer: issuer, device: device, slot: slot))
            let looked = try #require(SpareSlot.keys(mine: alice.agreementKey, theirs: bob.agreementKey.publicKey.rawRepresentation,
                                                     issuer: issuer, device: device, slot: slot))
            #expect(left.name == looked.name)
            names.append(left.name)
        }
        #expect(Set(names).count == SpareSlot.Slot.allCases.count)
        // The derivation builds before used, written out: the first slot must stay exactly that.
        let shared = try bob.agreementKey.sharedSecretFromKeyAgreement(with: alice.agreementKey.publicKey)
        let ikm = SymmetricKey(data: shared.withUnsafeBytes { Data($0) })
        let context = Data(SHA256.hash(data: Data("pulshade.spare.v1".utf8) + issuer + device))
        let signing = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: context, info: Data("pulshade.spare.signing".utf8), outputByteCount: 32)
        let old = try Curve25519.Signing.PrivateKey(rawRepresentation: signing.withUnsafeBytes { Data($0) })
        #expect(names.first == old.publicKey.rawRepresentation)
        #expect(SpareSlot.Slot.lastResort.reusable && !SpareSlot.Slot.first.reusable && !SpareSlot.Slot.second.reusable)
    }

    /// What goes on the relay is the size of the smallest backup, opens only with the slot's keys, and the session
    /// it starts works both ways.
    @Test func aSpareIsOneSizeAndOpensASession() throws {
        let alice = Identity.generate(), bob = Identity.generate()
        let device = Data(repeating: 3, count: 16)
        let keys = try #require(SpareSlot.keys(mine: bob.agreementKey, theirs: alice.agreementKey.publicKey.rawRepresentation,
                                               issuer: bob.signingKey.publicKey.rawRepresentation, device: device))
        let spare = try #require(SpareKey.make(pin: Data()))
        let spareCard = try #require(spare.card)
        let sealed = try #require(SpareSlot.seal(spareCard, with: keys))
        #expect(sealed.count == 4 * 1024 + 28, "every spare is one size")

        let other = try #require(SpareSlot.keys(mine: bob.agreementKey, theirs: alice.agreementKey.publicKey.rawRepresentation,
                                                issuer: bob.signingKey.publicKey.rawRepresentation, device: Data(repeating: 4, count: 16)))
        #expect(SpareSlot.open(sealed, with: other) == nil, "another slot's keys can't open it")
        var tampered = sealed
        tampered[100] ^= 1
        #expect(SpareSlot.open(tampered, with: keys) == nil)
        let card = try #require(SpareSlot.open(sealed, with: keys))

        // Alice answers it and writes at once; Bob finishes his side from the answer, later.
        let (session, answer) = try Handshake.accept(card.request, me: alice, initiatorAgreement: bob.agreementKey.publicKey.rawRepresentation, initiatorPin: Data(), responderPin: Data())
        var aliceSide = session
        #expect(aliceSide.canSend)
        let first = try aliceSide.encrypt(Data("written straight away".utf8))
        var bobSide = try Handshake.complete(spare.handshake, answer, me: bob, responderAgreement: alice.agreementKey.publicKey.rawRepresentation, responderPin: Data())
        #expect(try bobSide.decrypt(first) == Data("written straight away".utf8))
        let reply = try bobSide.encrypt(Data("got it".utf8))
        #expect(try aliceSide.decrypt(reply) == Data("got it".utf8))
        // The answer names the spare it took.
        #expect(answer.replyTo == spare.handshake.publicEphemeral)
    }
}
