import SwiftUI
import UIKit

struct TouchOptions: Equatable {
    /// Stick dead zone, as a fraction of full tilt.
    var deadzone: CGFloat = 0.12
    /// A stick's centre is wherever the thumb lands, not the drawn ring's centre.
    var floating = false
    /// A light tap of the Taptic Engine on every new press.
    var pressHaptics = true
}

/// The one view that takes touches on the controller screen. It tracks every finger itself, so several press at once
/// and a finger slides from key to key (rolling over the direction buttons, A to B) the way thumbs do on a real pad.
struct TouchSurface: UIViewRepresentable {
    let layout: PadLayout
    let options: TouchOptions
    /// The controller is covered (its menu is open) or the app is not in front: everything is let go, locked buttons too.
    var paused = false
    let onFrame: (InputFrame) -> Void
    let onAction: (PadAction) -> Void
    let onOrientation: (UIInterfaceOrientation) -> Void

    func makeUIView(context: Context) -> TouchSurfaceView {
        TouchSurfaceView()
    }

    func updateUIView(_ view: TouchSurfaceView, context: Context) {
        view.onFrame = onFrame
        view.onAction = onAction
        view.onOrientation = onOrientation
        view.options = options
        view.layout = layout
        view.paused = paused
    }
}

final class TouchSurfaceView: UIView {
    var layout = PadLayout.empty {
        didSet {
            // Another mode or screen size: whatever the fingers held is gone.
            if layout.key != oldValue.key { releaseAll() }
        }
    }
    var options = TouchOptions()
    var paused = false {
        didSet {
            if paused, !oldValue { releaseAll() }
        }
    }
    var onFrame: ((InputFrame) -> Void)?
    var onAction: ((PadAction) -> Void)?
    var onOrientation: ((UIInterfaceOrientation) -> Void)?

    private struct StickGrab {
        let side: Side
        let origin: CGPoint
        let ring: CGFloat
        let began: TimeInterval
        var travel: CGFloat
        /// The second touch of a double tap: the stick stays clicked while it lasts.
        let held: Bool
        /// The touch that lets a locked tilt go, or sweeps a camera area: it clicks nothing.
        var noClick = false
        /// A camera area can turn an axis round.
        var flipX = false
        var flipY = false
    }

    private enum Owner {
        case stick(StickGrab)
        case screen(slot: UInt8, rect: CGRect)
        case keys(Set<PadButton>)
        case action(PadAction, inside: Bool)
    }

    private static let tapMaxDuration: TimeInterval = 0.25
    private static let doubleTapWindow: TimeInterval = 0.3
    private static let clickPulse: TimeInterval = 0.09

    private var owners: [ObjectIdentifier: Owner] = [:]
    /// The fingers on the touch screen area, by touch.
    private var screenPoints: [ObjectIdentifier: TouchPoint] = [:]
    private var sticks: [Side: CGVector] = [:]
    private var stickOwner: [Side: ObjectIdentifier] = [:]
    private var lastTap: [Side: TimeInterval] = [:]
    private var pulses: [PadButton: CFTimeInterval] = [:]
    /// The locking buttons held down now (PadLayout.locking): a touch that begins on one turns it on or off; a finger that
    /// slides onto one, or stays on it, does nothing.
    private var latched: Set<PadButton> = []
    private var last = InputFrame()
    /// What was held before the turbo let go of it, to buzz only for a new press and not for every beat.
    private var lastHeld: Set<PadButton> = []
    private var turboTimer: Timer?
    private var lastOrientation = UIInterfaceOrientation.unknown
    private lazy var feedback = UIImpactFeedbackGenerator(style: .light, view: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(deviceTurned),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Orientation (the motion frame depends on which way the screen is turned)

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportOrientation()
        if window != nil { feedback.prepare() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportOrientation()
    }

    @objc private func deviceTurned() {
        // The interface turns a moment after the device does.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.reportOrientation()
        }
    }

    private func reportOrientation() {
        // Not before SwiftUI has handed over the callback, or the first orientation would be lost.
        guard let report = onOrientation,
              let o = window?.windowScene?.effectiveGeometry.interfaceOrientation,
              o != lastOrientation
        else { return }
        lastOrientation = o
        report(o)
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { begin(t) }
        publish()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { move(t) }
        publish()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { end(t, cancelled: false) }
        publish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { end(t, cancelled: true) }
        publish()
    }

