import Testing
import Foundation
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
}
