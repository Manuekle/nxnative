import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PackerView: View {
    private static let packageExtensions = ["nsp", "xci", "nsz", "xcz"]

    @EnvironmentObject private var build: BuildSession
    @AppStorage("checkoutPath") private var checkoutPath = ""
    @AppStorage("pythonPath") private var pythonPath = ""
    @State private var game: URL?
    @State private var keys: URL?
    @State private var output: URL?
    @State private var target = BuildTarget.ios
    @State private var inputError: String?
    @State private var showingTools = false
    @State private var showingLog = false

    private var checkout: URL? {
        let location = checkoutPath.isEmpty ? Bundle.main.bundleURL : URL(fileURLWithPath: checkoutPath)
        return BuildTools.checkout(containing: location)
    }

    private var python: URL? {
        if pythonPath.isEmpty { return BuildTools.defaultPython }
        return FileManager.default.isExecutableFile(atPath: pythonPath) ? URL(fileURLWithPath: pythonPath) : nil
    }

    private var needsKeys: Bool {
        guard let game, game.hasDirectoryPath else { return false }
        let files = (try? FileManager.default.contentsOfDirectory(at: game, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return files.contains {
            !$0.lastPathComponent.hasPrefix("._") && Self.packageExtensions.contains($0.pathExtension.lowercased())
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private var canBuild: Bool {
        !build.active && checkout != nil && python != nil && game != nil && (!needsKeys || keys != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 18) {
                    HStack(alignment: .top, spacing: 18) {
                        inputs.frame(maxWidth: .infinity)
                        destination.frame(maxWidth: .infinity)
                    }
                    .disabled(build.active)
                    status
                }
                .padding(24)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .background { WiiStripes() }
        }
        .sheet(isPresented: $showingTools) { toolsSheet }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 47, height: 47)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                WiiHeading("NX Packer", size: 26)
                Text("Build a game for your Mac, iPhone, or iPad.")
                    .foregroundStyle(Wii.muted)
            }
            Spacer()
            Button { showingTools = true } label: { Label("Build Tools", systemImage: "gearshape") }
                .buttonStyle(WiiButtonStyle(compact: true))
                .disabled(build.active)
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 14)
        .background(Wii.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Wii.line).frame(height: 1) }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 12) {
            WiiHeading("Game files", size: 20)
            PickerCard(title: "Game", hint: "Drop a game file or folder",
                       icon: "folder", selection: game, choose: chooseGame, accept: selectGame)
            PickerCard(title: "prod.keys", hint: game != nil && !needsKeys ? "Optional for this source" : "Drop your local keys file",
                       icon: "key", selection: keys, choose: chooseKeys, accept: selectKeys)
            if let inputError {
                Text(verbatim: inputError)
                    .font(.callout)
                    .foregroundStyle(Wii.red)
            }
        }
        .padding(18)
        .wiiPanel()
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 12) {
            WiiHeading("Build for", size: 20)
            HStack(spacing: 10) {
                ForEach(BuildTarget.allCases) { option in
                    Button {
                        selectTarget(option)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: option.icon)
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(Wii.blueText)
                                .accessibilityHidden(true)
                            Text(option.title)
                                .font(AppFont.wii(15))
                                .foregroundStyle(Wii.textStrong)
                            Text("." + option.fileExtension)
                                .font(.caption)
                                .foregroundStyle(Wii.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 88)
                        .wiiChannel(selected: target == option, radius: 16)
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(target == option ? .isSelected : [])
                }
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    WiiHeading("Save to", size: 14)
                    Text(output?.lastPathComponent ?? "Game folder")
                        .foregroundStyle(Wii.muted)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(output?.path ?? "The output stays beside the game files.")
                }
                Spacer(minLength: 0)
                if output != nil {
                    Button { output = nil } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(WiiButtonStyle(compact: true))
                        .accessibilityLabel("Reset output location")
                        .help("Use the game folder")
                }
                Button("Choose…", action: chooseOutput)
                    .buttonStyle(WiiButtonStyle(compact: true))
                    .accessibilityLabel("Choose output location")
            }
            .padding(.horizontal, 3)
            .frame(minHeight: 36)

            HStack {
                Spacer()
                Button(action: startBuild) { Label("Build Game", systemImage: "hammer") }
                    .buttonStyle(WiiButtonStyle(kind: .primary))
                    .disabled(!canBuild)
            }
        }
        .padding(18)
        .wiiPanel()
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch build.phase {
            case .idle:
                if checkout == nil || python == nil {
                    statusLabel("Set up Build Tools", icon: "gearshape",
                                detail: "Choose an nxnative checkout and Python 3.12 or newer.")
                } else {
                    statusLabel("Ready when you are", icon: "clock",
                                detail: "First builds can take 30–60 minutes. Later builds reuse extracted files.")
                }
            case .building, .stopping:
                HStack(alignment: .center) {
                    statusLabel(build.phase == .stopping ? "Stopping build…" : build.gameName ?? "Building game",
                                icon: "gearshape.2", detail: [build.stage, build.step].filter { !$0.isEmpty }.joined(separator: " · "))
                    Spacer()
                    if !build.stageCount.isEmpty {
                        Text(build.stageCount)
                            .foregroundStyle(Wii.muted)
                            .font(.callout.monospacedDigit())
                    }
                    Button("Cancel", action: build.cancel)
                        .buttonStyle(WiiButtonStyle(kind: .danger, compact: true))
                        .disabled(build.phase == .stopping)
                }
                if let fraction = build.fraction {
                    ProgressView(value: fraction).accessibilityLabel("Current build step")
                } else {
                    ProgressView().progressViewStyle(.linear).accessibilityLabel("Building")
                }
            case let .completed(file):
                HStack {
                    statusLabel(build.hasNotes ? "Build complete with notes" : "Build complete",
                                icon: "checkmark.circle", detail: file.lastPathComponent)
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(WiiButtonStyle(compact: true))
                }
            case let .failed(message):
                statusLabel("Build failed", icon: "exclamationmark.triangle", detail: message, color: Wii.red)
            case .cancelled:
                statusLabel("Build cancelled", icon: "stop.circle", detail: "Run Build Game to try again.")
            }
            if !build.diagnostics.isEmpty {
                DisclosureGroup("Build Log", isExpanded: $showingLog) {
                    ScrollView {
                        Text(verbatim: build.diagnostics.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Wii.textStrong)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 140)
                    .background(Wii.panel, in: RoundedRectangle(cornerRadius: 10))
                }
                .font(.callout)
            }
        }
        .tint(Wii.blueDark)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiiPanel(radius: 19)
    }

    private func statusLabel(_ title: String, icon: String, detail: String, color: Color = Wii.blueText) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 19, weight: .medium))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(AppFont.wii(15)).foregroundStyle(Wii.textStrong)
                Text(verbatim: detail).font(.callout).foregroundStyle(Wii.muted).textSelection(.enabled)
            }
        }
    }

    private var toolsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            WiiHeading("Build Tools", size: 22)
            PickerCard(title: "nxnative checkout", hint: "Choose the folder with the packing script",
                       icon: "folder.badge.gearshape", selection: checkout, choose: chooseCheckout, accept: selectCheckout)
            PickerCard(title: "Python 3.12 or newer", hint: "Choose the executable from your build environment",
                       icon: "terminal", selection: python, choose: choosePython, accept: selectPython)
            if let inputError {
                Text(verbatim: inputError).foregroundStyle(Wii.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Done") { inputError = nil; showingTools = false }
                    .buttonStyle(WiiButtonStyle(kind: .primary))
            }
        }
        .padding(22)
        .frame(width: 510)
        .background { WiiStripes() }
    }

    private func startBuild() {
        guard canBuild, let checkout, let python, let game else { return }
        showingLog = false
        inputError = nil
        build.start(BuildRequest(checkout: checkout, python: python, game: game, keys: keys, target: target, output: output))
    }

    private func chooseGame() {
        let types = (Self.packageExtensions + ["nup"]).compactMap { UTType(filenameExtension: $0) }
        if let url = choose(withTitle: "Choose a game file or folder", files: true, directories: true, types: [.folder] + types) {
            _ = selectGame(url)
        }
    }

    private func selectGame(_ url: URL) -> Bool {
        guard !build.active else { return false }
        let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let ext = url.pathExtension.lowercased()
        guard FileManager.default.isReadableFile(atPath: url.path),
              folder || ext == "nup" || Self.packageExtensions.contains(ext) else {
            inputError = "Choose a game folder or an NSP, XCI, NSZ, XCZ, or NUP file."
            return false
        }
        if folder || ext == "nup" {
            game = URL(fileURLWithPath: url.path, isDirectory: folder)
            if !folder { selectTarget(.mac) }
        } else {
            game = url.deletingLastPathComponent()
        }
        inputError = nil
        return true
    }

    private func selectTarget(_ option: BuildTarget) {
        guard target != option else { return }
        target = option
        output = nil
    }

    private func chooseKeys() {
        if let url = choose(withTitle: "Choose your prod.keys file", files: true) { _ = selectKeys(url) }
    }

    private func selectKeys(_ url: URL) -> Bool {
        guard !build.active else { return false }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: url.path) else {
            inputError = "Choose a readable prod.keys file."
            return false
        }
        keys = url
        inputError = nil
        return true
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.title = "Choose where to save the build"
        if let type = UTType(filenameExtension: target.fileExtension) { panel.allowedContentTypes = [type] }
        let gameName = game?.hasDirectoryPath == true ? game?.lastPathComponent : game?.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = (gameName ?? "Game") + "." + target.fileExtension
        panel.directoryURL = game?.hasDirectoryPath == true ? game : game?.deletingLastPathComponent()
        if panel.runModal() == .OK { output = panel.url }
    }

    private func chooseCheckout() {
        if let url = choose(withTitle: "Choose the nxnative checkout", directories: true) { _ = selectCheckout(url) }
    }

    private func selectCheckout(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let root = BuildTools.checkout(containing: url) else {
            inputError = "This folder does not contain the nxnative packing script."
            return false
        }
        checkoutPath = root.path
        inputError = nil
        return true
    }

    private func choosePython() {
        if let url = choose(withTitle: "Choose the Python executable", files: true) { _ = selectPython(url) }
    }

    private func selectPython(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
            inputError = "Choose a Python executable, such as venv/bin/python3."
            return false
        }
        pythonPath = url.path
        inputError = nil
        return true
    }

    private func choose(withTitle title: String, files: Bool = false, directories: Bool = false,
                        types: [UTType] = []) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseFiles = files
        panel.canChooseDirectories = directories
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct PickerCard: View {
    let title: String
    let hint: String
    let icon: String
    let selection: URL?
    let choose: () -> Void
    let accept: (URL) -> Bool
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            WiiIconBadge(systemName: selection == nil ? icon : "checkmark", size: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppFont.wii(15)).foregroundStyle(Wii.textStrong)
                Text(selection?.lastPathComponent ?? hint)
                    .font(.callout)
                    .foregroundStyle(Wii.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(selection?.path ?? hint)
            }
            Spacer(minLength: 0)
            Button(selection == nil ? "Choose…" : "Change…", action: choose)
                .buttonStyle(WiiButtonStyle(compact: true))
                .accessibilityLabel(selection == nil ? "Choose " + title : "Change " + title)
        }
        .padding(12)
        .frame(minHeight: 66)
        .wiiChannel(selected: targeted, radius: 16)
        .dropDestination(for: URL.self) { items, _ in
            guard items.count == 1, let url = items.first, url.isFileURL else { return false }
            return accept(url)
        } isTargeted: { targeted = $0 }
    }
}
