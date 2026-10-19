import AVFoundation
import SwiftUI
import VisionKit

/// The QR scanner (design B2, docs/design/screens/ios/40-kopplung): the camera in a tile of the
/// icon's shape whose outline runs outwards like the call's ripples while it searches. VisionKit's
/// DataScanner where supported, else a plain AVFoundation metadata scanner. Once a code pairs it
/// shows "Verbunden, Sir." for a moment, then the overview takes over.
struct ScannerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var access: Access = .checking
    @State private var error: String?
    @State private var lastCode: String?
    @State private var found = false
    @State private var torch = false

    enum Access { case checking, dataScanner, camera, denied, unavailable, demo }

    private static let tile: CGFloat = 290

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(Theme.card, in: Circle())
                }
                .tint(.primary)
                .accessibilityLabel("Schließen")
            }
            if access == .denied || access == .unavailable {
                cameraOff
            } else {
                scanner
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.background)
        .sensoryFeedback(.success, trigger: found)
        .task {
            if let i = CommandLine.arguments.firstIndex(of: "-demoScanner") {   // screenshots in the simulator
                let mode = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
                access = mode == "denied" ? .denied : .demo
                found = mode == "found"
                return
            }
            access = await Self.checkAccess()
        }
    }

    // MARK: - Searching / found

    private var scanner: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Code scannen").font(.largeTitle.bold())
                Text("Halten Sie das iPhone auf den Code am Mac.").foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            camera
                    .frame(width: Self.tile, height: Self.tile)
                    .clipShape(IconShape())
                    .overlay {
                        if found {
                            Image(systemName: "checkmark")
                                .font(.system(size: 40, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 84, height: 84)
                                .background(Circle().fill(.green))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .overlay(IconShape().stroke(found ? .green : Theme.claude, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                    .background { SilhouetteWaves(size: Self.tile, active: !found && access != .checking) }   // outside the layout
            .frame(maxWidth: .infinity)
            .frame(height: Self.tile + 70)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: found)

            if found {
                VStack(spacing: 4) {
                    Text("Verbunden, Sir.").font(.title2.bold())
                    Text(connectedDetail).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            } else {
                HintCard(symbol: "menubar.rectangle", title: "Kein Code zu sehen?",
                         detail: "Mac: Parley-Menü → „Handy\u{00A0}verbinden…\u{2060}“")
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.top, 10)
                }
            }

            Spacer(minLength: 16)

            if !found {
                HStack(spacing: 12) {
                    Button { paste() } label: {
                        Label("Link einfügen", systemImage: "doc.on.clipboard")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Capsule().fill(Theme.card))
                    }
                    .buttonStyle(.plain)
                    if Self.hasTorch {
                        Button { setTorch(!torch) } label: {
                            Image(systemName: torch ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.headline)
                                .frame(width: 54, height: 54)
                                .background(Circle().fill(torch ? Theme.claude : Theme.card))
                                .foregroundStyle(torch ? Theme.onAccent : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(torch ? "Licht aus" : "Licht an")
                    }
                }
            }
        }
    }

    @ViewBuilder private var camera: some View {
        switch access {
        case .dataScanner: DataScanner(onCode: handle)
        case .camera: CameraScanner(onCode: handle)
        case .checking: Theme.card.overlay(ProgressView())
        case .demo, .denied, .unavailable:
            LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                .overlay(Image(systemName: "qrcode").font(.system(size: 150)).foregroundStyle(.white.opacity(found ? 0.35 : 0.85)))
                .blur(radius: found ? 6 : 0)
        }
    }

    /// The Mac's name and how many sessions came with it — once its first list is here.
    private var connectedDetail: String {
        let sessions = model.relay.snapshot?.sessions ?? []
        let mac = sessions.lazy.compactMap(\.host).first ?? "Ihr Mac"
        return sessions.isEmpty ? mac : "\(mac) · \(sessions.count) \(sessions.count == 1 ? "Session" : "Sessions")"
    }

    // MARK: - No camera

    private var cameraOff: some View {
        VStack(spacing: 18) {
            Spacer()
            IconShape()
                .stroke(Theme.claude.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .frame(width: 180, height: 180)
                .overlay(Image(systemName: "camera.fill").font(.system(size: 40)).foregroundStyle(Theme.claude))
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(access == .denied ? "Kamera ist aus" : "Keine Kamera").font(.title2.bold())
                Text(access == .denied ? "Parley braucht sie nur für diesen einen Code." : "Fügen Sie stattdessen den Link vom Mac ein.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
            }
            Spacer()
            if access == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: url) {
                    Text("Kamera erlauben")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(Theme.onAccent)
                        .background(Capsule().fill(Theme.claude))
                }
            }
            Button { paste() } label: {
                Label(access == .denied ? "Stattdessen Link einfügen" : "Link einfügen", systemImage: "doc.on.clipboard")
                    .font(.headline)
                    .foregroundStyle(Theme.claude)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func handle(_ code: String) {
        guard code != lastCode, !found else { return }  // the scanner reports the same code repeatedly
        lastCode = code
        model.welcoming = true   // keeps this screen up for "Verbunden, Sir."
        do {
            try model.pair(code)
        } catch {
            model.welcoming = false
            self.error = error.localizedDescription
            return
        }
        error = nil
        setTorch(false)
        found = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            model.welcoming = false
        }
    }

    private func paste() {
        error = pasteAndPair(model)
    }

    private static var hasTorch: Bool { AVCaptureDevice.default(for: .video)?.hasTorch ?? false }

    private func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        torch = on
    }

    private static func checkAccess() async -> Access {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }  // e.g. the simulator
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        default: return .denied
        }
        return DataScannerViewController.isSupported && DataScannerViewController.isAvailable ? .dataScanner : .camera
    }
}

