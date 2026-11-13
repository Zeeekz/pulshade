import Testing
import Foundation
import CryptoKit
@testable import Pulshade

private func pair() throws -> (alice: Ratchet, bob: Ratchet) {
    let a = Identity.generate(), b = Identity.generate()
    let (pending, request) = try Handshake.start()
    let (bob, answer) = try Handshake.accept(request, me: b, initiatorAgreement: a.card.agreement)
    let alice = try Handshake.complete(pending, answer, me: a, responderAgreement: b.card.agreement)
    return (alice, bob)
}

private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

/// A small deterministic generator, so a failing run can be repeated.
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

private func saved(_ r: Ratchet) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(r)
}
private func restart(_ r: Ratchet) throws -> Ratchet { try JSONDecoder().decode(Ratchet.self, from: saved(r)) }

@Suite struct ChunkCodeTests {
    @Test func fieldArithmeticMatchesTheKnownValues() {
        // 2 * 0x80 wraps through the polynomial: x^8 = x^4 + x^3 + x^2 + 1 = 0x1d.
        #expect(ChunkCode.mul(2, 0x80) == 0x1d)
        #expect(ChunkCode.mul(0, 7) == 0 && ChunkCode.mul(1, 7) == 7)
        #expect(ChunkCode.mul(0x57, 0x83) == ChunkCode.mul(0x83, 0x57))
    }

    @Test func fixedVector() {
        // Chunk 0 of a single block is the data times 1/(0 + 240) in GF(2^8): fixed by the field and the matrix alone.
        let one = Data([1, 2, 3])
        let c = ChunkCode.chunk(one, number: 0)
        #expect(c.count == ChunkCode.size && c.dropFirst(3).allSatisfy { $0 == 0 })
        #expect(ChunkCode.mul(c[0], 0xf0) == 1 && ChunkCode.mul(c[1], 0xf0) == 2 && ChunkCode.mul(c[2], 0xf0) == 3)
        let data = Data((0..<200).map { UInt8(($0 * 7 + 3) & 0xff) })
        let parts = Dictionary(uniqueKeysWithValues: [239, 1, 5].map { ($0, ChunkCode.chunk(data, number: $0)) })
        #expect(ChunkCode.decode(parts, length: 200) == data)
    }

    @Test func anyKChunksRebuildTheData() {
        var dice = Dice(state: 1)
        for length in [1, 96, 97, 192, 1120, 1216, 1536] {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &dice) })
            let k = ChunkCode.blocks(for: length)
            for _ in 0..<20 {
                var numbers = Set<Int>()
                while numbers.count < k { numbers.insert(Int.random(in: 0..<ChunkCode.numbers, using: &dice)) }
                let parts = Dictionary(uniqueKeysWithValues: numbers.map { ($0, ChunkCode.chunk(data, number: $0)) })
                #expect(ChunkCode.decode(parts, length: length) == data)
            }
            var short = Dictionary(uniqueKeysWithValues: (0..<k).map { ($0, ChunkCode.chunk(data, number: $0)) })
            short.removeValue(forKey: 0)
            #expect(ChunkCode.decode(short, length: length) == nil, "One short is not enough")
        }
    }
}

@Suite(.serialized) struct RatchetPQTests {
    /// Both sides talk in turn, bob first.
    private func talk(_ alice: inout Ratchet, _ bob: inout Ratchet, rounds: Int, restarting: Bool = false) throws {
        for i in 0..<rounds {
            let b = try bob.encrypt(Data("b\(i)".utf8))
            #expect(text(try alice.decrypt(b)) == "b\(i)")
            let a = try alice.encrypt(Data("a\(i)".utf8))
            #expect(text(try bob.decrypt(a)) == "a\(i)")
            if restarting { alice = try restart(alice); bob = try restart(bob) }
        }
    }

