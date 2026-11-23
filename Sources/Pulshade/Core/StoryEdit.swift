import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// The story editor's changes to a photo or a clip, and the one place they are drawn: crop, straighten, turn and flip
// (`StoryCrop`), light and colour (`StoryAdjust`), the look (`StoryFilter`), and what shows behind the picture where it
// doesn't cover the frame (`StoryBackdrop`). Photos and clips go through the same code, so a photo posts as it looked in
// the editor and a clip's frames match its preview.

/// A colour, red, green and blue from 0 to 1.
struct StoryRGB: Equatable, Hashable, Sendable {
    var r: Double, g: Double, b: Double
    static let black = StoryRGB(r: 0, g: 0, b: 0)
    static let white = StoryRGB(r: 1, g: 1, b: 1)
    var ci: CIColor { CIColor(red: r, green: g, blue: b) }
}

/// What fills the frame around the picture.
enum StoryBackdrop: Equatable, Sendable {
    /// A soft, darkened copy of the picture itself.
    case blur
    /// From one colour at the top to another at the bottom: by default two taken from the picture, as Instagram does.
    case gradient(StoryRGB, StoryRGB)
    case solid(StoryRGB)
}

/// Light and colour, each from -1 to 1 (vignette and sharpen from 0 to 1), 0 leaving the picture as it is.
struct StoryAdjust: Equatable, Sendable {
    var brightness = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var warmth = 0.0
    var vignette = 0.0
    var sharpen = 0.0

    var isNeutral: Bool { self == StoryAdjust() }

    enum Tool: String, CaseIterable, Identifiable, Sendable {
        case brightness, contrast, saturation, warmth, vignette, sharpen
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .brightness: "sun.max"
            case .contrast: "circle.lefthalf.filled"
            case .saturation: "drop"
            case .warmth: "thermometer.medium"
            case .vignette: "circle.dashed"
            case .sharpen: "triangle"
            }
        }
        /// Vignette and sharpen only add; the rest go both ways.
        var range: ClosedRange<Double> { self == .vignette || self == .sharpen ? 0...1 : -1...1 }
    }

    subscript(tool: Tool) -> Double {
        get {
            switch tool {
            case .brightness: brightness
            case .contrast: contrast
            case .saturation: saturation
            case .warmth: warmth
            case .vignette: vignette
            case .sharpen: sharpen
            }
        }
        set {
            let v = min(max(newValue.isFinite ? newValue : 0, tool.range.lowerBound), tool.range.upperBound)
            switch tool {
            case .brightness: brightness = v
            case .contrast: contrast = v
            case .saturation: saturation = v
            case .warmth: warmth = v
            case .vignette: vignette = v
            case .sharpen: sharpen = v
            }
        }
    }

    func apply(_ image: CIImage) -> CIImage {
        guard !isNeutral else { return image }
        let extent = image.extent
        var out = image
        if brightness != 0 || contrast != 0 || saturation != 0 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness * 0.18,
                kCIInputContrastKey: 1 + contrast * 0.3,
                kCIInputSaturationKey: 1 + saturation,
            ])
        }
        if warmth != 0 {
            // A lower target than the neutral warms the picture, a higher one cools it.
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - warmth * 2200, y: 0),
            ])
        }
        if sharpen > 0 {
            out = out.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: sharpen * 1.2,
                                                                          kCIInputRadiusKey: max(extent.width, extent.height) / 900])
        }
        if vignette > 0 {
            let side = min(extent.width, extent.height)
            out = out.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: side * 0.75,
                kCIInputIntensityKey: vignette * 0.9,
                "inputFalloff": 0.6,
            ])
        }
        return out.cropped(to: extent)
    }
}

/// Which part of the picture is kept, and how it's turned. `rect` is a fraction of the picture after it is flipped and
/// turned by quarters, from its top left. `straighten` turns it a little more (in degrees, clockwise), about the middle of
/// what's kept, which is then enlarged just enough that no corner is left empty.
struct StoryCrop: Equatable, Sendable {
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Quarter turns clockwise.
    var turns = 0
    var flipped = false
    var straighten = 0.0

    static let straightenLimit = 45.0
    static let smallest: CGFloat = 0.08

    var isIdentity: Bool { self == StoryCrop() }

    /// The picture's size once flipped and turned.
    func orientedSize(of source: CGSize) -> CGSize {
        turns % 2 == 0 ? source : CGSize(width: source.height, height: source.width)
    }

    /// The size of what's kept, in the picture's own pixels.
    func outputSize(of source: CGSize) -> CGSize {
        let o = orientedSize(of: source)
        return CGSize(width: max(o.width * rect.width, 1), height: max(o.height * rect.height, 1))
    }

