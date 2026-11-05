import SwiftUI
import SceneKit
import simd

/// The Bitcoin collectible as a 3D coin: a thick disc of polished orange gold with a reeded edge and a raised rim,
/// the B on one face and Pulshade's pulse on the other, lit by a studio and the glow it gives off. It is turned by
/// `setPose`, `autoSpin` slowly turns it all the way round on its own, and `flip()` spins it once on the spot.
final class BitcoinStage {
    typealias V3 = SIMD3<Float>

    let scene = SCNScene()
    let camera = SCNNode()
    private let look = SCNNode()
    private let pitchNode = SCNNode(), yawNode = SCNNode(), spinNode = SCNNode(), flipNode = SCNNode(), coin = SCNNode()
    private(set) var reduceMotion = false

    static let distance: Float = 6.2
    private static let radius: CGFloat = 1.5, thickness: CGFloat = 0.22

    @MainActor init(reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
        scene.background.contents = dc(0, 0, 0, 0)
        scene.lightingEnvironment.contents = DragonMesh.studioImage()
        scene.lightingEnvironment.intensity = 1.05

        let cam = SCNCamera()
        cam.fieldOfView = 30
        cam.zNear = 0.1
        cam.zFar = 40
        cam.wantsHDR = true
        cam.bloomIntensity = 0.5
        cam.bloomThreshold = 0.95
        cam.bloomBlurRadius = 12
        cam.vignettingIntensity = 0.45
        cam.vignettingPower = 1.3
        cam.contrast = 0.1
        cam.saturation = 1.1
        camera.camera = cam
        camera.simdPosition = V3(0, 0, Self.distance)
        let aim = SCNLookAtConstraint(target: look)
        aim.isGimbalLockEnabled = true
        camera.constraints = [aim]
        scene.rootNode.addChildNode(camera)
        scene.rootNode.addChildNode(look)

        scene.rootNode.addChildNode(pitchNode)
        pitchNode.addChildNode(yawNode)
        yawNode.addChildNode(spinNode)
        spinNode.addChildNode(flipNode)
        flipNode.addChildNode(coin)

        buildCoin()
        buildLights()
    }

    @MainActor private func buildCoin() {
        let body = SCNCylinder(radius: Self.radius, height: Self.thickness)
        body.radialSegmentCount = 96

        func material(_ image: CGImage, metal: Double, rough: Double) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = image
            m.metalness.contents = metal
            m.roughness.contents = rough
            m.isDoubleSided = false
            return m
        }
        let front = material(BitcoinTextures.face(front: true), metal: 0.7, rough: 0.38)
        let back = material(BitcoinTextures.face(front: false), metal: 0.7, rough: 0.38)
        let edge = material(BitcoinTextures.reeding(), metal: 0.95, rough: 0.28)
        edge.diffuse.wrapS = .repeat
        // A cylinder's materials are its side, its top and its bottom.
        body.materials = [edge, front, back]
        coin.geometry = body
        // Stood on end, with its top, the front, towards the camera.
        coin.simdEulerAngles = V3(.pi / 2, 0, 0)

        // The raised rim on each face.
        let gold = SCNMaterial()
        gold.lightingModel = .physicallyBased
        gold.diffuse.contents = dc(0.97, 0.60, 0.12)
        gold.metalness.contents = 0.95
        gold.roughness.contents = 0.22
        for side in [1.0, -1.0] {
            let ring = SCNTorus(ringRadius: Self.radius - 0.07, pipeRadius: 0.075)
            ring.ringSegmentCount = 96
            ring.pipeSegmentCount = 20
            ring.materials = [gold]
            let node = SCNNode(geometry: ring)
            node.position = SCNVector3(0, Self.thickness / 2 * side, 0)
            coin.addChildNode(node)
        }
    }

    private func buildLights() {
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 450
        key.light?.color = dc(1, 0.95, 0.88)
        key.simdEulerAngles = V3(-0.6, -0.5, 0)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 350
        rim.light?.color = dc(0.55, 0.7, 1)
        rim.simdEulerAngles = V3(0.3, 2.6, 0)
        scene.rootNode.addChildNode(rim)

        // The warm glow it gives off.
        let glow = SCNNode()
        glow.light = SCNLight()
        glow.light?.type = .omni
        glow.light?.intensity = 90
        glow.light?.color = dc(1, 0.55, 0.1)
        glow.position = SCNVector3(0, 0, 3)
        scene.rootNode.addChildNode(glow)
    }

    func setPose(yaw: Double, pitch: Double, zoom: Double, duration: Double) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        yawNode.simdEulerAngles = V3(0, Float(yaw), 0)
        pitchNode.simdEulerAngles = V3(Float(pitch), 0, 0)
        camera.simdPosition = V3(0, 0, Self.distance / Float(zoom))
        SCNTransaction.commit()
    }

    var autoSpin = false {
        didSet {
            guard autoSpin != oldValue else { return }
            spinNode.removeAction(forKey: "spin")
            if autoSpin && !reduceMotion {
                spinNode.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 16)), forKey: "spin")
            }
        }
    }

    /// Spins once on the spot, quickly, and settles.
    func flip() {
        guard !reduceMotion, flipNode.action(forKey: "flip") == nil else { return }
        let turn = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.9)
        turn.timingMode = .easeInEaseOut
        flipNode.runAction(turn, forKey: "flip")
    }
}

