import SwiftUI

/// A collectible's picture, drawn rather than shipped as an image so it stays sharp from beside a name up to
/// full size in the Collectibles tab.
public struct CollectibleIcon: View {
    var item: Collectible.Kind
    var size: CGFloat

    public init(item: Collectible.Kind, size: CGFloat) {
        self.item = item
        self.size = size
    }

    public var body: some View {
        switch item {
        case .partyHat: PartyHatArt().frame(width: size, height: size)
        case .pumpkin: PumpkinArt().frame(width: size, height: size)
        case .topHat: TopHatArt().frame(width: size, height: size)
        case .pulsePop: PulsePopArt().frame(width: size, height: size)
        case .bonfire: BonfireArt().frame(width: size, height: size)
        case .christmasTree: ChristmasTreeArt().frame(width: size, height: size)
        case .pulze: DragonStill(size: size)
        case .goldPulze: DragonStill(size: size, golden: true)
        case .guardian: GuardianArt().frame(width: size, height: size)
        }
    }
}

/// A party hat in glossy foil: five pleats, each with a lit and a shaded face, polka dots and a gold bead on its tip,
/// a star-studded band, a sheen sweeping over it and confetti tumbling down all round, then round again every 4
/// seconds at the display's full frame rate. Still, among a few pieces of confetti, when the system asks for less
/// motion.
public struct PartyHatArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                PartyHatFrame(time: 1.3)
            } else {
                TimelineView(.animation) { context in
                    PartyHatFrame(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: PartyHatFrame.loop))
                }
            }
        }
        .accessibilityLabel("Party Hat")
    }
}

/// The party hat at `time` seconds into its loop.
struct PartyHatFrame: View {
    static let loop = 4.0

    var time: Double
    var paper = Color(red: 0.90, green: 0.20, blue: 0.24)

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s) }
            func dot(_ x: Double, _ y: Double, _ d: Double) -> Path { Path(ellipseIn: r(x - d / 2, y - d / 2, d, d)) }

            let t = time
            let small = size.width < 40
            let boost = small ? 1.5 : 1.0

            let left = 10.0, width = 80.0, points = 5
            let step = width / Double(points)
            let peak = 13.0, valley = 41.0, fold = 70.0, bottom = 86.0
            // The band dips a little in the middle, as a crown seen from just above.
            func dip(_ x: Double) -> Double { let u = (x - 50) / 40; return 4 * (1 - u * u) }

            let light = paper.mix(with: .white, by: 0.32), shade = paper.mix(with: .black, by: 0.30)
            let band = paper.mix(with: .black, by: 0.45), edge = paper.mix(with: .black, by: 0.62)
            let gold = Color(red: 1, green: 0.82, blue: 0.30), deepGold = Color(red: 0.66, green: 0.42, blue: 0.06)

            // A pool of party light behind it, and the shadow it sits in.
            let pulse = 0.5 + 0.5 * sin(t / Self.loop * 2 * .pi * 2)
            ctx.fill(Path(ellipseIn: r(0, 6, 100, 96)), with: .radialGradient(
                Gradient(colors: [paper.opacity(0.30 + 0.08 * pulse), Color(red: 1, green: 0.78, blue: 0.3).opacity(0.10), .clear]),
                center: p(50, 52), startRadius: 0, endRadius: 52 * s))
            ctx.fill(Path(ellipseIn: r(14, 88, 72, 9)), with: .color(.black.opacity(0.32)))

            // Confetti: coloured scraps tumbling down on the breeze, turning edge-on as they fall. Half behind the hat,
            // half in front.
            let colours: [Color] = [
                Color(red: 1, green: 0.82, blue: 0.30), Color(red: 0.30, green: 0.85, blue: 0.95), Color(red: 1, green: 0.40, blue: 0.70),
                Color(red: 0.55, green: 0.95, blue: 0.45), Color(red: 0.62, green: 0.50, blue: 1), Color.white,
            ]
            func confetti(front: Bool) {
                for i in 0..<(small ? 10 : 28) where (i % 2 == 0) == front {
                    let period = Self.loop / Double(1 + i % 3)
                    let k = (t + ArtKit.noise(i, 21) * period).truncatingRemainder(dividingBy: period) / period
                    let x = 3 + ArtKit.noise(i, 22) * 94 + sin(k * 2 * .pi * Double(1 + i % 2) + Double(i)) * 4
                    let y = -6 + k * 112
                    let spin = k * 2 * .pi * Double(2 + i % 3) + Double(i)
                    let w = (2.4 + ArtKit.noise(i, 23) * 2.4) * boost
                    let edgeOn = max(0.14, abs(cos(spin)))
                    let alpha = min(1, k * 10, (1 - k) * 10)
                    let colour = colours[i % colours.count]
                    ctx.drawLayer { piece in
                        piece.translateBy(x: p(x, y).x, y: p(x, y).y)
                        piece.rotate(by: .radians(Double(i) * 1.3 + sin(spin) * 0.7))
                        let scrap = Path(roundedRect: CGRect(x: -w / 2 * s, y: -w * 0.3 * edgeOn * s, width: w * s, height: w * 0.6 * edgeOn * s), cornerRadius: 0.4 * s)
                        piece.fill(scrap, with: .color(colour.opacity(alpha)))
                        // The side that faces the light is brighter.
                        if cos(spin) > 0 { piece.fill(scrap, with: .color(.white.opacity(0.28 * alpha))) }
                    }
                }
            }
            confetti(front: false)

            func tipX(_ i: Int) -> Double { left + Double(i) * step + step / 2 }
            func tipY(_ x: Double) -> Double { peak + dip(x) * 0.3 }

            var outline = Path()
            outline.move(to: p(left, fold + dip(left)))
            for i in 0..<points {
                let v = left + Double(i) * step
                outline.addLine(to: p(v, valley + dip(v) * 0.5))
                outline.addLine(to: p(tipX(i), tipY(tipX(i))))
            }
            outline.addLine(to: p(left + width, valley + dip(left + width) * 0.5))
            outline.addLine(to: p(left + width, bottom + dip(left + width)))
            for x in stride(from: left + width, through: left, by: -2) { outline.addLine(to: p(x, bottom + dip(x))) }
            outline.closeSubpath()

            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 2.5 * s, y: 2 * s))
                layer.fill(outline, with: .color(edge))
            }

            for i in 0..<points {
                let v = left + Double(i) * step, tip = tipX(i), next = v + step
                var lit = Path()
                lit.addLines([p(v, valley + dip(v) * 0.5), p(tip, tipY(tip)), p(tip, fold + dip(tip)), p(v, fold + dip(v))])
                ctx.fill(lit, with: .linearGradient(Gradient(colors: [light, paper]), startPoint: p(v, peak), endPoint: p(tip, fold)))
                var dark = Path()
                dark.addLines([p(tip, tipY(tip)), p(next, valley + dip(next) * 0.5), p(next, fold + dip(next)), p(tip, fold + dip(tip))])
                ctx.fill(dark, with: .linearGradient(Gradient(colors: [paper, shade]), startPoint: p(tip, peak), endPoint: p(next, fold)))
                // Foil is glossy: a soft bright strip down each lit face, and a dark one hugging the fold.
                var gloss = Path()
                gloss.addLines([p(v + 1.5, valley + 3 + dip(v) * 0.5), p(tip - 2.5, tipY(tip) + 10), p(tip - 2.5, fold - 4 + dip(tip)), p(v + 1.5, fold - 4 + dip(v))])
                ctx.fill(gloss, with: .linearGradient(Gradient(colors: [.white.opacity(0.30), .clear]), startPoint: p(v, peak), endPoint: p(tip, fold)))
                var crease = Path()
                crease.move(to: p(tip, tipY(tip)))
                crease.addLine(to: p(tip, fold + dip(tip)))
                ctx.stroke(crease, with: .color(.white.opacity(0.32)), lineWidth: 0.9 * s)
                // Polka dots, gold on the lit face and paler on the shaded one.
                let dots: [(Double, Double, Color)] = [(v + step * 0.26, 56, gold), (v + step * 0.18, 64, gold.opacity(0.8)), (tip + step * 0.30, 52, light.opacity(0.9)), (tip + step * 0.2, 62, light.opacity(0.75))]
                for (x, y, colour) in dots { ctx.fill(dot(x, y + dip(x), 2.0), with: .color(colour)) }
            }

            var bandPath = Path()
            bandPath.move(to: p(left, fold + dip(left)))
            for x in stride(from: left, through: left + width, by: 2) { bandPath.addLine(to: p(x, fold + dip(x))) }
            for x in stride(from: left + width, through: left, by: -2) { bandPath.addLine(to: p(x, bottom + dip(x))) }
            bandPath.closeSubpath()
            ctx.fill(bandPath, with: .linearGradient(Gradient(colors: [band.mix(with: .white, by: 0.16), band]), startPoint: p(50, fold), endPoint: p(50, bottom)))
            // A thin gold ribbon along the band, and stars studded on it.
            var ribbon = Path()
            ribbon.move(to: p(left, 78 + dip(left)))
            for x in stride(from: left, through: left + width, by: 2) { ribbon.addLine(to: p(x, 78 + dip(x))) }
            ctx.stroke(ribbon, with: .linearGradient(Gradient(colors: [deepGold, gold, deepGold]), startPoint: p(left, 78), endPoint: p(left + width, 78)), lineWidth: 1.4 * s)
            for i in 0..<7 {
                let x = left + 6 + Double(i) * 11.2
                let y = (i % 2 == 0 ? 74.0 : 82.4) + dip(x)
                ctx.fill(ArtKit.star(at: p(x, y), outer: 2.1 * s, inner: 0.9 * s), with: .color(gold.opacity(0.75 + 0.25 * ArtKit.twinkle(t, loop: Self.loop, times: 2, phase: Double(i) / 7))))
            }
            var lip = Path()
            lip.move(to: p(left, fold + dip(left)))
            for x in stride(from: left, through: left + width, by: 2) { lip.addLine(to: p(x, fold + dip(x))) }
            ctx.stroke(lip, with: .color(light.opacity(0.85)), lineWidth: 1.3 * s)
            ctx.stroke(outline, with: .color(edge), style: StrokeStyle(lineWidth: 1.6 * s, lineJoin: .round))

            // The sheen: a bright diagonal band sweeping across the foil, clipped to the hat.
            let x = -30 + t / Self.loop * 160
            ctx.drawLayer { sheen in
                sheen.clip(to: outline)
                sheen.blendMode = .plusLighter
                var wide = Path()
                wide.addLines([p(x, 0), p(x + 18, 0), p(x - 2, 100), p(x - 20, 100)])
                sheen.fill(wide, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.30), .clear]), startPoint: p(x - 6, 50), endPoint: p(x + 14, 50)))
                var thin = Path()
                thin.addLines([p(x + 22, 0), p(x + 25, 0), p(x + 5, 100), p(x + 2, 100)])
                sheen.fill(thin, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.35), .clear]), startPoint: p(x + 8, 50), endPoint: p(x + 20, 50)))
            }

            // A gold bead on every tip, glinting in turn.
            for i in 0..<points {
                let x = tipX(i), y = tipY(x) - 0.5
                let ball = dot(x, y, 7.6)
                ctx.drawLayer { bead in
                    bead.addFilter(.shadow(color: .black.opacity(0.35), radius: 1.2 * s, y: 1 * s))
                    bead.fill(ball, with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.97, blue: 0.75), gold, deepGold]),
                                                          center: p(x - 1.2, y - 1.4), startRadius: 0, endRadius: 4.6 * s))
                }
                ctx.stroke(ball, with: .color(deepGold.mix(with: .black, by: 0.45)), lineWidth: 0.7 * s)
                let glint = ArtKit.twinkle(t, loop: Self.loop, times: 1, phase: Double(i) / Double(points))
                if glint > 0.02 {
                    ctx.drawLayer { spark in
                        spark.blendMode = .plusLighter
                        spark.fill(ArtKit.glint(at: p(x - 1, y - 1), radius: (3 + 7 * glint) * s * boost), with: .color(.white.opacity(0.4 + 0.6 * glint)))
                    }
                }
            }
            confetti(front: true)
        }
    }
}

