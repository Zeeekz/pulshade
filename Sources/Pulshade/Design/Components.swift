import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// Tap an avatar to pick a picture; it's resized, re-encoded and stripped of metadata.
struct AvatarPicker: View {
    @Environment(\.theme) private var theme
    @Binding var image: Data?
    var seed: String
    var size: CGFloat = 120
    /// A coloured ring and glow around the picture. They sit under the camera badge so it stays on top.
    var ring: Color?
    /// Fills the gap between the picture and its ring, so a banner behind doesn't show through.
    var ringGap: Color?
    @State private var hover = false

    var body: some View {
        ImagePickButton(maxSide: 512, crop: .avatar, hasImage: image != nil, removeTitle: "Remove picture",
                        onRemove: { withAnimation { image = nil } }, picked: { data in withAnimation(.snappy) { image = data } }) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(image: image, seed: seed, size: size)
                    .background { if let ringGap { Circle().fill(ringGap).padding(-5) } }
                    .overlay { if let ring { Circle().strokeBorder(ring, lineWidth: 3).padding(-5) } }
                    .shadow(color: (ring ?? .clear).opacity(0.5), radius: ring == nil ? 0 : 22)
                    .scaleEffect(hover ? 1.02 : 1)
                Image(systemName: image == nil ? "camera.fill" : "arrow.triangle.2.circlepath.camera.fill")
                    .font(.system(size: size * 0.12, weight: .bold))
                    .foregroundStyle(Ink.onAccent.opacity(0.85))
                    .frame(width: size * 0.28, height: size * 0.28)
                    .background(theme.gradient, in: .circle)
                    .overlay(Circle().strokeBorder(Ink.void, lineWidth: 3))
            }
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy) { hover = h } }
        .contextMenu {
            if image != nil { Button("Remove picture", role: .destructive) { withAnimation { image = nil } } }
        }
    }
}

/// A profile's wide picture. Without one: light falling from above in the owner's colour over a faint dot grid, and
/// one heartbeat across it, placed by the seed so two profiles' banners don't line up.
struct Banner: View {
    @Environment(AppModel.self) private var model: AppModel?
    var image: Data?
    var seed: String
    var height: CGFloat = 120

    var body: some View {
        ZStack {
            if let image, let picture = DecodedImages.image(image) {
                Image(platformImage: picture).resizable().scaledToFill()
            } else {
                let tint = Signature.tint(for: seed, model: model)
                GeometryReader { geo in
                    ZStack {
                        Ink.raised
                        EllipticalGradient(colors: [tint.opacity(0.30), tint.opacity(0.08), .clear],
                                           center: UnitPoint(x: 0.5, y: -0.15), startRadiusFraction: 0, endRadiusFraction: 0.75)
                        DotGrid(spacing: 16)
                            .mask(LinearGradient(colors: [.white, .white.opacity(0.2)], startPoint: .top, endPoint: .bottom))
                            .opacity(Ink.scheme == .light ? 0.5 : 0.8)
                        WidePulseLine(at: 0.2 + 0.6 * CGFloat(abs(seed.stableHash) % 1000) / 1000)
                            .stroke(tint.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(height: geo.size.height * 0.36)
                            .frame(maxHeight: .infinity)
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.18),
                                                         .init(color: .white, location: 0.82), .init(color: .clear, location: 1)],
                                                 startPoint: .leading, endPoint: .trailing))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 16))
    }
}

/// Your banner, tap to choose and frame a new one.
struct BannerPicker: View {
    @Environment(\.theme) private var theme
    @Binding var image: Data?
    var seed: String
    var height: CGFloat = 130

    var body: some View {
        ImagePickButton(maxSide: CropFrame.banner.maxSide, crop: .banner, hasImage: image != nil, removeTitle: "Remove banner",
                        onRemove: { withAnimation { image = nil } }, picked: { data in withAnimation(.snappy) { image = data } }) {
            Banner(image: image, seed: seed, height: height)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: image == nil ? "photo.badge.plus" : "photo.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.onAccent.opacity(0.85))
                        .frame(width: 30, height: 30)
                        .background(theme.gradient, in: .circle)
                        .padding(10)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(image == nil ? "Add a banner" : "Change banner")
        .contextMenu {
            if image != nil { Button("Remove banner", role: .destructive) { withAnimation { image = nil } } }
        }
    }
}

/// A count with its noun, plural unless there is exactly one: "1 follower", "3 followers".
func counted(_ count: Int, _ noun: String) -> String { count == 1 ? "1 \(noun)" : "\(count) \(noun)s" }

/// Something went wrong, said in one quiet line under the control it belongs to.
struct ProblemText: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(branded: text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Something that can't be undone, waiting for a yes.
struct Pending: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
    var confirm: String
    var run: () -> Void
}

extension View {
    /// Asks before running whatever is put in `pending`.
    func confirms(_ pending: Binding<Pending?>) -> some View {
        confirmationDialog(pending.wrappedValue?.title ?? "",
                           isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: pending.wrappedValue) { asked in
            Button(asked.confirm, role: .destructive) { asked.run() }
        } message: { asked in
            if let message = asked.message { Text(branded: message) }
        }
    }
}

/// Copies text and wipes it from the clipboard later, if nothing else was copied since.
@MainActor func copyToClipboard(_ text: String, clearAfter seconds: Double? = nil) {
    Platform.copy(text, clearAfter: seconds)
}

struct QRCode: View {
    var text: String
    var size: CGFloat = 200

    var body: some View {
        if let image = Self.render(text) {
            Image(platformImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: size, height: size)
                .padding(size * 0.07)
                .background(.white, in: .rect(cornerRadius: size * 0.08))
        }
    }

    static func render(_ text: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return PlatformImage.from(cgImage: cg)
    }
}

/// Small round badge with a symbol, used for counts and kinds.
struct SymbolBadge: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var size: CGFloat = 18
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(Ink.onAccent.opacity(0.85))
            .frame(width: size, height: size)
            .background(theme.gradient, in: .circle)
            .overlay(Circle().strokeBorder(Ink.base, lineWidth: 2))
    }
}

struct SheetHeader: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    var symbol: String
    var title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.gradient)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Ink.text)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 30))
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
        }
    }
}

/// Dark sheet container with glow.
struct SheetBody<Content: View>: View {
    var width: CGFloat = 460
    @ViewBuilder var content: Content
    var body: some View {
        #if os(iOS)
        ScrollView { content.padding(20) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ink.base)
            .preferredColorScheme(Ink.scheme)
        #else
        content
            .padding(24)
            .frame(width: width)
            .background(Backdrop())
            .preferredColorScheme(Ink.scheme)
        #endif
    }
}

extension Date {
    var chatStamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The small green dot for someone who has Pulshade open.
struct OnlineDot: View {
    static let color = Color(red: 0.25, green: 0.82, blue: 0.5)
    var size: CGFloat = 12

    var body: some View {
        Circle().fill(Self.color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Ink.base, lineWidth: 2))
            .accessibilityLabel("Online")
    }
}

/// Marks someone who keeps Pulshade safe: they wear a Guardian, which only the creator's key can give out, and the
/// app has already checked it before it gets here. Shown on profiles beside (or in place of) the Creator tag.
struct ModeratorTag: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Label("Moderator", systemImage: "shield.lefthalf.filled")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(theme.wash, in: .capsule)
            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.5)))
            .help("Keeps Pulshade safe. Awarded by PULSHADE's creator.")
    }
}

extension Collectible? {
    /// Whether this is a Guardian, the badge of a moderator.
    var isModerator: Bool { self?.kind == .guardian }
}
