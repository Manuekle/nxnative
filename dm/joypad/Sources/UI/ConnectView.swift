import SwiftUI

/// The first screen, as a Wii Menu page: the games on this network and the ones played before as channels on the left, how
/// the phone is held and its colours on the right. A paired Mac's game that opens is joined by itself (AppModel).
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.mode) private var mode = PadMode.pair
    @AppStorage(SettingsKey.theme) private var themeID = PadTheme.defaultID
    @AppStorage(SettingsKey.lastAddress) private var address = ""
    @State private var showSettings = false
    @State private var badAddress = false
    @State private var showAddress = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        let theme = PadTheme.named(themeID)
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 16) {
                gamesPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controllerPanel(theme)
                    .frame(width: 330)
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .background(WiiStripes().ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsForm()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                                .font(AppFont.wii(16))
                                .tint(Wii.blueDark)
                        }
                    }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Spacer()
            Button {
                model.resetPairing()
                model.showPairing = true
            } label: {
                Label("Pair a Mac", systemImage: "link")
            }
            .buttonStyle(WiiButtonStyle(compact: true))
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(WiiButtonStyle(compact: true))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background {
            LinearGradient(colors: [.white, Color(hex: 0xF2F4F6)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .bottom) { Rectangle().fill(Wii.line).frame(height: 2) }
                .shadow(color: Wii.shadow.opacity(0.08), radius: 8, y: 4)
                .ignoresSafeArea(edges: [.top, .horizontal])
        }
    }

    // MARK: Games

    private var gamesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            WiiHeading("Games")
            if let notice = model.connectNotice {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Wii.blueText)
            }
            gameList
                .frame(maxHeight: .infinity, alignment: .top)
            manualEntry
        }
        .padding(16)
        .wiiPanel()
    }

    @ViewBuilder
    private var gameList: some View {
        let browser = model.browser
        let open = browser.hosts
        let openKeys = Set(open.compactMap { h in h.macID.map { "\($0)/\(h.gameKey)" } })
        let closed = model.store.macs.flatMap { mac in
            mac.games.filter { !openKeys.contains("\(mac.id)/\($0.id)") }.map { (mac, $0) }
        }
        if open.isEmpty && closed.isEmpty {
            emptyState(problem: browser.problem)
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(open) { host in
                        HostChannel(host: host, paired: model.isPaired(host), linked: model.session(for: host) != nil) {
                            model.open(host)
                        }
                    }
                    if open.isEmpty {
                        waitingRow(problem: browser.problem)
                    }
                    ForEach(closed, id: \.1.id) { mac, game in
                        ClosedGameChannel(title: game.title, mac: mac.name) {
                            withAnimation(.easeOut(duration: 0.2)) { model.forgetGame(game.id, on: mac.id) }
                        }
                    }
                    if closed.count > 1 {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                for (mac, game) in closed { model.forgetGame(game.id, on: mac.id) }
                            }
                        } label: {
                            Label("Clear closed games", systemImage: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Wii.blueText)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Nothing open and nothing played yet: how it starts.
    private func emptyState(problem: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProgressView().tint(Wii.blue)
                Text("Looking for games on this network…")
                    .font(AppFont.wii(15))
                    .foregroundStyle(Wii.textStrong)
            }
            Text(model.store.macs.isEmpty
                 ? "Open a game on your Mac, choose Controllers > Pair iPhone… and pair this iPhone once. Then its games show here and NX Pad joins them by itself."
                 : "Open a game on your Mac, on the same Wi-Fi: NX Pad joins it by itself.")
                .font(.system(size: 13))
                .foregroundStyle(Wii.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Wii.red)
            }
            if model.store.macs.isEmpty {
                Button {
                    model.resetPairing()
                    model.showPairing = true
                } label: {
                    Label("Pair a Mac", systemImage: "link")
                }
                .buttonStyle(WiiButtonStyle(kind: .primary, compact: true))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiiChannel()
    }

    private func waitingRow(problem: String?) -> some View {
        HStack(spacing: 12) {
            ProgressView().tint(Wii.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("No game open right now")
                    .font(AppFont.wii(14))
                    .foregroundStyle(Wii.textStrong)
                Text(problem ?? String(localized: "Open one on your Mac: NX Pad joins it by itself."))
                    .font(.system(size: 12, weight: problem == nil ? .regular : .medium))
                    .foregroundStyle(problem == nil ? Wii.muted : Wii.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiiChannel()
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showAddress {
                HStack(spacing: 10) {
                    TextField("Address (192.168.1.20 or mac.local:48620)", text: $address)
                        .font(.system(size: 15))
                        .foregroundStyle(Wii.textStrong)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit(connectToAddress)
                        .wiiField(focused: addressFocused)
                    Button("Connect", action: connectToAddress)
                        .buttonStyle(WiiButtonStyle(kind: .primary, compact: true))
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button("Connect by address…") { showAddress = true }
                    .font(.system(size: 13, weight: .medium))
                    .tint(Wii.blueText)
            }
            if badAddress {
                Text("That address is not valid.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Wii.red)
                    .padding(.leading, 16)
            }
        }
    }

    private func connectToAddress() {
        badAddress = !model.connect(address: address)
    }

    // MARK: Controller

    private func controllerPanel(_ theme: PadTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WiiHeading("Controller")
            HStack(spacing: 10) {
                ForEach(PadMode.allCases) { m in
                    ModeChannel(mode: m, theme: theme, selected: m == mode) { mode = m }
                }
            }
            WiiHeading("Colors", size: 15)
            HStack(spacing: 8) {
                ForEach(PadTheme.all) { t in
                    Button {
                        themeID = t.id
                    } label: {
                        ThemeSwatch(theme: t)
                            .padding(5)
                            .wiiChannel(selected: themeID == t.id, radius: 10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(t.name))
                }
            }
            Spacer(minLength: 0)
            Button {
                model.startOffline(mode: mode)
            } label: {
                Label("Try the layout offline", systemImage: "hand.tap.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(WiiButtonStyle(compact: true))
        }
        .padding(16)
        .wiiPanel()
    }
}

/// A game open on this network, as a Wii channel: its name, its Mac, and whether this iPhone may play it yet.
private struct HostChannel: View {
    let host: HostBrowser.Host
    let paired: Bool
    let linked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                WiiIconBadge(systemName: "gamecontroller.fill", size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(host.displayTitle)
                        .font(AppFont.wii(17))
                        .foregroundStyle(Wii.textStrong)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(paired ? Wii.muted : Wii.blueText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if paired {
                    Image(systemName: linked ? "dot.radiowaves.left.and.right" : "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Wii.blue)
                } else {
                    Label("Pair now", systemImage: "link")
                        .font(AppFont.wii(13))
                        .foregroundStyle(Wii.blueText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChannelPressStyle())
    }

    private var subtitle: String {
        let mac = host.macName ?? host.name
        if host.macID == nil { return String(localized: "\(mac) · update this game to play with NX Pad") }
        if !paired { return String(localized: "\(mac) · pair once to play") }
        return linked ? String(localized: "\(mac) · linked") : mac
    }
}

/// A game played before that is not open now: shown grey, and joined by itself when it opens.
private struct ClosedGameChannel: View {
    let title: String
    let mac: String
    /// Takes the game off the list: a game played before is only a memory, and a game that opens again is back.
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Wii.muted)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Wii.panel2))
                .overlay(Circle().strokeBorder(Wii.line, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.wii(16))
                    .foregroundStyle(Wii.muted)
                    .lineLimit(1)
                Text("Closed · open it on \(mac) to play")
                    .font(.system(size: 12))
                    .foregroundStyle(Wii.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Wii.muted)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Wii.panel2))
                    .overlay(Circle().strokeBorder(Wii.line, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(title)"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(0.85)
        .wiiChannel()
        .contextMenu {
            Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
        }
    }
}

/// How the phone is held, as a small Wii channel with the shape of the controller.
private struct ModeChannel: View {
    let mode: PadMode
    let theme: PadTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                MiniPad(mode: mode, theme: theme)
                    .frame(height: 58)
                Text(mode.title)
                    .font(AppFont.wii(12))
                    .foregroundStyle(selected ? Wii.blueText : Wii.textStrong)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChannelPressStyle(selected: selected))
    }
}

/// A channel that lights up sky blue while it is held, as the Wii Menu's do under the pointer.
private struct ChannelPressStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .wiiChannel(selected: selected || configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
