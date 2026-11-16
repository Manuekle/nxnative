import SwiftUI

@main
struct NXPadApp: App {
    @State private var model = AppModel()

    init() {
        AppFont.registerBundled()
        // Version 2 brought the Wii look: a controller left on an older default colour gets the Wii one, once
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: "uiVersion") < 2 {
            defaults.set(PadTheme.defaultID, forKey: SettingsKey.theme)
            defaults.set(2, forKey: "uiVersion")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.light)
                .tint(Wii.blue)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch model.screen {
            case .connect:
                ConnectView()
                    .transition(.opacity)
            case .controller:
                ControllerScreen()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.screen)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
        // The Mac's QR code, scanned with the Camera app: nxpad://pair?…
        .onOpenURL { url in
            model.pair(url: url)
        }
        .sheet(isPresented: Binding(get: { model.showPairing }, set: { shown in
            model.showPairing = shown
            if !shown { model.cancelPairing() }
        })) {
            PairView()
        }
    }
}
