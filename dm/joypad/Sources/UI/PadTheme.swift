import SwiftUI

/// What the controller is made of: its shells, rails and accents, its keys (resting and pressed), its sticks, the player
/// lights and the status text. "Wii" is light and glossy, with sky-blue presses; the Joy-Con colours keep dark keys, as
/// the real ones have.
struct PadTheme: Identifiable {
    let id: String
    let name: String
    /// A light theme: the striped Wii background around the shells and the status on a white card.
    let light: Bool
    let leftBody: [Color]
    let rightBody: [Color]
    let bodyEdge: Color
    let leftRail: Color
    let rightRail: Color
    let leftAccent: Color
    let rightAccent: Color
    let key: [Color]
    let keyEdge: Color
    let keyPressed: [Color]
    let keyPressedEdge: Color
    let label: Color
    let labelPressed: Color
    let well: [Color]
    let wellEdge: Color
    let knob: [Color]
    let led: Color
    let backdrop: Color
    let statusText: Color
    let statusMuted: Color
    let swatch: (Color, Color)

    static let defaultID = "wii"

    static let all: [PadTheme] = [
        wii,
        joyCon(id: "pastel", name: String(localized: "Pastel"), left: 0x2D2F34, right: 0x2D2F34,
               leftRail: 0xC9A7EB, rightRail: 0x8EE3CF, leftAccent: 0xC9A7EB, rightAccent: 0x8EE3CF, swatchRails: true),
        joyCon(id: "neon", name: String(localized: "Neon blue and red"), left: 0x0AB9E6, right: 0xFF3C28,
               leftRail: 0x0890B4, rightRail: 0xCC2E1E, leftAccent: 0x7FDDF5, rightAccent: 0xFF9A8C),
        joyCon(id: "gray", name: String(localized: "Gray"), left: 0x828282, right: 0x828282,
               leftRail: 0x6A6A6A, rightRail: 0x6A6A6A, leftAccent: 0xD8D8D8, rightAccent: 0xD8D8D8),
        joyCon(id: "purple", name: String(localized: "Neon purple and orange"), left: 0xB400E6, right: 0xFAA005,
               leftRail: 0x8C00B4, rightRail: 0xC87F00, leftAccent: 0xE38CFF, rightAccent: 0xFFD27F),
        joyCon(id: "green", name: String(localized: "Neon green and pink"), left: 0x1EDC00, right: 0xFF3278,
               leftRail: 0x16A800, rightRail: 0xCC285F, leftAccent: 0x9CF58C, rightAccent: 0xFF9CBF),
    ]

    /// The Wii Menu's: pearl shells, sky-blue rails, white glossy keys that turn sky blue when pressed.
    static let wii = PadTheme(
        id: "wii", name: String(localized: "Wii"), light: true,
        leftBody: [Color.white, Color(hex: 0xEEF1F4), Color(hex: 0xE2E6EA)],
        rightBody: [Color.white, Color(hex: 0xEEF1F4), Color(hex: 0xE2E6EA)],
        bodyEdge: Wii.line.opacity(0.8),
        leftRail: Wii.blue, rightRail: Wii.blue, leftAccent: Wii.blue, rightAccent: Wii.blue,
        key: [Color.white, Color(hex: 0xFDFEFF), Color(hex: 0xE6EDF2)], keyEdge: Wii.buttonRim,
        keyPressed: [Color(hex: 0x7FDCFC), Color(hex: 0x34BEED), Color(hex: 0x1AA9E2)], keyPressedEdge: Wii.primaryRim,
        label: Wii.textStrong, labelPressed: .white,
        well: [Color(hex: 0xD3D9DF), Color(hex: 0xE8ECEF)], wellEdge: Wii.line,
        knob: [Color.white, Color(hex: 0xE6EDF2)],
        led: Wii.blue, backdrop: Color(hex: 0xE9EAEC),
        statusText: Wii.textStrong, statusMuted: Wii.muted,
        swatch: (Color.white, Wii.blue))

    /// A pair of real Joy-Con colours: coloured shells and rails, dark keys.
    static func joyCon(id: String, name: String, left: UInt32, right: UInt32, leftRail: UInt32, rightRail: UInt32,
                       leftAccent: UInt32, rightAccent: UInt32, swatchRails: Bool = false) -> PadTheme {
        let l = Color(hex: left), r = Color(hex: right)
        return PadTheme(
            id: id, name: name, light: false,
            leftBody: [l.opacity(0.92), l], rightBody: [r.opacity(0.92), r], bodyEdge: Color.white.opacity(0.06),
            leftRail: Color(hex: leftRail), rightRail: Color(hex: rightRail),
            leftAccent: Color(hex: leftAccent), rightAccent: Color(hex: rightAccent),
            key: [Color(hex: 0x2A2C31), Color(hex: 0x1C1D21)], keyEdge: Color.white.opacity(0.08),
            keyPressed: [Color(hex: 0x4A4D55), Color(hex: 0x3A3D44)], keyPressedEdge: Color.white.opacity(0.25),
            label: Color(hex: 0xC9CBD1), labelPressed: .white,
            well: [Color(hex: 0x111214), Color(hex: 0x17181B)], wellEdge: Color.black.opacity(0.5),
            knob: [Color(hex: 0x2A2C31), Color(hex: 0x1C1D21)],
            led: Color(hex: 0x4ADE80), backdrop: Color(hex: 0x0D0E10),
            statusText: Color.white.opacity(0.88), statusMuted: Color.white.opacity(0.5),
            swatch: swatchRails ? (Color(hex: leftRail), Color(hex: rightRail)) : (l, r))
    }

    static func named(_ id: String) -> PadTheme {
        all.first { $0.id == id } ?? all[0]
    }

    func body(_ side: Side) -> [Color] { side == .left ? leftBody : rightBody }
    func rail(_ side: Side) -> Color { side == .left ? leftRail : rightRail }
    func accent(_ side: Side) -> Color { side == .left ? leftAccent : rightAccent }
}
