import SwiftUI

/// Pulshade's own love heart: a heart with a heartbeat running through it, drawn rather than the system's emoji. It
/// is what a ❤️ reaction looks like here. On the wire a reaction is still the plain ❤️, so everyone else's app shows
/// theirs.

/// The heart's outline.
struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.92))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.04, y: rect.minY + h * 0.36),
                   control1: CGPoint(x: rect.minX + w * 0.22, y: rect.minY + h * 0.78),
                   control2: CGPoint(x: rect.minX + w * 0.04, y: rect.minY + h * 0.58))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.2),
                   control1: CGPoint(x: rect.minX + w * 0.04, y: rect.minY + h * 0.14),
                   control2: CGPoint(x: rect.minX + w * 0.38, y: rect.minY + h * 0.1))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.96, y: rect.minY + h * 0.36),
                   control1: CGPoint(x: rect.minX + w * 0.62, y: rect.minY + h * 0.1),
                   control2: CGPoint(x: rect.minX + w * 0.96, y: rect.minY + h * 0.14))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.92),
                   control1: CGPoint(x: rect.minX + w * 0.96, y: rect.minY + h * 0.58),
                   control2: CGPoint(x: rect.minX + w * 0.78, y: rect.minY + h * 0.78))
        p.closeSubpath()
        return p
    }
}

/// The heartbeat: flat, a small rise, a tall spike up, a deep one down, and flat again.
struct HeartbeatLine: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let points: [(CGFloat, CGFloat)] = [(0, 0.5), (0.26, 0.5), (0.34, 0.42), (0.40, 0.5), (0.47, 0.12), (0.56, 0.86),
                                            (0.63, 0.5), (0.70, 0.5), (0.76, 0.4), (0.82, 0.5), (1, 0.5)]
        var p = Path()
        for (i, point) in points.enumerated() {
            let at = CGPoint(x: rect.minX + w * point.0, y: rect.minY + h * point.1)
            if i == 0 { p.move(to: at) } else { p.addLine(to: at) }
        }
        return p
    }
}

/// The heart with its beat through it. `drawn` runs the line across from nothing to all of it.
struct PulseHeart: View {
    var size: CGFloat
    /// How much of the line is drawn, 0 to 1.
    var drawn: CGFloat = 1

    var body: some View {
        ZStack {
            HeartShape()
                .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.36, blue: 0.45), Color(red: 0.86, green: 0.1, blue: 0.34)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay { HeartShape().fill(LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .topLeading, endPoint: .center)) }
            HeartbeatLine()
                .trim(from: 0, to: drawn)
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.2, size * 0.075), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.84, height: size * 0.6)
                .offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// What appears over a message when it's double-tapped: the heart pops up, its beat runs across, and it fades. Plays
/// each time `trigger` changes. With Reduce Motion on it just fades in and out.
struct HeartBurst: View {
    var trigger: Int
    var size: CGFloat = 92

    private struct Beat {
        var scale = 0.2
        var opacity = 0.0
        var line = 0.0
    }

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .keyframeAnimator(initialValue: Beat(), trigger: trigger) { _, beat in
                PulseHeart(size: size, drawn: beat.line).scaleEffect(beat.scale).opacity(beat.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(Platform.reduceMotion ? 1 : 1.25, duration: 0.18)
                    SpringKeyframe(1.0, duration: 0.22, spring: .bouncy)
                    CubicKeyframe(1.0, duration: 0.45)
                    CubicKeyframe(Platform.reduceMotion ? 1 : 1.12, duration: 0.2)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.1)
                    LinearKeyframe(1, duration: 0.7)
                    LinearKeyframe(0, duration: 0.25)
                }
                KeyframeTrack(\.line) {
                    LinearKeyframe(0, duration: 0.12)
                    LinearKeyframe(1, duration: 0.55)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
