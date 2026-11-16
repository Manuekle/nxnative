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
    }

    private enum Owner {
        case stick(StickGrab)
        case keys(Set<PadButton>)
        case action(PadAction, inside: Bool)
    }

    private static let tapMaxDuration: TimeInterval = 0.25
    private static let doubleTapWindow: TimeInterval = 0.3
    private static let clickPulse: TimeInterval = 0.09

    private var owners: [ObjectIdentifier: Owner] = [:]
    private var sticks: [Side: CGVector] = [:]
    private var stickOwner: [Side: ObjectIdentifier] = [:]
    private var lastTap: [Side: TimeInterval] = [:]
    private var pulses: [PadButton: CFTimeInterval] = [:]
    private var last = InputFrame()
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
            owners[id] = .stick(StickGrab(side: side, origin: origin, ring: ring, began: t.timestamp, travel: 0, held: held))
            stickOwner[side] = id
            sticks[side] = vector(p, origin: origin, ring: ring)
        case let .action(action, _):
            owners[id] = .action(action, inside: true)
        case .key, .cluster:
            owners[id] = .keys(layout.keys(at: p, holding: []))
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
            sticks[grab.side] = vector(p, origin: grab.origin, ring: grab.ring)
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
            sticks[grab.side] = .zero
            if stickOwner[grab.side] == id { stickOwner[grab.side] = nil }
            // A short tap that hardly moves clicks the stick; touching it again right after holds the click.
            if !cancelled, !grab.held, t.timestamp - grab.began < Self.tapMaxDuration, grab.travel < grab.ring * 0.25 {
                pulse(grab.side == .left ? .ls : .rs)
                lastTap[grab.side] = t.timestamp
            }
        case let .action(action, inside):
            if inside, !cancelled { onAction?(action) }
        case .keys:
            break
        }
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
        sticks.removeAll()
        stickOwner.removeAll()
        pulses.removeAll()
        // Not during SwiftUI's update of this view: the frame goes to observed state.
        Task { @MainActor [weak self] in self?.publish() }
    }

    private func publish() {
        var buttons = Set<PadButton>()
        for owner in owners.values {
            switch owner {
            case .keys(let keys): buttons.formUnion(keys)
            case .stick(let grab): if grab.held { buttons.insert(grab.side == .left ? .ls : .rs) }
            case .action: break
            }
        }
        buttons.formUnion(pulses.keys)
        let frame = InputFrame(buttons: buttons,
                               leftStick: sticks[.left] ?? .zero,
                               rightStick: sticks[.right] ?? .zero)
        guard frame != last else { return }
        if options.pressHaptics, !buttons.subtracting(last.buttons).isEmpty {
            feedback.impactOccurred(intensity: 0.75)
        }
        last = frame
        onFrame?(frame)
    }
}
