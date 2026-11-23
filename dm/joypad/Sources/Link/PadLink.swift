import Foundation
import Network

enum LinkStatus: Equatable, Sendable {
    case idle
    /// Resolving the game's address.
    case connecting
    /// HELLO sent, no WELCOME yet.
    case waiting
    case connected
    /// The game went quiet; HELLO goes out again until it answers.
    case lost
    case failed(String)
}

enum LinkEvent: Sendable {
    case status(LinkStatus)
    case welcome(Welcome)
    case lights(UInt8)
    case latency(Int)
    /// The game does not know this phone: it has to pair with the Mac (KICK, not paired).
    case notPaired
    /// The game's Mac challenged a HELLO and the session has no key for it (an address typed by hand): `setKey` answers.
    case needKey(UInt64)
}

/// The UDP session with one game: HELLO until it says WELCOME (answering its CHALLENGE with the Mac's pairing key), then the controller's state at up to 120 Hz
/// (right away on every change, repeated for a moment after it so a lost datagram costs nothing, and at
/// least every 100 ms as a heartbeat), the phone's motion samples as they come, and a PING a second.
/// Everything mutable lives on `queue`.
final class PadLink: @unchecked Sendable {
    /// Status, welcome, player lights and latency, on the main actor. Set it once, before the first connect.
    var onEvent: (@MainActor @Sendable (LinkEvent) -> Void)?
    /// The game's rumble, on the link's queue. Set it once, before the first connect.
    var onRumble: ((RumbleFrame) -> Void)?

    private static let tickNs: UInt64 = 8_333_333          // 120 Hz
    private static let helloEveryNs: UInt64 = 500_000_000
    private static let heartbeatNs: UInt64 = 100_000_000
    private static let repeatAfterChangeNs: UInt64 = 120_000_000
    private static let pingEveryNs: UInt64 = 1_000_000_000
    private static let lostAfterNs: UInt64 = 3_000_000_000
    /// HELLO unanswered this long: the connection starts over, so a game's Bonjour name is looked up again (a game that
    /// opened again may listen on another port).
    private static let reopenAfterNs: UInt64 = 3_000_000_000
    /// The Mac sent back the challenge just answered this many times: it does not take this phone's key.
    private static let refusedAnswers = 3
    private static let rumbleStaleNs: UInt64 = 500_000_000

    private let queue = DispatchQueue(label: "nxpad.link", qos: .userInteractive)
    private let clientID: UInt64

    private var endpoint: NWEndpoint?
    /// The Mac's ID (from the game's TXT record) and the key its pairing left, which every HELLO answers the challenge with.
    private var hostID: UInt64?
    private var key: Data?
    private var challenge: Data?
    /// The challenge the last HELLO answered, whether that HELLO still waits for the Mac's verdict, and how many answers
    /// in a row the Mac sent that challenge back for (it refused them).
    private var answered: Data?
    private var verdictDue = false
    private var refused = 0
    private var connection: NWConnection?
    private var ready = false
    /// The status stays what it is while this connection gets ready (open's keepStatus).
    private var holdStatus = false
    private var timer: DispatchSourceTimer?
    private var retry: DispatchWorkItem?
    private var motion: MotionSource?
    private var sides: UInt8 = 0b11
    private var name = "NX Pad"
    private var features: Wire.Features = []
    private var seq: UInt32 = 0
    private var welcomed = false
    private var status: LinkStatus = .idle
    private var snapshot = PadSnapshot()
    private var sent: PadSnapshot?
    private var lastHello: UInt64 = 0
    /// Since when HELLO goes out without a WELCOME (the connection opened, the game went quiet or the mode changed).
    private var helloSince: UInt64 = 0
    private var lastSend: UInt64 = 0
    private var lastHeard: UInt64 = 0
    private var lastPing: UInt64 = 0
    private var hotUntil: UInt64 = 0
    private var rumbleAt: UInt64 = 0
    private var rumbling = false
    /// The fingers on the touch screen area, and whether the host takes them (its WELCOME says so).
    private var touches: [TouchPoint] = []
    private var sentTouches: [TouchPoint]?
    private var hostTakesTouch = false
    private var touchHotUntil: UInt64 = 0
    private var lastTouchSend: UInt64 = 0