    /// Flipped and turned, with its corner at the origin.
    func oriented(_ image: CIImage) -> CIImage {
        var out = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        for _ in 0..<((turns % 4 + 4) % 4) {
            // A quarter turn clockwise as seen, which is the other way in Core Image's upward y.
            out = out.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
            out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        }
        // Flipped last, so it's always left for right as the picture now stands, whatever its turns.
        if flipped {
            out = out.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -out.extent.width, y: 0))
        }
        return out
    }

    /// How much the turned picture has to grow for a box of `size` at `centre` (in its pixels, y up) to stay covered.
    static func coverScale(box size: CGSize, centre: CGPoint, angle: Double, image: CGSize) -> CGFloat {
        guard angle != 0 || !CGRect(origin: .zero, size: image).contains(CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                                                                                 width: size.width, height: size.height).insetBy(dx: 0.5, dy: 0.5))
        else { return 1 }
        // The box's corners, turned back into the picture's frame about the centre: each must land inside it once scaled.
        let c = cos(angle), s = sin(angle)
        var scale: CGFloat = 1
        for (hx, hy) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
            let vx = hx * size.width / 2, vy = hy * size.height / 2
            let rx = vx * c - vy * s, ry = vx * s + vy * c
            if rx < 0, centre.x > 0 { scale = max(scale, -rx / centre.x) }
            if rx > 0, image.width - centre.x > 0 { scale = max(scale, rx / (image.width - centre.x)) }
            if ry < 0, centre.y > 0 { scale = max(scale, -ry / centre.y) }
            if ry > 0, image.height - centre.y > 0 { scale = max(scale, ry / (image.height - centre.y)) }
        }
        return min(scale, 20)
    }

    /// What's kept, at the origin.
    func apply(_ image: CIImage) -> CIImage {
        guard !isIdentity else { return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)) }
        let o = oriented(image)
        let W = o.extent.width, H = o.extent.height
        let r = rect.standardized
        let box = CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: max(r.width * W, 1), height: max(r.height * H, 1))
        let centre = CGPoint(x: box.midX, y: box.midY)
        let angle = straighten * .pi / 180
        var turned = o
        if angle != 0 {
            let k = Self.coverScale(box: box.size, centre: centre, angle: angle, image: o.extent.size)
            // Clockwise as seen is negative in Core Image, about the middle of the box, grown to cover it.
            let t = CGAffineTransform(translationX: centre.x, y: centre.y)
                .rotated(by: -angle)
                .scaledBy(x: k, y: k)
                .translatedBy(x: -centre.x, y: -centre.y)
            turned = o.clampedToExtent().transformed(by: t)
        }
        let cut = turned.cropped(to: box)
        return cut.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
    }
}

/// Everything about how the picture itself looks.
struct StoryLook: Equatable, Sendable {
    var filter = StoryFilter.none
    var adjust = StoryAdjust()
    var crop = StoryCrop()
    var backdrop = StoryBackdrop.blur

    /// The picture as it will sit in the frame: cut, turned, adjusted and given its look, with its corner at the origin.
    func media(_ source: CIImage) -> CIImage {
        let cut = crop.apply(source)
        let extent = cut.extent
        return filter.apply(adjust.apply(cut)).cropped(to: extent)
    }
}