/// A carved Halloween pumpkin with a candle burning inside: the flame flickers behind the grin and throws a wavering
/// glow over the ribs and the dark around it, spirits drift up off the top and a bat flits by, then round again every
/// 4 seconds at the display's full frame rate. A steady glow when the system asks for less motion.
public struct PumpkinArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                PumpkinFrame(time: 0.7, still: true)
            } else {
                TimelineView(.animation) { context in
                    PumpkinFrame(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: PumpkinFrame.loop))
                }
            }
        }
        .accessibilityLabel("Halloween Pumpkin")
    }
}

/// The pumpkin at `time` seconds into its loop.
struct PumpkinFrame: View {
    static let loop = 4.0

    var time: Double
    /// Holds the candle at an even glow, with nothing drifting about.
    var still = false

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s) }
            func dot(_ x: Double, _ y: Double, _ d: Double) -> Path { Path(ellipseIn: r(x - d / 2, y - d / 2, d, d)) }

            let t = time, turn = 2 * Double.pi / Self.loop
            let small = size.width < 40
            let boost = small ? 1.6 : 1.0

            // The candle: several quick waves of different speeds (whole turns per loop) that never quite line up.
            let flicker = still ? 0.9 : min(1.0, 0.84 + 0.07 * sin(t * turn * 3 + 0.4) + 0.05 * sin(t * turn * 7 + 1.3) + 0.04 * sin(t * turn * 13 + 2.2))

            let rind = Color(red: 0.96, green: 0.50, blue: 0.09)
            let light = rind.mix(with: .yellow, by: 0.32), shade = rind.mix(with: .black, by: 0.40)
            let edge = Color(red: 0.30, green: 0.11, blue: 0.02)
            let fire = Color(red: 1, green: 0.62, blue: 0.12), hot = Color(red: 1, green: 0.95, blue: 0.55)

            // The glow of the candle on the air around the pumpkin, and the shadow under it.
            ctx.fill(Path(ellipseIn: r(-4, 12, 108, 100)), with: .radialGradient(
                Gradient(colors: [fire.opacity(0.46 * flicker), Color(red: 1, green: 0.35, blue: 0.05).opacity(0.14 * flicker), .clear]),
                center: p(50, 64), startRadius: 0, endRadius: 56 * s))
            ctx.fill(Path(ellipseIn: r(12, 88, 76, 10)), with: .color(.black.opacity(0.4)))

            // Spirits: pale wisps that curl up off the pumpkin's top, swelling and fading as they rise.
            if !still {
                for i in 0..<(small ? 2 : 4) {
                    let period = Self.loop / Double(1 + i % 2)
                    let k = (t + ArtKit.noise(i, 31) * period).truncatingRemainder(dividingBy: period) / period
                    let x = 50 + (ArtKit.noise(i, 32) - 0.5) * 36 + sin(k * 2 * .pi * 2 + Double(i)) * 7 * k
                    let y = 26 - k * 20
                    let d = (6 + k * 9) * (small ? 1.3 : 1)
                    let a = 0.30 * sin(k * .pi)
                    ctx.fill(dot(x, y, d), with: .radialGradient(
                        Gradient(colors: [Color(red: 0.86, green: 0.82, blue: 1).opacity(a), Color(red: 0.62, green: 0.50, blue: 0.95).opacity(a * 0.45), .clear]),
                        center: p(x, y), startRadius: 0, endRadius: d / 2 * s))
                }
            }

            // Outer lobes first, the middle one last and brightest, so the ribs read as overlapping.
            let lobes: [(x: Double, w: Double, tone: Double)] = [(6, 40, 0.0), (54, 40, 0.0), (17, 40, 0.5), (43, 40, 0.5), (29, 42, 1.0)]
            var body = Path()
            for lobe in lobes { body.addEllipse(in: r(lobe.x, 28, lobe.w, 64)) }
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 2.5 * s, y: 2 * s))
                layer.fill(body, with: .color(edge))
            }
            for lobe in lobes {
                let shape = Path(ellipseIn: r(lobe.x, 28, lobe.w, 64))
                let top = shade.mix(with: light, by: lobe.tone)
                ctx.fill(shape, with: .radialGradient(Gradient(colors: [top, rind.mix(with: shade, by: 0.5 - lobe.tone * 0.4)]),
                                                      center: p(lobe.x + lobe.w * 0.4, 44), startRadius: 0, endRadius: 44 * s))
                // The rib: a bright rim on its upper left and a dark crease where it meets the next.
                ctx.stroke(shape, with: .linearGradient(Gradient(colors: [light.opacity(0.7), .clear]), startPoint: p(lobe.x, 30), endPoint: p(lobe.x + lobe.w * 0.7, 70)),
                           lineWidth: 1.3 * s)
                ctx.stroke(shape, with: .color(edge.opacity(0.6)), lineWidth: 0.9 * s)
            }
            // Candlelight spilling out of the face over the ribs near it, wavering with the flame, and the dark of the
            // underside.
            ctx.drawLayer { spill in
                spill.clip(to: body)
                spill.fill(Path(ellipseIn: r(0, 20, 100, 80)), with: .radialGradient(
                    Gradient(colors: [hot.opacity(0.46 * flicker), fire.opacity(0.22 * flicker), .clear]),
                    center: p(50, 64), startRadius: 0, endRadius: 40 * s))
                spill.fill(Path(r(0, 70, 100, 24)), with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.35)]), startPoint: p(50, 70), endPoint: p(50, 92)))
            }

            // The stem, leaning a little, and a curl of vine that sways.
            var stem = Path()
            stem.move(to: p(45, 31))
            stem.addQuadCurve(to: p(47, 12), control: p(44, 20))
            stem.addLine(to: p(56, 10))
            stem.addQuadCurve(to: p(55, 31), control: p(53, 20))
            stem.closeSubpath()
            ctx.fill(stem, with: .linearGradient(Gradient(colors: [Color(red: 0.50, green: 0.64, blue: 0.24), Color(red: 0.20, green: 0.28, blue: 0.08)]),
                                                 startPoint: p(45, 20), endPoint: p(56, 20)))
            ctx.stroke(stem, with: .color(edge), style: StrokeStyle(lineWidth: 1.4 * s, lineJoin: .round))
            var stemLight = Path()
            stemLight.move(to: p(47, 28))
            stemLight.addQuadCurve(to: p(49, 14), control: p(46, 20))
            ctx.stroke(stemLight, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 1.2 * s, lineCap: .round))
            let sway = still ? 0 : sin(t * turn * 2) * 1.2
            var vine = Path()
            vine.move(to: p(56, 22))
            vine.addCurve(to: p(70 + sway, 20), control1: p(60, 14), control2: p(70 + sway, 12))
            vine.addCurve(to: p(64 + sway * 0.6, 24), control1: p(70 + sway, 25), control2: p(65, 26))
            ctx.stroke(vine, with: .color(Color(red: 0.34, green: 0.48, blue: 0.14)), style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round))
            ctx.stroke(vine, with: .color(.white.opacity(0.16)), style: StrokeStyle(lineWidth: 0.6 * s, lineCap: .round))

            // The carved face with the candle burning behind it.
            var face = Path()
            face.addLines([p(27, 54), p(42, 54), p(34.5, 42)]); face.closeSubpath()
            face.addLines([p(58, 54), p(73, 54), p(65.5, 42)]); face.closeSubpath()
            face.addLines([p(46, 62), p(54, 62), p(50, 56)]); face.closeSubpath()
            face.move(to: p(24, 66))
            face.addLines([p(32, 70), p(36, 66), p(42, 72), p(50, 67), p(58, 72), p(64, 66), p(68, 70), p(76, 66)])
            face.addQuadCurve(to: p(24, 66), control: p(50, 96))
            face.closeSubpath()
            ctx.drawLayer { glow in
                glow.addFilter(.shadow(color: Color(red: 1, green: 0.8, blue: 0.25).opacity(0.85 * flicker), radius: (3 + 2.4 * flicker) * s))
                glow.fill(face, with: .radialGradient(Gradient(colors: [hot, fire, Color(red: 0.92, green: 0.40, blue: 0.06)]),
                                                     center: p(50, 66), startRadius: 0, endRadius: 30 * s))
            }
            // The flame itself, a teardrop leaning with the draught, seen through the holes.
            ctx.drawLayer { inside in
                inside.clip(to: face)
                let lean = still ? 0 : sin(t * turn * 5) * 3.2 + sin(t * turn * 9 + 1) * 1.4
                let h = 25.0 * flicker
                var flame = Path()
                flame.move(to: p(50, 84))
                flame.addQuadCurve(to: p(50 + lean, 84 - h), control: p(39, 80 - h * 0.35))
                flame.addQuadCurve(to: p(50, 84), control: p(61 + lean * 0.4, 80 - h * 0.35))
                flame.closeSubpath()
                inside.fill(flame, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.55, blue: 0.08), Color(red: 1, green: 0.97, blue: 0.78)]),
                                                         startPoint: p(50, 84 - h), endPoint: p(50, 84)))
                var core = Path()
                core.move(to: p(50, 84))
                core.addQuadCurve(to: p(50 + lean * 0.7, 84 - h * 0.55), control: p(45, 80 - h * 0.2))
                core.addQuadCurve(to: p(50, 84), control: p(55 + lean * 0.3, 80 - h * 0.2))
                core.closeSubpath()
                inside.fill(core, with: .color(.white.opacity(0.9)))
            }
            // The cut edges: a bright lip where the light catches them, then the dark rind.
            ctx.stroke(face, with: .color(Color(red: 0.55, green: 0.20, blue: 0.03).opacity(0.9)), style: StrokeStyle(lineWidth: 1.4 * s, lineJoin: .round))
            ctx.stroke(face, with: .color(.white.opacity(0.10 * flicker)), style: StrokeStyle(lineWidth: 0.5 * s, lineJoin: .round))

            guard !still else { return }
            // Motes of light lifting off the glow and drifting up past the stem.
            ctx.drawLayer { motes in
                motes.blendMode = .plusLighter
                for i in 0..<(small ? 3 : 8) {
                    let period = Self.loop / Double(1 + i % 3)
                    let k = (t + ArtKit.noise(i, 41) * period).truncatingRemainder(dividingBy: period) / period
                    let x = 50 + (ArtKit.noise(i, 42) - 0.5) * 46 + sin(k * 2 * .pi * 2 + Double(i)) * 3
                    let y = 52 - k * 42
                    let d = (1.3 + ArtKit.noise(i, 43) * 1.4) * boost
                    let a = sin(k * .pi)
                    motes.fill(dot(x, y, d * 2.6), with: .color(fire.opacity(0.18 * a)))
                    motes.fill(dot(x, y, d), with: .color(hot.opacity(0.9 * a)))
                }
            }
            // A bat flits across the dark above, wings beating; a smaller one the other way, lower down.
            if !small {
                func bat(_ x: Double, _ y: Double, _ scale: Double, _ flap: Double) {
                    var wings = Path()
                    for side in [-1.0, 1.0] {
                        wings.move(to: p(x, y))
                        wings.addQuadCurve(to: p(x + side * 9 * scale, y - 5 * scale * flap), control: p(x + side * 4 * scale, y - 6 * scale - 2 * scale * flap))
                        wings.addQuadCurve(to: p(x + side * 6.4 * scale, y + 1.6 * scale), control: p(x + side * 7.4 * scale, y - 1 * scale * flap))
                        wings.addQuadCurve(to: p(x + side * 3.4 * scale, y + 1.2 * scale), control: p(x + side * 4.8 * scale, y + 3.2 * scale))
                        wings.addLine(to: p(x, y + 2.4 * scale))
                        wings.closeSubpath()
                    }
                    let ink = Color(red: 0.07, green: 0.03, blue: 0.11)
                    ctx.fill(wings, with: .color(ink))
                    ctx.fill(Path(ellipseIn: r(x - 1.5 * scale, y - 2 * scale, 3 * scale, 5 * scale)), with: .color(ink))
                    for side in [-1.0, 1.0] { ctx.fill(dot(x + side * 0.9 * scale, y - 2.6 * scale, 1.5 * scale), with: .color(ink)) }
                    for side in [-1.0, 1.0] { ctx.fill(dot(x + side * 0.8 * scale, y - 1.2 * scale, 0.7 * scale), with: .color(Color(red: 1, green: 0.4, blue: 0.2))) }
                }
                let a = t / Self.loop
                bat(-14 + a * 128, 9 + sin(a * 2 * .pi * 2) * 3.5, 1.0, sin(t * turn * 18))
                let b = (a + 0.5).truncatingRemainder(dividingBy: 1)
                bat(114 - b * 128, 20 + cos(b * 2 * .pi * 3) * 3, 0.72, sin(t * turn * 22 + 1))
            }
        }
    }
}

