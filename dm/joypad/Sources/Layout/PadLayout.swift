import SwiftUI

enum PadAction: Hashable {
    case menu
    /// To the next open game (shown while the phone is linked to more than one).
    case switchGame
}

enum KeyLabel: Hashable {
    case text(String)
    case symbol(String)
}

enum KeyShape {
    case circle(CGFloat)      // radius
    case capsule(CGSize)
    case square(CGFloat)      // side

    var size: CGSize {
        switch self {
        case .circle(let r): return CGSize(width: 2 * r, height: 2 * r)
        case .capsule(let s): return s
        case .square(let s): return CGSize(width: s, height: s)
        }
    }
}

/// Four keys around a centre, north, east, south, west: the left Joy-Con's direction buttons or the right one's ABXY.
/// A finger between two neighbours presses both, within `comboHalfAngle` degrees of the diagonal.
struct Cluster {
    var keys: [PadButton]
    var labels: [KeyLabel]
    var gap: CGFloat
    var keyRadius: CGFloat
    var comboHalfAngle: Double

    var reach: CGFloat { gap + keyRadius }

    static let offsets = [CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)]

    func keys(at p: CGPoint, center: CGPoint) -> Set<PadButton> {
        let dx = Double(p.x - center.x), dy = Double(center.y - p.y)
        guard hypot(dx, dy) >= Double(gap) * 0.3 else { return [] }   // the middle presses nothing
        var angle = atan2(dy, dx) * 180 / .pi
        if angle < 0 { angle += 360 }
        let directions: [Double] = [90, 0, 270, 180]
        var out = Set<PadButton>()
        for (i, key) in keys.enumerated() {
            var diff = abs(angle - directions[i])
            if diff > 180 { diff = 360 - diff }
            if diff < 45 + comboHalfAngle { out.insert(key) }
        }
        return out
    }
}

struct Control: Identifiable {
    enum Kind {
        case key(PadButton, KeyShape, KeyLabel)
        case cluster(Cluster)
        case stick(Side, ring: CGFloat, knob: CGFloat)
        case action(PadAction, radius: CGFloat)
    }

    let id: String
    let kind: Kind
    let center: CGPoint
    let side: Side

    /// How far a point is from the control, in units of its size: 0 at the centre, 1 on its edge.
    func score(_ p: CGPoint) -> CGFloat {
        let dx = p.x - center.x, dy = p.y - center.y
        switch kind {
        case .key(_, let shape, _):
            switch shape {
            case .circle(let r):
                return hypot(dx, dy) / r
            case .square(let s):
                return hypot(dx, dy) / (s * 0.62)
            case .capsule(let size):
                let r = size.height / 2
                let ex = max(0, abs(dx) - (size.width / 2 - r))
                return hypot(ex, dy) / r
            }
        case .cluster(let cluster):
            return hypot(dx, dy) / cluster.reach
        case .stick(_, let ring, _):
            return hypot(dx, dy) / ring
        case .action(_, let radius):
            return hypot(dx, dy) / radius
        }
    }

    /// How far beyond its edge a control still takes a touch (a thumb is wide and lands a little off).
    var slop: CGFloat {
        switch kind {
        case .key: return 1.35
        case .cluster: return 1.25
        case .stick: return 1.3
        case .action: return 1.6
        }
    }

    static func makeKey(_ button: PadButton, _ shape: KeyShape, _ label: KeyLabel, at p: CGPoint) -> Control {
        Control(id: "key.\(button.rawValue)", kind: .key(button, shape, label), center: p, side: button.side)
    }

    static func makeStick(_ side: Side, ring: CGFloat, knob: CGFloat, at p: CGPoint) -> Control {
        Control(id: side == .left ? "stick.left" : "stick.right", kind: .stick(side, ring: ring, knob: knob), center: p, side: side)
    }

    static func makeCluster(_ name: String, _ cluster: Cluster, side: Side, at p: CGPoint) -> Control {
        Control(id: "cluster.\(name)", kind: .cluster(cluster), center: p, side: side)
    }

    static func makeAction(_ action: PadAction, radius: CGFloat, side: Side, at p: CGPoint) -> Control {
        Control(id: "action.\(action)", kind: .action(action, radius: radius), center: p, side: side)
    }
}

/// One Joy-Con's shell: its rect, its corners and its coloured rail strip, in screen points.
struct BodyPiece: Identifiable {
    let id: String
    let side: Side
    let rect: CGRect
    let radii: RectangleCornerRadii
    let rail: CGRect
}

/// Where everything goes for a mode and a screen. The drawing and the touch surface both read it, so what you see
/// is what you press.
struct PadLayout {
    let key: String
    let mode: PadMode
    let bodies: [BodyPiece]
    let controls: [Control]
    let statusCenter: CGPoint
    let statusWidth: CGFloat
    let lightsCenter: CGPoint

