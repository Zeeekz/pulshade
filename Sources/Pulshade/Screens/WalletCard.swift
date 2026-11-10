import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import ImageIO
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// A wallet address sent from the pinned sheet ("My Bitcoin address:" then the address). Read back from the words
/// alone, so the card and its QR code always match the address written in the message, whatever picture came with it.
struct WalletMessage: Equatable {
    var kind: ProfileLinkKind
    var address: String

    init(kind: ProfileLinkKind, address: String) {
        self.kind = kind
        self.address = address
    }

    init?(text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 2, lines[0].hasPrefix("My "), lines[0].hasSuffix(" address:") else { return nil }
        let name = lines[0].dropFirst(3).dropLast(" address:".count)
        guard let kind = ProfileLinkKind.wallets.first(where: { $0.title == name }),
              kind.normalize(lines[1]) == lines[1] else { return nil }
        self.init(kind: kind, address: lines[1])
    }

    /// The words it's sent as, which older apps show under the picture.
    var text: String { "My \(kind.title) address:\n\(address)" }

    /// What the QR code holds. A Bitcoin one is a `bitcoin:` link, which wallet apps open ready to pay; the others
    /// are the address itself.
    var qrText: String { kind == .bitcoin ? "bitcoin:\(address)" : address }
}

/// The squares of a QR code, top row first.
struct QRMatrix {
    let size: Int
    private let cells: [Bool]

    init?(_ text: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // The highest level, so the logo over the middle still leaves it readable.
        filter.correctionLevel = "H"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let n = cg.width
        var pixels = [UInt8](repeating: 255, count: n * n)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }
        size = n
        cells = pixels.map { $0 < 128 }
    }

    func dark(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < size && y < size && cells[y * size + x]
    }

    /// The three big corner squares a scanner looks for. CoreImage leaves one empty square around the code.
    var finders: [(x: Int, y: Int)] {
        let edge = (0..<size).first { i in (0..<size).contains { dark($0, i) } } ?? 0
        return [(edge, edge), (size - edge - 7, edge), (edge, size - edge - 7)]
    }
}

/// A QR code drawn with soft round squares, corner eyes in the coin's colour and its logo in the middle.
struct StyledQR: View {
    var text: String
    var kind: ProfileLinkKind

    var body: some View {
        if let matrix = QRMatrix(text) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let unit = side / CGFloat(matrix.size)
                let logo = side * 0.24
                ZStack {
                    Canvas { ctx, _ in draw(matrix, unit: unit, logo: logo, side: side, in: &ctx) }
                    BrandTile(kind: kind, size: logo * 0.84)
                        .padding(logo * 0.08)
                        .background(.white, in: .rect(cornerRadius: logo * 0.3, style: .continuous))
                }
                .frame(width: side, height: side)
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("QR code")
        }
    }

    private func draw(_ m: QRMatrix, unit: CGFloat, logo: CGFloat, side: CGFloat, in ctx: inout GraphicsContext) {
        let finders = m.finders
        func inFinder(_ x: Int, _ y: Int) -> Bool {
            finders.contains { x >= $0.x && x < $0.x + 7 && y >= $0.y && y < $0.y + 7 }
        }
        let middle = CGRect(x: (side - logo) / 2, y: (side - logo) / 2, width: logo, height: logo).insetBy(dx: -unit * 0.4, dy: -unit * 0.4)
        let ink = GraphicsContext.Shading.color(WalletStyle.ink(kind))
        var dots = Path()
        for y in 0..<m.size {
            for x in 0..<m.size where m.dark(x, y) && !inFinder(x, y) {
                let r = CGRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit, width: unit, height: unit)
                if middle.intersects(r) { continue }
                dots.addRoundedRect(in: r.insetBy(dx: unit * 0.06, dy: unit * 0.06), cornerSize: CGSize(width: unit * 0.36, height: unit * 0.36))
            }
        }
        ctx.fill(dots, with: ink)
        let eye = GraphicsContext.Shading.linearGradient(Gradient(colors: WalletStyle.eye(kind)), startPoint: .zero,
                                                         endPoint: CGPoint(x: side, y: side))
        for f in finders {
            let outer = CGRect(x: CGFloat(f.x) * unit, y: CGFloat(f.y) * unit, width: unit * 7, height: unit * 7)
            var ring = Path(roundedRect: outer, cornerRadius: unit * 2.2, style: .continuous)
            ring.addPath(Path(roundedRect: outer.insetBy(dx: unit, dy: unit), cornerRadius: unit * 1.5, style: .continuous))
            ctx.fill(ring, with: eye, style: FillStyle(eoFill: true))
            ctx.fill(Path(roundedRect: outer.insetBy(dx: unit * 2, dy: unit * 2), cornerRadius: unit * 1.1, style: .continuous), with: ink)
        }
    }
}

enum WalletStyle {
    /// Dark enough on white for any camera to read, still tinted with the coin's colour.
    static func ink(_ kind: ProfileLinkKind) -> Color {
        switch kind {
        case .bitcoin: .hex(0x2A1600)
        case .monero: .hex(0x2B1000)
        case .ethereum: .hex(0x121A45)
        case .litecoin: .hex(0x0E1D38)
        case .solana: .hex(0x1E0A40)
        case .lightning: .hex(0x2B1D00)
        default: .hex(0x111111)
        }
    }

