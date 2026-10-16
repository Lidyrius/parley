import AVFoundation
import SwiftUI
import VisionKit

/// Full-screen QR scanner. VisionKit's DataScanner where supported, else a plain
/// AVFoundation metadata scanner. `onCode` returns an error message, or nil once paired.
struct ScannerSheet: View {
    let onCode: (String) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var access: Access = .checking
    @State private var error: String?
    @State private var lastCode: String?

    enum Access { case checking, dataScanner, camera, denied, unavailable }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch access {
            case .checking:
                ProgressView().tint(.white)
            case .dataScanner:
                DataScanner(onCode: handle).ignoresSafeArea()
            case .camera:
                CameraScanner(onCode: handle).ignoresSafeArea()
            case .denied:
                message("Kein Kamerazugriff", "Erlaube Parley die Kamera in den Einstellungen – oder füge den Link stattdessen ein.") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Einstellungen öffnen", destination: url).buttonStyle(.borderedProminent)
                    }
                }
            case .unavailable:
                message("Kamera nicht verfügbar", "Füge stattdessen den Link aus Parley auf dem Mac ein.") { EmptyView() }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .tint(.white)
            .accessibilityLabel("Schließen")
            .padding(16)
        }
        .overlay(alignment: .bottom) {
            if access == .dataScanner || access == .camera {
                VStack(spacing: 10) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.red.opacity(0.85), in: Capsule())
                    }
                    Text("Richte die Kamera auf den QR-Code in Parley auf dem Mac.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .foregroundStyle(.white)
                .padding(24)
            }
        }
        .task { access = await Self.checkAccess() }
    }

    private func handle(_ code: String) {
        guard code != lastCode else { return }  // the scanner reports the same code repeatedly
        lastCode = code
        if let message = onCode(code) { error = message } else { dismiss() }
    }

    private func message<A: View>(_ title: String, _ text: String, @ViewBuilder actions: () -> A) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "camera")
        } description: {
            Text(text)
        } actions: {
            actions()
        }
        .environment(\.colorScheme, .dark)
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
