import SwiftUI

/// Winnie the Pooh sitting in a pool of warm light: a golden bear in a little red jumper, bobbing gently, one paw
/// waving, blinking twice and glancing at his honey. Every motion is a whole number of turns per loop (6 seconds), so
/// it joins up without a jump. Still, eyes open, when the system asks for less motion.
public struct WinnieArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                WinnieFrame(time: 0.4)
            } else {
                TimelineView(.animation) { context in
                    WinnieFrame(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: WinnieFrame.loop))
                }
            }
        }
        .accessibilityLabel("Winnie The Pooh")
    }
}

/// Winnie at `time` seconds into his loop.
struct WinnieFrame: View {
    static let loop = 6.0

    var time: Double

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s) }
            func oval(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> Path { Path(ellipseIn: r(x - rx, y - ry, rx * 2, ry * 2)) }
            func turned(_ path: Path, by angle: Double, about c: CGPoint) -> Path {
                path.applying(CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y))
            }

            let t = time, turn = 2 * Double.pi / Self.loop

            let fur = Color(red: 0.96, green: 0.67, blue: 0.16), furLit = Color(red: 1, green: 0.84, blue: 0.40)
            let furDeep = Color(red: 0.72, green: 0.40, blue: 0.06)
            let tan = Color(red: 0.99, green: 0.85, blue: 0.55)
            let red = Color(red: 0.88, green: 0.16, blue: 0.18), redDeep = Color(red: 0.52, green: 0.06, blue: 0.10)
            let ink = Color(red: 0.20, green: 0.09, blue: 0.03)

            // He rocks a little and breathes: a whole-loop sway and a belly that swells twice.
            let bob = sin(t * turn * 2) * 0.9
            let lean = sin(t * turn) * 0.025
            let breath = 1 + 0.015 * sin(t * turn * 4)

            // The warm light round him and the grass he sits on.
            ctx.fill(oval(50, 56, 54, 50), with: .radialGradient(
                Gradient(colors: [Color(red: 1, green: 0.78, blue: 0.35).opacity(0.28), Color(red: 1, green: 0.6, blue: 0.2).opacity(0.10), .clear]),
                center: p(50, 56), startRadius: 0, endRadius: 54 * s))
            ctx.fill(oval(50, 92, 36, 6), with: .color(.black.opacity(0.28)))
            ctx.fill(oval(50, 91, 32, 4.5), with: .linearGradient(
                Gradient(colors: [Color(red: 0.48, green: 0.72, blue: 0.28), Color(red: 0.25, green: 0.50, blue: 0.20)]), startPoint: p(50, 87), endPoint: p(50, 96)))

            // Everything from here on moves together with the bob and lean, about his seat.
            ctx.translateBy(x: 0, y: bob * s)
            ctx.translateBy(x: p(50, 90).x, y: p(50, 90).y)
            ctx.rotate(by: .radians(lean))
            ctx.translateBy(x: -p(50, 90).x, y: -p(50, 90).y)

            func shaded(_ path: Path, in c: inout GraphicsContext, from: Color, to: Color, start: CGPoint, end: CGPoint, line: Double = 1.2) {
                c.fill(path, with: .linearGradient(Gradient(colors: [from, to]), startPoint: start, endPoint: end))
                c.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: line * s, lineJoin: .round))
            }

            // Feet, sticking out in front, with their pale pads.
            for side in [-1.0, 1.0] {
                let foot = oval(50 + side * 17, 87, 11, 6.5)
                shaded(foot, in: &ctx, from: furLit, to: furDeep, start: p(50 + side * 17, 80), end: p(50 + side * 17, 94))
                ctx.fill(oval(50 + side * 17, 88, 6, 3.4), with: .color(tan))
            }

            // The tail is hidden; the body is a soft pear, tummy bulging below the jumper.
            let body = oval(50, 68, 25 * breath, 22 * breath)
            shaded(body, in: &ctx, from: furLit, to: furDeep, start: p(32, 50), end: p(70, 88), line: 1.4)
            ctx.fill(oval(50, 76, 15 * breath, 10 * breath), with: .radialGradient(
                Gradient(colors: [tan, fur.opacity(0)]), center: p(50, 76), startRadius: 0, endRadius: 15 * s))

            // The little red jumper: it stops short of the tummy, with a ragged hem.
            var jumper = Path()
            jumper.move(to: p(27.5, 60))
            jumper.addQuadCurve(to: p(50, 49.5), control: p(33, 50))
            jumper.addQuadCurve(to: p(72.5, 60), control: p(67, 50))
            jumper.addQuadCurve(to: p(70, 70), control: p(74, 66))
            jumper.addQuadCurve(to: p(50, 72.5), control: p(60, 74.5))
            jumper.addQuadCurve(to: p(30, 70), control: p(40, 74.5))
            jumper.addQuadCurve(to: p(27.5, 60), control: p(26, 66))
            jumper.closeSubpath()
            ctx.drawLayer { layer in
                layer.fill(jumper, with: .linearGradient(Gradient(stops: [
                    .init(color: red.mix(with: .white, by: 0.15), location: 0), .init(color: red, location: 0.5), .init(color: redDeep, location: 1),
                ]), startPoint: p(30, 52), endPoint: p(70, 72)))
                layer.clip(to: jumper)
                layer.stroke(Path { $0.move(to: p(24, 71)); $0.addQuadCurve(to: p(76, 71), control: p(50, 78)) },
                             with: .color(redDeep.opacity(0.55)), lineWidth: 2.4 * s)
                layer.fill(oval(40, 56, 8, 4), with: .color(.white.opacity(0.14)))
            }
            ctx.stroke(jumper, with: .color(ink), style: StrokeStyle(lineWidth: 1.2 * s, lineJoin: .round))

            // His left arm, resting on his tummy.
            let rest = oval(31, 66, 6, 11)
            shaded(turned(rest, by: 0.35, about: p(31, 66)), in: &ctx, from: furLit, to: fur, start: p(26, 58), end: p(36, 74))

            // The ears, then the head over them.
            for side in [-1.0, 1.0] {
                let ear = oval(50 + side * 19.5, 21.5, 8, 7.5)
                shaded(ear, in: &ctx, from: furLit, to: fur, start: p(50 + side * 24, 15), end: p(50 + side * 15, 28))
                ctx.fill(oval(50 + side * 19.5, 22.5, 4.4, 4), with: .color(furDeep.opacity(0.85)))
            }
            let head = oval(50, 39, 25, 21)
            shaded(head, in: &ctx, from: furLit, to: fur, start: p(34, 20), end: p(66, 60), line: 1.4)

            // A little curl of fur on the brow, then the muzzle.
            ctx.stroke(Path { $0.move(to: p(48, 20.5)); $0.addQuadCurve(to: p(54, 20), control: p(51, 16)) },
                       with: .color(furDeep), style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
            let muzzle = oval(50, 47, 12.5, 9)
            ctx.fill(muzzle, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.92, blue: 0.70), tan]), startPoint: p(50, 38), endPoint: p(50, 56)))
            ctx.stroke(muzzle, with: .color(ink.opacity(0.35)), lineWidth: 0.7 * s)

            // Rosy cheeks.
            for side in [-1.0, 1.0] {
                ctx.fill(oval(50 + side * 17, 45, 4, 2.6), with: .color(Color(red: 0.95, green: 0.42, blue: 0.30).opacity(0.38)))
            }

            // Nose and mouth.
            let nose = oval(50, 42.2, 4.6, 3.2)
            ctx.fill(nose, with: .linearGradient(Gradient(colors: [Color(red: 0.34, green: 0.16, blue: 0.08), ink]), startPoint: p(50, 39), endPoint: p(50, 46)))
            ctx.fill(oval(48.6, 41, 1.5, 0.9), with: .color(.white.opacity(0.65)))
            var mouth = Path()
            mouth.move(to: p(50, 45.4)); mouth.addLine(to: p(50, 48.2))
            mouth.move(to: p(43.8, 47.2)); mouth.addQuadCurve(to: p(50, 48.2), control: p(46.6, 52))
            mouth.addQuadCurve(to: p(56.2, 47.2), control: p(53.4, 52))
            ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 1.0 * s, lineCap: .round, lineJoin: .round))

            // Eyes: two beads, which look from one side to the other and close for a blink twice a loop.
            let phase = t / Self.loop
            let blinking = (phase * 2).truncatingRemainder(dividingBy: 1) > 0.94
            let glance = sin(t * turn) * 0.9
            for side in [-1.0, 1.0] {
                let x = 50 + side * 9.2
                if blinking {
                    ctx.stroke(Path { $0.move(to: p(x - 2.4, 35.2)); $0.addQuadCurve(to: p(x + 2.4, 35.2), control: p(x, 37.4)) },
                               with: .color(ink), style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
                } else {
                    ctx.fill(oval(x, 35, 2.5, 3), with: .color(ink))
                    ctx.fill(oval(x + glance * 0.5 - 0.7, 33.8, 0.95, 1.0), with: .color(.white.opacity(0.95)))
                }
            }

            // His right arm waves, about the shoulder, three times a loop.
            let shoulder = p(71, 59)
            let wave = 0.5 + sin(t * turn * 3) * 0.3
            let arm = oval(76.5, 52, 6, 11.5)
            shaded(turned(arm, by: wave, about: shoulder), in: &ctx, from: furLit, to: fur, start: p(72, 42), end: p(82, 62))
            ctx.fill(turned(oval(76.5, 43.5, 3.2, 2.6), by: wave, about: shoulder), with: .color(tan.opacity(0.9)))

            // A glint on the top of his head.
            let flash = ArtKit.twinkle(t, loop: Self.loop, times: 2, phase: 0.1)
            ctx.drawLayer { glow in
                glow.blendMode = .plusLighter
                glow.fill(ArtKit.glint(at: p(40, 25), radius: 4.6 * flash * s), with: .color(.white.opacity(0.8 * flash)))
            }
        }
    }
}

