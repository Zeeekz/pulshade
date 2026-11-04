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

/// An egg in 3D, to turn with a finger or the mouse. It cracks along its middle as its time runs out and, once
/// it's ready, glows, and rocks as if something inside wants out.
struct EggViewer3D: View {
    var progress: Double
    var ready: Bool
    var started: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @State private var stage: EggStage?

    var body: some View {
        ZStack {
            if let stage {
                EggSceneHost(scene: stage.scene)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { stage = EggStage(still: reduceMotion) }
        .onChange(of: progress, initial: true) { stage?.update(progress: progress, ready: ready, started: started) }
        .onChange(of: ready) { stage?.update(progress: progress, ready: ready, started: started) }
        .onChange(of: started) { stage?.update(progress: progress, ready: ready, started: started) }
        .accessibilityLabel("An egg, a 3D view you can turn")
    }
}

@MainActor final class EggStage {
    let scene = SCNScene()
    private let egg = SCNNode()
    private let shell = SCNMaterial()
    private let glow = SCNNode()
    private var lastBucket = -1
    private var wasReady = false
    private let still: Bool

    init(still: Bool) {
        self.still = still
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 96
        // Bring the sphere to an egg: longer, and narrower towards the top.
        sphere.firstMaterial = shell
        shell.lightingModel = .physicallyBased
        shell.roughness.contents = 0.34
        shell.metalness.contents = 0.12
        shell.diffuse.contents = Self.texture(crack: 0, started: false)
        shell.shaderModifiers = [.geometry: """
        float y = _geometry.position.y;
        float k = 1.0 - 0.17 * y;
        _geometry.position.x *= k;
        _geometry.position.z *= k;
        _geometry.position.y *= 1.3;
        """]
        egg.geometry = sphere
        egg.position = SCNVector3(0, 0.1, 0)
        scene.rootNode.addChildNode(egg)

        // A soft glow behind it for when it's ready.
        let halo = SCNPlane(width: 5, height: 5)
        let haloMaterial = SCNMaterial()
        haloMaterial.lightingModel = .constant
        haloMaterial.diffuse.contents = Self.halo()
        haloMaterial.blendMode = .add
        haloMaterial.writesToDepthBuffer = false
        halo.firstMaterial = haloMaterial
        glow.geometry = halo
        glow.position = SCNVector3(0, 0.1, -1.6)
        glow.opacity = 0
        scene.rootNode.addChildNode(glow)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.6, 0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 420
        scene.rootNode.addChildNode(fill)
        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 600
        rim.eulerAngles = SCNVector3(0.3, -2.6, 0)
        scene.rootNode.addChildNode(rim)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 32
        camera.position = SCNVector3(0, 0.2, 6.6)
        scene.rootNode.addChildNode(camera)

        if !still {
            let left = SCNAction.rotateTo(x: 0, y: -0.7, z: 0, duration: 3.4, usesShortestUnitArc: true)
            let right = SCNAction.rotateTo(x: 0, y: 0.7, z: 0, duration: 3.4, usesShortestUnitArc: true)
            left.timingMode = .easeInEaseOut
            right.timingMode = .easeInEaseOut
            egg.runAction(.repeatForever(.sequence([left, right])), forKey: "sway")
        }
    }

    /// Cracks it by how far along it is, and makes it glow and rock when it's ready.
    func update(progress: Double, ready: Bool, started: Bool) {
        let amount = ready ? 1 : max(0, min(progress, 1)) * 0.85
        let bucket = started ? Int(amount * 40) : -1
        if bucket != lastBucket {
            lastBucket = bucket
            shell.diffuse.contents = Self.texture(crack: started ? amount : 0, started: started)
        }
        guard ready != wasReady else { return }
        wasReady = ready
        if ready {
            shell.emission.contents = Self.accent
            shell.emission.intensity = 0.35
            glow.runAction(.fadeIn(duration: 0.6))
            if !still {
                egg.removeAction(forKey: "sway")
                let rock = SCNAction.sequence([
                    .rotateTo(x: 0, y: 0, z: 0.12, duration: 0.16),
                    .rotateTo(x: 0, y: 0, z: -0.12, duration: 0.32),
                    .rotateTo(x: 0, y: 0, z: 0, duration: 0.16),
                    .wait(duration: 1.1),
                ])
                egg.runAction(.repeatForever(rock), forKey: "rock")
            }
        }
    }

    private static var accent: Any {
        #if os(macOS)
        NSColor(red: 0.5, green: 0.6, blue: 1, alpha: 1)
        #else
        UIColor(red: 0.5, green: 0.6, blue: 1, alpha: 1)
        #endif
    }

    /// The shell's colour all the way round: a deep gradient, pale spots and, once it's started, a jagged crack.
    static func texture(crack: Double, started: Bool) -> CGImage? {
        let w = 1024, h = 512
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = [CGColor(red: 0.22, green: 0.19, blue: 0.62, alpha: 1), CGColor(red: 0.45, green: 0.35, blue: 0.95, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(h)), options: [])
        }
        var seed: UInt64 = 7
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        for _ in 0..<70 {
            let r = 6 + next() * 18
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10 + next() * 0.14))
            ctx.fillEllipse(in: CGRect(x: next() * Double(w) - r, y: next() * Double(h) * 0.9 + 20 - r, width: r * 2, height: r * 1.7))
        }
        if started, crack > 0 {
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
            ctx.setLineWidth(5)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let steps = 40
            let upTo = Int(Double(steps) * crack)
            var y = Double(h) * 0.5
            ctx.move(to: CGPoint(x: 0, y: y))
            seed = 11
            for i in 1...max(upTo, 1) {
                y = Double(h) * 0.5 + (i % 2 == 0 ? 1 : -1) * (14 + next() * 20)
                ctx.addLine(to: CGPoint(x: Double(w) * Double(i) / Double(steps), y: y))
            }
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    private static func halo() -> CGImage? {
        let s = 256
        guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        colors: [CGColor(red: 0.55, green: 0.6, blue: 1, alpha: 0.9), CGColor(red: 0.3, green: 0.3, blue: 1, alpha: 0)] as CFArray,
                                        locations: [0, 1]) else { return nil }
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0, endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: CGFloat(s / 2), options: [])
        return ctx.makeImage()
    }
}

