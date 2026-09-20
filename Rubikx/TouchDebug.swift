import Observation

/// What the touch controller is doing, shown on screen in debug builds so gestures can be
/// checked on a device, where there is no console to watch and no way to script touches.
@MainActor
@Observable
final class TouchDebug {
    var text = ""
}
