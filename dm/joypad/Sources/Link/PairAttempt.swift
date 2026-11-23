import Foundation
import Network

/// One pairing (README.md, "Pairing"): PAIR to each game that may be showing the code, until one answers PAIRED with a
/// confirmation that proves it holds the same key. A typed code goes to every game of every Mac on the network (only the
/// one whose Pair iPhone… window is open takes it); a scanned QR code goes to its Mac's address and to that Mac's games. Every
/// game of one Mac gets the same nonce and proof.
final class PairAttempt: @unchecked Sendable {
    enum Secret: Sendable {
        case code(String)
        case token(Data)

        var data: Data {
            switch self {
            case .code(let digits): return Data(digits.utf8)
            case .token(let token): return token
            }
        }

        var method: Wire.PairMethod {
            switch self {
            case .code: return .code
            case .token: return .qr
            }
        }
    }

    struct Target: Sendable {
        var endpoint: NWEndpoint
        /// The Mac's ID, from the game's TXT record or the QR code: a PAIRED from any other Mac is not taken.
        var host: UInt64
    }

    enum Outcome: Sendable {
        case paired(host: UInt64, macName: String, game: String, key: Data)
        /// A wrong code; `renewed`: too many, the Mac shows a new one.
        case wrong(renewed: Bool)
        /// Games answered, none with its pairing window open.
        case closed
        case noAnswer
    }

    private struct Leg {
        let target: Target
        let connection: NWConnection
        let nonce: Data
        let packet: Data
        var ready = false
        var answered = false
    }

    private static let resendEvery: TimeInterval = 0.4
    private static let giveUpAfter: TimeInterval = 4

    private let queue = DispatchQueue(label: "nxpad.pair", qos: .userInitiated)
    private let secret: Secret
    private let targets: [Target]
    private let name: String
    private let completion: @MainActor @Sendable (Outcome) -> Void
    private var legs: [Leg] = []
    private var best: Outcome = .noAnswer
    private var finished = false
    private var timer: DispatchSourceTimer?
    private var started = Date()

    init(secret: Secret, targets: [Target], name: String, completion: @escaping @MainActor @Sendable (Outcome) -> Void) {
        self.secret = secret
        self.targets = targets
        self.name = name
        self.completion = completion
    }

    func start() {
        queue.async { [self] in
            started = Date()
            guard !targets.isEmpty else { return finish(.noAnswer) }
            let client = PairStore.clientID
            // One PAIR per Mac, the same on every way to it: the QR code's address and the Bonjour service are often the same
            // game, which then takes the second as the first sent again (the same PAIRED) instead of a wrong code
            var packets: [UInt64: (nonce: Data, packet: Data)] = [:]
            for target in targets {
                let (nonce, packet) = packets[target.host] ?? {
                    let nonce = PairCrypto.random(16)
                    let proof = PairCrypto.proof(secret: secret.data, host: target.host, client: client, nonce: nonce)
                    return (nonce, Wire.pair(seq: UInt32.random(in: 1...UInt32.max), clientID: client, method: secret.method, nonce: nonce, proof: proof, name: name))
                }()
                packets[target.host] = (nonce, packet)
                let params = NWParameters.udp
                params.includePeerToPeer = false
                let c = NWConnection(to: target.endpoint, using: params)
                let index = legs.count
                legs.append(Leg(target: target, connection: c, nonce: nonce, packet: packet))
                c.stateUpdateHandler = { [weak self] state in
                    guard let self, case .ready = state, index < self.legs.count, !self.finished else { return }
                    self.legs[index].ready = true
                    c.send(content: packet, completion: .idempotent)
                    self.receive(index)
                }
                c.start(queue: queue)
            }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.resendEvery, repeating: Self.resendEvery)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            teardown()
        }
    }

    private func tick() {
        guard !finished else { return }
        if Date().timeIntervalSince(started) >= Self.giveUpAfter { return finish(best) }
        if legs.allSatisfy(\.answered) { return finish(best) }
        // A datagram may be lost: again to every game that has not answered (one that did would count a wrong code twice)
        for leg in legs where leg.ready && !leg.answered {
            leg.connection.send(content: leg.packet, completion: .idempotent)
        }
    }

    private func receive(_ index: Int) {
        let c = legs[index].connection
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.finished else { return }
            if let data, case .paired(let reply)? = Wire.parse(data) { self.handle(reply, index) }
            if error == nil, !self.finished, !self.legs[index].answered { self.receive(index) }
        }
    }

    private func handle(_ reply: PairedReply, _ index: Int) {
        let leg = legs[index]
        guard reply.host == leg.target.host, !leg.answered else { return }
        legs[index].answered = true
        switch reply.result {
        case .ok:
            let client = PairStore.clientID
            let key = PairCrypto.key(secret: secret.data, host: reply.host, client: client, phoneNonce: leg.nonce, hostNonce: reply.nonce)
            guard PairCrypto.equal(PairCrypto.confirm(key: key, host: reply.host, client: client), reply.confirm) else { return }
            finish(.paired(host: reply.host, macName: reply.macName, game: reply.game, key: key))
        case .wrong:
            if case .wrong(true) = best { break }
            best = .wrong(renewed: false)
        case .renewed:
            best = .wrong(renewed: true)
        case .closed:
            if case .noAnswer = best { best = .closed }
        }
        if legs.allSatisfy(\.answered) { finish(best) }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        teardown()
        let completion = self.completion
        DispatchQueue.main.async {
            MainActor.assumeIsolated { completion(outcome) }
        }
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        for leg in legs { leg.connection.cancel() }
        legs.removeAll()
    }
}