/// A top hat in satin whose colour runs round the rainbow, a full turn every two seconds, wearing a ribbon in the
/// opposite colour and a gold buckle, glinting as it turns and shedding stars. Still, in one colour, when the system
/// asks for less motion.
public struct TopHatArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                TopHatShape(time: 1.56)
            } else {
                TimelineView(.animation) { context in
                    TopHatShape(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: TopHatShape.loop))
                }
            }
        }
        .accessibilityLabel("Top Hat")
    }
}

/// The top hat at `time` seconds into its two-second loop, which is also the hue's one turn round.
struct TopHatShape: View {
    static let loop = 2.0

    var time: Double

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s) }
            func dot(_ x: Double, _ y: Double, _ d: Double) -> Path { Path(ellipseIn: r(x - d / 2, y - d / 2, d, d)) }

            let t = time, turn = 2 * Double.pi / Self.loop
            let hue = t / Self.loop
            let small = size.width < 40
            let boost = small ? 1.6 : 1.0

            func tone(_ shift: Double, _ saturation: Double, _ brightness: Double) -> Color {
                Color(hue: (hue + shift).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness)
            }
            let felt = tone(0, 0.88, 0.90), light = tone(0, 0.50, 1), shade = tone(0, 0.96, 0.46), deep = tone(0, 0.95, 0.26)
            let edge = tone(0, 0.9, 0.18)
            let ribbon = tone(0.5, 0.85, 0.55), ribbonLight = tone(0.5, 0.6, 0.85)
            let gold = Color(red: 1, green: 0.82, blue: 0.30), deepGold = Color(red: 0.66, green: 0.42, blue: 0.06)

            // The light it gives off, in its own colour, and the shadow it sits in.
            ctx.fill(Path(ellipseIn: r(-2, 4, 104, 100)), with: .radialGradient(
                Gradient(colors: [tone(0, 0.8, 1).opacity(0.34), tone(0.08, 0.8, 1).opacity(0.10), .clear]),
                center: p(50, 56), startRadius: 0, endRadius: 54 * s))
            ctx.fill(Path(ellipseIn: r(10, 82, 80, 12)), with: .color(.black.opacity(0.38)))

            // Stars it sheds, lifting off in its colours and fading as they climb.
            func stars(front: Bool) {
                for i in 0..<(small ? 4 : 10) where (i % 2 == 0) == front {
                    let period = Self.loop / Double(1 + i % 2)
                    let k = (t + ArtKit.noise(i, 51) * period).truncatingRemainder(dividingBy: period) / period
                    let x = 50 + (ArtKit.noise(i, 52) - 0.5) * 92 + sin(k * 2 * .pi + Double(i)) * 2
                    let y = 76 - k * (50 + ArtKit.noise(i, 53) * 30)
                    let d = (1.6 + ArtKit.noise(i, 54) * 1.6) * (1 - k * 0.4) * boost
                    ctx.drawLayer { layer in
                        layer.blendMode = .plusLighter
                        layer.fill(ArtKit.star(at: p(x, y), outer: d * 1.8 * s, inner: d * 0.7 * s, points: 4, rotation: k * 3 + Double(i)),
                                   with: .color(tone(Double(i) * 0.09, 0.45, 1).opacity(1 - k * k)))
                    }
                }
            }
            stars(front: false)

            // The brim, an ellipse seen from just above with its underside showing, then the crown rising out of it.
            let brimTop = Path(ellipseIn: r(6, 66, 88, 22)), brimUnder = Path(ellipseIn: r(6, 69, 88, 22))
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 2.5 * s, y: 2 * s))
                layer.fill(brimUnder, with: .color(edge))
                layer.fill(brimTop, with: .color(edge))
            }
            ctx.fill(brimUnder, with: .linearGradient(Gradient(colors: [shade, deep]), startPoint: p(50, 69), endPoint: p(50, 91)))
            ctx.fill(brimTop, with: .linearGradient(Gradient(stops: [
                .init(color: light, location: 0), .init(color: felt, location: 0.35), .init(color: shade, location: 0.8), .init(color: deep, location: 1),
            ]), startPoint: p(6, 66), endPoint: p(94, 90)))
            // The brim curls up at the edge, catching the light along it.
            ctx.stroke(brimTop, with: .linearGradient(Gradient(colors: [.white.opacity(0.55), .clear, .black.opacity(0.4)]), startPoint: p(10, 66), endPoint: p(90, 90)), lineWidth: 1.6 * s)
            ctx.stroke(brimTop, with: .color(edge), lineWidth: 1.2 * s)
            // The crown's shadow on the brim round it.
            ctx.fill(Path(ellipseIn: r(26, 70, 48, 10)), with: .color(.black.opacity(0.32)))

            var crown = Path()
            crown.move(to: p(27, 18))
            crown.addLine(to: p(73, 18))
            crown.addLine(to: p(69, 74))
            crown.addQuadCurve(to: p(31, 74), control: p(50, 81))
            crown.closeSubpath()
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 2 * s, y: 1.5 * s))
                layer.fill(crown, with: .color(edge))
            }
            // Round like a cylinder: bright left of centre, falling away to the right.
            ctx.fill(crown, with: .linearGradient(Gradient(stops: [
                .init(color: shade, location: 0), .init(color: felt, location: 0.22), .init(color: light, location: 0.36),
                .init(color: felt, location: 0.52), .init(color: shade, location: 0.85), .init(color: deep, location: 1),
            ]), startPoint: p(27, 40), endPoint: p(73, 40)))

            // The ribbon round the crown, in the opposite colour, with a gold buckle at the front.
            var band = Path()
            band.move(to: p(30.1, 58))
            band.addLine(to: p(69.9, 58))
            band.addLine(to: p(69, 74))
            band.addQuadCurve(to: p(31, 74), control: p(50, 81))
            band.closeSubpath()
            ctx.fill(band, with: .linearGradient(Gradient(stops: [
                .init(color: ribbon.mix(with: .black, by: 0.3), location: 0), .init(color: ribbonLight, location: 0.34),
                .init(color: ribbon, location: 0.55), .init(color: ribbon.mix(with: .black, by: 0.45), location: 1),
            ]), startPoint: p(30, 66), endPoint: p(70, 66)))
            ctx.stroke(band, with: .color(.black.opacity(0.35)), lineWidth: 0.7 * s)
            let buckle = Path(roundedRect: r(42.5, 59.5, 15, 14.5), cornerRadius: 2.2 * s)
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 0.9 * s, y: 0.8 * s))
                layer.fill(buckle, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.62), gold, deepGold]), startPoint: p(42, 59), endPoint: p(58, 75)))
            }
            ctx.stroke(buckle, with: .color(deepGold.mix(with: .black, by: 0.4)), lineWidth: 0.8 * s)
            let hole = Path(roundedRect: r(46, 62.5, 8, 8.5), cornerRadius: 1.2 * s)
            ctx.fill(hole, with: .color(ribbon.mix(with: .black, by: 0.2)))
            ctx.stroke(hole, with: .color(deepGold.mix(with: .black, by: 0.3)), lineWidth: 0.6 * s)

            // A sheen down the crown that drifts a little side to side as the hat turns, and a soft one on the far side.
            let drift = sin(t * turn) * 1.6
            var sheen = Path()
            sheen.move(to: p(33 + drift, 21))
            sheen.addLine(to: p(39 + drift, 21))
            sheen.addLine(to: p(38 + drift * 0.6, 54))
            sheen.addLine(to: p(33.5 + drift * 0.6, 54))
            sheen.closeSubpath()
            ctx.fill(sheen, with: .linearGradient(Gradient(colors: [.white.opacity(0.46), .white.opacity(0.08)]), startPoint: p(36, 21), endPoint: p(36, 54)))
            var rim = Path()
            rim.move(to: p(68.4, 22)); rim.addLine(to: p(70.4, 22)); rim.addLine(to: p(67.4, 54)); rim.addLine(to: p(65.8, 54)); rim.closeSubpath()
            ctx.fill(rim, with: .color(.white.opacity(0.14)))
            ctx.stroke(crown, with: .color(edge), style: StrokeStyle(lineWidth: 1.5 * s, lineJoin: .round))

            let top = Path(ellipseIn: r(27, 13, 46, 10))
            ctx.fill(top, with: .linearGradient(Gradient(colors: [light, felt, shade]), startPoint: p(27, 13), endPoint: p(73, 23)))
            ctx.stroke(top, with: .color(edge), lineWidth: 1.5 * s)
            ctx.stroke(Path(ellipseIn: r(29.5, 14.2, 41, 7.6)), with: .color(.white.opacity(0.22)), lineWidth: 0.6 * s)

            // Glints off the satin and the buckle, flashing in turn.
            ctx.drawLayer { glints in
                glints.blendMode = .plusLighter
                let spots: [(Double, Double, Double, Double)] = [(36, 30, 6.5, 0.0), (68, 18, 5, 0.34), (50, 66.5, 6, 0.66), (12, 74, 5, 0.5), (88, 76, 4.5, 0.17)]
                for (x, y, radius, phase) in spots {
                    let g = ArtKit.twinkle(t, loop: Self.loop, times: 1, phase: phase)
                    guard g > 0.02 else { continue }
                    glints.fill(ArtKit.glint(at: p(x, y), radius: radius * (0.4 + 0.6 * g) * s * boost), with: .color(.white.opacity(0.35 + 0.65 * g)))
                }
            }
            stars(front: true)
        }
    }
}

