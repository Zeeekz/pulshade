import Testing
import Foundation
import CoreImage
import ImageIO
@testable import Pulshade

/// The story editor's crop, straighten, turn, flip, placement, backdrop and adjustments, drawn the same way for the
/// preview, a photo as posted and a clip's frames.
struct StoryEditTests {
    /// A picture 400 wide and 200 high: red on its left half, blue on its right.
    static func halves() -> CIImage {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 200))
        return blue.composited(over: red)
    }

    static func jpeg(_ image: CIImage) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(StoryFilter.context.jpegRepresentation(of: image, colorSpace: space))
    }

    /// The colour at a place, x and y as fractions from the top left.
    static func colour(_ image: CIImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
        let e = image.extent
        let point = CGRect(x: e.minX + x * (e.width - 1), y: e.minY + (1 - y) * (e.height - 1), width: 1, height: 1)
        var px = [UInt8](repeating: 0, count: 4)
        StoryFilter.context.render(image, toBitmap: &px, rowBytes: 4, bounds: point, format: .RGBA8,
                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    static func decoded(_ data: Data) throws -> CIImage { try #require(CIImage(data: data)) }

    @Test func aCropKeepsItsPartAndTurningSwapsTheSides() {
        let source = Self.halves()
        var crop = StoryCrop()
        crop.rect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let right = crop.apply(source)
        #expect(right.extent.size == CGSize(width: 200, height: 200))
        #expect(Self.colour(right, x: 0.5, y: 0.5).b > 200, "only the blue half is kept")

        var turned = StoryCrop()
        turned.turns = 1
        let upright = turned.apply(source)
        #expect(upright.extent.size == CGSize(width: 200, height: 400))
        #expect(turned.outputSize(of: source.extent.size) == CGSize(width: 200, height: 400))
        // A quarter turn clockwise: what was on the left is now at the top.
        #expect(Self.colour(upright, x: 0.5, y: 0.1).r > 200)
        #expect(Self.colour(upright, x: 0.5, y: 0.9).b > 200)

        var flipped = StoryCrop()
        flipped.flipped = true
        let mirror = flipped.apply(source)
        #expect(Self.colour(mirror, x: 0.1, y: 0.5).b > 200, "flipped, blue is on the left")
    }

    /// Straightening grows the picture just enough that no corner of what's kept is left empty.
    @Test func straighteningLeavesNoEmptyCorners() {
        #expect(StoryCrop.coverScale(box: CGSize(width: 100, height: 100), centre: CGPoint(x: 50, y: 50), angle: 0,
                                     image: CGSize(width: 100, height: 100)) == 1)
        let k = StoryCrop.coverScale(box: CGSize(width: 100, height: 100), centre: CGPoint(x: 50, y: 50), angle: .pi / 4,
                                     image: CGSize(width: 100, height: 100))
        #expect(abs(k - 2.squareRoot()) < 0.001)
        var crop = StoryCrop()
        crop.straighten = 30
        let out = crop.apply(Self.halves())
        #expect(out.extent.size == CGSize(width: 400, height: 200))
        // The corners still show the picture's colours, not the empty space a turn would leave.
        for (x, y) in [(0.0, 0.0), (1, 0), (0, 1), (1, 1)] {
            let c = Self.colour(out, x: x, y: y)
            #expect(c.r > 150 || c.b > 150, "corner \(x),\(y) is covered")
        }
    }

    /// A photo fitted whole on its own colours, and one moved and turned, come out as placed.
    @Test func aPhotoPostsAsPlacedOnItsBackdrop() throws {
        let data = try Self.jpeg(Self.halves())
        let green = StoryRGB(r: 0, g: 1, b: 0)
        var look = StoryLook()
        look.backdrop = .solid(green)
        let fit = StoryFraming.fit(source: CGSize(width: 400, height: 200), frame: StoryCanvas.photoSize)
        let posted = try Self.decoded(try #require(StoryCanvas.photo(data, look: look, framing: fit, text: nil)))
        #expect(posted.extent.size == StoryCanvas.photoSize)
        #expect(Self.colour(posted, x: 0.5, y: 0.1).g > 200, "the backdrop shows above the fitted picture")
        #expect(Self.colour(posted, x: 0.25, y: 0.5).r > 200)
        #expect(Self.colour(posted, x: 0.75, y: 0.5).b > 200)

        // Turned a quarter clockwise: red, on the picture's left, is now above the middle.
        var turned = fit
        turned.angle = .pi / 2
        let up = try Self.decoded(try #require(StoryCanvas.photo(data, look: look, framing: turned, text: nil)))
        #expect(Self.colour(up, x: 0.5, y: 0.45).r > 200)
        #expect(Self.colour(up, x: 0.5, y: 0.55).b > 200)

        // Moved right by a quarter of the frame.
        var moved = fit
        moved.dx = 0.25
        let right = try Self.decoded(try #require(StoryCanvas.photo(data, look: look, framing: moved, text: nil)))
        #expect(Self.colour(right, x: 0.3, y: 0.5).r > 200)
        #expect(Self.colour(right, x: 0.1, y: 0.5).g > 200, "what it left shows the backdrop")
    }

    /// The default backdrop takes its colours from the photo: the top's and the bottom's.
    @Test func theBackdropComesFromThePhotosColours() throws {
        let top = CIImage(color: CIColor(red: 1, green: 0.5, blue: 0)).cropped(to: CGRect(x: 0, y: 100, width: 100, height: 100))
        let bottom = CIImage(color: CIColor(red: 0, green: 0.2, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let colours = try #require(StoryCanvas.colours(of: top.composited(over: bottom)))
        #expect(colours.0.r > colours.0.b, "warm at the top")
        #expect(colours.1.b > colours.1.r, "blue at the bottom")
    }

    @Test func adjustmentsChangeThePictureAndNeutralLeavesIt() {
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50))
        let same = StoryAdjust().apply(grey)
        #expect(Self.colour(same, x: 0.5, y: 0.5).r == Self.colour(grey, x: 0.5, y: 0.5).r)
        var bright = StoryAdjust()
        bright.brightness = 1
        #expect(Self.colour(bright.apply(grey), x: 0.5, y: 0.5).r > Self.colour(grey, x: 0.5, y: 0.5).r + 20)
        var warm = StoryAdjust()
        warm.warmth = 1
        let w = Self.colour(warm.apply(grey), x: 0.5, y: 0.5)
        #expect(w.r > w.b + 10, "warmer is redder")
        var vignette = StoryAdjust()
        vignette.vignette = 1
        let v = vignette.apply(grey)
        #expect(Self.colour(v, x: 0.02, y: 0.02).r < Self.colour(v, x: 0.5, y: 0.5).r, "corners darker")
        // Values past the ends are kept to them.
        var wild = StoryAdjust()
        wild[.sharpen] = -5
        wild[.contrast] = 9
        #expect(wild.sharpen == 0 && wild.contrast == 1)
    }

    /// The framing the editor allows stays on the frame and within its sizes.
    @Test func looseFramingStaysWithinItsLimits() {
        let wild = StoryFraming(zoom: 99, dx: 3, dy: -3, angle: .nan).loose()
        #expect(wild.zoom == StoryFraming.mostZoom && wild.dx == 0.5 && wild.dy == -0.5 && wild.angle == 0)
        #expect(StoryFraming(zoom: 0.001).loose().zoom == StoryFraming.leastZoom)
    }

    /// A clip cut to its right half: what's posted is the blue edge's side, not the green one.
    @Test func aCroppedClipExportsOnlyItsPart() async throws {
        let source = try await StoryFramingTests.wideClip()
        var look = StoryLook()
        look.crop.rect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        // Fitted whole, as the editor opens it: filling the tall frame would cut the sides off.
        let fit = StoryFraming.fit(source: look.crop.outputSize(of: CGSize(width: 320, height: 180)), frame: StoryFramingTests.frame)
        let exported = try await StoryVideo.export(from: source, filter: .none, framing: fit, look: look)
        let right = await StoryFramingTests.colour(of: MemoryClip(exported), x: 0.97, y: 0.5)
        #expect(right.b > right.g + 40, "the right edge is the blue stripe")
        let left = await StoryFramingTests.colour(of: MemoryClip(exported), x: 0.03, y: 0.5)
        #expect(left.g < 180, "the green stripe was cut away")
    }

    /// Flip is left for right as the picture stands, also after a quarter turn (it used to turn it upside down).
    @Test func flippingAfterATurnStaysLeftForRight() {
        var crop = StoryCrop()
        crop.turns = 1
        crop.flipped = true
        let out = crop.apply(Self.halves())
        // Turned, red is at the top and blue at the bottom; a left-for-right flip keeps it so.
        #expect(Self.colour(out, x: 0.5, y: 0.1).r > 200)
        #expect(Self.colour(out, x: 0.5, y: 0.9).b > 200)
    }

    /// A panorama fits only far below the usual smallest size; it is still allowed that small, so it posts as shown.
    @Test func aPanoramaKeepsTheSizeItFitsAt() {
        let fit = StoryFraming.fitZoom(source: CGSize(width: 2600, height: 200), frame: StoryCanvas.photoSize)
        #expect(fit < StoryFraming.leastZoom)
        #expect(StoryFraming(zoom: fit).loose(fit: fit).zoom == fit)
        #expect(StoryFraming(zoom: 0.001).loose(fit: fit).zoom == fit)
    }

    @Test func aFullTwistReadsAsUpright() {
        #expect(StoryFraming.wrapped(2 * .pi) == 0)
        #expect(abs(StoryFraming.wrapped(3 * .pi / 2) + .pi / 2) < 1e-9)
        #expect(StoryFraming(angle: -2 * .pi).loose().angle == 0)
    }

    /// A file with many pictures in it isn't decoded: a huge one could hide behind a small first one.
    @Test func aFileWithManyPicturesIsRefused() throws {
        func tiff(frames: Int) throws -> Data {
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, frames, nil))
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let image = try #require(StoryFilter.context.createCGImage(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)),
                                                                   from: CGRect(x: 0, y: 0, width: 8, height: 8), format: .RGBA8, colorSpace: space))
            for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }
        #expect(ImageLimits.isReasonable(try tiff(frames: 2)))
        #expect(!ImageLimits.isReasonable(try tiff(frames: ImageLimits.maxFrames + 1)))
    }
}
