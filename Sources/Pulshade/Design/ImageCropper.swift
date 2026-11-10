import SwiftUI
import CoreImage

/// The shape a picture is framed to before it's used.
struct CropFrame: Equatable {
    /// Width over height.
    var aspect: CGFloat
    var circle = false
    /// The longest side of the result, in pixels.
    var maxSide: CGFloat
    /// Whether the picture may be made smaller than the frame, to show all of it with a soft copy of it behind.
    var allowsFit = false

    static let avatar = CropFrame(aspect: 1, circle: true, maxSide: 512)
    static let banner = CropFrame(aspect: 3, maxSide: 1200)
    static let story = CropFrame(aspect: 9.0 / 16.0, maxSide: 1600, allowsFit: true)
}

/// A picture waiting to be framed.
struct PendingCrop: Identifiable {
    let id = UUID()
    let image: PlatformImage
}

/// Frames a picture like Instagram does: pinch (or scroll, or the slider) to zoom, drag to move, and the
/// part inside the frame is what's kept. Hands back a cleaned JPEG, or nil if cancelled.
struct ImageCropper: View {
    let image: PlatformImage
    var frame: CropFrame
    var title = "Move and scale"
    var useLabel = "Use"
    var done: (Data?) -> Void

    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    /// The picture redrawn upright (so the maths matches what's on screen), made once.
    @State private var picture: CGImage?

    var body: some View {
        VStack(spacing: 18) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text)
            GeometryReader { geo in
                let box = boxSize(in: geo.size)
                ZStack {
                    if let picture {
                        let shown = shownSize(picture, box: box)
                        Image(decorative: picture, scale: 1)
                            .resizable()
                            .frame(width: shown.width, height: shown.height)
                            .offset(offset)
                    }
                    // Everything outside the frame is dimmed.
                    CropDim(box: box, circle: frame.circle)
                        .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    cutout.stroke(.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: box.width, height: box.height)
                        .allowsHitTesting(false)
                    // Thirds guide, shown while you move the picture.
                    CropGrid()
                        .stroke(.white.opacity(0.35), lineWidth: 0.5)
                        .frame(width: box.width, height: box.height)
                        .opacity(dragging || pinching ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: dragging || pinching)
                        .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                // One recogniser for the move and the pinch, so adding or lifting a finger never jolts the picture.
                .overlay {
                    TransformSurface(
                        began: { _ in dragging = true; snapped = false },
                        changed: { value in
                            drag = value.translation
                            pinch = value.scale
                            pinching = value.fingers > 1
                            // The spot the fingers started on, from the middle, stays under them.
                            pinchAnchor = CGPoint(x: value.location.x - value.translation.width - geo.size.width / 2,
                                                  y: value.location.y - value.translation.height - geo.size.height / 2)
                            apply(geo.size, box: box)
                        },
                        ended: { _ in
                            dragging = false
                            pinching = false
                            settle(box: box)
                        })
                }
                .onAppear { boxCache = box; startFitted() }
                .onChange(of: geo.size) {
                    boxCache = boxSize(in: geo.size)
                    guard let picture else { return }
                    offset = clamp(offset, picture, box: boxCache, zoom: zoom)
                    settledOffset = offset
                }
            }
            .frame(minHeight: 280)
            .background(Color.black, in: .rect(cornerRadius: 16))
            .clipShape(.rect(cornerRadius: 16))

            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(Ink.faint)
                Slider(value: Binding(get: { zoom }, set: { setZoom($0) }), in: min(minZoom, Self.maxZoom - 0.01)...Self.maxZoom)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(Ink.faint)
                if frame.allowsFit, minZoom < 0.999 {
                    Button { setZoom(zoom > minZoom + 0.01 ? minZoom : 1, centred: true) } label: {
                        Image(systemName: zoom > minZoom + 0.01 ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(zoom > minZoom + 0.01 ? "Fit the whole picture" : "Fill the frame")
                }
            }
            .font(.system(size: 13))

            HStack(spacing: 12) {
                Button("Cancel") { done(nil) }.buttonStyle(SecondaryButtonStyle())
                Button(useLabel) { done(crop(picture)) }.buttonStyle(PrimaryButtonStyle()).disabled(picture == nil)
            }
        }
        .padding(20)
        .task {
            picture = cleanJPEG(image, maxSide: 2400).flatMap { PlatformImage(data: $0) }?.cgImageValue
            startFitted()
        }
        .frame(minWidth: Platform.isPhone ? nil : 460, minHeight: Platform.isPhone ? nil : 560)
        .background(Theme.dark.ink.base)
        .preferredColorScheme(.dark)
        // Pulling the picture down moved the sheet too; Cancel closes it instead.
        .interactiveDismissDisabled()
    }

