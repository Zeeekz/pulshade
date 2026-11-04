import SwiftUI
import SceneKit
import simd

/// Pulze The Dragon as a 3D scene: a small dark blue dragon with bat ears standing in its lair with a
/// little treasure, lit from the front and rim-lit from behind. It breathes, its wings beat slowly, and `zap()`
/// makes it roar. It is turned by `setPose`, and `autoSpin` slowly turns it all the way round on its own.
final class DragonStage {
    typealias V3 = DragonMesh.V3
    typealias V4 = DragonMesh.V4

    let scene = SCNScene()
    let camera = SCNNode()
    private let look = SCNNode()
    private let pitchNode = SCNNode(), yawNode = SCNNode(), spinNode = SCNNode(), model = SCNNode(), body = SCNNode()
    private let leftWing = SCNNode(), rightWing = SCNNode(), leftArm = SCNNode(), rightArm = SCNNode()
    private let head = SCNNode(), tail = SCNNode(), eyes = SCNNode(), tailHalo = SCNNode(), breath = SCNNode()
    private var bolts: [(node: SCNNode, phase: Double)] = []
    private var breathBolts: [SCNNode] = []
    private let mouthLight = SCNNode()
    private let fire = SCNNode()
    private var fireSystem: SCNParticleSystem?
    private var fireTime: Double = -10
    private let hoardLight = SCNNode()
    private let backdrop = SCNNode()

    /// Where the camera sits from the middle of the stage, before zooming.
    static let distance: Float = 8.2
    static let focus = V3(0, 1.3, 0)
    private(set) var reduceMotion = false

    /// The mouth, where the fire comes from.
    private static let snout = V3(0.98, 1.68, 0)

    /// The rare one: the same dragon in gold.
    let golden: Bool

    init(reduceMotion: Bool = false, backdrop showsBackdrop: Bool = true, golden: Bool = false) {
        self.golden = golden
        self.reduceMotion = reduceMotion
        scene.background.contents = dc(0, 0, 0, 0)
        scene.lightingEnvironment.contents = DragonMesh.studioImage()
        scene.lightingEnvironment.intensity = 1.1

        let cam = SCNCamera()
        cam.fieldOfView = 32
        cam.zNear = 0.1
        cam.zFar = 40
        // A film look: bloom on the bright electric parts, soft contact shading, a touch of depth of field and a vignette.
        cam.wantsHDR = true
        cam.bloomIntensity = 0.6
        cam.bloomThreshold = 0.88
        cam.bloomBlurRadius = 14
        cam.screenSpaceAmbientOcclusionIntensity = 0.5
        cam.screenSpaceAmbientOcclusionRadius = 0.5
        cam.screenSpaceAmbientOcclusionBias = 0.02
        cam.vignettingIntensity = 0.55
        cam.vignettingPower = 1.3
        cam.contrast = 0.12
        cam.saturation = 1.12
        cam.wantsDepthOfField = true
        cam.focusDistance = CGFloat(Self.distance)
        cam.fStop = 2.4
        cam.focalBlurSampleCount = 12
        camera.camera = cam
        camera.simdPosition = V3(0, 1.7, Self.distance)
        look.simdPosition = Self.focus
        let aim = SCNLookAtConstraint(target: look)
        aim.isGimbalLockEnabled = true
        camera.constraints = [aim]
        scene.rootNode.addChildNode(camera)
        scene.rootNode.addChildNode(look)

        scene.rootNode.addChildNode(pitchNode)
        pitchNode.addChildNode(yawNode)
        yawNode.addChildNode(spinNode)
        spinNode.addChildNode(model)
        model.addChildNode(body)

        buildLights()
        buildDragon()
        buildBase()
        buildFire()
        backdrop.isHidden = !showsBackdrop
        if !reduceMotion { startIdle() }
        setPose(yaw: -0.55, pitch: 0.1, zoom: 1, duration: 0)
    }

    // MARK: Posing

