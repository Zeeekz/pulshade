import Testing
import Foundation
import CryptoKit
import PulshadeShared

/// The collectibles list and copies, as the app checks them: only Pulshade's list counts, and only a copy the relay
/// signed for its holder.
struct CollectibleTests {
    private let admin = Curve25519.Signing.PrivateKey()
    private let issuer = Curve25519.Signing.PrivateKey()

    private func file(_ seed: UInt8, _ bytes: Int) -> (Data, CollectibleList.File) {
        let data = Data(repeating: seed, count: bytes)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, CollectibleList.File(sha256: sha, bytes: bytes))
    }

    private func list(version: UInt64 = 1, issuer: Data? = nil) -> CollectibleList {
        let (_, video) = file(1, 300_000), (_, still) = file(2, 40_000)
        return CollectibleList(format: 2, version: version, issuer: (issuer ?? self.issuer.publicKey.rawRepresentation).base64EncodedString(),
                               items: [.init(id: "snowglobe", name: "Snow Globe", blurb: "Shake it.", tier: .common, run: 500,
                                             giftable: true, season: "Winter", video: video, still: still)])
    }

    @Test func onlyTheAdminKeysListOpens() throws {
        let signed = try CollectibleList.Signed.make(list(), signedBy: admin)
        let opened = try #require(signed.open(adminKey: admin.publicKey.rawRepresentation))
        #expect(opened.item("snowglobe")?.run == 500)
        #expect(signed.open(adminKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation) == nil)
        #expect(signed.open(adminKey: nil) == nil, "a build without the admin key believes no list")
        var changed = signed
        changed.manifest = try JSONEncoder().encode(list(version: 9)).base64EncodedString()
        #expect(changed.open(adminKey: admin.publicKey.rawRepresentation) == nil, "a changed list loses its signature")
    }

    @Test func aBadlyFormedListIsRefusedEvenSigned() throws {
        var bad = list()
        bad.items.append(bad.items[0])
        #expect(try CollectibleList.Signed.make(bad, signedBy: admin).open(adminKey: admin.publicKey.rawRepresentation) == nil, "an id twice")
        bad = list()
        bad.items[0].video.bytes = CollectibleList.maxVideo + 1
        #expect(try CollectibleList.Signed.make(bad, signedBy: admin).open(adminKey: admin.publicKey.rawRepresentation) == nil, "too big")
        bad = list()
        bad.format = 3
        #expect(try CollectibleList.Signed.make(bad, signedBy: admin).open(adminKey: admin.publicKey.rawRepresentation) == nil)
    }

    @Test func picturesAreCheckedAgainstTheList() {
        let (data, f) = file(1, 1000)
        #expect(CollectibleList.matches(data, f))
        #expect(!CollectibleList.matches(Data(repeating: 9, count: 1000), f))
        #expect(!CollectibleList.matches(data.prefix(999), f))
    }

    @Test func onlyACopySignedForItsHolderIsGenuine() throws {
        let holder = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let sig = try issuer.signature(for: Collectible.signedPart(item: "snowglobe", serial: 7, owner: holder))
        let copy = Collectible(item: "snowglobe", serial: 7, owner: holder, sig: sig)
        let issuerKey = issuer.publicKey.rawRepresentation
        #expect(copy.isGenuine(for: holder, issuer: issuerKey))
        #expect(!copy.isGenuine(for: other, issuer: issuerKey), "shown by someone else")
        var stolen = copy
        stolen.owner = other
        #expect(!stolen.isGenuine(for: other, issuer: issuerKey), "relabelled for someone else")
        var renumbered = copy
        renumbered.serial = 1
        #expect(!renumbered.isGenuine(for: holder, issuer: issuerKey))
        #expect(!copy.isGenuine(for: holder, issuer: admin.publicKey.rawRepresentation), "only the issuer signs copies")
        #expect(!copy.isGenuine(for: holder, issuer: nil))
    }

    @Test func numberBadges() {
        let cases: [(UInt32, UInt32, Collectible.Badge?)] = [
            (1, 500, .first), (7, 500, .lucky), (3, 500, .topTen), (77, 500, .lucky), (555, 1000, .repeater),
            (123, 500, .straight), (321, 500, .straight), (100, 500, .round), (500, 1000, .round), (19, 500, .topTwentyFive),
            (500, 500, .round), (499, 499, .last), (382, 500, nil), (3, 3, .topTen),
        ]
        for (serial, run, badge) in cases {
            #expect(Collectible.badge(of: serial, run: run) == badge, "#\(serial) of \(run)")
        }
    }

    @Test func showcasesKeepOneOfEach() {
        let a = Collectible(item: "dice", serial: 4, owner: Data([1]), sig: Data([2]))
        let b = Collectible(item: "dice", serial: 5, owner: Data([1]), sig: Data([2]))
        #expect(Collectible.unique([a, a, b, a], limit: 6) == [a, b])
        #expect(Collectible.unique([a, b], limit: 1) == [a])
    }

    @Test func aShowcaseCountsOnlyForTheAccountWhoseKeyVouchesForItsCollector() throws {
        let signing = Curve25519.Signing.PrivateKey(), collector = Curve25519.Signing.PrivateKey()
        let collectorKey = collector.publicKey.rawRepresentation
        let sig = try issuer.signature(for: Collectible.signedPart(item: "dice", serial: 4, owner: collectorKey))
        let copy = Collectible(item: "dice", serial: 4, owner: collectorKey, sig: sig)
        let showcase = try Showcase.make(signing: signing, collector: collectorKey, copies: [copy, copy])
        let issuerKey = issuer.publicKey.rawRepresentation
        #expect(showcase.genuine(for: signing.publicKey.rawRepresentation, issuer: issuerKey) == [copy])
        // Someone else sending the same showcase (their own signing key) shows nothing.
        #expect(showcase.genuine(for: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, issuer: issuerKey).isEmpty)
        // Someone else's collector key vouched for by them doesn't make another's copies theirs.
        let thief = Curve25519.Signing.PrivateKey()
        let stolen = try Showcase.make(signing: thief, collector: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, copies: [copy])
        #expect(Showcase.received(stolen) == nil, "copies not held by the collector are dropped on arrival")
        #expect(Showcase.received(Showcase(collector: Data([1]), cert: showcase.cert, copies: [copy])) == nil)
        var odd = copy
        odd.item = String(repeating: "x", count: 5000)
        #expect(Showcase.received(Showcase(collector: collectorKey, cert: showcase.cert, copies: [odd])) == nil, "bounded on arrival")
        let many = (1...20).map { Collectible(item: "dice", serial: UInt32($0), owner: collectorKey, sig: Data(repeating: 1, count: 64)) }
        #expect(Showcase.received(Showcase(collector: collectorKey, cert: showcase.cert, copies: many))?.copies.count == Showcase.limit)
    }
}
