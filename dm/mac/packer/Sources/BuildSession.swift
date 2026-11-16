import Foundation
import SwiftUI

enum BuildTarget: String, CaseIterable, Identifiable {
    case ios
    case mac = "mac-app"

    var id: String { rawValue }
    var title: String { self == .mac ? "Mac" : "iPhone & iPad" }
    var fileExtension: String { self == .mac ? "app" : "ipa" }
    var icon: String { self == .mac ? "desktopcomputer" : "iphone" }
}

struct BuildRequest {
    let checkout: URL
    let python: URL
    let game: URL
    let keys: URL?
    let target: BuildTarget
    let output: URL?

    static let script = "scripts/build_ipa_from_nsp.py"

    var arguments: [String] {
        var arguments = [
            "-u", checkout.appending(path: Self.script).path,
            game.path, "--platform", target.rawValue, "--progress", "json",
        ]
        if let keys { arguments += ["--keys", keys.path] }
        if let output { arguments += ["--out", output.path] }
        return arguments
    }
}

enum BuildTools {
    static func checkout(containing url: URL) -> URL? {
        var directory = url.standardizedFileURL
        while true {
            if FileManager.default.isReadableFile(atPath: directory.appending(path: BuildRequest.script).path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    static var defaultPython: URL? {
        let search = ["/opt/homebrew/bin", "/usr/local/bin"] + path.split(separator: ":").map(String.init)
        return search.filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0).appending(path: "python3") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var path: String {
        ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }
}

@MainActor
final class BuildSession: ObservableObject {
    enum Phase: Equatable {
        case idle, building, stopping, completed(URL), failed(String), cancelled
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var gameName: String?
    @Published private(set) var stage = ""
    @Published private(set) var step = ""
    @Published private(set) var stageCount = ""
    @Published private(set) var fraction: Double?
    @Published private(set) var diagnostics = [String]()
    @Published private(set) var hasNotes = false

    var active: Bool { phase == .building || phase == .stopping }
    var onFinish: (() -> Void)?

    private var process: Process?
    private var output: URL?
    private var lastError: String?

    func start(_ request: BuildRequest) {
        guard process == nil else { return }
        output = nil
        lastError = nil
        gameName = nil
        stage = "Starting packer"
        step = ""
        stageCount = ""
        fraction = nil
        diagnostics = []
        hasNotes = false

        let child = Process()
        let pipe = Pipe()
        child.executableURL = request.python
        child.arguments = request.arguments
        child.currentDirectoryURL = request.checkout
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = request.python.deletingLastPathComponent().path + ":" + BuildTools.path
        child.environment = environment
        child.standardOutput = pipe
        child.standardError = pipe
        child.standardInput = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        process = child
        phase = .building
        try? pipe.fileHandleForWriting.close()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            // Read what is ready now. Progress must appear even when the next line is minutes away.
            var chunk = handle.availableData
            while !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    DispatchQueue.main.async { [weak self] in self?.consume(line) }
                }
                chunk = handle.availableData
            }
            if !buffer.isEmpty {
                let line = buffer
                DispatchQueue.main.async { [weak self] in self?.consume(line) }
            }
            try? handle.close()
            child.waitUntilExit()
            let status = child.terminationStatus
            let exitedNormally = child.terminationReason == .exit
            DispatchQueue.main.async { [weak self] in self?.finish(status, exitedNormally: exitedNormally) }
        }
    }

    func cancel() {
        guard phase == .building, let process, process.isRunning else { return }
        phase = .stopping
        process.terminate()
    }

    private func consume(_ line: Data) {
        guard let event = try? JSONDecoder().decode(BuildEvent.self, from: line) else {
            let text = String(decoding: line, as: UTF8.self)
            if !text.isEmpty { appendDiagnostic(text) }
            return
        }
        switch event.ev {
        case "game":
            gameName = event.name
            if let path = event.out, path.hasPrefix("/") { output = URL(fileURLWithPath: path) }
        case "stage":
            stage = event.name ?? "Building"
            step = event.step ?? ""
            if let k = event.k, let n = event.n { stageCount = "Stage \(k) of \(n)" }
            fraction = nil
        case "step":
            step = event.step ?? ""
            fraction = nil
        case "progress":
            fraction = event.frac.map { min(max($0, 0), 1) }
        case "stage_end":
            if event.ok == true { fraction = 1 }
            if event.warn == true { hasNotes = true }
            if let summary = event.summary, !summary.isEmpty {
                appendDiagnostic("\(event.name ?? stage): \(summary)")
            }
        case "say":
            guard let message = event.msg else { return }
            if message.hasPrefix("[RED] ") {
                lastError = String(message.dropFirst(6))
                hasNotes = true
            }
            appendDiagnostic(message)
        default:
            break
        }
    }

    private func appendDiagnostic(_ text: String) {
        diagnostics.append(text)
        if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) }
    }

    private func finish(_ status: Int32, exitedNormally: Bool) {
        process = nil
        if exitedNormally && status == 0 {
            if let output, FileManager.default.fileExists(atPath: output.path) {
                phase = .completed(output)
            } else {
                phase = .failed("The packer exited without a built game. Open Build Log for details.")
            }
        } else if phase == .stopping {
            phase = .cancelled
        } else {
            phase = .failed(lastError ?? "The packer stopped (code \(status)). Open Build Log for details.")
        }
        onFinish?()
        onFinish = nil
    }
}

private struct BuildEvent: Decodable {
    let ev: String
    let k: Int?
    let n: Int?
    let name: String?
    let step: String?
    let frac: Double?
    let summary: String?
    let ok: Bool?
    let warn: Bool?
    let out: String?
    let msg: String?
}
