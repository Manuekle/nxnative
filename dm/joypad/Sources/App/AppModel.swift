import Network
import Observation
import os
import SwiftUI
import UIKit

/// One open game the phone is linked to: its own UDP session, player and way of holding the phone. Several can be open at
/// once (one per game running on the Macs it is paired with); the one shown gets the touches and the motion, the others
/// get a released controller and keep their player.
@MainActor
@Observable
final class GameSession: Identifiable {
    /// The game's Bonjour service name, or "address:<what was typed>".
    let id: String
    let endpoint: NWEndpoint
    var title: String
    var macName: String
    var macID: UInt64?
    /// What the phone remembers the game by (PairStore.Game.id).
    let gameKey: String
    var mode: PadMode
    var status: LinkStatus = .connecting
    var player: Int?
    var lights: UInt8 = 0
    var latencyMs: Int?

    @ObservationIgnored let link = PadLink()
    /// Read on the link's queue: only the game shown rumbles the phone.
    @ObservationIgnored let shown = OSAllocatedUnfairLock(initialState: false)

    init(id: String, endpoint: NWEndpoint, title: String, macName: String, macID: UInt64?, gameKey: String, mode: PadMode) {
        self.id = id
        self.endpoint = endpoint
        self.title = title
        self.macName = macName
        self.macID = macID
        self.gameKey = gameKey
        self.mode = mode
    }
}

/// Pairing with a Mac, as the pairing sheet shows it.
enum PairState: Equatable {
    case idle
    case working
    case done(mac: String, game: String)
    case failed(String)
}

/// The app's state: which screen shows, the games the phone is linked to, pairing, and what the fingers press.
@MainActor
@Observable
final class AppModel {
    enum Screen: Equatable {
        case connect
        case controller
    }

    private(set) var screen: Screen = .connect
    private(set) var mode: PadMode = .pair
    /// The controller shows without a game, to try it out.
    private(set) var offline = false
    private(set) var sessions: [GameSession] = []
    private(set) var activeID: String?
    /// What the touch surface reports, for drawing the pressed keys and the stick knobs.
    private(set) var frame = InputFrame()
    /// A line the controller shows for a few seconds: another game opened, the one played closed.
    private(set) var notice: String?
    /// A line the games screen shows: why the phone came back to it.
    private(set) var connectNotice: String?

    // Pairing
    var showPairing = false
    private(set) var pairState: PairState = .idle
    /// The Mac the pairing sheet was opened for (a game that did not know this phone), if any.
    private(set) var pairingFor: String?

