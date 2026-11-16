import CoreMotion
import UIKit

/// The phone's gyro and accelerometer at 100 Hz, turned into the upright frame of the Joy-Con(s) the screen stands for,
/// buffered until the link takes them. No permission prompt: device motion needs none.
final class MotionSource: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "nxpad.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    private let lock = NSLock()
    // Guarded by `lock`.
    private var pending: [MotionSample] = []
    private var orientation = UIInterfaceOrientation.landscapeRight.rawValue
    private var mode: PadMode = .pair
    private var latest: (gravity: SIMD3<Float>, rate: SIMD3<Float>)?
    // Main actor only.
    private var running = false

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard !running, manager.isDeviceMotionAvailable else { return }
        running = true
        manager.deviceMotionUpdateInterval = 1.0 / 100
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.add(motion)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopDeviceMotionUpdates()
        lock.withLock {
            pending.removeAll()
            latest = nil
        }
    }

    func setOrientation(_ o: UIInterfaceOrientation) {
        lock.withLock { orientation = o.rawValue }
    }

    func setMode(_ m: PadMode) {
        lock.withLock { mode = m }
    }

    /// The newest reading in the picture's frame (x right, y up, z out of the screen), for a stick the player steers with
    /// the phone: nil before the first one or after stop().
    func picture() -> (gravity: SIMD3<Float>, rate: SIMD3<Float>)? {
        lock.withLock { latest }
    }

    /// The samples since the last call, the newest `max` of them.
    func drain(max count: Int) -> [MotionSample] {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let out = Array(pending.suffix(count))
        pending.removeAll(keepingCapacity: true)
        return out
    }

    private func add(_ m: CMDeviceMotion) {
        // Gravity plus the user's acceleration is what an accelerometer reads, in Core Motion's sign: (0, 0, -1) face up,
        // which is also the gravity direction the host wants.
        let acc = SIMD3<Float>(Float(m.gravity.x + m.userAcceleration.x),
                               Float(m.gravity.y + m.userAcceleration.y),
                               Float(m.gravity.z + m.userAcceleration.z))
        let rot = SIMD3<Float>(Float(m.rotationRate.x), Float(m.rotationRate.y), Float(m.rotationRate.z))
        let time = UInt64(max(0, m.timestamp) * 1_000_000_000)
        lock.lock()
        defer { lock.unlock() }
        let pictureAcc = Self.phoneToPicture(acc, orientation)
        let pictureRot = Self.phoneToPicture(rot, orientation)
        latest = (pictureAcc, pictureRot)
        let a = Self.pictureToJoyCon(pictureAcc, mode)
        let w = Self.pictureToJoyCon(pictureRot, mode)
        pending.append(MotionSample(timeNs: time, acc: a, rot: w))
        if pending.count > 16 { pending.removeFirst(pending.count - 16) }
    }

    /// The phone's hardware frame (portrait: x right, y up, z out of the screen) turned into the picture's for the
    /// interface orientation, as dm/host/motion_fusion.h's motion_phone_to_switch does.
    static func phoneToPicture(_ v: SIMD3<Float>, _ orientation: Int) -> SIMD3<Float> {
        switch orientation {
        case UIInterfaceOrientation.landscapeRight.rawValue: return SIMD3(-v.y, v.x, v.z)
        case UIInterfaceOrientation.landscapeLeft.rawValue: return SIMD3(v.y, -v.x, v.z)
        case UIInterfaceOrientation.portraitUpsideDown.rawValue: return SIMD3(-v.x, -v.y, v.z)
        default: return v
        }
    }

    /// The picture's frame turned into the upright Joy-Con's. A pair is held upright, faces to the player: the picture's
    /// frame as it is. One Joy-Con is held sideways, the left one turned a quarter counterclockwise and the right one a
    /// quarter clockwise: dm/host/pad_jc1.h's jc1_sideways_vec, undone.
    static func pictureToJoyCon(_ v: SIMD3<Float>, _ mode: PadMode) -> SIMD3<Float> {
        switch mode {
        case .pair: return v
        case .left: return SIMD3(v.y, -v.x, v.z)
        case .right: return SIMD3(-v.y, v.x, v.z)
        }
    }
}
