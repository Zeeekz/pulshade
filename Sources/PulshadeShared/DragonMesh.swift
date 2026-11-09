import SwiftUI
import SceneKit
import simd

#if os(macOS)
import AppKit
typealias DragonColor = NSColor
typealias DragonImage = NSImage
#else
import UIKit
typealias DragonColor = UIColor
typealias DragonImage = UIImage
#endif

/// A colour of the dragon, or of the rare golden one: the blues turned round, so what was blue becomes red and green
/// and what was red fades.
func dcTone(_ golden: Bool, _ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> DragonColor {
    guard golden else { return dc(r, g, b, a) }
    let red: Double = min(1.0, b + 0.04)
    let green: Double = min(1.0, 0.78 * b + 0.2 * g)
    let blue: Double = 0.5 * r
    return dc(red, green, blue, a)
}

func dc(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> DragonColor {
    DragonColor(red: r, green: g, blue: b, alpha: a)
}

/// Shapes for Pulze The Dragon, made in code: smooth tubes swept along a curve, flat wing membranes, cones for horns,
/// claws and spikes, and the scaly texture that covers it. Nothing is loaded from a file, so it stays sharp at any size.
enum DragonMesh {
    typealias V3 = SIMD3<Float>
    typealias V4 = SIMD4<Float>

    // MARK: Maths

    static func catmull(_ p0: V3, _ p1: V3, _ p2: V3, _ p3: V3, _ u: Float) -> V3 {
        let u2 = u * u, u3 = u2 * u
        let a = 2 * p1
        let b = (p2 - p0) * u
        let c = (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2
        let d = (3 * p1 - p0 - 3 * p2 + p3) * u3
        return 0.5 * (a + b + c + d)
    }

    static func catmull(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ u: Float) -> Float {
        let u2 = u * u, u3 = u2 * u
        return 0.5 * (2 * p1 + (p2 - p0) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2 + (3 * p1 - p0 - 3 * p2 + p3) * u3)
    }

    static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func mix(_ a: V4, _ b: V4, _ t: Float) -> V4 { a + (b - a) * t }

    static func data<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }

    // MARK: Paths

    /// A smooth curve through `pts` with a radius at each, sampled finely.
    struct Sampled {
        var path: [V3] = [], radius: [Float] = [], tangent: [V3] = [], arc: [Float] = []
        var count: Int { path.count }
        var length: Float { max(arc.last ?? 0, 0.001) }
    }

    static func sample(_ pts: [V3], _ radii: [Float], per: Int = 10) -> Sampled {
        var s = Sampled()
        for i in 0..<(pts.count - 1) {
            let a = pts[max(i - 1, 0)], b = pts[i], c = pts[i + 1], d = pts[min(i + 2, pts.count - 1)]
            let ra = radii[max(i - 1, 0)], rb = radii[i], rc = radii[i + 1], rd = radii[min(i + 2, radii.count - 1)]
            for j in 0..<per {
                let u = Float(j) / Float(per)
                s.path.append(catmull(a, b, c, d, u))
                s.radius.append(max(0.002, catmull(ra, rb, rc, rd, u)))
            }
        }
        s.path.append(pts[pts.count - 1]); s.radius.append(radii[radii.count - 1])
        let n = s.path.count
        for i in 0..<n { s.tangent.append(simd_normalize(s.path[min(i + 1, n - 1)] - s.path[max(i - 1, 0)])) }
        s.arc = [Float](repeating: 0, count: n)
        for i in 1..<n { s.arc[i] = s.arc[i - 1] + simd_length(s.path[i] - s.path[i - 1]) }
        return s
    }

    // MARK: Tubes

    private struct Ring { var c: V3, n: V3, b: V3, t: V3, r: Float, radial: Float, lean: Float, v: Float, f: Float }

    /// A tube along `pts`, `radii` wide at each, rounded at the ends that ask for it, textured with scales and tinted by
    /// `tint(normal, fractionAlong)`.
    static func tube(_ pts: [V3], _ radii: [Float], sides: Int = 20, per: Int = 10, capStart: Bool = false, capEnd: Bool = true,
                     scaleSize: Float = 0.07, tint: (V3, Float) -> V4) -> SCNGeometry {
        let s = sample(pts, radii, per: per)
        let n = s.count
        var rings: [Ring] = []
        let ref: V3 = abs(s.tangent[0].y) < 0.9 ? V3(0, 1, 0) : V3(1, 0, 0)
        var nrm = simd_normalize(simd_cross(ref, s.tangent[0]))
        var frames: [(V3, V3)] = []
        for i in 0..<n {
            nrm = simd_normalize(nrm - simd_dot(nrm, s.tangent[i]) * s.tangent[i])
            frames.append((nrm, simd_cross(s.tangent[i], nrm)))
        }
        let caps: [Float] = [90, 70, 45, 20].map { $0 * .pi / 180 }
        if capStart {
            for phi in caps {
                let r = s.radius[0]
                rings.append(Ring(c: s.path[0] - s.tangent[0] * r * sin(phi), n: frames[0].0, b: frames[0].1, t: s.tangent[0], r: r * cos(phi),
                                  radial: cos(phi), lean: -sin(phi), v: -r * (.pi / 2 - phi) / (scaleSize * 8), f: 0))
            }
        }
        for i in 0..<n {
            let slope = (s.radius[min(i + 1, n - 1)] - s.radius[max(i - 1, 0)]) / max(s.arc[min(i + 1, n - 1)] - s.arc[max(i - 1, 0)], 0.0001)
            rings.append(Ring(c: s.path[i], n: frames[i].0, b: frames[i].1, t: s.tangent[i], r: s.radius[i], radial: 1, lean: -slope,
                              v: s.arc[i] / (scaleSize * 8), f: s.arc[i] / s.length))
        }
        if capEnd {
            for phi in caps.reversed() {
                let r = s.radius[n - 1]
                rings.append(Ring(c: s.path[n - 1] + s.tangent[n - 1] * r * sin(phi), n: frames[n - 1].0, b: frames[n - 1].1, t: s.tangent[n - 1], r: r * cos(phi),
                                  radial: cos(phi), lean: sin(phi), v: (s.arc[n - 1] + r * (.pi / 2 - phi)) / (scaleSize * 8), f: 1))
            }
        }
        let meanRadius = s.radius.reduce(0, +) / Float(n)
        let around = max(1, (2 * Float.pi * meanRadius / (scaleSize * 8)).rounded())

        var positions: [V3] = [], normals: [V3] = [], uvs: [SIMD2<Float>] = [], colours: [V4] = [], indices: [UInt32] = []
        for ring in rings {
            for k in 0...sides {
                let theta = 2 * Float.pi * Float(k) / Float(sides)
                let d = cos(theta) * ring.n + sin(theta) * ring.b
                let normal = simd_normalize(d * ring.radial + ring.t * ring.lean)
                positions.append(ring.c + d * ring.r)
                normals.append(normal)
                uvs.append(SIMD2(Float(k) / Float(sides) * around, ring.v))
                colours.append(tint(normal, ring.f))
            }
        }
        let stride = sides + 1
        for j in 0..<(rings.count - 1) {
            for k in 0..<sides {
                let a = UInt32(j * stride + k), b = a + 1, c = a + UInt32(stride), d = c + 1
                indices += [a, b, c, b, d, c]
            }
        }
        return geometry(positions, normals, uvs, colours, indices)
    }

    static func geometry(_ positions: [V3], _ normals: [V3], _ uvs: [SIMD2<Float>]?, _ colours: [V4], _ indices: [UInt32]) -> SCNGeometry {
        var sources = [
            SCNGeometrySource(data: data(positions), semantic: .vertex, vectorCount: positions.count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<V3>.stride),
            SCNGeometrySource(data: data(normals), semantic: .normal, vectorCount: normals.count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<V3>.stride),
            SCNGeometrySource(data: data(colours), semantic: .color, vectorCount: colours.count, usesFloatComponents: true,
                              componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<V4>.stride),
        ]
        if let uvs {
            sources.append(SCNGeometrySource(data: data(uvs), semantic: .texcoord, vectorCount: uvs.count, usesFloatComponents: true,
                                             componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.stride))
        }
        return SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    // MARK: Membrane

    /// Flat triangles drawn from both sides, so a wing is lit properly whichever way it faces the viewer.
    static func membrane(_ triangles: [(V3, V3, V3)], tint: (V3) -> V4) -> SCNGeometry {
        var positions: [V3] = [], normals: [V3] = [], colours: [V4] = [], indices: [UInt32] = []
        let lift: Float = 0.004
        for (a, b, c) in triangles {
            let n = simd_normalize(simd_cross(b - a, c - a))
            let base = UInt32(positions.count)
            for p in [a, b, c] { positions.append(p + n * lift); normals.append(n); colours.append(tint(p)) }
            for p in [a, c, b] { positions.append(p - n * lift); normals.append(-n); colours.append(tint(p)) }
            indices += [base, base + 1, base + 2, base + 3, base + 4, base + 5]
        }
        return geometry(positions, normals, nil, colours, indices)
    }

    // MARK: Cones and spheres

    static func cone(from: V3, to: V3, radius: Float, material: SCNMaterial) -> SCNNode {
        let dir = to - from, length = simd_length(dir)
        let geometry = SCNCone(topRadius: 0, bottomRadius: CGFloat(radius), height: CGFloat(length))
        geometry.radialSegmentCount = 12
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = (from + to) / 2
        node.simdOrientation = simd_quatf(from: V3(0, 1, 0), to: dir / length)
        return node
    }

    static func ball(at p: V3, radius: Float, scale: V3 = V3(1, 1, 1), material: SCNMaterial) -> SCNNode {
        let geometry = SCNSphere(radius: CGFloat(radius))
        geometry.segmentCount = 72
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = p
        node.simdScale = scale
        return node
    }

    // MARK: Scales

    /// A tile of overlapping scales, light in the middle and dark at the rim, to be multiplied with the skin colour.
    static func scaleTexture() -> CGImage {
        let size = 256, cell = 32.0
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.40, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: 1.0, alpha: 1), CGColor(gray: 0.86, alpha: 1), CGColor(gray: 0.50, alpha: 1)] as CFArray,
                                  locations: [0, 0.55, 1])!
        // Lowest row first, so each row's scales overlap the one below, like tiles on a roof.
        for row in 0..<8 {
            for col in 0..<8 {
                for dx in [-1.0, 0.0, 1.0] {
                    for dy in [-1.0, 0.0, 1.0] {
                        let cx = (Double(col) + (row % 2 == 0 ? 0.5 : 1.0)) * cell + dx * Double(size)
                        let cy = (Double(row) + 0.5) * cell + dy * Double(size)
                        let rect = CGRect(x: cx - cell * 0.62, y: cy - cell * 0.68, width: cell * 1.24, height: cell * 1.36)
                        guard rect.maxX > 0, rect.minX < Double(size), rect.maxY > 0, rect.minY < Double(size) else { continue }
                        ctx.saveGState()
                        ctx.addEllipse(in: rect)
                        ctx.clip()
                        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: cx, y: cy + cell * 0.22), startRadius: 0,
                                               endCenter: CGPoint(x: cx, y: cy + cell * 0.05), endRadius: cell * 0.72, options: [])
                        ctx.restoreGState()
                        ctx.setStrokeColor(CGColor(gray: 0.22, alpha: 0.9))
                        ctx.setLineWidth(1.6)
                        ctx.strokeEllipse(in: rect)
                    }
                }
            }
        }
        return ctx.makeImage()!
    }

    /// A soft round dot, white in the middle and clear at the rim, for sparks and glows.
    static func glowImage() -> CGImage {
        let size = 64
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 0.5), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                                  locations: [0, 0.35, 1])!
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 32, y: 32), startRadius: 0, endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
        return ctx.makeImage()!
    }

    /// The wall of a cave: dark rock, an electric blue glow coming up from below, stalactites hanging from the roof and stalagmites
    /// rising at the sides, a vignette round the edge.
    static func lairImage() -> CGImage {
        let w = 1024, h = 768
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let space = CGColorSpaceCreateDeviceRGB()
        let wall = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.08, green: 0.11, blue: 0.24, alpha: 1), CGColor(red: 0.05, green: 0.07, blue: 0.16, alpha: 1), CGColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1),
        ] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(wall, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        // Rock: soft dark and warm patches, all over.
        for i in 0..<220 {
            let x = noise(i, 1) * Double(w), y = noise(i, 2) * Double(h), size = 50 + noise(i, 3) * 150
            let dark = noise(i, 4) < 0.6
            ctx.setFillColor(dark ? CGColor(red: 0, green: 0, blue: 0, alpha: 0.10 + noise(i, 5) * 0.10)
                                  : CGColor(red: 0.30, green: 0.40, blue: 0.80, alpha: 0.03 + noise(i, 5) * 0.04))
            ctx.fillEllipse(in: CGRect(x: x - size / 2, y: y - size * 0.35, width: size, height: size * 0.7))
        }
        // The glow of the hoard, low in the middle, and a warm haze up the wall.
        let fire = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.30, green: 0.55, blue: 1, alpha: 0.60), CGColor(red: 0.20, green: 0.30, blue: 0.85, alpha: 0.22), CGColor(red: 0.10, green: 0.10, blue: 0.5, alpha: 0),
        ] as CFArray, locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(fire, startCenter: CGPoint(x: Double(w) / 2, y: 130), startRadius: 0, endCenter: CGPoint(x: Double(w) / 2, y: 130), endRadius: 620, options: [])
        // Stalactites from the roof and stalagmites from the floor.
        ctx.setFillColor(CGColor(red: 0.03, green: 0.02, blue: 0.04, alpha: 1))
        for i in 0..<16 {
            let x = (Double(i) + noise(i, 8) * 0.8) / 16 * Double(w), width = 50 + noise(i, 9) * 90, length = 60 + noise(i, 10) * 190
            ctx.move(to: CGPoint(x: x - width / 2, y: Double(h) + 2))
            ctx.addLine(to: CGPoint(x: x + width / 2, y: Double(h) + 2))
            ctx.addLine(to: CGPoint(x: x + (noise(i, 11) - 0.5) * 14, y: Double(h) - length))
            ctx.fillPath()
        }
        for i in 0..<7 {
            let left = i < 4
            let x = left ? Double(i) * 70 + 20 : Double(w) - Double(i - 3) * 80 + 20
            let width = 60 + noise(i, 12) * 70, height = 120 + noise(i, 13) * 220
            ctx.move(to: CGPoint(x: x - width / 2, y: -2))
            ctx.addLine(to: CGPoint(x: x + width / 2, y: -2))
            ctx.addLine(to: CGPoint(x: x + (noise(i, 14) - 0.5) * 16, y: height))
            ctx.fillPath()
        }
        // A dark vignette round the edge.
        let vignette = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0), CGColor(red: 0, green: 0, blue: 0, alpha: 0.62),
        ] as CFArray, locations: [0.45, 1])!
        ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: Double(w) / 2, y: Double(h) / 2), startRadius: 0,
                               endCenter: CGPoint(x: Double(w) / 2, y: Double(h) / 2), endRadius: 640, options: [.drawsAfterEndLocation])
        return ctx.makeImage()!
    }

    /// The scales as a bump map: the scale tile read as a height field and turned into surface directions, so the light
    /// catches each scale's edge.
    static func scaleNormalMap() -> CGImage {
        let size = 256
        let space = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let source = scaleTexture()
        let height: [Float] = pixels.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
            return (0..<(size * size)).map { Float(raw[$0 * 4]) / 255 }
        }
        func h(_ x: Int, _ y: Int) -> Float { height[((y + size) % size) * size + ((x + size) % size)] }
        var out = [UInt8](repeating: 255, count: size * size * 4)
        let strength: Float = 3.2
        for y in 0..<size {
            for x in 0..<size {
                let dx = (h(x + 1, y) - h(x - 1, y)) * strength, dy = (h(x, y + 1) - h(x, y - 1)) * strength
                let n = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
                let i = (y * size + x) * 4
                out[i] = UInt8((n.x * 0.5 + 0.5) * 255); out[i + 1] = UInt8((n.y * 0.5 + 0.5) * 255); out[i + 2] = UInt8((n.z * 0.5 + 0.5) * 255)
            }
        }
        let provider = CGDataProvider(data: Data(out) as CFData)!
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// A photographer's studio to reflect: a dark blue room with soft light boxes above and either side, so glossy surfaces
    /// pick up long, soft highlights.
    static func studioImage() -> CGImage {
        let w = 1024, h = 512
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let room = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.30, green: 0.40, blue: 0.62, alpha: 1), CGColor(red: 0.08, green: 0.10, blue: 0.20, alpha: 1), CGColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1),
        ] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(room, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        // Soft boxes: bright, with the edge fading out in a few steps.
        func box(_ x: Double, _ y: Double, _ bw: Double, _ bh: Double, _ colour: (Double, Double, Double), _ alpha: Double) {
            for k in 0..<6 {
                let grow = Double(k) * 10
                ctx.setFillColor(CGColor(red: colour.0, green: colour.1, blue: colour.2, alpha: alpha / 5.0))
                ctx.fill(CGRect(x: x - grow, y: y - grow, width: bw + grow * 2, height: bh + grow * 2))
            }
        }
        box(300, 330, 420, 120, (1, 1, 1), 0.95)
        box(60, 160, 90, 250, (0.7, 0.9, 1), 0.85)
        box(860, 150, 90, 260, (0.85, 0.7, 1), 0.8)
        box(480, 100, 220, 40, (1, 0.95, 0.9), 0.6)
        return ctx.makeImage()!
    }
}
