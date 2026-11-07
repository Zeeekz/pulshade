import SwiftUI
import CryptoKit

/// The flat background behind every screen: nothing animates or blurs behind the chats and the keyboard.
struct Backdrop: View {
    var body: some View {
        Ink.void.ignoresSafeArea().allowsHitTesting(false)
    }
}

/// The signed-out screens' background: near-black with one soft light falling from above in the theme's
/// colour, a faint dot grid that fades out toward the edges, and a slow breath so it never feels static.
struct Aurora: View {
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = 0.5 + 0.5 * sin(t * 0.35)
            GeometryReader { geo in
                let size = geo.size
                let reach = max(size.width, size.height)
                ZStack {
                    Ink.void
                    // The main light, falling from just above the top edge and fading out with no edge of its own.
                    Rectangle()
                        .fill(EllipticalGradient(colors: [theme.accent.opacity(0.20 + 0.05 * breath),
                                                          theme.accent.opacity(0.06), .clear],
                                                 center: UnitPoint(x: 0.5, y: -0.08),
                                                 startRadiusFraction: 0, endRadiusFraction: 0.85))
                    // A cooler second tone low on the opposite side, barely there.
                    Circle()
                        .fill(RadialGradient(colors: [theme.colors[theme.colors.count - 1].opacity(0.07), .clear],
                                             center: .center, startRadius: 0, endRadius: reach * 0.45))
                        .frame(width: reach * 0.9, height: reach * 0.9)
                        .position(x: size.width * 0.85, y: size.height * 1.02)
                    DotGrid(spacing: 22)
                        .mask(RadialGradient(colors: [.white, .white.opacity(0.35), .clear],
                                             center: UnitPoint(x: 0.5, y: 0.22), startRadius: 0, endRadius: reach * 0.62))
                        .opacity(0.9)
                    // A hairline of light where the glow meets the dark.
                    LinearGradient(colors: [.clear, theme.accent.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 1)
                        .frame(width: size.width * 0.7)
                        .blur(radius: 0.5)
                        .position(x: size.width * 0.5, y: 0.5)
                }
            }
        }
        .background(Ink.void)
        .overlay(Grain().opacity(0.02))
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The lock screen's wallpaper: slow clouds of the theme's colours drifting over a faint dot grid, the beating
/// Pulshade mark in the middle and a hint to slide right. Everything on it moves by itself.
struct LockWallpaper: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Taps on the hint, for a Mac or VoiceOver where sliding is awkward.
    var onOpen: () -> Void = {}

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height, reach = max(w, h)
                ZStack {
                    Ink.void
                    ForEach(0..<4, id: \.self) { i in
                        let k = Double(i)
                        Circle()
                            .fill(RadialGradient(colors: [theme.colors[i % theme.colors.count].opacity(0.34 + 0.06 * sin(t * 0.3 + k)), .clear],
                                                 center: .center, startRadius: 0, endRadius: reach * 0.5))
                            .frame(width: reach, height: reach)
                            .position(x: w * (0.5 + 0.40 * sin(t * 0.11 + k * 1.7)), y: h * (0.5 + 0.36 * cos(t * 0.09 + k * 2.3)))
                    }
                    DotGrid(spacing: 22)
                        .mask(RadialGradient(colors: [.white, .white.opacity(0.3), .clear], center: .center,
                                             startRadius: 0, endRadius: reach * 0.6))
                        .opacity(0.8)
                    VStack(spacing: 18) {
                        PulseMark(size: 110, animated: !reduceMotion)
                        Text("Pulshade")
                            .font(.system(size: 30, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(Ink.text)
                    }
                    .position(x: w / 2, y: h * 0.42)
                    hint(t: t).position(x: w / 2, y: h - 72)
                }
            }
        }
        .ignoresSafeArea()
        .overlay(Grain().opacity(0.02).allowsHitTesting(false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pulshade is locked")
        .accessibilityHint("Slide left to enter your passcode")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
    }

    /// "Slide to unlock" with a ripple of light running along its arrows.
    private func hint(t: Double) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Text("Slide to unlock")
                    .font(.system(size: 15, weight: .medium))
                HStack(spacing: -2) {
                    ForEach(0..<3, id: \.self) { i in
                        let glow = 0.35 + 0.65 * max(0, sin(t * 3 - Double(2 - i) * 0.7))
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .opacity(glow)
                    }
                }
            }
            .foregroundStyle(Ink.dim)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Ink.raised.opacity(0.6), in: .capsule)
            .overlay(Capsule().strokeBorder(Ink.line))
        }
        .buttonStyle(.plain)
    }
}

