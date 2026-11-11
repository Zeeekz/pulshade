import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// Alice starts a handshake with Bob; Bob answers and talks first.
private func pair() throws -> (alice: Ratchet, bob: Ratchet) {
    let a = Identity.generate(), b = Identity.generate()
    let (pending, request) = try Handshake.start()
    let (bob, answer) = try Handshake.accept(request, me: b, initiatorAgreement: a.card.agreement)
    let alice = try Handshake.complete(pending, answer, me: a, responderAgreement: b.card.agreement)
    return (alice, bob)
}

private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

/// What a build from before the refresh sends and sees: no ML-KEM fields at all.
private func legacy(_ message: RatchetMessage) -> RatchetMessage {
    var m = message
    m.header.kem = nil
    m.header.kemCiphertext = nil
    m.header.v = nil
    return m
}

@Suite(.serialized) struct RatchetRefreshTests {
    @Test func refreshesAfterFiftyMessages() throws {
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        let start = try #require(alice.postQuantumAt)
        var offers = 0, answers = 0
        for i in 0..<40 {
            let a = try alice.encrypt(Data("a\(i)".utf8))
            offers += a.header.kem == nil ? 0 : 1
            answers += a.header.kemCiphertext == nil ? 0 : 1
            #expect(text(try bob.decrypt(a)) == "a\(i)")
            let b = try bob.encrypt(Data("b\(i)".utf8))
            offers += b.header.kem == nil ? 0 : 1
            answers += b.header.kemCiphertext == nil ? 0 : 1
            #expect(text(try alice.decrypt(b)) == "b\(i)")
        }
        #expect(offers > 0 && answers > 0, "A key was offered and answered")
        #expect(offers < 10, "Only a few messages carry the big keys")
        #expect(try #require(alice.postQuantumAt) > start)
        #expect(try #require(bob.postQuantumAt) > start)
    }

    @Test func refreshesAfterADay() throws {
        let realNow = Ratchet.now
        defer { Ratchet.now = realNow }
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        let later = Date().addingTimeInterval(Ratchet.pqRefreshInterval + 60)
        Ratchet.now = { later }

        let offer = try alice.encrypt(Data("tomorrow".utf8))
        #expect(offer.header.kem != nil)
        #expect(text(try bob.decrypt(offer)) == "tomorrow")
        let answer = try bob.encrypt(Data("reply".utf8))
        #expect(answer.header.kemCiphertext != nil)
        #expect(text(try alice.decrypt(answer)) == "reply")
        #expect(alice.postQuantumAt == later && bob.postQuantumAt == later)
        #expect(text(try bob.decrypt(alice.encrypt(Data("after".utf8)))) == "after")
    }

