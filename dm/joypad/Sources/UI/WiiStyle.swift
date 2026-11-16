import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Wii Menu's look: a pearl background with fine grey stripes, white "channels" with soft grey borders,
/// glossy pill buttons with a sky-blue rim, and sky blue (#34BEED) for whatever is selected.
enum Wii {
    static let panel = Color.white
    static let panel2 = Color(hex: 0xF5F7F9)
    static let line = Color(hex: 0xD5DAE0)
    static let lineSoft = Color(hex: 0xE4E8EC)
    static let text = Color(hex: 0x4A4F55)
    static let textStrong = Color(hex: 0x33373C)
    static let muted = Color(hex: 0x6B727A)
    static let blue = Color(hex: 0x34BEED)
    static let blueDark = Color(hex: 0x0E9AD6)
    static let blueText = Color(hex: 0x0A6FA3)          // blue that stays readable on white
    static let blueSoft = Color(hex: 0x34BEED).opacity(0.16)
    static let red = Color(hex: 0xE5484D)
    static let redSoft = Color(hex: 0xF3B4B6)
    static let green = Color(hex: 0x3FB950)
    static let buttonRim = Color(hex: 0x8FD6F0)
    static let primaryRim = Color(hex: 0x1597CF)
    static let shadow = Color(red: 40 / 255, green: 70 / 255, blue: 100 / 255)

    /// The white Wii Menu button: white at the top, a cool grey at the bottom.
    static let buttonFill = LinearGradient(stops: [
        .init(color: .white, location: 0),
        .init(color: Color(hex: 0xFDFEFF), location: 0.42),
        .init(color: Color(hex: 0xE6EDF2), location: 1),
    ], startPoint: .top, endPoint: .bottom)

    /// The sky-blue button, with the hard shine line across its middle.
    static let primaryFill = LinearGradient(stops: [
        .init(color: Color(hex: 0x7FDCFC), location: 0),
        .init(color: Color(hex: 0x34BEED), location: 0.48),
        .init(color: Color(hex: 0x1AA9E2), location: 0.52),
        .init(color: Color(hex: 0x22B3EA), location: 1),
    ], startPoint: .top, endPoint: .bottom)
}

// MARK: - Fonts

/// FOT-Rodin, the Wii's typeface, when the build carries it (Resources/Fonts, which git ignores: it is a commercial
/// font); otherwise the system's rounded face, the nearest it has.
enum AppFont {
    static let rodin = "RodinPro-DB"
    private(set) static var hasRodin = false

    /// Registers every font file the app bundle carries. Call once, at launch.
    static func registerBundled() {
        let urls = ["otf", "ttf"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
#if os(macOS)
        hasRodin = NSFont(name: rodin, size: 12) != nil
#else
        hasRodin = UIFont(name: rodin, size: 12) != nil
#endif
    }

    /// Titles, buttons and key labels.
    static func wii(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        hasRodin ? .custom(rodin, size: size, relativeTo: style) : .system(size: size, weight: .semibold, design: .rounded)
    }

    /// The controller's own labels: they keep their size whatever the text size setting.
    static func key(_ size: CGFloat) -> Font {
        hasRodin ? .custom(rodin, fixedSize: size) : .system(size: size, weight: .semibold, design: .rounded)
    }
}

// MARK: - Backgrounds

/// The Wii Menu's background: a pearl gradient under fine horizontal stripes.
struct WiiStripes: View {
    /// The softer stripes of a panel, instead of the page's.
    var soft = false

    var body: some View {
        ZStack {
            LinearGradient(colors: soft ? [.white, Color(hex: 0xF6F7F8)] : [Color(hex: 0xF3F4F5), Color(hex: 0xE9EAEC), Color(hex: 0xE1E3E6)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                let band = Color(red: 120 / 255, green: 128 / 255, blue: 138 / 255).opacity(soft ? 0.04 : 0.09)
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: soft ? 1 : 1.5)), with: .color(band))
                    if !soft { context.fill(Path(CGRect(x: 0, y: y + 1.5, width: size.width, height: 0.75)), with: .color(.white.opacity(0.4))) }
                    y += 4
                }
            }
        }
    }
}