    init() {
        clientID = PairStore.clientID
    }

    // MARK: Called from the main actor

    func connect(to endpoint: NWEndpoint, hostID: UInt64?, key: Data?, sides: UInt8, name: String, features: Wire.Features, motion: MotionSource?) {
        queue.async { [self] in
            stop(sayBye: true)
            self.endpoint = endpoint
            self.hostID = hostID
            self.key = key
            self.challenge = nil
            self.answered = nil
            self.verdictDue = false
            self.refused = 0
            self.sides = sides
            self.name = name
            self.features = features
            self.motion = motion
            open()
        }
    }

    func disconnect() {
        queue.async { [self] in
            stop(sayBye: true)
            endpoint = nil
            motion = nil
            set(.idle)
        }
    }

    /// The app went to the background: say goodbye, but keep the game's address for `resume`.
    func suspend() {
        queue.async { [self] in
            stop(sayBye: true)
        }
    }

    func resume() {
        queue.async { [self] in
            if endpoint != nil, connection == nil { open() }
        }
    }

    /// The game's Bonjour service went and came back (the game opened again, maybe on another port): its name is looked up
    /// again now rather than once HELLO has gone unanswered for a while.
    func reconnect() {
        queue.async { [self] in
            guard endpoint != nil, connection != nil else { return }
            closeConnection(sayBye: false)
            open(keepStatus: status != .connected)
        }
    }

    /// Another mode: the game is told with a new HELLO, and attaches the new Joy-Cons when it answers.
    func setSides(_ newSides: UInt8) {
        queue.async { [self] in
            guard newSides != sides else { return }
            sides = newSides
            snapshot = PadSnapshot()
            sent = nil
            touches = []
            sentTouches = nil
            guard connection != nil else { return }
            welcomed = false
            helloSince = now()
            set(.waiting)
            if ready { sendHello(helloSince) }
        }
    }

    /// The motion source while this session is the one played; nil while another game has the phone.
    func setMotion(_ newMotion: MotionSource?) {
        queue.async { [self] in
            motion = newMotion
        }
    }

    /// A new key for this Mac (the phone paired again): the next HELLO answers with it.
    func setKey(_ newKey: Data?, hostID newHost: UInt64?) {
        queue.async { [self] in
            key = newKey
            if let newHost { hostID = newHost }
            answered = nil
            verdictDue = false
            refused = 0
            guard connection != nil, !welcomed, ready else { return }
            sendHello(now())
        }
    }

    /// The fingers on the touch screen area, the whole set. They are sent again for a moment after a change and every 100 ms
    /// while any is down, so a datagram lost never leaves a finger stuck on the game's screen.
    func pushTouches(_ points: [TouchPoint]) {
        queue.async { [self] in
            guard points != touches else { return }
            touches = points
            if welcomed, hostTakesTouch { sendTouches(now()) }
        }
    }

    func push(_ newSnapshot: PadSnapshot) {
        queue.async { [self] in
            guard newSnapshot != snapshot else { return }
            snapshot = newSnapshot
            if welcomed { sendInput(now()) }   // now, not at the next tick
        }
    }

    // MARK: The connection