    @State private var boxCache: CGSize = .zero
    @State private var drag: CGSize = .zero
    @State private var pinch: CGFloat = 1
    @State private var pinchAnchor: CGPoint = .zero
    @State private var dragging = false
    @State private var pinching = false
    @State private var snapped = false
    private static let maxZoom: CGFloat = 8
    @State private var started = false

    /// The zoom at which all of the picture shows, where the frame allows that; filling is 1.
    private var minZoom: CGFloat {
        guard frame.allowsFit, let picture, boxCache.width > 0 else { return 1 }
        let fit = min(boxCache.width / CGFloat(picture.width), boxCache.height / CGFloat(picture.height))
        return min(1, fit / fill(picture, box: boxCache))
    }

    /// A story's picture opens fitted whole, so nothing is cut off until you choose to fill the frame.
    private func startFitted() {
        guard !started, frame.allowsFit, picture != nil, boxCache.width > 0 else { return }
        started = true
        zoom = minZoom
        settledZoom = zoom
        offset = .zero
        settledOffset = .zero
    }

    /// Moves and zooms from where the last gesture left off. A pinch holds the spot under your fingers still. Past
    /// the edges and the zoom limits the picture stretches a little, and settles back on letting go.
    private func apply(_ area: CGSize, box: CGSize) {
        guard let picture else { return }
        var wanted = settledZoom * pinch
        // Filling the frame exactly clicks into place, for a story picture that can also be fitted.
        if frame.allowsFit, minZoom < 0.999, abs(wanted - 1) < 0.03 {
            if !snapped { Haptics.snap() }
            snapped = true
            wanted = 1
        } else {
            snapped = false
        }
        let target = exp(RubberBand.clamp(log(max(wanted, 0.01)), log(minZoom)...log(Self.maxZoom), span: 0.2))
        let k = target / settledZoom
        let p = pinchAnchor
        let moved = CGSize(width: p.x - (p.x - settledOffset.width) * k + drag.width,
                           height: p.y - (p.y - settledOffset.height) * k + drag.height)
        zoom = target
        let edge = clamp(CGSize(width: 1e6, height: 1e6), picture, box: box, zoom: target)
        offset = CGSize(width: RubberBand.clamp(moved.width, -edge.width...edge.width, span: 60),
                        height: RubberBand.clamp(moved.height, -edge.height...edge.height, span: 60))
    }

    /// Locks the result in once the fingers lift, easing back inside the limits if it was stretched past them.
    private func settle(box: CGSize) {
        guard let picture else { return }
        let z = min(max(zoom, minZoom), Self.maxZoom)
        withAnimation(.spring(duration: 0.3, bounce: 0.12)) {
            zoom = z
            offset = clamp(offset, picture, box: box, zoom: z)
        }
        settledZoom = z
        settledOffset = clamp(offset, picture, box: box, zoom: z)
        drag = .zero
        pinch = 1
    }

    /// Zoom from the slider, around the middle of the frame.
    private func setZoom(_ value: CGFloat, centred: Bool = false) {
        guard let picture else { return }
        let value = max(value, minZoom)
        let k = value / max(zoom, 0.001)
        zoom = value
        settledZoom = value
        offset = centred ? .zero : clamp(CGSize(width: offset.width * k, height: offset.height * k), picture, box: boxCache, zoom: value)
        settledOffset = offset
    }

