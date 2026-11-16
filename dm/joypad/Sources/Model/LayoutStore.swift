import Foundation
import Observation

/// What the player changed about one control: where it is, how large, whether it shows.
struct ControlTweak: Codable, Hashable {
    /// The centre, as fractions of the screen's width and height; nil where the layout puts it.
    var x: Double?
    var y: Double?
    /// Times the size the layout gives it.
    var scale: Double = 1
    var hidden = false

    static let scaleRange = 0.6...2.2

    var isDefault: Bool { x == nil && y == nil && scale == 1 && !hidden }
}

/// A key the player added: one more place to press a button the layout already has (or a stick's click).
struct ExtraKey: Codable, Hashable, Identifiable {
    /// The control's ID in the layout, "extra.<n>".
    var id: String
    var button: PadButton
}

/// What a stick does besides tilting: which way it reads, which buttons its directions press (a stick pushed up as an
/// accelerator, for a game that wants a button held), and whether it keeps its tilt when the thumb lifts.
struct StickRule: Codable, Hashable {
    enum Axis: String, Codable, CaseIterable, Identifiable {
        case both, horizontal, vertical
        var id: String { rawValue }
    }

    var axis: Axis = .both
    /// The button each direction holds down while the stick is tilted that way; the stick no longer reports that direction.
    var up: PadButton?
    var down: PadButton?
    var left: PadButton?
    var right: PadButton?
    /// The tilt stays when the thumb lifts, until the stick is tapped.
    var locksTilt = false
    /// Only the way the stick is tilted most counts for the buttons: four directions, no diagonals.
    var snapFour = false
    /// How far the stick goes before a direction presses its button, as a fraction of full tilt.
    var threshold = 0.45
    /// A button pressed at full tilt, whatever else the stick does (a sprint that comes with pushing all the way).
    var edge: PadButton?

    static let thresholdRange = 0.2...0.9

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        axis = try c.decodeIfPresent(Axis.self, forKey: .axis) ?? .both
        up = try c.decodeIfPresent(PadButton.self, forKey: .up)
        down = try c.decodeIfPresent(PadButton.self, forKey: .down)
        left = try c.decodeIfPresent(PadButton.self, forKey: .left)
        right = try c.decodeIfPresent(PadButton.self, forKey: .right)
        locksTilt = try c.decodeIfPresent(Bool.self, forKey: .locksTilt) ?? false
        snapFour = try c.decodeIfPresent(Bool.self, forKey: .snapFour) ?? false
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.45
        edge = try c.decodeIfPresent(PadButton.self, forKey: .edge)
    }

    /// The four directions made direction buttons, as a stick that stands in for the direction pad.
    static var directionButtons: StickRule {
        var r = StickRule()
        r.up = .up
        r.down = .down
        r.left = .left
        r.right = .right
        return r
    }

    var isDefault: Bool { self == StickRule() }

    var mapsButtons: Bool { up != nil || down != nil || left != nil || right != nil || edge != nil }

    /// What the stick reports for a tilt, and the buttons its directions hold. y is up.
    func apply(_ v: CGVector) -> (stick: CGVector, buttons: Set<PadButton>) {
        var out = v
        var pressed = Set<PadButton>()
        let t = CGFloat(min(max(threshold, 0.05), 0.95))
        let vertical = !snapFour || abs(v.dy) > abs(v.dx)
        let horizontal = !snapFour || abs(v.dx) >= abs(v.dy)
        if let b = up { if vertical, v.dy > t { pressed.insert(b) }; out.dy = min(out.dy, 0) }
        if let b = down { if vertical, v.dy < -t { pressed.insert(b) }; out.dy = max(out.dy, 0) }
        if let b = right { if horizontal, v.dx > t { pressed.insert(b) }; out.dx = min(out.dx, 0) }
        if let b = left { if horizontal, v.dx < -t { pressed.insert(b) }; out.dx = max(out.dx, 0) }
        if let b = edge, hypot(v.dx, v.dy) > 0.95 { pressed.insert(b) }
        switch axis {
        case .both: break
        case .horizontal: out.dy = 0
        case .vertical: out.dx = 0
        }
        return (out, pressed)
    }
}

