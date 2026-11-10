import SwiftUI

/// What sits behind the messages in every chat: one of the built-in looks, drawn in the theme's own colours, or a
/// photo of your own. The photo lives inside the vault with the rest of your data, so it is sealed on disk and goes
/// with Burn; it is never put in the relay backup.
struct ChatBackground: Codable, Equatable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        /// Whatever the current theme uses.
        case theme
        case plain, glow, dots, waves
        case photo

        var id: String { rawValue }

        var name: String {
            switch self {
            case .theme: "Theme"
            case .plain: "Plain"
            case .glow: "Glow"
            case .dots: "Dots"
            case .waves: "Waves"
            case .photo: "Your photo"
            }
        }

        /// The looks that come with the app, in the order they're offered.
        static let builtIn: [Style] = [.plain, .glow, .dots, .waves]
    }

    var style: Style = .theme
    /// Your own picture, as a cleaned JPEG.
    var photo: Data?
    /// How far the photo is zoomed in past filling the screen: 1 just fills it.
    var zoom: Double = 1
    /// The point of the photo (0...1 across and down) kept in the middle of the chat, whatever its size.
    var focusX: Double = 0.5
    var focusY: Double = 0.5
    /// How much the theme's background colour is laid over the photo, so messages stay easy to read.
    var fade: Double = 0.25
    var blur: Double = 0
    /// The size of the dots and waves patterns, 1 being the usual size.
    var patternSize: Double = 1

    static let zoomRange: ClosedRange<Double> = 1...4
    static let patternRange: ClosedRange<Double> = 0.6...2
    /// The longest side, in pixels, a photo is kept at.
    static let photoSide: CGFloat = 2400

    init() {}

    /// What is actually drawn with this theme: the theme's own look when none is picked, or when a photo is picked
    /// but isn't here (it never travels in the backup).
    func shown(in theme: Theme) -> Style {
        switch style {
        case .theme: theme.backdrop
        case .photo where photo == nil: theme.backdrop
        default: style
        }
    }

    /// Tolerates fields added later, and a look from a newer build, which opens as the theme's own.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? c.decodeIfPresent(String.self, forKey: .style)).flatMap(Style.init(rawValue:)) ?? .theme
        photo = try? c.decodeIfPresent(Data.self, forKey: .photo)
        func number(_ key: CodingKeys, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let value = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback
            return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        zoom = number(.zoom, 1, Self.zoomRange)
        focusX = number(.focusX, 0.5, 0...1)
        focusY = number(.focusY, 0.5, 0...1)
        fade = number(.fade, 0.25, 0...0.9)
        blur = number(.blur, 0, 0...1)
        patternSize = number(.patternSize, 1, Self.patternRange)
    }

    /// Where a picture `image` big goes inside `box` so it fills it at `zoom`, with the focus point as near the
    /// middle as the edges allow. Works for any box, so the photo stays right as a window is resized or the phone
    /// turns.
    static func layout(image: CGSize, in box: CGSize, zoom: CGFloat, focus: CGPoint) -> CGRect {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return CGRect(origin: .zero, size: box) }
        let scale = max(box.width / image.width, box.height / image.height) * max(zoom, 1)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        let x = min(0, max(box.width - size.width, box.width / 2 - focus.x * size.width))
        let y = min(0, max(box.height - size.height, box.height / 2 - focus.y * size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

extension Theme {
    /// Each theme's own chat background, used until you pick another.
    var backdrop: ChatBackground.Style {
        switch id {
        case Theme.light.id: .dots
        case Theme.graphite.id: .waves
        default: .glow
        }
    }
}

/// Draws a chat background to fill whatever space it's given.
struct ChatBackdrop: View, Equatable {
    var background: ChatBackground
    var theme: Theme

    var body: some View {
        let ink = theme.ink
        ZStack {
            ink.base
            switch background.shown(in: theme) {
            case .glow: GlowPattern(theme: theme)
            case .dots: DotsPattern(theme: theme, size: background.patternSize)
            case .waves: WavesPattern(theme: theme, size: background.patternSize)
            case .photo:
                if let photo = background.photo {
                    PhotoBackdrop(data: photo, zoom: background.zoom, focus: CGPoint(x: background.focusX, y: background.focusY),
                                  blur: background.blur)
                    ink.base.opacity(background.fade)
                }
            case .plain, .theme: EmptyView()
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A few soft pools of the theme's colours.
private struct GlowPattern: View {
    var theme: Theme

    var body: some View {
        let strength = theme.scheme == .light ? 0.16 : 0.2
        Canvas { context, size in
            let reach = max(size.width, size.height)
            let pools: [(CGPoint, CGFloat, Color)] = [
                (CGPoint(x: size.width * 0.05, y: size.height * 0.12), reach * 0.65, theme.colors[0]),
                (CGPoint(x: size.width * 0.95, y: size.height * 0.5), reach * 0.6, theme.colors[1]),
                (CGPoint(x: size.width * 0.25, y: size.height * 1.0), reach * 0.6, theme.colors[2]),
            ]
            for (centre, radius, color) in pools {
                let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect),
                             with: .radialGradient(Gradient(colors: [color.opacity(strength), color.opacity(0)]),
                                                   center: centre, startRadius: 0, endRadius: radius))
            }
        }
    }
}

/// An even grid of small dots, offset every other row, under a faint wash of the accent.
private struct DotsPattern: View {
    var theme: Theme
    var size: Double

    var body: some View {
        let ink = theme.ink
        Canvas { context, area in
            context.fill(Path(CGRect(origin: .zero, size: area)),
                         with: .linearGradient(Gradient(colors: [theme.accent.opacity(theme.scheme == .light ? 0.07 : 0.08), .clear]),
                                               startPoint: .zero, endPoint: CGPoint(x: area.width, y: area.height)))
            let gap = 20 * size, radius = 1.4 * size
            let dot = ink.text.opacity(theme.scheme == .light ? 0.1 : 0.09)
            var row = 0
            var y = gap / 2
            while y < area.height + gap {
                var x = row.isMultiple(of: 2) ? gap / 2 : gap
                while x < area.width + gap {
                    context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(dot))
                    x += gap
                }
                y += gap * 0.87
                row += 1
            }
        }
    }
}

/// Gentle lines that rise and fall across the chat, in the accent.
private struct WavesPattern: View {
    var theme: Theme
    var size: Double

    var body: some View {
        Canvas { context, area in
            let gap = 30 * size, height = 7 * size, length = 120 * size
            var y: CGFloat = gap / 2
            var line = 0
            while y < area.height + gap {
                var path = Path()
                let shift = CGFloat(line % 3) * length / 3
                path.move(to: CGPoint(x: -length, y: y))
                var x: CGFloat = -length
                while x <= area.width + length {
                    path.addLine(to: CGPoint(x: x, y: y + sin((x + shift) / length * 2 * .pi) * height))
                    x += 4
                }
                let strength = theme.scheme == .light ? 0.13 : 0.1
                context.stroke(path, with: .color(theme.colors[line % 2 == 0 ? 0 : 1].opacity(strength)), lineWidth: max(1, 1.2 * size))
                y += gap
                line += 1
            }
        }
    }
}

/// Your own photo, filling the space around its focus point.
struct PhotoBackdrop: View {
    var data: Data
    var zoom: Double
    var focus: CGPoint
    var blur: Double

    var body: some View {
        GeometryReader { geo in
            if let image = DecodedImages.image(data, fit: ChatBackground.photoSide) {
                let rect = ChatBackground.layout(image: image.size, in: geo.size, zoom: zoom, focus: focus)
                Image(platformImage: image)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .blur(radius: blur * 24, opaque: true)
            }
        }
        .clipped()
    }
}

// MARK: - Choosing one

/// A small picture of one background, with a mock message each way, for the settings grid.
struct BackdropTile: View {
    var background: ChatBackground
    var theme: Theme
    var label: String
    var note: String?
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    ChatBackdrop(background: background, theme: theme)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 6).fill(theme.ink.raised)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.ink.line))
                            .frame(width: 44, height: 14)
                        RoundedRectangle(cornerRadius: 6).fill(theme.gradient)
                            .frame(width: 50, height: 14)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        RoundedRectangle(cornerRadius: 6).fill(theme.ink.raised)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.ink.line))
                            .frame(width: 34, height: 14)
                        Spacer(minLength: 0)
                    }
                    .padding(9)
                }
                .frame(height: 128)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Ink.line), lineWidth: selected ? 2 : 1))
                .scaleEffect(hover ? 1.02 : 1)
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(selected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Ink.faint))
                        Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(selected ? Ink.text : Ink.dim)
                    }
                    Text(note ?? " ").font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.25)) { hover = h } }
        .animation(.snappy, value: selected)
        .accessibilityLabel(label + (note.map { ", " + $0 } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Places your photo: drag to move it, pinch (or the slider) to zoom, and fade or blur it so messages stay readable.
/// The preview is the shape of this screen, with a few messages on it.
struct PhotoBackdropEditor: View {
    var start: ChatBackground
    var theme: Theme
    var done: (ChatBackground?) -> Void

    @State private var draft = ChatBackground()
    @State private var settledZoom: Double = 1
    @State private var settledFocus = CGPoint(x: 0.5, y: 0.5)
    @State private var imageSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 16) {
            Text("Move and scale").font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text)
            GeometryReader { geo in
                let box = previewSize(in: geo.size)
                ZStack {
                    ChatBackdrop(background: draft, theme: theme)
                    sampleMessages
                }
                .frame(width: box.width, height: box.height)
                .clipShape(.rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Ink.line))
                .overlay {
                    TransformSurface(
                        began: { _ in settledZoom = draft.zoom; settledFocus = CGPoint(x: draft.focusX, y: draft.focusY) },
                        changed: { value in move(value, box: box) },
                        ended: { _ in settledZoom = draft.zoom; settledFocus = CGPoint(x: draft.focusX, y: draft.focusY) })
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(minHeight: 300)

            VStack(spacing: 12) {
                slider("Zoom", symbol: "plus.magnifyingglass", value: $draft.zoom, range: ChatBackground.zoomRange)
                slider("Fade", symbol: "circle.lefthalf.filled", value: $draft.fade, range: 0...0.9)
                slider("Blur", symbol: "drop", value: $draft.blur, range: 0...1)
            }

            HStack(spacing: 12) {
                Button("Cancel") { done(nil) }.buttonStyle(SecondaryButtonStyle())
                Button("Set") { done(draft) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20)
        .frame(minWidth: Platform.isPhone ? nil : 460, minHeight: Platform.isPhone ? nil : 680)
        .background(Ink.base)
        .interactiveDismissDisabled()
        .onAppear {
            draft = start
            draft.style = .photo
            if let photo = start.photo, let image = DecodedImages.image(photo, fit: ChatBackground.photoSide) { imageSize = image.size }
        }
    }

    /// The preview keeps this screen's shape (a chat window's on the Mac), as large as fits.
    private func previewSize(in space: CGSize) -> CGSize {
        #if os(iOS)
        let screen = UIScreen.main.bounds.size
        let aspect = min(screen.width, screen.height) / max(screen.width, screen.height)
        #else
        let aspect: CGFloat = 0.8
        #endif
        let width = min(space.width, space.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    /// Dragging moves the photo under your finger; pinching zooms around the middle.
    private func move(_ value: TransformValue, box: CGSize) {
        let zoom = min(max(settledZoom * value.scale, ChatBackground.zoomRange.lowerBound), ChatBackground.zoomRange.upperBound)
        draft.zoom = zoom
        let shown = ChatBackground.layout(image: imageSize, in: box, zoom: zoom, focus: settledFocus).size
        guard shown.width > 0, shown.height > 0 else { return }
        // Keep the focus where the edges let it be, so letting go never makes the photo jump.
        let reachX = box.width / 2 / shown.width, reachY = box.height / 2 / shown.height
        let x = settledFocus.x - value.translation.width / shown.width
        let y = settledFocus.y - value.translation.height / shown.height
        draft.focusX = Double(min(max(x, reachX), 1 - reachX))
        draft.focusY = Double(min(max(y, reachY), 1 - reachY))
    }

    private func slider(_ title: String, symbol: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Ink.faint).frame(width: 20)
            Text(title).font(.system(size: 14)).foregroundStyle(Ink.dim).frame(width: 44, alignment: .leading)
            Slider(value: value, in: range).tint(theme.accent)
        }
        .font(.system(size: 13))
    }

    private var sampleMessages: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            bubble("Did you see it?", mine: false)
            bubble("Just now, it's great", mine: true)
            bubble("Told you", mine: false)
        }
        .padding(14)
        .allowsHitTesting(false)
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(mine ? theme.ink.onAccent : theme.ink.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(mine ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(theme.ink.surface), in: .rect(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}