    let browser = HostBrowser()
    let store = PairStore()
    /// The layouts the player made, for every game and for single ones.
    let layouts = LayoutStore()
    private let motion = MotionSource()
    private let rumble = RumblePlayer()
    @ObservationIgnored private var motionWanted = true
    /// What the fingers hold, before the phone's motion is mixed in (`frame` is what the game gets).
    @ObservationIgnored private var touchFrame = InputFrame()
    /// The phone's motion as a stick, when the layout has one (PadProfile.gyro).
    @ObservationIgnored private var gyro: GyroRule?
    /// The wheel angle that counts as straight; nil takes the next reading.
    @ObservationIgnored private var gyroCenter: Float?
    @ObservationIgnored private var gyroEngaged = false
    @ObservationIgnored private var gyroTask: Task<Void, Never>?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var offlineLights: UInt8 = 0
    /// Games the player left (Back to games): not joined by themselves again until they close and open again.
    @ObservationIgnored private var leftGames: Set<String> = []
    @ObservationIgnored private var attempt: PairAttempt?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Linked games the network no longer lists, and since when: let go after 2 s (a browse that is starting over may
    /// list them a moment later).
    @ObservationIgnored private var missing: [String: Date] = [:]

    init() {
        browser.onChange = { [weak self] hosts in self?.hostsChanged(hosts) }
        browser.start()
    }

    // MARK: What the screens read

    var active: GameSession? { sessions.first { $0.id == activeID } }
    var status: LinkStatus { active?.status ?? .idle }
    var player: Int? { active?.player }
    var lights: UInt8 { offline ? offlineLights : active?.lights ?? 0 }
    var latencyMs: Int? { active?.latencyMs }
    var hostLabel: String { active?.macName ?? "" }
    var gameTitle: String { active?.title ?? "" }
    /// The game whose own layout the controller shows, when it has one (none in the offline test).
    var layoutGame: String? { offline ? nil : active?.gameKey }

    var statusText: String {
        if offline { return String(localized: "Offline test") }
        switch status {
        case .idle: return String(localized: "Not connected")
        case .connecting: return String(localized: "Connecting…")
        case .waiting: return String(localized: "Waiting for the game…")
        case .connected:
            guard let player else { return String(localized: "Press a button to play") }
            return String(localized: "Player \(player + 1)")
        case .lost: return String(localized: "Reconnecting…")
        case .failed(let message): return message
        }
    }

    /// Whether this game's Mac knows this phone (a game of protocol 1, without a Mac ID, is taken as it comes).
    func isPaired(_ host: HostBrowser.Host) -> Bool {
        guard let mac = host.macID else { return false }
        return store.key(for: mac) != nil
    }

    func session(for host: HostBrowser.Host) -> GameSession? { sessions.first { $0.id == host.id } }

    // MARK: Connecting

    /// The player picked a game: linked and shown, or the pairing sheet when its Mac does not know this phone.
    func open(_ host: HostBrowser.Host) {
        connectNotice = nil
        leftGames.remove(host.id)
        guard isPaired(host) else {
            pairingFor = host.macName ?? host.displayTitle
            pairState = .idle
            showPairing = true
            return
        }
        let s = session(for: host) ?? startSession(host)
        activate(s.id)
        enterController()
    }

    /// "192.168.1.20", "192.168.1.20:48620", "mac.local:48620" or "[fe80::1]:48620". False when it is not an address.
    @discardableResult
    func connect(address: String) -> Bool {
        guard let endpoint = Self.endpoint(from: address) else { return false }
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = "address:\(text)"
        connectNotice = nil
        if sessions.first(where: { $0.id == id }) == nil {
            let s = GameSession(id: id, endpoint: endpoint, title: text, macName: text, macID: nil, gameKey: text, mode: defaultMode)
            sessions.append(s)
            start(s)
        }
        activate(id)
        enterController()
        return true
    }

    func startOffline(mode: PadMode) {
        endAllSessions()
        offline = true
        self.mode = mode
        offlineLights = Self.defaultLights(0)
        touchFrame = InputFrame()
        frame = InputFrame()
        motion.setMode(mode)
        rumble.setMode(mode)
        enterController()
    }

    /// Back to the games: every game is let go, and none is joined by itself again until it closes and opens again.
    func leave() {
        for s in sessions { leftGames.insert(s.id) }
        endAllSessions()
        offline = false
        suspended = false
        touchFrame = InputFrame()
        frame = InputFrame()
        screen = .connect
        motion.stop()
        rumble.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// The next open game, in the order they were linked.
    func switchToNextGame() {
        guard sessions.count > 1, let i = sessions.firstIndex(where: { $0.id == activeID }) else { return }
        let next = sessions[(i + 1) % sessions.count]
        activate(next.id)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showNotice(String(localized: "Now playing \(next.title)"))
    }

    func switchTo(_ id: String) {
        guard id != activeID, sessions.contains(where: { $0.id == id }) else { return }
        activate(id)
    }

    // MARK: Pairing

    /// The six digits a Mac's Pair iPhone… window shows: sent to every game on the network.
    func pair(code: String) {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return }
        pairState = .working
        startPairing(.code(digits), fixed: [], macID: nil, waited: 0)
    }

    /// An nxpad://pair link (the Mac's QR code, scanned in the app or by the Camera). False when it is not one.
    @discardableResult
    func pair(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "nxpad", url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let mac = item("m").flatMap({ UInt64($0, radix: 16) }), let token = item("k").flatMap(Self.unhex), token.count == 16 else { return false }
        var fixed: [PairAttempt.Target] = []
        if let a = item("a"), let p = item("p").flatMap(UInt16.init), let port = NWEndpoint.Port(rawValue: p) {
            fixed.append(PairAttempt.Target(endpoint: .hostPort(host: NWEndpoint.Host(a), port: port), host: mac))
        }
        pairingFor = item("n")
        pairState = .working
        showPairing = true
        startPairing(.token(token), fixed: fixed, macID: mac, waited: 0)
        return true
    }

    func cancelPairing() {
        attempt?.cancel()
        attempt = nil
        if pairState == .working { pairState = .idle }
    }

    func resetPairing() {
        cancelPairing()
        pairState = .idle
        pairingFor = nil
    }

    func forgetMac(_ id: UInt64) {
        store.forget(id)
        for s in sessions where s.macID == id { endSession(s.id, notice: nil) }
    }

    private func startPairing(_ secret: PairAttempt.Secret, fixed: [PairAttempt.Target], macID: UInt64?, waited: Int) {
        attempt?.cancel()
        var targets = fixed
        for h in browser.hosts {
            guard let mac = h.macID, macID == nil || mac == macID else { continue }
            targets.append(PairAttempt.Target(endpoint: h.endpoint, host: mac))
        }
        // A Mac that never paired a phone starts listening when its Pair iPhone… window opens: its game may take a moment to show up
        if targets.isEmpty, waited < 4 {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.pairState == .working else { return }
                self.startPairing(secret, fixed: fixed, macID: macID, waited: waited + 1)
            }
            return
        }
        let a = PairAttempt(secret: secret, targets: targets, name: UIDevice.current.name) { [weak self] outcome in
            self?.pairingDone(outcome)
        }
        attempt = a
        a.start()
    }

