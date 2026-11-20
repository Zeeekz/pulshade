import Testing
import SceneKit
import Foundation
@testable import Pulshade

@MainActor
struct EggTests {
    private func snapshot(_ stage: EggStage, size: Int = 400) throws -> NSImage {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = stage.scene
        renderer.pointOfView = stage.scene.rootNode.childNodes.first { $0.camera != nil }
        return renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
    }

    @Test func theEggDrawsAndItsShellCracksAsItHatches() throws {
        let fresh = EggStage(still: true)
        fresh.update(progress: 0, ready: false, started: false)
        let halfway = EggStage(still: true)
        halfway.update(progress: 0.6, ready: false, started: true)
        let ready = EggStage(still: true)
        ready.update(progress: 1, ready: true, started: true)
        let images = try [fresh, halfway, ready].map { try snapshot($0) }
        #expect(images.allSatisfy { $0.size.width == 400 })
        // A crack changes the picture.
        #expect(images[0].tiffRepresentation != images[1].tiffRepresentation)
        if let dir = ProcessInfo.processInfo.environment["PULSHADE_ART_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (i, image) in images.enumerated() {
                let rep = NSBitmapImageRep(data: try #require(image.tiffRepresentation))
                try #require(rep?.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(dir)/egg-\(i).png"))
            }
        }
    }

    @Test func eachEggTakesItsNameColoursAndRarityFromTheRelayAndOldRelaysStillWork() throws {
        let new = try JSONDecoder().decode(RelayClient.EggInfo.self, from: Data(#"{"id":"a","kind":"raven","hatches_at":null,"seconds":86400,"now":1,"name":"Raven Egg","colors":["ffce60","10122a"],"rarity":"Legendary"}"#.utf8))
        #expect(new.title == "Raven Egg" && new.rarity == "Legendary")
        let palette = try #require(new.palette)
        #expect(abs(palette.light.r - 1) < 0.01 && abs(palette.dark.b - 42.0 / 255) < 0.01)
        let old = try JSONDecoder().decode(RelayClient.EggInfo.self, from: Data(#"{"id":"b","kind":"dragon","seconds":600,"now":1}"#.utf8))
        #expect(old.title == "Dragon Egg" && old.palette == nil && old.rarity == nil)
        #expect(EggPalette(hex: ["zzzzzz", "000000"]) == nil && EggPalette(hex: ["ffffff"]) == nil)
        // A coloured shell draws differently from the plain one.
        let plain = EggStage(still: true), raven = EggStage(still: true, palette: palette)
        plain.update(progress: 0, ready: false, started: false)
        raven.update(progress: 0, ready: false, started: false)
        #expect(try snapshot(plain).tiffRepresentation != snapshot(raven).tiffRepresentation)
    }
}