#if os(macOS)
private struct EggSceneHost: NSViewRepresentable {
    var scene: SCNScene
    func makeNSView(context: Context) -> SCNView { configured(SCNView(), scene) }
    func updateNSView(_ view: SCNView, context: Context) {}
}
#else
private struct EggSceneHost: UIViewRepresentable {
    var scene: SCNScene
    func makeUIView(context: Context) -> SCNView { configured(SCNView(), scene) }
    func updateUIView(_ view: SCNView, context: Context) {}
}
#endif

@MainActor private func configured(_ view: SCNView, _ scene: SCNScene) -> SCNView {
    view.scene = scene
    view.pointOfView = scene.rootNode.childNodes.first { $0.camera != nil }
    view.backgroundColor = .clear
    view.antialiasingMode = .multisampling4X
    view.rendersContinuously = true
    view.allowsCameraControl = true
    view.defaultCameraController.interactionMode = .orbitTurntable
    view.defaultCameraController.inertiaEnabled = true
    return view
}

/// An egg opened up to look at: turn it, watch it crack, and start it or open it from here.
struct EggSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let eggID: String
    var opened: (Collectible) -> Void
    @State private var working = false
    @State private var problem: String?

    private var egg: RelayClient.EggInfo? { model.eggs.first { $0.id == eggID } }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
            }
            if let egg {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = model.secondsLeft(egg, at: context.date)
                    let progress = left.map { 1 - $0 / Double(max(egg.seconds, 1)) } ?? 0
                    VStack(spacing: 16) {
                        VStack(spacing: 4) {
                            Text(EggNames.name(egg.kind)).font(.system(size: 22, weight: .bold)).foregroundStyle(Ink.text)
                            Text(status(egg, left)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                                .foregroundStyle(left == 0 ? theme.accent : Ink.faint)
                        }
                        EggViewer3D(progress: progress, ready: left == 0, started: left != nil)
                            .frame(maxWidth: .infinity, minHeight: 300).frame(maxHeight: 440)
                            .background(
                                RadialGradient(colors: [Color(red: 0.07, green: 0.11, blue: 0.26), Color(red: 0.03, green: 0.04, blue: 0.09)],
                                               center: .bottom, startRadius: 0, endRadius: 460),
                                in: .rect(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Ink.line))
                            .clipShape(.rect(cornerRadius: 18))
                        if left == nil {
                            button("Start hatching") { try await model.startEgg(egg.id) }
                        } else if left == 0 {
                            button("Open") { let pet = try await model.hatchEgg(egg.id); dismiss(); opened(pet) }
                        }
                        if let problem { Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange) }
                        Text("You can't tell what's inside until it hatches.").font(.system(size: 12)).foregroundStyle(Ink.faint)
                    }
                }
            } else {
                Text("This egg has gone.").font(.system(size: 14)).foregroundStyle(Ink.faint)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Ink.surface)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 640)
        #endif
    }

    private func status(_ egg: RelayClient.EggInfo, _ left: TimeInterval?) -> String {
        guard let left else { return "Takes \(EggNames.minutes(egg.seconds)) to hatch" }
        if left == 0 { return "Ready to open" }
        let s = Int(left.rounded(.up))
        return s >= 3600 ? String(format: "Hatching · %d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "Hatching · %d:%02d", s / 60, s % 60)
    }

    private func button(_ title: String, _ run: @escaping () async throws -> Void) -> some View {
        Button {
            working = true
            problem = nil
            Task {
                do { try await run() } catch RelayClient.HatchError.notReady {
                    problem = "Not quite ready yet"
                } catch RelayClient.HatchError.soldOut {
                    problem = "Nothing left to hatch from this egg"
                } catch {
                    problem = "Couldn't reach the server"
                }
                working = false
            }
        } label: {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.onAccent)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(theme.accent, in: .capsule).opacity(working ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }
}
