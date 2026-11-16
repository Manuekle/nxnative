import Foundation

/// What a held button turns into: the buttons it also presses, and a turbo that lets go and presses again.
enum ButtonMath {
    /// How long a turbo button is down, and then up, in seconds: ten presses a second.
    static let turboHalfPeriod: TimeInterval = 0.05

    /// Whether a turbo button is down at `time` (they all beat together).
    static func turboDown(at time: TimeInterval) -> Bool {
        Int((time / turboHalfPeriod).rounded(.down)) % 2 == 0
    }

    /// `held` plus the buttons each of them also presses.
    static func withCombos(_ held: Set<PadButton>, _ combos: [PadButton: Set<PadButton>]) -> Set<PadButton> {
        guard !combos.isEmpty else { return held }
        var out = held
        for b in held { if let extra = combos[b] { out.formUnion(extra) } }
        return out
    }

    /// `pressed` with the turbo buttons let go while the beat is up.
    static func withTurbo(_ pressed: Set<PadButton>, turbo: Set<PadButton>, down: Bool) -> Set<PadButton> {
        down ? pressed : pressed.subtracting(turbo)
    }
}
