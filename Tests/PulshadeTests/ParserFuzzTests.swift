import Testing
import Foundation
import PulshadeShared
@testable import Pulshade

/// Crash-only robustness tests for every parser that touches bytes or text from another person or the relay.
///
/// These are not trying to prove a parser *accepts* the right things (the focused tests do that). They are
/// trying to prove it never traps: no index out of range, no force unwrap, no integer conversion failure, no
/// unbounded recursion. That is the class of bug a remote peer can turn into "the app dies when you open it".
///
/// Deterministic: a failing seed reproduces the exact input.
@Suite(.serialized) struct ParserFuzzTests {
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

    private func randomText(length: Int, dice: inout Dice) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        for _ in 0..<length { bytes.append(UInt8.random(in: 32...126, using: &dice)) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func randomBytes(length: Int, dice: inout Dice) -> Data {
        Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &dice) })
    }

    /// Everything that consumes a scanned/pasted/linked code. Each must return nil or a value, never crash.
    @Test func codeParsersNeverTrap() {
        var dice = Dice(state: 0xC0DE_1234_5678_9ABC)
        let prefixes = ["", "psh1", "psh2", "pshjoin1", "pshchat1", "pshcall1", "pshgroup1",
                        "pulshade://", "pulshade://join/", "@", "http://", "https://", "a"]
        for _ in 0..<4_000 {
            let body = randomText(length: Int.random(in: 0...120, using: &dice), dice: &dice)
            let text = (prefixes.randomElement(using: &dice) ?? "") + body
            _ = Base32.decode(text)
            _ = Invite(code: text)
            _ = ChatLink(text)
            _ = Invite.allowedRelay(text)
            _ = Data(hexString: text)
            if let url = URL(string: text) { _ = LinkPreviews.openable(url) }
        }
    }

    /// Wallet addresses and links arrive in other people's profiles and are parsed on every refresh. Bech32 in
    /// particular slices out a witness program: a data part holding only the six checksum characters once produced the
    /// empty range `1..<0` and trapped, which a contact could turn into a crash on every profile refresh. Fuzz it with
    /// short, checksum-shaped and arbitrary inputs.
    @Test func walletAndProfileLinkParsersNeverTrap() {
        var dice = Dice(state: 0xBEEF_0BAD_1234_5678)
        let bech32 = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let bases = ["", "bc1", "ltc1", "npub1", "bc", "ltc", "npub", "0x", "1", "3", "4", "8"]
        // The exact strings that used to trap, kept as seeds so a regression is caught immediately.
        for seed in ["ltc1pdtjxt", "bc1gmk9yu", "bc1a8xfp7"] {
            for kind in ProfileLinkKind.allCases { _ = kind.normalize(seed) }
        }
        for _ in 0..<6_000 {
            let base = bases.randomElement(using: &dice) ?? ""
            let length = Int.random(in: 0...30, using: &dice)
            let body = String((0..<length).map { _ in bech32[Int.random(in: 0..<bech32.count, using: &dice)] })
            let text = base + body
            for kind in ProfileLinkKind.allCases {
                _ = kind.normalize(text)
                _ = ProfileLink.make(kind, from: text)
            }
            _ = ProfileLink.cleaned(ProfileLinkKind.allCases.map { ProfileLink(kind: $0, value: text) })
        }
        // Arbitrary printable text through every kind as well.
        for _ in 0..<2_000 {
            let text = randomText(length: Int.random(in: 0...120, using: &dice), dice: &dice)
            for kind in ProfileLinkKind.allCases { _ = kind.normalize(text) }
        }
    }

    /// The wire framers and payload decoder see raw bytes from the relay. Fuzz them with arbitrary and
    /// length-lying inputs.
    @Test func binaryFramingNeverTraps() throws {
        var dice = Dice(state: 0x0BAD_F00D_DEAD_BEEF)
        for _ in 0..<3_000 {
            let data = randomBytes(length: Int.random(in: 0...300, using: &dice), dice: &dice)
            _ = Frame.split(data)
            _ = try? Payload.fromWire(data)
        }

        // A frame that claims more bytes than it has, and one that claims zero.
        for claimed in [0, 1, 4, 31, 32, 1_000, UInt32.max] {
            var framed = withUnsafeBytes(of: claimed.bigEndian) { Data($0) }
            framed.append(randomBytes(length: Int.random(in: 0...8, using: &dice), dice: &dice))
            if let parts = Frame.split(framed) {
                #expect(parts.tail.count <= framed.count)
            }
        }
    }

    /// Base32 is the layer under every code: it must round-trip exactly and reject non-alphabet input without
    /// indexing out of bounds. It also takes a length prefix from callers, so feed it lengths that don't fit.
    @Test func base32RoundTripsAndRejects() {
        var dice = Dice(state: 0xFEED_FACE_CAFE_0001)
        for _ in 0..<400 {
            let data = randomBytes(length: Int.random(in: 0...256, using: &dice), dice: &dice)
            let encoded = Base32.encode(data)
            #expect(Base32.decode(encoded) == data)
            // Corrupt one character: it must return a value or nil, never trap.
            if !encoded.isEmpty {
                var chars = Array(encoded)
                chars[Int.random(in: 0..<chars.count, using: &dice)] = "!"
                _ = Base32.decode(String(chars))
            }
        }
        // Empty is empty; anything outside the Crockford alphabet is refused.
        #expect(Base32.decode("") == Data())
        #expect(Base32.decode("!!!!") == nil)
        #expect(Base32.decode("ABC") != nil)
        #expect(Base32.decode("abc") == nil)
    }
}