/// A can of Pulse Pop that pops itself open: the ring-pull snaps up, the can jolts, fizz sprays out and bubbles rise,
/// then it starts again, every 3.2 seconds at the display's full frame rate. Open and still when the system asks for
/// less motion.
public struct PulsePopArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                PulsePopFrame(time: 2.2)
            } else {
                TimelineView(.animation) { context in
                    PulsePopFrame(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: PulsePopFrame.loop))
                }
            }
        }
        .accessibilityLabel("Pulse Pop")
    }
}

/// The can at `time` seconds into its loop.
struct PulsePopFrame: View {
    static let loop = 3.2
    /// When the ring-pull snaps up, and when the can closes again for the next round.
    static let pop = 1.0, close = 2.85

    var time: Double

    private static func ease(_ t: Double) -> Double { let t = min(max(t, 0), 1); return 1 - pow(1 - t, 3) }
    /// The same "random" number for the same particle every frame.
    private static func noise(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i * 127 + salt * 311) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s) }

            let t = time, since = time - Self.pop
            let lift = t < Self.close ? Self.ease(since / 0.14) : 1 - Self.ease((t - Self.close) / 0.25)
            let open = since > 0.02 && t < Self.close + 0.2
            // A jolt as it pops: squashed, then a few quick wobbles that die away.
            let jolt = since > 0 && since < 0.6 ? exp(-since * 7) : 0
            let squash = 1 - 0.07 * jolt * cos(since * 38)
            let tilt = Angle.degrees(4 * jolt * sin(since * 30))

            let purple = Color(red: 0.42, green: 0.30, blue: 0.95), teal = Color(red: 0.10, green: 0.82, blue: 0.78)
            let edge = Color(red: 0.08, green: 0.06, blue: 0.20)
            let metal = Gradient(colors: [Color(white: 0.55), Color(white: 0.92), Color(white: 0.70), Color(white: 0.45)])

            ctx.drawLayer { can in
                // Jolt about the bottom of the can, so it seems to kick off the table.
                can.translateBy(x: p(50, 92).x, y: p(50, 92).y)
                can.rotate(by: tilt)
                can.scaleBy(x: 2 - squash, y: squash)
                can.translateBy(x: -p(50, 92).x, y: -p(50, 92).y)

                let body = Path(roundedRect: r(29, 30, 42, 60), cornerRadius: 6 * s)
                can.drawLayer { shadow in
                    shadow.addFilter(.shadow(color: .black.opacity(0.4), radius: 3 * s, y: 2.5 * s))
                    shadow.fill(body, with: .color(edge))
                }
                can.fill(body, with: .linearGradient(Gradient(colors: [purple, teal]), startPoint: p(50, 30), endPoint: p(50, 90)))
                // Round, like metal: dark at the edges, a bright stripe left of centre.
                can.fill(body, with: .linearGradient(Gradient(stops: [
                    .init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.22),
                    .init(color: .white.opacity(0.35), location: 0.32), .init(color: .clear, location: 0.45),
                    .init(color: .clear, location: 0.75), .init(color: .black.opacity(0.4), location: 1),
                ]), startPoint: p(29, 60), endPoint: p(71, 60)))
                // The pulse across the label.
                var pulse = Path()
                pulse.move(to: p(31, 60))
                pulse.addLines([p(40, 60), p(44, 50), p(49, 70), p(54, 54), p(57, 60), p(69, 60)])
                can.stroke(pulse, with: .color(.white), style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round, lineJoin: .round))
                if size.width >= 40 {
                    can.draw(Text("POP").font(.system(size: 9 * s, weight: .black, design: .rounded)).foregroundStyle(.white.opacity(0.9)),
                             at: p(50, 79))
                }
                can.stroke(body, with: .color(edge), lineWidth: 1.6 * s)

                // The rims and the lid.
                can.fill(Path(roundedRect: r(30, 86, 40, 6), cornerRadius: 3 * s), with: .linearGradient(metal, startPoint: p(30, 89), endPoint: p(70, 89)))
                can.fill(Path(roundedRect: r(30, 25, 40, 8), cornerRadius: 3 * s), with: .linearGradient(metal, startPoint: p(30, 29), endPoint: p(70, 29)))
                let lid = Path(ellipseIn: r(32, 23, 36, 8))
                can.fill(lid, with: .linearGradient(Gradient(colors: [Color(white: 0.85), Color(white: 0.6)]), startPoint: p(32, 23), endPoint: p(68, 31)))
                can.stroke(lid, with: .color(edge.opacity(0.7)), lineWidth: 1 * s)
                if open {
                    can.fill(Path(ellipseIn: r(43, 25, 9, 4)), with: .color(Color(red: 0.12, green: 0.08, blue: 0.10)))
                }
                // The ring-pull, swinging up from its rivet at the middle of the lid.
                can.drawLayer { tab in
                    let pivot = p(52, 27)
                    tab.translateBy(x: pivot.x, y: pivot.y)
                    tab.rotate(by: .degrees(-62 * lift))
                    tab.translateBy(x: -pivot.x, y: -pivot.y)
                    var ring = Path(roundedRect: r(50, 25.2, 13, 3.6), cornerRadius: 1.8 * s)
                    ring.addRoundedRect(in: r(56.5, 26.2, 5, 1.6), cornerSize: CGSize(width: 0.8 * s, height: 0.8 * s))
                    tab.fill(ring, with: .color(Color(white: 0.78)), style: FillStyle(eoFill: true))
                    tab.stroke(Path(roundedRect: r(50, 25.2, 13, 3.6), cornerRadius: 1.8 * s), with: .color(edge.opacity(0.8)), lineWidth: 0.8 * s)
                }
                can.fill(Path(ellipseIn: r(50.8, 26, 2.4, 2)), with: .color(Color(white: 0.5)))
            }

            guard since > 0 else { return }
            let mouth = (x: 47.5, y: 26.0)
            let fizz = Color(red: 0.86, green: 1, blue: 0.97)
            // Small beside a name, the fizz is drawn bigger so it still reads.
            let boost = size.width < 40 ? 1.7 : 1.0
            // Fizz stays bright, fading only near the end of its life.
            func fade(_ k: Double) -> Double { k < 0.6 ? 1 : max(0, 1 - (k - 0.6) / 0.4) }

            // A puff of foam that swells out of the opening and sinks back.
            if since < 0.7 {
                let k = since / 0.7, swell = sin(min(k, 1) * .pi)
                ctx.drawLayer { foam in
                    foam.addFilter(.shadow(color: teal.opacity(0.6), radius: 3 * s))
                    for (dx, dy, d) in [(0.0, -3.0, 9.0), (-4.5, -1.0, 6.5), (4.5, -1.5, 7.0), (-1.5, -6.5, 6.0), (2.5, -7.0, 5.0)] {
                        let size = d * swell * boost
                        foam.fill(Path(ellipseIn: r(mouth.x + dx * swell - size / 2, mouth.y + dy * swell - size / 2, size, size)), with: .color(.white))
                    }
                }
            }

            // The "pssh": three short lines flashing out from the opening.
            if since < 0.3 && size.width >= 40 {
                let k = Self.ease(since / 0.3)
                for a in [-130.0, -90, -50] {
                    let rad = a * .pi / 180
                    var line = Path()
                    line.move(to: p(mouth.x + cos(rad) * (6 + 8 * k), mouth.y + sin(rad) * (6 + 8 * k)))
                    line.addLine(to: p(mouth.x + cos(rad) * (11 + 12 * k), mouth.y + sin(rad) * (11 + 12 * k)))
                    ctx.stroke(line, with: .color(.white.opacity(1 - k)), style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round))
                }
            }
            // The spray: droplets thrown up and out, falling back under gravity and fading.
            for i in 0..<30 {
                let start = Self.noise(i, 1) * 0.12, life = 0.65 + Self.noise(i, 2) * 0.35
                let age = since - start
                guard age > 0, age < life else { continue }
                let angle = (-90 + (Self.noise(i, 3) - 0.5) * 80) * .pi / 180
                let speed = 55 + Self.noise(i, 4) * 45
                let x = mouth.x + cos(angle) * speed * age
                let y = mouth.y + sin(angle) * speed * age + 0.5 * 140 * age * age
                let d = (2.4 + Self.noise(i, 5) * 2.4) * boost
                ctx.fill(Path(ellipseIn: r(x - d / 2, y - d / 2, d, d)), with: .color(fizz.opacity(fade(age / life))))
                ctx.fill(Path(ellipseIn: r(x - d * 0.25, y - d * 0.3, d * 0.3, d * 0.3)), with: .color(.white.opacity(fade(age / life))))
            }
            // Then bubbles, rising in a wavering line until the can closes.
            for i in 0..<10 {
                let period = 0.9 + Self.noise(i, 6) * 0.5
                let age = (since - 0.25 - Double(i) * 0.12).truncatingRemainder(dividingBy: period)
                guard since > 0.25 + Double(i) * 0.12, t < Self.close, age > 0 else { continue }
                let rise = age / period
                let x = mouth.x + (Self.noise(i, 7) - 0.5) * 8 + sin(age * 9 + Double(i)) * 1.6
                let y = mouth.y - 2 - rise * 22
                let d = (2 + Self.noise(i, 8) * 2) * boost
                ctx.stroke(Path(ellipseIn: r(x - d / 2, y - d / 2, d, d)), with: .color(fizz.opacity(fade(rise))), lineWidth: 1.1 * s)
            }
        }
    }
}

