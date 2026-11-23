import SwiftUI
import CoreImage

// The story editor's tools for the picture itself: the photo as it sits on the canvas (moved, resized and turned
// freely, over its backdrop), the adjust sliders, and the crop screen. What they set is drawn the same way in the
// preview and in what's posted (see `StoryCanvas`).

extension StoryRGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

/// The photo's place on the canvas, followed live while a finger moves it. Only the photo's own view reads it, so a
/// pinch doesn't redraw the whole editor.
@MainActor
@Observable
final class LiveFraming {
    var value = StoryFraming.fill
}

/// What fills the frame around the picture, in the editor.
struct StoryBackdropView: View {
    var backdrop: StoryBackdrop
    var image: PlatformImage?
    var canvas: CGSize

    var body: some View {
        switch backdrop {
        case .blur:
            ZStack {
                Color.black
                if let image {
                    Image(platformImage: image).resizable().scaledToFill()
                        .frame(width: canvas.width, height: canvas.height)
                        .blur(radius: canvas.width / 14)
                        .clipped()
                }
                Color.black.opacity(0.3)
            }
        case let .gradient(top, bottom):
            LinearGradient(colors: [top.color, bottom.color], startPoint: .top, endPoint: .bottom)
        case let .solid(colour):
            colour.color
        }
    }
}

/// A photo on the story's canvas: its backdrop, and the edited picture placed by `live` (the same sums as
/// `StoryCanvas.compose`, so it posts as it looks).
struct StoryPhotoStage: View {
    var image: PlatformImage
    /// The picture's shape, in pixels.
    var source: CGSize
    var backdrop: StoryBackdrop
    var live: LiveFraming
    var canvas: CGSize

    var body: some View {
        let f = live.value
        let fill = max(canvas.width / max(source.width, 1), canvas.height / max(source.height, 1))
        let w = source.width * fill * f.zoom, h = source.height * fill * f.zoom
        ZStack {
            StoryBackdropView(backdrop: backdrop, image: image, canvas: canvas)
            Image(platformImage: image).resizable()
                .frame(width: w, height: h)
                .rotationEffect(.radians(f.angle))
                .position(x: canvas.width / 2 + f.dx * canvas.width, y: canvas.height / 2 + f.dy * canvas.height)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .accessibilityLabel("Photo")
    }
}

// MARK: - Adjust

/// Brightness, contrast, saturation, warmth, vignette and sharpen: pick one below, slide it above. A small dot marks
/// the ones that have been changed; tap the number to put one back.
struct StoryAdjustPanel: View {
    @Binding var adjust: StoryAdjust
    @Binding var tool: StoryAdjust.Tool
    var done: () -> Void

    private var value: Binding<Double> {
        Binding(get: { adjust[tool] }, set: { new in
            let old = adjust[tool]
            // A tick when it passes through, or lands on, where it started.
            var snapped = new
            if abs(new) < 0.03 { snapped = 0 }
            if (old == 0) != (snapped == 0) || (old < 0) != (snapped < 0) { Haptics.tick() }
            adjust[tool] = snapped
        })
    }

