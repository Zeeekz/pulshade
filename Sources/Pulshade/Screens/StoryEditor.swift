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

/// The text on top of the preview, handled the way Instagram does: tap empty space to add text, tap a piece to type
/// in it, drag it to move it, and pinch or twist with two fingers anywhere to resize and turn the last one touched.
/// Drop a piece on the bin to remove it.
///
/// While a piece is dragged its movement is kept apart from the list and applied as an offset, and the drag is
/// measured against the canvas rather than the piece (which moves under the finger), so it follows smoothly.
struct StoryOverlayCanvas: View {
    @Binding var items: [StoryTextOverlay]
    @Binding var active: UUID?
    @Binding var typing: UUID?
    var canvas: CGSize
    var add: () -> Void
    @State private var dragging: UUID?
    @State private var offset = CGSize.zero
    @State private var pinch = 1.0
    @State private var twist = 0.0
    @State private var snapped = false

    private static let space = "storyCanvas"

    /// Whether the piece being dragged is over the bin at the bottom.
    private var overBin: Bool {
        guard let dragging, let item = items.first(where: { $0.id == dragging }) else { return false }
        return item.y + offset.height / canvas.height > 0.88
    }

    var body: some View {
        ZStack {
            Color.clear.contentShape(.rect).onTapGesture { add() }
            ForEach(items) { item in
                let live = live(item)
                StoryTextItem(item: live, canvas: canvas, hint: true)
                    .opacity(typing == item.id ? 0 : 1)
                    .contentShape(.rect)
                    .gesture(drag(item))
                    .position(x: canvas.width * item.x + (dragging == item.id ? offset.width : 0),
                              y: canvas.height * item.y + (dragging == item.id ? offset.height : 0))
                    .accessibilityLabel(item.text.isEmpty ? "Empty text" : item.text)
                    .accessibilityHint("Double tap to edit")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { typing = item.id }
            }
            if dragging != nil {
                Image(systemName: "trash.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(overBin ? Color.red : Color.black.opacity(0.55), in: .circle)
                    .scaleEffect(overBin ? 1.25 : 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
                    .allowsHitTesting(false)
                    .animation(.snappy(duration: 0.15), value: overBin)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .coordinateSpace(name: Self.space)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { _ in
                    update(active) { $0.scale = min(max($0.scale * pinch, 0.3), 6) }
                    pinch = 1
                })
        .simultaneousGesture(
            RotateGesture()
                .onChanged { value in
                    twist = Self.snap(value.rotation.radians, from: active.flatMap { id in items.first { $0.id == id }?.rotation } ?? 0,
                                      snapped: &snapped)
                }
                .onEnded { _ in
                    update(active) { $0.rotation += twist }
                    twist = 0
                    snapped = false
                })
    }

    /// The piece as it looks right now, including a pinch or twist in progress.
    private func live(_ item: StoryTextOverlay) -> StoryTextOverlay {
        guard item.id == active else { return item }
        var shown = item
        shown.scale = min(max(item.scale * pinch, 0.3), 6)
        shown.rotation = item.rotation + twist
        return shown
    }

    /// A turn that lands within a few degrees of upright (or a quarter turn) clicks into place.
    private static func snap(_ turn: Double, from start: Double, snapped: inout Bool) -> Double {
        let total = start + turn
        let quarter = Double.pi / 2
        let nearest = (total / quarter).rounded() * quarter
        if abs(total - nearest) < 0.07 {
            if !snapped { snapped = true; Haptics.tick() }
            return nearest - start
        }
        snapped = false
        return turn
    }

    private func update(_ id: UUID?, _ change: (inout StoryTextOverlay) -> Void) {
        guard let id, let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    private func drag(_ item: StoryTextOverlay) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                active = item.id
                let moved = CGSize(width: value.location.x - value.startLocation.x, height: value.location.y - value.startLocation.y)
                guard dragging == item.id || hypot(moved.width, moved.height) > 5 else { return }
                dragging = item.id
                offset = moved
            }
            .onEnded { value in
                let moved = CGSize(width: value.location.x - value.startLocation.x, height: value.location.y - value.startLocation.y)
                defer { dragging = nil; offset = .zero }
                // Hardly moved: it was a tap, so type in it.
                guard dragging == item.id else { typing = item.id; return }
                if overBin { items.removeAll { $0.id == item.id }; active = nil; return }
                update(item.id) {
                    $0.x = min(max($0.x + moved.width / canvas.width, 0.03), 0.97)
                    $0.y = min(max($0.y + moved.height / canvas.height, 0.03), 0.97)
                }
            }
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
            let size = canvasWidth * item.size
            let ink = StoryInk.colors[item.color % StoryInk.colors.count]
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { finish() }
                // Scrolls when the words outgrow the room above the keyboard, so they can't run off the screen.
                ScrollView {
                TextField("", text: binding(\.text, fallback: ""),
                          prompt: Text("Type here").foregroundStyle(.white.opacity(0.45)), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(item.face.font(size: size))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(item.backed ? StoryInk.readable(on: item.color) : ink)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .padding(.horizontal, item.backed ? size * 0.5 : 0)
                    .padding(.vertical, item.backed ? size * 0.25 : 0)
                    .background {
                        if item.backed { RoundedRectangle(cornerRadius: size * 0.35, style: .continuous).fill(ink) }
                    }
                    .opacity(item.opacity)
                    .frame(maxWidth: canvasWidth * 0.86)
                    .animation(.snappy(duration: 0.15), value: item.backed)
                    .animation(.snappy(duration: 0.15), value: item.face)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.never)
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