    static let empty = PadLayout(key: "empty", mode: .pair, bodies: [], controls: [], statusCenter: .zero, statusWidth: 0, lightsCenter: .zero)

    /// `scale` is the player's Size setting (1 = as designed for a 414-point-tall phone). `switcher` adds the button that
    /// goes to the next open game, beside the menu's.
    static func make(mode: PadMode, size: CGSize, insets: EdgeInsets, scale: CGFloat = 1, switcher: Bool = false) -> PadLayout {
        guard size.width > 200, size.height > 150 else { return .empty }
        let layout: PadLayout
        switch mode {
        case .pair: layout = pair(size: size, insets: insets, scale: scale)
        case .left: layout = single(.left, size: size, insets: insets, scale: scale)
        case .right: layout = single(.right, size: size, insets: insets, scale: scale)
        }
        guard switcher, let menu = layout.control(for: .menu), case .action(_, let radius) = menu.kind else { return layout }
        let swap = Control.makeAction(.switchGame, radius: radius, side: menu.side, at: CGPoint(x: menu.center.x + 2.8 * radius, y: menu.center.y))
        return PadLayout(key: layout.key + " switcher", mode: layout.mode, bodies: layout.bodies, controls: layout.controls + [swap],
                         statusCenter: layout.statusCenter, statusWidth: layout.statusWidth, lightsCenter: layout.lightsCenter)
    }

    /// The control a new touch lands on, of any kind: the nearest one in units of size, within its slop.
    func control(at p: CGPoint) -> Control? {
        var best: Control?
        var bestScore = CGFloat.infinity
        for c in controls {
            let s = c.score(p)
            if s <= c.slop, s < bestScore {
                best = c
                bestScore = s
            }
        }
        return best
    }

    /// The keys under a finger that may slide from key to key (sticks and actions do not take a sliding finger).
    /// A key already held keeps the finger a little further out, so it does not flicker on its edge.
    func keys(at p: CGPoint, holding: Set<PadButton>) -> Set<PadButton> {
        var best: Control?
        var bestScore = CGFloat.infinity
        for c in controls {
            let held: Bool
            switch c.kind {
            case .key(let b, _, _): held = holding.contains(b)
            case .cluster(let cluster): held = !holding.isDisjoint(with: cluster.keys)
            case .stick, .action: continue
            }
            let s = c.score(p)
            if s <= c.slop + (held ? 0.2 : 0), s < bestScore {
                best = c
                bestScore = s
            }
        }
        guard let c = best else { return [] }
        switch c.kind {
        case .key(let b, _, _): return [b]
        case .cluster(let cluster): return cluster.keys(at: p, center: c.center)
        case .stick, .action: return []
        }
    }

    func control(for action: PadAction) -> Control? {
        controls.first { c in
            if case .action(let a, _) = c.kind { return a == action }
            return false
        }
    }

    // MARK: Layouts

    private static let arrows: [KeyLabel] = [
        .symbol("arrowtriangle.up.fill"), .symbol("arrowtriangle.right.fill"),
        .symbol("arrowtriangle.down.fill"), .symbol("arrowtriangle.left.fill"),
    ]

    private static func layoutKey(_ mode: PadMode, _ size: CGSize, _ insets: EdgeInsets, _ scale: CGFloat) -> String {
        "\(mode.rawValue) \(Int(size.width))x\(Int(size.height)) \(Int(insets.leading)) \(Int(insets.trailing)) \(Int(insets.bottom)) \(Int(scale * 100))"
    }

    // Where the thumbs are. Held sideways in both hands, a phone's thumbs pivot near its lower outer corners and reach about
    // 250 points in from the side: every control sits within that, sized in points (times the player's Size setting), not
    // stretched across the screen; a wide phone gets a wider gap in the middle instead. The controls used most are lowest
    // and outermost (the left stick, the right one's A B X Y), the next ones inward and a little lower (the direction
    // buttons, the right stick, as on a Pro Controller), the shoulders just above them in the outer column, the small
    // system buttons above the inner ones. No control comes near the top or bottom edge, where the system holds a quick
    // touch for its own gestures, and the shells stay clear of the camera notch or the Dynamic Island, which sit inside the
    // side inset (its last 10 points are only margin).

    private static let shellMargin: CGFloat = 8

    /// The y range controls may use: clear of the top and bottom edges.
    private static func controlBand(_ h: CGFloat, _ insets: EdgeInsets, top extra: CGFloat = 0) -> (top: CGFloat, bottom: CGFloat) {
        (shellMargin + 10 + extra, h - max(insets.bottom, 20) - 16)
    }

