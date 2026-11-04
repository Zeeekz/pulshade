import SwiftUI

/// What the collectibles' drawings have in common.
enum ArtKit {
    /// The same "random" number for the same particle every frame.
    static func noise(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i * 127 + salt * 311) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }

    /// A star with `points` points, `outer` from the middle to a tip and `inner` to a notch, turned by `rotation`.
    static func star(at c: CGPoint, outer: CGFloat, inner: CGFloat, points: Int = 5, rotation: Double = -.pi / 2) -> Path {
        var path = Path()
        for i in 0..<(points * 2) {
            let radius = i % 2 == 0 ? outer : inner
            let angle = Double(i) * .pi / Double(points) + rotation
            let point = CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// A four-pointed glint, the kind that flashes off polished things.
    static func glint(at c: CGPoint, radius: CGFloat) -> Path {
        star(at: c, outer: radius, inner: radius * 0.16, points: 4, rotation: 0)
    }

    /// A glint that swells and fades once every `loop / times` seconds, offset by `phase` (0 to 1) of that.
    static func twinkle(_ time: Double, loop: Double, times: Int, phase: Double) -> Double {
        let wave = sin(2 * .pi * (time / loop * Double(times) - phase))
        return pow(max(0, wave), 3)
    }
}
