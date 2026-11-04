import SwiftUI
import SceneKit
import simd

// MARK: Still pictures

extension DragonStage {
    /// A picture of the dragon, on a clear background: all of it from the front and a little to the side, or just its head
    /// for when it is shown small beside a name.
    @MainActor static func still(head: Bool, pixels: Int, yaw angle: Float? = nil, lair: Bool = false, eyesOpen: Float = 1, zapping: Bool = false, golden: Bool = false) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let stage = DragonStage(reduceMotion: true, backdrop: lair, golden: golden)
        let yaw: Float = angle ?? (head ? -0.7 : -0.6)
        stage.setPose(yaw: Double(yaw), pitch: head ? 0 : 0.12, zoom: 1, duration: 0)
        if head {
            let target = simd_quatf(angle: yaw, axis: V3(0, 1, 0)).act(V3(0.5, 1.9, 0))
            stage.frame(from: target + simd_normalize(V3(0.1, 0.05, 1)) * 3.0, looking: target)
        } else {
            stage.frame(from: V3(0, 2.2, 9.2), looking: V3(0, 1.2, 0))
        }
        stage.setEyes(open: eyesOpen)
        if zapping { stage.showZap() }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = stage.scene
        renderer.pointOfView = stage.camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: pixels, height: pixels), antialiasingMode: .multisampling4X)
        #if os(macOS)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }
}

/// The two pictures, made the first time they're wanted and kept.
@MainActor enum DragonStillCache {
    private static var made: [String: CGImage] = [:]

    private static func key(_ head: Bool, _ golden: Bool) -> String { "\(head)\(golden)" }

    static func peek(head wantHead: Bool, golden: Bool = false) -> CGImage? { made[key(wantHead, golden)] }

    static func image(head wantHead: Bool, golden: Bool = false) -> CGImage? {
        if let cached = peek(head: wantHead, golden: golden) { return cached }
        let image = DragonStage.still(head: wantHead, pixels: wantHead ? 256 : 512, golden: golden)
        if let image { made[key(wantHead, golden)] = image }
        return image
    }
}

/// The dragon as a picture, for the Collectibles list and beside a name. Its head when small, so it can still be told
/// from the rest; all of it when there's room.
struct DragonStill: View {
    var size: CGFloat
    var golden = false
    @State private var made: CGImage?

    var body: some View {
        let head = size < 40
        let picture = DragonStillCache.peek(head: head, golden: golden) ?? made
        Group {
            if let picture {
                Image(decorative: picture, scale: 1).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "lizard.fill").resizable().scaledToFit().padding(size * 0.15)
                    .foregroundStyle(Color(red: 0.2, green: 0.75, blue: 0.35))
            }
        }
        .frame(width: size, height: size)
        .task { made = DragonStillCache.image(head: head, golden: golden) }
        .accessibilityLabel(golden ? "Golden Pulze The Dragon" : "Pulze The Dragon")
    }
}

// MARK: The 3D view

#if os(macOS)
private struct DragonSceneRep: NSViewRepresentable {
    let stage: DragonStage
    func makeNSView(context: Context) -> SCNView { configured(SCNView(frame: .zero), stage) }
    func updateNSView(_ view: SCNView, context: Context) {}
}
#else
private struct DragonSceneRep: UIViewRepresentable {
    let stage: DragonStage
    func makeUIView(context: Context) -> SCNView { configured(SCNView(frame: .zero), stage) }
    func updateUIView(_ view: SCNView, context: Context) {}
}
#endif

private func configured(_ view: SCNView, _ stage: DragonStage) -> SCNView {
    view.scene = stage.scene
    view.pointOfView = stage.camera
    view.backgroundColor = dc(0, 0, 0, 0)
    view.antialiasingMode = .multisampling4X
    view.allowsCameraControl = false
    view.autoenablesDefaultLighting = false
    view.preferredFramesPerSecond = 60
    view.isPlaying = true
    return view
}

/// Pulze The Dragon in 3D. Drag to turn it all the way round or tip it, pinch (or scroll) to bring it closer, and tap
/// it to make it breathe fire. Left alone it slowly turns on its own, and stops while you hold it.
public struct DragonViewer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: DragonStage?
    @State private var yaw = -0.55
    @State private var pitch = 0.1
    @State private var zoom = 1.0
    @State private var dragYaw: Double?
    @State private var dragPitch: Double?
    @State private var zoomFrom: Double?
    @State private var resume: Task<Void, Never>?
    var golden = false

    public init(golden: Bool = false) { self.golden = golden }

    public var body: some View {
        ZStack {
            if let stage {
                DragonSceneRep(stage: stage).allowsHitTesting(false)
            }
            // The scene doesn't take touches itself; this does, so drags and taps behave the same on Mac and iPhone.
            Color.clear.contentShape(Rectangle())
                .gesture(drag)
                .simultaneousGesture(pinch)
                .onTapGesture { stage?.zap() }
        }
        .onAppear {
            if stage == nil {
                let made = DragonStage(reduceMotion: reduceMotion, golden: golden)
                made.setPose(yaw: yaw, pitch: pitch, zoom: zoom, duration: 0)
                stage = made
                made.autoSpin = true
            }
        }
        .onDisappear { resume?.cancel(); stage?.autoSpin = false }
        .accessibilityElement()
        .accessibilityLabel("\(golden ? "Golden Pulze" : "Pulze") The Dragon, a 3D model. Swipe up or down to turn it. Double tap to make it zap.")
        .accessibilityAdjustableAction { direction in
            yaw += direction == .increment ? 0.6 : -0.6
            stage?.setPose(yaw: yaw, pitch: pitch, zoom: zoom, duration: 0.3)
        }
    }

    /// Holds the spin while the dragon is being handled, and lets it go on again a few seconds after.
    private func touched() {
        stage?.autoSpin = false
        resume?.cancel()
    }

    private func letGoSoon() {
        guard !reduceMotion else { return }
        resume = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { stage?.autoSpin = true }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                touched()
                // The dragon's turn so far, which the slow spin has been adding to, is kept as it is.
                let startYaw = dragYaw ?? yaw, startPitch = dragPitch ?? pitch
                dragYaw = startYaw
                dragPitch = startPitch
                yaw = startYaw + Double(value.translation.width) * 0.011
                pitch = min(max(startPitch + Double(value.translation.height) * 0.006, -0.45), 0.6)
                stage?.setPose(yaw: yaw, pitch: pitch, zoom: zoom, duration: 0)
            }
            .onEnded { value in
                // Let go with a flick and it keeps turning for a moment, slowing down.
                let carry = Double(value.predictedEndTranslation.width - value.translation.width) * 0.011
                yaw += carry
                stage?.setPose(yaw: yaw, pitch: pitch, zoom: zoom, duration: 0.9)
                dragYaw = nil
                dragPitch = nil
                letGoSoon()
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                touched()
                let start = zoomFrom ?? zoom
                zoomFrom = start
                zoom = min(max(start * Double(value.magnification), 0.7), 2.4)
                stage?.setPose(yaw: yaw, pitch: pitch, zoom: zoom, duration: 0)
            }
            .onEnded { _ in zoomFrom = nil; letGoSoon() }
    }
}
