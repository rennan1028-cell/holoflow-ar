import Foundation
import UIKit
import ARKit
import RealityKit
import Combine
import SwiftUI

/// O AR do HOLOFLOW.
/// - mira de posicionamento: mostra na superfície o contorno exato onde a cidade vai nascer
/// - toque: a cidade "sobe" do chão presa ali (mesa, chão, cama, bancada…)
/// - gestos: 1 dedo arrasta · 2 dedos giram · pinça aumenta/diminui · presets MESA / CHÃO / GIGANTE
/// - a cidade desliza suave para o passado (60 fps), sem saltos
/// - prédios com topo neon, halo nos muros, rio dourado do preço, coluna de luz, cone de projeção
/// - rótulos 3D que sempre olham para você, scanner varrendo a cidade, faíscas dos negócios
/// - baleia: feixe + onda + texto 3D + vibração forte
/// - sua mão e objetos reais passam NA FRENTE da cidade (oclusão) quando o iPhone suporta
final class ARController: NSObject, ObservableObject, ARSessionDelegate {
    let arView: ARView
    @Published var placed = false
    @Published var aiming = false           // a mira encontrou uma superfície
    @Published var sizeName = "MESA"

    private weak var model: CityModel?
    private var anchor: AnchorEntity?
    private let reticleAnchor = AnchorEntity(world: matrix_identity_float4x4)
    private let reticle = Entity()
    private let root = ModelEntity()          // recebe os gestos
    private let city = ModelEntity()          // malha que desliza (prédios, grade, rio do preço)
    private let fx = ModelEntity()            // malha fixa (coluna de luz, cone)
    private let frame = Entity()              // moldura holográfica
    private let scanner = ModelEntity()
    private let priceLabel = Entity()
    private let projLabel = Entity()
    private var sparks: [ModelEntity] = []
    private var sparkIdx = 0
    private var subs = Set<AnyCancellable>()
    private var drawTimer: Timer?
    private var mats: [RealityKit.Material] = []
    private var meshMid = 0.0                 // centro usado na última malha
    private var frameState = 0
    private var lastPriceText = "", lastProjText = ""
    private var lastLabelAt = Date.distantPast
    private var frameCount = 0
    private var t0 = Date()
    private var gestures: [EntityGestureRecognizer] = []

    // tamanho base (metros) — a pinça e os presets multiplicam
    let cw: Float = 0.008
    let rd: Float = 0.010
    let H: Float = 0.15
    var W: Float { Float(CityModel.N) * cw }
    var D: Float { Float(CityModel.T) * rd }