    var body: some View {
        VStack(spacing: 14) {
            // Tap the number to put this one back.
            Button { adjust[tool] = 0; Haptics.tick() } label: {
                Text(label(adjust[tool]))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 60, minHeight: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset \(tool.label)")
            Slider(value: value, in: tool.range)
                .tint(.white)
                .padding(.horizontal, 28)
                .accessibilityLabel(tool.label)
                .accessibilityValue(label(adjust[tool]))
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(StoryAdjust.Tool.allCases) { item in
                        Button { withAnimation(.snappy(duration: 0.2)) { tool = item } } label: {
                            VStack(spacing: 6) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(width: 46, height: 46)
                                    .background(.white.opacity(tool == item ? 0.22 : 0.08), in: .circle)
                                    .overlay(alignment: .topTrailing) {
                                        if adjust[item] != 0 { Circle().fill(.white).frame(width: 6, height: 6).offset(x: -2, y: 2) }
                                    }
                                Text(item.label).font(.system(size: 11, weight: tool == item ? .semibold : .regular))
                            }
                            .foregroundStyle(.white.opacity(tool == item ? 1 : 0.75))
                            .frame(width: 70)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.label)
                        .accessibilityAddTraits(tool == item ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.never)
            HStack {
                Button("Reset") { withAnimation(.snappy) { adjust = StoryAdjust() } }
                    .disabled(adjust.isNeutral)
                    .opacity(adjust.isNeutral ? 0.4 : 1)
                Spacer()
                Button("Done", action: done).fontWeight(.semibold)
            }
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .padding(.horizontal, 22)
        }
        .padding(.vertical, 16)
        .background(.black.opacity(0.55))
    }

    private func label(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }
}

// MARK: - Crop

/// Crop, straighten, turn and flip, Instagram-style: drag the corners or edges of the box (or the box itself), pick a
/// shape, turn the dial to straighten. Done hands back the crop; nothing changes until then.
struct StoryCropTool: View {
    /// The whole picture, the right way up, with nothing cut yet.
    let source: PlatformImage
    @State var draft: StoryCrop
    var done: (StoryCrop) -> Void
    var cancel: () -> Void

    @State private var aspect = CropShape.free
    /// The picture flipped and turned as the draft says, for drawing.
    @State private var oriented: PlatformImage?
    @State private var grab: Grab?
    @State private var startRect: CGRect?
    @State private var startAngle: Double?

    enum CropShape: String, CaseIterable, Identifiable {
        case free = "Free", original = "Original", square = "1:1", portrait = "4:5", story = "9:16", wide = "16:9"
        var id: String { rawValue }
        /// Width over height in pixels; nil for free.
        func ratio(original: CGSize) -> CGFloat? {
            switch self {
            case .free: nil
            case .original: original.width / max(original.height, 1)
            case .square: 1
            case .portrait: 4.0 / 5
            case .story: 9.0 / 16
            case .wide: 16.0 / 9
            }
        }
    }

    private enum Grab: Equatable { case corner(Int), edge(Int), move }

    private var sourceSize: CGSize {
        let image = source.cgImageValue
        return CGSize(width: image?.width ?? 1, height: image?.height ?? 1)
    }
    private var orientedSize: CGSize { draft.orientedSize(of: sourceSize) }

    var body: some View {
        GeometryReader { geo in
            let area = CGSize(width: geo.size.width - 48, height: max(geo.size.height - 250, 100))
            let o = orientedSize
            let k = min(area.width / max(o.width, 1), area.height / max(o.height, 1))
            let shown = CGSize(width: o.width * k, height: o.height * k)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2, y: 70 + (area.height - shown.height) / 2)
            let box = CGRect(x: origin.x + draft.rect.minX * shown.width, y: origin.y + draft.rect.minY * shown.height,
                             width: draft.rect.width * shown.width, height: draft.rect.height * shown.height)
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                if let oriented, let cg = oriented.cgImageValue,
                   abs(CGFloat(cg.width) / CGFloat(max(cg.height, 1)) - o.width / max(o.height, 1)) < 0.01 {
                    picture(oriented, shown: shown, origin: origin)
                }
                shade(box: box, size: geo.size)
                frame(box: box)
                    .contentShape(Rectangle())
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { drag in dragged(drag, box: box, shown: shown) }
                        .onEnded { _ in grab = nil; startRect = nil })
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    controls
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: [draft.turns, draft.flipped ? 1 : 0]) { await orient() }
    }

