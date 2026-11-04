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

/// A picture from a chat at full size: pinch or double-tap to zoom, drag it down to close, and save, share or copy it.
struct ImageViewer: View {
    var data: Data
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var settledPan: CGSize = .zero
    /// How far it's been dragged down on its way to closing (only while not zoomed in).
    @State private var dragY: CGFloat = 0
    @State private var notice: String?

    private var image: PlatformImage? { PlatformImage(data: data) }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - Double(min(dragY, 300)) / 600).ignoresSafeArea()
            if let image {
                Image(platformImage: image)
                    .resizable().scaledToFit()
                    .scaleEffect(zoom)
                    .offset(x: pan.width, y: pan.height + dragY)
                    .gesture(magnify)
                    .simultaneousGesture(drag)
                    .onTapGesture(count: 2) { toggleZoom() }
                    .accessibilityLabel("Photo")
            }
            VStack {
                HStack {
                    Spacer()
                    control("xmark", label: "Close") { dismiss() }
                }
                Spacer()
                HStack(spacing: 14) {
                    control("square.and.arrow.down", label: "Save") { save() }
                    ShareLink(item: PhotoFile(data: data), preview: SharePreview("Photo")) { face("square.and.arrow.up") }
                        .accessibilityLabel("Share")
                    control("doc.on.doc", label: "Copy") { copy() }
                }
            }
            .padding(16)
            .opacity(dragY > 20 ? 0 : 1)
            if let notice {
                Text(notice)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: .capsule)
                    .transition(.opacity)
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        .onKeyPress(.escape) { dismiss(); return .handled }
        #endif
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { zoom = min(max(settledZoom * $0.magnification, 1), 6) }
            .onEnded { _ in
                settledZoom = zoom
                if zoom <= 1.02 { reset() }
            }
    }

    /// Zoomed in, a drag moves the picture; at normal size, dragging down closes it.
    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if zoom > 1.02 {
                    pan = CGSize(width: settledPan.width + value.translation.width, height: settledPan.height + value.translation.height)
                } else {
                    dragY = value.translation.height > abs(value.translation.width) ? max(value.translation.height, 0) : 0
                }
            }
            .onEnded { value in
                if zoom > 1.02 {
                    settledPan = pan
                } else if value.translation.height > abs(value.translation.width),
                          value.translation.height > 120 || value.predictedEndTranslation.height > 400 {
                    dismiss()
                } else {
                    withAnimation(.smooth(duration: 0.25)) { dragY = 0 }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.smooth(duration: 0.25)) {
            if zoom > 1.02 { reset() } else { zoom = 2.5; settledZoom = 2.5 }
        }
    }

    private func reset() {
        zoom = 1; settledZoom = 1; pan = .zero; settledPan = .zero
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { face(symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func face(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.45), in: .circle)
    }

    private func say(_ text: String) {
        withAnimation { notice = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { withAnimation { notice = nil } }
    }

    /// Photos on iPhone (only ever added to, never read), a file of your choosing on the Mac.
    private func save() {
        #if os(iOS)
        let photo = data
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                say("Allow saving to Photos in Settings"); return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: photo, options: nil)
                }
                say("Saved to Photos")
            } catch {
                say("Couldn't save")
            }
        }
        #else
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "Photo.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); say("Saved") } catch { say("Couldn't save") }
        #endif
    }

    private func copy() {
        Platform.copyImage(data)
        say("Copied")
    }
}

/// Opens an `ImageViewer` over the chat: full screen on iPhone, a sheet on the Mac.
struct ImageViewerCover: ViewModifier {
    @Binding var isPresented: Bool
    var data: Data

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) { ImageViewer(data: data) }
        #else
        content.sheet(isPresented: $isPresented) { ImageViewer(data: data) }
        #endif
    }
}
