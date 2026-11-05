import SwiftUI

extension View {
    /// The chat camera: full screen on iPhone, a sheet on the Mac. `taken` gets cleaned JPEGs ready to attach.
    func chatCamera(isPresented: Binding<Bool>, taken: @escaping ([Data]) -> Void) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) { ChatCamera(taken: taken) }
        #else
        sheet(isPresented: isPresented) { ChatCamera(taken: taken).frame(width: 420, height: 640) }
        #endif
    }
}

/// Take a photo to send. The photo goes into the message being written, where it can be removed or sent with
/// a caption; the button at the bottom left picks photos from the library instead.
struct ChatCamera: View {
    @Environment(\.dismiss) private var dismiss
    @State private var camera = Camera()
    @State private var ready: Bool?
    @State private var taking = false
    var taken: ([Data]) -> Void

    private static let maxSide: CGFloat = 1600

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if ready == true {
                LayerView(layer: camera.preview).ignoresSafeArea()
                    .accessibilityLabel("Camera preview")
            } else if ready == false {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill").font(.system(size: 34)).foregroundStyle(Ink.faint)
                    Text("No camera available").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text)
                    Text("Choose a photo from your library instead.").font(.system(size: 13)).foregroundStyle(Ink.dim)
                }
            }
            VStack {
                HStack {
                    Button { dismiss() } label: { face("xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")
                    Spacer()
                    if camera.hasFlash && ready == true {
                        Button { camera.flash.toggle() } label: { face(camera.flash ? "bolt.fill" : "bolt.slash.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(camera.flash ? "Flash on" : "Flash off")
                    }
                }
                Spacer()
                HStack(alignment: .center) {
                    ImagePickButton(maxSide: Self.maxSide, pickedMany: { photos in
                        taken(photos)
                        dismiss()
                    }) {
                        face("photo.on.rectangle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose photos from your library")
                    Spacer()
                    shutter
                    Spacer()
                    #if os(iOS)
                    Button { camera.flip() } label: { face("arrow.triangle.2.circlepath.camera") }
                        .buttonStyle(.plain)
                        .disabled(ready != true)
                        .accessibilityLabel("Switch camera")
                    #else
                    face("camera").opacity(0)
                    #endif
                }
                .padding(.horizontal, 28)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
        }
        .preferredColorScheme(.dark)
        .task { ready = await camera.start() }
        .onDisappear { camera.stop() }
    }

    private var shutter: some View {
        Button(action: shoot) {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.5), lineWidth: 4).frame(width: 82, height: 82)
                Circle().fill(.white).frame(width: 66, height: 66)
            }
            .frame(width: 90, height: 90)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(ready != true || taking)
        .opacity(ready == true ? 1 : 0.35)
        .accessibilityLabel("Take photo")
    }

    private func shoot() {
        guard ready == true, !taking else { return }
        taking = true
        Haptics.tick()
        camera.capture { image in
            if let data = cleanJPEG(image, maxSide: Self.maxSide) { taken([data]) }
            dismiss()
        }
    }

    private func face(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.35), in: .circle)
    }
}
