import Combine
import RealityKit
import RubikxCore
import UIKit

/// The RealityKit view: a non-AR `ARView` that renders the cube and receives raw touches.
///
/// `ARView` rather than `RealityView`, because it gives direct access to per-finger
/// `touchesBegan/Moved/Ended` plus `project(_:)`.
@MainActor
final class CubeARView: ARView, CubeCommands {
    private let model: CubeModel
    private let cubeScene: CubeScene
    private let engine: TurnEngine
    private var rotator: WholeCubeRotator!
    private var touchController: TouchController!

    private let camera = PerspectiveCamera()
    private var updateSubscription: Cancellable?

    /// Vertical field of view in degrees.
    static let fieldOfView: Float = 30
    /// Direction from the cube to the camera: above and to the right, so the top and right faces
    /// show clearly enough to push their stickers.
    static let viewDirection = simd_normalize(SIMD3<Float>(0.5, 0.6, 1))
    /// Fraction of the screen's shorter side the cube's outline spans.
    static let screenFill: Float = 0.7

    init(model: CubeModel) {
        self.model = model
        cubeScene = CubeScene(state: model.state)
        engine = TurnEngine(scene: cubeScene, model: model)
        super.init(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)

        rotator = WholeCubeRotator(cubeRoot: cubeScene.cubeRoot) { [unowned self] in
            camera.orientation(relativeTo: nil)
        }
        touchController = TouchController(
            engine: engine,
            rotator: rotator,
            faceDrag: { [unowned self] in faceDrag(at: $0) },
            projection: { [unowned self] in projection() },
            radiansPerPoint: { [unowned self] in radiansPerPoint() }
        )
        engine.onAxisFreed = { [unowned self] in touchController.axisFreed() }
        model.view = self

        isMultipleTouchEnabled = true
        environment.background = .color(UIColor(white: 0.09, alpha: 1))
        renderOptions.insert(.disableMotionBlur)

        camera.camera.fieldOfViewInDegrees = Self.fieldOfView
        let cameraAnchor = AnchorEntity(world: .zero)
        cameraAnchor.addChild(camera)
        scene.addAnchor(cameraAnchor)

        let light = DirectionalLight()
        light.light.intensity = 2800
        light.look(at: .zero, from: [2.5, 6, 5], relativeTo: nil)
        cameraAnchor.addChild(light)

        scene.addAnchor(cubeScene.anchor)

        updateSubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            let dt = event.deltaTime
            MainActor.assumeIsolated {
                self?.touchController.update(now: ProcessInfo.processInfo.systemUptime)
                self?.engine.update(dt)
                self?.rotator.update(dt)
            }
        }
    }

    @available(*, unavailable)
    required init(frame frameRect: CGRect) {
        fatalError("init(frame:) is not supported")
    }

    @available(*, unavailable)
    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionCamera()
    }

    /// Backs the camera off far enough that the square-on cube spans `screenFill` of the
    /// shorter side.
    private func positionCamera() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let tanVertical = tan(Self.fieldOfView * .pi / 360)
        let tanHorizontal = tanVertical * Float(bounds.width / bounds.height)
        let limit = min(tanVertical, tanHorizontal) * Self.screenFill
        let back = Self.viewDirection
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up = simd_cross(back, right)
        var distance: Float = 0
        for x in [-1, 1] as [Float] {
            for y in [-1, 1] as [Float] {
                for z in [-1, 1] as [Float] {
                    let corner = SIMD3(x, y, z) * Float(CubeHit.halfSize)
                    let offset = max(abs(simd_dot(corner, right)), abs(simd_dot(corner, up)))
                    distance = max(distance, simd_dot(corner, back) + offset / limit)
                }
            }
        }
        camera.look(at: .zero, from: back * distance, relativeTo: nil)
    }

    // MARK: - Hit testing

    /// The sticker push a finger at `point` starts, or nil if the point is off the cube.
    private func faceDrag(at point: SIMD2<Double>) -> FaceDrag? {
        guard let ray = ray(through: CGPoint(x: point.x, y: point.y)) else { return nil }
        let root = cubeScene.cubeRoot
        let origin = SIMD3<Double>(root.convert(position: ray.origin, from: nil))
        let direction = SIMD3<Double>(root.convert(direction: ray.direction, from: nil))
        // A small margin, so a touch just off an edge still grabs the edge sticker.
        guard let hit = CubeHit(origin: origin, direction: direction, margin: 0.12) else { return nil }

        let surface = SIMD3<Float>(hit.point)
        let onScreen = screenPoint(root.convert(position: surface, to: nil))
        return FaceDrag(hit: hit, start: point) { axis in
            let step: Float = 0.1
            let moved = screenPoint(root.convert(position: surface + SIMD3<Float>(axis.unit) * step, to: nil))
            return (moved - onScreen) / Double(step)
        }
    }

    /// How the cube currently sits on screen, for turns made while a long-press grips a layer.
    private func projection() -> CubeProjection {
        let root = cubeScene.cubeRoot
        let center = screenPoint(root.convert(position: .zero, to: nil))
        let cameraInCube = root.convert(position: camera.position(relativeTo: nil), from: nil)
        return CubeProjection(center: center, towardCamera: SIMD3<Double>(cameraInCube)) { axis in
            let step: Float = 0.1
            return (screenPoint(root.convert(position: SIMD3<Float>(axis.unit) * step, to: nil)) - center) / Double(step)
        }
    }

    /// Whole-cube radians per point of drag, so the cube's near side keeps pace with the finger.
    private func radiansPerPoint() -> Double {
        let right = camera.convert(direction: SIMD3<Float>(1, 0, 0), to: nil)
        let span = simd_length(screenPoint(right * Float(CubeHit.halfSize)) - screenPoint(.zero))
        return 1 / max(span, 1)
    }

    private func screenPoint(_ world: SIMD3<Float>) -> SIMD2<Double> {
        let point = project(world) ?? .zero
        return SIMD2(Double(point.x), Double(point.y))
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchController.began(samples(touches))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchController.moved(samples(touches))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchController.ended(samples(touches))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchController.ended(samples(touches))
    }

    private func samples(_ touches: Set<UITouch>) -> [TouchSample] {
        touches.map { touch in
            let point = touch.location(in: self)
            return TouchSample(id: ObjectIdentifier(touch), point: SIMD2(Double(point.x), Double(point.y)), time: touch.timestamp)
        }
    }

    // MARK: - CubeCommands

    var isIdle: Bool { engine.isIdle }

    func play(_ moves: [Move]) {
        engine.play(moves)
    }

    func show(_ state: CubeState) {
        rotator.resetOrientation()
        engine.reset(to: state)
    }
}
