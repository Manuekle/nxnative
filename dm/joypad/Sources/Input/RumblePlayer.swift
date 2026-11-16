import CoreHaptics
import Foundation

/// Plays the game's HD Rumble on the phone's Taptic Engine: one continuous haptic whose intensity and sharpness follow
/// the strongest actuator of the Joy-Con(s) the phone stands for. Everything runs on its own queue.
final class RumblePlayer: @unchecked Sendable {
    let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private let queue = DispatchQueue(label: "nxpad.rumble", qos: .userInteractive)
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var playing = false
    private var enabled = true
    private var strength: Float = 1
    private var mode: PadMode = .pair

    func configure(enabled: Bool, strength: Float) {
        queue.async { [self] in
            self.enabled = enabled
            self.strength = max(0, min(strength, 1))
            if !enabled { silence() }
        }
    }

    func setMode(_ newMode: PadMode) {
        queue.async { [self] in mode = newMode }
    }

    func play(_ frame: RumbleFrame) {
        queue.async { [self] in
            guard supported, enabled else { return }
            let motors: ArraySlice<Vibration>
            switch mode {
            case .pair: motors = frame.motors[...]
            case .left: motors = frame.motors.prefix(1)
            case .right: motors = frame.motors.dropFirst().prefix(1)
            }
            let levels = motors.map(Self.level)
            guard let strongest = levels.max(by: { $0.intensity < $1.intensity }),
                  strongest.intensity * strength > 0.02
            else {
                silence()
                return
            }
            render(intensity: min(1, strongest.intensity * strength), sharpness: strongest.sharpness)
        }
    }

    func stop() {
        queue.async { [self] in
            silence()
            engine?.stop(completionHandler: nil)
            engine = nil
            player = nil
        }
    }

    // MARK: Private

    struct Level {
        var intensity: Float
        var sharpness: Float
    }

    /// An actuator's two bands as one haptic: the louder band's amplitude (a gentle curve, as the phone's engine is
    /// weaker at low intensities), and a sharpness that rises with the amplitude-weighted pitch over HD Rumble's
    /// range of about 40 to 1250 Hz.
    static func level(_ v: Vibration) -> Level {
        func finite(_ x: Float) -> Float { x.isFinite ? max(0, x) : 0 }
        let al = min(finite(v.ampLow), 1), ah = min(finite(v.ampHigh), 1)
        let sum = al + ah
        let freq = sum > 0.001 ? (al * finite(v.freqLow) + ah * finite(v.freqHigh)) / sum : 160
        let sharp = log2(max(freq, 40) / 40) / log2(Float(1250) / 40)
        return Level(intensity: pow(max(al, ah), 0.6), sharpness: min(max(sharp, 0), 1))
    }

    private func render(intensity: Float, sharpness: Float) {
        do {
            if engine == nil { try startEngine() }
            if player == nil { player = try makePlayer() }
            let parameters = [
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
                // Added to the event's sharpness of 0.5.
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness - 0.5, relativeTime: 0),
            ]
            try player?.sendParameters(parameters, atTime: CHHapticTimeImmediate)
            if !playing {
                try player?.start(atTime: CHHapticTimeImmediate)
                playing = true
            }
        } catch {
            engine = nil
            player = nil
            playing = false
        }
    }

    private func silence() {
        guard playing else { return }
        try? player?.stop(atTime: CHHapticTimeImmediate)
        playing = false
    }

    private func startEngine() throws {
        let e = try CHHapticEngine()
        e.playsHapticsOnly = true
        e.isAutoShutdownEnabled = false
        e.resetHandler = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.player = nil
                self.playing = false
                try? self.engine?.start()
            }
        }
        e.stoppedHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.engine = nil
                self.player = nil
                self.playing = false
            }
        }
        try e.start()
        engine = e
    }

    private func makePlayer() throws -> CHHapticAdvancedPatternPlayer {
        guard let engine else { throw CocoaError(.featureUnsupported) }
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
        ], relativeTime: 0, duration: 30)
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let p = try engine.makeAdvancedPlayer(with: pattern)
        p.loopEnabled = true
        return p
    }
}
