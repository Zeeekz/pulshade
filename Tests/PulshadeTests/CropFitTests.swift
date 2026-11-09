import Testing
import Foundation
import CoreGraphics
@testable import Pulshade

/// A wide picture put into the story's tall frame whole, or moved about in it.
struct CropFitTests {
    /// 400×200: grey, with a green block in its top-left corner and a blue one in its bottom-right.
    static func wide() -> CGImage {
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 150, width: 50, height: 50))   // top-left
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 350, y: 0, width: 50, height: 50))    // bottom-right
        return ctx.makeImage()!
    }

    /// The colour at a fraction of the way across and down (from the top) of a picture.
    static func colour(_ image: CGImage, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int) {
        let (w, h) = (image.width, image.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (min(h - 1, Int(y * Double(h))) * w + min(w - 1, Int(x * Double(w)))) * 4
        return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]))
    }

    static let out = CGSize(width: 180, height: 320)

    @Test func aWholePictureSitsInTheMiddleWithItsCornersWhereTheyWere() throws {
        let image = try #require(drawFitted(Self.wide(), out: Self.out, scale: 180.0 / 400.0, shift: .zero))
        // The picture is 180 × 90, so it fills rows 115…205 of 320; its green corner is at the top-left of that band.
        let green = Self.colour(image, 0.03, (115 + 4.0) / 320)
        let blue = Self.colour(image, 0.97, (205 - 4.0) / 320)
        #expect(green.g > 200 && green.r < 60, "green is at the top-left of the picture: \(green)")
        #expect(blue.b > 200 && blue.r < 60, "blue is at the bottom-right: \(blue)")
        let bar = Self.colour(image, 0.5, 0.05), middle = Self.colour(image, 0.5, 0.5)
        #expect(bar.r > 40 && bar.r < middle.r - 8, "above the picture is a dimmed copy of it, not black or the picture itself: \(bar) vs \(middle)")
    }

    @Test func movingDownMovesThePictureDown() throws {
        let image = try #require(drawFitted(Self.wide(), out: Self.out, scale: 180.0 / 400.0, shift: CGSize(width: 0, height: 60)))
        let green = Self.colour(image, 0.03, (115 + 60 + 4.0) / 320)
        #expect(green.g > 200 && green.r < 60, "the picture moved 60 down: \(green)")
    }

    @Test func fillingCoversTheFrameWithNoSoftCopy() throws {
        let image = try #require(drawFitted(Self.wide(), out: Self.out, scale: 320.0 / 200.0, shift: .zero))
        for y in [0.02, 0.5, 0.98] {
            let c = Self.colour(image, 0.5, y), middle = Self.colour(image, 0.5, 0.5)
            #expect(abs(c.r - middle.r) < 4 && abs(c.g - middle.g) < 4, "the picture all the way, no dimmed copy: \(c) vs \(middle)")
        }
    }
}
