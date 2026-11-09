import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// Parsers that handle bytes from other people, or from a hostile relay, must refuse bad input cleanly and never
/// trap. These are deterministic: a seeded generator means a failure can be reproduced exactly.
struct RobustnessTests {
    /// A small reproducible generator; `SystemRandomNumberGenerator` would hide the failing input.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private func bytes(_ count: Int, _ rng: inout Seeded) -> Data {
        var out = Data(capacity: count)
        for _ in 0..<count { out.append(UInt8.random(in: .min ... .max, using: &rng)) }
        return out
    }

    private func text(_ count: Int, _ rng: inout Seeded) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/\\ .:@")
        return String((0..<count).map { _ in alphabet.randomElement(using: &rng)! })
    }

    @Test func arbitraryEnvelopesAreRefused() {
        var rng = Seeded(state: 1)
        let me = Identity.generate()
        for _ in 0..<400 {
            let blob = bytes(Int.random(in: 0...700, using: &rng), &rng)
            _ = try? Envelope.openFull(blob, with: me)
        }
        // Lengths around the header it expects.
        for length in [0, 1, 32, 33, 60, 61, 62, 63] {
            _ = try? Envelope.openFull(Data(repeating: 2, count: length), with: me)
        }
    }

    @Test func everyByteOfASealedEnvelopeMatters() throws {
        let me = Identity.generate(), them = Identity.generate()
        let payload = Payload.typing(conversation: nil)
        let blob = try Envelope.seal(payload, from: them, to: me.card.agreement)
        for i in blob.indices {
            var broken = blob
            broken[i] ^= 0x01
            #expect(throws: (any Error).self, "byte \(i) of \(blob.count) was not covered") {
                try Envelope.openFull(broken, with: me)
            }
        }
        // Nothing longer or shorter opens either.
        for cut in [0, 1, 33, 61, blob.count - 1] where cut < blob.count {
            #expect(throws: (any Error).self) { try Envelope.openFull(Data(blob.prefix(cut)), with: me) }
        }
    }

    @Test func framesSplitWithoutTrustingTheirLength() {
        var rng = Seeded(state: 2)
        for _ in 0..<500 {
            let data = bytes(Int.random(in: 0...100, using: &rng), &rng)
            if let (header, tail) = Frame.split(data) {
                #expect(header.count + tail.count + 5 == data.count)
                #expect(data.first == Frame.mark)
            }
            _ = try? Payload.fromWire(data)
        }
        // A length that claims more than the data holds is refused, and doesn't allocate it.
        #expect(Frame.split(Data([0, 0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3])) == nil)
        #expect(Frame.split(Data([0, 0, 0, 0, 0]))?.tail.isEmpty == true)
        #expect(Frame.split(Data()) == nil)
    }

    @Test func hostileJSONNeverReachesBugs() {
        var rng = Seeded(state: 3)
        let decoder = JSONDecoder.pulshade
        for _ in 0..<300 {
            let junk = bytes(Int.random(in: 0...300, using: &rng), &rng)
            _ = try? decoder.decode(Payload.self, from: junk)
            _ = try? decoder.decode(GroupInfo.self, from: junk)
            _ = try? decoder.decode(Attachment.self, from: junk)
            _ = try? decoder.decode(Message.self, from: junk)
        }
        for hostile in ["{", "[]", "null", "{\"ratchet\":{}}", "{\"message\":{\"text\":\"x\"}}"] {
            _ = try? decoder.decode(Payload.self, from: Data(hostile.utf8))
        }
    }

    @Test func base32AndHexRoundTrip() {
        var rng = Seeded(state: 4)
        for count in 0...80 {
            let raw = bytes(count, &rng)
            #expect(Base32.decode(Base32.encode(raw)) == raw)
            #expect(Data(hexString: raw.hex) == raw)
        }
        // Broken spellings and lengths are refused, not guessed at.
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
        #expect(Base32.decode("!") == nil)
        #expect(Base32.decode("") == Data())
    }

    @Test func codesRefuseGarbageWithoutCrashing() {
        var rng = Seeded(state: 5)
        for _ in 0..<200 {
            let junk = text(Int.random(in: 0...90, using: &rng), &rng)
            _ = Invite(code: junk)
            _ = LinkCode(junk)
            _ = JoinCode(junk)
            _ = ChatLink(junk)
            _ = ChatCode(junk)
            if let url = URL(string: "pulshade://u/\(junk)") { _ = DirectoryProfile.handle(fromLink: url) }
        }
        for junk in ["", "psh1", "pshchat1", "pshlink1", "pshjoin1", "pulshade://"] {
            _ = Invite(code: junk)
            _ = ChatLink(junk)
            _ = LinkCode(junk)
            _ = JoinCode(junk)
        }
    }

    @Test func aChangedFilePieceNeverOpens() throws {
        let key = Data.random(32)
        let id = Data.random(16).hex
        let plain = Data((0..<4_000).map { i in UInt8(i % 251) })
        let sealed = try BlobCrypto.seal(plain, key: key, id: id, index: 2, last: false)
        #expect(try BlobCrypto.open(sealed, key: key, id: id, index: 2, last: false) == plain)

        func refused(_ piece: Data, key: Data = key, id: String = id, index: Int = 2, last: Bool = false) {
            #expect(throws: (any Error).self) { try BlobCrypto.open(piece, key: key, id: id, index: index, last: last) }
        }
        var broken = sealed
        broken[broken.startIndex] ^= 0x01
        refused(broken)
        refused(sealed.dropLast(1))
        refused(sealed, key: Data.random(32))
        refused(sealed, id: Data.random(16).hex)
        refused(sealed, index: 3)
        refused(sealed, last: true)
        // Tampered in each part: nonce is derived, so the ciphertext and tag are what's covered.
        for offset in [0, sealed.count - 16, sealed.count - 1] where sealed.indices.contains(sealed.startIndex + offset) {
            var piece = sealed
            piece[piece.startIndex + offset] ^= 0x80
            refused(piece)
        }
    }

    @Test func attachmentsCheckTheirShape() {
        let good = Attachment(id: Data.random(16).hex, key: .random(32), size: 10, kind: .file, name: "a.txt",
                              type: "text/plain", sha256: .random(32), secret: .random(32),
                              expires: Date().addingTimeInterval(600))
        #expect(good.isValid)
        #expect(good.shownName == "a.txt")
        #expect(!Attachment(id: "short", key: .random(32), size: 10, kind: .file, sha256: .random(32),
                            secret: .random(32), expires: Date()).isValid)
        #expect(!Attachment(id: good.id, key: .random(31), size: 10, kind: .file, sha256: .random(32),
                            secret: .random(32), expires: Date()).isValid)
        #expect(!Attachment(id: good.id, key: .random(32), size: 0, kind: .file, sha256: .random(32),
                            secret: .random(32), expires: Date()).isValid)
        // A name never carries a folder or control characters into a save dialog.
        var named = good
        named.name = "../../etc/pass\u{0}wd"
        #expect(named.shownName == "passwd") // control characters removed, folders never shown
    }
}
