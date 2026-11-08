import Testing
import Foundation
import CryptoKit
@testable import Pulshade

struct LimitsTests {
    @Test func readsOpenGraphTagsInAnyOrder() {
        let html = """
        <html><head><title>Fallback</title>
        <meta content="A &amp; B" property="og:title">
        <META PROPERTY='og:site_name' CONTENT='Example'>
        <meta property="og:image" content="/img/card.png">
        </head></html>
        """
        let meta = LinkPreviews.Meta(html: html)
        #expect(meta.title == "A & B")
        #expect(meta.site == "Example")
        #expect(meta.image == "/img/card.png")
    }

    @Test func fallsBackToTheTitleTag() {
        let meta = LinkPreviews.Meta(html: "<head><title>\n  Just   a page </title></head>")
        #expect(meta.title == "Just a page")
        #expect(meta.site == nil && meta.image == nil)
    }

    @Test func clockOffsetRoundTrips() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RelayClock.local(RelayClock.relay(date)) == date)
    }

    /// The relay checks the same vector, so both hash a proof the same way.
    @Test func proofOfWorkMatchesTheRelay() {
        let first = (0...).first { n in
            Work.leadingZeroBits(SHA256.hash(data: Data("pulshade.pow.v1|vector|1800000000|\(n)".utf8))) >= Work.bits
        }
        #expect(first == 19909)
        let proof = Work.proof(for: "lookup|someone").split(separator: ":")
        let digest = SHA256.hash(data: Data("pulshade.pow.v1|lookup|someone|\(proof[0])|\(proof[1])".utf8))
        #expect(Work.leadingZeroBits(digest) >= Work.bits)
    }
}
