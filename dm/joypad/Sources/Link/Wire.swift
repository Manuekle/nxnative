import CoreGraphics
import CryptoKit
import Foundation

/// The NXPD wire format: little-endian UDP datagrams between the phone and the game's host (README.md, "Protocol").
enum Wire {
    static let magic: UInt32 = 0x4450_584E   // "NXPD" in memory order
    static let version: UInt8 = 2
    static let defaultPort: UInt16 = 48620
    static let serviceType = "_nxpad._udp"
    static let maxMotionSamples = 4

    enum Kind: UInt8 {
        // phone to host
        case hello = 0x01
        case input = 0x02
        case bye = 0x03
        case ping = 0x04
        case pair = 0x05
        // host to phone
        case welcome = 0x81
        case rumble = 0x82
        case lights = 0x83
        case pong = 0x84
        case kick = 0x85
        case paired = 0x86
        case challenge = 0x87
    }

    /// What the phone pretends to be. Joy-Con 2 (C button, mouse sensor) would be 2.
    enum Device: UInt8 {
        case joyCon = 1
    }

    struct Features: OptionSet, Sendable {
        let rawValue: UInt8
        static let motion = Features(rawValue: 1 << 0)
        static let rumble = Features(rawValue: 1 << 1)
    }

    enum KickReason: UInt8 {
        case full = 1
        case closing = 2
        case unsupported = 3
        case notPaired = 4
    }

    /// PAIR's method: the six digits typed, or the token of the QR code the Mac shows.
    enum PairMethod: UInt8 {
        case code = 1
        case qr = 2
    }

    /// PAIRED's result.
    enum PairResult: UInt8 {
        case ok = 0
        case wrong = 1
        /// No pairing window is open in that game.
        case closed = 2
        /// Too many wrong codes: the Mac shows a new one.
        case renewed = 3
    }

    enum Incoming: Sendable {
        case welcome(Welcome)
        case rumble([Vibration])
        case lights(UInt8)
        case pong(UInt64)
        case kick(UInt8)
        case paired(PairedReply)
        case challenge(host: UInt64, nonce: Data)
    }

    // MARK: Phone to host

    /// HELLO; `auth` answers the host's CHALLENGE (`helloAuth`). The first one goes without.
    static func hello(seq: UInt32, clientID: UInt64, sides: UInt8, features: Features, name: String, auth: Data?) -> Data {
        var w = WireWriter(kind: .hello, seq: seq)
        w.u64(clientID)
        w.u8(sides)
        w.u8(Device.joyCon.rawValue)
        w.u8(features.rawValue)
        w.u8(0)
        w.string(name, maxBytes: 32)
        if let auth { w.bytes(auth) }
        return w.data
    }

    static func pair(seq: UInt32, clientID: UInt64, method: PairMethod, nonce: Data, proof: Data, name: String) -> Data {
        var w = WireWriter(kind: .pair, seq: seq)
        w.u64(clientID)
        w.u8(method.rawValue)
        w.u8(0)
        w.u16(0)
        w.bytes(nonce)
        w.bytes(proof)
        w.string(name, maxBytes: 32)
        return w.data
    }

    static func input(seq: UInt32, nowNs: UInt64, sides: UInt8, snapshot s: PadSnapshot, motion: [MotionSample]) -> Data {
        var w = WireWriter(kind: .input, seq: seq)
        w.u64(nowNs)
        w.u8(sides)
        w.u8(s.extras)
        w.u16(0)
        w.u32(s.leftButtons)
        w.i16(s.leftStick.x)
        w.i16(s.leftStick.y)
        w.u32(s.rightButtons)
        w.i16(s.rightStick.x)
        w.i16(s.rightStick.y)
        let samples = motion.suffix(maxMotionSamples)
        w.u8(UInt8(samples.count))
        w.u8(0)
        w.u16(0)
        for m in samples {
            // How long before this packet the sample was taken; the host dates it from the packet's arrival.
            let age = nowNs > m.timeNs ? min((nowNs - m.timeNs) / 1000, UInt64(UInt32.max)) : 0
            w.u32(UInt32(age))
            w.f32(m.acc.x)
            w.f32(m.acc.y)
            w.f32(m.acc.z)
            w.f32(m.rot.x)
            w.f32(m.rot.y)
            w.f32(m.rot.z)
        }
        return w.data
    }

