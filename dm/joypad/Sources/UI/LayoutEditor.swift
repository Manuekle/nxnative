import SwiftUI

/// The controller's layout editor (the menu's Customize the layout). It lies over the controls, which the controller screen
/// draws from the same layout: every control takes a drag, and the one touched last shows in the panel, to resize it, hide
/// it or make its button lock. What changes goes to `profile` at once.
struct LayoutEditor: View {
    /// The layout as edited so far, hidden controls included.
    let layout: PadLayout
    /// The layout as designed: the buttons a key can be added for.
    let base: PadLayout
    @Binding var profile: PadProfile
    let size: CGSize
    let theme: PadTheme
    /// The game played, when there is one: its layout can be its own.
    let gameTitle: String?
    @Binding var perGame: Bool
    let onReset: () -> Void
    let onDone: () -> Void

    @State private var selection: String?
    @State private var panelOffset = CGSize.zero
    @State private var panelStart: CGSize?
    @State private var drags = DragOrigins()
    @State private var confirmReset = false

    /// Where each control was when the finger on it came down. Not view state: nothing is drawn from it.
    private final class DragOrigins {
        var origin: [String: CGPoint] = [:]
        var moved: Set<String> = []
    }

    private static let panelWidth: CGFloat = 292
    /// The selection that stands for the phone's motion, which is no control on the screen.
    private static let gyroID = "gyro"

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selection = nil }
            ForEach(layout.controls) { control in
                handle(control)
            }
            panel
                .offset(panelOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
        }
        .frame(width: size.width, height: size.height)
        .confirmationDialog("Reset this layout?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                selection = nil
                onReset()
            }
        } message: {
            if gameTitle != nil, perGame {
                Text("This game goes back to the layout every game uses.")
            } else {
                Text("Every control goes back to where it was, and the buttons you added go.")
            }
        }
    }

    private var selected: Control? {
        selection.flatMap { id in layout.controls.first { $0.id == id } }
    }

    // MARK: Handles

    private func handle(_ control: Control) -> some View {
        let isSelected = selection == control.id
        let box = control.extent
        let w = max(box.width, 34) + 10, h = max(box.height, 34) + 10
        let shape = RoundedRectangle(cornerRadius: min(w, h) * 0.26, style: .continuous)
        let idle = theme.light ? Wii.muted.opacity(0.75) : Color.white.opacity(0.6)
        return shape
            .strokeBorder(isSelected ? Wii.blue : idle,
                          style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: isSelected ? [] : [5, 4]))
            .background(shape.fill(isSelected ? Wii.blue.opacity(0.14) : Color.clear))
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .position(control.center)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in drag(control, by: value.translation) }
                    .onEnded { _ in
                        drags.origin[control.id] = nil
                        drags.moved.remove(control.id)
                    }
            )
            .accessibilityLabel(Text(control.title(in: layout.mode)))
    }

    private func drag(_ control: Control, by translation: CGSize) {
        let origin = drags.origin[control.id] ?? control.center
        if drags.origin[control.id] == nil {
            drags.origin[control.id] = origin
            selection = control.id
        }
        // A tap selects without nudging the control
        guard drags.moved.contains(control.id) || hypot(translation.width, translation.height) > 4 else { return }
        drags.moved.insert(control.id)
        let p = PadLayout.onScreen(CGPoint(x: origin.x + translation.width, y: origin.y + translation.height), size)
        var tweak = profile.tweak(control.id)
        tweak.x = Double(p.x / size.width)
        tweak.y = Double(p.y / size.height)
        profile.setTweak(tweak, for: control.id)
    }

    // MARK: Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Wii.muted)
                Text("Customize")
                    .font(AppFont.wii(16))
                    .foregroundStyle(Wii.textStrong)
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(WiiButtonStyle(kind: .primary, compact: true))
            }
            .contentShape(Rectangle())
            .gesture(panelDrag)

            if gameTitle != nil {
                Picker("Layout for", selection: $perGame) {
                    Text("This game").tag(true)
                    Text("Every game").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if selection == Self.gyroID {
                        gyroInspector
                    } else if let control = selected {
                        inspector(control)
                    } else {
                        Text("Drag a control to move it. Tap one to resize it, hide it, or change how it works: a button can lock (a tap holds it down until the next tap), a stick can press buttons, like pushing up to accelerate. Motion moves a stick with the phone itself.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Wii.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 3)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: max(size.height - 190, 90))
            Divider()

            HStack {
                Menu {
                    Button("Camera area") {
                        selection = profile.addZone()
                    }
                    Divider()
                    ForEach(addable, id: \.self) { button in
                        Button(addTitle(button)) {
                            selection = profile.addExtra(button)
                        }
                    }
                } label: {
                    Label("Add a button", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                Button {
                    selection = Self.gyroID
                } label: {
                    Label("Motion", systemImage: "gyroscope")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityAddTraits(profile.gyro != nil ? .isSelected : [])
                Spacer()
                Button("Reset", role: .destructive) { confirmReset = true }
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(profile.isEmpty)
            }
        }
        .padding(12)
        .frame(width: Self.panelWidth)
        .wiiPanel(radius: 20)
        .tint(Wii.blue)
        .environment(\.colorScheme, .light)
    }

    /// The panel moves by its title bar, out of the way of the controls under it.
    private var panelDrag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let start = panelStart ?? panelOffset
                if panelStart == nil { panelStart = start }
                let reachX = max(size.width / 2 - 70, 0)
                panelOffset = CGSize(width: min(max(start.width + value.translation.width, -reachX), reachX),
                                     height: min(max(start.height + value.translation.height, -4), max(size.height - 70, 0)))
            }
            .onEnded { _ in panelStart = nil }
    }

    @ViewBuilder
    private func inspector(_ control: Control) -> some View {
        let tweak = profile.tweak(control.id)
        HStack(spacing: 8) {
            Text(control.title(in: layout.mode))
                .font(AppFont.wii(15))
                .foregroundStyle(Wii.textStrong)
                .lineLimit(1)
            Spacer()
            if control.isZone {
                Button(role: .destructive) {
                    profile.removeZone(control.id)
                    selection = nil
                } label: {
                    Label("Remove", systemImage: "trash.fill")
                }
                .font(.system(size: 13, weight: .semibold))
            } else if control.isExtra {
                Button(role: .destructive) {
                    profile.locked.subtract(lockable(control).filter { button in !stillDrawn(button, without: control.id) })
                    profile.removeExtra(control.id)
                    selection = nil
                } label: {
                    Label("Remove", systemImage: "trash.fill")
                }
                .font(.system(size: 13, weight: .semibold))
            } else if control.canHide {
                Button {
                    var t = tweak
                    t.hidden.toggle()
                    profile.setTweak(t, for: control.id)
                } label: {
                    Label(tweak.hidden ? "Show" : "Hide", systemImage: tweak.hidden ? "eye.fill" : "eye.slash.fill")
                }
                .font(.system(size: 13, weight: .semibold))
            }
        }
        HStack(spacing: 10) {
            Text("Size")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Wii.text)
            Slider(value: Binding(get: { tweak.scale }, set: { scale in
                var t = profile.tweak(control.id)
                t.scale = (scale * 20).rounded() / 20
                profile.setTweak(t, for: control.id)
            }), in: ControlTweak.scaleRange)
            Text(tweak.scale, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Wii.blueText)
                .frame(width: 42, alignment: .trailing)
        }
        if case .stick = control.kind {
            stickInspector(control)
        }
        if control.isZone {
            zoneInspector(control)
        }
        let keys = lockable(control)
        if keys.count == 1, let button = keys.first {
            Toggle(isOn: lockBinding(button)) {
                Label("Lock on tap", systemImage: "lock.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Wii.text)
            }
        } else if keys.count > 1 {
            HStack(spacing: 8) {
                Label("Lock on tap", systemImage: "lock.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Wii.text)
                Spacer()
                ForEach(keys, id: \.self) { button in
                    let on = profile.locked.contains(button)
                    Button {
                        lockBinding(button).wrappedValue = !on
                    } label: {
                        KeyLabelView(label: layout.label(for: button), size: 14, color: on ? .white : Wii.textStrong)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(on ? AnyShapeStyle(Wii.primaryFill) : AnyShapeStyle(Wii.buttonFill)))
                            .overlay(Circle().strokeBorder(on ? Wii.primaryRim : Wii.buttonRim, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(layout.label(for: button).title))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Camera area and motion

    private func zoneBinding(_ id: String) -> Binding<ZoneSpec> {
        Binding(get: { profile.zones.first { $0.id == id } ?? ZoneSpec(id: id) }, set: { new in
            if let i = profile.zones.firstIndex(where: { $0.id == id }) { profile.zones[i] = new }
        })
    }

    /// A finger sweeping in the area steers a stick, from where it lands.
    @ViewBuilder
    private func zoneInspector(_ control: Control) -> some View {
        let zone = zoneBinding(control.id)
        Picker("Steers", selection: zone.rightStick) {
            Text("Left stick").tag(false)
            Text("Right stick").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        sensitivityRow(zone.sensitivity, range: ZoneSpec.sensitivityRange)
        VStack(spacing: 4) {
            Toggle("Flip side to side", isOn: zone.invertX)
            Toggle("Flip up and down", isOn: zone.invertY)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Wii.text)
        Text("A finger sweeping here steers the stick from where it lands. Anything else on the area still takes its own touches.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Wii.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sensitivityRow(_ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text("Speed")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Wii.text)
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 * 20).rounded() / 20 }), in: range)
            Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Wii.blueText)
                .frame(width: 42, alignment: .trailing)
        }
    }

    /// The phone's own motion as a stick: it does not belong to a control on the screen.
    @ViewBuilder
    private var gyroInspector: some View {
        let on = Binding(get: { profile.gyro != nil }, set: { profile.gyro = $0 ? GyroRule() : nil })
        Toggle(isOn: on) {
            Label("Move a stick with the phone", systemImage: "gyroscope")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Wii.textStrong)
        }
        if let current = profile.gyro {
            let rule = Binding(get: { current }, set: { profile.gyro = $0 })
            Picker("Motion", selection: rule.mode) {
                Text("Steering wheel").tag(GyroRule.Mode.wheel)
                Text("Aim").tag(GyroRule.Mode.aim)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("Stick", selection: rule.rightStick) {
                Text("Left stick").tag(false)
                Text("Right stick").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            sensitivityRow(rule.sensitivity, range: GyroRule.sensitivityRange)
            VStack(spacing: 4) {
                Toggle("Flip side to side", isOn: rule.invertX)
                if current.mode == .aim { Toggle("Flip up and down", isOn: rule.invertY) }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Wii.text)
            HStack {
                Text("Only while holding")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Wii.text)
                Spacer()
                directionMenu("Hold", systemImage: "hand.tap.fill", selection: rule.holdButton)
                    .frame(width: 100)
            }
            Text(current.mode == .wheel
                 ? "Turn the phone like a steering wheel: straight is where you hold it when you close this panel (or when the button goes down)."
                 : "How fast you turn the phone is how far the stick goes, so the camera follows where it points.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Wii.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Stick

    private func ruleBinding(_ id: String) -> Binding<StickRule> {
        Binding(get: { profile.rule(id) }, set: { profile.setRule($0, for: id) })
    }

    /// Everything a stick can be set to: which way it reads, what its directions press, whether its tilt stays.
    @ViewBuilder
    private func stickInspector(_ control: Control) -> some View {
        let rule = ruleBinding(control.id)
        Picker("Reads", selection: rule.axis) {
            Text("Any way").tag(StickRule.Axis.both)
            Text("Side to side").tag(StickRule.Axis.horizontal)
            Text("Up and down").tag(StickRule.Axis.vertical)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Toggle(isOn: rule.locksTilt) {
            Label("Lock the tilt", systemImage: "lock.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Wii.text)
        }
        Text("Presses a button when tilted")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Wii.muted)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
            directionMenu("Up", systemImage: "arrow.up", selection: rule.up)
            directionMenu("Down", systemImage: "arrow.down", selection: rule.down)
            directionMenu("Left", systemImage: "arrow.left", selection: rule.left)
            directionMenu("Right", systemImage: "arrow.right", selection: rule.right)
        }
    }

    private func directionMenu(_ name: LocalizedStringKey, systemImage: String, selection: Binding<PadButton?>) -> some View {
        Menu {
            Button("Nothing") { selection.wrappedValue = nil }
            // The buttons a game holds down to drive come first
            let first: [PadButton] = [.a, .b, .x, .y, .zr, .zl, .r, .l]
            let all = addable
            ForEach(first.filter(all.contains) + all.filter { !first.contains($0) }, id: \.self) { button in
                Button(base.label(for: button).title) { selection.wrappedValue = button }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                Text(selection.wrappedValue.map { base.label(for: $0).title } ?? "—")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(selection.wrappedValue == nil ? AnyShapeStyle(Wii.buttonFill) : AnyShapeStyle(Wii.blue.opacity(0.18))))
        }
        .accessibilityLabel(Text(name))
    }

    // MARK: Buttons

    /// The buttons a control presses: the ones that can lock. A stick and the menu button have none.
    private func lockable(_ control: Control) -> [PadButton] {
        switch control.kind {
        case .key(let button, _, _): return [button]
        case .cluster(let cluster): return cluster.keys
        case .stick, .action, .zone: return []
        }
    }

    private func lockBinding(_ button: PadButton) -> Binding<Bool> {
        Binding(get: { profile.locked.contains(button) }, set: { on in
            if on { profile.locked.insert(button) } else { profile.locked.remove(button) }
        })
    }

    /// Whether some other control than `id` still presses the button.
    private func stillDrawn(_ button: PadButton, without id: String) -> Bool {
        layout.controls.contains { $0.id != id && lockable($0).contains(button) }
    }

    /// Every button of this way of holding the phone, once each: a key can be added for any of them.
    private var addable: [PadButton] {
        var seen = Set<PadButton>()
        return base.buttons.filter { seen.insert($0).inserted }
    }

    private func addTitle(_ button: PadButton) -> String {
        let name = base.label(for: button).title
        return button == .ls || button == .rs ? String(localized: "\(name) (stick click)") : name
    }
}

extension Control {
    /// The control's name in the layout editor.
    func title(in mode: PadMode) -> String {
        switch kind {
        case .key(_, _, let label):
            return isExtra ? String(localized: "\(label.title) (added)") : label.title
        case .cluster(let cluster):
            return cluster.keys.contains(.a) ? "A B X Y" : String(localized: "Direction buttons")
        case .stick(let side, _, _):
            guard mode == .pair else { return String(localized: "Stick") }
            return side == .left ? String(localized: "Left stick") : String(localized: "Right stick")
        case .zone:
            return String(localized: "Camera area")
        case .action(let action, _):
            return action == .menu ? String(localized: "Menu") : String(localized: "Switch game")
        }
    }
}
