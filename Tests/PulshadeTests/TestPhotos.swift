import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import Pulshade

/// Sample media for the tests. A real PNG, not random bytes, because the app makes a thumbnail of it on the
/// path that moves big photos through the relay.
///
/// This exists only because the relay test that defines `RelayFlowTests.bigPhoto()` is not in this review copy.
/// A tree that already has it should not take this file.
enum TestPhotos {
    static func bigPhoto() -> Data {
        #if canImport(AppKit)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 320,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
        var dice = UInt64(0x5747_1CE0_1234_5678)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                dice = dice &* 6364136223846793005 &+ 1442695040888963407
                let r = UInt8(truncatingIfNeeded: dice >> 16)
                dice = dice &* 6364136223846793005 &+ 1442695040888963407
                let g = UInt8(truncatingIfNeeded: dice >> 16)
                dice = dice &* 6364136223846793005 &+ 1442695040888963407
                let b = UInt8(truncatingIfNeeded: dice >> 16)
                rep.setColor(NSColor(deviceRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                                     blue: CGFloat(b) / 255, alpha: 1), atX: x, y: y)
            }
        }
        return rep.representation(using: .png, properties: [:]) ?? Data()
        #else
        return Data()
        #endif
    }
}