    override init() {
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        super.init()
        arView.renderOptions.insert(.disableMotionBlur)
        mats = ARController.makeMaterials()

        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal]
        cfg.environmentTexturing = .none
        // oclusão: objetos reais passam NA FRENTE da cidade (um modo OU outro, nunca os dois juntos)
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            // iPhone Pro (LiDAR): móveis, mãos e objetos escondem a cidade atrás deles
            cfg.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            // demais iPhones: a sua mão e o seu corpo passam na frente
            cfg.frameSemantics.insert(.personSegmentationWithDepth)
        }
        arView.session.delegate = self
        arView.session.run(cfg)

        let coach = ARCoachingOverlayView()
        coach.session = arView.session
        coach.goal = .horizontalPlane
        coach.activatesAutomatically = true
        coach.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(coach)

        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onTap(_:))))
        buildStatic()
        buildReticle()
        arView.scene.addAnchor(reticleAnchor)
        arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in self?.tick(dt: e.deltaTime) }.store(in: &subs)
    }

    func attach(_ m: CityModel) {
        guard model == nil else { return }
        model = m
        m.whale.receive(on: DispatchQueue.main).sink { [weak self] w in self?.whaleFX(x: w.x, buy: w.buy, mag: w.mag) }.store(in: &subs)
        m.tradeTick.receive(on: DispatchQueue.main).sink { [weak self] t in self?.spark(x: t.x, buy: t.buy, q: t.q) }.store(in: &subs)
        drawTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.redraw() }
        if let t = drawTimer { RunLoop.main.add(t, forMode: .common) }
    }

    // MARK: materiais (sem luz: brilham como holograma)
    static func unlit(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: Float = 1) -> UnlitMaterial {
        var m = UnlitMaterial(color: UIColor(red: r, green: g, blue: b, alpha: 1))
        if a < 1 { m.blending = .transparent(opacity: .init(scale: a)) }
        return m
    }
    private static func makeMaterials() -> [RealityKit.Material] {
        return [
            unlit(0.10, 0.85, 1.00),         // 0 compra · agora
            unlit(0.00, 0.55, 0.78),         // 1 compra · recente
            unlit(0.00, 0.24, 0.36),         // 2 compra · passado
            unlit(1.00, 0.25, 0.85),         // 3 venda · agora
            unlit(0.78, 0.08, 0.60),         // 4 venda · recente
            unlit(0.34, 0.03, 0.27),         // 5 venda · passado
            unlit(1.00, 0.84, 0.38),         // 6 preço (dourado)
            unlit(0.30, 1.00, 0.55, 0.70),   // 7 projeção de alta
            unlit(1.00, 0.25, 0.30, 0.70),   // 8 projeção de queda
            unlit(0.00, 0.50, 0.65, 0.50),   // 9 grade do chão
            unlit(0.85, 1.00, 1.00),         // 10 topo neon · compra
            unlit(1.00, 0.85, 1.00),         // 11 topo neon · venda
            unlit(0.20, 0.90, 1.00, 0.18),   // 12 halo · muro de compra
            unlit(1.00, 0.30, 0.90, 0.18),   // 13 halo · muro de venda
            unlit(0.45, 0.90, 1.00),         // 14 topo · compra recente
            unlit(1.00, 0.55, 0.95),         // 15 topo · venda recente
        ]
    }

    // MARK: cena fixa: plataforma, moldura, scanner, rótulos, faíscas
    private func buildStatic() {
        root.addChild(city)
        root.addChild(fx)
        // plataforma escura translúcida (dá contraste ao holograma sobre qualquer superfície)
        let plat = ModelEntity(mesh: .generateBox(size: [W + 0.05, 0.003, D + 0.11], cornerRadius: 0.004),
                               materials: [ARController.unlit(0.0, 0.03, 0.06, 0.78)])
        plat.position = [0, 0.0015, -D / 2 + 0.03]
        root.addChild(plat)
        setFrame(color: (0.0, 0.85, 1.0))
        root.addChild(frame)
        // scanner: parede de luz que varre a cidade de frente para trás
        scanner.model = ModelComponent(mesh: .generatePlane(width: W + 0.03, height: H * 1.25),
                                       materials: [ARController.unlit(0.2, 0.9, 1.0, 0.10)])
        let line = ModelEntity(mesh: .generateBox(size: [W + 0.03, 0.0015, 0.0015]), materials: [ARController.unlit(0.5, 1.0, 1.0)])
        line.position = [0, -H * 0.625 + 0.002, 0]
        scanner.addChild(line)
        let back = ModelEntity(mesh: .generatePlane(width: W + 0.03, height: H * 1.25), materials: [ARController.unlit(0.2, 0.9, 1.0, 0.10)])
        back.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        scanner.addChild(back)
        root.addChild(scanner)
        root.addChild(priceLabel)
        root.addChild(projLabel)
        // faíscas reaproveitáveis
        let sm = ModelEntity(mesh: .generateBox(size: 0.0028))
        for _ in 0..<36 {
            let s = sm.clone(recursive: false)
            s.model?.materials = [ARController.unlit(1, 1, 1)]
            s.isEnabled = false
            root.addChild(s); sparks.append(s)
        }
        // área de toque dos gestos
        root.collision = CollisionComponent(shapes: [ShapeResource.generateBox(size: [W + 0.06, 0.22, D + 0.14]).offsetBy(translation: [0, 0.11, -D / 2 + 0.03])])
    }

    private func setFrame(color c: (CGFloat, CGFloat, CGFloat)) {
        for c in Array(frame.children) { c.removeFromParent() }
        let m = ARController.unlit(c.0, c.1, c.2)
        let w = W + 0.05, d = D + 0.11, z0 = -D / 2 + 0.03, t: Float = 0.0018, y: Float = 0.0035
        let edges: [(SIMD3<Float>, SIMD3<Float>)] = [
            ([w, t, t], [0, y, z0 + d / 2]), ([w, t, t], [0, y, z0 - d / 2]),
            ([t, t, d], [-w / 2, y, z0]), ([t, t, d], [w / 2, y, z0])]
        for (size, pos) in edges {
            let e = ModelEntity(mesh: .generateBox(size: size), materials: [m]); e.position = pos; frame.addChild(e)
        }
        // cantoneiras altas nos 4 cantos
        for sx: Float in [-1, 1] { for sz: Float in [-1, 1] {
            let p = ModelEntity(mesh: .generateBox(size: [0.003, 0.03, 0.003]), materials: [m])
            p.position = [sx * w / 2, 0.015, z0 + sz * d / 2]; frame.addChild(p)
        } }
    }

    // mira: contorno do tamanho da cidade + cruz no centro
    private func buildReticle() {
        let m = ARController.unlit(0.2, 0.95, 1.0, 0.9)
        let w = W + 0.05, d = D + 0.11, t: Float = 0.002
        let parts: [(SIMD3<Float>, SIMD3<Float>)] = [
            ([w, t, t], [0, 0, 0.03]), ([w, t, t], [0, 0, 0.03 - d]),
            ([t, t, d], [-w / 2, 0, 0.03 - d / 2]), ([t, t, d], [w / 2, 0, 0.03 - d / 2]),
            ([0.04, t, t], [0, 0, 0]), ([t, t, 0.04], [0, 0, 0])]
        for (s, p) in parts { let e = ModelEntity(mesh: .generateBox(size: s), materials: [m]); e.position = p; reticle.addChild(e) }
        reticle.isEnabled = false
        reticleAnchor.addChild(reticle)
    }

    // MARK: colocar
    private func centerHit() -> ARRaycastResult? {
        let c = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        return arView.raycast(from: c, allowing: .existingPlaneGeometry, alignment: .horizontal).first
            ?? arView.raycast(from: c, allowing: .estimatedPlane, alignment: .horizontal).first
    }

    private func yawFacingCamera(_ p: SIMD3<Float>) -> simd_quatf {
        let c = arView.cameraTransform.translation
        return simd_quatf(angle: atan2(c.x - p.x, c.z - p.z), axis: [0, 1, 0])
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard !placed else { return }
        let pt = g.location(in: arView)
        let hit = arView.raycast(from: pt, allowing: .existingPlaneGeometry, alignment: .horizontal).first
            ?? arView.raycast(from: pt, allowing: .estimatedPlane, alignment: .horizontal).first
            ?? centerHit()
        guard let h = hit else { return }
        place(at: h.worldTransform)
    }

    func placeAtCenter() { if let h = centerHit() { place(at: h.worldTransform) } }

    private func place(at t: simd_float4x4) {
        let p = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let a = AnchorEntity(world: p)
        root.position = .zero                                     // zera arrastes de antes
        root.orientation = yawFacingCamera(p)
        let target = root.scale
        root.scale = [target.x, 0.02 * target.y, target.z]       // nasce achatada…
        a.addChild(root)
        arView.scene.addAnchor(a)
        anchor = a
        for g in gestures { arView.removeGestureRecognizer(g) }
        gestures = arView.installGestures([.translation, .rotation, .scale], for: root)
        var tt = root.transform; tt.scale = target
        root.move(to: tt, relativeTo: a, duration: 1.1, timingFunction: .easeOut)   // …e sobe
        reticle.isEnabled = false
        placed = true
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    func reposition() {
        if let a = anchor { root.removeFromParent(); arView.scene.removeAnchor(a) }
        anchor = nil
        placed = false
    }

    /// MESA = 1× (≈ 45 cm) · CHÃO = 4× (≈ 1,8 m) · GIGANTE = 10× (≈ 4,5 m, dá para andar dentro)
    func setSize(_ name: String) {
        let k: Float = name == "CHÃO" ? 4 : (name == "GIGANTE" ? 10 : 1)
        sizeName = name
        guard placed, let a = anchor else { root.scale = [k, k, k]; return }
        var t = root.transform; t.scale = [k, k, k]
        root.move(to: t, relativeTo: a, duration: 0.8, timingFunction: .easeInOut)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: a cada quadro (60 fps): deslizar, scanner, rótulos olhando para você, mira
    private func tick(dt: Double) {
        frameCount += 1
        if !placed {
            if frameCount % 3 == 0 {
                if let h = centerHit() {
                    let p = SIMD3<Float>(h.worldTransform.columns.3.x, h.worldTransform.columns.3.y, h.worldTransform.columns.3.z)
                    reticle.position = p
                    reticle.orientation = yawFacingCamera(p)
                    let s = root.scale.x
                    reticle.scale = [s, 1, s]
                    reticle.isEnabled = true
                    if !aiming { aiming = true }
                } else {
                    reticle.isEnabled = false
                    if aiming { aiming = false }
                }
            }
            return
        }
        guard let m = model else { return }
        // desliza suave para o passado e acompanha o preço de lado
        let frac = m.frozen ? 0 : min(1, Date().timeIntervalSince(m.lastAdvance) / m.advanceEvery)
        if !m.frozen { m.midBs += (m.midB - m.midBs) * min(1, dt * 4) }
        city.position = [Float(meshMid - m.midBs) * cw, 0, -Float(frac) * rd]
        // scanner
        let ph = Float(Date().timeIntervalSince(t0).truncatingRemainder(dividingBy: 3.2) / 3.2)
        scanner.position = [0, H * 0.625, 0.01 - ph * (D + 0.02)]
        scanner.isEnabled = m.gotBook
        // rótulos sempre de frente para a câmera
        for l in [priceLabel, projLabel] where l.isEnabled { faceCamera(l) }
    }

    /// gira o texto só no eixo vertical para ficar de frente para você (mantém posição e tamanho)
    private func faceCamera(_ e: Entity) {
        let cam = root.convert(position: arView.cameraTransform.translation, from: nil)
        let p = e.position
        e.orientation = simd_quatf(angle: atan2(cam.x - p.x, cam.z - p.z), axis: [0, 1, 0])
    }

    // MARK: rótulos 3D
    /// o texto fica num filho deslocado para o centro: o suporte gira pelo meio
    private func setLabel(_ e: Entity, _ text: String, _ color: UIColor, size: CGFloat) {
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.0006,
                                             font: .monospacedSystemFont(ofSize: size, weight: .heavy),
                                             containerFrame: .zero, alignment: .center, lineBreakMode: .byClipping)
        for c in Array(e.children) { c.removeFromParent() }
        let t = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        let b = mesh.bounds
        t.position = [-b.center.x, 0, 0]
        e.addChild(t)
    }

    private func updateLabels(_ m: CityModel) {
        guard Date().timeIntervalSince(lastLabelAt) > 0.4 else { return }
        lastLabelAt = Date()
        let pt = m.price > 0 ? String(format: "%.2f", m.price) : ""
        if pt != lastPriceText {
            lastPriceText = pt
            setLabel(priceLabel, pt, UIColor(red: 1, green: 0.86, blue: 0.45, alpha: 1), size: 0.016)
            priceLabel.position = [0, 0.235, 0]
        }
        let show = abs(m.projS) > 0.2
        projLabel.isEnabled = show
        if show {
            let up = m.projS > 0
            let txt = String(format: "%@ 15s  %.2f", up ? "▲" : "▼", m.price + m.projS * m.projSig)
            if txt != lastProjText {
                lastProjText = txt
                setLabel(projLabel, txt, up ? UIColor(red: 0.4, green: 1, blue: 0.6, alpha: 1) : UIColor(red: 1, green: 0.4, blue: 0.45, alpha: 1), size: 0.009)
            }
            let mvCols = Float(m.projS * m.projSig / m.tick) * cw
            projLabel.position = [mvCols, 0.03, 0.125]
        }
    }

    // MARK: a malha (redesenhada 4x por segundo; o deslizar é feito a cada quadro)
    private var P: [SIMD3<Float>] = []
    private var I: [UInt32] = []
    private var F: [UInt32] = []

    private func box(_ x0: Float, _ x1: Float, _ y0: Float, _ y1: Float, _ z0: Float, _ z1: Float, _ m: UInt32) {
        let o = UInt32(P.count)
        P += [[x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0], [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]]
        let t: [UInt32] = [4, 5, 6, 4, 6, 7,  0, 2, 1, 0, 3, 2,  5, 1, 2, 5, 2, 6,  0, 4, 7, 0, 7, 3,  7, 6, 2, 7, 2, 3,  0, 1, 5, 0, 5, 4]
        I += t.map { $0 + o }
        F += [UInt32](repeating: m, count: 12)
    }

    private func quadUp(_ xl0: Float, _ xr0: Float, _ z0: Float, _ xl1: Float, _ xr1: Float, _ z1: Float, _ y: Float, _ m: UInt32) {
        let o = UInt32(P.count)
        P += [[xl0, y, z0], [xr0, y, z0], [xr1, y, z1], [xl1, y, z1]]
        I += [0, 1, 2, 0, 2, 3].map { $0 + o }
        F += [m, m]
    }

    private func flush(into e: ModelEntity, name: String) {
        guard !I.isEmpty else { e.isEnabled = false; return }
        var d = MeshDescriptor(name: name)
        d.positions = MeshBuffers.Positions(P)
        d.primitives = .triangles(I)
        d.materials = .perFace(F)
        if let mesh = try? MeshResource.generate(from: [d]) {
            e.model = ModelComponent(mesh: mesh, materials: mats)
            e.isEnabled = true
        }
        P.removeAll(keepingCapacity: true); I.removeAll(keepingCapacity: true); F.removeAll(keepingCapacity: true)
    }

    private func redraw() {
        guard let m = model, m.gotBook, placed else { return }
        let N = CityModel.N, T = CityModel.T, half = W / 2 + cw
        let gx = cw * 0.10, gz = rd * 0.12
        meshMid = m.midBs

        // ---- cidade (desliza)
        var c = -half
        while c <= half { box(c - 0.0004, c + 0.0004, 0.0032, 0.0036, -D - rd, rd, 9); c += cw * 8 }
        for k in stride(from: 0, through: T, by: 6) { let z = -Float(k) * rd; box(-half, half, 0.0032, 0.0036, z - 0.0004, z + 0.0004, 9) }
        for age in 0..<T {
            let r = (m.head - age + T) % T
            guard m.rowValid[r] else { continue }
            let z1 = -Float(age) * rd - gz, z0 = -Float(age + 1) * rd + gz
            let fadeBack: Float = age > T - 6 ? Float(T - age) / 6 : 1
            for i in 0..<N {
                let vb = m.gridB[r][i], va = m.gridA[r][i]
                let v = max(vb, va)
                guard v > 0.03 else { continue }
                let x = (Float(m.rowBase[r] + i - N / 2) - Float(meshMid)) * cw
                guard abs(x) < half else { continue }
                let h = H * powf(min(v, 1.6), 0.7) * fadeBack
                let bid = vb >= va
                let tier: UInt32 = age < 3 ? 0 : (age < 14 ? 1 : 2)
                let x0 = x - cw / 2 + gx, x1 = x + cw / 2 - gx, y0: Float = 0.0035
                let cap: Float = min(0.002, h * 0.25)
                box(x0, x1, y0, y0 + h - cap, z0, z1, (bid ? 0 : 3) + tier)                       // corpo
                if tier < 2 { box(x0, x1, y0 + h - cap, y0 + h, z0, z1, tier == 0 ? (bid ? 10 : 11) : (bid ? 14 : 15)) } // topo neon
                if v > 0.95 && age < 20 {                                                             // halo dos muros
                    let g: Float = cw * 0.35
                    box(x0 - g, x1 + g, y0, y0 + h + g, z0 - g * 0.5, z1 + g * 0.5, bid ? 12 : 13)
                }
            }
            let px = (Float(m.rowMid[r]) - Float(meshMid)) * cw
            box(px - 0.0014, px + 0.0014, 0.0036, 0.0065, z0 - gz, z1 + gz, 6)                       // rio do preço
        }
        flush(into: city, name: "cidade")

        // ---- efeitos fixos: coluna de luz e cone da projeção (o futuro fica na frente)
        box(-0.0013, 0.0013, 0.0035, 0.22, -0.0013, 0.0013, 6)
        box(-0.006, 0.006, 0.0035, 0.0055, -0.006, 0.006, 6)
        if abs(m.projS) > 0.12 {
            let mvCols = Float(m.projS * m.projSig / m.tick) * cw
            let sigCols = Float(m.projSig / m.tick) * cw
            let mat: UInt32 = m.projS > 0 ? 7 : 8
            let L: Float = 0.11, K = 14
            for k in 0..<K {
                let f0 = Float(k) / Float(K), f1 = Float(k + 1) / Float(K)
                let e0 = f0 * f0 * (3 - 2 * f0), e1 = f1 * f1 * (3 - 2 * f1)
                let w0 = 0.002 + f0 * max(0.012, sigCols * 1.1), w1 = 0.002 + f1 * max(0.012, sigCols * 1.1)
                quadUp(mvCols * e0 - w0, mvCols * e0 + w0, 0.006 + f0 * L, mvCols * e1 - w1, mvCols * e1 + w1, 0.006 + f1 * L, 0.0045, mat)
            }
            box(mvCols - 0.0035, mvCols + 0.0035, 0.0035, 0.016, 0.006 + L - 0.0035, 0.006 + L + 0.0035, mat)
        }
        flush(into: fx, name: "efeitos")

        // ---- moldura muda de cor com a tendência
        let st = m.trend > 0.2 ? 1 : (m.trend < -0.2 ? -1 : 0)
        if st != frameState {
            frameState = st
            let up: (CGFloat, CGFloat, CGFloat) = (0.3, 1.0, 0.5), dn: (CGFloat, CGFloat, CGFloat) = (1.0, 0.3, 0.35), ne: (CGFloat, CGFloat, CGFloat) = (0.0, 0.85, 1.0)
            setFrame(color: st > 0 ? up : (st < 0 ? dn : ne))
        }
        updateLabels(m)
    }

    // MARK: faísca de cada negócio (≥ 3 contratos)
    private func spark(x: Double, buy: Bool, q: Double) {
        guard placed, q >= 3, !sparks.isEmpty else { return }
        let px = Float(x) * cw
        guard abs(px) < W / 2 else { return }
        let s = sparks[sparkIdx]; sparkIdx = (sparkIdx + 1) % sparks.count
        s.model?.materials = [buy ? ARController.unlit(0.4, 1.0, 0.8) : ARController.unlit(1.0, 0.35, 0.85)]
        let k = Float(min(3.0, 1 + log2(q / 3)))
        s.transform = Transform(scale: [k, k, k], rotation: simd_quatf(angle: 0, axis: [0, 1, 0]), translation: [px + Float.random(in: -0.002...0.002), 0.006, -0.004])
        s.isEnabled = true
        var t = s.transform
        t.translation += [Float.random(in: -0.01...0.01), 0.05 + 0.02 * k, Float.random(in: -0.006...0.006)]
        t.scale = [0.05, 0.05, 0.05]
        s.move(to: t, relativeTo: root, duration: 0.9, timingFunction: .easeOut)
    }

    // MARK: baleia: feixe de luz + onda no chão + texto 3D + vibração forte
    private func whaleFX(x: Double, buy: Bool, mag: Double) {
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.impactOccurred(intensity: CGFloat(min(1.0, 0.6 + mag * 0.15)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { gen.impactOccurred(intensity: 0.7) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5) }
        guard placed else { return }
        let px = Float(x) * cw
        guard abs(px) < W / 2 + cw else { return }
        let col = buy ? ARController.unlit(0.4, 1.0, 0.75) : ARController.unlit(1.0, 0.3, 0.8)
        let beam = ModelEntity(mesh: .generateBox(size: [0.003, 0.32, 0.003]), materials: [col])
        beam.position = [px, 0.16, -rd / 2]
        root.addChild(beam)
        var t = beam.transform; t.scale = [6, 1.2, 6]
        beam.move(to: t, relativeTo: root, duration: 0.9, timingFunction: .easeOut)
        let glow = ModelEntity(mesh: .generateBox(size: [0.012, 0.34, 0.012]),
                               materials: [buy ? ARController.unlit(0.4, 1.0, 0.75, 0.22) : ARController.unlit(1.0, 0.3, 0.8, 0.22)])
        glow.position = beam.position
        root.addChild(glow)
        for (i, k) in [9.0, 15.0].enumerated() {
            let wave = ModelEntity(mesh: .generatePlane(width: 0.02, depth: 0.02, cornerRadius: 0.01),
                                   materials: [buy ? ARController.unlit(0.4, 1.0, 0.75, 0.45) : ARController.unlit(1.0, 0.3, 0.8, 0.45)])
            wave.position = [px, 0.005 + Float(i) * 0.001, -rd / 2]
            root.addChild(wave)
            var tw = wave.transform; let s = Float(k + mag * 3); tw.scale = [s, 1, s]
            wave.move(to: tw, relativeTo: root, duration: 0.9 + Double(i) * 0.4, timingFunction: .easeOut)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4 + Double(i) * 0.4) { wave.removeFromParent() }
        }
        let txt = Entity()
        setLabel(txt, buy ? "BALEIA COMPRANDO" : "BALEIA VENDENDO", buy ? UIColor(red: 0.45, green: 1, blue: 0.7, alpha: 1) : UIColor(red: 1, green: 0.45, blue: 0.85, alpha: 1), size: 0.012)
        txt.position = [px, 0.26, -rd / 2]
        root.addChild(txt)
        faceCamera(txt)
        var tt = txt.transform; tt.translation.y += 0.04
        txt.move(to: tt, relativeTo: root, duration: 2.2, timingFunction: .easeOut)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { beam.removeFromParent(); glow.removeFromParent() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { txt.removeFromParent() }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let controller: ARController
    func makeUIView(context: Context) -> ARView { controller.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
