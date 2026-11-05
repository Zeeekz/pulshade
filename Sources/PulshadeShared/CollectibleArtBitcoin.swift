import SwiftUI

/// A Bitcoin coin in glossy orange gold: a minted rim of beads, a bevelled face with the white B and its two strokes
/// top and bottom, which spins once on the spot to show the pulse on its back, then catches a sheen sweeping over it
/// while blocks of light rise behind it and glints flash off its rim, then round again every 6 seconds at the
/// display's full frame rate. Every motion is a whole number of turns per loop, so it joins up without a jump. Facing
/// front, shining and still, when the system asks for less motion.
public struct BitcoinArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                BitcoinFrame(time: 4.2)
            } else {
                TimelineView(.animation) { context in
                    BitcoinFrame(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: BitcoinFrame.loop))
                }
            }
        }
        .accessibilityLabel("Bitcoin")
    }
}

/// The coin at `time` seconds into its loop.
struct BitcoinFrame: View {
    static let loop = 6.0

    var time: Double

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s) }

            let t = time, turn = 2 * Double.pi / Self.loop
            let small = size.width < 40

            let hi = Color(red: 1, green: 0.86, blue: 0.50)
            let mid = Color(red: 0.97, green: 0.58, blue: 0.10)
            let lo = Color(red: 0.60, green: 0.28, blue: 0.02)
            let ink = Color(red: 0.28, green: 0.12, blue: 0)

            // One slow turn on the spot, then it rests facing front while it shines.
            let spin = min(max((t - 0.8) / 2.2, 0), 1)
            let angle = 2 * Double.pi * spin * spin * (3 - 2 * spin)
            let width = cos(angle), side = sin(angle)
            let bob = 1.6 * sin(t * turn)
            let beat = 0.5 + 0.5 * sin(t * turn * 2)

            let cx = 50.0, cy = 46.0 + bob, radius = 30.0, depth = 7.0

            // The light it gives off on the night around it, and its shadow on the ground.
            ctx.fill(Path(ellipseIn: r(-6, -6, 112, 108)), with: .radialGradient(
                Gradient(colors: [mid.opacity(0.30 + 0.08 * beat), Color(red: 0.9, green: 0.35, blue: 0.05).opacity(0.10), .clear]),
                center: p(50, 48), startRadius: 0, endRadius: 56 * s))
            ctx.fill(Path(ellipseIn: r(28 + bob * 0.8, 88, 44 - bob * 1.6, 7)), with: .color(.black.opacity(0.30)))

            // Blocks of light rising behind it, each a whole number of times per loop.
            for i in 0..<(small ? 7 : 16) {
                let ph = (Double(1 + i % 2) * t / Self.loop + ArtKit.noise(i, 1)).truncatingRemainder(dividingBy: 1)
                let x = 50 + (ArtKit.noise(i, 2) - 0.5) * 86 + 3 * sin(ph * 2 * .pi + Double(i))
                let y = 97 - ph * 92
                let half = (1.2 + ArtKit.noise(i, 3) * 1.8) * s / 2
                let spun = ph * 2 * .pi * Double(1 + i % 3)
                let block = Path(roundedRect: CGRect(x: -half, y: -half, width: half * 2, height: half * 2), cornerRadius: half * 0.25)
                    .applying(CGAffineTransform(translationX: ox + x * s, y: oy + y * s).rotated(by: spun))
                ctx.fill(block, with: .color((i % 3 == 0 ? Color.white : hi).opacity(0.8 * sin(ph * .pi))))
            }

            // Which face is turned to us, and where the two faces sit across the coin's thickness.
            let facingFront = width >= 0
            let across = abs(width)
            let near = cx + (facingFront ? 1 : -1) * depth / 2 * side
            let far = 2 * cx - near

            // The far face and the edge joining it to the near one.
            let farFace = Path(ellipseIn: CGRect(x: ox + (far - radius * across) * s, y: oy + (cy - radius) * s,
                                                 width: 2 * radius * across * s, height: 2 * radius * s))
            ctx.fill(farFace, with: .color(lo))
            let edge = CGRect(x: ox + min(near, far) * s, y: oy + (cy - radius) * s, width: abs(near - far) * s, height: 2 * radius * s)
            ctx.fill(Path(edge), with: .linearGradient(Gradient(colors: [lo, mid, lo]), startPoint: CGPoint(x: edge.minX, y: 0), endPoint: CGPoint(x: edge.maxX, y: 0)))

            // The near face, drawn flat in its own units and squeezed by the turn.
            ctx.drawLayer { l in
                l.translateBy(x: ox + near * s, y: oy + cy * s)
                l.scaleBy(x: s * max(across, 0.001), y: s)
                let sweep = min(max((t - 3.2) / 1.5, 0), 1)
                Self.paintFace(&l, front: facingFront, sweep: sweep)
            }

            // Glints off the rim.
            if across > 0.5 {
                for (x, y, size, phase) in [(cx - 19.0, cy - 22.0, 7.0, 0.10), (cx + 21.0, cy + 17.0, 5.0, 0.55)] {
                    let glow = ArtKit.twinkle(t, loop: Self.loop, times: 2, phase: phase)
                    ctx.fill(ArtKit.glint(at: p(x, y), radius: size * s * (0.4 + 0.6 * glow)), with: .color(.white.opacity(glow)))
                }
            }
        }
    }

    private static let hi = Color(red: 1, green: 0.86, blue: 0.50)
    private static let mid = Color(red: 0.97, green: 0.58, blue: 0.10)
    private static let lo = Color(red: 0.60, green: 0.28, blue: 0.02)
    private static let ink = Color(red: 0.28, green: 0.12, blue: 0)

    /// One face of the coin, flat, in units where the coin is 30 across from its middle to its rim: the front with the B, or
    /// the back with the pulse, with a sheen part-way (0 to 1) across it, or none.
    static func paintFace(_ l: inout GraphicsContext, front facingFront: Bool, sweep: Double, shadow: Bool = true) {
        let radius = 30.0
        let hi = Self.hi, mid = Self.mid, lo = Self.lo, ink = Self.ink
        let R = radius
        let disc = Path(ellipseIn: CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R))
        if shadow {
            l.drawLayer { shadowed in
                shadowed.addFilter(.shadow(color: .black.opacity(0.4), radius: 2.2, y: 1.4))
                shadowed.fill(disc, with: .color(lo))
            }
        }
        l.fill(disc, with: .linearGradient(Gradient(colors: [hi, mid, lo]),
                                           startPoint: CGPoint(x: -R * 0.7, y: -R * 0.85), endPoint: CGPoint(x: R * 0.7, y: R * 0.85)))
        l.stroke(disc, with: .color(ink.opacity(0.55)), lineWidth: 0.8)

        // The rim, minted with a ring of beads, and the groove inside it.
        for k in 0..<30 {
            let a = Double(k) / 30 * 2 * .pi
            let bead = Path(ellipseIn: CGRect(x: cos(a) * 26.2 - 0.8, y: sin(a) * 26.2 - 0.8, width: 1.6, height: 1.6))
            l.fill(bead, with: .color(hi.opacity(0.85)))
            l.fill(bead.offsetBy(dx: 0.3, dy: 0.4), with: .color(ink.opacity(0.25)))
        }
        let inner = Path(ellipseIn: CGRect(x: -22.5, y: -22.5, width: 45, height: 45))
        l.fill(inner, with: .linearGradient(Gradient(colors: [mid.opacity(0.9), hi.opacity(0.55)]),
                                            startPoint: CGPoint(x: -15, y: -20), endPoint: CGPoint(x: 15, y: 20)))
        l.stroke(inner, with: .color(ink.opacity(0.45)), lineWidth: 0.9)
        l.stroke(inner.offsetBy(dx: 0.3, dy: 0.7), with: .color(.white.opacity(0.35)), lineWidth: 0.5)

        // The mark on the face: the B on the front, the pulse on the back.
        let mark = facingFront ? Self.letter() : Self.pulse()
        let strokeStyle = StrokeStyle(lineWidth: facingFront ? 4.2 : 3.6, lineCap: facingFront ? .butt : .round, lineJoin: .round)
        l.stroke(mark.offsetBy(dx: 0.8, dy: 1.3), with: .color(ink.opacity(0.40)), style: strokeStyle)
        l.stroke(mark, with: .color(Color(red: 1, green: 0.98, blue: 0.93)), style: strokeStyle)

        // The sheen, a band of light sweeping across once the coin has settled, and the soft light up in a corner.
        l.drawLayer { shine in
            shine.clip(to: disc)
            if sweep > 0 && sweep < 1 {
                let u = -55 + 110 * sweep
                var band = Path()
                band.addLines([CGPoint(x: u - 3, y: -R - 4), CGPoint(x: u + 7, y: -R - 4), CGPoint(x: u - 7, y: R + 4), CGPoint(x: u - 17, y: R + 4)])
                shine.fill(band, with: .color(.white.opacity(0.42 * sin(sweep * .pi))))
            }
            shine.fill(Path(ellipseIn: CGRect(x: -R * 0.9, y: -R * 1.0, width: R * 1.1, height: R * 0.7)), with: .linearGradient(
                Gradient(colors: [.white.opacity(0.28), .clear]), startPoint: CGPoint(x: -R * 0.6, y: -R * 0.8), endPoint: CGPoint(x: -R * 0.2, y: -R * 0.2)))
        }
    }

    /// The B with a stroke above and below, a little tilted as on the coin everyone knows.
    private static func letter() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -7, y: -12)); path.addLine(to: CGPoint(x: -7, y: 12))
        path.move(to: CGPoint(x: -7, y: -12)); path.addLine(to: CGPoint(x: 3, y: -12))
        path.addCurve(to: CGPoint(x: 3, y: -0.5), control1: CGPoint(x: 11.5, y: -12), control2: CGPoint(x: 11.5, y: -0.5))
        path.addLine(to: CGPoint(x: -7, y: -0.5))
        path.move(to: CGPoint(x: -7, y: -0.5)); path.addLine(to: CGPoint(x: 5, y: -0.5))
        path.addCurve(to: CGPoint(x: 5, y: 12), control1: CGPoint(x: 15, y: -0.5), control2: CGPoint(x: 15, y: 12))
        path.addLine(to: CGPoint(x: -7, y: 12))
        for x in [-2.5, 2.5] {
            path.move(to: CGPoint(x: x, y: -17.5)); path.addLine(to: CGPoint(x: x, y: -12))
            path.move(to: CGPoint(x: x, y: 12)); path.addLine(to: CGPoint(x: x, y: 17.5))
        }
        return path.applying(CGAffineTransform(rotationAngle: 0.21))
    }

    /// Pulshade's pulse, on the back.
    private static func pulse() -> Path {
        var path = Path()
        path.addLines([CGPoint(x: -17, y: 1), CGPoint(x: -8, y: 1), CGPoint(x: -3.5, y: -11), CGPoint(x: 3, y: 11), CGPoint(x: 7, y: 1), CGPoint(x: 11, y: 1)])
        path.addEllipse(in: CGRect(x: 12.5, y: -0.5, width: 3, height: 3))
        return path
    }
}
