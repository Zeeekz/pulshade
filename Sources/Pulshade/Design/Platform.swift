import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
import PhotosUI
typealias PlatformImage = UIImage
#endif

/// The few things that differ between the Mac and iPhone apps, kept in one place.
enum Platform {
    static var isPhone: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    @MainActor static var isActive: Bool {
        #if os(macOS)
        NSApp?.isActive ?? false
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    @MainActor static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    @MainActor static func setBadge(_ count: Int) {
        #if os(macOS)
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #else
        UNUserNotificationCenter.current().setBadgeCount(count)
        #endif
    }

    /// The Mac's emoji palette. On iPhone the keyboard already has emoji.
    @MainActor static func showEmojiPicker() {
        #if os(macOS)
        NSApp.orderFrontCharacterPalette(nil)
        #endif
    }

    /// Copies text and wipes it from the clipboard later, if nothing else was copied since. It stays on this
    /// device (no Universal Clipboard), and clipboard managers are asked not to keep it.
    @MainActor static func copy(_ text: String, clearAfter seconds: Double? = nil) {
        #if os(macOS)
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard let seconds else { return }
        let count = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if board.changeCount == count { board.clearContents() }
        }
        #else
        let board = UIPasteboard.general
        if let seconds {
            board.setItems([[UTType.plainText.identifier: text]],
                           options: [.expirationDate: Date().addingTimeInterval(seconds), .localOnly: true])
        } else {
            board.setItems([[UTType.plainText.identifier: text]], options: [.localOnly: true])
        }
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    var cgImageValue: CGImage? {
        #if os(macOS)
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        cgImage
        #endif
    }

    static func from(cgImage: CGImage) -> PlatformImage {
        #if os(macOS)
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        UIImage(cgImage: cgImage)
        #endif
    }
}

/// Redraws a picture into a fresh JPEG. Re-drawing the pixels drops metadata such as GPS location
/// and camera serial numbers.
func cleanJPEG(_ image: PlatformImage, maxSide: CGFloat) -> Data? {
    guard let cg = image.cgImageValue else { return nil }
    // The size the picture is seen at. An iPhone photo's pixels are stored sideways, with a rotation to stand it
    // upright; measuring the pixels instead would squeeze the upright picture into a sideways frame.
    var (width, height) = (cg.width, cg.height)
    #if os(iOS)
    if [.left, .leftMirrored, .right, .rightMirrored].contains(image.imageOrientation) { swap(&width, &height) }
    #endif
    let scale = min(1, maxSide / CGFloat(max(width, height)))
    let w = Int(CGFloat(width) * scale), h = Int(CGFloat(height) * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    #if os(iOS)
    // UIKit images can carry a rotation; draw upright.
    if image.imageOrientation != .up {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: w, height: h), true, 1)
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        let upright = UIGraphicsGetImageFromCurrentImageContext()?.cgImage
        UIGraphicsEndImageContext()
        if let upright { ctx.draw(upright, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    } else {
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    #else
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    #endif
    guard let out = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

/// Picks a photo and hands back a cleaned JPEG: a file panel on the Mac, the photo picker on iPhone. With a
/// crop frame, the picture is framed first (zoom and move), as on Instagram.
struct ImagePickButton<Label: View>: View {
    var maxSide: CGFloat
    var crop: CropFrame? = nil
    /// When there is already a picture, tapping asks whether to change or remove it.
    var hasImage = false
    var removeTitle = "Remove picture"
    var onRemove: (() -> Void)? = nil
    var picked: (Data) -> Void
    @ViewBuilder var label: Label
    @State private var pending: PendingCrop?
    @State private var asking = false
    #if os(iOS)
    @State private var choosing = false
    @State private var item: PhotosPickerItem?
    #endif

    var body: some View {
        Button {
            if hasImage, onRemove != nil { asking = true } else { choose() }
        } label: { label }
            .confirmationDialog("", isPresented: $asking, titleVisibility: .hidden) {
                Button("Choose a new picture") { choose() }
                Button(removeTitle, role: .destructive) { onRemove?() }
                Button("Cancel", role: .cancel) {}
            }
            #if os(iOS)
            .photosPicker(isPresented: $choosing, selection: $item, matching: .images)
            .onChange(of: item) { _, new in
                guard let new else { return }
                Task {
                    if let raw = try? await new.loadTransferable(type: Data.self), let image = UIImage(data: raw) {
                        use(image)
                    }
                    item = nil
                }
            }
            #endif
            .cropper($pending, frame: crop ?? .avatar, done: picked)
    }

    private func use(_ image: PlatformImage) {
        if crop != nil {
            pending = PendingCrop(image: image)
        } else if let data = cleanJPEG(image, maxSide: maxSide) {
            picked(data)
        }
    }

    private func choose() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        use(image)
        #else
        choosing = true
        #endif
    }
}

/// Hosts a CALayer-backed view, such as a camera preview, on either platform.
#if os(macOS)
struct LayerView: NSViewRepresentable {
    let layer: CALayer
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.layer = layer
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
#else
struct LayerView: UIViewRepresentable {
    let layer: CALayer
    final class Host: UIView {
        var hosted: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
    func makeUIView(context: Context) -> Host {
        let view = Host()
        view.hosted = layer
        view.layer.addSublayer(layer)
        return view
    }
    func updateUIView(_ view: Host, context: Context) {}
}
#endif

#if os(iOS)
/// Closes the keyboard when you tap outside a text box, anywhere in the app.
@MainActor
final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismisser()
    /// Off while a chat is open: there, taps on the send button mustn't close the keyboard.
    var enabled = true
    private var installed = false

    static func hide() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func install() {
        guard !installed, let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        installed = true
    }

    @objc private func tapped() {
        if enabled { Self.hide() }
    }

    nonisolated func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Taps on a text box (or anything inside one) keep the keyboard up.
        MainActor.assumeIsolated {
            var view = touch.view
            while let current = view {
                if current is UITextInput { return false }
                view = current.superview
            }
            return true
        }
    }

    nonisolated func gestureRecognizer(_ gesture: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif

#if os(iOS)
/// Hiding the system navigation bar also switches off iOS's swipe-from-the-edge to go back.
/// This turns it back on for every navigation stack in the app.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
#endif
