import SwiftUI
import CoreImage

/// Colours text on a story can take.
enum StoryInk {
    static let colors: [Color] = [
        .white, .black, .hex(0xFF3B30), .hex(0xFF9500), .hex(0xFFD60A),
        .hex(0x34C759), .hex(0x2EF2C8), .hex(0x0A84FF), .hex(0xBF5AF2), .hex(0xFF2D92),
    ]
    /// The colours light enough that words on them need to be dark.
    private static let light: Set<Int> = [0, 3, 4, 5, 6]

    /// Text drawn on a background of this colour.
    static func readable(on index: Int) -> Color { light.contains(index) ? .black : .white }
}

/// One piece of text placed on a story picture or clip. Positions are fractions of the story's frame and sizes are
/// fractions of its width, so the same text lands in the same place in the preview and in the picture that is sent.
struct StoryTextOverlay: Identifiable, Equatable {
    enum Face: String, CaseIterable, Identifiable {
        case bold, rounded, serif, mono
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bold: "Bold"
            case .rounded: "Round"
            case .serif: "Serif"
            case .mono: "Mono"
            }
        }
        func font(size: CGFloat) -> Font {
            switch self {
            case .bold: .system(size: size, weight: .bold)
            case .rounded: .system(size: size, weight: .heavy, design: .rounded)
            case .serif: .system(size: size, weight: .semibold, design: .serif)
            case .mono: .system(size: size, weight: .semibold, design: .monospaced)
            }
        }
    }

    var id = UUID()
    var text = ""
    var color = 0
    /// A solid block of the colour behind the words, which then turn dark or light to stay readable.
    var backed = false
    var face = Face.bold
    /// Font size as a fraction of the frame's width.
    var size = 0.08
    var opacity = 1.0
    var x = 0.5
    var y = 0.5
    var scale = 1.0
    var rotation = 0.0

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The words themselves, centred on the origin of their own frame.
struct StoryTextItem: View {
    var item: StoryTextOverlay
    var canvas: CGSize
    /// In the editor, an empty piece of text shows a hint so it can be found.
    var hint = false

    var body: some View {
        let size = canvas.width * item.size
        let ink = StoryInk.colors[item.color % StoryInk.colors.count]
        let shown = item.text.isEmpty ? (hint ? "Type here" : "") : item.text
        let words = Text(shown)
            .font(item.face.font(size: size))
            .multilineTextAlignment(.center)
            .foregroundStyle(item.backed ? StoryInk.readable(on: item.color) : ink)
            .opacity(item.text.isEmpty ? 0.5 : 1)
        // Short text hugs its words; long text wraps at most of the frame's width.
        return WidthLimit(limit: canvas.width * 0.86) { words }
            .padding(.horizontal, item.backed ? size * 0.5 : 0)
            .padding(.vertical, item.backed ? size * 0.25 : 0)
            .background {
                if item.backed { RoundedRectangle(cornerRadius: size * 0.35, style: .continuous).fill(ink) }
            }
            .shadow(color: .black.opacity(item.backed ? 0 : 0.4), radius: size * 0.12)
            .scaleEffect(item.scale)
            .rotationEffect(.radians(item.rotation))
            .opacity(item.opacity)
    }
}

/// Lets its content be as wide as it wants up to a limit, and no wider: text that fits hugs itself, and longer text
/// wraps at the limit.
private struct WidthLimit: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        return view.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? limit, limit), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The finished text, for drawing into the picture that is sent.
struct StoryTextLayer: View {
    var items: [StoryTextOverlay]
    var canvas: CGSize