    /// Where a shell's outer edge goes: just clear of the notch or the Dynamic Island.
    private static func shellEdge(_ insets: EdgeInsets) -> CGFloat {
        max(max(insets.leading, insets.trailing) - 10, shellMargin)
    }

    /// Points per design unit: the phone's height against the 414 points the layout was drawn for, times the Size setting.
    private static func unit(_ h: CGFloat, _ scale: CGFloat) -> CGFloat {
        min(max(h / 414, 0.85), 1.1) * min(max(scale, 0.7), 1.4)
    }

    /// The phone held sideways in both hands as a Joy-Con pair: the left Joy-Con's shell on the left, the right one's on
    /// the right, the player lights, the status and the menu button in the gap between them. x is measured in from the
    /// outer edge of the controls, y up from the bottom of the control band.
    private static func pair(size: CGSize, insets: EdgeInsets, scale: CGFloat) -> PadLayout {
        let w = size.width, h = size.height
        let edge = shellEdge(insets)
        let band = controlBand(h, insets)
        let rail: CGFloat = 7, pad: CGFloat = 6
        let reach: CGFloat = 256   // design units from the controls' outer edge to the innermost control's inner edge
        // The halves' controls never meet in the middle: on a narrow phone the layout shrinks to keep a 110-point gap
        var u = unit(h, scale)
        u = min(u, ((w - 110) / 2 - edge - pad - rail - 8) / reach, (band.bottom - band.top) / 272)
        let shellW = pad + reach * u + 8 + rail
        let shellH = h - 2 * shellMargin
        let outer = min(shellW * 0.42, shellH * 0.3), inner: CGFloat = 16
        let bodies = [
            BodyPiece(id: "body.left", side: .left, rect: CGRect(x: edge, y: shellMargin, width: shellW, height: shellH),
                      radii: RectangleCornerRadii(topLeading: outer, bottomLeading: outer, bottomTrailing: inner, topTrailing: inner),
                      rail: CGRect(x: edge + shellW - rail, y: shellMargin, width: rail, height: shellH)),
            BodyPiece(id: "body.right", side: .right, rect: CGRect(x: w - edge - shellW, y: shellMargin, width: shellW, height: shellH),
                      radii: RectangleCornerRadii(topLeading: inner, bottomLeading: inner, bottomTrailing: outer, topTrailing: outer),
                      rail: CGRect(x: w - edge - shellW, y: shellMargin, width: rail, height: shellH)),
        ]
        let ox = edge + pad
        func L(_ x: CGFloat, _ up: CGFloat) -> CGPoint { CGPoint(x: ox + x * u, y: band.bottom - up * u) }
        func R(_ x: CGFloat, _ up: CGFloat) -> CGPoint { CGPoint(x: w - ox - x * u, y: band.bottom - up * u) }
        let shoulder = KeyShape.capsule(CGSize(width: 88 * u, height: 40 * u))
        let small = KeyShape.circle(17 * u)
        let controls: [Control] = [
            .makeStick(.left, ring: 56 * u, knob: 30 * u, at: L(74, 96)),
            .makeCluster("dpad", Cluster(keys: [.up, .right, .down, .left], labels: arrows,
                                         gap: 36 * u, keyRadius: 21 * u, comboHalfAngle: 22.5), side: .left, at: L(190, 58)),
            .makeKey(.l, shoulder, .text("L"), at: L(58, 186)),
            .makeKey(.zl, shoulder, .text("ZL"), at: L(58, 236)),
            .makeKey(.minus, small, .symbol("minus"), at: L(190, 148)),
            .makeKey(.capture, .square(30 * u), .symbol("circle.fill"), at: L(190, 196)),

            .makeCluster("face", Cluster(keys: [.x, .a, .b, .y], labels: [.text("X"), .text("A"), .text("B"), .text("Y")],
                                         gap: 42 * u, keyRadius: 25 * u, comboHalfAngle: 10), side: .right, at: R(78, 100)),
            .makeStick(.right, ring: 50 * u, knob: 27 * u, at: R(194, 58)),
            .makeKey(.r, shoulder, .text("R"), at: R(58, 196)),
            .makeKey(.zr, shoulder, .text("ZR"), at: R(58, 246)),
            .makeKey(.plus, small, .symbol("plus"), at: R(194, 148)),
            .makeKey(.home, small, .symbol("house.fill"), at: R(194, 196)),

            .makeAction(.menu, radius: 20, side: .left, at: CGPoint(x: w / 2, y: band.bottom - 30)),
        ]
        let gapW = w - 2 * (edge + shellW)
        return PadLayout(key: layoutKey(.pair, size, insets, scale), mode: .pair, bodies: bodies, controls: controls,
                         statusCenter: CGPoint(x: w / 2, y: h * 0.46), statusWidth: min(gapW - 24, 220),
                         lightsCenter: CGPoint(x: w / 2, y: band.top + 12))
    }

