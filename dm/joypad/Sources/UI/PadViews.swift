import SwiftUI

// What the controller looks like. None of these views takes touches: TouchSurface lies over all of them.

struct PadBodiesView: View {
    let layout: PadLayout
    let theme: PadTheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.bodies) { piece in
                let rail = piece.rail.offsetBy(dx: -piece.rect.minX, dy: -piece.rect.minY)
                let shape = UnevenRoundedRectangle(cornerRadii: piece.radii, style: .continuous)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(LinearGradient(colors: theme.body(piece.side), startPoint: .top, endPoint: .bottom))
                    Rectangle()
                        .fill(theme.rail(piece.side))
                        .frame(width: rail.width, height: rail.height)
                        .offset(x: rail.minX, y: rail.minY)
                }
                .frame(width: piece.rect.width, height: piece.rect.height)
                .clipShape(shape)
                // A light along the top edge, fading down, as on glossy plastic; then one thin, even edge all round
                .overlay(shape.inset(by: 1).stroke(LinearGradient(colors: [Color.white.opacity(theme.light ? 0.95 : 0.18), .clear],
                                                                  startPoint: .top, endPoint: .center), lineWidth: 1.5))
                .overlay(shape.strokeBorder(theme.bodyEdge, lineWidth: 1))
                .shadow(color: (theme.light ? Wii.shadow : .black).opacity(theme.light ? 0.16 : 0.45), radius: 14, y: 6)
                .position(x: piece.rect.midX, y: piece.rect.midY)
            }
        }
    }
}

struct PadControlsView: View {
    let layout: PadLayout
    let theme: PadTheme
    let frame: InputFrame

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.controls) { control in
                ControlView(control: control, theme: theme, frame: frame, locking: layout.locking)
                    .opacity(control.hidden ? 0.3 : 1)
                    .position(control.center)
            }
        }
    }
}

struct ControlView: View {
    let control: Control
    let theme: PadTheme
    let frame: InputFrame
    var locking: Set<PadButton> = []

    var body: some View {
        switch control.kind {
        case let .key(button, shape, label):
            KeyView(shape: shape, label: label, pressed: frame.buttons.contains(button), theme: theme, locks: locking.contains(button))
        case let .cluster(cluster):
            ClusterView(cluster: cluster, pressed: frame.buttons, theme: theme, locking: locking)
        case let .stick(side, ring, knob):
            StickView(ring: ring, knob: knob,
                      value: side == .left ? frame.leftStick : frame.rightStick,
                      clicked: frame.buttons.contains(side == .left ? .ls : .rs),
                      accent: theme.accent(side), theme: theme)
        case let .action(action, radius):
            MenuButtonView(radius: radius, theme: theme, symbol: action == .switchGame ? "arrow.left.arrow.right" : "gearshape.fill")
        }
    }
}

struct KeyView: View {
    let shape: KeyShape
    let label: KeyLabel
    let pressed: Bool
    let theme: PadTheme
    /// A button that locks (PadLayout.locking): a small padlock on its rim, closed while it is held down.
    var locks = false

    var body: some View {
        let size = shape.size
        let edge = theme.light ? max(1.5, min(size.width, size.height) * 0.042) : 1
        ZStack {
            outline
                .fill(LinearGradient(colors: pressed ? theme.keyPressed : theme.key, startPoint: .top, endPoint: .bottom))
                .shadow(color: (theme.light ? Wii.shadow : .black).opacity(pressed ? 0.12 : (theme.light ? 0.22 : 0.5)),
                        radius: pressed ? 1 : 3, y: pressed ? 0.5 : 2)
            if theme.light && !pressed {   // the white inner rim of a Wii Menu button
                outline.stroke(Color.white.opacity(0.9), lineWidth: 1).padding(edge + 0.5)
            }
            outline.stroke(pressed ? theme.keyPressedEdge : theme.keyEdge, lineWidth: edge)
            KeyLabelView(label: label, size: min(size.width, size.height) * 0.42, color: pressed ? theme.labelPressed : theme.label)
                .shadow(color: pressed && theme.light ? Color(red: 0, green: 60 / 255, blue: 100 / 255).opacity(0.35) : .clear, radius: 0, y: 1)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topTrailing) {
            if locks { lockBadge(min(size.width, size.height)) }
        }
        .background(outline.stroke(pressed && theme.light ? Wii.blueSoft : .clear, lineWidth: 8))
        .scaleEffect(pressed ? 0.93 : 1)
        .animation(.easeOut(duration: 0.06), value: pressed)
    }

    private func lockBadge(_ side: CGFloat) -> some View {
        let d = min(max(side * 0.36, 13), 20)
        return Image(systemName: pressed ? "lock.fill" : "lock.open.fill")
            .font(.system(size: d * 0.5, weight: .bold))
            .foregroundStyle(pressed ? Color.white : (theme.light ? Wii.blueText : theme.label))
            .frame(width: d, height: d)
            .background(Circle().fill(pressed ? AnyShapeStyle(theme.light ? Wii.blueDark : Color(hex: 0x5A5E68))
                                              : AnyShapeStyle(theme.light ? Color.white : Color(hex: 0x1C1D21))))
            .overlay(Circle().stroke(pressed ? theme.keyPressedEdge : theme.keyEdge, lineWidth: 1))
            .offset(x: d * 0.18, y: -d * 0.18)
    }

    private var outline: AnyShape {
        switch shape {
        case .circle: return AnyShape(Circle())
        case .capsule: return AnyShape(Capsule())
        case .square(let s): return AnyShape(RoundedRectangle(cornerRadius: s * 0.24, style: .continuous))
        }
    }
}

struct KeyLabelView: View {
    let label: KeyLabel
    let size: CGFloat
    let color: Color

