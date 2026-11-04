import SwiftUI
#if canImport(PulshadeShared)
import PulshadeShared
#endif

// MARK: - Drawing a logo from SVG path data

/// Turns SVG path data (M L H V C S Q T A Z, absolute and relative) into a SwiftUI `Path`. Logos are one path each.
enum SVGPath {
    static func path(_ d: String) -> Path {
        var reader = Reader(Array(d))
        var path = Path()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var cmd: Character = "M"

        while true {
            if let next = reader.command() { cmd = next } else if !reader.hasNumber() { break }
            let rel = cmd.isLowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            switch cmd.uppercased().first! {
            case "M":
                guard let x = reader.number(), let y = reader.number() else { return path }
                cur = pt(x, y); start = cur; path.move(to: cur)
                cmd = rel ? "l" : "L"   // more pairs after a move are lines
                lastCubic = nil; lastQuad = nil
            case "L":
                guard let x = reader.number(), let y = reader.number() else { return path }
                cur = pt(x, y); path.addLine(to: cur); lastCubic = nil; lastQuad = nil
            case "H":
                guard let x = reader.number() else { return path }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur); lastCubic = nil; lastQuad = nil
            case "V":
                guard let y = reader.number() else { return path }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur); lastCubic = nil; lastQuad = nil
            case "C":
                guard let a = reader.number(), let b = reader.number(), let c = reader.number(), let d = reader.number(),
                      let e = reader.number(), let f = reader.number() else { return path }
                let c1 = pt(a, b), c2 = pt(c, d), end = pt(e, f)
                path.addCurve(to: end, control1: c1, control2: c2); lastCubic = c2; lastQuad = nil; cur = end
            case "S":
                guard let c = reader.number(), let d = reader.number(), let e = reader.number(), let f = reader.number() else { return path }
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(c, d), end = pt(e, f)
                path.addCurve(to: end, control1: c1, control2: c2); lastCubic = c2; lastQuad = nil; cur = end
            case "Q":
                guard let a = reader.number(), let b = reader.number(), let e = reader.number(), let f = reader.number() else { return path }
                let c1 = pt(a, b), end = pt(e, f)
                path.addQuadCurve(to: end, control: c1); lastQuad = c1; lastCubic = nil; cur = end
            case "T":
                guard let e = reader.number(), let f = reader.number() else { return path }
                let c1 = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let end = pt(e, f)
                path.addQuadCurve(to: end, control: c1); lastQuad = c1; lastCubic = nil; cur = end
            case "A":
                guard let rx = reader.number(), let ry = reader.number(), let rot = reader.number(),
                      let large = reader.flag(), let sweep = reader.flag(), let x = reader.number(), let y = reader.number()
                else { return path }
                let end = pt(x, y)
                arc(&path, from: cur, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, to: end)
                cur = end; lastCubic = nil; lastQuad = nil
            case "Z":
                path.closeSubpath(); cur = start; lastCubic = nil; lastQuad = nil
            default:
                return path
            }
        }
        return path
    }

    /// An elliptical arc as up to four-per-turn cubic curves (SVG 1.1 appendix F.6).
    private static func arc(_ path: inout Path, from p0: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, rotation: CGFloat,
                            large: Bool, sweep: Bool, to p1: CGPoint) {
        var rx = abs(rx0), ry = abs(ry0)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat { atan2(ux * vy - uy * vx, ux * vx + uy * vy) }
        let ux = (x1 - cxp) / rx, uy = (y1 - cyp) / ry
        let theta = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
        let step = delta / CGFloat(segments), k = 4 / 3 * tan(step / 4)
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * x * cosP - ry * y * sinP, y: cy + rx * x * sinP + ry * y * cosP)
        }
        var t = theta
        for _ in 0..<segments {
            let c1 = cos(t), s1 = sin(t), c2 = cos(t + step), s2 = sin(t + step)
            path.addCurve(to: at(c2, s2), control1: at(c1 - k * s1, s1 + k * c1), control2: at(c2 + k * s2, s2 - k * c2))
            t += step
        }
    }

    private struct Reader {
        let s: [Character]
        var i = 0
        init(_ s: [Character]) { self.s = s }
        mutating func skip() { while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" { i += 1 } }
        mutating func command() -> Character? {
            skip()
            guard i < s.count, s[i].isLetter, s[i] != "e", s[i] != "E" else { return nil }
            defer { i += 1 }
            return s[i]
        }
        mutating func hasNumber() -> Bool {
            skip()
            guard i < s.count else { return false }
            return s[i].isNumber || s[i] == "-" || s[i] == "+" || s[i] == "."
        }
        mutating func number() -> CGFloat? {
            skip()
            let begin = i
            if i < s.count, s[i] == "-" || s[i] == "+" { i += 1 }
            var dot = false
            while i < s.count {
                if s[i].isNumber { i += 1 } else if s[i] == ".", !dot { dot = true; i += 1 } else { break }
            }
            if i < s.count, s[i] == "e" || s[i] == "E" {
                i += 1
                if i < s.count, s[i] == "-" || s[i] == "+" { i += 1 }
                while i < s.count, s[i].isNumber { i += 1 }
            }
            return Double(String(s[begin..<i])).map { CGFloat($0) }
        }
        /// Arc flags are a single 0 or 1 and may have no space after them.
        mutating func flag() -> Bool? {
            skip()
            guard i < s.count, s[i] == "0" || s[i] == "1" else { return nil }
            defer { i += 1 }
            return s[i] == "1"
        }
    }
}