    private var cutout: AnyShape {
        frame.circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6))
    }

    /// The frame, as large as fits with a margin.
    private func boxSize(in size: CGSize) -> CGSize {
        let width = max(1, size.width - 32), height = max(1, size.height - 32)
        return width / height > frame.aspect
            ? CGSize(width: height * frame.aspect, height: height)
            : CGSize(width: width, height: width / frame.aspect)
    }

    /// Drawn just big enough to fill the frame at zoom 1.
    private func fill(_ picture: CGImage, box: CGSize) -> CGFloat {
        max(box.width / CGFloat(picture.width), box.height / CGFloat(picture.height))
    }

    private func shownSize(_ picture: CGImage, box: CGSize) -> CGSize {
        let s = fill(picture, box: box) * zoom
        return CGSize(width: CGFloat(picture.width) * s, height: CGFloat(picture.height) * s)
    }

    /// Keeps the frame covered by the picture.
    private func clamp(_ o: CGSize, _ picture: CGImage, box: CGSize, zoom: CGFloat) -> CGSize {
        let s = fill(picture, box: box) * zoom
        // Grown past the frame it stays covering it; shrunk inside it, it stays inside.
        let spareX = frame.allowsFit ? abs(CGFloat(picture.width) * s - box.width) / 2 : max(0, (CGFloat(picture.width) * s - box.width) / 2)
        let spareY = frame.allowsFit ? abs(CGFloat(picture.height) * s - box.height) / 2 : max(0, (CGFloat(picture.height) * s - box.height) / 2)
        return CGSize(width: min(spareX, max(-spareX, o.width)), height: min(spareY, max(-spareY, o.height)))
    }

    /// The result's size in pixels, how many of them one of the picture's pixels covers, and how far it is moved.
    fileprivate func fittedLayout(_ picture: CGImage) -> (CGSize, CGFloat, CGSize) {
        let out = frame.aspect <= 1 ? CGSize(width: frame.maxSide * frame.aspect, height: frame.maxSide)
                                    : CGSize(width: frame.maxSide, height: frame.maxSide / frame.aspect)
        let k = out.width / boxCache.width
        return (out, fill(picture, box: boxCache) * zoom * k, CGSize(width: offset.width * k, height: offset.height * k))
    }

    /// The part of the picture inside the frame, as a JPEG.
    private func crop(_ picture: CGImage?) -> Data? {
        guard let picture, boxCache.width > 0 else { return nil }
        if frame.allowsFit { return renderFitted(picture) }
        let s = fill(picture, box: boxCache) * zoom
        let w = boxCache.width / s, h = boxCache.height / s
        let x = CGFloat(picture.width) / 2 - offset.width / s - w / 2
        let y = CGFloat(picture.height) / 2 - offset.height / s - h / 2
        let rect = CGRect(x: x, y: y, width: w, height: h).integral
            .intersection(CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        guard let cropped = picture.cropping(to: rect) else { return nil }
        return cleanJPEG(.from(cgImage: cropped), maxSide: frame.maxSide)
    }
}

/// A picture drawn into a frame of `out` pixels at `scale` (one of its pixels covers that many of the frame's), moved
/// `shift` down and to the right from the middle. Where it doesn't reach, a dimmed, blurred copy of it fills the frame.
func drawFitted(_ picture: CGImage, out: CGSize, scale: CGFloat, shift: CGSize) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: Int(out.width.rounded()), height: Int(out.height.rounded()), bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let canvas = CGRect(origin: .zero, size: out)
    let placed = CGRect(x: out.width / 2 - CGFloat(picture.width) * scale / 2 + shift.width,
                        y: out.height / 2 - CGFloat(picture.height) * scale / 2 - shift.height,
                        width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
    if !placed.insetBy(dx: -0.5, dy: -0.5).contains(canvas) {
        let fillScale = max(out.width / CGFloat(picture.width), out.height / CGFloat(picture.height))
        let back = CIImage(cgImage: picture)
            .transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
            .transformed(by: CGAffineTransform(translationX: (out.width - CGFloat(picture.width) * fillScale) / 2,
                                               y: (out.height - CGFloat(picture.height) * fillScale) / 2))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: out.width / 14)
            .cropped(to: canvas)
        let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.3)).cropped(to: canvas)
        if let softened = CIContext().createCGImage(dim.composited(over: back), from: canvas) {
            ctx.draw(softened, in: canvas)
        }
    }
    ctx.interpolationQuality = .high
    ctx.draw(picture, in: placed)
    return ctx.makeImage()
}

extension ImageCropper {
    /// The frame drawn out for the result.
    fileprivate func renderFitted(_ picture: CGImage) -> Data? {
        let (out, scale, shift) = fittedLayout(picture)
        guard let made = drawFitted(picture, out: out, scale: scale, shift: shift) else { return nil }
        return cleanJPEG(.from(cgImage: made), maxSide: frame.maxSide)
    }
}

extension View {
    /// Shows the cropper for a picked picture, as a sheet (or full screen on iPhone).
    func cropper(_ pending: Binding<PendingCrop?>, frame: CropFrame, done: @escaping (Data) -> Void) -> some View {
        sheet(item: pending) { item in
            ImageCropper(image: item.image, frame: frame) { data in
                pending.wrappedValue = nil
                if let data { done(data) }
            }
        }
    }
}

/// The whole area with the frame cut out of it.
private struct CropDim: Shape {
    var box: CGSize
    var circle: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let hole = CGRect(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2, width: box.width, height: box.height)
        path.addPath(circle ? Path(ellipseIn: hole) : Path(roundedRect: hole, cornerRadius: 6))
        return path
    }
}

private struct CropGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3, y = rect.minY + rect.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