    var body: some View {
        switch label {
        case .text(let text):
            Text(verbatim: text)
                .font(AppFont.key(size))
                .foregroundStyle(color)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.85, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

struct ClusterView: View {
    let cluster: Cluster
    let pressed: Set<PadButton>
    let theme: PadTheme
    var locking: Set<PadButton> = []

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                KeyView(shape: .circle(cluster.keyRadius), label: cluster.labels[i],
                        pressed: pressed.contains(cluster.keys[i]), theme: theme, locks: locking.contains(cluster.keys[i]))
                    .offset(x: Cluster.offsets[i].dx * cluster.gap, y: Cluster.offsets[i].dy * cluster.gap)
            }
        }
        .frame(width: cluster.reach * 2, height: cluster.reach * 2)
    }
}

struct StickView: View {
    let ring: CGFloat
    let knob: CGFloat
    let value: CGVector
    let clicked: Bool
    let accent: Color
    let theme: PadTheme

    var body: some View {
        let travel = ring - knob * 0.85
        ZStack {
            // The well the knob sits in: sunk into the shell
            Circle()
                .fill(LinearGradient(colors: theme.well, startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(theme.wellEdge, lineWidth: theme.light ? 2 : 2))
                .overlay(Circle().stroke(Color.black.opacity(theme.light ? 0.06 : 0.3), lineWidth: 6).blur(radius: 3).clipShape(Circle()))
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: theme.knob, startPoint: .top, endPoint: .bottom))
                    .shadow(color: (theme.light ? Wii.shadow : .black).opacity(theme.light ? 0.28 : 0.55), radius: 5, y: 3)
                if theme.light {
                    Circle().stroke(Wii.line, lineWidth: 1.5)
                }
                Circle()
                    .stroke(accent, lineWidth: max(2.5, knob * 0.1))
                    .padding(knob * 0.13)
                Circle()
                    .fill(clicked ? AnyShapeStyle(theme.light ? Wii.primaryFill : LinearGradient(colors: [.white.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(Color.black.opacity(theme.light ? 0.04 : 0.0)))
                    .padding(knob * 0.36)
            }
            .frame(width: knob * 2, height: knob * 2)
            .scaleEffect(clicked ? 0.9 : 1)
            .animation(.easeOut(duration: 0.06), value: clicked)
            .offset(x: value.dx * travel, y: -value.dy * travel)
        }
        .frame(width: ring * 2, height: ring * 2)
    }
}

struct MenuButtonView: View {
    let radius: CGFloat
    let theme: PadTheme
    var symbol = "gearshape.fill"

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: radius * 0.9, weight: .semibold))
            .foregroundStyle(theme.light ? Wii.textStrong : theme.label.opacity(0.85))
            .frame(width: radius * 2, height: radius * 2)
            .background(Circle().fill(LinearGradient(colors: theme.key, startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().stroke(theme.keyEdge, lineWidth: theme.light ? 2 : 1))
            .shadow(color: (theme.light ? Wii.shadow : .black).opacity(0.2), radius: 3, y: 2)
    }
}

/// The four player lights, lit as the game sets them (bit 0 is the first light).
struct PlayerLightsView: View {
    let lights: UInt8
    let color: Color
    var light = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                let on = (lights >> i) & 1 == 1
                Capsule()
                    .fill(on ? color : (light ? Wii.line : Color.white.opacity(0.12)))
                    .frame(width: 12, height: 5)
                    .shadow(color: on ? color.opacity(0.8) : .clear, radius: 3)
            }
        }
    }
}

/// Small silhouettes of a mode, for the mode picker.
struct MiniPad: View {
    let mode: PadMode
    let theme: PadTheme

    var body: some View {
        switch mode {
        case .pair:
            HStack(spacing: 4) {
                half(.left)
                half(.right)
            }
        case .left:
            sideways(.left)
        case .right:
            sideways(.right)
        }
    }

    private func half(_ side: Side) -> some View {
        let radii = side == .left
            ? RectangleCornerRadii(topLeading: 14, bottomLeading: 14, bottomTrailing: 3, topTrailing: 3)
            : RectangleCornerRadii(topLeading: 3, bottomLeading: 3, bottomTrailing: 14, topTrailing: 14)
        let shape = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
        return ZStack(alignment: side == .left ? .trailing : .leading) {
            Rectangle().fill(LinearGradient(colors: theme.body(side), startPoint: .top, endPoint: .bottom))
            Rectangle().fill(theme.rail(side)).frame(width: 3)
            Circle()
                .fill(LinearGradient(colors: theme.key, startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(theme.keyEdge, lineWidth: 1))
                .frame(width: 10, height: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: side == .left ? -9 : 9)
        }
        .frame(width: 26, height: 56)
        .clipShape(shape)
        .overlay(shape.stroke(theme.bodyEdge, lineWidth: 1))
    }

    private func sideways(_ side: Side) -> some View {
        let shape = UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: 3, bottomLeading: 14, bottomTrailing: 14, topTrailing: 3),
                                           style: .continuous)
        return ZStack(alignment: .top) {
            Rectangle().fill(LinearGradient(colors: theme.body(side), startPoint: .top, endPoint: .bottom))
            Rectangle().fill(theme.rail(side)).frame(height: 3)
            HStack(spacing: 18) {
                Circle().fill(LinearGradient(colors: theme.key, startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().stroke(theme.keyEdge, lineWidth: 1))
                    .frame(width: 10, height: 10)
                Circle().fill(LinearGradient(colors: theme.key, startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().stroke(theme.keyEdge, lineWidth: 1))
                    .frame(width: 7, height: 7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 62, height: 30)
        .clipShape(shape)
        .overlay(shape.stroke(theme.bodyEdge, lineWidth: 1))
    }
}
