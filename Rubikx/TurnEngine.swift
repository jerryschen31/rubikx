import Foundation
import RubikxCore

/// Animates layer turns: finger-held layers, released layers settling on a spring, and queued
/// moves (scramble, undo).
///
/// Only one axis can be off-grid at a time, as on a real cube. Any number of layers on that axis
/// can turn at once, each with its own angle.
@MainActor
final class TurnEngine: LayerTurning {
    private struct LayerTurn {
        var angle: Double = 0
        var spring: LayerSpring?
        /// The finger holding the layer, if any.
        var holder: ObjectIdentifier?
        /// Recent (time, angle) samples for estimating the release velocity.
        var samples: [(time: TimeInterval, angle: Double)] = []
        /// The quarter turn the held layer was last nearest, for detent haptics.
        var detent = 0
        /// Whether the released layer has reached its quarter turn and clicked.
        var seated = false
    }

    private let scene: CubeScene
    private let model: CubeModel

    /// The axis whose layers are off-grid, if any.
    private(set) var axis: Axis?
    private var layers: [Int: LayerTurn] = [:]
    private var queue: [Move] = []
    private var isPlaying = false

    /// Called when every layer is back on the grid and no queued move is waiting.
    var onAxisFreed: (() -> Void)?

    static let velocityWindow: TimeInterval = 0.1
    /// How close, in radians, a settling layer must come to its quarter turn to click.
    static let seatTolerance = 0.03

    init(scene: CubeScene, model: CubeModel) {
        self.scene = scene
        self.model = model
    }

    var isIdle: Bool { axis == nil && queue.isEmpty && !isPlaying }

    /// Whether a finger may start turning a layer on `axis` now.
    func canGrab(_ axis: Axis) -> Bool {
        !isPlaying && queue.isEmpty && (self.axis == nil || self.axis == axis)
    }

    /// Whether a finger is holding `layer` on `axis`.
    func isHeld(axis: Axis, layer: Int) -> Bool {
        self.axis == axis && layers[layer]?.holder != nil
    }

    /// Highlights the layer a long-press grips, or clears it when `axis` is nil.
    func showGrip(axis: Axis?, layer: Int) {
        scene.setGrip(axis: axis, layer: layer, state: model.state)
        if axis != nil {
            Haptics.grip()
        }
    }

    // MARK: - Finger-driven turns

    /// Starts holding a layer and returns its current angle. Grabbing a settling layer stops it
    /// where it is, as a finger would.
    func grab(axis: Axis, layer: Int, finger: ObjectIdentifier, time: TimeInterval) -> Double {
        precondition(canGrab(axis))
        if self.axis == nil {
            self.axis = axis
        }
        if layers[layer] == nil {
            scene.beginTurn(axis: axis, layer: layer, state: model.state)
            layers[layer] = LayerTurn()
        }
        layers[layer]!.spring = nil
        layers[layer]!.seated = false
        layers[layer]!.holder = finger
        layers[layer]!.samples = [(time, layers[layer]!.angle)]
        layers[layer]!.detent = LayerSpring.quarterTurns(for: layers[layer]!.angle)
        scene.setHighlighted(true, layer: layer)
        Haptics.grab()
        return layers[layer]!.angle
    }

    /// Moves a held layer. Returns false if `finger` no longer holds it.
    @discardableResult
    func drag(layer: Int, finger: ObjectIdentifier, to angle: Double, time: TimeInterval) -> Bool {
        guard var turn = layers[layer], turn.holder == finger, let axis else { return false }
        turn.angle = angle
        turn.samples.append((time, angle))
        turn.samples.removeAll { time - $0.time > Self.velocityWindow }
        let detent = LayerSpring.quarterTurns(for: angle)
        if detent != turn.detent {
            turn.detent = detent
            Haptics.detent()
        }
        layers[layer] = turn
        scene.setAngle(angle, axis: axis, layer: layer)
        return true
    }

    /// Lets go of a layer: it keeps its momentum and settles into a quarter turn.
    func release(layer: Int, finger: ObjectIdentifier, time: TimeInterval) {
        guard var turn = layers[layer], turn.holder == finger else { return }
        turn.samples.append((time, turn.angle))
        turn.samples.removeAll { time - $0.time > Self.velocityWindow }
        var velocity = 0.0
        if let first = turn.samples.first, let last = turn.samples.last, last.time - first.time > 0.008 {
            velocity = (last.angle - first.angle) / (last.time - first.time)
        }
        let target = LayerSpring.snapTarget(angle: turn.angle, velocity: velocity)
        turn.spring = LayerSpring(angle: turn.angle, velocity: velocity, target: target)
        turn.holder = nil
        layers[layer] = turn
        scene.setHighlighted(false, layer: layer)
    }

    // MARK: - Queued moves

    /// Animates `moves` one after another once the layers in hand have settled. The moves are
    /// committed as non-user moves, so they don't enter the undo history.
    func play(_ moves: [Move]) {
        queue.append(contentsOf: moves)
        startNextQueuedMove()
    }

    private func startNextQueuedMove() {
        guard axis == nil, !queue.isEmpty else { return }
        let move = queue.removeFirst()
        isPlaying = true
        axis = move.axis
        for layer in move.layers {
            scene.beginTurn(axis: move.axis, layer: layer, state: model.state)
            let target = Double(move.quarterTurns) * LayerSpring.quarterTurn
            layers[layer] = LayerTurn(spring: LayerSpring(angle: 0, velocity: 0, target: target, response: 0.1, dampingRatio: 1))
        }
    }

    /// Drops every turn in progress and shows `state` as is.
    func reset(to state: CubeState) {
        queue = []
        layers = [:]
        axis = nil
        isPlaying = false
        scene.sync(state)
        onAxisFreed?()
    }

    // MARK: - Frame update

    func update(_ dt: TimeInterval) {
        guard let axis else { return }
        for (layer, var turn) in layers {
            guard var spring = turn.spring else { continue }
            spring.step(dt)
            turn.angle = spring.angle
            turn.spring = spring
            // Click as the layer arrives, not when the spring's last wobble dies out.
            if !turn.seated && abs(spring.angle - spring.target) < Self.seatTolerance {
                turn.seated = true
                if !isPlaying {
                    Haptics.seat()
                }
            }
            layers[layer] = turn
            scene.setAngle(turn.angle, axis: axis, layer: layer)
            if spring.isSettled {
                finish(layer: layer, axis: axis, target: spring.target)
            }
        }
    }

    private func finish(layer: Int, axis: Axis, target: Double) {
        let quarterTurns = LayerSpring.quarterTurns(for: target)
        if quarterTurns % 4 != 0 {
            model.commit(Move(axis: axis, layers: [layer], quarterTurns: quarterTurns), byUser: !isPlaying)
        }
        scene.endTurn(layer: layer, state: model.state)
        layers[layer] = nil

        guard layers.isEmpty else { return }
        self.axis = nil
        isPlaying = false
        startNextQueuedMove()
        if self.axis == nil {
            onAxisFreed?()
        }
    }
}