    /// One Joy-Con held sideways, rail away from the player and stick on the left, as one shell across the screen. The stick
    /// sits at the left thumb, the face buttons at the right one, SL and SR (a sideways Joy-Con's shoulders) above each, the
    /// rest inward. The face buttons keep the upright Joy-Con's names, turned with it (dm/host/pad_jc1.h,
    /// jc1_sideways_buttons): on the left one Right is on top, Down on the right, Left below and Up on the left; on the right
    /// one Y, X, A and B.
    private static func single(_ side: Side, size: CGSize, insets: EdgeInsets, scale: CGFloat) -> PadLayout {
        let w = size.width, h = size.height
        let edge = shellEdge(insets)
        let rail: CGFloat = 8
        let band = controlBand(h, insets, top: rail)
        let shellH = h - 2 * shellMargin
        let outer = min(shellH * 0.4, 160)
        let body = BodyPiece(id: "body", side: side, rect: CGRect(x: edge, y: shellMargin, width: w - 2 * edge, height: shellH),
                             radii: RectangleCornerRadii(topLeading: 18, bottomLeading: outer, bottomTrailing: outer, topTrailing: 18),
                             rail: CGRect(x: edge, y: shellMargin, width: w - 2 * edge, height: rail))
        var u = unit(h, scale)
        u = min(u, (w / 2 - edge - 30) / 276, (band.bottom - band.top) / 250)
        let ox = edge + 8
        func L(_ x: CGFloat, _ up: CGFloat) -> CGPoint { CGPoint(x: ox + x * u, y: band.bottom - up * u) }
        func R(_ x: CGFloat, _ up: CGFloat) -> CGPoint { CGPoint(x: w - ox - x * u, y: band.bottom - up * u) }
        let railKey = KeyShape.capsule(CGSize(width: 124 * u, height: 44 * u))
        let shoulder = KeyShape.capsule(CGSize(width: 76 * u, height: 40 * u))
        let small = KeyShape.circle(17 * u)
        var controls: [Control]
        if side == .left {
            controls = [
                .makeStick(.left, ring: 64 * u, knob: 33 * u, at: L(96, 100)),
                .makeCluster("face", Cluster(keys: [.right, .down, .left, .up], labels: arrows,
                                             gap: 50 * u, keyRadius: 29 * u, comboHalfAngle: 10), side: .left, at: R(110, 100)),
                .makeKey(.leftSL, railKey, .text("SL"), at: L(96, 220)),
                .makeKey(.leftSR, railKey, .text("SR"), at: R(110, 220)),
                .makeKey(.l, shoulder, .text("L"), at: L(226, 60)),
                .makeKey(.zl, shoulder, .text("ZL"), at: L(226, 116)),
                .makeKey(.minus, small, .symbol("minus"), at: L(226, 176)),
                .makeKey(.capture, .square(30 * u), .symbol("circle.fill"), at: R(236, 176)),
            ]
        } else {
            controls = [
                .makeStick(.right, ring: 64 * u, knob: 33 * u, at: L(96, 100)),
                .makeCluster("face", Cluster(keys: [.y, .x, .a, .b], labels: [.text("Y"), .text("X"), .text("A"), .text("B")],
                                             gap: 50 * u, keyRadius: 29 * u, comboHalfAngle: 10), side: .right, at: R(110, 100)),
                .makeKey(.rightSL, railKey, .text("SL"), at: L(96, 220)),
                .makeKey(.rightSR, railKey, .text("SR"), at: R(110, 220)),
                .makeKey(.r, shoulder, .text("R"), at: R(236, 60)),
                .makeKey(.zr, shoulder, .text("ZR"), at: R(236, 116)),
                .makeKey(.plus, small, .symbol("plus"), at: R(236, 176)),
                .makeKey(.home, small, .symbol("house.fill"), at: L(226, 176)),
            ]
        }
        controls.append(.makeAction(.menu, radius: 20, side: side, at: CGPoint(x: w / 2, y: band.bottom - 30)))
        let mode: PadMode = side == .left ? .left : .right
        return PadLayout(key: layoutKey(mode, size, insets, scale), mode: mode, bodies: [body], controls: controls,
                         statusCenter: CGPoint(x: w / 2, y: h * 0.42), statusWidth: max(min(w - 2 * (ox + 300 * u), 220), 110),
                         lightsCenter: CGPoint(x: w / 2, y: band.top + 12))
    }
}