/// The look read by the frame renderer on its own thread while the editor changes it.
final class LookBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: StoryLook
    init(_ value: StoryLook = StoryLook()) { current = value }
    var value: StoryLook {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

enum StoryCanvas {
    /// A photo story's size: the frame at full HD, as text is drawn.
    static let photoSize = CGSize(width: 1080, height: 1920)

    /// The picture placed in the frame (`framing`), on its backdrop. `media` has its corner at the origin.
    static func compose(_ media: CIImage, framing: StoryFraming, backdrop: StoryBackdrop, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let e = media.extent
        guard e.width > 0, e.height > 0 else { return CIImage(color: .black).cropped(to: frame) }
        let fillScale = max(size.width / e.width, size.height / e.height)
        let scale = fillScale * framing.zoom
        // About its own middle: grown, turned (clockwise as seen), then moved to its place, down being up in Core Image.
        let t = CGAffineTransform(translationX: size.width / 2 + framing.dx * size.width, y: size.height / 2 - framing.dy * size.height)
            .rotated(by: -framing.angle)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -e.width / 2, y: -e.height / 2)
        let placed = media.transformed(by: t)
        // Covering the whole frame already: nothing of the backdrop would show.
        if framing.angle == 0, placed.extent.contains(frame.insetBy(dx: 0.5, dy: 0.5)) { return placed.cropped(to: frame) }
        return placed.composited(over: background(backdrop, media: media, size: size)).cropped(to: frame)
    }

    static func background(_ backdrop: StoryBackdrop, media: CIImage, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        switch backdrop {
        case .blur:
            let e = media.extent
            let fillScale = max(size.width / e.width, size.height / e.height)
            // Blurred at a quarter of the size and scaled back up: it looks the same, and costs a sixteenth, which keeps the
            // live preview smooth.
            let q: CGFloat = 0.25
            let back = media.transformed(by: CGAffineTransform(scaleX: fillScale * q, y: fillScale * q))
                .transformed(by: CGAffineTransform(translationX: (size.width - e.width * fillScale) / 2 * q,
                                                   y: (size.height - e.height * fillScale) / 2 * q))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: size.width / 14 * q)
                .transformed(by: CGAffineTransform(scaleX: 1 / q, y: 1 / q))
                .cropped(to: frame)
            let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.3)).cropped(to: frame)
            return dim.composited(over: back)
        case let .gradient(top, bottom):
            let gradient = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: size.height), "inputColor0": top.ci,
                "inputPoint1": CIVector(x: 0, y: 0), "inputColor1": bottom.ci,
            ])?.outputImage
            return (gradient ?? CIImage(color: top.ci)).cropped(to: frame)
        case let .solid(colour):
            return CIImage(color: colour.ci).cropped(to: frame)
        }
    }

    /// Two colours from the picture, for the backdrop behind it: the average of its top part and of its bottom part,
    /// a little deepened so the picture stands out against them.
    static func colours(of image: CIImage) -> (StoryRGB, StoryRGB)? {
        let e = image.extent
        guard e.width >= 1, e.height >= 1 else { return nil }
        func average(_ rect: CGRect) -> StoryRGB? {
            guard let out = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)]) as CIImage?,
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            StoryFilter.context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                       format: .RGBA8, colorSpace: space)
            let deepen = 0.82
            return StoryRGB(r: Double(px[0]) / 255 * deepen, g: Double(px[1]) / 255 * deepen, b: Double(px[2]) / 255 * deepen)
        }
        let third = e.height / 3
        guard let top = average(CGRect(x: e.minX, y: e.maxY - third, width: e.width, height: third)),
              let bottom = average(CGRect(x: e.minX, y: e.minY, width: e.width, height: third)) else { return nil }
        return (top, bottom)
    }

    /// A picture from file bytes, the right way up, made no bigger than `maxSide`.
    static func source(_ data: Data, maxSide: CGFloat) -> CIImage? {
        guard ImageLimits.isReasonable(data),
              var image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let longest = max(image.extent.width, image.extent.height)
        if longest > maxSide {
            let s = maxSide / longest
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        return image
    }

    /// The edited picture alone (no placement or backdrop) for the editor's preview, as a JPEG, with its colours.
    static func preview(_ data: Data, look: StoryLook, maxSide: CGFloat) -> (jpeg: Data, colours: (StoryRGB, StoryRGB)?)? {
        guard let source = source(data, maxSide: maxSide) else { return nil }
        let media = look.media(source)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = StoryFilter.context.jpegRepresentation(of: media, colorSpace: space,
                                                                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
        else { return nil }
        return (jpeg, colours(of: media))
    }

    /// The same, from a picture already decoded (the editor keeps one, so a slider doesn't decode the file each time).
    static func preview(base: CGImage, look: StoryLook) -> (jpeg: Data, colours: (StoryRGB, StoryRGB)?)? {
        let media = look.media(CIImage(cgImage: base))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = StoryFilter.context.jpegRepresentation(of: media, colorSpace: space,
                                                                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
        else { return nil }
        return (jpeg, colours(of: media))
    }

    /// The picture's size as it sits in the frame once cut and turned.
    static func mediaSize(_ data: Data, crop: StoryCrop) -> CGSize? {
        guard let source = source(data, maxSide: 4096) else { return nil }
        return crop.outputSize(of: source.extent.size)
    }

    /// A photo story as posted: the picture edited and placed on its backdrop, the words over it, as a clean JPEG (no
    /// location or camera details).
    static func photo(_ data: Data, look: StoryLook, framing: StoryFraming, text: CIImage?) -> Data? {
        let size = photoSize
        guard let source = source(data, maxSide: 2600) else { return nil }
        var out = compose(look.media(source), framing: framing, backdrop: look.backdrop, size: size)
        if let text {
            let s = size.width / max(text.extent.width, 1)
            out = text.transformed(by: CGAffineTransform(scaleX: s, y: s)).composited(over: out)
        }
        out = out.cropped(to: CGRect(origin: .zero, size: size))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return StoryFilter.context.jpegRepresentation(of: out, colorSpace: space,
                                                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
    }
}