/// A grid of very faint dots, like graph paper in the dark.
struct DotGrid: View {
    var spacing: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let dot: CGFloat = 1.2
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                             with: .color(Ink.text.opacity(0.1)))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

/// Fine static noise that stops gradients looking flat.
struct Grain: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 7)
            for _ in 0..<Int(size.width * size.height / 90) {
                let p = CGPoint(x: rng.next() * size.width, y: rng.next() * size.height)
                ctx.fill(Path(CGRect(origin: p, size: CGSize(width: 1, height: 1))),
                         with: .color(.white.opacity(rng.next())))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Deterministic abstract art drawn from a fingerprint: no two identities look alike.
struct GenerativeArt: View {
    let seed: String

    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: UInt64(truncatingIfNeeded: seed.stableHash))
            let hue = rng.next()
            let c1 = Color(hue: hue, saturation: 0.75, brightness: 0.95)
            let c2 = Color(hue: (hue + 0.18 + rng.next() * 0.2).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.7)
            let c3 = Color(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 1)
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [c1, c2]),
                                                       startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            for i in 0..<5 {
                let r = size.width * (0.18 + rng.next() * 0.45)
                let center = CGPoint(x: rng.next() * size.width, y: rng.next() * size.height)
                let shape = CGRect(x: center.x - r / 2, y: center.y - r / 2, width: r, height: r)
                ctx.opacity = 0.25 + rng.next() * 0.45
                let color = [c1, c2, c3, .white, .black][i % 5]
                if rng.next() > 0.5 {
                    ctx.fill(Path(ellipseIn: shape), with: .color(color))
                } else {
                    var path = Path()
                    path.addArc(center: center, radius: r / 2, startAngle: .degrees(rng.next() * 360),
                                endAngle: .degrees(rng.next() * 360 + 120), clockwise: false)
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: size.width * 0.07, lineCap: .round))
                }
            }
        }
    }
}

/// A profile picture if there is one. Otherwise the PULSHADE heartbeat (or a group's or channel's symbol) in the
/// owner's signature colour on a quiet disc, so a default picture looks like part of the app, not a placeholder.
struct Avatar: View {
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.theme) private var theme
    var image: Data?
    var seed: String
    var size: CGFloat = 44
    var symbol: String?
    /// Whether a story nobody here has watched yet makes the picture glow and tapping it open the story. Off where
    /// a tap means something else (the story viewer itself, a banner, a call, a list you pick from), and where the
    /// caller draws its own ring.
    var showsStory = true

    var body: some View {
        let reel = showsStory ? model?.unwatchedReel(of: seed) : nil
        ZStack {
            if let image, let ns = DecodedImages.image(image) {
                Image(platformImage: ns).resizable().scaledToFill()
            } else {
                PulseArt(tint: Signature.tint(for: seed, model: model), size: size, symbol: symbol)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Ink.line))
        .overlay {
            if reel != nil {
                Circle().strokeBorder(theme.accent, lineWidth: max(1.5, size * 0.045))
                    .padding(-size * 0.07)
                    .shadow(color: theme.accent.opacity(0.85), radius: max(3, size * 0.1))
                    .allowsHitTesting(false)
            }
        }
        .modifier(OpensStory(reel: reel, model: model))
    }
}

