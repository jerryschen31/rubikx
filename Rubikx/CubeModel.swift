import Observation
import RubikxCore

/// What the cube view can be asked to do from outside it.
@MainActor
protocol CubeCommands: AnyObject {
    /// True when no layer is turning and no animated moves are queued.
    var isIdle: Bool { get }
    /// Animates `moves` in order, as quick turns.
    func play(_ moves: [Move])
    /// Jumps to `state` in the default orientation, dropping any turns in progress.
    func show(_ state: CubeState)
}

/// The cube's state and the user's move history. The single source of truth for the puzzle;
/// the view only animates towards it.
@MainActor
@Observable
final class CubeModel {
    private(set) var state = CubeState()
    private(set) var history: [Move] = []
    /// True from a scramble until the cube is next solved by hand.
    private(set) var isScrambled = false
    /// True right after the user solves a scrambled cube, until their next move.
    private(set) var justSolved = false

    @ObservationIgnored weak var view: CubeCommands?

    var canUndo: Bool { !history.isEmpty }

    /// Records a finished turn. `byUser` is false for scramble and undo animations.
    func commit(_ move: Move, byUser: Bool) {
        state.apply(move)
        guard byUser else { return }
        history.append(move)
        justSolved = false
        if isScrambled && state.isSolved {
            isScrambled = false
            justSolved = true
            Haptics.solved()
        }
    }

    func scramble() {
        guard let view, view.isIdle else { return }
        history = []
        isScrambled = true
        justSolved = false
        view.play(Scrambler.scramble())
    }

    func undo() {
        guard let view, view.isIdle, let last = history.popLast() else { return }
        justSolved = false
        view.play([last.inverse])
    }

    func reset() {
        state = CubeState()
        history = []
        isScrambled = false
        justSolved = false
        view?.show(state)
    }
}
