import Testing
import Foundation
@testable import Pulshade

/// Alice starts a handshake with Bob; Bob answers and talks first.
private func pair() throws -> (alice: Ratchet, bob: Ratchet, aliceID: Identity, bobID: Identity) {
    let a = Identity.generate(), b = Identity.generate()
    let (pending, request) = try Handshake.start()
    let (bob, answer) = try Handshake.accept(request, me: b, initiatorAgreement: a.card.agreement)
    let alice = try Handshake.complete(pending, answer, me: a, responderAgreement: b.card.agreement)
    return (alice, bob, a, b)
}

private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

@Suite struct RatchetTests {
    @Test func conversationBothWays() throws {
        var (alice, bob, _, _) = try pair()
        #expect(bob.canSend && !alice.canSend, "Responder speaks first")
        let hi = try bob.encrypt(Data("hi alice".utf8))
        #expect(text(try alice.decrypt(hi)) == "hi alice")
        #expect(alice.canSend)
        for i in 0..<5 {
            #expect(text(try bob.decrypt(alice.encrypt(Data("a\(i)".utf8)))) == "a\(i)")
            #expect(text(try alice.decrypt(bob.encrypt(Data("b\(i)".utf8)))) == "b\(i)")
        }
    }

    @Test func outOfOrderAndAcrossSteps() throws {
        var (alice, bob, _, _) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        let m1 = try alice.encrypt(Data("1".utf8))
        let m2 = try alice.encrypt(Data("2".utf8))
        let m3 = try alice.encrypt(Data("3".utf8))
        #expect(text(try bob.decrypt(m3)) == "3")
        _ = try alice.decrypt(bob.encrypt(Data("reply".utf8))) // new ratchet step in between
        #expect(text(try bob.decrypt(m1)) == "1")
        #expect(text(try bob.decrypt(m2)) == "2")
    }

    @Test func replayIsRejected() throws {
        var (alice, bob, _, _) = try pair()
        let m = try bob.encrypt(Data("once".utf8))
        _ = try alice.decrypt(m)
        #expect(throws: (any Error).self) { try alice.decrypt(m) }
    }

    @Test func tamperingIsRejectedAndStateSurvives() throws {
        var (alice, bob, _, _) = try pair()
        var m = try bob.encrypt(Data("real".utf8))
        let original = m
        m.ciphertext[0] ^= 1
        #expect(throws: (any Error).self) { try alice.decrypt(m) }
        #expect(text(try alice.decrypt(original)) == "real")
    }

    /// Forward secrecy: a thief who copies Bob's state today can't read what Bob already received.
    @Test func stolenStateCannotReadThePast() throws {
        var (alice, bob, _, _) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        let recorded = try alice.encrypt(Data("yesterday's secret".utf8))
        _ = try bob.decrypt(recorded)
        var stolen = bob
        #expect(throws: (any Error).self) { try stolen.decrypt(recorded) }
    }

    /// Healing: once both sides have taken fresh steps, a copy of old state stops working.
    @Test func stolenStateLocksOutAfterNewSteps() throws {
        var (alice, bob, _, _) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        var stolen = alice
        _ = try bob.decrypt(alice.encrypt(Data("a".utf8)))
        _ = try alice.decrypt(bob.encrypt(Data("b".utf8)))
        _ = try bob.decrypt(alice.encrypt(Data("c".utf8)))
        let later = try bob.encrypt(Data("after healing".utf8))
        #expect(text(try alice.decrypt(later)) == "after healing")
        #expect(throws: (any Error).self) { try stolen.decrypt(later) }
    }

    @Test func wrongIdentityCannotCompleteHandshake() throws {
        let a = Identity.generate(), b = Identity.generate(), mallory = Identity.generate()
        let (pending, request) = try Handshake.start()
        var (bob, answer) = try Handshake.accept(request, me: b, initiatorAgreement: a.card.agreement)
        // Alice thinks she's talking to Mallory: keys won't line up.
        var alice = try Handshake.complete(pending, answer, me: a, responderAgreement: mallory.card.agreement)
        #expect(throws: (any Error).self) { try alice.decrypt(bob.encrypt(Data("x".utf8))) }
        // A tampered post-quantum ciphertext breaks the session too.
        answer.kemCiphertext[answer.kemCiphertext.startIndex] ^= 1
        var tampered = try Handshake.complete(pending, answer, me: a, responderAgreement: b.card.agreement)
        #expect(throws: (any Error).self) { try tampered.decrypt(bob.encrypt(Data("y".utf8))) }
    }

    /// Stealing identity keys later still doesn't open recorded traffic: the outer seal
    /// opens, but the message inside needs a session key that no longer exists anywhere.
    @Test func identityKeysAloneCannotReadRecordedMessages() throws {
        var (alice, bob, aliceID, bobID) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        let secret = Payload.message(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "meet at 9",
                                                 image: nil, date: Date(timeIntervalSince1970: 1_800_000_000)))
        let inner = try alice.encrypt(JSONEncoder.pulshade.encode(secret))
        let recorded = try Envelope.seal(.ratchet(inner), from: aliceID, to: bobID.card.agreement)

        let (outer, _) = try Envelope.open(recorded, with: bobID)
        guard case let .ratchet(message) = outer else { Issue.record("expected ratchet payload"); return }
        #expect(message.ciphertext.range(of: Data("meet at 9".utf8)) == nil)
        // A fresh session for the same two identities can't decrypt it either.
        var (_, otherBob, _, _) = try pair()
        #expect(throws: (any Error).self) { try otherBob.decrypt(message) }
    }
}
