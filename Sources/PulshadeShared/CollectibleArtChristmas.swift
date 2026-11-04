import SwiftUI

/// A Christmas tree standing in the snow: three tiers of frosted branches, strings of lights that twinkle in turn,
/// glossy baubles, presents at its foot and a gold star on top that glows and throws its rays, with snow drifting
/// down all round, then round again every 8 seconds at the display's full frame rate. Every motion is a whole number
/// of turns per loop, so it joins up without a jump. Lit and still, with a little snow, when the system asks for
/// less motion.
public struct ChristmasTreeArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                ChristmasTreeFrame(time: 2.0)
            } else {
                TimelineView(.animation) { context in
                    ChristmasTreeFrame(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: ChristmasTreeFrame.loop))
                }
            }
        }
        .accessibilityLabel("Christmas Tree")
    }
}

/// The tree at `time` seconds into its loop.
struct ChristmasTreeFrame: View {
    static let loop = 8.0

    var time: Double

    /// One tier of branches: its tip, its base, and how far it reaches either side of the trunk at the base.
    private static let tiers: [(tip: Double, base: Double, reach: Double)] = [(55, 87, 33), (38, 71, 27), (22, 53, 20)]

    private static let lightColours: [Color] = [
        Color(red: 1, green: 0.28, blue: 0.30), Color(red: 1, green: 0.84, blue: 0.30), Color(red: 0.35, green: 0.62, blue: 1),
        Color(red: 1, green: 0.45, blue: 0.82), Color(red: 0.45, green: 1, blue: 0.55),
    ]

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s) }
            func dot(_ x: Double, _ y: Double, _ d: Double) -> Path { Path(ellipseIn: r(x - d / 2, y - d / 2, d, d)) }

            let t = time, turn = 2 * Double.pi / Self.loop
            let small = size.width < 40
            let boost = small ? 1.5 : 1.0

            let green = Color(red: 0.13, green: 0.52, blue: 0.27), deepGreen = Color(red: 0.04, green: 0.22, blue: 0.14)
            let leaf = green.mix(with: Color(red: 0.55, green: 0.95, blue: 0.5), by: 0.35)
            let gold = Color(red: 1, green: 0.82, blue: 0.30), deepGold = Color(red: 0.66, green: 0.42, blue: 0.06)
            let ink = Color(red: 0.02, green: 0.10, blue: 0.07)

            // The pulse of the star, once every two seconds.
            let beat = 0.5 + 0.5 * sin(t * turn * 4)

            // Warm light from the tree on the night around it, and the snow it stands in.
            ctx.fill(Path(ellipseIn: r(-4, 6, 108, 104)), with: .radialGradient(
                Gradient(colors: [Color(red: 1, green: 0.8, blue: 0.4).opacity(0.20 + 0.06 * beat), Color(red: 0.2, green: 0.7, blue: 0.5).opacity(0.10), .clear]),
                center: p(50, 54), startRadius: 0, endRadius: 54 * s))
            let drift = Path(ellipseIn: r(2, 85, 96, 22))
            ctx.fill(drift, with: .linearGradient(Gradient(colors: [Color(red: 0.96, green: 0.98, blue: 1), Color(red: 0.62, green: 0.70, blue: 0.86)]), startPoint: p(50, 85), endPoint: p(50, 105)))
            ctx.fill(Path(ellipseIn: r(18, 88, 64, 8)), with: .color(.black.opacity(0.18)))

            // The trunk.
            ctx.fill(Path(roundedRect: r(44.5, 82, 11, 9), cornerRadius: 1 * s), with: .linearGradient(
                Gradient(colors: [Color(red: 0.55, green: 0.34, blue: 0.16), Color(red: 0.26, green: 0.14, blue: 0.06)]), startPoint: p(44, 82), endPoint: p(56, 82)))

            // Each tier is a tent of branches with a scalloped hem: lit on the left, shaded on the right, laid in rows of
            // fronds and edged in snow. The upper tiers go on last, over the hem of the one below.
            func halfWidth(_ tier: (tip: Double, base: Double, reach: Double), _ y: Double) -> Double { tier.reach * (y - tier.tip) / (tier.base - tier.tip) }
            func hem(_ tier: (tip: Double, base: Double, reach: Double)) -> Path {
                var path = Path()
                let n = 5
                path.move(to: p(50 + tier.reach, tier.base))
                for i in 0..<n {
                    let from = 50 + tier.reach - 2 * tier.reach * Double(i) / Double(n)
                    let to = 50 + tier.reach - 2 * tier.reach * Double(i + 1) / Double(n)
                    path.addQuadCurve(to: p(to, tier.base), control: p((from + to) / 2, tier.base + 7))
                }
                return path
            }
            for tier in Self.tiers {
                var shape = hem(tier)
                shape.addLine(to: p(50, tier.tip))
                shape.closeSubpath()
                ctx.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(0.45), radius: 2 * s, y: 1.6 * s))
                    layer.fill(shape, with: .color(ink))
                }
                ctx.fill(shape, with: .linearGradient(Gradient(stops: [
                    .init(color: leaf, location: 0), .init(color: green, location: 0.45), .init(color: deepGreen, location: 1),
                ]), startPoint: p(50 - tier.reach, tier.base), endPoint: p(50 + tier.reach, tier.base - 6)))
                ctx.drawLayer { layer in
                    layer.clip(to: shape)
                    // The right-hand side turned from the light.
                    var shadow = Path()
                    shadow.addLines([p(50, tier.tip), p(50 + tier.reach + 2, tier.base + 4), p(50, tier.base + 4)])
                    layer.fill(shadow, with: .color(.black.opacity(0.20)))
                    // Rows of fronds, each a downturned chevron, a dark line and a light one beside it.
                    for row in 1...4 {
                        let y = tier.tip + (tier.base - tier.tip) * Double(row) / 4.4
                        let w = halfWidth(tier, y)
                        var chevron = Path()
                        chevron.move(to: p(50 - w, y + 3.4))
                        chevron.addQuadCurve(to: p(50, y - 1.8), control: p(50 - w * 0.5, y + 1.6))
                        chevron.addQuadCurve(to: p(50 + w, y + 3.4), control: p(50 + w * 0.5, y + 1.6))
                        layer.stroke(chevron, with: .color(.black.opacity(0.30)), style: StrokeStyle(lineWidth: 1.0 * s, lineCap: .round))
                        layer.stroke(chevron.offsetBy(dx: 0, dy: -1.3 * s), with: .color(leaf.opacity(0.35)), style: StrokeStyle(lineWidth: 0.7 * s, lineCap: .round))
                    }
                }
                ctx.stroke(shape, with: .color(ink), style: StrokeStyle(lineWidth: 1.2 * s, lineJoin: .round))
                // Snow along the hem and a little on the shoulders.
                ctx.stroke(hem(tier), with: .color(.white.opacity(0.92)), style: StrokeStyle(lineWidth: 1.7 * s, lineCap: .round, lineJoin: .round))
                ctx.stroke(hem(tier).offsetBy(dx: 0, dy: -1.3 * s), with: .color(.white.opacity(0.38)), style: StrokeStyle(lineWidth: 0.8 * s, lineCap: .round))
            }

            // Strings of gold garland looping across each tier, and the lights hung along them, each twinkling at its own
            // pace (whole turns per loop) and in its own colour.
            ctx.drawLayer { strings in
                for (index, tier) in Self.tiers.enumerated() {
                    let y0 = tier.tip + (tier.base - tier.tip) * 0.46, sag = 5.5 + Double(index)
                    let w = halfWidth(tier, y0) - 1.5
                    var garland = Path()
                    garland.move(to: p(50 - w, y0))
                    garland.addQuadCurve(to: p(50 + w, y0), control: p(50, y0 + 2 * sag))
                    strings.stroke(garland, with: .color(deepGold.opacity(0.9)), style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round))
                    strings.stroke(garland, with: .color(gold.opacity(0.9)), style: StrokeStyle(lineWidth: 0.9 * s, lineCap: .round))
                }
            }
            ctx.drawLayer { glow in
                glow.blendMode = .plusLighter
                for (index, tier) in Self.tiers.enumerated() {
                    let y0 = tier.tip + (tier.base - tier.tip) * 0.46, sag = 5.5 + Double(index)
                    let w = halfWidth(tier, y0) - 1.5
                    let count = [8, 6, 4][index]
                    for i in 0..<count {
                        let u = (Double(i) + 0.5) / Double(count)
                        let x = 50 - w + 2 * w * u, y = y0 + 4 * sag * u * (1 - u) + 0.8
                        let id = index * 8 + i
                        let colour = Self.lightColours[(id + index) % Self.lightColours.count]
                        let level = 0.55 + 0.45 * sin(t * turn * Double(2 + id % 3) + Double(id) * 1.9)
                        glow.fill(dot(x, y, 8.5 * boost), with: .radialGradient(
                            Gradient(colors: [colour.opacity(0.55 * level), .clear]), center: p(x, y), startRadius: 0, endRadius: 4.3 * s * boost))
                        glow.fill(dot(x, y, 2.5 * boost), with: .color(colour.mix(with: .white, by: 0.35 * level).opacity(0.55 + 0.45 * level)))
                    }
                }
            }

            // Baubles, glossy, each with its cap and loop.
            let baubles: [(x: Double, y: Double, d: Double, colour: Color)] = [
                (41, 79, 6.6, Color(red: 0.88, green: 0.12, blue: 0.20)), (60, 82, 6, Color(red: 0.25, green: 0.50, blue: 0.95)),
                (28, 76, 5.4, gold), (73, 77, 5.6, Color(red: 0.88, green: 0.12, blue: 0.20)),
                (35, 61, 5.6, Color(red: 0.25, green: 0.50, blue: 0.95)), (57, 63, 6.2, gold), (66, 59, 4.8, Color(red: 0.88, green: 0.12, blue: 0.20)),
                (47, 47, 5.2, Color(red: 0.88, green: 0.12, blue: 0.20)), (56, 43, 4.6, Color(red: 0.25, green: 0.50, blue: 0.95)),
                (47, 32, 4.4, gold), (53, 29, 3.8, Color(red: 0.88, green: 0.12, blue: 0.20)),
            ]
            for (index, b) in baubles.enumerated() {
                let d = b.d * (small ? 1.25 : 1)
                var loop = Path()
                loop.move(to: p(b.x, b.y - d / 2 - 2.2))
                loop.addLine(to: p(b.x, b.y - d / 2 + 0.4))
                ctx.stroke(loop, with: .color(gold), lineWidth: 0.6 * s)
                ctx.fill(Path(roundedRect: r(b.x - 1.2, b.y - d / 2 - 1.4, 2.4, 1.8), cornerRadius: 0.5 * s), with: .color(gold))
                let ball = dot(b.x, b.y, d)
                ctx.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 0.9 * s, y: 0.8 * s))
                    layer.fill(ball, with: .radialGradient(
                        Gradient(colors: [b.colour.mix(with: .white, by: 0.55), b.colour, b.colour.mix(with: .black, by: 0.55)]),
                        center: p(b.x - d * 0.2, b.y - d * 0.22), startRadius: 0, endRadius: d * 0.72 * s))
                }
                ctx.fill(dot(b.x - d * 0.2, b.y - d * 0.22, d * 0.26), with: .color(.white.opacity(0.85)))
                let glint = ArtKit.twinkle(t, loop: Self.loop, times: 1, phase: Double(index) / Double(baubles.count))
                if glint > 0.05 && !small {
                    ctx.drawLayer { spark in
                        spark.blendMode = .plusLighter
                        spark.fill(ArtKit.glint(at: p(b.x - d * 0.2, b.y - d * 0.22), radius: (1 + 3.6 * glint) * s), with: .color(.white.opacity(0.9 * glint)))
                    }
                }
            }

            // The star: a halo that swells with the beat, long rays turning slowly behind it, and the star itself, faceted.
            let star = (x: 50.0, y: 17.0)
            ctx.drawLayer { halo in
                halo.blendMode = .plusLighter
                halo.fill(dot(star.x, star.y, 34 + 8 * beat), with: .radialGradient(
                    Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.6).opacity(0.65), Color(red: 1, green: 0.75, blue: 0.2).opacity(0.22), .clear]),
                    center: p(star.x, star.y), startRadius: 0, endRadius: (17 + 4 * beat) * s))
                let spin = t * turn
                for k in 0..<4 {
                    let angle = spin + Double(k) * .pi / 2
                    let reach = (k % 2 == 0 ? 19.0 : 12.0) * (0.85 + 0.15 * beat)
                    var ray = Path()
                    ray.move(to: p(star.x + cos(angle + 0.06) * 3, star.y + sin(angle + 0.06) * 3))
                    ray.addLine(to: p(star.x + cos(angle) * reach, star.y + sin(angle) * reach))
                    ray.addLine(to: p(star.x + cos(angle - 0.06) * 3, star.y + sin(angle - 0.06) * 3))
                    halo.fill(ray, with: .linearGradient(Gradient(colors: [.white.opacity(0.7), .clear]),
                                                         startPoint: p(star.x, star.y), endPoint: p(star.x + cos(angle) * reach, star.y + sin(angle) * reach)))
                }
            }
            let outer = ArtKit.star(at: p(star.x, star.y), outer: 8.6 * s, inner: 3.7 * s)
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: Color(red: 1, green: 0.8, blue: 0.2).opacity(0.9), radius: 2.4 * s))
                layer.fill(outer, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.97, blue: 0.7), gold, deepGold]), startPoint: p(44, 9), endPoint: p(56, 26)))
            }
            // Each point split into a bright and a dark half, so it reads as folded gold.
            for i in 0..<5 {
                let angle = Double(i) * 2 * .pi / 5 - .pi / 2
                var facet = Path()
                facet.move(to: p(star.x, star.y))
                facet.addLine(to: p(star.x + cos(angle) * 8.6, star.y + sin(angle) * 8.6))
                facet.addLine(to: p(star.x + cos(angle + .pi / 5) * 3.7, star.y + sin(angle + .pi / 5) * 3.7))
                facet.closeSubpath()
                ctx.fill(facet, with: .color(.black.opacity(0.20)))
            }
            ctx.stroke(outer, with: .color(deepGold.mix(with: .black, by: 0.35)), style: StrokeStyle(lineWidth: 0.9 * s, lineJoin: .round))

            // Presents at the foot of the tree, ribbons and bows.
            func present(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ wrap: Color, _ ribbon: Color) {
                let box = Path(roundedRect: r(x, y, w, h), cornerRadius: 0.8 * s)
                ctx.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 1.2 * s, y: 1 * s))
                    layer.fill(box, with: .color(ink))
                }
                ctx.fill(box, with: .linearGradient(Gradient(colors: [wrap.mix(with: .white, by: 0.25), wrap, wrap.mix(with: .black, by: 0.4)]), startPoint: p(x, y), endPoint: p(x + w, y + h)))
                ctx.fill(Path(r(x + w / 2 - 1.1, y, 2.2, h)), with: .color(ribbon))
                ctx.fill(Path(r(x, y + h * 0.36, w, 2.0)), with: .color(ribbon))
                ctx.fill(Path(r(x, y, w, 1.6)), with: .color(.white.opacity(0.28)))
                ctx.stroke(box, with: .color(ink.opacity(0.85)), lineWidth: 0.8 * s)
                for side in [-1.0, 1.0] {
                    var bow = Path()
                    bow.move(to: p(x + w / 2, y))
                    bow.addQuadCurve(to: p(x + w / 2 + side * 3.8, y - 2.8), control: p(x + w / 2 + side * 4.4, y + 0.4))
                    bow.addQuadCurve(to: p(x + w / 2, y), control: p(x + w / 2 + side * 1.0, y - 4.2))
                    ctx.fill(bow, with: .color(ribbon))
                    ctx.stroke(bow, with: .color(ink.opacity(0.6)), lineWidth: 0.5 * s)
                }
                ctx.fill(dot(x + w / 2, y - 0.2, 1.8), with: .color(ribbon.mix(with: .black, by: 0.2)))
            }
            present(13, 82, 17, 12, Color(red: 0.86, green: 0.14, blue: 0.22), gold)
            present(31, 86, 11, 8.5, Color(red: 0.22, green: 0.50, blue: 0.95), Color(red: 0.96, green: 0.96, blue: 1))
            present(65, 84, 14, 10, Color(red: 0.55, green: 0.30, blue: 0.85), gold)
            present(78, 88, 10, 7, Color(red: 0.14, green: 0.66, blue: 0.40), Color(red: 1, green: 0.5, blue: 0.5))

            // Snow drifting down in front of it all, swaying side to side; the flakes nearer the eye are bigger and quicker.
            ctx.drawLayer { snow in
                for i in 0..<(small ? 8 : 26) {
                    let near = ArtKit.noise(i, 61) > 0.55
                    let period = Self.loop / Double((near ? 3 : 2) + i % 2)
                    let k = (t + ArtKit.noise(i, 62) * period).truncatingRemainder(dividingBy: period) / period
                    let x = 2 + ArtKit.noise(i, 63) * 96 + sin(k * 2 * .pi * Double(1 + i % 3) + Double(i)) * 3.2
                    let y = -4 + k * 108
                    let d = (near ? 2.0 : 1.3) * (1 + ArtKit.noise(i, 64) * 0.5) * boost
                    let alpha = min(1, k * 10, (1 - k) * 10) * (near ? 0.95 : 0.65)
                    snow.fill(dot(x, y, d * 1.9), with: .color(.white.opacity(0.06 * alpha)))
                    snow.fill(dot(x, y, d), with: .color(.white.opacity(alpha)))
                }
            }
        }
    }
}
