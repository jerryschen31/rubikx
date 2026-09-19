import Foundation
import RubikxCore
import simd

struct TouchSample {
    let id: ObjectIdentifier
    let point: SIMD2<Double>
    let time: TimeInterval
}

/// Turns fingers into layer turns and whole-cube rotations, tracking each finger on its own.
///
/// - A finger on the cube that moves pushes the sticker under it and turns that layer.
/// - A finger off the cube that moves rotates the whole cube, starting right away.
/// - A finger that stays still for `holdDuration` grips a layer, and every other finger that is
///   down and still grips with it. While the grip lasts, new fingers anywhere turn layers
///   parallel to the gripped one, and a gripping finger that drags turns the gripped layer.
///
/// A turning finger is *undecided* until it has moved far enough to pick a layer, then
/// *turning*. If its layer is on a different axis from a layer that is still off-grid, it is
/// *pending* until the cube is aligned again, and then starts measuring from where it is, so the
/// new turn never jumps. Layer fingers and whole-cube fingers never mix.
@MainActor
final class TouchController {
    private enum Phase {
        /// Down, no grip yet, not moved far enough to tell. Off the cube (`push` is nil) it
        /// already rotates the whole cube.
        case pressing(start: SIMD2<Double>, time: TimeInterval, push: FaceDrag?)
        /// Pushing a sticker, direction not yet clear.
        case pushing(FaceDrag)
        /// Under a grip, direction not yet clear.
        case gripping(HoldRole, start: SIMD2<Double>, hit: CubeHit?)
        /// Waiting for the cube to align. The role is nil for a sticker push.
        case pending(HoldRole?)
        case turning(Grip, baseAngle: Double, role: HoldRole?)
        case wholeCube
        /// Does nothing until it lifts.
        case ignored

        var rotatesWholeCube: Bool {
            switch self {
            case .pressing(_, _, nil), .wholeCube: true
            default: false
            }
        }

        var isLayerFinger: Bool {
            switch self {
            case .pushing, .gripping, .pending, .turning: true
            default: false
            }
        }
    }

    private struct Finger {
        var phase: Phase
        var point: SIMD2<Double>
    }

    private struct Hold {
        let gripped: (axis: Axis, layer: Int)
        let view: CubeProjection
        var holders: Set<ObjectIdentifier>
    }

    /// How long a finger must stay still to grip.
    static let holdDuration: TimeInterval = 0.35
    /// How far a finger may drift and still grip.
    static let holdSlop: Double = 10

    private let engine: TurnEngine
    private let rotator: WholeCubeRotator
    /// Hit-tests a screen point against the cube; nil when the point is off the cube.
    private let faceDrag: (SIMD2<Double>) -> FaceDrag?
    private let projection: () -> CubeProjection
    /// Radians of whole-cube rotation per point of drag.
    private let radiansPerPoint: () -> Double
    private var fingers: [ObjectIdentifier: Finger] = [:]
    private var hold: Hold?

    init(
        engine: TurnEngine,
        rotator: WholeCubeRotator,
        faceDrag: @escaping (SIMD2<Double>) -> FaceDrag?,
        projection: @escaping () -> CubeProjection,
        radiansPerPoint: @escaping () -> Double
    ) {
        self.engine = engine
        self.rotator = rotator
        self.faceDrag = faceDrag
        self.projection = projection
        self.radiansPerPoint = radiansPerPoint
    }

    func began(_ touches: [TouchSample]) {
        if fingers.isEmpty {
            rotator.hold()
        }
        Haptics.prepare()
        for touch in touches {
            let push = faceDrag(touch.point)
            let phase: Phase
            if hold != nil {
                phase = .gripping(.turner, start: touch.point, hit: push?.hit)
            } else if fingers.values.contains(where: { if case .wholeCube = $0.phase { true } else { false } }) {
                phase = .wholeCube  // Joins the rotation, so a two-finger twist can start anywhere.
            } else if fingers.values.contains(where: \.phase.isLayerFinger) {
                phase = push.map(Phase.pushing) ?? .ignored
            } else {
                phase = .pressing(start: touch.point, time: touch.time, push: push)
            }
            fingers[touch.id] = Finger(phase: phase, point: touch.point)
        }
    }

    func moved(_ touches: [TouchSample]) {
        let wholeCubeBefore = wholeCubePoints()
        var latestTime: TimeInterval = 0

        for touch in touches {
            guard var finger = fingers[touch.id] else { continue }
            finger.point = touch.point
            latestTime = max(latestTime, touch.time)

            switch finger.phase {
            case let .pressing(start, _, push):
                let movedAway = simd_distance(touch.point, start) > Self.holdSlop
                if let push {
                    if let grip = push.grip(to: touch.point) {
                        finger.phase = startTurning(grip, role: nil, finger: touch.id, at: touch)
                    } else if movedAway {
                        finger.phase = .pushing(push)
                    }
                } else if movedAway {
                    finger.phase = .wholeCube
                }
            case let .pushing(push):
                if let grip = push.grip(to: touch.point) {
                    finger.phase = startTurning(grip, role: nil, finger: touch.id, at: touch)
                }
            case let .gripping(role, start, hit):
                finger.phase = decide(role, from: start, hit: hit, at: touch)
            case let .turning(grip, baseAngle, role):
                let angle = baseAngle + grip.angle(at: touch.point)
                if !engine.drag(layer: grip.layer, finger: touch.id, to: angle, time: touch.time) {
                    // The turn was taken away (another finger grabbed the layer, or a reset).
                    finger.phase = .pending(role)
                }
            case .pending, .wholeCube, .ignored:
                break
            }
            fingers[touch.id] = finger
        }

        rotateWholeCube(from: wholeCubeBefore, to: wholeCubePoints(), time: latestTime)
    }