/// A shift key: while it is held (or locked, the lock being the button's own), the other buttons become others, or nothing, so one
/// pad holds two sets of controls, such as driving and walking.
struct ShiftSpec: Codable, Hashable {
    var button: PadButton
    /// The shift key itself still reaches the game.
    var sendsButton = false
    /// For a button (by PadButton.rawValue), the button it becomes while shifted.
    var remap: [String: PadButton] = [:]
    /// Buttons that do nothing while shifted.
    var muted: Set<PadButton> = []

    init(button: PadButton) { self.button = button }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        button = try c.decode(PadButton.self, forKey: .button)
        sendsButton = try c.decodeIfPresent(Bool.self, forKey: .sendsButton) ?? false
        remap = try c.decodeIfPresent([String: PadButton].self, forKey: .remap) ?? [:]
        muted = try c.decodeIfPresent(Set<PadButton>.self, forKey: .muted) ?? []
    }

    var isIdle: Bool { remap.isEmpty && muted.isEmpty }

    /// What the buttons held become.
    func apply(_ held: Set<PadButton>) -> Set<PadButton> {
        guard held.contains(button) else { return held }
        var out = Set<PadButton>()
        for b in held {
            if b == button {
                if sendsButton { out.insert(b) }
            } else if !muted.contains(b) {
                out.insert(remap[b.rawValue] ?? b)
            }
        }
        return out
    }

    /// What `button` does while shifted.
    enum Target: Hashable {
        case same
        case nothing
        case other(PadButton)
    }

    func target(of b: PadButton) -> Target {
        if muted.contains(b) { return .nothing }
        if let t = remap[b.rawValue] { return .other(t) }
        return .same
    }

    mutating func set(_ t: Target, for b: PadButton) {
        remap[b.rawValue] = nil
        muted.remove(b)
        switch t {
        case .same: break
        case .nothing: muted.insert(b)
        case .other(let to): if to != b { remap[b.rawValue] = to }
        }
    }
}

/// The phone's own motion as a stick: turned like a steering wheel, or swept like an aim.
struct GyroRule: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        /// The phone turned like a steering wheel: its tilt is the stick's side to side.
        case wheel
        /// How fast the phone turns is how far the stick goes: the camera follows where the phone points.
        case aim
        var id: String { rawValue }
    }

    var mode: Mode = .wheel
    /// The stick it moves: the right one, or the left one.
    var rightStick = false
    var sensitivity = 1.0
    var invertX = false
    var invertY = false
    /// The motion counts only while this button is held (nil: always).
    var holdButton: PadButton?

    static let sensitivityRange = 0.5...3.0
}

/// A part of the screen where a finger sweeping steers a stick, from where it lands: the camera on a touch screen.
struct ZoneSpec: Codable, Hashable, Identifiable {
    /// The control's ID in the layout, "zone.<n>".
    var id: String
    var rightStick = true
    var sensitivity = 1.0
    var invertX = false
    var invertY = false

    static let sensitivityRange = 0.5...3.0
}