// MARK: - Buttons

/// A Wii Menu pill button: white with a sky-blue rim, sky blue for the main action, or a red rim for leaving.
struct WiiButtonStyle: ButtonStyle {
    enum Kind { case secondary, primary, danger }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        WiiButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct WiiButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: WiiButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let pressed = configuration.isPressed
        let rim: Color = switch kind {
        case .secondary: pressed ? Wii.blue : Wii.buttonRim
        case .primary: Wii.primaryRim
        case .danger: pressed ? Wii.red : Wii.redSoft
        }
        configuration.label
            .font(AppFont.wii(compact ? 14 : 16, relativeTo: .callout))
            .lineLimit(1)
            .foregroundStyle(kind == .primary ? Color.white : kind == .danger ? Wii.red : Wii.textStrong)
            .shadow(color: kind == .primary ? Color(red: 0, green: 60 / 255, blue: 100 / 255).opacity(0.35) : .clear, radius: 0, y: 1)
            .padding(.horizontal, compact ? 14 : 22)
            .padding(.vertical, compact ? 7 : 11)
            .background {
                Capsule().fill(kind == .primary ? AnyShapeStyle(Wii.primaryFill) : AnyShapeStyle(Wii.buttonFill))
                    .overlay(Capsule().inset(by: compact ? 2 : 3).stroke(Color.white.opacity(kind == .primary ? 0.35 : 0.95), lineWidth: 1.5))
            }
            .overlay(Capsule().strokeBorder(rim, lineWidth: compact ? 2 : 3))
            .background(Capsule().stroke(pressed ? Wii.blueSoft : .clear, lineWidth: 8))
            .shadow(color: Wii.shadow.opacity(0.14), radius: 4, y: 2)
            .scaleEffect(pressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .contentShape(Capsule())
    }
}

// MARK: - Channels and panels

extension View {
    /// A Wii channel: a white rounded tile with a grey border, sky blue with a soft halo when selected.
    func wiiChannel(selected: Bool = false, radius: CGFloat = 18) -> some View {
        modifier(WiiChannel(selected: selected, radius: radius))
    }

    /// A Wii Menu window: softly striped, a light border and a deep soft shadow.
    func wiiPanel(radius: CGFloat = 26) -> some View {
        background(WiiStripes(soft: true).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Wii.lineSoft, lineWidth: 3))
            .shadow(color: Wii.shadow.opacity(0.14), radius: 18, y: 10)
    }

    /// A Wii text field: a white pill with an inset, sky blue when it has the focus.
    func wiiField(focused: Bool) -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white).shadow(color: Wii.shadow.opacity(0.07), radius: 1.5, y: 1))
            .overlay(Capsule().strokeBorder(focused ? Wii.blue : Wii.line, lineWidth: 2))
            .background(Capsule().stroke(focused ? Wii.blueSoft : .clear, lineWidth: 7))
    }
}

private struct WiiChannel: ViewModifier {
    let selected: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(Color.white))
            .overlay(shape.strokeBorder(selected ? Wii.blue : Wii.line, lineWidth: 2))
            .background(shape.stroke(selected ? Wii.blueSoft : .clear, lineWidth: 9))
            .shadow(color: selected ? Wii.blueDark.opacity(0.18) : Wii.shadow.opacity(0.08), radius: selected ? 9 : 4, y: selected ? 5 : 2)
            .animation(.easeOut(duration: 0.18), value: selected)
    }
}

/// A section title in the Wii's typeface.
struct WiiHeading: View {
    let text: LocalizedStringKey
    var size: CGFloat = 17

    init(_ text: LocalizedStringKey, size: CGFloat = 17) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(AppFont.wii(size, relativeTo: .headline))
            .foregroundStyle(Wii.textStrong)
    }
}

/// The round sky-blue badge an icon sits in, as on the Wii Menu's buttons.
struct WiiIconBadge: View {
    let systemName: String
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Wii.primaryFill))
            .overlay(Circle().strokeBorder(Wii.primaryRim, lineWidth: 1.5))
            .shadow(color: Wii.blueDark.opacity(0.3), radius: 3, y: 2)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
