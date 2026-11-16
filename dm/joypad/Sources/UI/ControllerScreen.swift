import SwiftUI
import UIKit

/// The controller itself, full screen.
struct ControllerScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.theme) private var themeID = PadTheme.defaultID
    @AppStorage(SettingsKey.deadzone) private var deadzone = 0.12
    @AppStorage(SettingsKey.floatingSticks) private var floatingSticks = false
    @AppStorage(SettingsKey.pressHaptics) private var pressHaptics = true
    @AppStorage(SettingsKey.motion) private var motion = true
    @AppStorage(SettingsKey.rumble) private var rumble = true
    @AppStorage(SettingsKey.rumbleStrength) private var rumbleStrength = 1.0
    @AppStorage(SettingsKey.controlScale) private var controlScale = 1.0
    @State private var showMenu = false

    var body: some View {
        let theme = PadTheme.named(themeID)
        GeometryReader { geo in
            let layout = PadLayout.make(mode: model.mode, size: geo.size, insets: Self.safeInsets(geo.safeAreaInsets), scale: CGFloat(controlScale),
                                        switcher: model.sessions.count > 1)
            ZStack(alignment: .topLeading) {
                if theme.light { WiiStripes() } else { theme.backdrop }
                PadBodiesView(layout: layout, theme: theme)
                PadControlsLayer(layout: layout, theme: theme)
                PlayerLightsView(lights: model.lights, color: theme.led, light: theme.light)
                    .position(layout.lightsCenter)
                StatusView(width: layout.statusWidth, theme: theme)
                    .position(layout.statusCenter)
                TouchSurface(layout: layout,
                             options: TouchOptions(deadzone: CGFloat(deadzone), floating: floatingSticks, pressHaptics: pressHaptics),
                             onFrame: { model.update($0) },
                             onAction: { action in
                                 if action == .switchGame { model.switchToNextGame() } else { showMenu = true }
                             },
                             onOrientation: { model.setOrientation($0) })
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .defersSystemGestures(on: .all)
        .sheet(isPresented: $showMenu) {
            MenuSheet()
        }
        .onChange(of: motion, initial: true) { _, on in
            model.setMotion(enabled: on)
        }
        .onChange(of: rumble, initial: true) { _, _ in
            model.setRumble(enabled: rumble, strength: rumbleStrength)
        }
        .onChange(of: rumbleStrength) { _, _ in
            model.setRumble(enabled: rumble, strength: rumbleStrength)
        }
    }
}

extension ControllerScreen {
    /// The screen's safe-area insets: the notch or the Dynamic Island, the home indicator. A view that ignores the safe area
    /// is told they are zero, so the window's own are taken as well.
    static func safeInsets(_ fromProxy: EdgeInsets) -> EdgeInsets {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        let w = window?.safeAreaInsets ?? .zero
        return EdgeInsets(top: max(fromProxy.top, w.top), leading: max(fromProxy.leading, w.left),
                          bottom: max(fromProxy.bottom, w.bottom), trailing: max(fromProxy.trailing, w.right))
    }
}

/// Reads the pressed keys on its own, so only the controls redraw while the fingers move.
private struct PadControlsLayer: View {
    @Environment(AppModel.self) private var model
    let layout: PadLayout
    let theme: PadTheme

    var body: some View {
        PadControlsView(layout: layout, theme: theme, frame: model.frame)
    }
}

private struct StatusView: View {
    @Environment(AppModel.self) private var model
    let width: CGFloat
    let theme: PadTheme

    var body: some View {
        VStack(spacing: 5) {
            Text(model.statusText)
                .font(AppFont.key(15))
                .foregroundStyle(theme.statusText)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            let subtitle = model.gameTitle.isEmpty ? model.hostLabel : model.gameTitle
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.statusMuted)
                    .lineLimit(2)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.light ? Wii.blueText : theme.statusText)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.light ? Wii.blueSoft : Color.white.opacity(0.12)))
                    .transition(.opacity)
            } else if model.sessions.count > 1 {
                Text("\(model.sessions.count) games open")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.statusMuted)
            }
            if let ms = model.latencyMs {
                Text(verbatim: "\(ms) ms")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.light ? Wii.blueText : theme.statusMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.light ? Wii.blueSoft : Color.white.opacity(0.08)))
            }
        }
        .multilineTextAlignment(.center)
        .animation(.easeInOut(duration: 0.2), value: model.notice)
        .padding(.vertical, theme.light ? 12 : 0)
        .padding(.horizontal, theme.light ? 8 : 0)
        .frame(width: max(width, 1))
        .modifier(StatusCard(light: theme.light))
        .allowsHitTesting(false)
    }
}

/// On a light theme the status sits on a white Wii channel, between the shells.
private struct StatusCard: ViewModifier {
    let light: Bool

    func body(content: Content) -> some View {
        if light { content.wiiChannel(radius: 16) } else { content }
    }
}