    @Test func outOfOrderAcrossARefresh() throws {
        let realNow = Ratchet.now
        defer { Ratchet.now = realNow }
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        Ratchet.now = { Date().addingTimeInterval(Ratchet.pqRefreshInterval + 60) }

        _ = try bob.decrypt(alice.encrypt(Data("offer".utf8)))
        let b1 = try bob.encrypt(Data("1".utf8))
        let b2 = try bob.encrypt(Data("2".utf8))
        let b3 = try bob.encrypt(Data("3".utf8))
        #expect(b1.header.kemCiphertext != nil && b3.header.kemCiphertext == b1.header.kemCiphertext,
                "Every message of the chain carries the answer, so any one of them can arrive first")
        #expect(text(try alice.decrypt(b3)) == "3")
        _ = try bob.decrypt(alice.encrypt(Data("reply".utf8)))
        #expect(text(try alice.decrypt(b1)) == "1")
        #expect(text(try alice.decrypt(b2)) == "2")
    }

    @Test func aChangedAnswerOpensNothingAndStateSurvives() throws {
        let realNow = Ratchet.now
        defer { Ratchet.now = realNow }
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        Ratchet.now = { Date().addingTimeInterval(Ratchet.pqRefreshInterval + 60) }
        _ = try bob.decrypt(alice.encrypt(Data("offer".utf8)))

        let answer = try bob.encrypt(Data("real".utf8))
        var forged = answer
        forged.header.kemCiphertext![0] ^= 1
        #expect(throws: (any Error).self) { try alice.decrypt(forged) }
        var swapped = answer
        swapped.header.kemCiphertext = nil
        #expect(throws: (any Error).self) { try alice.decrypt(swapped) }
        #expect(text(try alice.decrypt(answer)) == "real")
    }

    @Test func olderBuildsKeepTalking() throws {
        let realNow = Ratchet.now
        defer { Ratchet.now = realNow }
        var (alice, bob) = try pair()
        Ratchet.now = { Date().addingTimeInterval(Ratchet.pqRefreshInterval + 60) }
        // Bob plays an old build: he never sees offers and never sends any.
        _ = try alice.decrypt(legacy(bob.encrypt(Data("open".utf8))))
        for i in 0..<60 {
            let a = try alice.encrypt(Data("a\(i)".utf8))
            #expect(a.header.kemCiphertext == nil, "Nothing to answer from an old build")
            #expect(text(try bob.decrypt(legacy(a))) == "a\(i)")
            #expect(text(try alice.decrypt(legacy(bob.encrypt(Data("b\(i)".utf8))))) == "b\(i)")
        }
    }

    @Test func sessionsSavedBeforeTheRefreshLoadAndRefresh() throws {
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        let pqKeys = ["kemSeed", "kemPublic", "kemTheirs", "kemAnswered", "kemCiphertextOut", "pqAt", "pqMessages"]
        func reload(_ r: Ratchet) throws -> Ratchet {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
            for key in pqKeys { json.removeValue(forKey: key) }
            return try JSONDecoder().decode(Ratchet.self, from: JSONSerialization.data(withJSONObject: json))
        }
        alice = try reload(alice)
        bob = try reload(bob)
        #expect(alice.postQuantumAt == nil)

        let offer = try alice.encrypt(Data("upgraded".utf8))
        #expect(offer.header.kem != nil, "An old session refreshes straight away")
        #expect(text(try bob.decrypt(offer)) == "upgraded")
        #expect(text(try alice.decrypt(bob.encrypt(Data("reply".utf8)))) == "reply")
        #expect(alice.postQuantumAt != nil && bob.postQuantumAt != nil)
    }

    // MARK: Authenticated ML-KEM fields

    @Test func messagesAreSealedTheOldWayUntilTheOtherSideSaysItCanRead() throws {
        var (alice, bob) = try pair()
        let first = try bob.encrypt(Data("one".utf8))
        #expect(first.header.v == 1, "A first message can't assume the other side reads the new form")
        #expect(text(try alice.decrypt(first)) == "one")
        let reply = try alice.encrypt(Data("two".utf8))
        #expect(reply.header.v == 2, "Alice has seen that Bob reads it")
        #expect(text(try bob.decrypt(reply)) == "two")
        let again = try bob.encrypt(Data("three".utf8))
        #expect(again.header.v == 2)
        #expect(text(try alice.decrypt(again)) == "three")
    }

    @Test func aChangedOfferIsRefusedOnTheSpot() throws {
        let realNow = Ratchet.now
        defer { Ratchet.now = realNow }
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        _ = try bob.decrypt(alice.encrypt(Data("bound".utf8)))
        let later = Date().addingTimeInterval(Ratchet.pqRefreshInterval + 60)
        Ratchet.now = { later }

        let offer = try alice.encrypt(Data("offer".utf8))
        #expect(offer.header.v == 2 && offer.header.kem != nil)
        var forged = offer
        forged.header.kem = try MLKEM768.PrivateKey().publicKey.rawRepresentation
        #expect(throws: RatchetError.self) { _ = try bob.decrypt(forged) }
        #expect(text(try bob.decrypt(offer)) == "offer", "The real one still opens, so the forgery changed nothing")
    }

    @Test func aChangedAnswerIsRefusedOnTheSpot() throws {
        let realNow = Ratchet.now
        defer { Ratchet.now = realNow }
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        _ = try bob.decrypt(alice.encrypt(Data("bound".utf8)))
        let later = Date().addingTimeInterval(Ratchet.pqRefreshInterval + 60)
        Ratchet.now = { later }
        _ = try bob.decrypt(alice.encrypt(Data("offer".utf8)))

        // The answer rides on Bob's next new chain, which a round trip or two brings.
        var answer: RatchetMessage?
        for _ in 0..<4 where answer == nil {
            let b = try bob.encrypt(Data("b".utf8))
            if b.header.kemCiphertext != nil { answer = b; break }
            _ = try alice.decrypt(b)
            _ = try bob.decrypt(alice.encrypt(Data("a".utf8)))
        }
        let real = try #require(answer)
        #expect(real.header.v == 2)
        var forged = real
        forged.header.kemCiphertext = Data(repeating: 9, count: real.header.kemCiphertext!.count)
        #expect(throws: RatchetError.self) { _ = try alice.decrypt(forged) }
        #expect(text(try alice.decrypt(real)) == "b")
    }

    @Test func aChangedVersionOrMissingFieldIsRefused() throws {
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        let bound = try alice.encrypt(Data("bound".utf8))
        #expect(bound.header.v == 2)
        var down = bound
        down.header.v = 1
        #expect(throws: RatchetError.self) { _ = try bob.decrypt(down) }
        #expect(text(try bob.decrypt(bound)) == "bound")
    }

    @Test func aBuildFromBeforeTheBindingKeepsTalkingBothWays() throws {
        var (alice, bob) = try pair()
        // Bob is an old build: he never learns anything from a version, and sends none. (A new ratchet that
        // forgets what it heard before each send behaves the same way.)
        func forgetting(_ r: Ratchet) throws -> Ratchet {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
            json.removeValue(forKey: "peerBinds")
            return try JSONDecoder().decode(Ratchet.self, from: JSONSerialization.data(withJSONObject: json))
        }
        func fromOldBob(_ text: String) throws -> RatchetMessage {
            bob = try forgetting(bob)
            var m = try bob.encrypt(Data(text.utf8))
            #expect(m.header.authenticated == m.header.bytes)
            m.header.v = nil
            return m
        }
        _ = try alice.decrypt(fromOldBob("open"))
        for i in 0..<5 {
            let a = try alice.encrypt(Data("a\(i)".utf8))
            #expect(a.header.v == 1, "Still the old form for Bob")
            #expect(a.header.authenticated == a.header.bytes, "which is what an old Bob checks")
            #expect(text(try bob.decrypt(a)) == "a\(i)")
            #expect(text(try alice.decrypt(fromOldBob("b\(i)"))) == "b\(i)")
        }
    }

    @Test func sessionsSavedBeforeTheBindingStillLoad() throws {
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        func reload(_ r: Ratchet) throws -> Ratchet {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
            json.removeValue(forKey: "peerBinds")
            return try JSONDecoder().decode(Ratchet.self, from: JSONSerialization.data(withJSONObject: json))
        }
        alice = try reload(alice)
        bob = try reload(bob)
        let one = try alice.encrypt(Data("one".utf8))
        #expect(one.header.v == 1, "A restored session starts the old way until it hears")
        #expect(text(try bob.decrypt(one)) == "one")
        #expect(text(try alice.decrypt(bob.encrypt(Data("two".utf8)))) == "two")
        #expect(try alice.encrypt(Data("three".utf8)).header.v == 2)
    }
}