    /// The corner eyes: the coin's colour, deepened so it still reads as dark to a scanner.
    static func eye(_ kind: ProfileLinkKind) -> [Color] {
        switch kind {
        case .bitcoin: [.hex(0xD86F00), .hex(0x8F4500)]
        case .monero: [.hex(0xD45000), .hex(0x8A3000)]
        case .ethereum: [.hex(0x5468D8), .hex(0x2B3A99)]
        case .litecoin: [.hex(0x3D6BB5), .hex(0x1F3D73)]
        case .solana: [.hex(0x8E3BF0), .hex(0x0F8F66)]
        case .lightning: [.hex(0xC98A00), .hex(0x805500)]
        default: [.hex(0x444444), .hex(0x111111)]
        }
    }
}

/// A wallet address as a card: the coin's colours, its QR code on a white plate inside a slowly turning ring of
/// colour, and the address. In a chat a tap copies the address. Sent as a still picture too, for older apps.
struct WalletCard: View {
    var wallet: WalletMessage
    var width: CGFloat = 264
    /// Turning ring and passing shine. Off for the still picture and with Reduce Motion.
    var animated = true
    /// Shown in the pill at the bottom; nil hides it.
    var hint: String? = "Tap to copy"
    var copied = false
    /// What sits in the top corner: the time and ticks in a chat, a scan mark on the picture.
    var corner: AnyView? = nil

    @State private var spin = false
    @State private var shine = false

    private var colors: [Color] { wallet.kind.brandColors }
    /// Light sweeping round dark: shows up as it turns, even on a card of the same colour.
    private var ring: [Color] { [.white, colors[0], colors[colors.count - 1], WalletStyle.eye(wallet.kind)[1], colors[0], .white] }
    private var moving: Bool { animated && !Platform.reduceMotion }

    var body: some View {
        let plate = width * 0.72
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.22))
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.75)
                    if let data = wallet.kind.logoPath {
                        LogoShape(data: data).fill(.white).frame(width: 17, height: 17)
                    } else {
                        Image(systemName: wallet.kind.symbol).font(.system(size: 15, weight: .bold))
                    }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(wallet.kind.title).font(.system(size: 16, weight: .bold))
                    Text("Wallet address").font(.system(size: 11, weight: .medium)).opacity(0.75)
                }
                Spacer(minLength: 0)
                if let corner { corner } else {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 17, weight: .semibold)).opacity(0.8)
                }
            }
            .foregroundStyle(.white)

            ZStack {
                // The ring of colour around the plate.
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(AngularGradient(colors: ring, center: .center,
                                          angle: .degrees(spin ? 360 : 0)))
                    .frame(width: plate + 8, height: plate + 8)
                    .blur(radius: 6)
                    .opacity(0.9)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AngularGradient(colors: ring, center: .center,
                                          angle: .degrees(spin ? 360 : 0)))
                    .frame(width: plate + 5, height: plate + 5)
                StyledQR(text: wallet.qrText, kind: wallet.kind)
                    .padding(plate * 0.06)
                    .frame(width: plate, height: plate)
                    .background(.white, in: .rect(cornerRadius: 22, style: .continuous))
            }
            .animation(moving ? .linear(duration: 7).repeatForever(autoreverses: false) : nil, value: spin)

            Text(wallet.address)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)

            if let hint {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark" : animated ? "doc.on.doc" : "qrcode")
                        .contentTransition(.symbolEffect(.replace))
                    Text(copied ? "Address copied" : hint)
                        .contentTransition(.opacity)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.white.opacity(copied ? 0.3 : 0.18), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
            }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, hint == nil ? 18 : 14)
        .frame(width: width)
        .background {
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                // A soft light from the top corner, so it isn't a flat slab of colour.
                RadialGradient(colors: [.white.opacity(0.28), .clear], center: .topLeading, startRadius: 0, endRadius: width * 0.9)
                RadialGradient(colors: [.black.opacity(0.22), .clear], center: .bottomTrailing, startRadius: 0, endRadius: width * 0.8)
                if moving {
                    // A band of light that passes over now and then.
                    LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width * 0.45)
                        .rotationEffect(.degrees(20))
                        .offset(x: shine ? width * 1.1 : -width * 1.1)
                        .animation(.easeInOut(duration: 1.6).delay(2.6).repeatForever(autoreverses: false), value: shine)
                        .blendMode(.plusLighter)
                }
            }
        }
        .clipped()
        .onAppear {
            guard moving else { return }
            spin = true
            shine = true
        }
    }

    /// The card as a still picture to send, so apps from before cards show it too. The scanner check in the tests
    /// reads this exact picture.
    @MainActor static func picture(_ wallet: WalletMessage) -> Data? {
        let card = WalletCard(wallet: wallet, width: 300, animated: false, hint: "Scan to pay")
            .clipShape(.rect(cornerRadius: 28, style: .continuous))
            .padding(1)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        renderer.isOpaque = false
        guard let cg = renderer.cgImage else { return nil }
        // Flattened onto the chat's dark grey: JPEG has no see-through corners.
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let flat = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
