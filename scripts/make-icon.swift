// Renders the Pulshade app icon: swift scripts/make-icon.swift Resources/AppIcon.icns
import SwiftUI
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

func c(_ hex: UInt32, _ a: Double = 1) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: a)
}

/// One clean heartbeat: flat, a single sharp spike, flat again.
struct Beat: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(0, 0.5), (0.3, 0.5), (0.42, 0.06), (0.58, 0.94), (0.7, 0.5), (1, 0.5)]
        var p = Path()
        for (i, pt) in pts.enumerated() {
            let q = CGPoint(x: r.minX + pt.0 * r.width, y: r.minY + pt.1 * r.height)
            i == 0 ? p.move(to: q) : p.addLine(to: q)
        }
        return p
    }
}

/// A round speech bubble with a short tail at the bottom left.
struct Bubble: Shape {
    func path(in r: CGRect) -> Path {
        let circle = Path(ellipseIn: r)
        var tail = Path()
        tail.move(to: CGPoint(x: r.minX + r.width * 0.10, y: r.minY + r.height * 0.64))
        tail.addLine(to: CGPoint(x: r.minX + r.width * 0.02, y: r.minY + r.height * 0.98))
        tail.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.minY + r.height * 0.92))
        tail.closeSubpath()
        return circle.union(tail)
    }
}

struct Icon: View {
    /// iOS icons are full squares (iOS rounds the corners itself) with no transparency.
    var bleed = false
    let ink = c(0x0A0A0F), teal = c(0x2EF2C8), violet = c(0x6A5CFF)

    var body: some View {
        let side: CGFloat = bleed ? 1024 : 824
        let scale = side / 1024
        ZStack {
            RoundedRectangle(cornerRadius: bleed ? 0 : 186, style: .continuous)
                .fill(LinearGradient(colors: [c(0x1A1A24), ink], startPoint: .top, endPoint: .bottom))
                .overlay {
                    ZStack {
                        Bubble()
                            .fill(LinearGradient(colors: [teal, violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 600, height: 600)
                        // The pulse, cut out of the bubble in the background colour.
                        Beat()
                            .stroke(ink, style: StrokeStyle(lineWidth: 52, lineCap: .round, lineJoin: .round))
                            .frame(width: 400, height: 270)
                    }
                    .offset(x: 12, y: -6)
                    .scaleEffect(scale)
                }
                .overlay {
                    // A hairline of light along the top edge, as on Apple's own icons.
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center),
                                      lineWidth: 2)
                        .opacity(bleed ? 0 : 1)
                }
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(bleed ? 0 : 0.4), radius: 20, y: 12)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render(_ size: Int, bleed: Bool = false) -> Data {
    let renderer = ImageRenderer(content: Icon(bleed: bleed))
    renderer.isOpaque = bleed
    renderer.scale = CGFloat(size) / 1024
    let cg = renderer.cgImage!
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
}

MainActor.assumeIsolated {
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Pulshade.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    try! render(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
    let iosIcon = URL(fileURLWithPath: "ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    try? FileManager.default.createDirectory(at: iosIcon.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! render(1024, bleed: true).write(to: iosIcon)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", out]
    try! task.run()
    task.waitUntilExit()
    print(task.terminationStatus == 0 ? "Wrote \(out)" : "iconutil failed")
}
