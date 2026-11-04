import SwiftUI

/// The shape a picture is framed to before it's used.
struct CropFrame: Equatable {
    /// Width over height.
    var aspect: CGFloat
    var circle = false
    /// The longest side of the result, in pixels.
    var maxSide: CGFloat

    static let avatar = CropFrame(aspect: 1, circle: true, maxSide: 512)
    static let banner = CropFrame(aspect: 3, maxSide: 1200)
    static let story = CropFrame(aspect: 9.0 / 16.0, maxSide: 1600)
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
                .contentShape(.rect)
                .gesture(
                    DragGesture()
                        .onChanged { g in
                            dragging = true
                            drag = g.translation
                            apply(geo.size, box: box)
                        }
                        .onEnded { _ in
                            dragging = false
                            commitIfIdle()
                        }
                        .simultaneously(with: MagnifyGesture()
                            .onChanged { g in
                                pinching = true
                                pinch = g.magnification
                                pinchAnchor = CGPoint(x: g.startAnchor.x * geo.size.width - geo.size.width / 2,
                                                      y: g.startAnchor.y * geo.size.height - geo.size.height / 2)
                                apply(geo.size, box: box)
                            }
                            .onEnded { _ in
                                pinching = false
                                commitIfIdle()
                            })
                )
                .onAppear { boxCache = box }
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
                Slider(value: Binding(get: { zoom }, set: { setZoom($0) }), in: 1...Self.maxZoom)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(Ink.faint)
            }
            .font(.system(size: 13))

            HStack(spacing: 12) {
                Button("Cancel") { done(nil) }.buttonStyle(SecondaryButtonStyle())
                Button(useLabel) { done(crop(picture)) }.buttonStyle(PrimaryButtonStyle()).disabled(picture == nil)
            }
        }
        .padding(20)
        .task { picture = cleanJPEG(image, maxSide: 2400).flatMap { PlatformImage(data: $0) }?.cgImageValue }
        .frame(minWidth: Platform.isPhone ? nil : 460, minHeight: Platform.isPhone ? nil : 560)
        .background(Theme.dark.ink.base)
        .preferredColorScheme(.dark)
    }

    @State private var boxCache: CGSize = .zero
    @State private var drag: CGSize = .zero
    @State private var pinch: CGFloat = 1
    @State private var pinchAnchor: CGPoint = .zero
    @State private var dragging = false
    @State private var pinching = false
    private static let maxZoom: CGFloat = 8

    /// Moves and zooms from where the last gesture left off. A pinch holds the spot under your fingers still.
    private func apply(_ area: CGSize, box: CGSize) {
        guard let picture else { return }
        let target = min(Self.maxZoom, max(1, settledZoom * pinch))
        let k = target / settledZoom
        let p = pinchAnchor
        let moved = CGSize(width: p.x - (p.x - settledOffset.width) * k + drag.width,
                           height: p.y - (p.y - settledOffset.height) * k + drag.height)
        zoom = target
        offset = clamp(moved, picture, box: box, zoom: target)
    }

    /// Locks the result in once both fingers-and-thumbs gestures are over.
    private func commitIfIdle() {
        guard !dragging, !pinching else { return }
        settledZoom = zoom
        settledOffset = offset
        drag = .zero
        pinch = 1
    }

    /// Zoom from the slider, around the middle of the frame.
    private func setZoom(_ value: CGFloat) {
        guard let picture else { return }
        let k = value / max(zoom, 0.001)
        zoom = value
        settledZoom = value
        offset = clamp(CGSize(width: offset.width * k, height: offset.height * k), picture, box: boxCache, zoom: value)
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
        let spareX = max(0, (CGFloat(picture.width) * s - box.width) / 2)
        let spareY = max(0, (CGFloat(picture.height) * s - box.height) / 2)
        return CGSize(width: min(spareX, max(-spareX, o.width)), height: min(spareY, max(-spareY, o.height)))
    }

    /// The part of the picture inside the frame, as a JPEG.
    private func crop(_ picture: CGImage?) -> Data? {
        guard let picture, boxCache.width > 0 else { return nil }
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
