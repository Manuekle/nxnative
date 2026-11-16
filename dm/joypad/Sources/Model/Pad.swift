import CoreGraphics

/// Which Joy-Con a control or a button belongs to.
enum Side: Int, Sendable {
    case left = 0
    case right = 1
}

/// How the phone is held: both Joy-Cons at once, or one of them on its own, sideways.
enum PadMode: String, CaseIterable, Identifiable, Sendable {
    case pair
    case left
    case right

    var id: String { rawValue }

    /// The Joy-Cons this mode stands for, as the host's dm_joy_attach counts them: bit 0 the left one, bit 1 the right one.
    var sides: UInt8 {
        switch self {
        case .pair: return 0b11
        case .left: return 0b01
        case .right: return 0b10
        }
    }
}

/// A Joy-Con (Switch 1) button. Each one belongs to one Joy-Con, the way the hardware reports it.
enum PadButton: String, CaseIterable, Hashable, Sendable {
    case a, b, x, y
    case ls, rs
    case l, r, zl, zr
    case plus, minus
    case left, up, right, down
    case leftSL, leftSR, rightSL, rightSR
    case home, capture

    var side: Side {
        switch self {
        case .a, .b, .x, .y, .rs, .r, .zr, .plus, .rightSL, .rightSR, .home:
            return .right
        case .ls, .l, .zl, .minus, .left, .up, .right, .down, .leftSL, .leftSR, .capture:
            return .left
        }
    }

    /// The nn::hid::NpadButton bit (dm/host/dm_input.h, DM_BTN_*). Home and Capture are not NpadButtons.
    var npadBit: UInt32? {
        switch self {
        case .a: return 1 << 0
        case .b: return 1 << 1
        case .x: return 1 << 2
        case .y: return 1 << 3
        case .ls: return 1 << 4
        case .rs: return 1 << 5
        case .l: return 1 << 6
        case .r: return 1 << 7
        case .zl: return 1 << 8
        case .zr: return 1 << 9
        case .plus: return 1 << 10
        case .minus: return 1 << 11
        case .left: return 1 << 12
        case .up: return 1 << 13
        case .right: return 1 << 14
        case .down: return 1 << 15
        case .leftSL: return 1 << 24
        case .leftSR: return 1 << 25
        case .rightSL: return 1 << 26
        case .rightSR: return 1 << 27
        case .home, .capture: return nil
        }
    }

    /// The input packet's extra-button bit for the buttons that are not NpadButtons.
    var extraBit: UInt8? {
        switch self {
        case .home: return 1 << 0
        case .capture: return 1 << 1
        default: return nil
        }
    }
}

/// What the fingers on the screen hold right now, in the frame of the picture the phone draws:
/// sticks run from -1 to 1 with y up. In a single-Joy-Con mode that frame is the sideways Joy-Con's.
struct InputFrame: Equatable, Sendable {
    var buttons: Set<PadButton> = []
    var leftStick: CGVector = .zero
    var rightStick: CGVector = .zero
}
