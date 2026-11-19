import Testing
import Foundation
@testable import Pulshade

/// A deterministic mutation fuzzer for every parser that takes bytes or text from another person or the relay.
/// It is gated on `PULSHADE_FUZZ_SECONDS`, so the normal suite stays quick: `scripts/fuzz.sh 60` sets it and
/// builds with AddressSanitizer. This is mutation fuzzing, not coverage-guided — Swift's driver here does not
/// accept libFuzzer's `-sanitize=fuzzer`.
@Suite(.serialized) struct MutationFuzzerTests {
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func parsersSurviveMutation() {
        guard let raw = ProcessInfo.processInfo.environment["PULSHADE_FUZZ_SECONDS"],
              let seconds = Double(raw), seconds > 0 else { return }

        let seeds: [Data] = [
            Data("pulshade://join/pshjoin1AAAAAAAAAAAAAAAA".utf8),
            Data("pulshade://chat/pshchat1AAAAAAAAAAAAAAAA".utf8),
            Data("pulshade://group/pshgroup1AAAAAAAAAAAA".utf8),
            Data("pshcall1AAAAAAAAAAAAAAAA".utf8),
            Data("@handle".utf8),
            Data("https://example.com/x".utf8),
            Data([0, 0, 0, 0, 3, 1, 2, 3]),
        ]

        func exercise(_ bytes: Data) {
            let text = String(decoding: bytes, as: UTF8.self)
            _ = Frame.split(bytes)
            _ = try? Payload.fromWire(bytes)
            _ = Base32.decode(text)
            _ = Invite(code: text)
            _ = JoinCode(text)
            _ = ChatLink(text)
            _ = Data(hexString: text)
            if let url = URL(string: text) { _ = LinkPreviews.openable(url) }
        }

        var rng = SplitMix64(state: 0xC0FFEE)
        var corpus = seeds
        let started = Date()
        var iterations = 0
        print("mutation fuzzing for \(Int(seconds))s, rng seed 0xC0FFEE")

        while Date().timeIntervalSince(started) < seconds {
            var bytes = Array(corpus.randomElement(using: &rng) ?? Data())
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                switch Int.random(in: 0..<6, using: &rng) {
                case 0 where !bytes.isEmpty:
                    bytes[Int.random(in: 0..<bytes.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
                case 1 where !bytes.isEmpty:
                    bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                case 2:
                    let at = Int.random(in: 0...bytes.count, using: &rng)
                    let count = Int.random(in: 1...8, using: &rng)
                    bytes.insert(contentsOf: (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }, at: at)
                case 3 where !bytes.isEmpty:
                    let at = Int.random(in: 0..<bytes.count, using: &rng)
                    let count = Int.random(in: 1...min(8, bytes.count - at), using: &rng)
                    bytes.removeSubrange(at..<(at + count))
                case 4 where !bytes.isEmpty:
                    let at = Int.random(in: 0..<bytes.count, using: &rng)
                    let count = Int.random(in: 1...min(16, bytes.count - at), using: &rng)
                    let slice = bytes[at..<(at + count)]
                    bytes.insert(contentsOf: slice, at: at)
                default:
                    break
                }
                if bytes.count > 8_192 { bytes.removeSubrange(8_192..<bytes.count) }
            }

            exercise(Data(bytes))
            iterations += 1
            if corpus.count < 4_096, rng.next() % 500 == 0 { corpus.append(Data(bytes)) }
            if iterations % 20_000 == 0 {
                print("\(iterations) inputs, \(corpus.count) corpus")
            }
        }
        print("done: \(iterations) inputs")
    }
}
