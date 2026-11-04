import Testing
import SwiftUI
import AppKit
@testable import PulshadeShared

/// Every collectible draws at every size. Set PULSHADE_ART_DIR to also save frames as PNGs, to look at.
@MainActor
struct CollectibleArtTests {
    private func render(_ view: some View, size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: view.frame(width: size, height: size).background(Color(red: 0.05, green: 0.05, blue: 0.09)))
        renderer.scale = 2
        return renderer.nsImage
    }

    private func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @Test func everyCollectibleDrawsAtEverySize() throws {
        for kind in Collectible.Kind.allCases {
            for size in [15.0, 52, 84, 256] {
                let image = try #require(render(CollectibleIcon(item: kind, size: size), size: size), "\(kind.name) at \(size)")
                #expect(image.size.width > 0)
            }
        }
    }

    /// The frame of each collectible that moves, at a time in its loop, and how long its loop is.
    private let animated: [(name: String, loop: Double, draw: (Double) -> AnyView)] = [
        ("partyhat", PartyHatFrame.loop, { AnyView(PartyHatFrame(time: $0)) }),
        ("pumpkin", PumpkinFrame.loop, { AnyView(PumpkinFrame(time: $0)) }),
        ("tophat", TopHatShape.loop, { AnyView(TopHatShape(time: $0)) }),
        ("bonfire", BonfireFrame.loop, { AnyView(BonfireFrame(time: $0)) }),
        ("christmastree", ChristmasTreeFrame.loop, { AnyView(ChristmasTreeFrame(time: $0)) }),
    ]

    private func frame(_ index: Int, _ time: Double, _ size: CGFloat) throws -> Data {
        let image = try #require(render(animated[index].draw(time), size: size))
        return try #require(png(image))
    }

    /// How much of the picture differs noticeably. The renderer isn't exact to the last bit from one run to the next.
    private func difference(_ a: Data, _ b: Data) throws -> Double {
        let x = try #require(NSBitmapImageRep(data: a)), y = try #require(NSBitmapImageRep(data: b))
        let left = try #require(x.bitmapData), right = try #require(y.bitmapData)
        let count = x.bytesPerRow * x.pixelsHigh
        var differing = 0
        for i in 0..<count where abs(Int(left[i]) - Int(right[i])) > 16 { differing += 1 }
        return Double(differing) / Double(count)
    }

    @Test func everyAnimatedCollectibleMovesAndJoinsUpAtTheLoop() throws {
        for (index, item) in animated.enumerated() {
            #expect(try difference(frame(index, item.loop * 0.13, 120), frame(index, item.loop * 0.31, 120)) > 0.005, "\(item.name) moves")
            #expect(try difference(frame(index, 0, 120), frame(index, item.loop, 120)) < 0.002, "\(item.name): the last frame is the first, so the loop has no jump")
        }
    }

    @Test func savesFramesToLookAt() throws {
        guard let dir = ProcessInfo.processInfo.environment["PULSHADE_ART_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (index, item) in animated.enumerated() {
            for (i, fraction) in [0.06, 0.2, 0.34, 0.5, 0.66, 0.82].enumerated() {
                try frame(index, item.loop * fraction, 420).write(to: URL(fileURLWithPath: "\(dir)/\(item.name)-\(i).png"))
            }
            for size in [15.0, 24, 52] {
                try frame(index, item.loop * 0.4, size).write(to: URL(fileURLWithPath: "\(dir)/\(item.name)-small-\(Int(size)).png"))
            }
        }
        for (i, sweep) in [0.15, 0.5].enumerated() {
            let image = try #require(render(GuardianFrame(sweep: sweep), size: 420))
            try #require(png(image)).write(to: URL(fileURLWithPath: "\(dir)/guardian-\(i).png"))
        }
    }

    @Test func theGoldenDragonRendersAndIsNotTheBlueOne() throws {
        let blue = try #require(DragonStage.still(head: false, pixels: 300))
        let gold = try #require(DragonStage.still(head: false, pixels: 300, golden: true))
        #expect(gold.width == 300)
        if let dir = ProcessInfo.processInfo.environment["PULSHADE_ART_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try #require(png(NSImage(cgImage: gold, size: .zero))).write(to: URL(fileURLWithPath: "\(dir)/golddragon.png"))
            try #require(png(NSImage(cgImage: blue, size: .zero))).write(to: URL(fileURLWithPath: "\(dir)/bluedragon.png"))
        }
        func average(_ image: CGImage) -> (r: Int, b: Int) {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (Int(px[0]), Int(px[2]))
        }
        #expect(average(gold).r > average(gold).b, "gold is redder than blue")
        #expect(average(blue).b > average(blue).r)
    }

    @Test func theDragonRendersFromItsScene() throws {
        let full = try #require(DragonStage.still(head: false, pixels: 600))
        let head = try #require(DragonStage.still(head: true, pixels: 300))
        #expect(full.width == 600 && head.width == 300)
        guard let dir = ProcessInfo.processInfo.environment["PULSHADE_ART_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var shots = [("dragon-full", full), ("dragon-head", head)]
        // All the way round, as it turns.
        for (i, angle) in [Float(0.9), 2.2, 3.4, 4.7].enumerated() {
            shots.append(("dragon-turn-\(i)", try #require(DragonStage.still(head: false, pixels: 450, yaw: angle))))
        }
        shots.append(("dragon-lair", try #require(DragonStage.still(head: false, pixels: 600, lair: true))))
        shots.append(("dragon-blink-head", try #require(DragonStage.still(head: true, pixels: 300, eyesOpen: 0.1))))
        shots.append(("dragon-blink-full", try #require(DragonStage.still(head: false, pixels: 500, yaw: -0.3, lair: true, eyesOpen: 0.1))))
        shots.append(("dragon-zap", try #require(DragonStage.still(head: false, pixels: 500, yaw: -0.2, lair: true, zapping: true))))
        for (name, image) in shots {
            let rep = NSBitmapImageRep(cgImage: image)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