    var body: some View {
        ZStack {
            ForEach(items.filter { !$0.isEmpty }) { item in
                StoryTextItem(item: item, canvas: canvas)
                    .position(x: canvas.width * item.x, y: canvas.height * item.y)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

/// What a pinch and drag on the story's picture do to a clip under the text: start, follow the fingers (answering
/// which centre lines it has clicked onto), and settle.
struct StoryMediaHandle {
    var began: () -> Void
    var changed: (TransformValue) -> (x: Bool, y: Bool)
    var ended: () -> Void
}

/// The text on top of the preview: tap empty space to add text, tap a piece to type in it, drag it to move it, and
/// pinch or twist to resize and turn it. Two fingers away from any text work on the clip under it, if there is one,
/// or else on the last piece touched. Drop a piece on the bin to remove it.
///
/// One recogniser follows the fingers for all of it (see `TransformSurface`), so the move, pinch and twist never fight
/// and nothing jumps when a finger is added or lifted. Touches are matched to the words as they are drawn, scaled and
/// turned, so what you see is what you can grab. Pieces click onto the centre lines and onto upright, with a tap of
/// the phone, and a piece pulled past an edge stretches and settles back.
struct StoryOverlayCanvas: View {
    @Binding var items: [StoryTextOverlay]
    @Binding var active: UUID?
    @Binding var typing: UUID?
    /// True while a piece or the clip is being held, so the editor can clear its buttons out of the way.
    @Binding var interacting: Bool
    var canvas: CGSize
    var media: StoryMediaHandle? = nil
    /// A sideways swipe on empty space, for changing the look: 1 for the next one, -1 for the one before.
    var swipe: ((Int) -> Void)? = nil
    var add: () -> Void

    private enum Target: Equatable { case item(UUID), media, none }

    @State private var target = Target.none
    /// The piece held, as it was when the touch began, and as it is now.
    @State private var start: StoryTextOverlay?
    @State private var held: StoryTextOverlay?
    /// Each piece's size before its scale and turn, as laid out.
    @State private var sizes: [UUID: CGSize] = [:]
    @State private var guideX = false
    @State private var guideY = false
    @State private var upright = false
    @State private var overBin = false
    @State private var moved = false

    /// How close, in points, a centre has to come to a centre line to click onto it.
    static let snapDistance: CGFloat = 7
    static let scaleRange: ClosedRange<CGFloat> = 0.3...6
    private var binCentre: CGPoint { CGPoint(x: canvas.width / 2, y: canvas.height - 16 - 23) }

    var body: some View {
        ZStack {
            TransformSurface(began: began, changed: changed, ended: ended, tapped: tapped)
            ForEach(items) { item in
                let shown = held.flatMap { $0.id == item.id ? $0 : nil } ?? item
                StoryTextItem(item: shown, canvas: canvas, hint: true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { sizes[item.id] = $0 }
                    .scaleEffect(held?.id == item.id && overBin ? 0.5 : 1)
                    .opacity(typing == item.id ? 0 : held?.id == item.id && overBin ? 0.6 : 1)
                    .position(x: canvas.width * shown.x, y: canvas.height * shown.y)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.text.isEmpty ? "Empty text" : item.text)
                    .accessibilityHint("Double tap to edit")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { typing = item.id }
            }
            guides.allowsHitTesting(false)
            if case .item = target, moved {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(overBin ? Color.red : Color.black.opacity(0.45), in: .circle)
                    .overlay(Circle().strokeBorder(.white.opacity(overBin ? 0 : 0.6), lineWidth: 1))
                    .scaleEffect(overBin ? 1.2 : 1)
                    .position(binCentre)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .animation(.snappy(duration: 0.18), value: overBin)
        .animation(.easeOut(duration: 0.15), value: moved)
    }

    private var guides: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.75)).frame(width: 1).opacity(guideX ? 1 : 0)
            Rectangle().fill(.white.opacity(0.75)).frame(height: 1).opacity(guideY ? 1 : 0)
        }
        .frame(width: canvas.width, height: canvas.height)
        .animation(.easeOut(duration: 0.12), value: guideX)
        .animation(.easeOut(duration: 0.12), value: guideY)
    }

    // MARK: Touches

    /// The top piece under a point, matched against the words as drawn (moved, scaled and turned), with room to spare
    /// around small ones.
    private func item(at point: CGPoint) -> UUID? {
        items.reversed().first { item in
            Self.hits(point, center: CGPoint(x: canvas.width * item.x, y: canvas.height * item.y),
                      size: sizes[item.id] ?? CGSize(width: 80, height: 40), scale: item.scale, rotation: item.rotation)
        }?.id
    }

    /// Whether a point falls on a piece `size` across before scaling, centred at `center`, scaled and turned. Small
    /// pieces still take a touch 44 points across.
    static func hits(_ point: CGPoint, center: CGPoint, size: CGSize, scale: CGFloat, rotation: Double) -> Bool {
        let dx = point.x - center.x, dy = point.y - center.y
        let c = cos(-rotation), s = sin(-rotation)
        let x = dx * c - dy * s, y = dx * s + dy * c
        let halfW = max(size.width * scale / 2, 22) + 6, halfH = max(size.height * scale / 2, 22) + 6
        return abs(x) <= halfW && abs(y) <= halfH
    }

    private func began(_ value: TransformValue) {
        moved = false
        if let id = item(at: value.startLocation) {
            pick(id)
        } else if let media {
            target = .media
            media.began()
        } else if value.fingers >= 2, let active, items.contains(where: { $0.id == active }) {
            pick(active)
        } else {
            target = .none
            return
        }
        interacting = true
    }

    private func pick(_ id: UUID) {
        // The piece touched comes to the front.
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: i)
        items.append(item)
        target = .item(id)
        active = id
        start = item
        held = item
        // Already on a line or upright: the phone taps only when it clicks on again after leaving.
        guideX = abs(item.x - 0.5) * canvas.width < Self.snapDistance
        guideY = abs(item.y - 0.5) * canvas.height < Self.snapDistance
        upright = Self.snapTurn(item.rotation).1
    }

    private func changed(_ value: TransformValue) {
        switch target {
        case .item:
            guard let start else { return }
            if !moved, hypot(value.translation.width, value.translation.height) > 2 || value.fingers > 1 { moved = true }
            var next = start
            var x = canvas.width * start.x + value.translation.width
            var y = canvas.height * start.y + value.translation.height
            let snapX = abs(x - canvas.width / 2) < Self.snapDistance
            let snapY = abs(y - canvas.height / 2) < Self.snapDistance
            if snapX { x = canvas.width / 2 }
            if snapY { y = canvas.height / 2 }
            if snapX && !guideX || snapY && !guideY { Haptics.snap() }
            guideX = snapX
            guideY = snapY
            x = RubberBand.clamp(x, 0...canvas.width, span: 40)
            y = RubberBand.clamp(y, 0...canvas.height, span: 40)
            next.x = x / canvas.width
            next.y = y / canvas.height
            next.scale = Self.softScale(start.scale * value.scale)
            let (turn, snapped) = Self.snapTurn(start.rotation + value.rotation)
            if snapped && !upright { Haptics.snap() }
            upright = snapped
            next.rotation = turn
            held = next
            // The finger, not the middle of the words, decides the bin, so a piece held by its edge still lands in it.
            let finger = value.location
            let nearBin = value.fingers == 1 && hypot(finger.x - binCentre.x, finger.y - binCentre.y) < 50
            if nearBin && !overBin { Haptics.warn() }
            overBin = nearBin
        case .media:
            let lines = media?.changed(value) ?? (x: false, y: false)
            if lines.x && !guideX || lines.y && !guideY { Haptics.snap() }
            guideX = lines.x
            guideY = lines.y
        case .none:
            break
        }
    }

    private func ended(_ value: TransformValue) {
        defer {
            target = .none
            start = nil
            guideX = false
            guideY = false
            upright = false
            overBin = false
            moved = false
            interacting = false
        }
        switch target {
        case let .item(id):
            guard let i = items.firstIndex(where: { $0.id == id }), let now = held else { held = nil; return }
            if overBin {
                withAnimation(.snappy(duration: 0.2)) { items.removeAll { $0.id == id }; held = nil }
                active = nil
                return
            }
            var settled = now
            settled.x = min(max(now.x, 0.04), 0.96)
            settled.y = min(max(now.y, 0.04), 0.96)
            settled.scale = min(max(now.scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
            withAnimation(.spring(duration: 0.32, bounce: 0.18)) {
                items[i] = settled
                held = nil
            }
        case .media:
            media?.ended()
        case .none:
            let dx = value.translation.width, dy = value.translation.height
            if let swipe, value.fingers == 1, abs(dx) > 48, abs(dx) > abs(dy) * 1.5 { swipe(dx < 0 ? 1 : -1) }
        }
    }

    private func tapped(_ point: CGPoint) {
        if let id = item(at: point) {
            active = id
            typing = id
        } else {
            add()
        }
    }

    /// A scale past the limits stretches a little, measured in steps of doubling so it feels the same at both ends.
    static func softScale(_ scale: CGFloat) -> CGFloat {
        let r = scaleRange
        return exp(RubberBand.clamp(log(max(scale, 0.01)), log(r.lowerBound)...log(r.upperBound), span: 0.25))
    }

    /// A turn that lands within a few degrees of upright (or a quarter turn) clicks into place.
    static func snapTurn(_ total: Double) -> (Double, Bool) {
        let quarter = Double.pi / 2
        let nearest = (total / quarter).rounded() * quarter
        return abs(total - nearest) < 0.07 ? (nearest, true) : (total, false)
    }
}

/// Typing in a piece of text, the way Instagram does: the screen dims, the words sit in the middle in their own look,
/// a slider down the left edge sets the size, and above the keyboard are the colours, the font, the background and
/// how see-through it is.
struct StoryTypingOverlay: View {
    @Binding var items: [StoryTextOverlay]
    @Binding var typing: UUID?
    var canvasWidth: CGFloat
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    private var index: Int? { items.firstIndex { $0.id == typing } }

    private func binding<T>(_ keyPath: WritableKeyPath<StoryTextOverlay, T>, fallback: T) -> Binding<T> {
        Binding(get: { index.map { items[$0][keyPath: keyPath] } ?? fallback },
                set: { new in if let i = index { items[i][keyPath: keyPath] = new } })
    }

    private func finish() {
        // Text with nothing in it goes away rather than lingering as a hint.
        if let i = index, items[i].isEmpty { items.remove(at: i) }
        typing = nil
    }

    var body: some View {
        if let i = index {
            let item = items[i]
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { finish() }
                // Scrolls when the words outgrow the room above the keyboard, so they can't run off the screen, and
                // sits in the middle of that room when they don't.
                GeometryReader { room in
                    ScrollView {
                        field(item)
                            .frame(maxWidth: .infinity, minHeight: max(room.size.height - 24, 0))
                            .padding(.vertical, 12)
                            // Tapping around the words, not on them, finishes.
                            .background(Color.clear.contentShape(.rect).onTapGesture { finish() })
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.never)
                }
                // Clear of the Done button; the sides are left alone so words wrap exactly as they will in the story.
                .padding(.top, 52)
            }
            .overlay(alignment: .topTrailing) {
                Button("Done") { finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .overlay(alignment: .leading) {
                VerticalSlider(value: binding(\.size, fallback: 0.08), range: 0.04...0.2)
                    .frame(width: 34, height: 220)
                    .padding(.leading, 8)
                    .accessibilityLabel("Text size")
            }
            .safeAreaInset(edge: .bottom) { controls }
            .onAppear { focused = true }
            .transition(.opacity)
        }
    }

    /// The words being typed, in the box they will have in the story. The box is sized by the words drawn the same
    /// way as on the story (hugging short text, wrapping long text at the same width), and the field sits on top of
    /// it, so the block doesn't change shape when typing ends.
    private func field(_ item: StoryTextOverlay) -> some View {
        let size = canvasWidth * item.size
        let ink = StoryInk.colors[item.color % StoryInk.colors.count]
        // A trailing new line still takes a line of its own, as it does in the field.
        let measured = item.text.isEmpty ? "Type here" : item.text.hasSuffix("\n") ? item.text + " " : item.text
        return WidthLimit(limit: canvasWidth * 0.86) {
            Text(measured)
                .font(item.face.font(size: size))
                .multilineTextAlignment(.center)
        }
        .hidden()
        .overlay {
            TextField("", text: binding(\.text, fallback: ""),
                      prompt: Text("Type here").foregroundStyle(.white.opacity(0.45)), axis: .vertical)
                .textFieldStyle(.plain)
                .font(item.face.font(size: size))
                .multilineTextAlignment(.center)
                .foregroundStyle(item.backed ? StoryInk.readable(on: item.color) : ink)
                .focused($focused)
                .autocorrectionDisabled()
                // A hair of room, so the field never wraps a line the drawn words fit on.
                .padding(.horizontal, -3)
        }
        .padding(.horizontal, item.backed ? size * 0.5 : 0)
        .padding(.vertical, item.backed ? size * 0.25 : 0)
        .background {
            if item.backed { RoundedRectangle(cornerRadius: size * 0.35, style: .continuous).fill(ink) }
        }
        .opacity(item.opacity)
        .animation(.snappy(duration: 0.15), value: item.backed)
        .animation(.snappy(duration: 0.15), value: item.face)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                let face = binding(\.face, fallback: .bold)
                Button {
                    let all = StoryTextOverlay.Face.allCases
                    face.wrappedValue = all[((all.firstIndex(of: face.wrappedValue) ?? 0) + 1) % all.count]
                } label: {
                    Text("Aa").font(face.wrappedValue.font(size: 17)).foregroundStyle(.white)
                        .frame(width: 44, height: 36).background(.white.opacity(0.18), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Font, \(face.wrappedValue.label)")

                let backed = binding(\.backed, fallback: false)
                Button { backed.wrappedValue.toggle() } label: {
                    Image(systemName: backed.wrappedValue ? "a.square.fill" : "a.square")
                        .font(.system(size: 19)).foregroundStyle(backed.wrappedValue ? Color.black : .white)
                        .frame(width: 44, height: 36)
                        .background(backed.wrappedValue ? Color.white : .white.opacity(0.18), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(backed.wrappedValue ? "Remove background" : "Add background")

                Image(systemName: "circle.lefthalf.filled").font(.system(size: 15)).foregroundStyle(.white.opacity(0.8))
                Slider(value: binding(\.opacity, fallback: 1), in: 0.15...1).tint(.white).accessibilityLabel("Transparency")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(0..<StoryInk.colors.count, id: \.self) { i in
                        let on = binding(\.color, fallback: 0).wrappedValue == i
                        Button { binding(\.color, fallback: 0).wrappedValue = i } label: {
                            Circle().fill(StoryInk.colors[i])
                                .frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5).padding(-4).opacity(on ? 1 : 0))
                                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                                .scaleEffect(on ? 1.12 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(i + 1)")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        .background(.black.opacity(0.35))
    }
}

/// A slider that goes up and down, for the text size at the edge of the screen.
struct VerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.3)).frame(width: 4)
                Circle().fill(.white).frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.3), radius: 3)
                    .offset(y: -(geo.size.height - 22) * t)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let t = 1 - min(max((drag.location.y - 11) / max(geo.size.height - 22, 1), 0), 1)
                value = range.lowerBound + t * (range.upperBound - range.lowerBound)
            })
        }
        .accessibilityElement()
        .accessibilityValue("\(Int((value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 10
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}

/// The background of a text story: its colours, with the faint pattern.
struct StoryTextBackdrop: View {
    var palette: Int
    var seed = "pulshade"

    var body: some View {
        ZStack {
            StoryPalette.gradient(palette)
            GenerativeArt(seed: seed).opacity(0.18).blendMode(.overlay)
        }
        .clipped()
    }
}

/// Draws the text into pictures: one for putting over every frame of a clip or a photo, and whole text stories.
@MainActor
enum StoryOverlayRender {
    /// The size everything is drawn at (the story's frame at full HD).
    static let size = CGSize(width: 1080, height: 1920)

    private static func cgImage<V: View>(_ view: V) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        return renderer.cgImage
    }

    /// Only the text, on a clear background. Nil if there's none.
    static func text(_ items: [StoryTextOverlay]) -> CIImage? {
        guard items.contains(where: { !$0.isEmpty }), let image = cgImage(StoryTextLayer(items: items, canvas: size)) else { return nil }
        return CIImage(cgImage: image)
    }

    /// A text story as a picture: the colours with the text on top.
    static func textStory(_ items: [StoryTextOverlay], palette: Int, seed: String) -> Data? {
        let view = ZStack {
            StoryTextBackdrop(palette: palette, seed: seed)
            StoryTextLayer(items: items, canvas: size)
        }
        guard let image = cgImage(view), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return StoryFilter.context.jpegRepresentation(
            of: CIImage(cgImage: image), colorSpace: space,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
    }
}
