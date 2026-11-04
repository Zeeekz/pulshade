import SwiftUI
import SceneKit
#if canImport(PulshadeShared)
import PulshadeShared
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A collectible as a solid object you can turn: its picture is stacked into a thick cut-out of its own outline,
/// with a lit face front and back and shaded edges, swaying gently until you take hold of it. Drag to turn, pinch
/// or scroll to zoom. (Pulze The Dragon has its own, fully modelled viewer.)
struct ObjectViewer3D: View {
    var kind: Collectible.Kind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var object: ObjectScene?

    var body: some View {
        ZStack {
            if let object {
                // Ticks with the screen itself, so the artwork on the object moves as smoothly as anything else.
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    SceneHost(scene: object.scene)
                        .onChange(of: timeline.date) { object.refresh() }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: kind) { object = ObjectScene(kind, still: reduceMotion) }
        .accessibilityLabel("\(kind.name), a 3D view you can turn")
    }
}

@MainActor final class ObjectScene {
    let scene = SCNScene()
    private let kind: Collectible.Kind
    private let face = SCNMaterial()
    private let side = SCNMaterial()

    /// The collectible's art on a clear background, as an image to stack. Drawn at the moment it's asked for, so
    /// its animation is wherever it has got to.
    static func picture(_ kind: Collectible.Kind) -> CGImage? {
        let renderer = ImageRenderer(content: CollectibleIcon(item: kind, size: 320).frame(width: 320, height: 320))
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.cgImage
    }

    init(_ kind: Collectible.Kind, still: Bool) {
        self.kind = kind
        let object = SCNNode()
        for material in [face, side] {
            material.lightingModel = .constant
            material.isDoubleSided = true
            // Only the opaque parts of the picture are solid, so the stack takes the picture's outline.
            material.shaderModifiers = [.fragment: "if (_output.color.a < 0.45) { discard_fragment(); }"]
        }
        // The two faces keep the art's own colours; everything between them is the shaded side of the object.
        #if os(macOS)
        side.multiply.contents = NSColor(white: 0.62, alpha: 1)
        #else
        side.multiply.contents = UIColor(white: 0.62, alpha: 1)
        #endif
        refresh()
        let layers = 48
        let depth: Float = 0.30
        for i in 0..<layers {
            let plane = SCNPlane(width: 2.5, height: 2.5)
            plane.materials = [i == 0 || i == layers - 1 ? face : side]
            let layer = SCNNode(geometry: plane)
            let along = Float(i) / Float(layers - 1) - 0.5
            layer.simdPosition = SIMD3<Float>(0, 0, along * depth)
            object.addChildNode(layer)
        }
        if !still {
            // A slow sway, so it reads as solid before anyone touches it.
            let sway = SCNAction.sequence([
                .rotateTo(x: 0, y: -0.55, z: 0, duration: 3.2, usesShortestUnitArc: true),
                .rotateTo(x: 0, y: 0.55, z: 0, duration: 3.2, usesShortestUnitArc: true),
            ])
            sway.timingMode = .easeInEaseOut
            object.runAction(.repeatForever(sway))
        }
        scene.rootNode.addChildNode(object)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 32
        camera.position = SCNVector3(0, 0, 6.2)
        scene.rootNode.addChildNode(camera)
    }

    private var lastFrame = Date.distantPast
    /// How many frames of the artwork have gone onto the object.
    private(set) var framesDrawn = 0

    /// Puts the artwork's current frame on the object, at most about 100 times a second.
    func refresh() {
        let now = Date()
        guard now.timeIntervalSince(lastFrame) >= 0.009 || lastFrame == .distantPast else { return }
        lastFrame = now
        guard let image = Self.picture(kind) else { return }
        framesDrawn += 1
        face.diffuse.contents = image
        side.diffuse.contents = image
    }
}

#if os(macOS)
private struct SceneHost: NSViewRepresentable {
    var scene: SCNScene
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = scene.rootNode.childNodes.first { $0.camera != nil }
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 120
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {}
}
#else
private struct SceneHost: UIViewRepresentable {
    var scene: SCNScene
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = scene.rootNode.childNodes.first { $0.camera != nil }
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 120
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {}
}
#endif