    @Test func everyMessageCarriesOneChunkOfTheSameSize() throws {
        var (alice, bob) = try pair()
        var sizes = Set<Int>()
        for i in 0..<120 {
            let m = try bob.encrypt(Data("b\(i)".utf8))
            sizes.insert(m.header.pq?.count ?? -1)
            #expect(m.header.v == RatchetHeader.version)
            _ = try alice.decrypt(m)
            let a = try alice.encrypt(Data("a\(i)".utf8))
            sizes.insert(a.header.pq?.count ?? -1)
            _ = try bob.decrypt(a)
        }
        #expect(sizes.count == 1 && sizes.first! > 0, "The chunk is always there and always as long")
    }

    @Test func aMessageStillFitsTheSmallestBucket() throws {
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        let m = try alice.encrypt(Data(repeating: 65, count: 300))
        let wire = try JSONEncoder.pulshade.encode(Payload.ratchet(m))
        #expect(wire.count < 1000, "A chunk adds only a little: \(wire.count) bytes")
        #expect(Envelope.paddedSize(of: wire.count + 600) == 2_048)
    }

    @Test func secretsKeepGoingIn() throws {
        var (alice, bob) = try pair()
        try talk(&alice, &bob, rounds: 150)
        let a = alice.postQuantumEpochs, b = bob.postQuantumEpochs
        #expect(a.offered >= 3 && a.answered >= 3 && b.offered >= 3 && b.answered >= 3, "\(a) \(b)")
        #expect(a.offered == b.answered && a.answered == b.offered, "Both sides count the same epochs")
    }

    @Test func theSecretReallyIsInTheRoot() throws {
        var (alice, bob) = try pair()
        // Run until the first secret has been decapsulated on Alice's side and is waiting.
        var steps = 0
        while steps < 200 {
            let json = try JSONSerialization.jsonObject(with: saved(alice)) as! [String: Any]
            if let q = json["pq"] as? [String: Any], q["offerSecret"] != nil { break }
            try talk(&alice, &bob, rounds: 1)
            steps += 1
        }
        #expect(steps < 200)
        // A thief who has everything but that secret: Alice with a wrong one.
        var json = try JSONSerialization.jsonObject(with: saved(alice)) as! [String: Any]
        var q = json["pq"] as! [String: Any]
        q["offerSecret"] = Data(repeating: 1, count: 32).base64EncodedString()
        json["pq"] = q
        var thief = try JSONDecoder().decode(Ratchet.self, from: JSONSerialization.data(withJSONObject: json))
        var failures = 0
        for i in 0..<12 {
            let b = try bob.encrypt(Data("b\(i)".utf8))
            if (try? thief.decrypt(b)) == nil { failures += 1 }
            _ = try alice.decrypt(b)
            _ = try bob.decrypt(alice.encrypt(Data("a\(i)".utf8)))
        }
        #expect(failures > 0, "Without the post-quantum secret, a chain that mixed it in doesn't open")
    }