/// The coin's faces and edge, drawn from the same art as the flat picture.
@MainActor enum BitcoinTextures {
    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 1
        return renderer.cgImage!
    }

    /// One face, filling a square the way a cylinder's end wants it.
    static func face(front: Bool) -> CGImage {
        render(Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.6, green: 0.28, blue: 0.02)))
            var c = ctx
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.rotate(by: .degrees(90))
            c.scaleBy(x: -size.width / 60, y: size.height / 60)
            BitcoinFrame.paintFace(&c, front: front, sweep: 0, shadow: false)
        }, width: 1024, height: 1024)
    }

    /// The reeded edge: fine vertical grooves all the way round.
    static func reeding() -> CGImage {
        render(Canvas { ctx, size in
            let n = 180
            for i in 0..<n {
                let x = size.width * Double(i) / Double(n)
                let w = size.width / Double(n)
                ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .linearGradient(
                    Gradient(colors: [Color(red: 1, green: 0.78, blue: 0.38), Color(red: 0.62, green: 0.30, blue: 0.03)]),
                    startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + w, y: 0)))
            }
        }, width: 1024, height: 64)
    }
}

extension BitcoinStage {
    /// A picture of the coin, for checking it, on a clear background.
    @MainActor static func still(pixels: Int, yaw: Double, pitch: Double = 0.1) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let stage = BitcoinStage(reduceMotion: true)
        stage.setPose(yaw: yaw, pitch: pitch, zoom: 1, duration: 0)
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

// MARK: The 3D view

#if os(macOS)
private struct BitcoinSceneRep: NSViewRepresentable {
    let stage: BitcoinStage
    func makeNSView(context: Context) -> SCNView { configured(SCNView(frame: .zero), stage) }
    func updateNSView(_ view: SCNView, context: Context) {}
}
#else
private struct BitcoinSceneRep: UIViewRepresentable {
    let stage: BitcoinStage
    func makeUIView(context: Context) -> SCNView { configured(SCNView(frame: .zero), stage) }
    func updateUIView(_ view: SCNView, context: Context) {}
}
#endif

private func configured(_ view: SCNView, _ stage: BitcoinStage) -> SCNView {
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

/// The Bitcoin coin in 3D. Drag to turn it all the way round or tip it, pinch (or scroll) to bring it closer, and tap
/// it to make it spin. Left alone it slowly turns on its own, and stops while you hold it.
public struct BitcoinViewer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: BitcoinStage?
    @State private var yaw = -0.5
    @State private var pitch = 0.1
    @State private var zoom = 1.0
    @State private var dragYaw: Double?
    @State private var dragPitch: Double?
    @State private var zoomFrom: Double?
    @State private var resume: Task<Void, Never>?

    public init() {}

    public var body: some View {
        ZStack {
            if let stage {
                BitcoinSceneRep(stage: stage).allowsHitTesting(false)
            }
            // The scene doesn't take touches itself; this does, so drags and taps behave the same on Mac and iPhone.
            Color.clear.contentShape(Rectangle())
                .gesture(drag)
                .simultaneousGesture(pinch)
                .onTapGesture { stage?.flip() }
        }
        .onAppear {
            if stage == nil {
                let made = BitcoinStage(reduceMotion: reduceMotion)
                made.setPose(yaw: yaw, pitch: pitch, zoom: zoom, duration: 0)
                stage = made
                made.autoSpin = true
            }
        }
        .onDisappear { resume?.cancel(); stage?.autoSpin = false }
        .accessibilityElement()
        .accessibilityLabel("Bitcoin, a 3D coin. Swipe up or down to turn it. Double tap to spin it.")
        .accessibilityAdjustableAction { direction in
            yaw += direction == .increment ? 0.6 : -0.6
            stage?.setPose(yaw: yaw, pitch: pitch, zoom: zoom, duration: 0.3)
        }
    }

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
                let startYaw = dragYaw ?? yaw, startPitch = dragPitch ?? pitch
                dragYaw = startYaw
                dragPitch = startPitch
                yaw = startYaw + Double(value.translation.width) * 0.011
                pitch = min(max(startPitch + Double(value.translation.height) * 0.006, -0.6), 0.6)
                stage?.setPose(yaw: yaw, pitch: pitch, zoom: zoom, duration: 0)
            }
            .onEnded { value in
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