    /// The picture, straightened about the middle of the box and grown just enough to cover it, as it will be cut.
    private func picture(_ image: PlatformImage, shown: CGSize, origin: CGPoint) -> some View {
        let o = orientedSize
        let r = draft.rect
        let boxPixels = CGRect(x: r.minX * o.width, y: (1 - r.maxY) * o.height, width: r.width * o.width, height: r.height * o.height)
        let grow = StoryCrop.coverScale(box: boxPixels.size, centre: CGPoint(x: boxPixels.midX, y: boxPixels.midY),
                                        angle: draft.straighten * .pi / 180, image: o)
        let anchor = UnitPoint(x: r.midX, y: r.midY)
        return Image(platformImage: image).resizable()
            .frame(width: shown.width, height: shown.height)
            .scaleEffect(grow, anchor: anchor)
            .rotationEffect(.degrees(draft.straighten), anchor: anchor)
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
    }

    /// Everything outside the box, dimmed.
    private func shade(box: CGRect, size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: CGPoint(x: -100, y: -100), size: CGSize(width: size.width + 200, height: size.height + 200)))
            path.addRect(box)
        }
        .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// The box's border, a third grid while it's being moved, and the corner marks.
    private func frame(box: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().strokeBorder(.white, lineWidth: 1.5)
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
            if grab != nil {
                Path { path in
                    for n in 1...2 {
                        let x = box.minX + box.width * CGFloat(n) / 3, y = box.minY + box.height * CGFloat(n) / 3
                        path.move(to: CGPoint(x: x, y: box.minY)); path.addLine(to: CGPoint(x: x, y: box.maxY))
                        path.move(to: CGPoint(x: box.minX, y: y)); path.addLine(to: CGPoint(x: box.maxX, y: y))
                    }
                }
                .stroke(.white.opacity(0.5), lineWidth: 0.75)
            }
            Path { path in
                let l: CGFloat = 20
                for (x, y, sx, sy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1, 1),
                                       (box.maxX, box.maxY, -1, -1), (box.minX, box.maxY, 1, -1)] {
                    path.move(to: CGPoint(x: x, y: y + l * sy)); path.addLine(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x + l * sx, y: y))
                }
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack {
            Button(action: cancel) { Image(systemName: "xmark") }
                .accessibilityLabel("Cancel")
            Spacer()
            Text("Crop").font(.system(size: 16, weight: .semibold))
            Spacer()
            Button { done(draft) } label: { Image(systemName: "checkmark") }
                .accessibilityLabel("Done")
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            StraightenDial(angle: $draft.straighten)
            HStack(spacing: 22) {
                Button {
                    withAnimation(.snappy) {
                        draft.turns = (draft.turns + 1) % 4
                        draft.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
                    }
                    apply(aspect)
                } label: { Image(systemName: "rotate.right") }
                    .accessibilityLabel("Turn a quarter")
                Button { withAnimation(.snappy) { draft.flipped.toggle() } } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .accessibilityLabel("Flip")
                Spacer()
                Button("Reset") {
                    withAnimation(.snappy) { draft = StoryCrop(); aspect = .free }
                }
                .font(.system(size: 15, weight: .medium))
                .disabled(draft.isIdentity)
                .opacity(draft.isIdentity ? 0.4 : 1)
            }
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(CropShape.allCases) { shape in
                        Button(shape.rawValue) { withAnimation(.snappy) { aspect = shape; apply(shape) } }
                            .font(.system(size: 13, weight: aspect == shape ? .semibold : .regular))
                            .foregroundStyle(aspect == shape ? .black : .white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(aspect == shape ? Color.white : .white.opacity(0.12), in: .capsule)
                            .buttonStyle(.plain)
                            .accessibilityLabel("Crop to \(shape == .free ? "any shape" : shape.rawValue)")
                            .accessibilityAddTraits(aspect == shape ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.never)
        }
        .padding(.bottom, 20)
    }

    // MARK: Changing the box

    /// The box's width over height as a fraction of the picture, for a shape in pixels.
    private func unitRatio(_ shape: CropShape) -> CGFloat? {
        let o = orientedSize
        return shape.ratio(original: o).map { $0 * o.height / max(o.width, 1) }
    }

    /// The biggest box of `shape` that fits, around the middle of the one there is.
    private func apply(_ shape: CropShape) {
        guard let a = unitRatio(shape) else { return }
        var w: CGFloat = 1, h = 1 / a
        if h > 1 { h = 1; w = a }
        let c = CGPoint(x: draft.rect.midX, y: draft.rect.midY)
        let x = min(max(c.x - w / 2, 0), 1 - w), y = min(max(c.y - h / 2, 0), 1 - h)
        draft.rect = CGRect(x: x, y: y, width: w, height: h)
    }

    private func dragged(_ drag: DragGesture.Value, box: CGRect, shown: CGSize) {
        if grab == nil {
            startRect = draft.rect
            let p = drag.startLocation
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            if let n = corners.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 34 }) {
                grab = .corner(n)
            } else if abs(p.y - box.minY) < 22, p.x > box.minX, p.x < box.maxX { grab = .edge(0)
            } else if abs(p.x - box.maxX) < 22, p.y > box.minY, p.y < box.maxY { grab = .edge(1)
            } else if abs(p.y - box.maxY) < 22, p.x > box.minX, p.x < box.maxX { grab = .edge(2)
            } else if abs(p.x - box.minX) < 22, p.y > box.minY, p.y < box.maxY { grab = .edge(3)
            } else if box.contains(p) { grab = .move
            } else { return }
        }
        guard let grab, let start = startRect else { return }
        let dx = drag.translation.width / max(shown.width, 1), dy = drag.translation.height / max(shown.height, 1)
        let least = StoryCrop.smallest
        var r = start
        switch grab {
        case .move:
            r.origin.x = min(max(start.minX + dx, 0), 1 - start.width)
            r.origin.y = min(max(start.minY + dy, 0), 1 - start.height)
        case let .edge(e):
            // With a shape chosen, the edge's own side leads and the other follows.
            guard unitRatio(aspect) == nil else {
                return resizeCorner(e == 0 || e == 3 ? 0 : 2, dx: e % 2 == 1 ? dx : 0, dy: e % 2 == 0 ? dy : 0, start: start,
                                    lead: e % 2 == 1 ? .width : .height)
            }
            switch e {
            case 0: let top = min(max(start.minY + dy, 0), start.maxY - least); r = CGRect(x: start.minX, y: top, width: start.width, height: start.maxY - top)
            case 1: let right = min(max(start.maxX + dx, start.minX + least), 1); r.size.width = right - start.minX
            case 2: let bottom = min(max(start.maxY + dy, start.minY + least), 1); r.size.height = bottom - start.minY
            default: let left = min(max(start.minX + dx, 0), start.maxX - least); r = CGRect(x: left, y: start.minY, width: start.maxX - left, height: start.height)
            }
        case let .corner(n):
            return resizeCorner(n, dx: dx, dy: dy, start: start)
        }
        draft.rect = r
    }

    private enum Lead { case width, height }

    /// Moves one corner (0 top left, then clockwise) with the opposite one held, keeping the shape if one is chosen: the
    /// side moved further (for its size) leads, so the box shrinks as readily as it grows.
    private func resizeCorner(_ n: Int, dx: CGFloat, dy: CGFloat, start: CGRect, lead: Lead? = nil) {
        let least = StoryCrop.smallest
        let anchor = [CGPoint(x: start.maxX, y: start.maxY), CGPoint(x: start.minX, y: start.maxY),
                      CGPoint(x: start.minX, y: start.minY), CGPoint(x: start.maxX, y: start.minY)][n]
        let moving = [CGPoint(x: start.minX, y: start.minY), CGPoint(x: start.maxX, y: start.minY),
                      CGPoint(x: start.maxX, y: start.maxY), CGPoint(x: start.minX, y: start.maxY)][n]
        let sx: CGFloat = n == 0 || n == 3 ? -1 : 1, sy: CGFloat = n < 2 ? -1 : 1
        // How far the moving corner may go from the held one, staying inside the picture.
        let roomX = sx > 0 ? 1 - anchor.x : anchor.x, roomY = sy > 0 ? 1 - anchor.y : anchor.y
        var w = min(max((moving.x + dx - anchor.x) * sx, least), roomX)
        var h = min(max((moving.y + dy - anchor.y) * sy, least), roomY)
        if let a = unitRatio(aspect) {
            let byWidth = lead.map { $0 == .width }
                ?? (abs(w - start.width) / max(start.width, 0.001) >= abs(h - start.height) / max(start.height, 0.001))
            if byWidth { h = w / a } else { w = h * a }
            if w < least { w = least; h = w / a }
            if h < least { h = least; w = h * a }
            if h > roomY { h = roomY; w = h * a }
            if w > roomX { w = roomX; h = w / a }
        }
        draft.rect = CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
    }

    /// Flips and turns the picture for drawing, off the main thread. Kept only if the draft still turns and flips that way,
    /// so quick taps can't leave it showing an older turn squeezed into the new shape.
    private func orient() async {
        guard let cg = source.cgImageValue else { return }
        let crop = draft
        let made: CGImage? = await Task.detached(priority: .userInitiated) {
            let image = crop.oriented(CIImage(cgImage: cg))
            return StoryFilter.context.createCGImage(image, from: image.extent)
        }.value
        guard !Task.isCancelled, draft.turns == crop.turns, draft.flipped == crop.flipped, let made else { return }
        oriented = .from(cgImage: made)
    }
}

