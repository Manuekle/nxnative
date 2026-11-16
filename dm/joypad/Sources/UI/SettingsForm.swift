import SwiftUI

struct SettingsForm: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.theme) private var themeID = PadTheme.defaultID
    @AppStorage(SettingsKey.deadzone) private var deadzone = 0.12
    @AppStorage(SettingsKey.floatingSticks) private var floatingSticks = false
    @AppStorage(SettingsKey.pressHaptics) private var pressHaptics = true
    @AppStorage(SettingsKey.motion) private var motion = true
    @AppStorage(SettingsKey.rumble) private var rumble = true
    @AppStorage(SettingsKey.rumbleStrength) private var rumbleStrength = 1.0
    @AppStorage(SettingsKey.controlScale) private var controlScale = 1.0
    @AppStorage(SettingsKey.autoJoin) private var autoJoin = true
    @State private var forgetting: PairStore.Mac?

    var body: some View {
        Form {
            Section {
                ForEach(model.store.macs) { mac in
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(Wii.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.name).font(AppFont.wii(15)).foregroundStyle(Wii.textStrong)
                            Text(mac.games.isEmpty ? String(localized: "No game played yet")
                                                   : mac.games.prefix(3).map(\.title).joined(separator: ", "))
                                .font(.system(size: 12))
                                .foregroundStyle(Wii.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Forget", role: .destructive) { forgetting = mac }
                            .buttonStyle(.borderless)
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                if model.store.macs.isEmpty {
                    Text("No Mac yet.").foregroundStyle(Wii.muted)
                }
                Toggle(isOn: $autoJoin) { WiiRowLabel("Join open games by themselves") }
            } header: {
                WiiSectionHeader("Paired Macs")
            } footer: {
                Text("A paired Mac's games show up and are joined as soon as they open. A Mac pairs once, with the code its game shows under Controllers > Pair iPhone….")
                    .foregroundStyle(Wii.muted)
            }
            .listRowBackground(Color.white)

            Section {
                ForEach(PadTheme.all) { theme in
                    Button {
                        themeID = theme.id
                    } label: {
                        HStack(spacing: 12) {
                            ThemeSwatch(theme: theme)
                            Text(theme.name)
                                .font(AppFont.wii(15))
                                .foregroundStyle(Wii.textStrong)
                            Spacer()
                            if themeID == theme.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Wii.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                WiiSectionHeader("Colors")
            }
            .listRowBackground(Color.white)

            Section {
                LabeledContent {
                    Text(controlScale, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(Wii.blueText)
                } label: {
                    WiiRowLabel("Size")
                }
                Slider(value: $controlScale, in: 0.8...1.25, step: 0.05)
            } header: {
                WiiSectionHeader("Controller")
            } footer: {
                Text("Smaller if your thumbs do not reach every control, larger for bigger hands. The controls stay at the lower corners, where the thumbs rest.")
                    .foregroundStyle(Wii.muted)
            }
            .listRowBackground(Color.white)

            Section {
                LabeledContent {
                    Text(deadzone, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(Wii.blueText)
                } label: {
                    WiiRowLabel("Dead zone")
                }
                Slider(value: $deadzone, in: 0...0.4, step: 0.01)
                Toggle(isOn: $floatingSticks) { WiiRowLabel("Floating sticks") }
            } header: {
                WiiSectionHeader("Sticks")
            } footer: {
                Text("A floating stick starts where your thumb lands. Tap a stick to click it; tap it, then touch it again and hold to keep it clicked.")
                    .foregroundStyle(Wii.muted)
            }
            .listRowBackground(Color.white)

            Section {
                Toggle(isOn: $pressHaptics) { WiiRowLabel("Vibrate on press") }
                Toggle(isOn: $rumble) { WiiRowLabel("Game rumble") }
                if rumble {
                    LabeledContent {
                        Text(rumbleStrength, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(Wii.blueText)
                    } label: {
                        WiiRowLabel("Rumble strength")
                    }
                    Slider(value: $rumbleStrength, in: 0.1...1, step: 0.05)
                    HStack {
                        Spacer()
                        Button("Test rumble") {
                            model.setRumble(enabled: rumble, strength: rumbleStrength)
                            model.testRumble()
                        }
                        .buttonStyle(WiiButtonStyle(compact: true))
                        Spacer()
                    }
                }
            } header: {
                WiiSectionHeader("Feedback")
            }
            .listRowBackground(Color.white)

            Section {
                Toggle(isOn: $motion) { WiiRowLabel("Send the phone's gyro") }
            } header: {
                WiiSectionHeader("Motion")
            } footer: {
                Text("The game reads the phone's movement as the Joy-Cons' motion sensors: aiming, tilting, shaking.")
                    .foregroundStyle(Wii.muted)
            }
            .listRowBackground(Color.white)

            Section {
                LabeledContent {
                    Text(verbatim: "NXPD \(Wire.version)").foregroundStyle(Wii.muted)
                } label: {
                    WiiRowLabel("Protocol")
                }
                LabeledContent {
                    Text(verbatim: String(Wire.defaultPort)).foregroundStyle(Wii.muted)
                } label: {
                    WiiRowLabel("Port")
                }
            } header: {
                WiiSectionHeader("About")
            }
            .listRowBackground(Color.white)
        }
        .wiiForm()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Settings").font(AppFont.wii(17)).foregroundStyle(Wii.textStrong)
            }
        }
        .confirmationDialog(Text(forgetting.map { "Forget \($0.name)?" } ?? ""), isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                if let mac = forgetting { model.forgetMac(mac.id) }
                forgetting = nil
            }
        } message: {
            Text("This iPhone stops joining its games until it is paired again with a new code.")
        }
    }
}

struct ThemeSwatch: View {
    let theme: PadTheme

    var body: some View {
        HStack(spacing: 2) {
            UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: 7, bottomLeading: 7, bottomTrailing: 2, topTrailing: 2))
                .fill(theme.swatch.0)
            UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: 2, bottomLeading: 2, bottomTrailing: 7, topTrailing: 7))
                .fill(theme.swatch.1)
        }
        .frame(width: 30, height: 22)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Wii.line, lineWidth: 1))
    }
}

