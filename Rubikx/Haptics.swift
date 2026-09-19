import CoreHaptics
import UIKit

/// The clicks a physical cube makes, as haptics.
///
/// Core Haptics transients rather than `UIImpactFeedbackGenerator`, so each click's sharpness
/// can be tuned: the seat is a crisp mechanical click, the detents are soft ticks. Devices
/// without a Taptic Engine fall back to impact generators.
@MainActor
enum Haptics {
    private static let engine: CHHapticEngine? = makeEngine()
    private static var needsStart = false
    private static let fallback = UIImpactFeedbackGenerator(style: .rigid)
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    /// A finger touched down and may turn something.
    static func prepare() {
        if engine == nil {
            fallback.prepare()
        } else {
            startIfNeeded()
        }
    }

    /// A long-press grips a layer: a firmer squeeze than catching one.
    static func grip() {
        click(intensity: 0.8, sharpness: 0.5)
    }

    /// A finger catches a layer: its push has picked the layer to turn.
    static func grab() {
        click(intensity: 0.5, sharpness: 0.6)
    }

    /// A held layer passes a quarter turn.
    static func detent() {
        click(intensity: 0.35, sharpness: 0.4)
    }

    /// A released layer clicks into its quarter turn.
    static func seat() {
        click(intensity: 1, sharpness: 0.85)
    }

    /// The whole cube settles square-on in the hand.
    static func cubeSettled() {
        click(intensity: 0.55, sharpness: 0.3)
    }

    static func solved() {
        notificationGenerator.notificationOccurred(.success)
    }

    // MARK: - Engine

    private static func click(intensity: Float, sharpness: Float) {
        guard let engine else {
            fallback.impactOccurred(intensity: CGFloat(intensity))
            return
        }
        startIfNeeded()
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0
        )
        do {
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            needsStart = true
        }
    }

    private static func startIfNeeded() {
        guard needsStart, let engine else { return }
        needsStart = (try? engine.start()) == nil
    }

    private static func makeEngine() -> CHHapticEngine? {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let engine = try? CHHapticEngine() else { return nil }
        engine.playsHapticsOnly = true
        // The system stops the engine when the app goes to the background or the haptic server
        // resets; start it again on the next click.
        engine.stoppedHandler = { _ in
            Task { @MainActor in needsStart = true }
        }
        engine.resetHandler = {
            Task { @MainActor in needsStart = true }
        }
        try? engine.start()
        return engine
    }
}
