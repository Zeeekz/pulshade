import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// Short web links (`pulsh.me/i/<24 letters>`): the letters, where they're listed, and what's sealed under them.
@Suite(.serialized)
struct ShortLinkTests {
    @Test func lettersRoundTripAndListUnderAHandleNobodyCanPick() {
        let code = ShortCode.make()
        #expect(code.text.count == 24 && ShortCode(code.text) == code && ShortCode(code.text.uppercased()) == code)
        #expect(ShortCode("short") == nil && ShortCode(String(repeating: "u", count: 24)) == nil && ShortCode(String(code.text.prefix(16))) == nil)
        #expect(code.listing.count == 24 && code.listing.hasPrefix("_"))
        #expect(DirectoryProfile.validHandle(code.listing) == code.listing, "a name the relay takes")
        #expect(!code.listing.contains(code.text), "the listing says nothing of the letters")
        #expect(ShortCode.make().listing != code.listing)
    }

    @Test func onlyTheLettersOpenItAndOnlyTheKeyItNamesSignsIt() throws {
        let code = ShortCode.make(), key = Curve25519.Signing.PrivateKey()
        let target = try Invite(kind: .contact, identity: .generate(), sendID: .random(32)).code
        let entry = try #require(code.entry(.init(target: target), key: key, updated: 60_000))
        #expect(code.read(entry) == .init(target: target))
        #expect(try #require(Data(base64Encoded: entry.blob)).count == ShortCode.paddedSize + 28, "every link one size")
        #expect(ShortCode.make().read(entry) == nil, "other letters don't open it")

        var forged = entry
        forged.key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(code.read(forged) == nil)
        var stamped = entry
        stamped.updated += 1
        #expect(code.read(stamped) == nil)

        let revoked = try #require(code.entry(.init(target: nil, revoked: true), key: key, updated: 120_000))
        #expect(code.read(revoked)?.revoked == true)
    }

    @Test func webLinksCarryTheShortLetters() {
        WebLinks.domainOverride = "pul.sh"
        defer { WebLinks.domainOverride = nil }
        let code = ShortCode.make()
        #expect(WebLinks.short(code) == "https://pul.sh/i/" + code.text)
        #expect(WebLinks.parse(URL(string: WebLinks.short(code))!) == .short(code))
        #expect(WebLinks.parse(URL(string: "https://pul.sh/i/" + code.text.uppercased())!) == .short(code))
    }

    /// A channel's code comes out different each time it's made (its signature does), and a screen asks for it at every
    /// redraw: two codes for the same invite share one short link, so they can't make one each.
    @MainActor @Test func codesForTheSameInviteShareOneShortLink() throws {
        let model = testModel("pulshade-short")
        let id = Identity.generate(), box = Data.random(32)
        let a = try Invite(kind: .channel, identity: id, sendID: box, channel: UUID()).code
        let b = try Invite(kind: .channel, identity: id, sendID: box, channel: UUID()).code
        #expect(a != b)
        #expect(model.shortKey(a) == model.shortKey(b))
        #expect(model.shortKey(a) != model.shortKey(try Invite(kind: .channel, identity: id, sendID: .random(32)).code))
    }
}