/// A jar of honey, labelled HUNNY, with honey brimming over its lip and trickling down, a bee circling it and
/// another loop-the-looping over the top, then round again every 6 seconds at the display's full frame rate. Still,
/// with one bee, when the system asks for less motion.
public struct HoneyJarArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                HoneyJarFrame(time: 1.0)
            } else {
                TimelineView(.animation) { context in
                    HoneyJarFrame(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: HoneyJarFrame.loop))
                }
            }
        }
        .accessibilityLabel("Honey Jar")
    }
}

/// The jar at `time` seconds into its loop.
struct HoneyJarFrame: View {
    static let loop = 6.0

    var time: Double

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s) }
            func oval(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> Path { Path(ellipseIn: r(x - rx, y - ry, rx * 2, ry * 2)) }

            let t = time, turn = 2 * Double.pi / Self.loop
            let small = size.width < 40

            let amber = Color(red: 1, green: 0.70, blue: 0.10), amberLit = Color(red: 1, green: 0.88, blue: 0.40)
            let amberDeep = Color(red: 0.70, green: 0.34, blue: 0.02)
            let ink = Color(red: 0.24, green: 0.11, blue: 0.02)
            let cream = Color(red: 1, green: 0.96, blue: 0.82)

            // Light round it, and the table it stands on.
            ctx.fill(oval(50, 58, 54, 50), with: .radialGradient(
                Gradient(colors: [Color(red: 1, green: 0.76, blue: 0.25).opacity(0.30), Color(red: 1, green: 0.55, blue: 0.1).opacity(0.10), .clear]),
                center: p(50, 58), startRadius: 0, endRadius: 54 * s))
            ctx.fill(oval(50, 91, 32, 5), with: .color(.black.opacity(0.30)))

            // The jar: a round-shouldered glass pot with a short neck.
            var jar = Path()
            jar.move(to: p(36, 30))
            jar.addLine(to: p(36, 36))
            jar.addQuadCurve(to: p(24, 50), control: p(24, 38))
            jar.addLine(to: p(24, 80))
            jar.addQuadCurve(to: p(34, 90), control: p(24, 90))
            jar.addLine(to: p(66, 90))
            jar.addQuadCurve(to: p(76, 80), control: p(76, 90))
            jar.addLine(to: p(76, 50))
            jar.addQuadCurve(to: p(64, 36), control: p(76, 38))
            jar.addLine(to: p(64, 30))
            jar.closeSubpath()

            // Honey fills it nearly to the brim, its top gently heaving.
            let top = 45.0 + sin(t * turn * 2) * 0.9
            ctx.drawLayer { layer in
                layer.fill(jar, with: .color(Color(red: 0.85, green: 0.92, blue: 1).opacity(0.22)))
                layer.clip(to: jar)
                var honey = Path()
                honey.move(to: p(20, 100))
                honey.addLine(to: p(20, top))
                for i in 0...12 {
                    let x = 20 + 60 * Double(i) / 12
                    honey.addLine(to: p(x, top + sin(Double(i) * 0.9 + t * turn * 2) * 0.9))
                }
                honey.addLine(to: p(80, 100))
                honey.closeSubpath()
                layer.fill(honey, with: .linearGradient(Gradient(stops: [
                    .init(color: amberLit, location: 0), .init(color: amber, location: 0.35), .init(color: amberDeep, location: 1),
                ]), startPoint: p(30, top), endPoint: p(70, 92)))
                // Light shining through the honey from the lower left.
                layer.fill(oval(36, 80, 9, 12), with: .radialGradient(
                    Gradient(colors: [Color(red: 1, green: 0.96, blue: 0.6).opacity(0.45), .clear]), center: p(36, 80), startRadius: 0, endRadius: 12 * s))
                // Bubbles drifting up through it.
                if !small {
                    for i in 0..<5 {
                        let period = Self.loop / Double(1 + i % 2)
                        let k = (t + Double(i) * 1.3).truncatingRemainder(dividingBy: period) / period
                        let x = 32 + Double(i) * 8.5 + sin(k * 2 * .pi) * 1.5
                        let y = 88 - k * (88 - top - 3)
                        layer.fill(oval(x, y, 1.1 + Double(i % 3) * 0.4, 1.1 + Double(i % 3) * 0.4), with: .color(.white.opacity(0.4 * min(1, k * 8, (1 - k) * 8))))
                    }
                }
            }
            ctx.stroke(jar, with: .color(ink), style: StrokeStyle(lineWidth: 1.5 * s, lineJoin: .round))

            // The label, with its one word.
            let label = Path(roundedRect: r(30, 56, 40, 22), cornerRadius: 3.5 * s)
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 1 * s, y: 0.7 * s))
                layer.fill(label, with: .linearGradient(Gradient(colors: [cream, Color(red: 0.93, green: 0.86, blue: 0.66)]), startPoint: p(30, 56), endPoint: p(70, 78)))
            }
            ctx.stroke(label, with: .color(ink.opacity(0.8)), lineWidth: 1 * s)
            ctx.stroke(Path(roundedRect: r(32.2, 58.2, 35.6, 17.6), cornerRadius: 2.4 * s), with: .color(Color(red: 0.72, green: 0.12, blue: 0.12).opacity(0.7)), lineWidth: 0.7 * s)
            if !small {
                ctx.draw(Text("HUNNY").font(.system(size: 9.4 * s, weight: .heavy, design: .rounded)).foregroundColor(Color(red: 0.62, green: 0.08, blue: 0.10)), at: p(50, 67.2))
            } else {
                for i in 0..<3 {
                    ctx.fill(Path(roundedRect: r(35, 61 + Double(i) * 5, 30, 2.4), cornerRadius: 1 * s), with: .color(Color(red: 0.62, green: 0.08, blue: 0.10)))
                }
            }

            // A cloth lid tied on with string, its edge scalloped.
            var cloth = Path()
            cloth.move(to: p(30, 36))
            cloth.addQuadCurve(to: p(36, 24), control: p(31, 28))
            cloth.addLine(to: p(64, 24))
            cloth.addQuadCurve(to: p(70, 36), control: p(69, 28))
            let scallops = 6
            for i in 0..<scallops {
                let from = 70 - 40 * Double(i) / Double(scallops), to = 70 - 40 * Double(i + 1) / Double(scallops)
                cloth.addQuadCurve(to: p(to, 36), control: p((from + to) / 2, 41.5))
            }
            cloth.closeSubpath()
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.3), radius: 1.2 * s, y: 1 * s))
                layer.fill(cloth, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.98, blue: 0.9), Color(red: 0.86, green: 0.78, blue: 0.58)]), startPoint: p(32, 24), endPoint: p(68, 40)))
            }
            ctx.drawLayer { layer in
                layer.clip(to: cloth)
                // Gingham, a few checks only.
                for i in 0..<4 {
                    layer.fill(Path(CGRect(x: ox + (31 + Double(i) * 10) * s, y: oy + 22 * s, width: 5 * s, height: 22 * s)), with: .color(Color(red: 0.78, green: 0.14, blue: 0.14).opacity(0.28)))
                }
                for i in 0..<2 {
                    layer.fill(Path(CGRect(x: ox + 28 * s, y: oy + (26 + Double(i) * 7) * s, width: 44 * s, height: 3.4 * s)), with: .color(Color(red: 0.78, green: 0.14, blue: 0.14).opacity(0.28)))
                }
            }
            ctx.stroke(cloth, with: .color(ink), style: StrokeStyle(lineWidth: 1.2 * s, lineJoin: .round))
            ctx.stroke(Path { $0.move(to: p(34.6, 31)); $0.addQuadCurve(to: p(65.4, 31), control: p(50, 35)) },
                       with: .color(Color(red: 0.55, green: 0.32, blue: 0.14)), style: StrokeStyle(lineWidth: 1.7 * s, lineCap: .round))
            ctx.stroke(Path { $0.move(to: p(50, 33)); $0.addQuadCurve(to: p(44, 41), control: p(46, 34)) },
                       with: .color(Color(red: 0.55, green: 0.32, blue: 0.14)), style: StrokeStyle(lineWidth: 1.2 * s, lineCap: .round))

            // Honey oozing from under the lid, down the shoulder and along the glass, with a drop that swells at the end,
            // lets go, falls to the table and is gone before the loop comes round (it starts from nothing, so the loop joins).
            let k = t / Self.loop
            let end = 63.0
            var trickle = Path()
            trickle.move(to: p(67, 37.5))
            trickle.addQuadCurve(to: p(77.5, 50), control: p(77.5, 38))
            trickle.addLine(to: p(77.5, end))
            ctx.stroke(trickle, with: .color(ink.opacity(0.85)), style: StrokeStyle(lineWidth: 5.6 * s, lineCap: .round, lineJoin: .round))
            ctx.stroke(trickle, with: .color(amber), style: StrokeStyle(lineWidth: 4.0 * s, lineCap: .round, lineJoin: .round))
            ctx.stroke(trickle.offsetBy(dx: -0.8 * s, dy: 0), with: .color(amberLit.opacity(0.8)), style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
            let swell = min(1, k / 0.4)
            let fall = max(0, (k - 0.4) / 0.5)
            if k < 0.9 {
                let dropY = end + 3 + swell * 2 + fall * fall * (88.5 - end - 5)
                let stretch = 1 + 0.5 * (1 - fall) * swell
                let alpha = min(1, (0.9 - k) * 20)
                ctx.drawLayer { drop in
                    drop.opacity = alpha
                    drop.fill(oval(77.5, dropY, 2.3 * swell, 3.0 * swell * stretch), with: .linearGradient(
                        Gradient(colors: [amberLit, amberDeep]), startPoint: p(77.5, dropY - 3), endPoint: p(77.5, dropY + 3)))
                    drop.fill(oval(76.8, dropY - 0.8, 0.7 * swell, 1.0 * swell), with: .color(.white.opacity(0.7)))
                }
            }

            // Glass highlights down the left of the jar, and a glint on the shoulder.
            ctx.stroke(Path { $0.move(to: p(28.5, 52)); $0.addLine(to: p(28.5, 84)) }, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round))
            ctx.stroke(Path { $0.move(to: p(32, 52)); $0.addLine(to: p(32, 56)) }, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2 * s, lineCap: .round))
            let flash = ArtKit.twinkle(t, loop: Self.loop, times: 2, phase: 0.2)
            ctx.drawLayer { glow in
                glow.blendMode = .plusLighter
                glow.fill(ArtKit.glint(at: p(30, 46), radius: 6 * flash * s), with: .color(.white.opacity(0.85 * flash)))
            }

            // The bees. One circles the jar once a loop, passing behind it and in front; a second loops over the top.
            func bee(_ x: Double, _ y: Double, scale: Double, facing: Double, flap: Double) {
                var body = ctx
                body.translateBy(x: p(x, y).x, y: p(x, y).y)
                body.scaleBy(x: facing * scale * s, y: scale * s)
                let wing = Color.white.opacity(0.78)
                body.drawLayer { w in
                    let lift = 0.35 + 0.65 * abs(flap)
                    w.fill(Path(ellipseIn: CGRect(x: -3.2, y: -6.2 * lift - 1, width: 4.6, height: 6.2 * lift)), with: .color(wing))
                    w.fill(Path(ellipseIn: CGRect(x: -0.4, y: -5.4 * lift - 1, width: 3.8, height: 5.4 * lift)), with: .color(wing.opacity(0.7)))
                    w.stroke(Path(ellipseIn: CGRect(x: -3.2, y: -6.2 * lift - 1, width: 4.6, height: 6.2 * lift)), with: .color(ink.opacity(0.4)), lineWidth: 0.35)
                }
                let torso = Path(ellipseIn: CGRect(x: -4.6, y: -2.7, width: 9.2, height: 5.4))
                body.fill(torso, with: .color(Color(red: 1, green: 0.82, blue: 0.12)))
                body.drawLayer { st in
                    st.clip(to: torso)
                    for sx in [-1.8, 1.0] {
                        st.fill(Path(CGRect(x: sx, y: -3, width: 1.5, height: 6)), with: .color(ink))
                    }
                }
                body.stroke(torso, with: .color(ink), lineWidth: 0.6)
                body.fill(Path(ellipseIn: CGRect(x: 3.4, y: -2.1, width: 3.6, height: 3.8)), with: .color(ink))
                body.fill(Path(ellipseIn: CGRect(x: 5, y: -1.3, width: 0.9, height: 0.9)), with: .color(.white))
                body.stroke(Path { $0.move(to: CGPoint(x: -4.6, y: 0)); $0.addLine(to: CGPoint(x: -6.4, y: 0.6)) }, with: .color(ink), lineWidth: 0.7)
            }
            let orbit = t * turn
            let bx = 50 + 41 * cos(orbit), by = 38 + 9 * sin(orbit) - 6 * cos(orbit * 2)
            bee(bx, by, scale: small ? 1.7 : 1.1, facing: -sin(orbit) >= 0 ? 1 : -1, flap: sin(t * turn * 36))
            if !small {
                let loopA = t * turn * 2
                let cx = 50 + 20 * sin(loopA), cy = 15 + 5.5 * sin(loopA * 2)
                bee(cx, cy, scale: 0.85, facing: cos(loopA) >= 0 ? 1 : -1, flap: sin(t * turn * 40 + 1))
            }
        }
    }
}
