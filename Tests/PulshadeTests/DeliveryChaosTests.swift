import Testing
import Foundation
@testable import Pulshade

/// Delivery stress tests for the ratchet.
///
/// Real relays lose, duplicate, delay and reorder mail. The ratchet is supposed to survive all of that within a
/// chain (skipped keys) and across steps (one message from the next chain advances the receiver). These tests
/// drive that deliberately: every round sends a chain of messages, then delivers a random permutation of them with
/// some dropped and some replayed, and asserts that every message that *was* delivered opened to exactly its
/// plaintext. The point is not one lucky seed: a failure prints the seed and the round so it can be repeated.
///
/// What it deliberately does not do is permute messages across chain boundaries arbitrarily. A message from a
/// later chain can legitimately require an earlier one to establish the chain root; that is a protocol property,
/// not a bug. Cross-chain order is covered by alternating directions and by dropping whole chains' worth of
/// messages, which is the real-world shape (a relay outage).
@Suite(.serialized) struct DeliveryChaosTests {
    /// SplitMix64, so a failing run can be repeated exactly.
    private struct Dice: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func pair() throws -> (alice: Ratchet, bob: Ratchet) {
        let a = Identity.generate(), b = Identity.generate()
        let (pending, request) = try Handshake.start()
        let (bob, answer) = try Handshake.accept(request, me: b, initiatorAgreement: a.card.agreement,
                                                 initiatorPin: Data(), responderPin: Data())
        let alice = try Handshake.complete(pending, answer, me: a, responderAgreement: b.card.agreement,
                                           responderPin: Data())
        return (alice, bob)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private func roundTrip(_ ratchet: Ratchet) throws -> Ratchet {
        try JSONDecoder().decode(Ratchet.self, from: JSONEncoder().encode(ratchet))
    }

    /// Sends one chain from `sender`, delivers a permuted subset to `receiver`, replays a few, and fails if any
    /// message that was not dropped fails to open. At least one message always gets through, so the exchange can
    /// continue and the other side gets its step.
    private func chaosRound(_ sender: inout Ratchet, _ receiver: inout Ratchet,
                            label prefix: String, perRound: Int, dice: inout Dice,
                            seed: UInt64, round: Int) throws {
        var messages: [(String, RatchetMessage)] = []
        for i in 0..<perRound {
            let plain = "\(prefix)-\(i)"
            messages.append((plain, try sender.encrypt(Data(plain.utf8))))
        }

        var order = Array(0..<perRound).shuffled(using: &dice)
        var opened = Set<Int>()

        func deliver(_ index: Int) throws {
            let (plain, message) = messages[index]
            let openedText = text(try receiver.decrypt(message))
            #expect(openedText == plain, "seed \(seed) round \(round): message \(index) opened as \(openedText)")
            opened.insert(index)
        }

        while let index = order.first {
            order.removeFirst()
            // Roughly one in five is lost. The relay can drop anything; skipped keys cover the gaps.
            if dice.next() % 5 == 0 { continue }
            try deliver(index)
            // Roughly one in four is replayed immediately after it opened: the same ciphertext must not open twice.
            if dice.next() % 4 == 0 {
                let (plain, message) = messages[index]
                var replayed = false
                do {
                    _ = try receiver.decrypt(message)
                    replayed = true
                } catch {}
                #expect(!replayed, "seed \(seed) round \(round): \(plain) replayed")
            }
        }

        if opened.isEmpty {
            // The whole chain was lost. Deliver one so the exchange can move on; skip(until:) must handle it.
            try deliver(order.isEmpty ? 0 : (messages.indices.first { !opened.contains($0) } ?? 0))
        }
    }

    @Test func chainsSurviveLossReorderingAndReplays() throws {
        let perRound = 5
        let rounds = 6
        for seed in 1...20 {
            var dice = Dice(state: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15)
            var (alice, bob) = try pair()
            let opening = try bob.encrypt(Data("open".utf8))
            #expect(text(try alice.decrypt(opening)) == "open", "seed \(seed): opening message")

            for round in 0..<rounds {
                if round % 2 == 0 {
                    try chaosRound(&alice, &bob, label: "a\(round)", perRound: perRound, dice: &dice,
                                   seed: UInt64(seed), round: round)
                } else {
                    try chaosRound(&bob, &alice, label: "b\(round)", perRound: perRound, dice: &dice,
                                   seed: UInt64(seed), round: round)
                }
                // Persisting and reloading between rounds is what a suspended app does; it must not lose the
                // skipped keys or the epoch state the next chain depends on.
                if dice.next() % 2 == 0 {
                    alice = try roundTrip(alice)
                    bob = try roundTrip(bob)
                }
            }

            // After all that, both sides must still talk normally.
            let last = try alice.encrypt(Data("still here".utf8))
            #expect(text(try bob.decrypt(last)) == "still here", "seed \(seed): after chaos")
        }
    }

    /// A message delayed past the reordering window must still open from the skipped-key cache, and a message
    /// that was never sent must not.
    @Test func aLateMessageOpensButAForgedOneDoesNot() throws {
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))

        let first = try alice.encrypt(Data("first".utf8))
        let second = try alice.encrypt(Data("second".utf8))
        #expect(text(try bob.decrypt(second)) == "second")
        #expect(text(try bob.decrypt(first)) == "first", "an older message of the same chain must still open")

        // A ciphertext with one bit flipped, at a number that has already been consumed.
        var forged = try alice.encrypt(Data("forged".utf8))
        forged.ciphertext[0] ^= 0x01
        #expect(throws: (any Error).self) { try bob.decrypt(forged) }
    }
}