    static func ping(seq: UInt32, nowNs: UInt64) -> Data {
        var w = WireWriter(kind: .ping, seq: seq)
        w.u64(nowNs)
        return w.data
    }

    static func bye(seq: UInt32) -> Data {
        WireWriter(kind: .bye, seq: seq).data
    }

    // MARK: Host to phone

    static func parse(_ data: Data) -> Incoming? {
        var r = WireReader(data)
        guard r.u32() == magic, r.u8() == version,
              let raw = r.u8(), let kind = Kind(rawValue: raw),
              r.u16() != nil, r.u32() != nil
        else { return nil }
        switch kind {
        case .welcome:
            guard let player = r.u8(), let sides = r.u8(), let lights = r.u8(), let flags = r.u8() else { return nil }
            let title = r.string() ?? ""
            return .welcome(Welcome(player: Int(player), sides: sides, lights: lights, flags: flags, title: title))
        case .rumble:
            var motors: [Vibration] = []
            for _ in 0..<2 {
                guard let al = r.f32(), let fl = r.f32(), let ah = r.f32(), let fh = r.f32() else { return nil }
                motors.append(Vibration(ampLow: al, freqLow: fl, ampHigh: ah, freqHigh: fh))
            }
            return .rumble(motors)
        case .lights:
            guard let lights = r.u8() else { return nil }
            return .lights(lights)
        case .pong:
            guard let sent = r.u64() else { return nil }
            return .pong(sent)
        case .kick:
            return .kick(r.u8() ?? 0)
        case .paired:
            guard let raw = r.u8(), let result = PairResult(rawValue: raw), r.bytes(7) != nil, let host = r.u64(),
                  let nonce = r.bytes(16), let confirm = r.bytes(32) else { return nil }
            let macName = r.string() ?? ""
            let game = r.string() ?? ""
            return .paired(PairedReply(result: result, host: host, nonce: nonce, confirm: confirm, macName: macName, game: game))
        case .challenge:
            guard let host = r.u64(), let nonce = r.bytes(16) else { return nil }
            return .challenge(host: host, nonce: nonce)
        case .hello, .input, .bye, .ping, .pair:
            return nil
        }
    }
}

/// The pairing's HMAC-SHA256s, as dm/host/pad_net.h computes them: the label's bytes, the host's and the phone's IDs
/// (8 bytes each, little endian), then the rest.
enum PairCrypto {
    static func mac(key: Data, label: String, host: UInt64, client: UInt64, extra: Data = Data()) -> Data {
        var msg = Data(label.utf8)
        withUnsafeBytes(of: host.littleEndian) { msg.append(contentsOf: $0) }
        withUnsafeBytes(of: client.littleEndian) { msg.append(contentsOf: $0) }
        msg.append(extra)
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }

    /// What PAIR proves; `secret` is the six digits as text, or the QR code's token.
    static func proof(secret: Data, host: UInt64, client: UInt64, nonce: Data) -> Data {
        mac(key: secret, label: "NXPD pair", host: host, client: client, extra: nonce)
    }

    static func key(secret: Data, host: UInt64, client: UInt64, phoneNonce: Data, hostNonce: Data) -> Data {
        mac(key: secret, label: "NXPD key", host: host, client: client, extra: phoneNonce + hostNonce)
    }

    static func confirm(key: Data, host: UInt64, client: UInt64) -> Data {
        mac(key: key, label: "NXPD paired", host: host, client: client)
    }

    static func helloAuth(key: Data, host: UInt64, client: UInt64, challenge: Data, sides: UInt8) -> Data {
        mac(key: key, label: "NXPD hello", host: host, client: client, extra: challenge + Data([sides]))
    }

