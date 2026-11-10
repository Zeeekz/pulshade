import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import Photos
#endif

/// A picture to hand to the share sheet as the JPEG it is.
struct PhotoFile: Transferable {
    var data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { $0.data }
    }
}

/// How big a photo or video sits in a chat bubble: as wide as a bubble gets, as tall as its own shape asks, within
/// limits. A very tall or very wide one is cropped to fit rather than shrunk to a sliver.
enum MediaFrame {
    static var maxWidth: CGFloat { Platform.isPhone ? 264 : 320 }
    static let minWidth: CGFloat = 150
    static let maxHeight: CGFloat = 360
    static let minHeight: CGFloat = 120

    static func size(for natural: CGSize) -> CGSize {
        let aspect = natural.width / max(natural.height, 1)
        var width = maxWidth
        var height = width / max(aspect, 0.01)
        if height > maxHeight {
            height = maxHeight
            width = min(maxWidth, max(minWidth, height * aspect))
        }
        height = max(height, minHeight)
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}

/// A picture from a chat at full size. It grows out of its bubble and shrinks back into it. Pinch or double-tap to
/// zoom (where you tapped), drag to look around, tap once to hide everything but the picture, swipe down to close.
struct ImageViewer: View {
    var data: Data
    /// Who sent it ("You" for your own) and when, shown along the top.
    var title: String?
    var date: Date?
    /// The words sent with it.
    var caption: String?
    /// Whether this viewer closes itself on a downward swipe. On iPhone the zoom transition already does that when
    /// it opened from a bubble.
    var swipeToClose = true

    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var settledPan: CGSize = .zero
    /// How far it's been dragged down on its way to closing (only while not zoomed in).
    @State private var dragY: CGFloat = 0
    @State private var chrome = true
    @State private var captionOpen = false
    @State private var notice: (text: String, symbol: String)?
    /// The picture redrawn into a fresh JPEG, which is what's saved, shared and copied: what a stranger sent is never
    /// passed on as it arrived, so it can't bring location or other hidden data into your library.
    @State private var cleaned: Data?

    private var image: PlatformImage? { DecodedImages.image(data) }
    private var zoomed: Bool { zoom > 1.02 }
    private var dragProgress: CGFloat { min(dragY / 400, 1) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(1 - Double(dragProgress) * 0.9).ignoresSafeArea()
                if let image {
                    Image(platformImage: image)
                        .resizable().scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(zoom * (1 - dragProgress * 0.25))
                        .offset(x: pan.width, y: pan.height + dragY)
                        .gesture(magnify(in: geo.size, image: image.size))
                        // Unzoomed after opening from a bubble, the swipe down belongs to the zoom transition.
                        .simultaneousGesture(drag(in: geo.size, image: image.size), including: zoomed || swipeToClose ? .all : .subviews)
                        .onTapGesture(count: 2, coordinateSpace: .local) { toggleZoom(at: $0, in: geo.size, image: image.size) }
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() } }
                        .accessibilityLabel(caption.map { "Photo. \($0)" } ?? "Photo")
                        .accessibilityAction(named: "Close") { dismiss() }
                }
                overlayChrome
                    .opacity(chrome && dragY < 10 ? 1 : 0)
                    .allowsHitTesting(chrome)
                if let notice {
                    Label(notice.text, systemImage: notice.symbol)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .task { cleaned = image.flatMap { cleanJPEG($0, maxSide: 4096) } }
        #if os(iOS)
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        #else
        .frame(minWidth: 640, minHeight: 520)
        .onKeyPress(.escape) { dismiss(); return .handled }
        #endif
    }

    // MARK: Chrome

    private var overlayChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                glassButton("xmark", label: "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                if title != nil || date != nil {
                    VStack(spacing: 1) {
                        if let title { Text(title).font(.system(size: 15, weight: .semibold)) }
                        if let date {
                            Text(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                // Keeps the title centred against the close button.
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 28)
            .background(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
            }
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 15)).foregroundStyle(.white)
                        .lineLimit(captionOpen ? nil : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .onTapGesture { withAnimation(.snappy) { captionOpen.toggle() } }
                }
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        if let cleaned {
                            ShareLink(item: PhotoFile(data: cleaned), preview: SharePreview("Photo")) { glassFace("square.and.arrow.up") }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Share")
                        }
                        glassButton("arrow.down.to.line", label: "Save") { save() }
                        glassButton("doc.on.doc", label: "Copy") { copy() }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 36).padding(.bottom, 12)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private func glassButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { glassFace(symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .help(label)
    }

    private func glassFace(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
    }

    // MARK: Zoom and pan

    /// The picture's size on screen at normal zoom.
    private func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        let s = min(box.width / max(image.width, 1), box.height / max(image.height, 1))
        return CGSize(width: image.width * s, height: image.height * s)
    }

