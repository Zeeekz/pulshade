import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// Files kept on the relay: what the phones do to them before and after. The relay side has its own tests.
struct BlobTests {
    private func attachment(size: Int = 1000) -> Pulshade.Attachment {
        Pulshade.Attachment(id: Data.random(16).hex, key: .random(32), size: size, kind: .file, name: "a.txt", type: "text/plain",
                   sha256: Data(SHA256.hash(data: Data(count: 32))), secret: .random(32), expires: Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test func pieceMathMatchesWhatTheRelayStores() {
        #expect(BlobCrypto.pieceCount(of: 1) == 1)
        #expect(BlobCrypto.sealedSize(of: 1) == 17)
        #expect(BlobCrypto.pieceCount(of: BlobCrypto.plainPiece) == 1)
        #expect(BlobCrypto.sealedSize(of: BlobCrypto.plainPiece) == BlobCrypto.sealedPiece, "a full piece is exactly 1 MiB sealed")
        #expect(BlobCrypto.pieceCount(of: BlobCrypto.plainPiece + 1) == 2)
        #expect(BlobCrypto.sealedSize(of: BlobCrypto.maxFile) == BlobCrypto.maxFile + BlobCrypto.pieceCount(of: BlobCrypto.maxFile) * 16)
        #expect(BlobCrypto.sealedRange(of: 2) == 2_097_152...3_145_727)
    }

    @Test func aPieceOpensOnlyWithItsOwnPlace() throws {
        let key = Data.random(32), id = Data.random(16).hex
        let plain = Data.random(5000)
        let sealed = try BlobCrypto.seal(plain, key: key, id: id, index: 3, last: false)
        #expect(sealed.count == plain.count + 16)
        #expect(sealed.range(of: plain.prefix(32)) == nil, "the plaintext isn't in what is sent")
        #expect(try BlobCrypto.open(sealed, key: key, id: id, index: 3, last: false) == plain)
        #expect(throws: BlobError.damaged) { try BlobCrypto.open(sealed, key: key, id: id, index: 4, last: false) }
        #expect(throws: BlobError.damaged) { try BlobCrypto.open(sealed, key: key, id: id, index: 3, last: true) }
        #expect(throws: BlobError.damaged) { try BlobCrypto.open(sealed, key: key, id: Data.random(16).hex, index: 3, last: false) }
        #expect(throws: BlobError.damaged) { try BlobCrypto.open(sealed, key: .random(32), id: id, index: 3, last: false) }
        var flipped = sealed
        flipped[10] ^= 1
        #expect(throws: BlobError.damaged) { try BlobCrypto.open(flipped, key: key, id: id, index: 3, last: false) }
        #expect(throws: BlobError.damaged) { try BlobCrypto.open(Data(sealed.dropLast(1)), key: key, id: id, index: 3, last: false) }
    }

    @Test func aWholeFileSealsAndOpensPieceByPiece() throws {
        let key = Data.random(32), id = Data.random(16).hex
        let plain = Data.random(BlobCrypto.plainPiece * 2 + 777)
        let count = BlobCrypto.pieceCount(of: plain.count)
        #expect(count == 3)
        var sealed = Data()
        for i in 0..<count {
            let from = i * BlobCrypto.plainPiece
            sealed += try BlobCrypto.seal(plain.subdata(in: from..<min(from + BlobCrypto.plainPiece, plain.count)), key: key, id: id, index: i, last: i == count - 1)
        }
        #expect(sealed.count == BlobCrypto.sealedSize(of: plain.count))
        var opened = Data()
        for i in 0..<count {
            let r = BlobCrypto.sealedRange(of: i)
            opened += try BlobCrypto.open(sealed.subdata(in: r.lowerBound..<min(r.upperBound + 1, sealed.count)), key: key, id: id, index: i, last: i == count - 1)
        }
        #expect(opened == plain)
    }

    @Test func aFileCutShortOrReorderedFailsToOpen() throws {
        let key = Data.random(32), id = Data.random(16).hex
        let a = try BlobCrypto.seal(Data.random(100), key: key, id: id, index: 0, last: false)
        // A copy cut off after the first piece claims to be the last one only if it is sealed that way.
        #expect(throws: BlobError.damaged) { try BlobCrypto.open(a, key: key, id: id, index: 0, last: true) }
    }

    @Test func receivedAttachmentsAreCheckedBeforeUse() {
        #expect(attachment().isValid)
        var bad = attachment(); bad.id = "../etc/passwd"; #expect(!bad.isValid)
        bad = attachment(); bad.id = String(repeating: "A", count: 32); #expect(!bad.isValid, "ids are lowercase hex")
        bad = attachment(); bad.key = Data(count: 31); #expect(!bad.isValid)
        bad = attachment(); bad.size = 0; #expect(!bad.isValid)
        bad = attachment(); bad.size = BlobCrypto.maxFile + 1; #expect(!bad.isValid)
        bad = attachment(); bad.name = String(repeating: "x", count: 300); #expect(!bad.isValid)
    }

    @Test func aShownNameHasNoFoldersOrControlCharacters() {
        var a = attachment()
        a.name = "../../Library/evil\u{0}.txt"
        #expect(a.shownName == "evil.txt")
        a.name = "  "
        #expect(a.shownName == "File")
        a.name = nil
        #expect(a.shownName == "File")
    }

    @Test func aMessageCarriesAnAttachmentToAnOlderAppAsWords() throws {
        let a = attachment()
        let wire = WireMessage(id: UUID(), conversation: nil, kind: .direct, text: "📎 a.txt (a file: update Pulshade to open it)", image: nil,
                               voice: nil, date: Date(), expiresIn: nil, reply: nil, preview: nil, attachment: a)
        let data = try JSONEncoder.pulshade.encode(wire)
        #expect(try JSONDecoder.pulshade.decode(WireMessage.self, from: data).attachment == a)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["attachment"] = nil
        let old = try JSONDecoder.pulshade.decode(WireMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.attachment == nil && old.text.contains("a.txt"), "an app that doesn't know files just shows the words")
    }

    @Test func hexRoundTrips() {
        let bytes = Data.random(40)
        #expect(Data(hexString: bytes.hex) == bytes)
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
    }
}

/// The phones' half and the relay's half together: a real file goes up in pieces, comes back byte for byte, and is erased.
/// Needs a throwaway relay (scripts/test.sh starts one).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct BlobRelayTests {
    private func client() throws -> RelayClient {
        RelayClient(base: try #require(URL(string: ProcessInfo.processInfo.environment["PULSHADE_TEST_RELAY"] ?? "http://127.0.0.1:7890")), lane: "blob-test")
    }

    private func file(size: Int) throws -> (URL, Data) {
        let data = Data.random(size)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blobtest-\(UUID().uuidString).bin")
        try data.write(to: url)
        return (url, data)
    }

    @Test func aFileGoesUpComesBackAndIsErased() async throws {
        let relay = try client()
        let (url, original) = try file(size: BlobCrypto.plainPiece * 2 + 12_345)
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try BlobTransfer.prepare(url)
        #expect(prepared.attachment.size == original.count)
        #expect(prepared.attachment.pieceCount == 3)
        try await BlobTransfer.upload(prepared, to: relay) { _ in }
        let head = try #require(try await relay.blobHead(prepared.attachment.id))
        #expect(head.complete && head.size == prepared.attachment.sealedSize)
        let back = try await BlobTransfer.download(prepared.attachment, from: relay) { _ in }
        #expect(back == original)
        // Another test locking an app at the same moment drops every connection in the process, which can cut the
        // erase off part way (and then whether it landed isn't known). Tried again until it says so or the file is gone.
        var erased = await BlobTransfer.erase(prepared.attachment, from: relay)
        for _ in 0..<2 where !erased {
            erased = try await relay.blobHead(prepared.attachment.id) == nil ? true : await BlobTransfer.erase(prepared.attachment, from: relay)
        }
        #expect(erased)
        #expect(try await relay.blobHead(prepared.attachment.id) == nil, "gone from the relay once erased")
        await #expect(throws: BlobError.gone) { _ = try await BlobTransfer.download(prepared.attachment, from: relay) { _ in } }
    }

    @Test func aWrongSecretErasesNothing() async throws {
        let relay = try client()
        let (url, _) = try file(size: 5000)
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try BlobTransfer.prepare(url)
        try await BlobTransfer.upload(prepared, to: relay) { _ in }
        await #expect(throws: (any Error).self) { try await relay.blobDelete(prepared.attachment.id, secret: .random(32)) }
        #expect(try await relay.blobHead(prepared.attachment.id) != nil)
        _ = await BlobTransfer.erase(prepared.attachment, from: relay)
    }

    @Test func aChangedFileIsNotAccepted() async throws {
        let relay = try client()
        let (url, _) = try file(size: 70_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var prepared = try BlobTransfer.prepare(url)
        try await BlobTransfer.upload(prepared, to: relay) { _ in }
        prepared.attachment.sha256 = Data(SHA256.hash(data: Data("other".utf8)))
        await #expect(throws: BlobError.damaged) { _ = try await BlobTransfer.download(prepared.attachment, from: relay) { _ in } }
        prepared.attachment.sha256 = (try BlobTransfer.prepare(url)).attachment.sha256
        _ = await BlobTransfer.erase(prepared.attachment, from: relay)
    }
}