    /// keepStatus: a connection started over while the game is away keeps saying so (Waiting for the game…, Reconnecting…,
    /// The game closed) rather than Connecting… every few seconds.
    private func open(keepStatus: Bool = false) {
        guard let endpoint else { return }
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice   // Wi-Fi's voice queue: the lowest latency there is
        params.includePeerToPeer = false          // AWDL hops channels and adds latency spikes
        let c = NWConnection(to: endpoint, using: params)
        connection = c
        ready = false
        welcomed = false
        helloSince = now()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            self.connectionChanged(c, state)
        }
        c.start(queue: queue)
        startTimer()
        holdStatus = keepStatus
        if !keepStatus { set(.connecting) }
    }

    private func connectionChanged(_ c: NWConnection, _ state: NWConnection.State) {
        guard c === connection else { return }
        switch state {
        case .ready:
            ready = true
            if !holdStatus { set(.waiting) }
            receive(on: c)
            sendHello(now())
        case .waiting(let error):
            ready = false
            if !holdStatus { set(.failed(error.localizedDescription)) }
        case .failed(let error):
            ready = false
            if !holdStatus { set(.failed(error.localizedDescription)) }
            scheduleReopen()
        default:
            break
        }
    }

    private func scheduleReopen() {
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.endpoint != nil else { return }
            self.closeConnection(sayBye: false)
            self.open(keepStatus: self.holdStatus)
        }
        retry = item
        queue.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, _, _, error in
            guard let self, let c, c === self.connection else { return }
            if let data, let message = Wire.parse(data) { self.handle(message) }
            if error == nil {
                self.receive(on: c)
            } else {
                // Nobody listening yet (ICMP port unreachable) and the like: keep listening a little later.
                self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self, weak c] in
                    guard let self, let c, c === self.connection, self.ready else { return }
                    self.receive(on: c)
                }
            }
        }
    }

    private func handle(_ message: Wire.Incoming) {
        let t = now()
        lastHeard = t
        switch message {
        case .challenge(let host, let nonce):
            // Answered at once, and with every HELLO after it until WELCOME; a challenge from another Mac than the
            // one this game advertised is not answered.
            if let hostID, host != hostID { return }
            hostID = host
            challenge = nonce
            guard key != nil else { return post(.needKey(host)) }
            guard !welcomed else { return }
            guard nonce == answered else {
                refused = 0
                return sendHello(t)
            }
            // The challenge just answered, back again. Answering it at once again would bounce HELLO and CHALLENGE as fast
            // as the network goes: the next HELLO goes at the usual pace. The first one back after an answer is the Mac's
            // refusal; more of them are its answers to HELLOs sent before (a game that stalled answers them all at once).
            // A few refusals in a row mean this Mac holds another key for this phone (it paired again, and this phone
            // missed the end).
            guard verdictDue else { return }
            verdictDue = false
            refused += 1
            guard refused >= Self.refusedAnswers else { return }
            stop(sayBye: false)
            endpoint = nil
            set(.failed(String(localized: "Pair this iPhone with the Mac first")))
            post(.notPaired)
        case .welcome(let welcome):
            let first = !welcomed
            welcomed = true
            holdStatus = false
            answered = nil
            verdictDue = false
            refused = 0
            hostTakesTouch = Wire.Features(rawValue: welcome.flags).contains(.touch)
            challenge = nil
            set(.connected)
            post(.welcome(welcome))
            if first {
                sent = nil
                sendInput(t)
                sentTouches = nil
                if hostTakesTouch, !touches.isEmpty { sendTouches(t) }
            }
        case .rumble(let motors):
            rumbleAt = t
            rumbling = motors.contains { !$0.isSilent }
            onRumble?(RumbleFrame(motors: motors))
        case .lights(let lights):
            post(.lights(lights))
        case .paired:
            break
        case .pong(let sentAt):
            if t > sentAt, t - sentAt < 5_000_000_000 { post(.latency(Int((t - sentAt) / 1_000_000))) }
        case .kick(let reason):
            let text: String
            switch Wire.KickReason(rawValue: reason) {
            case .full?: text = String(localized: "The game has no free player")
            case .closing?: text = String(localized: "The game closed")
            case .notPaired?: text = String(localized: "Pair this iPhone with the Mac first")
            case .unsupported?, nil: text = String(localized: "The game refused the controller")
            }
            if reason == Wire.KickReason.closing.rawValue {
                // It may open again in a moment, perhaps on another port: HELLO goes on, to its name looked up again, for as
                // long as the app keeps this session (it lets go once the game's Bonjour service is gone)
                welcomed = false
                set(.failed(text))
                closeConnection(sayBye: false)
                open(keepStatus: true)
                return
            }
            stop(sayBye: false)
            endpoint = nil
            set(.failed(text))
            if reason == Wire.KickReason.notPaired.rawValue { post(.notPaired) }
        }
    }

    // MARK: Sending

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(Int(Self.tickNs)), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let t = now()
        let samples = motion?.drain(max: Wire.maxMotionSamples) ?? []
        if rumbling, t - rumbleAt > Self.rumbleStaleNs {
            // The host repeats a rumble that goes on; one that stopped coming must not shake forever.
            rumbling = false
            onRumble?(.silent)
        }
        guard ready else { return }
        guard welcomed else {
            if lastHeard <= helloSince, t - helloSince >= Self.reopenAfterNs {
                // Not a word since HELLO started: the game may be listening somewhere else now
                closeConnection(sayBye: false)
                open(keepStatus: true)
            } else if t - lastHello >= Self.helloEveryNs {
                sendHello(t)
            }
            return
        }
        if t - lastHeard > Self.lostAfterNs {
            welcomed = false
            helloSince = t
            set(.lost)
            sendHello(t)
            return
        }
        if !samples.isEmpty || t < hotUntil || t - lastSend >= Self.heartbeatNs {
            sendInput(t, motion: samples)
        }
        if hostTakesTouch, t < touchHotUntil || (!touches.isEmpty && t - lastTouchSend >= Self.heartbeatNs) {
            sendTouches(t)
        }
        if t - lastPing >= Self.pingEveryNs {
            lastPing = t
            send(Wire.ping(seq: nextSeq(), nowNs: t))
        }
    }

    private func sendHello(_ t: UInt64) {
        lastHello = t
        var auth: Data?
        if let key, let hostID, let challenge {
            auth = PairCrypto.helloAuth(key: key, host: hostID, client: clientID, challenge: challenge, sides: sides)
            answered = challenge
            verdictDue = true
        }
        send(Wire.hello(seq: nextSeq(), clientID: clientID, sides: sides, features: features, name: name, auth: auth))
    }

    private func sendInput(_ t: UInt64, motion samples: [MotionSample] = []) {
        if snapshot != sent { hotUntil = t + Self.repeatAfterChangeNs }
        send(Wire.input(seq: nextSeq(), nowNs: t, sides: sides, snapshot: snapshot, motion: samples))
        sent = snapshot
        lastSend = t
    }

    private func sendTouches(_ t: UInt64) {
        if touches != sentTouches { touchHotUntil = t + Self.repeatAfterChangeNs }
        send(Wire.touch(seq: nextSeq(), points: touches))
        sentTouches = touches
        lastTouchSend = t
    }

    private func send(_ data: Data) {
        guard let c = connection, ready else { return }
        c.send(content: data, completion: .idempotent)
    }

    private func nextSeq() -> UInt32 {
        seq &+= 1
        return seq
    }

    // MARK: Teardown

    private func stop(sayBye: Bool) {
        retry?.cancel()
        retry = nil
        closeConnection(sayBye: sayBye)
        timer?.cancel()
        timer = nil
        welcomed = false
        sent = nil
        snapshot = PadSnapshot()
        touches = []
        sentTouches = nil
        hostTakesTouch = false
        if rumbling {
            rumbling = false
            onRumble?(.silent)
        }
    }

    private func closeConnection(sayBye: Bool) {
        guard let c = connection else { return }
        c.stateUpdateHandler = nil
        if sayBye && ready {
            // Cancel only once the goodbye is out, or it may never leave.
            c.send(content: Wire.bye(seq: nextSeq()), completion: .contentProcessed { _ in c.cancel() })
        } else {
            c.cancel()
        }
        connection = nil
        ready = false
    }

    // MARK: Helpers

    private func set(_ newStatus: LinkStatus) {
        guard newStatus != status else { return }
        status = newStatus
        post(.status(newStatus))
    }

    private func post(_ event: LinkEvent) {
        let callback = onEvent
        DispatchQueue.main.async {
            MainActor.assumeIsolated { callback?(event) }
        }
    }

    /// Host-uptime nanoseconds: the clock Core Motion stamps its samples with.
    private func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