/// Makes a picture open its owner's story when tapped. Without one it adds nothing, so the picture's usual tap
/// (or the row it sits in) still works.
private struct OpensStory: ViewModifier {
    var reel: StoryReel?
    var model: AppModel?

    func body(content: Content) -> some View {
        if let reel, let model {
            content
                .contentShape(Circle())
                .onTapGesture { Haptics.tick(); model.storyToOpen = reel }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens their story")
        } else {
            content
        }
    }
}

/// The default picture itself: a disc washed in `tint`, lit softly from above, with the heartbeat or a symbol.
struct PulseArt: View {
    var tint: Color
    var size: CGFloat
    var symbol: String?

    var body: some View {
        ZStack {
            Ink.raised
            tint.opacity(Ink.scheme == .light ? 0.12 : 0.10)
            RadialGradient(colors: [tint.opacity(0.28), .clear], center: UnitPoint(x: 0.5, y: -0.1),
                           startRadius: 0, endRadius: size * 0.85)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(tint)
            } else {
                PulseLine()
                    .stroke(tint, style: StrokeStyle(lineWidth: max(1.2, size * 0.055), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.6, height: size * 0.4)
            }
        }
    }
}

extension Signature {
    /// Whose colour a picture's seed stands for: your own chosen colour for your own fingerprint, a contact's chosen
    /// one, or one picked from the seed. Darkened a little on the light theme, where the brightest ones would wash out.
    @MainActor static func tint(for seed: String, model: AppModel?) -> Color {
        let color: Color
        if let model {
            color = seed == model.fingerprint ? model.signature("me") : model.signature(seed)
        } else {
            color = Signature.color(nil, seed: seed)
        }
        return Ink.scheme == .light ? color.mix(with: .black, by: 0.3) : color
    }
}

