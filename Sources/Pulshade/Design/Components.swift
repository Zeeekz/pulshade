import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
#if canImport(PulshadeShared)
import PulshadeShared
#if os(iOS)
import UIKit
#endif
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

/// Copies text and, unless told otherwise, wipes it from the clipboard two minutes later. Links and codes that name
/// a mailbox or group otherwise sit in the clipboard, and in whatever a clipboard manager keeps, indefinitely.
@MainActor func copyToClipboard(_ text: String, clearAfter seconds: Double? = 120) {
    Platform.copy(text, clearAfter: seconds)
}

/// Shows the system share sheet for some text.
@MainActor func presentShareSheet(_ text: String) {
    #if os(iOS)
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
          var top = scene.keyWindow?.rootViewController else { return }
    while let next = top.presentedViewController { top = next }
    let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    sheet.popoverPresentationController?.sourceView = top.view
    top.present(sheet, animated: true)
    #endif
}

/// Copy and Share for a code: the short link (pulsh.me/i/…) is put up on the relay only when one is tapped, never just
/// because a screen opened, and both wait the moment that takes. The long link goes if it can't be put up.
struct SharedLinkButtons<CopyLabel: View, ShareLabel: View>: View {
    @Environment(AppModel.self) private var model
    let target: String
    var onCopied: () -> Void = {}
    @ViewBuilder var copyLabel: () -> CopyLabel
    @ViewBuilder var shareLabel: () -> ShareLabel
    var copyStyle: AnyButtonStyle? = nil
    var shareStyle: AnyButtonStyle? = nil
    @State private var busy = false

    var body: some View {
        styled(Button { run { copyToClipboard($0); onCopied() } } label: { label(copyLabel()) }, copyStyle)
            .disabled(busy)
        styled(Button { run { presentShareSheet($0) } } label: { label(shareLabel()) }, shareStyle)
            .disabled(busy)
    }

    @ViewBuilder private func styled(_ button: some View, _ style: AnyButtonStyle?) -> some View {
        if let style { button.buttonStyle(style) } else { button.buttonStyle(.plain) }
    }

    private func label(_ inner: some View) -> some View {
        inner.opacity(busy ? 0.4 : 1).overlay { if busy { ProgressView().controlSize(.small) } }
    }

    private func run(_ then: @escaping (String) -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            let link = await model.linkToShare(target)
            busy = false
            then(link)
        }
    }
}

/// Copy alone, for a code, the same way: the short link is put up when it's tapped.
struct CopyLinkButton<Label: View>: View {
    @Environment(AppModel.self) private var model
    let target: String
    var onCopied: () -> Void = {}
    @ViewBuilder var label: () -> Label
    @State private var busy = false

    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            Task {
                let link = await model.linkToShare(target)
                busy = false
                copyToClipboard(link)
                onCopied()
            }
        } label: {
            label().opacity(busy ? 0.4 : 1).overlay { if busy { ProgressView().controlSize(.small) } }
        }
        .buttonStyle(.plain)
        .disabled(busy || target.isEmpty)
    }
}

/// Lets a stored button style be chosen at run time.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
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