/// A bonfire on Bonfire Night: crackling flames that lick and flicker over a pile of logs, smoke drifting up and
/// away, embers floating off, and fireworks launching and bursting above, three in turn, then round again every
/// 6.4 seconds at the display's full frame rate. Every motion is a whole number of turns per loop, so it joins up
/// without a jump. One still burst over the flames when the system asks for less motion.
public struct BonfireArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                BonfireFrame(time: 1.5)
            } else {
                TimelineView(.animation) { context in
                    BonfireFrame(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: BonfireFrame.loop))
                }
            }
        }
        .accessibilityLabel("Bonfire Night")
    }
}

/// The bonfire at `time` seconds into its loop.
struct BonfireFrame: View {
    static let loop = 6.4

    var time: Double

    /// The same "random" number for the same particle every frame.
    private static func noise(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i * 127 + salt * 311) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }

    /// When each firework leaves the fire, where it bursts, and its two colours.
    private static let bursts: [(start: Double, x: Double, y: Double, main: Color, spark: Color)] = [
        (0.3, 32, 27, Color(red: 1, green: 0.80, blue: 0.28), Color(red: 1, green: 0.96, blue: 0.80)),
        (2.0, 69, 21, Color(red: 1, green: 0.28, blue: 0.58), Color(red: 0.80, green: 0.50, blue: 1)),
        (3.7, 50, 31, Color(red: 0.30, green: 0.88, blue: 1), Color(red: 0.55, green: 1, blue: 0.62)),
    ]

    /// Tongues of flame, tallest in the middle: where, how wide and tall, and how they sway (whole turns per loop).
    private static let tongues: [(x: Double, w: Double, h: Double, phase: Double, turns: Double)] = [
        (34, 13, 25, 0.7, 7), (66, 13, 26, 1.9, 6), (41, 17, 36, 1.3, 6), (59, 17, 38, 2.1, 5), (50, 24, 47, 0.0, 5), (46, 14, 31, 3.0, 8),
    ]

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s) }
            func dot(_ x: Double, _ y: Double, _ d: Double) -> Path { Path(ellipseIn: r(x - d / 2, y - d / 2, d, d)) }

            let t = time, turn = 2 * Double.pi / Self.loop
            // Beside a name, particles are drawn bigger so they still read.
            let small = size.width < 40
            let boost = small ? 1.7 : 1.0
            let base = 84.0

            // The glow of the fire on the ground and the air around it.
            ctx.fill(Path(ellipseIn: r(6, 58, 88, 50)), with: .radialGradient(
                Gradient(colors: [Color(red: 1, green: 0.5, blue: 0.1).opacity(0.5), Color(red: 1, green: 0.3, blue: 0.05).opacity(0.15), .clear]),
                center: p(50, 86), startRadius: 0, endRadius: 46 * s))
            ctx.fill(Path(ellipseIn: r(18, 91, 64, 8)), with: .color(.black.opacity(0.35)))

            // Smoke: soft puffs that swell as they climb, drifting off on the breeze, fading in and out.
            for i in 0..<(small ? 4 : 9) {
                let period = Self.loop / Double(2 + i % 2)
                let age = (t + Self.noise(i, 1) * period).truncatingRemainder(dividingBy: period)
                let k = age / period
                let x = 50 + (Self.noise(i, 2) - 0.5) * 12 + k * 17 + sin(k * 6 + Double(i)) * 3 * k
                let y = 64 - k * 50
                let d = (8 + k * 20) * (small ? 1.2 : 1)
                let a = 0.34 * sin(min(max(k, 0), 1) * .pi)
                ctx.fill(dot(x, y, d), with: .radialGradient(
                    Gradient(colors: [Color(red: 0.62, green: 0.58, blue: 0.68).opacity(a), Color(red: 0.34, green: 0.32, blue: 0.42).opacity(a * 0.5), .clear]),
                    center: p(x, y), startRadius: 0, endRadius: d / 2 * s))
            }

            // Fireworks over the top: a rocket climbs from the fire, flashes and bursts into sparks that slow, droop and fade.
            ctx.drawLayer { sky in
                sky.blendMode = .plusLighter
                for (index, burst) in Self.bursts.enumerated() {
                    let climb = 0.45, life = 1.5
                    let since = t - burst.start
                    guard since > 0, since < climb + life else { continue }
                    if since < climb {
                        let k = since / climb, e = 1 - pow(1 - k, 2)
                        let from = (x: 50 + (burst.x - 50) * 0.25, y: 62.0)
                        let x = from.x + (burst.x - from.x) * e, y = from.y + (burst.y - from.y) * e
                        var tail = Path()
                        tail.move(to: p(x, y))
                        tail.addLine(to: p(x - (burst.x - from.x) * 0.05, y + 9))
                        sky.stroke(tail, with: .color(burst.spark.opacity(0.7)), style: StrokeStyle(lineWidth: 1.4 * s * boost, lineCap: .round))
                        sky.fill(dot(x, y, 3 * boost), with: .color(.white))
                        continue
                    }
                    let age = since - climb
                    // The flash of the burst, lingering as a glow that dims.
                    let glow = max(0, 1 - age / 0.5)
                    sky.fill(dot(burst.x, burst.y, 14 + 30 * min(age / 0.25, 1)), with: .radialGradient(
                        Gradient(colors: [.white.opacity(0.6 * glow * glow), burst.main.opacity(0.32 * glow), .clear]),
                        center: p(burst.x, burst.y), startRadius: 0, endRadius: (7 + 15 * min(age / 0.25, 1)) * s))
                    // Two rings of sparks: a wide one and a smaller, slower one in the second colour. Each spark leaves a
                    // glittering tail of fading echoes as it slows and droops.
                    let rings: [(count: Int, reach: Double, colour: Color, speed: Double)] = [
                        (small ? 16 : 34, 1.0, burst.main, 3.4), (small ? 8 : 16, 0.55, burst.spark, 2.6),
                    ]
                    for (ringIndex, ring) in rings.enumerated() {
                        for i in 0..<ring.count {
                            let angle = Double(i) / Double(ring.count) * 2 * .pi + Self.noise(i, index * 9 + ringIndex) * 0.3
                            let reach = (18 + Self.noise(i, index * 9 + 2) * 8) * ring.reach * (small ? 1.12 : 1)
                            func at(_ a: Double) -> (x: Double, y: Double) {
                                let out = reach * (1 - exp(-ring.speed * max(a, 0)))
                                return (burst.x + cos(angle) * out, burst.y + sin(angle) * out + 0.5 * 7 * a * a)
                            }
                            let twinkle = 0.8 + 0.2 * sin(age * 41 + Double(i) * 1.7)
                            // The tail fades with the spark itself, and thins to nothing behind it.
                            let life = pow(max(0, 1 - age / life), 0.8) * twinkle
                            for echo in 0..<(small ? 2 : 5) {
                                let k = age - Double(echo) * 0.05
                                guard k > 0, life > 0 else { continue }
                                let pos = at(k)
                                let d = (echo == 0 ? 2.5 : 1.7 - Double(echo) * 0.22) * boost
                                let fade = life * (1 - Double(echo) * 0.22)
                                if echo == 0 { sky.fill(dot(pos.x, pos.y, d * 2.4), with: .color(ring.colour.opacity(fade * 0.16))) }
                                sky.fill(dot(pos.x, pos.y, d), with: .color((echo == 0 ? Color.white.mix(with: ring.colour, by: 0.55) : ring.colour).opacity(fade)))
                            }
                        }
                    }
                }
            }

            // Logs piled into a tepee: the back two first, then the flames, then the front ones across their feet.
            func log(_ x: Double, _ y: Double, _ length: Double, _ thickness: Double, _ degrees: Double) {
                ctx.drawLayer { layer in
                    layer.translateBy(x: p(x, y).x, y: p(x, y).y)
                    layer.rotate(by: .degrees(degrees))
                    let body = Path(roundedRect: CGRect(x: -length / 2 * s, y: -thickness / 2 * s, width: length * s, height: thickness * s), cornerRadius: thickness / 2 * s)
                    layer.fill(body, with: .linearGradient(Gradient(colors: [Color(red: 0.50, green: 0.30, blue: 0.14), Color(red: 0.20, green: 0.10, blue: 0.05)]),
                                                           startPoint: CGPoint(x: 0, y: -thickness / 2 * s), endPoint: CGPoint(x: 0, y: thickness / 2 * s)))
                    // Lit orange along the top by the fire, with a few bark lines.
                    layer.fill(body, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.5, blue: 0.1).opacity(0.55), .clear]),
                                                           startPoint: CGPoint(x: 0, y: -thickness / 2 * s), endPoint: CGPoint(x: 0, y: thickness * 0.1 * s)))
                    for k in [-0.28, 0.0, 0.3] {
                        var bark = Path()
                        bark.move(to: CGPoint(x: (length * k - 4) * s, y: -thickness * 0.15 * s))
                        bark.addLine(to: CGPoint(x: (length * k + 4) * s, y: thickness * 0.1 * s))
                        layer.stroke(bark, with: .color(.black.opacity(0.35)), lineWidth: 0.7 * s)
                    }
                    layer.stroke(body, with: .color(Color(red: 0.10, green: 0.05, blue: 0.02)), lineWidth: 1.1 * s)
                    // The cut end, with its rings, glowing a little.
                    let end = Path(ellipseIn: CGRect(x: (length / 2 - thickness * 0.35) * s, y: -thickness * 0.42 * s, width: thickness * 0.7 * s, height: thickness * 0.84 * s))
                    layer.fill(end, with: .color(Color(red: 0.86, green: 0.58, blue: 0.30)))
                    layer.stroke(Path(ellipseIn: CGRect(x: (length / 2 - thickness * 0.2) * s, y: -thickness * 0.22 * s, width: thickness * 0.4 * s, height: thickness * 0.44 * s)),
                                 with: .color(Color(red: 0.55, green: 0.32, blue: 0.14)), lineWidth: 0.6 * s)
                }
            }
            log(37, 81, 40, 8, -24)
            log(63, 81, 40, 8, 24)

            // The flames: each tongue is three layers, red outside, orange, yellow, then a white-hot core.
            let layers: [(scale: Double, from: Color, to: Color)] = [
                (1.0, Color(red: 0.95, green: 0.16, blue: 0.04), Color(red: 1, green: 0.45, blue: 0.08)),
                (0.74, Color(red: 1, green: 0.42, blue: 0.06), Color(red: 1, green: 0.72, blue: 0.15)),
                (0.46, Color(red: 1, green: 0.78, blue: 0.20), Color(red: 1, green: 0.97, blue: 0.70)),
            ]
            ctx.drawLayer { fire in
                fire.addFilter(.shadow(color: Color(red: 1, green: 0.45, blue: 0.05).opacity(0.75), radius: 4 * s))
                for layer in layers {
                    for tongue in Self.tongues {
                        let sway = sin(t * turn * tongue.turns + tongue.phase)
                        let flicker = 0.88 + 0.12 * sin(t * turn * (tongue.turns + 3) + tongue.phase * 2)
                        let h = tongue.h * layer.scale * flicker, w = tongue.w * (0.6 + 0.4 * layer.scale)
                        let lean = sway * 5 * layer.scale + (tongue.x - 50) * -0.12
                        let tip = (x: tongue.x + lean, y: base - h)
                        var flame = Path()
                        flame.move(to: p(tongue.x - w / 2, base))
                        flame.addQuadCurve(to: p(tip.x, tip.y), control: p(tongue.x - w * 0.62 + lean * 0.2, base - h * 0.55))
                        flame.addQuadCurve(to: p(tongue.x + w / 2, base), control: p(tongue.x + w * 0.62 + lean * 0.6, base - h * 0.42))
                        flame.closeSubpath()
                        fire.fill(flame, with: .linearGradient(Gradient(colors: [layer.from, layer.to]), startPoint: p(tongue.x, base), endPoint: p(tip.x, tip.y)))
                    }
                }
            }

            log(40, 89, 44, 9, 10)
            log(60, 89, 44, 9, -10)
            log(50, 93, 48, 8, 0)

            // Embers lifted off the fire, cooling from yellow to red as they rise.
            for i in 0..<(small ? 5 : 13) {
                let period = Self.loop / Double(3 + i % 3)
                let age = (t + Self.noise(i, 11) * period).truncatingRemainder(dividingBy: period)
                let k = age / period
                let x = 50 + (Self.noise(i, 12) - 0.5) * 28 + sin(age * 5 + Double(i)) * 3 * k
                let y = 72 - k * (28 + Self.noise(i, 13) * 20)
                let d = (1.7 + Self.noise(i, 14) * 1.5) * (1 - k * 0.55) * boost
                ctx.fill(dot(x, y, d), with: .color(Color(red: 1, green: 0.85 - 0.5 * k, blue: 0.25 - 0.2 * k).opacity(1 - k * k)))
            }
        }
    }
}