    private func begin(_ t: UITouch) {
        let id = ObjectIdentifier(t)
        let p = t.location(in: self)
        guard let c = layout.control(at: p) else {
            owners[id] = .keys([])   // on nothing yet; it may slide onto a key
            return
        }
        switch c.kind {
        case let .stick(side, ring, knob):
            guard stickOwner[side] == nil else {
                owners[id] = .keys([])
                return
            }
            // A thumb on the knob takes it where it is; one on the ring around it tilts the stick at once.
            let onKnob = hypot(p.x - c.center.x, p.y - c.center.y) <= knob * 1.15
            let origin = options.floating || onKnob ? p : c.center
            let held = lastTap[side].map { t.timestamp - $0 < Self.doubleTapWindow } ?? false
            let releasing = (layout.stickRules[side]?.locksTilt ?? false) && (sticks[side] ?? .zero) != .zero
            owners[id] = .stick(StickGrab(side: side, origin: origin, ring: ring, began: t.timestamp, travel: 0, held: held,
                                          noClick: releasing))
            stickOwner[side] = id
            sticks[side] = vector(p, origin: origin, ring: ring)
        case let .touchScreen(size):
            // A finger on the Switch's touch screen: the lowest free slot, and where it is on the area
            let used = Set(screenPoints.values.map(\.id))
            guard let slot = (0..<UInt8(Wire.maxTouches)).first(where: { !used.contains($0) }) else {
                owners[id] = .keys([])
                return
            }
            let rect = CGRect(x: c.center.x - size.width / 2, y: c.center.y - size.height / 2, width: size.width, height: size.height)
            owners[id] = .screen(slot: slot, rect: rect)
            screenPoints[id] = Self.screenPoint(p, slot: slot, rect: rect)
        case let .zone(zone):
            // A sweeping finger steers the stick from where it landed: full tilt 72 points out at sensitivity 1
            let side = zone.side
            guard stickOwner[side] == nil else {
                owners[id] = .keys([])
                return
            }
            owners[id] = .stick(StickGrab(side: side, origin: p, ring: 90 / max(zone.sensitivity, 0.1), began: t.timestamp,
                                          travel: 0, held: false, noClick: true, flipX: zone.invertX, flipY: zone.invertY))
            stickOwner[side] = id
            sticks[side] = .zero
        case let .action(action, _):
            owners[id] = .action(action, inside: true)
        case .key, .cluster:
            let keys = layout.keys(at: p, holding: [])
            let locks = keys.intersection(layout.locking)
            if !locks.isEmpty {
                // Letting go makes no new press for publish() to tap the Taptic Engine for
                if options.pressHaptics, !locks.isDisjoint(with: latched) { feedback.impactOccurred(intensity: 0.5) }
                latched.formSymmetricDifference(locks)
            }
            owners[id] = .keys(keys)
        }
    }

    private func move(_ t: UITouch) {
        let id = ObjectIdentifier(t)
        guard let owner = owners[id] else { return }
        let p = t.location(in: self)
        switch owner {
        case .stick(var grab):
            grab.travel = max(grab.travel, hypot(p.x - grab.origin.x, p.y - grab.origin.y))
            owners[id] = .stick(grab)
            var v = vector(p, origin: grab.origin, ring: grab.ring)
            if grab.flipX { v.dx = -v.dx }
            if grab.flipY { v.dy = -v.dy }
            sticks[grab.side] = v
        case let .screen(slot, rect):
            screenPoints[id] = Self.screenPoint(p, slot: slot, rect: rect)
        case .keys(let held):
            owners[id] = .keys(layout.keys(at: p, holding: held))
        case let .action(action, _):
            let inside = layout.control(for: action).map { $0.score(p) <= $0.slop } ?? false
            owners[id] = .action(action, inside: inside)
        }
    }

    private func end(_ t: UITouch, cancelled: Bool) {
        let id = ObjectIdentifier(t)
        guard let owner = owners.removeValue(forKey: id) else { return }
        switch owner {
        case .stick(let grab):
            let tilted = grab.travel >= grab.ring * 0.25
            // A stick that locks its tilt keeps it after a real push; a tap lets it go
            if cancelled || !(layout.stickRules[grab.side]?.locksTilt ?? false) || !tilted { sticks[grab.side] = .zero }
            if stickOwner[grab.side] == id { stickOwner[grab.side] = nil }
            // A short tap that hardly moves clicks the stick; touching it again right after holds the click.
            if !cancelled, !grab.held, !grab.noClick, t.timestamp - grab.began < Self.tapMaxDuration, grab.travel < grab.ring * 0.25 {
                pulse(grab.side == .left ? .ls : .rs)
                lastTap[grab.side] = t.timestamp
            }
        case let .action(action, inside):
            if inside, !cancelled { onAction?(action) }
        case .screen:
            screenPoints[id] = nil
        case .keys:
            break
        }
    }

