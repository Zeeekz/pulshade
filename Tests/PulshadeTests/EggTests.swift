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
}