/// A shield for the people who keep Pulshade safe: brushed steel edged in gold, the pulse running across it in a
/// glow, a star above, and a sheen that sweeps over it every 4 seconds. Still when the system asks for less motion.
public struct GuardianArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                GuardianFrame(sweep: 0.5)
            } else {
                TimelineView(.animation) { context in
                    GuardianFrame(sweep: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4)
                }
            }
        }
        .accessibilityLabel("Guardian")
    }
}

struct GuardianFrame: View {
    /// 0 to 1 across one loop: where the sheen has got to.
    var sweep: Double

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

            func shield(_ inset: Double) -> Path {
                var path = Path()
                path.move(to: p(50, 7 + inset))
                path.addCurve(to: p(86 - inset, 20 + inset), control1: p(62, 14 + inset), control2: p(76, 18 + inset))
                path.addCurve(to: p(50, 94 - inset), control1: p(86 - inset, 62), control2: p(70, 82))
                path.addCurve(to: p(14 + inset, 20 + inset), control1: p(30, 82), control2: p(14 + inset, 62))
                path.addCurve(to: p(50, 7 + inset), control1: p(24, 18 + inset), control2: p(38, 14 + inset))
                path.closeSubpath()
                return path
            }

            let gold = Color(red: 0.98, green: 0.78, blue: 0.30), deepGold = Color(red: 0.62, green: 0.40, blue: 0.08)
            let steel = Color(red: 0.62, green: 0.68, blue: 0.80), deepSteel = Color(red: 0.16, green: 0.20, blue: 0.34)
            let teal = Color(red: 0.25, green: 0.92, blue: 0.85)