/// The gear button's sheet, over the controller.
struct MenuSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.mode) private var storedMode = PadMode.pair

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        Text(model.statusText).foregroundStyle(Wii.blueText)
                    } label: {
                        WiiRowLabel("Status")
                    }
                    if !model.gameTitle.isEmpty {
                        LabeledContent {
                            Text(model.gameTitle).foregroundStyle(Wii.muted)
                        } label: {
                            WiiRowLabel("Game")
                        }
                    }
                    if let ms = model.latencyMs {
                        LabeledContent {
                            Text(verbatim: "\(ms) ms").monospacedDigit().foregroundStyle(Wii.muted)
                        } label: {
                            WiiRowLabel("Latency")
                        }
                    }
                } header: {
                    WiiSectionHeader("Status")
                }
                .listRowBackground(Color.white)

                if model.sessions.count > 1 {
                    Section {
                        ForEach(model.sessions) { session in
                            Button {
                                model.switchTo(session.id)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title).font(AppFont.wii(15)).foregroundStyle(Wii.textStrong)
                                        Text(session.player.map { String(localized: "\(session.macName) · player \($0 + 1)") } ?? session.macName)
                                            .font(.system(size: 12)).foregroundStyle(Wii.muted)
                                    }
                                    Spacer()
                                    if session.id == model.activeID {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Wii.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        WiiSectionHeader("Open games")
                    } footer: {
                        Text("⇄ beside the menu button switches too. Each game keeps your player and how you hold the phone.")
                            .foregroundStyle(Wii.muted)
                    }
                    .listRowBackground(Color.white)
                }

                Section {
                    Picker("Mode", selection: Binding(get: { model.mode }, set: { mode in
                        storedMode = mode
                        model.setMode(mode)
                    })) {
                        ForEach(PadMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    NavigationLink {
                        SettingsForm()
                    } label: {
                        WiiRowLabel("Settings")
                    }
                } header: {
                    WiiSectionHeader("Controller")
                }
                .listRowBackground(Color.white)

                Section {
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            dismiss()
                            model.leave()
                        } label: {
                            if model.offline {
                                Label("Leave test", systemImage: "xmark.circle.fill")
                            } else {
                                Label("Back to games", systemImage: "xmark.circle.fill")
                            }
                        }
                        .buttonStyle(WiiButtonStyle(kind: .danger))
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)
            }
            .wiiForm()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(AppFont.wii(16))
                        .tint(Wii.blueDark)
                }
            }
        }
    }
}

/// A settings section's title, in the Wii's typeface and blue.
struct WiiSectionHeader: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(AppFont.wii(13))
            .foregroundStyle(Wii.blueText)
            .textCase(nil)
    }
}

/// A settings row's name.
struct WiiRowLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Wii.textStrong)
    }
}

extension View {
    /// A form on the Wii Menu's stripes, its rows on white, its controls sky blue.
    func wiiForm() -> some View {
        scrollContentBackground(.hidden)
            .background(WiiStripes().ignoresSafeArea())
            .tint(Wii.blue)
            .environment(\.colorScheme, .light)
    }
}

extension PadMode {
    var title: LocalizedStringKey {
        switch self {
        case .pair: return "Pair"
        case .left: return "Left Joy-Con"
        case .right: return "Right Joy-Con"
        }
    }
}