    private func pairingDone(_ outcome: PairAttempt.Outcome) {
        attempt = nil
        switch outcome {
        case let .paired(host, macName, game, key):
            store.add(id: host, name: macName, key: key)
            pairState = .done(mac: macName, game: game)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            for s in sessions where s.macID == host { s.link.setKey(key, hostID: host) }
            hostsChanged(browser.hosts)   // its games join now
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                guard let self, case .done = self.pairState else { return }
                self.showPairing = false
                self.pairState = .idle
                self.pairingFor = nil
            }
        case .wrong(let renewed):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            pairState = .failed(renewed ? String(localized: "Wrong code. After too many tries the Mac shows a new one: type that one.")
                                        : String(localized: "Wrong code. Check the numbers on the Mac."))
        case .closed:
            pairState = .failed(String(localized: "No pairing window is open. In the game on your Mac, choose Controllers > Pair iPhone…, then type the code it shows."))
        case .noAnswer:
            pairState = .failed(String(localized: "No Mac answered. Open a game on your Mac and its Controllers > Pair iPhone… window, on the same Wi-Fi as this iPhone."))
        }
    }

    // MARK: While playing

    func update(_ newFrame: InputFrame) {
        touchFrame = newFrame
        let out = mixed(newFrame)
        frame = out
        guard !offline, let active else { return }
        active.link.push(Self.snapshot(of: out, mode: mode))
    }

    /// The layout's motion rule, or nil to turn it off. Motion is read while the controller shows, even with a rule on
    /// and "Send the phone's gyro" off: that one is only about what the game receives.
    func setGyro(_ rule: GyroRule?) {
        guard rule != gyro else { return }
        gyro = rule
        gyroCenter = nil
        gyroEngaged = false
        updateMotion()
        update(touchFrame)
    }

    /// Takes the phone's position now as straight, for a wheel.
    func recenterGyro() { gyroCenter = nil }

    /// The fingers' frame with the phone's motion added to the stick it moves.
    private func mixed(_ f: InputFrame) -> InputFrame {
        guard let rule = gyro else { return f }
        let engaged = rule.holdButton.map { f.buttons.contains($0) } ?? true
        defer { gyroEngaged = engaged }
        guard engaged, let m = motion.picture() else { return f }
        // A wheel with a hold button takes its straight where the phone is when the button goes down
        if gyroCenter == nil || (!gyroEngaged && rule.holdButton != nil) {
            gyroCenter = GyroMath.wheelAngle(gravity: m.gravity)
        }
        let g = GyroMath.stick(rule, gravity: m.gravity, rate: m.rate, center: gyroCenter ?? 0)
        func add(_ a: CGVector) -> CGVector {
            let x = a.dx + g.dx, y = a.dy + g.dy
            let len = hypot(x, y)
            return len > 1 ? CGVector(dx: x / len, dy: y / len) : CGVector(dx: x, dy: y)
        }
        var out = f
        if rule.rightStick { out.rightStick = add(f.rightStick) } else { out.leftStick = add(f.leftStick) }
        return out
    }

    /// Re-mixes the motion about 60 times a second while a rule is on, and sends what changed.
    private func updateGyroPump() {
        let wanted = gyro != nil && screen == .controller && !suspended
        if wanted, gyroTask == nil {
            gyroTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    guard let self else { return }
                    let out = self.mixed(self.touchFrame)
                    guard out != self.frame else { continue }
                    self.frame = out
                    if !self.offline, let active = self.active {
                        active.link.push(Self.snapshot(of: out, mode: self.mode))
                    }
                }
            }
        } else if !wanted {
            gyroTask?.cancel()
            gyroTask = nil
        }
    }

    func setMode(_ newMode: PadMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: SettingsKey.mode)
        touchFrame = InputFrame()
        frame = InputFrame()
        motion.setMode(newMode)
        rumble.setMode(newMode)
        guard !offline, let active else { return }
        active.mode = newMode
        if let mac = active.macID { store.setMode(newMode, gameID: active.gameKey, on: mac) }
        active.link.setSides(newMode.sides)
    }

    func setOrientation(_ orientation: UIInterfaceOrientation) {
        motion.setOrientation(orientation)
    }

    func setMotion(enabled: Bool) {
        motionWanted = enabled
        active?.link.setMotion(enabled ? motion : nil)
        updateMotion()
    }

    func setRumble(enabled: Bool, strength: Double) {
        rumble.configure(enabled: enabled, strength: Float(strength))
    }

    func testRumble() {
        let buzz = Vibration(ampLow: 0.8, freqLow: 160, ampHigh: 0.6, freqHigh: 320)
        rumble.play(RumbleFrame(motors: [buzz, buzz]))
        let rumble = self.rumble
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            rumble.play(.silent)
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if !suspended {
                suspended = true
                for s in sessions { s.link.suspend() }
                motion.stop()
                rumble.stop()
            }
            browser.stop()
        case .active:
            missing.removeAll()
            browser.start()
            guard suspended else { return }
            suspended = false
            for s in sessions { s.link.resume() }
            updateMotion()
        default:
            break
        }
    }

    // MARK: Sessions

    private var defaultMode: PadMode {
        UserDefaults.standard.string(forKey: SettingsKey.mode).flatMap(PadMode.init(rawValue:)) ?? .pair
    }

    private var autoJoin: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.autoJoin) as? Bool ?? true
    }

    /// The games on the network changed: remember the paired Macs' games, let go of the games that closed, and join the
    /// paired ones that opened (showing the controller when the phone was waiting on the games screen).
    private func hostsChanged(_ hosts: [HostBrowser.Host]) {
        let ids = Set(hosts.map(\.id))
        leftGames.formIntersection(ids)
        for h in hosts {
            if let mac = h.macID, store.mac(mac) != nil { store.saw(gameID: h.gameKey, title: h.displayTitle, on: mac, macName: h.macName) }
        }
        for s in sessions where !s.id.hasPrefix("address:") {
            if ids.contains(s.id) { missing[s.id] = nil } else if missing[s.id] == nil { missing[s.id] = Date() }
        }
        if !missing.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                self?.dropMissing()
            }
        }
        guard autoJoin, !offline, !suspended else { return }
        let wasEmpty = sessions.isEmpty
        var joined: [GameSession] = []
        for h in hosts where isPaired(h) && session(for: h) == nil && !leftGames.contains(h.id) {
            joined.append(startSession(h))
        }
        guard let first = joined.first else { return }
        if wasEmpty {
            activate(first.id)
            if screen == .connect { connectNotice = nil; enterController() }
        } else if screen == .controller {
            showNotice(joined.count == 1 ? String(localized: "\(first.title) is open: ⇄ switches to it")
                                         : String(localized: "More games are open: ⇄ switches between them"))
        }
    }

    private func dropMissing() {
        guard !suspended else { return }
        let now = Date()
        for (id, since) in missing where now.timeIntervalSince(since) >= 2 {
            missing[id] = nil
            if let s = sessions.first(where: { $0.id == id }) { endSession(id, notice: String(localized: "\(s.title) closed")) }
        }
    }

    @discardableResult
    private func startSession(_ host: HostBrowser.Host) -> GameSession {
        let mode = host.macID.flatMap { store.mode(gameID: host.gameKey, on: $0) } ?? defaultMode
        let s = GameSession(id: host.id, endpoint: host.endpoint, title: host.displayTitle, macName: host.macName ?? host.name,
                            macID: host.macID, gameKey: host.gameKey, mode: mode)
        sessions.append(s)
        if let mac = host.macID { store.saw(gameID: host.gameKey, title: host.displayTitle, on: mac, macName: host.macName) }
        start(s)
        return s
    }

    private func start(_ s: GameSession) {
        s.link.onEvent = { [weak self, weak s] event in
            guard let self, let s else { return }
            self.handle(event, from: s)
        }
        let rumble = self.rumble
        let shown = s.shown
        s.link.onRumble = { frame in
            if shown.withLock({ $0 }) { rumble.play(frame) }
        }
        var features: Wire.Features = []
        if motion.isAvailable { features.insert(.motion) }
        if rumble.supported { features.insert(.rumble) }
        let key = s.macID.flatMap { store.key(for: $0) }
        s.link.connect(to: s.endpoint, hostID: s.macID, key: key, sides: s.mode.sides, name: UIDevice.current.name, features: features, motion: nil)
    }

    /// The game the touches and the motion go to; the one shown before gets a released controller and keeps its player.
    private func activate(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        if let old = active, old.id != id {
            old.link.push(PadSnapshot())
            old.link.setMotion(nil)
            old.shown.withLock { $0 = false }
            rumble.play(.silent)
        }
        activeID = id
        offline = false
        s.shown.withLock { $0 = true }
        s.link.setMotion(motionWanted ? motion : nil)
        touchFrame = InputFrame()
        frame = InputFrame()
        mode = s.mode
        motion.setMode(mode)
        rumble.setMode(mode)
        updateMotion()
    }

    private func endSession(_ id: String, notice: String?) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions.remove(at: i)
        missing[id] = nil
        s.shown.withLock { $0 = false }
        s.link.disconnect()
        guard id == activeID else { return }
        activeID = nil
        rumble.play(.silent)
        if let next = sessions.first {
            activate(next.id)
            if let notice { showNotice(notice) }
        } else if screen == .controller, !offline {
            connectNotice = notice
            screen = .connect
            motion.stop()
            rumble.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func endAllSessions() {
        for s in sessions {
            s.shown.withLock { $0 = false }
            s.link.disconnect()
        }
        sessions.removeAll()
        activeID = nil
    }

    private func enterController() {
        screen = .controller
        UIApplication.shared.isIdleTimerDisabled = true
        updateMotion()
    }

    private func updateMotion() {
        // Only a game on the other end reads the phone's motion, and a stick the phone moves reads it here
        let game = motionWanted && !offline && active != nil
        if screen == .controller, !suspended, game || gyro != nil {
            motion.start()
        } else {
            motion.stop()
        }
        updateGyroPump()
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func handle(_ event: LinkEvent, from s: GameSession) {
        switch event {
        case .status(let newStatus):
            s.status = newStatus
            if newStatus != .connected { s.latencyMs = nil }
        case .welcome(let welcome):
            // 255: the game takes a controller at its first button press (Press a button to join)
            s.player = welcome.player < 8 ? welcome.player : nil
            s.lights = welcome.lights != 0 ? welcome.lights : (s.player.map { Self.defaultLights($0) } ?? 0)
            if !welcome.title.isEmpty { s.title = welcome.title }
        case .lights(let newLights):
            s.lights = newLights
        case .latency(let ms):
            s.latencyMs = ms
        case .needKey(let mac):
            if let key = store.key(for: mac) {
                s.macID = mac
                s.link.setKey(key, hostID: mac)
            } else {
                notPaired(s, mac: mac)
            }
        case .notPaired:
            // The Mac forgot this phone (Forget on the Mac, or its paired phones' file went): this phone forgets it too
            if let mac = s.macID { store.forget(mac) }
            notPaired(s, mac: s.macID)
        }
    }

    private func notPaired(_ s: GameSession, mac: UInt64?) {
        let name = s.macName
        endSession(s.id, notice: nil)
        for other in sessions where mac != nil && other.macID == mac { endSession(other.id, notice: nil) }
        pairingFor = name
        pairState = .failed(String(localized: "This Mac does not know this iPhone (any more). Pair it again with the code the Mac shows."))
        showPairing = true
    }

    // MARK: Helpers

    /// What the fingers hold, as the Joy-Cons report it: each one's NpadButtons, and its stick in the upright
    /// Joy-Con's frame. A Joy-Con drawn sideways has its stick turned back a quarter (dm/host/pad_jc1.h's
    /// jc1_sideways_stick, undone).
    nonisolated static func snapshot(of frame: InputFrame, mode: PadMode) -> PadSnapshot {
        var s = PadSnapshot()
        for button in frame.buttons {
            if let bit = button.npadBit {
                if button.side == .left { s.leftButtons |= bit } else { s.rightButtons |= bit }
            }
            if let bit = button.extraBit { s.extras |= bit }
        }
        switch mode {
        case .pair:
            s.leftStick = StickValue(frame.leftStick)
            s.rightStick = StickValue(frame.rightStick)
        case .left:
            let v = frame.leftStick
            s.leftStick = StickValue(CGVector(dx: v.dy, dy: -v.dx))
        case .right:
            let v = frame.rightStick
            s.rightStick = StickValue(CGVector(dx: -v.dy, dy: v.dx))
        }
        return s
    }

    /// The Switch's player light patterns, players 1 to 8.
    nonisolated static func defaultLights(_ player: Int) -> UInt8 {
        let patterns: [UInt8] = [0b0001, 0b0011, 0b0111, 0b1111, 0b1001, 0b0101, 0b1101, 0b0110]
        return patterns[min(max(player, 0), patterns.count - 1)]
    }

    nonisolated static func unhex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var out = Data()
        var it = text.makeIterator()
        while let h = it.next(), let l = it.next() {
            guard let b = UInt8(String([h, l]), radix: 16) else { return nil }
            out.append(b)
        }
        return out
    }

    nonisolated static func endpoint(from address: String) -> NWEndpoint? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var host = text
        var port = Wire.defaultPort
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            // [IPv6]:port
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) else { return nil }
                port = p
            }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            // host:port (a bare IPv6 address has more colons and no port)
            host = String(text[..<colon])
            guard let p = UInt16(text[text.index(after: colon)...]) else { return nil }
            port = p
        }
        guard !host.isEmpty, !host.contains(" "), port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }
}