    func ended(_ touches: [TouchSample]) {
        var latestTime: TimeInterval = 0
        for touch in touches {
            latestTime = max(latestTime, touch.time)
            guard let finger = fingers.removeValue(forKey: touch.id) else { continue }
            if case let .turning(grip, _, _) = finger.phase {
                engine.release(layer: grip.layer, finger: touch.id, time: touch.time)
            }
            if hold?.holders.remove(touch.id) != nil, hold?.holders.isEmpty == true {
                endHold()
            }
        }
        if fingers.isEmpty {
            rotator.release(time: latestTime)
        }
    }

    /// Called every frame: grips once every finger down has stayed still and one of them long enough.
    func update(now: TimeInterval) {
        guard hold == nil, !fingers.isEmpty else { return }
        var ready = false
        for finger in fingers.values {
            guard case let .pressing(_, time, _) = finger.phase else { return }
            ready = ready || now - time >= Self.holdDuration
        }
        guard ready else { return }

        let holders = Set(fingers.keys)
        let centroid = fingers.values.reduce(SIMD2<Double>.zero) { $0 + $1.point } / Double(fingers.count)
        let view = projection()
        let gripped = view.grippedLayer(at: centroid, hit: faceDrag(centroid)?.hit)
        hold = Hold(gripped: gripped, view: view, holders: holders)
        for id in holders {
            fingers[id]!.phase = .gripping(.holder, start: fingers[id]!.point, hit: nil)
        }
        engine.showGrip(axis: gripped.axis, layer: gripped.layer)
        Haptics.grip()
    }

    /// Every layer is back on the grid: waiting fingers can pick their layer now, measured from
    /// where they are.
    func axisFreed() {
        for (id, finger) in fingers {
            guard case let .pending(role) = finger.phase else { continue }
            let push = faceDrag(finger.point)
            if let role {
                fingers[id]!.phase = hold == nil ? .ignored : .gripping(role, start: finger.point, hit: push?.hit)
            } else {
                fingers[id]!.phase = push.map(Phase.pushing) ?? .ignored
            }
        }
    }

    // MARK: - Helpers

    private func decide(_ role: HoldRole, from start: SIMD2<Double>, hit: CubeHit?, at touch: TouchSample) -> Phase {
        guard let hold else { return .ignored }
        let decision = hold.view.holdTurn(gripped: hold.gripped, role: role, from: start, to: touch.point, hit: hit) { axis, layer in
            engine.isHeld(axis: axis, layer: layer)
        }
        switch decision {
        case .wait: return .gripping(role, start: start, hit: hit)
        case .ignore: return .ignored
        case let .turn(grip): return startTurning(grip, role: role, finger: touch.id, at: touch)
        }
    }

    private func startTurning(_ grip: Grip, role: HoldRole?, finger id: ObjectIdentifier, at touch: TouchSample) -> Phase {
        guard engine.canGrab(grip.axis) else { return .pending(role) }
        let baseAngle = engine.grab(axis: grip.axis, layer: grip.layer, finger: id, time: touch.time)
        engine.drag(layer: grip.layer, finger: id, to: baseAngle + grip.angle(at: touch.point), time: touch.time)
        Haptics.grab()
        return .turning(grip, baseAngle: baseAngle, role: role)
    }

    /// The last gripping finger lifted. Layers still turning keep going; other fingers wait to lift.
    private func endHold() {
        hold = nil
        engine.showGrip(axis: nil, layer: 0)
        for (id, finger) in fingers {
            switch finger.phase {
            case .gripping, .pending(.some):
                fingers[id]!.phase = .ignored
            default:
                break
            }
        }
    }

    /// Positions of the fingers rotating the whole cube, in a stable order.
    private func wholeCubePoints() -> [(id: ObjectIdentifier, point: SIMD2<Double>)] {
        fingers
            .filter { $0.value.phase.rotatesWholeCube }
            .map { ($0.key, $0.value.point) }
            .sorted { $0.id.hashValue < $1.id.hashValue }
    }

    /// One finger rolls the cube like a trackball; two fingers also twist it.
    private func rotateWholeCube(
        from before: [(id: ObjectIdentifier, point: SIMD2<Double>)],
        to after: [(id: ObjectIdentifier, point: SIMD2<Double>)],
        time: TimeInterval
    ) {
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.point) })
        let pairs = after.compactMap { a in beforeByID[a.id].map { (old: $0, new: a.point) } }
        guard !pairs.isEmpty else { return }

        let count = Double(pairs.count)
        let oldCentroid = pairs.reduce(SIMD2<Double>.zero) { $0 + $1.old } / count
        let newCentroid = pairs.reduce(SIMD2<Double>.zero) { $0 + $1.new } / count
        var twist = 0.0
        if pairs.count >= 2 {
            let oldVector = pairs[1].old - pairs[0].old
            let newVector = pairs[1].new - pairs[0].new
            twist = atan2(newVector.y, newVector.x) - atan2(oldVector.y, oldVector.x)
            if twist > .pi { twist -= 2 * .pi }
            if twist < -.pi { twist += 2 * .pi }
        }
        let translation = newCentroid - oldCentroid
        guard simd_length(translation) > 0 || twist != 0 else { return }
        rotator.drag(translation: translation, twist: twist, radiansPerPoint: radiansPerPoint(), time: time)
    }
}