            let outer = shield(0), face = shield(5.5)
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 2.6 * s, y: 2 * s))
                layer.fill(outer, with: .linearGradient(Gradient(colors: [gold, deepGold]), startPoint: p(30, 8), endPoint: p(70, 94)))
            }
            ctx.stroke(outer, with: .color(deepGold.mix(with: .black, by: 0.5)), style: StrokeStyle(lineWidth: 1.3 * s, lineJoin: .round))
            ctx.fill(face, with: .linearGradient(Gradient(colors: [steel, deepSteel]), startPoint: p(30, 10), endPoint: p(72, 92)))
            // A bevel: light along the top and left, dark along the bottom, so the face reads as raised.
            ctx.stroke(face, with: .linearGradient(Gradient(colors: [.white.opacity(0.7), .clear, .black.opacity(0.45)]), startPoint: p(20, 10), endPoint: p(78, 92)),
                       style: StrokeStyle(lineWidth: 1.4 * s, lineJoin: .round))

            // The pulse across the face, glowing.
            var pulse = Path()
            pulse.addLines([p(24, 52), p(38, 52), p(44, 38), p(52, 68), p(58, 46), p(62, 52), p(76, 52)])
            ctx.drawLayer { glow in
                glow.addFilter(.shadow(color: teal.opacity(0.9), radius: 3.2 * s))
                glow.stroke(pulse, with: .color(teal), style: StrokeStyle(lineWidth: 3.2 * s, lineCap: .round, lineJoin: .round))
            }
            ctx.stroke(pulse, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round, lineJoin: .round))

            // A star above the pulse.
            var star = Path()
            for i in 0..<10 {
                let radius = i % 2 == 0 ? 7.5 : 3.1
                let angle = Double(i) * .pi / 5 - .pi / 2
                let point = p(50 + cos(angle) * radius, 27 + sin(angle) * radius)
                if i == 0 { star.move(to: point) } else { star.addLine(to: point) }
            }
            star.closeSubpath()
            ctx.fill(star, with: .linearGradient(Gradient(colors: [.white, gold]), startPoint: p(50, 19), endPoint: p(50, 35)))
            ctx.stroke(star, with: .color(deepGold), style: StrokeStyle(lineWidth: 0.8 * s, lineJoin: .round))

            // The sheen: a soft diagonal band sweeping across, clipped to the shield.
            let x = -30 + sweep * 160
            ctx.drawLayer { sheen in
                sheen.clip(to: outer)
                var band = Path()
                band.addLines([p(x, 0), p(x + 14, 0), p(x - 6, 100), p(x - 20, 100)])
                sheen.fill(band, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.38), .clear]), startPoint: p(x - 6, 50), endPoint: p(x + 14, 50)))
            }
        }
    }
}