/// The scanner tile's outline sent outwards while it searches: the call's ripples (Ringing.swift
/// `.ripples` — same beat, life, easing and fade knobs) in the icon's shape, growing to ~1.6×.
struct SilhouetteWaves: View {
    let size: CGFloat
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let k = Appearance.shared.tuning
        let g = Knobs.general(.ripples)
        let reach = 1 + max(0.1, k[Knobs.Ripples.reach])
        TimelineView(.animation(paused: !active || reduceMotion)) { context in
            Canvas { ctx, canvas in
                guard active, !reduceMotion else { return }
                typealias R = Knobs.Ripples
                let t = context.date.timeIntervalSinceReferenceDate
                let cycle = max(0.1, k[g.cycle]), life = max(0.1, k[R.life])
                let phase = t.truncatingRemainder(dividingBy: cycle)
                let fade = min(1, max(0, k[g.opacity]))
                for back in 0...Int(ceil(life / cycle)) {
                    for launch in [k[g.beat1], k[g.beat2]] {
                        let age = phase - launch + Double(back) * cycle
                        guard age >= 0, age < life else { continue }
                        let p = age / life
                        let s = size * (1 + k[R.reach] * (1 - pow(1 - p, k[R.ease])))
                        let a = fade * pow(1 - p, k[R.fade])
                        let shape = IconShape().path(in: CGRect(x: (canvas.width - s) / 2, y: (canvas.height - s) / 2, width: s, height: s))
                        ctx.fill(shape, with: .color(Theme.claude.opacity(a * k[R.fill] * 0.5)))
                        ctx.stroke(shape, with: .color(Theme.claude.opacity(a * k[R.stroke])), lineWidth: k[R.width] * 0.75)
                    }
                }
            }
        }
        .frame(width: size * reach, height: size * reach)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DataScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in addedItems {
                if let payload = code.payloadStringValue { onCode(payload); return }
            }
        }
    }
}

/// Fallback for devices or states where DataScanner is unavailable.
private struct CameraScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> CameraScannerController {
        let controller = CameraScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: CameraScannerController, context: Context) {
        controller.onCode = onCode
    }
}

final class CameraScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void = { _ in }
    private let session = AVCaptureSession()
    private let preview = AVCaptureVideoPreviewLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setRunning(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setRunning(false)
    }

    private func setRunning(_ on: Bool) {
        nonisolated(unsafe) let session = session
        // start/stopRunning block; keep them off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { on ? session.startRunning() : session.stopRunning() }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = objects.lazy.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        MainActor.assumeIsolated { onCode(code) }  // delegate queue is .main
    }
}