    /// Turns the dragon `yaw` radians about its own upright and tips it `pitch` towards or away from the viewer, and
    /// brings the camera `zoom` times closer. With a `duration` the change eases in over that long.
    func setPose(yaw: Double, pitch: Double, zoom: Double, duration: Double) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        yawNode.simdEulerAngles = V3(0, Float(yaw), 0)
        pitchNode.simdEulerAngles = V3(Float(pitch), 0, 0)
        camera.simdPosition = V3(0, 1.7, Self.distance / Float(zoom))
        camera.camera?.focusDistance = CGFloat(Self.distance / Float(zoom))
        SCNTransaction.commit()
    }

    /// Shows the lightning breath, for a still picture of a zap.
    func showZap() { breath.isHidden = false }

    /// How far open the eyes are, 0 to 1, for a still picture of a blink.
    func setEyes(open: Float) { eyes.simdScale = V3(1, open, 1) }

    /// Frames the camera by hand, for a still picture.
    func frame(from position: V3, looking target: V3) {
        camera.simdPosition = position
        look.simdPosition = target
    }

    /// Turns slowly all the way round, once every 28 seconds, until told to stop.
    var autoSpin = false {
        didSet {
            guard autoSpin != oldValue else { return }
            spinNode.removeAction(forKey: "spin")
            if autoSpin && !reduceMotion {
                spinNode.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 28)), forKey: "spin")
            }
        }
    }

    /// Rears up and zaps, throwing lightning out of his mouth and flapping hard.
    func zap() {
        fireTime = CACurrentMediaTime()
        fireSystem?.birthRate = 900
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.15
        mouthLight.light?.intensity = 1600
        SCNTransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.fireSystem?.birthRate = 0
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            self?.mouthLight.light?.intensity = 0
            SCNTransaction.commit()
        }
    }

    // MARK: Idle

    /// Everything that moves on its own: breathing, a head that looks about, blinking, a swishing tail, swinging arms,
    /// and little wings. All whole turns per loop, so none of it jumps.
    private func startIdle() {
        let wingPeriod = 2.4
        let flap = SCNAction.repeatForever(.customAction(duration: wingPeriod) { [weak self] node, elapsed in
            guard let self else { return }
            let side: Float = node === self.rightWing ? -1 : 1
            let boost = max(0, 1 - (CACurrentMediaTime() - self.fireTime) / 1.4)
            let slow = 0.20 * sin(2 * .pi * Double(elapsed) / wingPeriod)
            let beat = 0.45 * boost * sin(CACurrentMediaTime() * 17)
            node.simdEulerAngles = V3(side * Float(slow + beat), 0, 0)
        })
        leftWing.runAction(flap)
        rightWing.runAction(flap)
        body.runAction(.repeatForever(.customAction(duration: 3) { node, elapsed in
            let breath = sin(2 * .pi * Double(elapsed) / 3)
            node.simdScale = V3(1 - Float(0.010 * breath), 1 + Float(0.022 * breath), 1 - Float(0.010 * breath))
        }))
        head.runAction(.repeatForever(.customAction(duration: 6) { node, elapsed in
            let t = Double(elapsed)
            node.simdEulerAngles = V3(0, Float(0.30 * sin(2 * .pi * t / 6)), Float(0.05 * sin(2 * .pi * t / 3)))
        }))
        tail.runAction(.repeatForever(.customAction(duration: 2) { [weak self] node, elapsed in
            guard let self else { return }
            let boost = max(0, 1 - (CACurrentMediaTime() - self.fireTime) / 1.6)
            let sway = 0.28 * sin(2 * .pi * Double(elapsed) / 2) + 0.5 * boost * sin(CACurrentMediaTime() * 14)
            node.simdEulerAngles = V3(0, Float(sway), 0)
        }))
        for (index, arm) in [leftArm, rightArm].enumerated() {
            let side: Float = index == 1 ? -1 : 1
            arm.runAction(.repeatForever(.customAction(duration: 3) { node, elapsed in
                let swing = 0.22 * sin(2 * .pi * Double(elapsed) / 3 + (index == 0 ? 0 : .pi))
                node.simdEulerAngles = V3(side * Float(0.35 + swing), 0, 0)
            }))
        }
        // Blinks, now and then, once in a while twice.
        eyes.runAction(.repeatForever(.customAction(duration: 7.5) { node, elapsed in
            var open: Float = 1
            for start in [2.6, 5.0, 5.35] {
                let dt = Double(elapsed) - start
                if dt > 0 && dt < 0.17 { open = Float(1 - 0.92 * sin(.pi * dt / 0.17)) }
            }
            node.simdScale = V3(1, open, 1)
        }))
        // The crackle: each bolt blinks on and off at its own pace, and jumps between its three zigzags.
        model.runAction(.repeatForever(.customAction(duration: 3) { [weak self] _, elapsed in
            guard let self else { return }
            let now = CACurrentMediaTime(), t = Double(elapsed) * 2 * .pi / 3
            self.hoardLight.light?.intensity = CGFloat(120 + 40 * sin(t * 2) + 25 * sin(t * 5 + 1) + 15 * sin(t * 9 + 2))
            for (i, bolt) in self.bolts.enumerated() {
                let on = sin(now * (7 + Double(i % 5)) + bolt.phase) * sin(now * (3.1 + Double(i % 3)) + bolt.phase * 2) > 0.12
                bolt.node.isHidden = !on
                if on { self.show(variant: Int(now * 15 + Double(i)) % 3, of: bolt.node) }
            }
            let zapping = now - self.fireTime < 1.0
            self.breath.isHidden = !zapping
            if zapping {
                for (i, bolt) in self.breathBolts.enumerated() {
                    bolt.isHidden = sin(now * 40 + Double(i) * 2.3) < -0.55
                    self.show(variant: Int(now * 22 + Double(i)) % 3, of: bolt)
                }
            }
            let pulse = 0.85 + 0.15 * sin(now * 11)
            self.tailHalo.simdScale = V3(Float(pulse), Float(pulse), Float(pulse))
        }))
    }

    private func show(variant: Int, of bolt: SCNNode) {
        for (index, child) in bolt.childNodes.enumerated() { child.isHidden = index != variant }
    }

    // MARK: Lights

    private func buildLights() {
        func light(_ type: SCNLight.LightType, _ colour: DragonColor, _ intensity: CGFloat, at p: V3, shadows: Bool = false) -> SCNNode {
            let l = SCNLight()
            l.type = type
            l.color = colour
            l.intensity = intensity
            if shadows {
                l.castsShadow = true
                l.shadowRadius = 9
                l.shadowSampleCount = 16
                l.shadowMode = .deferred
                l.shadowColor = dc(0, 0, 0, 0.6)
                l.shadowMapSize = CGSize(width: 2048, height: 2048)
            }
            let node = SCNNode()
            node.light = l
            node.simdPosition = p
            if type != .ambient { node.simdLook(at: V3(0, 1, 0)) }
            return node
        }
        scene.rootNode.addChildNode(light(.ambient, dc(0.45, 0.50, 0.95), 130, at: V3(0, 3, 0)))
        scene.rootNode.addChildNode(light(.directional, dc(0.88, 0.94, 1), 800, at: V3(3.4, 6, 4.2), shadows: true))
        scene.rootNode.addChildNode(light(.directional, dc(0.40, 0.62, 1), 950, at: V3(-4, 3.5, -4.5)))
        let fill = light(.omni, dc(0.40, 0.60, 1), 120, at: V3(-2.5, 0.8, 3.2))
        scene.rootNode.addChildNode(fill)
        // The glow of the fire in its throat.
        let flare = SCNLight()
        flare.type = .omni
        flare.color = dc(0.4, 0.7, 1)
        flare.intensity = 0
        flare.attenuationStartDistance = 0.2
        flare.attenuationEndDistance = 3.5
        mouthLight.light = flare
        mouthLight.simdPosition = Self.snout + V3(0.35, 0, 0)
        model.addChildNode(mouthLight)
    }

    // MARK: Dragon

    /// One crackle of lightning: a jagged line `length` long that can be seen as three different zigzags in turn, so
    /// that it seems to jump about.
    private func boltNode(length: Float, radius: Float, seed: Int, material: SCNMaterial) -> SCNNode {
        let node = SCNNode()
        for variant in 0..<3 {
            var points = [V3(0, 0, 0)]
            var radii: [Float] = [radius]
            let segments = 6
            for k in 1...segments {
                let u = Float(k) / Float(segments)
                let spread = length * 0.13 * (k == segments ? 0.4 : 1)
                points.append(V3(length * u, Float(DragonMesh.noise(seed * 7 + k, variant * 5 + 1) - 0.5) * 2 * spread,
                                 Float(DragonMesh.noise(seed * 7 + k, variant * 5 + 2) - 0.5) * 2 * spread))
                radii.append(radius * (1 - 0.65 * u))
            }
            let geometry = DragonMesh.tube(points, radii, sides: 5, per: 1, capStart: true, capEnd: true, tint: { _, _ in V4(1, 1, 1, 1) })
            geometry.materials = [material]
            let child = SCNNode(geometry: geometry)
            child.isHidden = variant != 0
            node.addChildNode(child)
        }
        return node
    }

    /// Pulze: a small, round, dark blue dragon with a gremlin's grin, big bat ears, glowing slit eyes, and electricity
    /// crackling round his tail and between his horns.
    private func buildDragon() {
        // Gold is the blues turned round: what was blue becomes red and green, and what was red fades.
        let golden = golden
        func dc(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> DragonColor { dcTone(golden, r, g, b, a) }
        let bumps = DragonMesh.scaleNormalMap()
        func material(_ colour: DragonColor, rough: CGFloat = 0.30, glow: DragonColor? = nil, scaled: Bool = false) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = colour
            m.roughness.contents = rough
            m.metalness.contents = 0.0
            if let glow { m.emission.contents = glow }
            if scaled { bump(m) }
            return m
        }
        func bump(_ m: SCNMaterial) {
            m.normal.contents = bumps
            m.normal.intensity = 0.28
            m.normal.wrapS = .repeat
            m.normal.wrapT = .repeat
        }
        func lit(_ colour: DragonColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = colour
            return m
        }
        let skin = material(dc(0.12, 0.24, 0.66), glow: dc(0.0, 0.04, 0.16), scaled: true)
        let darkSkin = material(dc(0.07, 0.14, 0.42), glow: dc(0.0, 0.03, 0.10), scaled: true)
        let lightSkin = material(dc(0.20, 0.36, 0.80), glow: dc(0.0, 0.05, 0.18), scaled: true)
        let belly = material(dc(0.46, 0.66, 0.98), rough: 0.5, glow: dc(0.05, 0.09, 0.18))
        let horn = material(dc(0.62, 0.92, 1.0), rough: 0.3, glow: dc(0.14, 0.34, 0.50))
        let inner = material(dc(0.2, 0.7, 1.0), rough: 0.5, glow: dc(0.10, 0.36, 0.6))
        let teeth = material(dc(0.94, 0.97, 1.0), rough: 0.25)
        let ink = material(dc(0.02, 0.03, 0.06), rough: 0.08)
        let brow = material(dc(0.04, 0.06, 0.20), rough: 0.5)
        let eyeball = material(dc(0.30, 0.95, 1.0), rough: 0.12, glow: dc(0.25, 0.85, 0.95))
        eyeball.emission.intensity = 1.2
        let shine = lit(dc(1, 1, 1))
        let spark = lit(dc(0.80, 0.97, 1.0))
        spark.blendMode = .add
        let orbMaterial = lit(dc(0.72, 0.96, 1.0))
        let painted = SCNMaterial()
        painted.lightingModel = .physicallyBased
        painted.diffuse.contents = dc(1, 1, 1)
        painted.roughness.contents = 0.30
        painted.emission.contents = dc(0.0, 0.03, 0.12)
        bump(painted)

        func put(_ node: SCNNode, in parent: SCNNode, at origin: V3 = V3(0, 0, 0)) {
            node.simdPosition -= origin
            parent.addChildNode(node)
        }
        func ball(_ p: V3, _ r: Float, _ scale: V3 = V3(1, 1, 1), _ m: SCNMaterial, in parent: SCNNode, origin: V3 = V3(0, 0, 0)) {
            var material = m
            if m.normal.contents != nil {
                // The same scales as on the tubes: about one tile for every 0.56 of surface.
                material = m.copy() as! SCNMaterial
                let u = Double(max(1, (2 * Float.pi * r * max(scale.x, scale.z) / 0.56).rounded())), v = Double(max(1, (Float.pi * r * scale.y / 0.56).rounded()))
                #if os(macOS)
                material.normal.contentsTransform = SCNMatrix4MakeScale(CGFloat(u), CGFloat(v), 1)
                #else
                material.normal.contentsTransform = SCNMatrix4MakeScale(Float(u), Float(v), 1)
                #endif
            }
            put(DragonMesh.ball(at: p, radius: r, scale: scale, material: material), in: parent, at: origin)
        }
        func ball(_ p: V3, _ r: Float, _ m: SCNMaterial, in parent: SCNNode, origin: V3 = V3(0, 0, 0)) {
            ball(p, r, V3(1, 1, 1), m, in: parent, origin: origin)
        }
        func cone(_ from: V3, _ to: V3, _ r: Float, _ m: SCNMaterial, in parent: SCNNode, origin: V3 = V3(0, 0, 0)) {
            put(DragonMesh.cone(from: from, to: to, radius: r, material: m), in: parent, at: origin)
        }
        /// A bolt placed at `p` and pointing along `direction`, crackling on and off.
        func addBolt(_ length: Float, _ radius: Float, at p: V3, along direction: V3, seed: Int, in parent: SCNNode) {
            let bolt = boltNode(length: length, radius: radius, seed: seed, material: spark)
            bolt.simdPosition = p
            bolt.simdOrientation = simd_quatf(from: V3(1, 0, 0), to: simd_normalize(direction))
            parent.addChildNode(bolt)
            bolts.append((bolt, Double(DragonMesh.noise(seed, 99)) * 6))
        }

        // Body and belly.
        ball(V3(0, 0.82, 0), 0.62, V3(0.95, 1.05, 0.92), skin, in: body)
        ball(V3(0.40, 0.78, 0), 0.50, V3(0.50, 0.95, 0.80), belly, in: body)

        // Feet with sharp pale claws.
        for side: Float in [-1, 1] {
            ball(V3(0.20, 0.17, 0.34 * side), 0.27, V3(1.25, 0.62, 0.95), darkSkin, in: body)
            for c: Float in [-1, 0, 1] {
                cone(V3(0.46, 0.13, (0.34 + c * 0.12) * side), V3(0.68, 0.09, (0.34 + c * 0.15) * side), 0.05, teeth, in: body)
            }
        }

        // Arms: little paws with claws, swinging from the shoulder.
        for side: Float in [-1, 1] {
            let node = side > 0 ? rightArm : leftArm
            let shoulder = V3(0.26, 1.12, 0.50 * side)
            ball(V3(0.05, -0.20, 0.06 * side) + shoulder, 0.15, V3(0.85, 1.55, 0.85), skin, in: node, origin: shoulder)
            ball(V3(0.10, -0.40, 0.09 * side) + shoulder, 0.115, V3(1, 0.9, 1), darkSkin, in: node, origin: shoulder)
            for c: Float in [-1, 0, 1] {
                cone(V3(0.15, -0.44, (0.09 + c * 0.05) * side) + shoulder, V3(0.25, -0.52, (0.09 + c * 0.075) * side) + shoulder, 0.028, teeth, in: node, origin: shoulder)
            }
            node.simdPosition = shoulder
            body.addChildNode(node)
        }

        // Tail: thick and curling, with spikes, a glowing orb on the end and lightning crackling all along it.
        let tailRoot = V3(-0.45, 0.55, 0)
        let tailPoints: [V3] = [V3(-0.45, 0.55, 0), V3(-0.85, 0.38, 0.12), V3(-1.25, 0.42, 0.40), V3(-1.52, 0.68, 0.56), V3(-1.44, 0.99, 0.50)]
        let tailRadius: [Float] = [0.25, 0.20, 0.15, 0.10, 0.05]
        let tailTint: (V3, Float) -> V4 = { n, _ in
            let under = DragonMesh.smooth(-0.1, -0.7, n.y)
            return DragonMesh.mix(V4(0.12, 0.24, 0.66, 1), V4(0.46, 0.66, 0.98, 1), under)
        }
        let tailGeometry = DragonMesh.tube(tailPoints.map { $0 - tailRoot }, tailRadius, sides: 24, per: 12, capStart: false, capEnd: true, tint: tailTint)
        tailGeometry.materials = [painted]
        tail.addChildNode(SCNNode(geometry: tailGeometry))
        let sampled = DragonMesh.sample(tailPoints.map { $0 - tailRoot }, tailRadius, per: 12)
        for i in stride(from: 8, to: sampled.count - 6, by: 9) {
            let r = sampled.radius[i]
            let base = sampled.path[i] + V3(0, 1, 0) * r * 0.9
            tail.addChildNode(DragonMesh.cone(from: base - V3(0, 0.03, 0), to: base + V3(-0.05, 0.12 + r * 0.7, 0), radius: 0.04 + r * 0.25, material: horn))
        }
        let end = tailPoints[tailPoints.count - 1] - tailRoot
        tail.addChildNode(DragonMesh.ball(at: end + V3(0, 0.10, 0), radius: 0.12, material: orbMaterial))
        let halo = SCNPlane(width: 0.9, height: 0.9)
        let haloMaterial = SCNMaterial()
        haloMaterial.lightingModel = .constant
        haloMaterial.diffuse.contents = DragonMesh.glowImage()
        haloMaterial.multiply.contents = dc(0.3, 0.7, 1.0)
        haloMaterial.blendMode = .add
        haloMaterial.writesToDepthBuffer = false
        haloMaterial.isDoubleSided = true
        halo.materials = [haloMaterial]
        tailHalo.geometry = halo
        tailHalo.simdPosition = end + V3(0, 0.10, 0)
        tailHalo.constraints = [SCNBillboardConstraint()]
        tailHalo.renderingOrder = 6
        tail.addChildNode(tailHalo)
        // Bolts leaping off the tail, some small, some big, and a fizz round the tip.
        var boltSeed = 1
        for i in stride(from: 5, to: sampled.count - 2, by: 6) {
            let out = V3(Float(DragonMesh.noise(boltSeed, 3) - 0.5) * 0.8, 1, Float(DragonMesh.noise(boltSeed, 4) - 0.5) * 1.4)
            addBolt(0.40 + Float(DragonMesh.noise(boltSeed, 5)) * 0.3, 0.021, at: sampled.path[i] + simd_normalize(out) * sampled.radius[i] * 0.9,
                    along: out + V3(-0.4, 0, 0), seed: boltSeed, in: tail)
            boltSeed += 1
        }
        for k in 0..<3 {
            let a = Float(k) / 3 * 2 * .pi
            addBolt(0.5, 0.022, at: end + V3(0, 0.10, 0), along: V3(cos(a) * 0.5, 0.8, sin(a)), seed: 40 + k, in: tail)
        }
        tail.simdPosition = tailRoot
        body.addChildNode(tail)

        // Spikes down the back, pale and glowing.
        for (from, to) in [(V3(-0.54, 1.25, 0), V3(-0.78, 1.46, 0)), (V3(-0.58, 0.90, 0), V3(-0.86, 1.02, 0)), (V3(-0.52, 0.62, 0), V3(-0.78, 0.62, 0))] {
            body.addChildNode(DragonMesh.cone(from: from, to: to, radius: 0.085, material: horn))
        }

        // Wings: bat-like and dark, with a purple-blue membrane.
        for side: Float in [-1, 1] {
            let node = side > 0 ? rightWing : leftWing
            let shoulder = V3(-0.10, 1.22, 0.40 * side)
            func w(_ x: Float, _ y: Float, _ z: Float) -> V3 { V3(x, y, z * side) }
            let S = w(0, 0, 0), E = w(-0.05, 0.60, 0.38), W = w(-0.30, 1.08, 0.80)
            let tips = [w(-0.28, 1.55, 1.05), w(-0.78, 1.28, 1.22), w(-0.92, 0.78, 0.96)]
            let A = w(-0.28, -0.55, 0.0)
            var edge: [V3] = [tips[0]]
            for k in 0..<2 {
                let mid = (tips[k] + tips[k + 1]) / 2
                edge.append(mid + (W - mid) * 0.30)
                edge.append(tips[k + 1])
            }
            edge.append(((tips[2] + A) / 2) + (W - (tips[2] + A) / 2) * 0.28)
            edge.append(A)
            var triangles: [(V3, V3, V3)] = []
            for k in 0..<(edge.count - 1) { triangles.append(side > 0 ? (W, edge[k], edge[k + 1]) : (W, edge[k + 1], edge[k])) }
            triangles.append(side > 0 ? (W, A, S) : (W, S, A))
            triangles.append(side > 0 ? (S, E, W) : (S, W, E))
            let reach = simd_length(tips[1] - W)
            let sheet = DragonMesh.membrane(triangles) { p in
                DragonMesh.mix(V4(0.20, 0.16, 0.62, 1), V4(0.42, 0.34, 0.98, 1), min(simd_length(p - W) / reach, 1))
            }
            sheet.materials = [material(dc(0.32, 0.26, 0.90), rough: 0.5, glow: dc(0.05, 0.04, 0.24))]
            node.addChildNode(SCNNode(geometry: sheet))
            func bone(_ pts: [V3], _ radii: [Float]) {
                let g = DragonMesh.tube(pts, radii, sides: 12, per: 8, capStart: true, capEnd: true, tint: { _, _ in V4(0.05, 0.09, 0.28, 1) })
                g.materials = [painted]
                node.addChildNode(SCNNode(geometry: g))
            }
            bone([S, E, W], [0.07, 0.055, 0.045])
            for tip in tips { bone([W, (W + tip) / 2 + V3(0, 0.03, 0), tip], [0.04, 0.03, 0.018]) }
            for tip in tips { node.addChildNode(DragonMesh.cone(from: tip - V3(0, 0.02, 0), to: tip + V3(0, 0.12, 0), radius: 0.03, material: teeth)) }
            node.simdPosition = shoulder
            body.addChildNode(node)
        }

        // Head: big and round, on the neck.
        let neck = V3(0.05, 1.40, 0)
        let eyeCentre = V3(0.72, 2.0, 0)
        head.simdPosition = neck
        body.addChildNode(head)
        ball(V3(0.10, 1.95, 0), 0.72, V3(1.0, 0.88, 1.12), skin, in: head, origin: neck)
        ball(V3(0.68, 1.79, 0), 0.34, V3(0.75, 0.60, 1.0), lightSkin, in: head, origin: neck)
        for side: Float in [-1, 1] {
            ball(V3(0.925, 1.85, 0.09 * side), 0.035, V3(0.5, 0.8, 1), ink, in: head, origin: neck)
            // Horns, pale and sharp, and big pointed bat ears with a glowing inside.
            cone(V3(0.0, 2.50, 0.28 * side), V3(-0.24, 3.00, 0.40 * side), 0.095, horn, in: head, origin: neck)
            cone(V3(-0.02, 2.12, 0.68 * side), V3(-0.40, 2.80, 1.28 * side), 0.27, darkSkin, in: head, origin: neck)
            cone(V3(0.03, 2.14, 0.72 * side), V3(-0.30, 2.66, 1.18 * side), 0.17, inner, in: head, origin: neck)
            // Slanted brows, low in the middle: a scowl.
            let browNode = DragonMesh.ball(at: V3(0.70, 2.15, 0.30 * side), radius: 0.15, scale: V3(0.4, 0.2, 1.1), material: brow)
            browNode.simdEulerAngles = V3(-0.5 * side, 0, 0)
            put(browNode, in: head, at: neck)
            // Eyes: glowing, with a slit pupil and a glint.
            ball(V3(0.72, 2.00, 0.31 * side), 0.16, V3(0.5, 0.9, 1.0), eyeball, in: eyes, origin: eyeCentre)
            ball(V3(0.785, 2.00, 0.31 * side), 0.07, V3(0.3, 1.5, 0.30), ink, in: eyes, origin: eyeCentre)
            ball(V3(0.79, 2.07, 0.27 * side), 0.03, shine, in: eyes, origin: eyeCentre)
        }
        eyes.simdPosition = eyeCentre - neck
        head.addChildNode(eyes)
        // A wide, wicked grin that turns up at the ends, with fangs.
        let grin: [V3] = [V3(0.77, 1.75, -0.27), V3(0.83, 1.675, -0.14), V3(0.862, 1.655, 0), V3(0.83, 1.675, 0.14), V3(0.77, 1.75, 0.27)]
        let smile = DragonMesh.tube(grin.map { $0 - neck }, [0.018, 0.018, 0.018, 0.018, 0.018], sides: 8, per: 6, capStart: true, capEnd: true, tint: { _, _ in V4(0.02, 0.03, 0.08, 1) })
        smile.materials = [painted]
        head.addChildNode(SCNNode(geometry: smile))
        let fangs: [(Float, Float, Float, Float)] = [(0.842, 1.668, -0.11, 0.05), (0.858, 1.658, -0.04, 0.045), (0.858, 1.658, 0.04, 0.045), (0.842, 1.668, 0.11, 0.05), (0.80, 1.71, -0.2, 0.04), (0.80, 1.71, 0.2, 0.04)]
        for (x, y, z, size) in fangs {
            cone(V3(x, y, z), V3(x + 0.004, y - size, z), 0.016, teeth, in: head, origin: neck)
        }
        // Crest on the back of the head.
        cone(V3(-0.40, 2.42, 0), V3(-0.62, 2.72, 0), 0.085, horn, in: head, origin: neck)
        cone(V3(-0.60, 2.05, 0), V3(-0.90, 2.20, 0), 0.085, horn, in: head, origin: neck)
        // A spark arcing from horn to horn.
        addBolt(0.80, 0.022, at: V3(-0.24, 3.0, -0.40) - neck, along: V3(0, 0, 1), seed: 60, in: head)
        // A few small sparks round the shoulders.
        addBolt(0.34, 0.019, at: V3(-0.2, 1.45, 0.5), along: V3(-0.3, 1, 0.8), seed: 61, in: body)
        addBolt(0.34, 0.019, at: V3(-0.2, 1.45, -0.5), along: V3(-0.3, 1, -0.8), seed: 62, in: body)

        // Lightning to breathe: big bolts fanning out of the mouth when he zaps.
        breath.simdPosition = Self.snout - neck
        for k in 0..<6 {
            let yaw = (Float(k) - 2.5) * 0.17, pitch = Float(DragonMesh.noise(k, 77) - 0.5) * 0.35
            let bolt = boltNode(length: 1.7, radius: 0.03, seed: 80 + k, material: spark)
            bolt.simdOrientation = simd_quatf(angle: yaw, axis: V3(0, 1, 0)) * simd_quatf(angle: pitch, axis: V3(0, 0, 1))
            breath.addChildNode(bolt)
            breathBolts.append(bolt)
        }
        breath.isHidden = true
        head.addChildNode(breath)
    }

    // MARK: Base

    /// The dragon's lair: a stone floor with rocks round it, heaps of gold and gems, stalagmites, sparks drifting up, and
    /// a cold electric glow from the hoard. The cave wall behind it is a flat picture that stays put as the dragon turns.
    private func buildBase() {
        let glow = DragonMesh.glowImage()
        func material(_ colour: DragonColor, rough: CGFloat, metal: CGFloat = 0, glow: DragonColor? = nil) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = colour
            m.roughness.contents = rough
            m.metalness.contents = metal
            if let glow { m.emission.contents = glow }
            return m
        }
        func sprite(_ size: CGFloat, _ colour: DragonColor, _ opacity: CGFloat) -> SCNNode {
            let plane = SCNPlane(width: size, height: size)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = glow
            m.multiply.contents = colour
            m.blendMode = .add
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            plane.materials = [m]
            let node = SCNNode(geometry: plane)
            node.opacity = opacity
            node.constraints = [SCNBillboardConstraint()]
            node.renderingOrder = 5
            return node
        }

        // The cave wall.
        let wall = SCNPlane(width: 20, height: 15)
        let wallMaterial = SCNMaterial()
        wallMaterial.lightingModel = .constant
        wallMaterial.diffuse.contents = DragonMesh.lairImage()
        wallMaterial.writesToDepthBuffer = false
        wall.materials = [wallMaterial]
        backdrop.geometry = wall
        backdrop.simdPosition = V3(0, 2.8, -7)
        backdrop.renderingOrder = -10
        scene.rootNode.addChildNode(backdrop)

        // Stone floor, in two steps, with a soft shadow under the dragon.
        let stone = material(dc(0.12, 0.13, 0.21), rough: 0.95)
        let floor = SCNCylinder(radius: 2.15, height: 0.16)
        floor.radialSegmentCount = 48
        floor.materials = [stone]
        let floorNode = SCNNode(geometry: floor)
        floorNode.simdPosition = V3(0, -0.08, 0)
        model.addChildNode(floorNode)
        let step = SCNCylinder(radius: 1.9, height: 0.05)
        step.radialSegmentCount = 48
        step.materials = [material(dc(0.09, 0.10, 0.17), rough: 0.95)]
        let stepNode = SCNNode(geometry: step)
        stepNode.simdPosition = V3(0, 0.025, 0)
        model.addChildNode(stepNode)
        let shadow = SCNPlane(width: 2.2, height: 2.2)
        let shadowMaterial = SCNMaterial()
        shadowMaterial.lightingModel = .constant
        shadowMaterial.diffuse.contents = glow
        shadowMaterial.multiply.contents = dc(0, 0, 0)
        shadowMaterial.writesToDepthBuffer = false
        shadowMaterial.isDoubleSided = true
        shadow.materials = [shadowMaterial]
        let shadowNode = SCNNode(geometry: shadow)
        shadowNode.simdEulerAngles = V3(-.pi / 2, 0, 0)
        shadowNode.simdPosition = V3(0.05, 0.056, 0)
        shadowNode.opacity = 0.7
        model.addChildNode(shadowNode)

        // Rocks round the edge, and stalagmites at the back.
        let rockMaterial = material(dc(0.10, 0.11, 0.18), rough: 0.9)
        for k in 0..<14 {
            let n = { (salt: Int) in Float(DragonMesh.noise(k, salt + 70)) }
            let angle = Float(k) / 14 * 2 * .pi + n(1) * 0.3
            let r = 0.12 + n(2) * 0.14
            model.addChildNode(DragonMesh.ball(at: V3(cos(angle) * 1.98, r * 0.5, sin(angle) * 1.98), radius: r, scale: V3(1.2, 0.8, 1), material: rockMaterial))
        }
        for (x, z, h, r) in [(Float(-1.75), Float(-0.55), Float(0.7), Float(0.15)), (1.7, -0.7, 0.9, 0.17), (-0.5, -1.85, 0.6, 0.12)] {
            model.addChildNode(DragonMesh.cone(from: V3(x, 0, z), to: V3(x + 0.05, h, z), radius: r, material: rockMaterial))
        }

        // Heaps of gold, with gems set in them.
        let gold = material(dc(1, 0.78, 0.25), rough: 0.28, metal: 1.0, glow: dc(0.20, 0.12, 0.0))
        let gems: [DragonColor] = [dc(0.9, 0.12, 0.2), dc(0.2, 0.5, 1), dc(0.15, 0.85, 0.45), dc(0.7, 0.3, 0.95)]
        func heap(_ centre: V3, _ radius: Float, _ count: Int, _ seed: Int) {
            let mound = DragonMesh.ball(at: centre + V3(0, 0.03, 0), radius: radius, scale: V3(1, 0.34, 1), material: gold)
            model.addChildNode(mound)
            for i in 0..<count {
                let n = { (salt: Int) in Float(DragonMesh.noise(i + seed * 40, salt)) }
                let angle = n(1) * 2 * .pi, d = radius * sqrt(n(2)) * 0.95
                let top = radius * 0.34 * sqrt(max(0, 1 - (d / radius) * (d / radius)))
                let coin = SCNCylinder(radius: 0.095, height: 0.018)
                coin.radialSegmentCount = 20
                coin.materials = [gold]
                let node = SCNNode(geometry: coin)
                node.simdPosition = centre + V3(cos(angle) * d, 0.03 + top + 0.01, sin(angle) * d)
                node.simdEulerAngles = V3((n(3) - 0.5) * 1.1, n(4) * 6, (n(5) - 0.5) * 1.1)
                model.addChildNode(node)
            }
            for g in 0..<3 {
                let n = { (salt: Int) in Float(DragonMesh.noise(g + seed * 9, salt + 30)) }
                let colour = gems[(g + seed) % gems.count]
                let gem = SCNSphere(radius: CGFloat(0.065 + n(1) * 0.03))
                gem.segmentCount = 4
                gem.materials = [material(colour, rough: 0.1, metal: 0.2, glow: colour.withAlphaComponent(0.35))]
                let node = SCNNode(geometry: gem)
                let angle = n(2) * 2 * .pi, d = radius * 0.55 * n(3)
                node.simdPosition = centre + V3(cos(angle) * d, 0.03 + radius * 0.34 * 0.8, sin(angle) * d)
                node.simdEulerAngles = V3(0.3, n(4) * 6, 0.2)
                model.addChildNode(node)
            }
        }
        heap(V3(-1.15, 0.05, -0.8), 0.80, 38, 1)
        heap(V3(1.10, 0.05, -0.9), 0.68, 30, 2)
        heap(V3(1.15, 0.05, 0.95), 0.42, 14, 3)

        // A cold electric glow, flickering.
        let flare = SCNLight()
        flare.type = .omni
        flare.color = dc(0.35, 0.62, 1.0)
        flare.intensity = 120
        flare.attenuationStartDistance = 0.5
        flare.attenuationEndDistance = 5
        hoardLight.light = flare
        hoardLight.simdPosition = V3(0, 0.7, -0.6)
        model.addChildNode(hoardLight)

        // Sparks rising off the gold and drifting up into the dark.
        for k in 0..<22 {
            let n = { (salt: Int) in Float(DragonMesh.noise(k, salt + 50)) }
            let hot = k % 3 == 0
            let ember = sprite(CGFloat(0.05 + n(1) * 0.07), hot ? dc(0.9, 1, 1) : dc(0.35, 0.65, 1), 0.9)
            let angle = n(2) * 2 * .pi, dist = 0.7 + n(3) * 1.4
            let start = V3(cos(angle) * dist, 0.1, sin(angle) * dist)
            let rise: Float = 1.6 + n(4) * 1.4
            ember.simdPosition = start + V3(0, n(5) * rise, 0)
            model.addChildNode(ember)
            if !reduceMotion {
                let period = 4.0 + Double(n(6)) * 3.0
                let phase = Double(n(5))
                ember.runAction(.repeatForever(.customAction(duration: period) { node, elapsed in
                    let k = (Double(elapsed) / period + phase).truncatingRemainder(dividingBy: 1)
                    node.simdPosition = start + V3(Float(sin(k * 2 * .pi * 2 + Double(n(7)) * 6) * 0.12), Float(k) * rise, 0)
                    node.opacity = CGFloat(sin(k * .pi) * 0.9)
                }))
            }
        }
    }

    // MARK: Fire

    private func buildFire() {
        let system = SCNParticleSystem()
        system.birthRate = 0
        system.loops = true
        system.emissionDuration = 1
        system.particleLifeSpan = 0.75
        system.particleLifeSpanVariation = 0.25
        system.particleVelocity = 3.4
        system.particleVelocityVariation = 1.0
        system.emittingDirection = SCNVector3(1, 0.06, 0)
        system.spreadingAngle = 13
        system.particleSize = 0.12
        system.particleSizeVariation = 0.06
        system.particleImage = DragonMesh.glowImage()
        system.particleColor = dc(0.45, 0.85, 1.0)
        system.particleColorVariation = SCNVector4(0.08, 0.1, 0.0, 0)
        system.blendMode = .additive
        system.isAffectedByGravity = false
        system.acceleration = SCNVector3(0, 0.6, 0)
        system.isLightingEnabled = false
        let size = CAKeyframeAnimation()
        size.values = [0.35, 1.2, 2.6]
        size.keyTimes = [0, 0.4, 1]
        size.duration = 1
        let fade = CAKeyframeAnimation()
        fade.values = [0.0, 1.0, 0.8, 0.0]
        fade.keyTimes = [0, 0.1, 0.55, 1]
        fade.duration = 1
        system.propertyControllers = [.size: SCNParticlePropertyController(animation: size), .opacity: SCNParticlePropertyController(animation: fade)]
        fireSystem = system
        fire.simdPosition = Self.snout
        fire.addParticleSystem(system)
        model.addChildNode(fire)
    }
}

extension DragonMesh {
    static func noise(_ i: Int, _ salt: Int) -> Double { ArtKit.noise(i, salt) }
}
