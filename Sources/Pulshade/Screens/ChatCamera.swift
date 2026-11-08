import SwiftUI

extension View {
    /// The chat camera: full screen on iPhone, a sheet on the Mac. `taken` gets cleaned JPEGs ready to attach.
    /// `filmed` gets a video, recorded by holding the button or picked from the library, still to be made ready.
    func chatCamera(isPresented: Binding<Bool>, taken: @escaping ([Data]) -> Void,
                    filmed: @escaping (MemoryClip, ZoomTrack) -> Void = { _, _ in }) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) { ChatCamera(taken: taken, filmed: filmed) }
        #else
        sheet(isPresented: isPresented) { ChatCamera(taken: taken, filmed: filmed).frame(width: 420, height: 640) }
        #endif
    }
}

/// Take a photo or a video to send: tap the button for a photo, hold it for a video (up to 30 seconds; drag up and
/// down while holding to zoom). Either goes into the message being written, where it can be removed or sent with a
/// caption. The buttons at the bottom left pick photos or a video from the library instead.
struct ChatCamera: View {
    @Environment(\.dismiss) private var dismiss
    @State private var camera = Camera()
    @State private var ready: Bool?
    @State private var taking = false
    @State private var pressStart: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var holding = false
    @State private var zoomAtPress: CGFloat = 1
    var taken: ([Data]) -> Void
    var filmed: (MemoryClip, ZoomTrack) -> Void = { _, _ in }

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
                    Button(action: pickVideo) { face("film") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose a video from your library")
                    Spacer()
                    shutter
                    Spacer()
                    // Balances the two buttons on the left, so the shutter stays in the middle.
                    face("camera").opacity(0).accessibilityHidden(true)
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
        .task {
            camera.clipLimit = ChatVideo.maxSeconds
            ready = await camera.start()
        }
        .onDisappear { holdTask?.cancel(); camera.stop() }
        .overlay(alignment: .top) {
            if camera.recording, let start = camera.recordingStart {
                TimelineView(.periodic(from: start, by: 0.5)) { context in
                    let seconds = min(Int(context.date.timeIntervalSince(start)), Int(ChatVideo.maxSeconds))
                    Text(String(format: "0:%02d", seconds))
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: .capsule)
                }
                .padding(.top, 22)
                .accessibilityLabel("Recording")
            }
        }
    }

    /// White for a photo; while it's held, a red square inside a ring that fills over the 30 seconds.
    private var shutter: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 4).frame(width: 82, height: 82)
            if camera.recording, let start = camera.recordingStart {
                TimelineView(.animation) { context in
                    Circle().trim(from: 0, to: min(context.date.timeIntervalSince(start) / ChatVideo.maxSeconds, 1))
                        .stroke(.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 82, height: 82)
                }
            }
            RoundedRectangle(cornerRadius: camera.recording ? 10 : 33)
                .fill(camera.recording ? Color.red : .white)
                .frame(width: camera.recording ? 36 : 66, height: camera.recording ? 36 : 66)
                .animation(.snappy(duration: 0.2), value: camera.recording)
        }
        .frame(width: 90, height: 90)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged(shutterMoved).onEnded(shutterLifted))
        .opacity(ready == true && !taking ? 1 : 0.35)
        .accessibilityElement()
        .accessibilityLabel(camera.recording ? "Stop recording" : "Take photo")
        .accessibilityHint("Hold for a video")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { camera.recording ? camera.finishRecording() : shoot() }
        .accessibilityAction(named: "Record video") { startClip() }
    }

    /// Down starts the clock; a press that lasts starts a video, and dragging up or down then zooms.
    private func shutterMoved(_ drag: DragGesture.Value) {
        guard ready == true, !taking else { return }
        if pressStart == nil {
            pressStart = Date()
            zoomAtPress = camera.zoom
            holdTask = Task {
                try? await Task.sleep(for: .seconds(ShutterTiming.holdAfter))
                guard !Task.isCancelled else { return }
                startClip()
            }
        }
        if holding {
            camera.setZoom(ZoomMath.zoom(start: zoomAtPress, drag: drag.translation.height, min: camera.minZoom, max: camera.maxZoom))
        }
    }

    /// Up: stops the video, or, if it was only a tap, takes the photo.
    private func shutterLifted(_ drag: DragGesture.Value) {
        holdTask?.cancel()
        let start = pressStart
        pressStart = nil
        if holding {
            holding = false
            camera.finishRecording()
        } else if let start, ShutterTiming.isTap(duration: Date().timeIntervalSince(start),
                                                 travel: hypot(drag.translation.width, drag.translation.height)) {
            shoot()
        }
    }

    private func startClip() {
        guard ready == true, !holding, !camera.recording else { return }
        holding = true
        Haptics.tick()
        camera.record { made, track in
            holding = false
            guard let made else { return }
            filmed(made, track)
            dismiss()
        }
    }

    /// A video from the library: the photo picker on iPhone, a file panel on the Mac. Held in memory, never copied
    /// to a file of ours.
    private func pickVideo() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        filmed(MemoryClip(bytes), .none)
        dismiss()
        #else
        LibraryPicker.present(videosOnly: true) { kind, _ in
            guard case let .clip(clip, track) = kind else { return }
            filmed(clip, track)
            dismiss()
        }
        #endif
    }

    private func shoot() {
        guard ready == true, !taking else { return }
        taking = true
        Haptics.tick()
        camera.capture { image in
            if let image, let data = cleanJPEG(image, maxSide: Self.maxSide) { taken([data]) }
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