/// A ruler that turns the picture up to 45 degrees either way: drag it sideways. It clicks at upright, and a
/// double tap puts it back.
struct StraightenDial: View {
    @Binding var angle: Double
    @State private var start: Double?
    /// Degrees per point dragged.
    private let rate = 0.12

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%.0f°", angle))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(angle == 0 ? .white.opacity(0.7) : .white)
            GeometryReader { geo in
                Canvas { context, size in
                    let mid = size.width / 2
                    let step = 1 / rate
                    // Ticks every degree, longer every five, moving as the angle changes.
                    for d in Int(-StoryCrop.straightenLimit)...Int(StoryCrop.straightenLimit) {
                        let x = mid + (Double(d) - angle) * step
                        guard x >= 0, x <= size.width else { continue }
                        let long = d % 5 == 0
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: size.height / 2 - (long ? 9 : 5)))
                        path.addLine(to: CGPoint(x: x, y: size.height / 2 + (long ? 9 : 5)))
                        context.stroke(path, with: .color(.white.opacity(d == 0 ? 1 : long ? 0.7 : 0.35)), lineWidth: d == 0 ? 2 : 1)
                    }
                    var needle = Path()
                    needle.move(to: CGPoint(x: mid, y: 0)); needle.addLine(to: CGPoint(x: mid, y: size.height))
                    context.stroke(needle, with: .color(.yellow), lineWidth: 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if start == nil { start = angle }
                        let limit = StoryCrop.straightenLimit
                        var next = min(max((start ?? 0) - drag.translation.width * rate, -limit), limit)
                        if abs(next) < 0.6 { next = 0 }
                        if (next == 0) != (angle == 0) { Haptics.tick() }
                        angle = next
                    }
                    .onEnded { _ in start = nil })
                .simultaneousGesture(TapGesture(count: 2).onEnded { withAnimation(.snappy) { angle = 0 } })
                .frame(width: geo.size.width)
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 24)
        .accessibilityElement()
        .accessibilityLabel("Straighten")
        .accessibilityValue(String(format: "%.0f degrees", angle))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: angle = min(angle + 1, StoryCrop.straightenLimit)
            case .decrement: angle = max(angle - 1, -StoryCrop.straightenLimit)
            @unknown default: break
            }
        }
    }
}
