import SwiftUI
import VisionKit

/// Pairing with a Mac, once: the Mac's game shows a QR code and six digits (Controllers > Pair iPhone…); the phone scans the
/// one or types the other. After that it joins every game on that Mac by itself.
struct PairView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var scanning = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(alignment: .top, spacing: 16) {
                steps
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
                    .wiiPanel(radius: 20)
                entry
                    .frame(width: 320)
                    .padding(14)
                    .wiiPanel(radius: 20)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WiiStripes().ignoresSafeArea())
        // The number pad covers the lower half in landscape: the code stays where it is, above it
        .ignoresSafeArea(.keyboard)
        .fullScreenCover(isPresented: $scanning) {
            ScannerScreen { url in
                scanning = false
                model.pair(url: url)
            } onCancel: {
                scanning = false
            }
        }
        .onAppear {
            if model.pairState != .working { codeFocused = true }
        }
        .onChange(of: model.pairState) { _, state in
            if case .failed = state {
                code = ""
                codeFocused = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Close") {
                model.resetPairing()
                dismiss()
            }
            .buttonStyle(WiiButtonStyle(compact: true))
            Spacer(minLength: 8)
            Group {
                if let mac = model.pairingFor {
                    Text("Pair with \(mac)")
                } else {
                    Text("Pair a Mac")
                }
            }
            .font(AppFont.wii(17))
            .foregroundStyle(Wii.textStrong)
            .lineLimit(1)
            Spacer(minLength: 8)
            if DataScannerViewController.isSupported {
                Button {
                    codeFocused = false
                    scanning = true
                } label: {
                    Label("Scan the QR code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(WiiButtonStyle(kind: .primary, compact: true))
                .disabled(model.pairState == .working)
            }
        }
    }

    // MARK: How

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepRow(number: 1, text: "On the Mac, open a game built with nxnative.")
            StepRow(number: 2, text: "In its menu bar: Controllers > Pair iPhone… (⌘⇧P).")
            StepRow(number: 3, text: DataScannerViewController.isSupported ? "Scan its QR code, or type its six numbers."
                                                                          : "Point the Camera app at its QR code, or type its six numbers.")
            Text("Once for each Mac: then NX Pad joins its games by itself.")
                .font(.system(size: 12))
                .foregroundStyle(Wii.muted)
        }
    }

    // MARK: The code

    private var entry: some View {
        VStack(spacing: 10) {
            ZStack {
                // The digits are typed into a field nobody sees; the boxes show them.
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFocused)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { code = digits }
                        if digits.count == 6, model.pairState != .working { model.pair(code: digits) }
                    }
                CodeBoxes(code: code, focused: codeFocused)
                    .contentShape(Rectangle())
                    .onTapGesture { codeFocused = true }
            }
            .frame(height: 58)
            .disabled(model.pairState == .working)
            stateLine
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
    }

    @ViewBuilder
    private var stateLine: some View {
        switch model.pairState {
        case .idle:
            Text("The Mac shows a new code every 10 minutes.")
                .font(.system(size: 12))
                .foregroundStyle(Wii.muted)
        case .working:
            HStack(spacing: 8) {
                ProgressView().tint(Wii.blue)
                Text("Pairing…").font(AppFont.wii(14)).foregroundStyle(Wii.textStrong)
            }
        case let .done(mac, game):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Wii.green).font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paired with \(mac)").font(AppFont.wii(14)).foregroundStyle(Wii.textStrong)
                    if !game.isEmpty {
                        Text("Joining \(game)…").font(.system(size: 12)).foregroundStyle(Wii.muted)
                    }
                }
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Wii.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(AppFont.wii(13))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Wii.primaryFill))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Wii.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Six boxes, three and three, as the Mac shows the code.
private struct CodeBoxes: View {
    let code: String
    let focused: Bool

    var body: some View {
        let digits = Array(code)
        HStack(spacing: 6) {
            ForEach(0..<6, id: \.self) { i in
                if i == 3 { Spacer().frame(width: 8) }
                let filled = i < digits.count
                let current = focused && i == min(digits.count, 5)
                Text(filled ? String(digits[i]) : " ")
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Wii.textStrong)
                    .frame(width: 40, height: 54)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(current ? Wii.blue : Wii.line, lineWidth: current ? 2.5 : 2))
            }
        }
    }
}

/// The camera, reading QR codes until one carries an nxpad://pair link.
private struct ScannerScreen: View {
    let onFound: (URL) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            QRScanner(onFound: onFound)
                .ignoresSafeArea()
            HStack {
                Text("Point at the QR code on the Mac's screen")
                    .font(AppFont.wii(15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WiiButtonStyle(compact: true))
            }
            .padding(20)
        }
        .background(Color.black)
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onFound: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (URL) -> Void
        private var done = false

        init(onFound: @escaping (URL) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                guard !done, case .barcode(let code) = item, let text = code.payloadStringValue,
                      let url = URL(string: text), url.scheme?.lowercased() == "nxpad" else { continue }
                done = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onFound(url)
            }
        }
    }
}