/// A layout the player made, for one way of holding the phone: the controls moved, resized or hidden, the keys added, and
/// the buttons that lock (a tap holds them down, the next tap lets them go), for a button a thumb cannot keep held while it
/// does something else.
struct PadProfile: Codable, Hashable {
    /// By control ID (Control.id).
    var controls: [String: ControlTweak] = [:]
    var extras: [ExtraKey] = []
    var locked: Set<PadButton> = []
    /// By stick control ID ("stick.left", "stick.right").
    var sticks: [String: StickRule] = [:]
    /// The phone's motion as a stick; nil is off.
    var gyro: GyroRule?
    var zones: [ZoneSpec] = []
    /// The layout has an area that is the Switch's touch screen: fingers on it touch the game's screen.
    var touchScreen = false
    /// The buttons that beat while held: let go and pressed again ten times a second (a locked one does it until the next tap).
    var turbo: Set<PadButton> = []
    /// The shift key, if the layout has one.
    var shift: ShiftSpec?
    /// For a button, the other buttons it presses with it (by PadButton.rawValue).
    var combos: [String: Set<PadButton>] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controls = try c.decodeIfPresent([String: ControlTweak].self, forKey: .controls) ?? [:]
        extras = try c.decodeIfPresent([ExtraKey].self, forKey: .extras) ?? []
        locked = try c.decodeIfPresent(Set<PadButton>.self, forKey: .locked) ?? []
        sticks = try c.decodeIfPresent([String: StickRule].self, forKey: .sticks) ?? [:]
        gyro = try c.decodeIfPresent(GyroRule.self, forKey: .gyro)
        zones = try c.decodeIfPresent([ZoneSpec].self, forKey: .zones) ?? []
        turbo = try c.decodeIfPresent(Set<PadButton>.self, forKey: .turbo) ?? []
        shift = try c.decodeIfPresent(ShiftSpec.self, forKey: .shift)
        touchScreen = try c.decodeIfPresent(Bool.self, forKey: .touchScreen) ?? false
        combos = try c.decodeIfPresent([String: Set<PadButton>].self, forKey: .combos) ?? [:]
    }

    var isEmpty: Bool { controls.isEmpty && extras.isEmpty && locked.isEmpty && sticks.isEmpty && gyro == nil && zones.isEmpty && turbo.isEmpty && combos.isEmpty && shift == nil && !touchScreen }

    func also(_ button: PadButton) -> Set<PadButton> { combos[button.rawValue] ?? [] }

    mutating func setAlso(_ extra: Set<PadButton>, for button: PadButton) {
        combos[button.rawValue] = extra.isEmpty ? nil : extra.subtracting([button])
    }

    /// A button no control draws any more keeps no lock, turbo or combo.
    mutating func forget(_ button: PadButton) {
        locked.remove(button)
        turbo.remove(button)
        combos[button.rawValue] = nil
        if shift?.button == button { shift = nil }
    }

    func rule(_ id: String) -> StickRule { sticks[id] ?? StickRule() }

    mutating func setRule(_ rule: StickRule, for id: String) {
        sticks[id] = rule.isDefault ? nil : rule
    }

    func tweak(_ id: String) -> ControlTweak { controls[id] ?? ControlTweak() }

    /// A tweak that changes nothing is not kept, so a layout put back by hand equals the one it started from.
    mutating func setTweak(_ tweak: ControlTweak, for id: String) {
        controls[id] = tweak.isDefault ? nil : tweak
    }

    mutating func addExtra(_ button: PadButton) -> String {
        let used = extras.compactMap { Int($0.id.dropFirst("extra.".count)) }
        let id = "extra.\((used.max() ?? 0) + 1)"
        extras.append(ExtraKey(id: id, button: button))
        return id
    }

    mutating func addZone() -> String {
        let used = zones.compactMap { Int($0.id.dropFirst("zone.".count)) }
        let id = "zone.\((used.max() ?? 0) + 1)"
        zones.append(ZoneSpec(id: id))
        return id
    }

    mutating func removeZone(_ id: String) {
        zones.removeAll { $0.id == id }
        controls[id] = nil
    }

    mutating func removeExtra(_ id: String) {
        extras.removeAll { $0.id == id }
        controls[id] = nil
    }
}

/// The layouts the player made: one for every game (per way of holding the phone), and one of its own for each game that
/// has one, known by the game's title ID (GameSession.gameKey). A game without its own uses the one for every game.
@MainActor
@Observable
final class LayoutStore {
    private(set) var profiles: [String: PadProfile] = [:]

    private static let defaultsKey = "layouts"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: PadProfile].self, from: data) {
            profiles = saved
        }
    }

    private static func key(_ game: String?, _ mode: PadMode) -> String {
        game.map { "game|\(mode.rawValue)|\($0)" } ?? "all|\(mode.rawValue)"
    }

    func hasOwn(game: String, mode: PadMode) -> Bool { profiles[Self.key(game, mode)] != nil }

    /// The layout a game plays with: its own, or the one for every game. `game` nil is the one for every game.
    func profile(game: String?, mode: PadMode) -> PadProfile {
        if let game, let own = profiles[Self.key(game, mode)] { return own }
        return profiles[Self.key(nil, mode)] ?? PadProfile()
    }

    /// A game's layout that equals the one for every game is not kept as its own: the game goes on following that one.
    func set(_ profile: PadProfile, game: String?, mode: PadMode) {
        let k = Self.key(game, mode)
        let redundant = game == nil ? profile.isEmpty : profile == self.profile(game: nil, mode: mode)
        let new: PadProfile? = redundant ? nil : profile
        guard profiles[k] != new else { return }
        profiles[k] = new
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}