    /// Keeps a zoomed picture from being dragged off its edges.
    private func clamp(_ p: CGSize, zoom z: CGFloat, in box: CGSize, image: CGSize) -> CGSize {
        let f = fitted(image, in: box)
        let maxX = max(0, (f.width * z - box.width) / 2), maxY = max(0, (f.height * z - box.height) / 2)
        return CGSize(width: min(max(p.width, -maxX), maxX), height: min(max(p.height, -maxY), maxY))
    }

    private func magnify(in box: CGSize, image: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { zoom = min(max(settledZoom * $0.magnification, 0.85), 6) }
            .onEnded { _ in
                withAnimation(.smooth(duration: 0.3)) {
                    if zoom <= 1.02 { reset() } else {
                        settledZoom = zoom
                        pan = clamp(pan, zoom: zoom, in: box, image: image)
                        settledPan = pan
                    }
                }
            }
    }

    /// Zoomed in, a drag moves the picture; at normal size, dragging down closes it.
    private func drag(in box: CGSize, image: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if zoomed {
                    pan = CGSize(width: settledPan.width + value.translation.width, height: settledPan.height + value.translation.height)
                } else if swipeToClose {
                    dragY = value.translation.height > abs(value.translation.width) ? max(value.translation.height, 0) : 0
                }
            }
            .onEnded { value in
                if zoomed {
                    withAnimation(.smooth(duration: 0.35)) {
                        pan = clamp(CGSize(width: settledPan.width + value.predictedEndTranslation.width * 0.6,
                                           height: settledPan.height + value.predictedEndTranslation.height * 0.6),
                                    zoom: zoom, in: box, image: image)
                    }
                    settledPan = pan
                } else if swipeToClose, value.translation.height > abs(value.translation.width),
                          value.translation.height > 110 || value.predictedEndTranslation.height > 380 {
                    dismiss()
                } else {
                    withAnimation(.smooth(duration: 0.25)) { dragY = 0 }
                }
            }
    }

    /// Double tap: in to where you tapped, or back out.
    private func toggleZoom(at point: CGPoint, in box: CGSize, image: CGSize) {
        withAnimation(.smooth(duration: 0.3)) {
            if zoomed { reset(); return }
            let z: CGFloat = 2.5
            // Keeps the tapped spot under your finger as it grows.
            let target = CGSize(width: (box.width / 2 - point.x) * (z - 1), height: (box.height / 2 - point.y) * (z - 1))
            zoom = z; settledZoom = z
            pan = clamp(target, zoom: z, in: box, image: image); settledPan = pan
        }
    }

    private func reset() {
        zoom = 1; settledZoom = 1; pan = .zero; settledPan = .zero
    }

    // MARK: Save and copy

    private func say(_ text: String, _ symbol: String) {
        withAnimation(.snappy) { notice = (text, symbol) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(.easeOut) { notice = nil } }
    }

    /// Photos on iPhone (only ever added to, never read), a file of your choosing on the Mac.
    private func save() {
        guard let photo = cleaned else { say("Couldn't read the picture", "exclamationmark.triangle"); return }
        #if os(iOS)
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                say("Allow saving to Photos in Settings", "lock"); return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: photo, options: nil)
                }
                Haptics.tick()
                say("Saved to Photos", "checkmark")
            } catch {
                say("Couldn't save", "exclamationmark.triangle")
            }
        }
        #else
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "Photo.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try photo.write(to: url, options: .atomic); say("Saved", "checkmark") } catch { say("Couldn't save", "exclamationmark.triangle") }
        #endif
    }

    private func copy() {
        guard let cleaned else { say("Couldn't read the picture", "exclamationmark.triangle"); return }
        Platform.copyImage(cleaned)
        Haptics.tick()
        say("Copied", "doc.on.doc")
    }
}

/// Opens an `ImageViewer` over the chat: full screen on iPhone, growing out of the bubble it was tapped in when
/// there is one; a sheet on the Mac.
struct ImageViewerCover: ViewModifier {
    @Binding var isPresented: Bool
    var data: Data
    var title: String? = nil
    var date: Date? = nil
    var caption: String? = nil
    /// The bubble it grows out of.
    var source: (id: UUID, space: Namespace.ID)? = nil

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) {
            if let source {
                ImageViewer(data: data, title: title, date: date, caption: caption, swipeToClose: false)
                    .navigationTransition(.zoom(sourceID: source.id, in: source.space))
            } else {
                ImageViewer(data: data, title: title, date: date, caption: caption)
                    .presentationBackground(.clear)
            }
        }
        #else
        content.sheet(isPresented: $isPresented) { ImageViewer(data: data, title: title, date: date, caption: caption) }
        #endif
    }
}
