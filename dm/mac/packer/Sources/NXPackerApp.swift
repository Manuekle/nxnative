import AppKit
import SwiftUI

@main
struct NXPackerApp: App {
    @NSApplicationDelegateAdaptor(PackerDelegate.self) private var delegate

    var body: some Scene {
        Window("NX Packer", id: "packer") {
            PackerView()
                .environmentObject(delegate.build)
                .preferredColorScheme(.light)
                .frame(minWidth: 800, minHeight: 550)
        }
        .defaultSize(width: 950, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class PackerDelegate: NSObject, NSApplicationDelegate {
    let build = BuildSession()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFont.registerBundled()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard build.active else { return .terminateNow }
        build.onFinish = { sender.reply(toApplicationShouldTerminate: true) }
        build.cancel()
        return .terminateLater
    }
}
