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

    /// The relay checks the same vector, so both hash a proof the same way. (19 bits here: the vector is about the hash, not the
    /// difficulty, which is the relay's to ask for.)
    @Test func proofOfWorkMatchesTheRelay() {
        let first = (0...).first { n in
            Work.leadingZeroBits(SHA256.hash(data: Data("pulshade.pow.v2|vector|1800000000|\(n)".utf8))) >= 19
        }
        #expect(first == 30409)
        let proof = Work.proof(for: "lookup|someone", bits: 19).split(separator: ":")
        #expect(proof.count == 3 && proof[0] == "2")
        let digest = SHA256.hash(data: Data("pulshade.pow.v2|lookup|someone|\(proof[1])|\(proof[2])".utf8))
        #expect(Work.leadingZeroBits(digest) >= 19)
        // The faster solver finds the same kind of proof as hashing a whole string would.
        let nonce = Work.solve(prefix: "pulshade.pow.v2|x|1|", bits: 16)
        #expect(Work.leadingZeroBits(SHA256.hash(data: Data("pulshade.pow.v2|x|1|\(nonce)".utf8))) >= 16)
    }

    /// The table of how much work each route asks for is the relay's too, and stays inside what a phone can do.
    @Test func workIsAskedForByRouteAndCapped() {
        for bound in ["lookup|someone", "announcements", "mine", "held", "update", "backup-read|k"] { #expect(Work.baseBits(for: bound) == Work.light) }
        for bound in ["claim|someone", "retire", "backup|k", "burn", "push", "group|id", "giveaway-claim", "collectible-claim"] {
            #expect(Work.baseBits(for: bound) == Work.heavy)
        }
        Work.learn(Work.ceiling + 5, for: "lookup|a")
        #expect(Work.bits(for: "lookup|a") == Work.light, "an absurd ask is not learned")
        Work.learn(25, for: "lookup|a")
        #expect(Work.bits(for: "lookup|b") == 25, "what the relay asked of a route is used for that route")
        #expect(Work.bits(for: "claim|a") == Work.heavy)
    }

    /// SEC-204: a level the relay asked for during a flood wears off as requests go through, rather than lasting ten minutes.
    @Test func aLearnedLevelStepsDownAfterSuccessesAtItAndNotBeforeTheGapHasPassed() {
        let route = "lookup|decay", start = Date()
        Work.learn(27, for: route, now: start)
        #expect(Work.bits(for: route) == 27)
        Work.accepted(route, now: start.addingTimeInterval(5))
        #expect(Work.bits(for: route) == 27, "not stepped down straight away: a busy relay would be asked again at once")
        var t = start
        for expected in stride(from: 26, through: Work.light + 1, by: -1) {
            t = t.addingTimeInterval(Work.decayEvery + 1)
            Work.accepted(route, now: t)
            #expect(Work.bits(for: route) == expected)
        }
        t = t.addingTimeInterval(Work.decayEvery + 1)
        Work.accepted(route, now: t)
        #expect(Work.bits(for: route) == Work.light, "back to the base, and forgotten")
        // A heavy route never decays below its own base.
        Work.learn(24, for: "claim|decay", now: start)
        Work.accepted("claim|decay", now: start.addingTimeInterval(Work.decayEvery + 1))
        #expect(Work.bits(for: "claim|decay") == Work.heavy)
    }

    /// How long the work takes here, for the record: the heavy route's share of a second on one core.
    @Test func aHeavyProofIsQuick() {
        let start = Date()
        _ = Work.proof(for: "backup|speed", bits: Work.heavy)
        let seconds = Date().timeIntervalSince(start)
        print("PoW \(Work.heavy) bits took \(seconds) s")
        #expect(seconds < 10)
    }
}