    @Test func survivesRestartsAtEveryStep() throws {
        var (alice, bob) = try pair()
        try talk(&alice, &bob, rounds: 100, restarting: true)
        #expect(alice.postQuantumEpochs.offered >= 2 && bob.postQuantumEpochs.offered >= 2)
    }

    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6])
    func lossReorderingAndDuplicatesNeverBreakIt(seed: UInt64) throws {
        var dice = Dice(state: seed)
        var (alice, bob) = try pair()
        var toAlice: [(RatchetMessage, String)] = [], toBob: [(RatchetMessage, String)] = []
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        var delivered = 0
        var sentA = 0, sentB = 0
        // `deliver` is run twice a round, once for each side.
        func deliver(_ queue: inout [(RatchetMessage, String)], to r: inout Ratchet) throws {
            guard !queue.isEmpty else { return }
            let at = Int.random(in: 0..<min(queue.count, 4), using: &dice)
            let (m, expected) = queue.remove(at: at)
            switch Int.random(in: 0..<10, using: &dice) {
            case 0: return // lost
            case 1:
                #expect(text(try r.decrypt(m)) == expected)
                delivered += 1
                // Again: refused, and nothing changes.
                let before = try saved(r)
                #expect(throws: RatchetError.self) { _ = try r.decrypt(m) }
                #expect(try saved(r) == before)
            default:
                #expect(text(try r.decrypt(m)) == expected)
                delivered += 1
            }
        }
        for _ in 0..<400 {
            let speaker = Bool.random(using: &dice)
            for _ in 0..<Int.random(in: 1...3, using: &dice) {
                if speaker {
                    toBob.append((try alice.encrypt(Data("a\(sentA)".utf8)), "a\(sentA)"))
                    sentA += 1
                } else {
                    toAlice.append((try bob.encrypt(Data("b\(sentB)".utf8)), "b\(sentB)"))
                    sentB += 1
                }
            }
            try deliver(&toAlice, to: &alice)
            try deliver(&toBob, to: &bob)
        }
        #expect(delivered > 300)
        // Secrets kept going in despite a tenth of everything lost.
        #expect(alice.postQuantumEpochs.offered + bob.postQuantumEpochs.offered >= 2,
                "\(alice.postQuantumEpochs) \(bob.postQuantumEpochs)")
    }

    @Test func aFailedOrForgedMessageChangesNothing() throws {
        var (alice, bob) = try pair()
        try talk(&alice, &bob, rounds: 20)
        let before = try saved(alice)
        let good = try bob.encrypt(Data("hello".utf8))

        var wrongChunk = good
        wrongChunk.header.pq![10] ^= 1
        var wrongAck = good
        wrongAck.header.pd = 7
        var wrongMix = good
        wrongMix.header.pm = 1
        var wrongBody = good
        wrongBody.ciphertext[0] ^= 1
        var dropped = good
        dropped.header.pq = nil
        var shortChunk = good
        shortChunk.header.pq = Data(repeating: 9, count: 5)
        for forged in [wrongChunk, wrongAck, wrongMix, wrongBody, dropped, shortChunk] {
            #expect(throws: RatchetError.self) { _ = try alice.decrypt(forged) }
            #expect(try saved(alice) == before, "A refused message leaves the state exactly as it was")
        }
        #expect(text(try alice.decrypt(good)) == "hello")
    }

    @Test func skippedKeyLimitStillHolds() throws {
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        var late: RatchetMessage?
        for i in 0...(Int(Ratchet.maxSkip) + 1) { late = try alice.encrypt(Data("m\(i)".utf8)) }
        let before = try saved(bob)
        #expect(throws: RatchetError.tooManySkipped) { _ = try bob.decrypt(late!) }
        #expect(try saved(bob) == before)
    }

    @Test func buildsFromBeforeAreRefusedByName() throws {
        var (alice, bob) = try pair()
        let m = try bob.encrypt(Data("hi".utf8))
        for v in [nil, UInt8(1), UInt8(2)] {
            var old = m
            old.header.v = v
            old.header.pq = nil
            #expect(throws: RatchetError.peerTooOld) { _ = try alice.decrypt(old) }
        }
        #expect(text(try alice.decrypt(m)) == "hi")
    }

    @Test func sessionsSavedBeforeLoadAndStartTheNewRatchet() throws {
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        // What the previous build saved: its refresh fields and the old binding flag, and none of the new ones.
        func asSavedBefore(_ r: Ratchet) throws -> Ratchet {
            var json = try JSONSerialization.jsonObject(with: saved(r)) as! [String: Any]
            json.removeValue(forKey: "pq")
            json.removeValue(forKey: "sendMix")
            json["pqMessages"] = 7
            json["peerBinds"] = true
            json["kemSeed"] = Data(repeating: 4, count: 64).base64EncodedString()
            json["kemPublic"] = Data(repeating: 5, count: 1184).base64EncodedString()
            return try JSONDecoder().decode(Ratchet.self, from: JSONSerialization.data(withJSONObject: json))
        }
        alice = try asSavedBefore(alice)
        bob = try asSavedBefore(bob)
        #expect(alice.postQuantumEpochs.offered == 0)
        try talk(&alice, &bob, rounds: 120)
        #expect(alice.postQuantumEpochs.offered >= 2 && bob.postQuantumEpochs.offered >= 2)
        let json = try JSONSerialization.jsonObject(with: saved(alice)) as! [String: Any]
        #expect(json["kemSeed"] == nil && json["peerBinds"] == nil && json["pqMessages"] == nil, "The old fields are gone once saved again")
    }
}