    /// A point of the touch screen area as the game's screen has it: clamped to the area, so a finger that slides off its edge stays on the screen's.
    private static func screenPoint(_ p: CGPoint, slot: UInt8, rect: CGRect) -> TouchPoint {
        func unit(_ v: CGFloat, _ lo: CGFloat, _ len: CGFloat) -> UInt16 {
            let f = min(max((v - lo) / max(len, 1), 0), 65535.0 / 65536.0)
            return UInt16(f * 65536)
        }
        return TouchPoint(id: slot, x: unit(p.x, rect.minX, rect.width), y: unit(p.y, rect.minY, rect.height))
    }

    /// The stick's tilt: full at 80 % of the ring, nothing inside the dead zone, the rest scaled so it starts at 0.
    private func vector(_ p: CGPoint, origin: CGPoint, ring: CGFloat) -> CGVector {
        let full = ring * 0.8
        let dx = (p.x - origin.x) / full, dy = (origin.y - p.y) / full
        let m = hypot(dx, dy)
        let dead = min(max(options.deadzone, 0), 0.9)
        guard m > dead else { return .zero }
        let scaled = min(1, (m - dead) / (1 - dead))
        return CGVector(dx: dx / m * scaled, dy: dy / m * scaled)
    }

    private func pulse(_ button: PadButton) {
        pulses[button] = CACurrentMediaTime() + Self.clickPulse
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.clickPulse + 0.01) * 1_000_000_000))
            self?.expirePulses()
        }
    }

    private func expirePulses() {
        let now = CACurrentMediaTime()
        let before = pulses.count
        pulses = pulses.filter { $0.value > now }
        if pulses.count != before { publish() }
    }

    private func releaseAll() {
        owners.removeAll()
        screenPoints.removeAll()
        sticks.removeAll()
        stickOwner.removeAll()
        pulses.removeAll()
        latched.removeAll()
        turboTimer?.invalidate()
        turboTimer = nil
        // Not during SwiftUI's update of this view: the frame goes to observed state.
        Task { @MainActor [weak self] in self?.publish() }
    }

    private func publish() {
        var buttons = Set<PadButton>()
        for owner in owners.values {
            if case .keys(let keys) = owner { buttons.formUnion(keys) }
        }
        // A locking button is down while latched, whatever the fingers on its key do
        buttons.subtract(layout.locking)
        buttons.formUnion(latched)
        for owner in owners.values {
            if case .stick(let grab) = owner, grab.held { buttons.insert(grab.side == .left ? .ls : .rs) }
        }
        buttons.formUnion(pulses.keys)
        var out: [Side: CGVector] = [:]
        for side in [Side.left, .right] {
            let raw = sticks[side] ?? .zero
            guard let rule = layout.stickRules[side] else { out[side] = raw; continue }
            let (stick, pressed) = rule.apply(raw)
            out[side] = stick
            buttons.formUnion(pressed)
        }
        if let shift = layout.shift { buttons = shift.apply(buttons) }
        buttons = ButtonMath.withCombos(buttons, layout.combos)
        let held = buttons
        // Turbo beats only while something it holds is down: a timer republishes until then
        if held.isDisjoint(with: layout.turbo) {
            turboTimer?.invalidate()
            turboTimer = nil
        } else {
            if turboTimer == nil {
                turboTimer = Timer.scheduledTimer(withTimeInterval: ButtonMath.turboHalfPeriod / 2, repeats: true) { [weak self] _ in
                    self?.publish()
                }
            }
            buttons = ButtonMath.withTurbo(buttons, turbo: layout.turbo, down: ButtonMath.turboDown(at: CACurrentMediaTime()))
        }
        let frame = InputFrame(buttons: buttons,
                               leftStick: out[.left] ?? .zero,
                               rightStick: out[.right] ?? .zero,
                               touches: screenPoints.values.sorted { $0.id < $1.id })
        defer { lastHeld = held }
        guard frame != last else { return }
        if options.pressHaptics, !held.subtracting(lastHeld).isEmpty {
            feedback.impactOccurred(intensity: 0.75)
        }
        last = frame
        onFrame?(frame)
    }
}
