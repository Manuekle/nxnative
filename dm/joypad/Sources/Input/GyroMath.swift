import CoreGraphics
import Foundation

/// The phone's motion turned into a stick tilt (GyroRule), in the picture's frame: x right, y up, z out of the screen.
enum GyroMath {
    /// How far the phone is turned like a steering wheel, in degrees, clockwise positive: 0 held upright. Gravity points
    /// along -y with the phone upright and gains +x as it turns clockwise.
    static func wheelAngle(gravity g: SIMD3<Float>) -> Float {
        atan2(g.x, -g.y) * 180 / .pi
    }

    static func stick(_ rule: GyroRule, gravity: SIMD3<Float>, rate: SIMD3<Float>, center: Float) -> CGVector {
        var v: CGVector
        switch rule.mode {
        case .wheel:
            // The phone laid flat has no wheel angle to read
            guard hypot(gravity.x, gravity.y) > 0.3 else { return .zero }
            var a = wheelAngle(gravity: gravity) - center
            if a > 180 { a -= 360 } else if a < -180 { a += 360 }
            let dead: Float = 2.5
            let full = Float(45 / min(max(rule.sensitivity, 0.1), 10))
            let m = min(1, max(0, (abs(a) - dead) / max(full - dead, 1)))
            v = CGVector(dx: CGFloat(a < 0 ? -m : m), dy: 0)
        case .aim:
            // Turned right (about -y) is stick right; the top moving away (about -x) is stick up
            let full = Float(3.5 / min(max(rule.sensitivity, 0.1), 10))
            let dead: Float = 0.06
            func axis(_ r: Float) -> CGFloat {
                let m = min(1, max(0, (abs(r) - dead) / max(full - dead, 0.1)))
                return CGFloat(r < 0 ? -m : m)
            }
            v = CGVector(dx: axis(-rate.y), dy: axis(-rate.x))
        }
        if rule.invertX { v.dx = -v.dx }
        if rule.invertY { v.dy = -v.dy }
        return v
    }
}