/// The collectible someone shows after their name, sized to the text beside it.
public struct BadgeMark: View {
    var badge: Collectible?
    var size: CGFloat

    public init(badge: Collectible?, size: CGFloat = 15) {
        self.badge = badge
        self.size = size
    }

    public var body: some View {
        if let badge, let kind = badge.kind {
            CollectibleIcon(item: kind, size: size)
                .help("\(kind.name) #\(badge.serial)")
                .accessibilityLabel("\(kind.name) number \(badge.serial)")
        }
    }
}

/// A collectible's number, with a flourish for the rare ones: gold for the first ten, silver to 25, and the end of the run.
public struct RarityTag: View {
    var item: Collectible

    public init(item: Collectible) { self.item = item }

    public var body: some View {
        let rarity = item.rarity
        let tint: Color = switch rarity {
        case .legendary: Color(red: 0.98, green: 0.78, blue: 0.30)
        case .rare: Color(red: 0.72, green: 0.78, blue: 0.90)
        case .last: Color(red: 0.74, green: 0.55, blue: 1)
        case .common: Color.white.opacity(0.42)
        }
        HStack(spacing: 4) {
            if rarity == .legendary { Image(systemName: "star.fill").font(.system(size: 9)) }
            Text("#\(item.serial)").font(.system(size: 12, weight: rarity == .common ? .regular : .semibold, design: .monospaced))
            if let name = rarity.name { Text("· \(name)").font(.system(size: 11, weight: .medium)) }
        }
        .foregroundStyle(tint)
        .accessibilityLabel("Number \(item.serial)\(rarity.name.map { ", \($0)" } ?? "")")
    }
}