/// A logo scaled to fit its frame (the data is drawn in a 24 x 24 box).
struct LogoShape: Shape {
    var data: String
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 24
        return SVGPath.path(data).applying(CGAffineTransform(translationX: 0, y: 0).scaledBy(x: scale, y: scale))
            .offsetBy(dx: rect.minX + (rect.width - side) / 2, dy: rect.minY + (rect.height - side) / 2)
    }
}

// MARK: - Brand colours and the tile

extension ProfileLinkKind {
    /// The brand's colour (or colours, top to bottom) behind its logo. Dark brands get a deep grey, not pure black.
    var brandColors: [Color] {
        switch self {
        case .x: [.hex(0x2B2B2F), .hex(0x0E0E10)]
        case .instagram: [.hex(0xFEDA77), .hex(0xF58529), .hex(0xDD2A7B), .hex(0x8134AF), .hex(0x515BD4)]
        case .youtube: [.hex(0xFF3B3B), .hex(0xD90000)]
        case .tiktok: [.hex(0x2B2B2F), .hex(0x0E0E10)]
        case .github: [.hex(0x3A3F47), .hex(0x1B1F24)]
        case .telegram: [.hex(0x3FB8F0), .hex(0x1C93D6)]
        case .discord: [.hex(0x7983F5), .hex(0x4752C4)]
        case .nostr: [.hex(0xA855F7), .hex(0x7B2CBF)]
        case .mastodon: [.hex(0x7C7DFF), .hex(0x4E4FD6)]
        case .linkedin: [.hex(0x2F8AD8), .hex(0x0A66C2)]
        case .twitch: [.hex(0xA970FF), .hex(0x7A3FE0)]
        case .bitcoin: [.hex(0xFFA83A), .hex(0xE8800C)]
        case .monero: [.hex(0xFF8533), .hex(0xE05400)]
        case .ethereum: [.hex(0x8A9DF0), .hex(0x4B64CF)]
        case .litecoin: [.hex(0x5B86C8), .hex(0x2F5598)]
        case .solana: [.hex(0x9945FF), .hex(0x14C98F)]
        case .lightning: [.hex(0xFFD23A), .hex(0xF2A100)]
        case .website, .custom, .unknown: [.hex(0x5B6475), .hex(0x373E4D)]
        }
    }
}

/// A rounded tile in the brand's colour with its logo in white: the mark that sits next to every link and wallet.
struct BrandTile: View {
    var kind: ProfileLinkKind
    var size: CGFloat = 40

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: kind.brandColors, startPoint: kind == .instagram ? .bottomLeading : .top,
                                      endPoint: kind == .instagram ? .topTrailing : .bottom))
            if let data = kind.logoPath {
                LogoShape(data: data).fill(.white).frame(width: size * 0.5, height: size * 0.5)
            } else {
                Image(systemName: kind.symbol).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
        .shadow(color: kind.brandColors.last?.opacity(0.28) ?? .clear, radius: size * 0.14, y: size * 0.05)
        .accessibilityHidden(true)
    }
}