/// Spinning gradient ring around an avatar that has a story waiting.
struct StoryRing<Content: View>: View {
    @Environment(\.theme) private var theme
    var active: Bool
    var size: CGFloat
    /// 0...1 while the story is still going out: an arc fills slowly round the picture. Nil when it isn't.
    var uploading: Double?
    /// Nobody has viewed it yet: the ring glows.
    var glow = false
    @ViewBuilder var content: Content
    @State private var spin = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            if let uploading {
                Circle().strokeBorder(Ink.line, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(uploading, 0.06))
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .padding(1.25)
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: uploading)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: spin)
            } else {
                Circle()
                    .strokeBorder(active ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Ink.line), lineWidth: glow ? 2.5 : 2)
                    .shadow(color: theme.accent.opacity(glow ? (pulse ? 0.95 : 0.45) : 0), radius: glow ? (pulse ? 9 : 4) : 0)
                    .shadow(color: theme.accent.opacity(glow ? 0.5 : 0), radius: glow ? 3 : 0)
            }
            content.padding(4)
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.4), value: uploading == nil)
        .onAppear { spin = true }
        .task(id: glow) {
            guard glow else { pulse = false; return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// The Pulshade mark, the same as the app icon: a speech bubble with a heartbeat cut through it.
/// Animated, the beat traces across like a heart monitor and the bubble thumps as the spike passes.
struct PulseMark: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = 120
    var animated = false

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                mark(phase: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6)
            }
        } else {
            mark(phase: nil)
        }
    }

    /// `phase` runs 0...1 once per beat: the trace draws in, the spike thumps, then the trace fades from the start.
    private func mark(phase: Double?) -> some View {
        let line = size * 0.087
        let head = phase.map { min(1, $0 / 0.5) } ?? 1
        let tail = phase.map { max(0, ($0 - 0.55) / 0.4) } ?? 0
        // The spike sits a little before the middle of the beat's length.
        let thump = phase.map { exp(-pow(($0 - 0.22) / 0.045, 2)) } ?? 0
        let ripple = phase.map { max(0, min(1, ($0 - 0.2) / 0.55)) } ?? 0
        return ZStack {
            if phase != nil {
                Circle()
                    .fill(RadialGradient(colors: [theme.accent.opacity(0.22 + 0.25 * thump), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.85))
                    .frame(width: size * 1.7, height: size * 1.7)
                Circle()
                    .strokeBorder(theme.accent.opacity(0.55 * (1 - ripple)), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(1 + ripple * 0.55)
                    .opacity(ripple > 0 ? 1 : 0)
            }
            ZStack {
                MarkBubble().fill(theme.gradient)
                if phase != nil {
                    // A faint resting line so the mark always reads, with the live trace on top.
                    PulseLine()
                        .stroke(Ink.mark.opacity(0.22), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                        .frame(width: size * 0.667, height: size * 0.45)
                }
                PulseLine()
                    .trim(from: tail, to: head)
                    .stroke(Ink.mark, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.667, height: size * 0.45)
            }
            .frame(width: size, height: size)
            .scaleEffect(1 + 0.045 * thump)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A round speech bubble with a short tail at the bottom left.
struct MarkBubble: Shape {
    func path(in r: CGRect) -> Path {
        var tail = Path()
        tail.move(to: CGPoint(x: r.minX + r.width * 0.10, y: r.minY + r.height * 0.64))
        tail.addLine(to: CGPoint(x: r.minX + r.width * 0.02, y: r.minY + r.height * 0.98))
        tail.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.minY + r.height * 0.92))
        tail.closeSubpath()
        return Path(ellipseIn: r).union(tail)
    }
}

/// A banner-wide heartbeat: a flat line with one beat at `at` (0...1 across), the beat as wide as it is tall.
struct WidePulseLine: Shape {
    var at: CGFloat

    func path(in rect: CGRect) -> Path {
        let beat = min(rect.height * 1.1, rect.width * 0.3)
        let start = rect.minX + (rect.width - beat) * at
        let mid = rect.midY
        let points: [(CGFloat, CGFloat)] = [(0.0, 0.5), (0.24, 0.06), (0.56, 0.94), (0.76, 0.5)]
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: mid))
        path.addLine(to: CGPoint(x: start, y: mid))
        for p in points { path.addLine(to: CGPoint(x: start + p.0 * beat, y: rect.minY + p.1 * rect.height)) }
        path.addLine(to: CGPoint(x: rect.maxX, y: mid))
        return path
    }
}

/// A single heartbeat: flat, one sharp spike, flat again.
struct PulseLine: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [(0, 0.5), (0.3, 0.5), (0.42, 0.06), (0.58, 0.94), (0.7, 0.5), (1, 0.5)]
        var path = Path()
        for (i, p) in points.enumerated() {
            let pt = CGPoint(x: rect.minX + p.0 * rect.width, y: rect.minY + p.1 * rect.height)
            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
        }
        return path
    }
}

/// PULSHADE in small, widely spaced capitals.
struct Wordmark: View {
    var size: CGFloat = 20
    var color: Color = Ink.text

    var body: some View {
        Text(verbatim: brandName)
            .font(.system(size: size, weight: .semibold))
            .tracking(size * 0.18)
            .foregroundStyle(color)
    }
}

/// A calm empty state: a soft icon and, optionally, one line.
struct Constellation: View {
    var symbol: String
    var text: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Ink.faint)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Ink.surface))
                .overlay(Circle().strokeBorder(Ink.line))
            if let text {
                Text(text).font(.system(size: 13)).foregroundStyle(Ink.faint)
            }
        }
        .frame(maxWidth: 300)
    }
}

// MARK: - Deterministic randomness for art

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
    }
}

extension String {
    var stableHash: Int {
        Int(truncatingIfNeeded: SHA256.hash(data: Data(utf8)).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    }
}