    /// Compares in constant time.
    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var d: UInt8 = 0
        for (x, y) in zip(a, b) { d |= x ^ y }
        return d == 0
    }

    static func random(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }
}

struct PairedReply: Sendable {
    var result: Wire.PairResult
    var host: UInt64
    var nonce: Data
    var confirm: Data
    var macName: String
    var game: String
}

/// A stick as the host takes it: -32767...32767, y up.
struct StickValue: Equatable, Sendable {
    var x: Int16 = 0
    var y: Int16 = 0

    init() {}

    init(_ v: CGVector) {
        x = Self.quantize(v.dx)
        y = Self.quantize(v.dy)
    }

    private static func quantize(_ f: CGFloat) -> Int16 {
        Int16(clamping: Int((max(-1, min(1, f)) * 32767).rounded()))
    }
}

/// The state one input packet carries: each Joy-Con's NpadButtons and stick, in the upright Joy-Con's frame.
struct PadSnapshot: Equatable, Sendable {
    var leftButtons: UInt32 = 0
    var rightButtons: UInt32 = 0
    var leftStick = StickValue()
    var rightStick = StickValue()
    /// Bit 0 Home, bit 1 Capture.
    var extras: UInt8 = 0
}

/// One six-axis sample in the upright frame of the Joy-Con(s) the phone stands for:
/// x the short axis (right), y the long axis (toward the top), z out of the face.
/// Acceleration is the gravity direction in G ((0, 0, -1) face up), rotation in rad/s.
struct MotionSample: Sendable {
    var timeNs: UInt64
    var acc: SIMD3<Float>
    var rot: SIMD3<Float>
}

/// One HD Rumble actuator's state, as the host's dm_vibration.
struct Vibration: Equatable, Sendable {
    var ampLow: Float = 0
    var freqLow: Float = 160
    var ampHigh: Float = 0
    var freqHigh: Float = 320

    var isSilent: Bool { !(ampLow > 0.001) && !(ampHigh > 0.001) }
}

/// Both actuators: motor 0 the left Joy-Con's, motor 1 the right one's.
struct RumbleFrame: Sendable {
    var motors: [Vibration]

    static let silent = RumbleFrame(motors: [Vibration(), Vibration()])
}

struct Welcome: Sendable {
    var player: Int
    var sides: UInt8
    var lights: UInt8
    var flags: UInt8
    var title: String
}

struct WireWriter {
    private(set) var data = Data()

    init(kind: Wire.Kind, seq: UInt32) {
        data.reserveCapacity(160)
        u32(Wire.magic)
        u8(Wire.version)
        u8(kind.rawValue)
        u16(0)
        u32(seq)
    }

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { append(v.littleEndian) }
    mutating func u32(_ v: UInt32) { append(v.littleEndian) }
    mutating func u64(_ v: UInt64) { append(v.littleEndian) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }

    /// A length byte and UTF-8, cut at a character boundary.
    mutating func string(_ s: String, maxBytes: Int) {
        var bytes: [UInt8] = []
        for ch in s {
            let b = Array(String(ch).utf8)
            if bytes.count + b.count > maxBytes { break }
            bytes += b
        }
        u8(UInt8(bytes.count))
        data.append(contentsOf: bytes)
    }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
    }
}

struct WireReader {
    private let bytes: [UInt8]
    private var at = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    private var remaining: Int { bytes.count - at }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { at += 1 }
        return bytes[at]
    }

    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { at += 2 }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[at + i]) << (8 * i) }
        at += 4
        return v
    }

    mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[at + i]) << (8 * i) }
        at += 8
        return v
    }

    mutating func f32() -> Float? {
        u32().map { Float(bitPattern: $0) }
    }

    mutating func bytes(_ n: Int) -> Data? {
        guard remaining >= n else { return nil }
        defer { at += n }
        return Data(bytes[at..<(at + n)])
    }

    mutating func string() -> String? {
        guard let n = u8(), remaining >= Int(n) else { return nil }
        let s = String(decoding: bytes[at..<(at + Int(n))], as: UTF8.self)
        at += Int(n)
        return s
    }
}
