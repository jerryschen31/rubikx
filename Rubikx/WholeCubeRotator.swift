import Foundation
import RealityKit
import RubikxCore
import simd

/// Turns the whole cube in the user's hand: a trackball that follows the finger and a two-finger
/// twist about the view axis. When the cube is let go it keeps its momentum and settles
/// square-on, the way a layer settles into a quarter turn, so the front, top and right faces
/// always face the user.
@MainActor
final class WholeCubeRotator {
    private let cubeRoot: Entity
    /// The camera's world orientation, for converting screen drags into world rotations.
    private let cameraOrientation: () -> simd_quatf

    /// World-space angular velocity of the drag, in radians per second.
    private var velocity = SIMD3<Double>.zero
    private var lastDragTime: TimeInterval?
    private var isHeld = false
    private var spring: OrientationSpring?
    private var clicked = false

    static let maxSpeed = 25.0
    /// How close, in radians, the settling cube must come to square-on to click.
    static let settleTolerance = 0.03
    /// Settles smaller than this many radians don't click.
    static let quietCorrection = 0.1

    init(cubeRoot: Entity, cameraOrientation: @escaping () -> simd_quatf) {
        self.cubeRoot = cubeRoot
        self.cameraOrientation = cameraOrientation
    }

    /// A finger touched down: the cube stops where it is, as in a hand.
    func hold() {
        isHeld = true
        spring = nil
        velocity = .zero
        lastDragTime = nil
    }

    /// Rotates by a screen drag (points, y down) and a twist (radians, clockwise on screen).
    /// `radiansPerPoint` makes the cube's front face keep pace with the finger.
    func drag(translation: SIMD2<Double>, twist: Double, radiansPerPoint: Double, time: TimeInterval) {
        // Dragging right turns the cube about the camera's up axis; dragging down, about its
        // right axis. A clockwise twist is a negative turn about the axis toward the camera.
        let cameraSpace = SIMD3<Float>(
            Float(translation.y * radiansPerPoint),
            Float(translation.x * radiansPerPoint),
            Float(-twist)
        )
        let rotation = SIMD3<Double>(cameraOrientation().act(cameraSpace))
        apply(rotation)

        if let lastDragTime, time - lastDragTime > 0.001 {
            velocity = simd_mix(velocity, rotation / (time - lastDragTime), SIMD3(repeating: 0.5))
        }
        lastDragTime = time
    }

    /// Every finger lifted. The cube carries on with the drag's momentum into the nearest
    /// square-on orientation.
    func release(time: TimeInterval) {
        isHeld = false
        if let lastDragTime, time - lastDragTime > 0.06 {
            velocity = .zero  // The finger had stopped before lifting.
        }
        let speed = simd_length(velocity)
        if speed > Self.maxSpeed {
            velocity *= Self.maxSpeed / speed
        }
        let orientation = currentOrientation
        let target = OrientationSpring.snapTarget(orientation: orientation, velocity: velocity)
        let settling = OrientationSpring(orientation: orientation, velocity: velocity, target: target)
        velocity = .zero
        lastDragTime = nil
        guard !settling.isSettled else { return }
        // A tiny correction settles quietly; anything the user can see moving clicks into place.
        clicked = settling.remainingAngle < Self.quietCorrection
        spring = settling
    }

    func resetOrientation() {
        spring = nil
        velocity = .zero
        cubeRoot.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }

    func update(_ dt: TimeInterval) {
        guard !isHeld, var spring else { return }
        spring.step(dt)
        cubeRoot.orientation = simd_quatf(spring.orientation)
        if !clicked && spring.remainingAngle < Self.settleTolerance {
            clicked = true
            Haptics.cubeSettled()
        }
        self.spring = spring.isSettled ? nil : spring
    }

    private var currentOrientation: simd_quatd {
        simd_quatd(cubeRoot.orientation)
    }

    /// Applies a world-space rotation vector (axis × angle).
    private func apply(_ rotation: SIMD3<Double>) {
        let angle = simd_length(rotation)
        guard angle > 1e-6 else { return }
        let delta = simd_quatf(angle: Float(angle), axis: SIMD3<Float>(rotation / angle))
        cubeRoot.orientation = simd_normalize(delta * cubeRoot.orientation)
    }
}

private extension simd_quatd {
    init(_ q: simd_quatf) {
        self.init(ix: Double(q.imag.x), iy: Double(q.imag.y), iz: Double(q.imag.z), r: Double(q.real))
    }
}

private extension simd_quatf {
    init(_ q: simd_quatd) {
        self.init(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real))
    }
}
