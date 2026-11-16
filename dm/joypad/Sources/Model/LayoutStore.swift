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

    /// How far the stick goes before a direction presses its button.
    static let threshold: CGFloat = 0.45

    var isDefault: Bool { self == StickRule() }

    var mapsButtons: Bool { up != nil || down != nil || left != nil || right != nil }

    /// What the stick reports for a tilt, and the buttons its directions hold. y is up.
    func apply(_ v: CGVector) -> (stick: CGVector, buttons: Set<PadButton>) {
        var out = v
        var pressed = Set<PadButton>()
        let t = Self.threshold
        if let b = up { if v.dy > t { pressed.insert(b) }; out.dy = min(out.dy, 0) }
        if let b = down { if v.dy < -t { pressed.insert(b) }; out.dy = max(out.dy, 0) }
        if let b = right { if v.dx > t { pressed.insert(b) }; out.dx = min(out.dx, 0) }
        if let b = left { if v.dx < -t { pressed.insert(b) }; out.dx = max(out.dx, 0) }
        switch axis {
        case .both: break
        case .horizontal: out.dy = 0
        case .vertical: out.dx = 0
        }
        return (out, pressed)
    }
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

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controls = try c.decodeIfPresent([String: ControlTweak].self, forKey: .controls) ?? [:]
        extras = try c.decodeIfPresent([ExtraKey].self, forKey: .extras) ?? []
        locked = try c.decodeIfPresent(Set<PadButton>.self, forKey: .locked) ?? []
        sticks = try c.decodeIfPresent([String: StickRule].self, forKey: .sticks) ?? [:]
    }

    var isEmpty: Bool { controls.isEmpty && extras.isEmpty && locked.isEmpty && sticks.isEmpty }

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
