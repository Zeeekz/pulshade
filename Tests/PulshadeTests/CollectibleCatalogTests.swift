import Testing
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
@testable import Pulshade
import PulshadeShared

/// A square of one colour, `side` pixels across.
func catalogTestFrame(_ side: Int, red: CGFloat, green: CGFloat = 0.2) -> CGImage {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: red, green: green, blue: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()!
}

/// A list item with a small animated picture of `frames` frames, and the picture.
func catalogTestItem(_ id: String, frames: Int = 4, transferable: Bool = true, seed: CGFloat = 0) -> (CollectibleCatalog.Item, Data) {
    let images = (0..<frames).map { catalogTestFrame(32, red: min(1, seed + CGFloat($0) / CGFloat(max(frames, 2)))) }
    let made = CollectibleCatalog.makeArt(frames: images, loop: 2)!
    return (CollectibleCatalog.Item(id: id, name: "Snow Globe", blurb: "Shake it.", category: .items, transferable: transferable, art: made.art),
            made.data)
}

@MainActor
@Suite(.serialized) struct CollectibleCatalogTests {
    let admin = Curve25519.Signing.PrivateKey()
    var adminKey: Data { admin.publicKey.rawRepresentation }

    @Test func aSignedListOpensWithTheAdminKeyOnly() throws {
        let (item, _) = catalogTestItem("snowglobe")
        let list = CollectibleCatalog(version: 1, issued: 0, items: [item])
        let signed = try list.sign(with: admin)
        #expect(try CollectibleCatalog.open(signed, adminKey: adminKey) == list)
        #expect(throws: CollectibleCatalog.Problem.badSignature) {
            try CollectibleCatalog.open(signed, adminKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        }
        #expect(throws: CollectibleCatalog.Problem.badSignature) { try CollectibleCatalog.open(signed, adminKey: nil) }
        // One byte changed: the relay can't edit a word of it.
        var raw = Data(base64Encoded: signed.manifest)!
        raw[raw.count / 2] ^= 1
        #expect(throws: CollectibleCatalog.Problem.badSignature) {
            try CollectibleCatalog.open(.init(manifest: raw.base64EncodedString(), sig: signed.sig), adminKey: adminKey)
        }
        // A signature the admin key made over something else (the bare bytes, without the list's own label) doesn't count.
        let bare = try admin.signature(for: Data(base64Encoded: signed.manifest)!)
        #expect(throws: CollectibleCatalog.Problem.badSignature) {
            try CollectibleCatalog.open(.init(manifest: signed.manifest, sig: bare.base64EncodedString()), adminKey: adminKey)
        }
    }

    @Test func aListThatBreaksTheRulesIsRefusedEvenWhenSigned() throws {
        let (item, _) = catalogTestItem("snowglobe")
        func refused(_ change: (inout CollectibleCatalog) -> Void) -> Bool {
            var list = CollectibleCatalog(version: 1, issued: 0, items: [item])
            change(&list)
            return (try? list.validate()) == nil
        }
        #expect(!refused { _ in })
        #expect(refused { $0.items[0].id = "partyhat" }, "a built-in collectible can't be taken over")
        #expect(refused { $0.items[0].id = "Snow Globe" })
        #expect(refused { $0.items[0].id = String(repeating: "a", count: 33) })
        #expect(refused { $0.items.append($0.items[0]) }, "listed twice")
        #expect(refused { $0.items[0].name = "" })
        #expect(refused { $0.items[0].name = String(repeating: "x", count: 41) })
        #expect(refused { $0.items[0].name = "Two\nlines" })
        #expect(refused { $0.items[0].blurb = String(repeating: "x", count: 241) })
        #expect(refused { $0.items[0].art.frames = 73 })
        #expect(refused { $0.items[0].art.width = 513 })
        #expect(refused { $0.items[0].art.bytes = 512 * 1024 + 1 })
        #expect(refused { $0.items[0].art.loop = 0.1 })
        #expect(refused { $0.items[0].art.sha256 = "nothex" })
        #expect(refused { $0.format = 2 })
        #expect(refused { list in list.items = (0...60).map { var i = item; i.id = "item\($0)"; return i } })
        #expect(refused { list in
            list.items = (0..<13).map { n in
                var i = item; i.id = "big\(n)"; i.art.bytes = 500 * 1024; i.art.sha256 = String(format: "%064x", n); return i
            }
        }, "over 6 MB of pictures together")
        // A list from a later build's format is set aside, not misread.
        var later = CollectibleCatalog(version: 1, issued: 0, items: [item])
        later.format = 2
        let encoded = try JSONEncoder().encode(later)
        let sig = try admin.signature(for: CollectibleCatalog.signedPart(encoded))
        #expect(throws: CollectibleCatalog.Problem.unknownFormat) {
            try CollectibleCatalog.open(.init(manifest: encoded.base64EncodedString(), sig: sig.base64EncodedString()), adminKey: adminKey)
        }
    }

    /// A list made before a later build drew one of its items itself: that build opens it without that item.
    @Test func anItemALaterBuildDrawsItselfIsLeftOutNotTheWholeList() throws {
        let (item, _) = catalogTestItem("snowglobe")
        var taken = item
        taken.id = "partyhat"
        let manifest = try JSONEncoder().encode(CollectibleCatalog(version: 4, issued: 0, items: [item, taken]))
        let sig = try admin.signature(for: CollectibleCatalog.signedPart(manifest))
        let opened = try CollectibleCatalog.open(.init(manifest: manifest.base64EncodedString(), sig: sig.base64EncodedString()), adminKey: adminKey)
        #expect(opened.items == [item])
    }

    @Test func aPictureIsCheckedAgainstTheListBeforeItIsUsed() throws {
        let (item, data) = catalogTestItem("snowglobe", frames: 5)
        #expect(item.art.frames == 5 && item.art.width == 32 && item.art.loop == 2)
        try CollectibleCatalog.checkArt(data, against: item.art)
        var flipped = data
        flipped[flipped.count - 20] ^= 1
        #expect(throws: (any Error).self) { try CollectibleCatalog.checkArt(flipped, against: item.art) }
        var lying = item.art
        lying.frames = 4
        #expect(throws: (any Error).self) { try CollectibleCatalog.checkArt(data, against: lying) }
        // Not a PNG at all, even with a matching hash.
        let jpeg = Data("not a png".utf8)
        let art = CollectibleCatalog.Art(sha256: CollectibleCatalog.hex(SHA256.hash(data: jpeg)), bytes: jpeg.count, width: 1, height: 1, frames: 1, loop: 0)
        #expect(throws: (any Error).self) { try CollectibleCatalog.checkArt(jpeg, against: art) }
        // One frame makes a still PNG.
        let still = try #require(CollectibleCatalog.makeArt(frames: [catalogTestFrame(16, red: 1)], loop: 3))
        #expect(still.art.frames == 1 && still.art.loop == 0)
        try CollectibleCatalog.checkArt(still.data, against: still.art)
    }

    @Test func framesPlayInTurnAndAreDecodedAtTheSizeDrawn() throws {
        let (item, data) = catalogTestItem("snowglobe", frames: 4)
        let frames = CatalogFrames()
        let first = try #require(frames.frame(art: item.art, data: data, index: 0, pixels: 32))
        let third = try #require(frames.frame(art: item.art, data: data, index: 2, pixels: 32))
        func red(_ image: CGImage) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return pixel[0]
        }
        #expect(red(third) > red(first) + 60, "frame 2 is a later frame, not frame 0 again")
        #expect(frames.frame(art: item.art, data: data, index: 4, pixels: 32) == nil)
        // The loop is shared by every screen: halfway round is frame 2 of 4.
        let half = Date(timeIntervalSinceReferenceDate: 1001)
        #expect(CatalogFrames.index(at: half, art: item.art) == 2)
    }

    @Test func aCollectibleNeedNotBeOneThisBuildDraws() throws {
        let relay = Curve25519.Signing.PrivateKey()
        let owner = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let message = Collectible.signedPart(item: "snowglobe", serial: 3, owner: owner)
        let byAdmin = Collectible(item: "snowglobe", serial: 3, owner: owner, sig: try admin.signature(for: message))
        let byRelay = Collectible(item: "snowglobe", serial: 3, owner: owner, sig: try relay.signature(for: message))
        let petKey = relay.publicKey.rawRepresentation
        #expect(byAdmin.isGenuine(for: owner, adminKey: adminKey), "admin-signed, whatever the item")
        #expect(!byAdmin.isGenuine(for: Data(repeating: 1, count: 32), adminKey: adminKey), "still only for its owner")
        // The relay's key makes only what can be passed on, and of an item this build doesn't draw, only once the list
        // says it can be.
        #expect(!byRelay.isGenuine(for: owner, adminKey: adminKey, petKey: petKey))
        #expect(!byRelay.isGenuine(for: owner, adminKey: adminKey, petKey: petKey, transferable: false))
        #expect(byRelay.isGenuine(for: owner, adminKey: adminKey, petKey: petKey, transferable: true))
        // An item string the relay would never take isn't a collectible.
        let odd = "Snow Globe!"
        let oddOne = Collectible(item: odd, serial: 1, owner: owner, sig: try admin.signature(for: Collectible.signedPart(item: odd, serial: 1, owner: owner)))
        #expect(!oddOne.isGenuine(for: owner, adminKey: adminKey))
        // A built-in that can't be passed on stays the admin key's alone, whatever a list might claim.
        let guardian = Collectible.signedPart(item: "guardian", serial: 1, owner: owner)
        let forged = Collectible(item: "guardian", serial: 1, owner: owner, sig: try relay.signature(for: guardian))
        #expect(!forged.isGenuine(for: owner, adminKey: adminKey, petKey: petKey, transferable: true))
    }

    @Test func theLibraryShowsListedItemsAndAPlaceholderForTheRest() throws {
        let library = CollectibleLibrary()
        let (item, data) = catalogTestItem("snowglobe")
        let (other, _) = catalogTestItem("medal", transferable: false, seed: 0.5)
        #expect(!library.info("snowglobe").known)
        #expect(library.info("snowglobe").name == CollectibleInfo.unknownName)
        #expect(!library.info("snowglobe").transferable, "nothing is passed on until the list says so")
        #expect(library.info("partyhat").kind == .partyHat, "built-ins need no list")
        // The medal's picture didn't come: it's listed, but has no picture, so it's left to the placeholder.
        library.install(CollectibleCatalog(version: 1, issued: 0, items: [item, other]), art: [item.art.sha256: data])
        #expect(library.info("snowglobe").name == "Snow Globe")
        #expect(library.info("snowglobe").known && library.info("snowglobe").transferable)
        #expect(library.artData(item) == data)
        #expect(library.artData(other) == nil)
        #expect(!library.hasAllArt)
        #expect(!library.info("medal").transferable)
        library.clear()
        #expect(library.catalog == nil && !library.info("snowglobe").known)
    }

    @Test func theListIsKeptSealedAndGoesWithABurn() throws {
        let dir = testDirectory("pulshade-catalog")
        let vault = Vault(directory: dir)
        #expect(vault.loadCatalog() == nil)
        let plain = Data("{\"the\":\"list\"}".utf8)
        try vault.saveCatalog(plain)
        #expect(vault.loadCatalog() == plain)
        let onDisk = try Data(contentsOf: dir.appendingPathComponent("catalog.cache"))
        #expect(onDisk.range(of: plain) == nil, "not written plain")
        // Not counted with the data files, so it says nothing about how many accounts there are.
        let vaults = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".vault") }
        #expect(vaults.isEmpty)
        vault.destroy(leavingNoTrace: true)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("catalog.cache").path))
        #expect(Vault(directory: dir).loadCatalog() == nil)
    }

    @Test func aDetachShredsTheListToo() throws {
        let dir = testDirectory("pulshade-catalog")
        let vault = Vault(directory: dir)
        try vault.saveCatalog(Data("list".utf8))
        vault.destroy()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("catalog.cache").path))
        #expect(vault.loadCatalog() == nil)
    }
}
