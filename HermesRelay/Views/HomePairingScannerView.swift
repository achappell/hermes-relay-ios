#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Scans the Home pairing page's QR code. Only a `hermes-home://pair` link
/// that parses as a pairing invitation is accepted; every other code is
/// ignored. When the camera is denied or missing, the caller falls back to
/// typed entry.
struct HomePairingScannerView: UIViewControllerRepresentable {
    let onLink: @MainActor (URL) -> Void
    let onUnavailable: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> HomePairingScannerViewController {
        let controller = HomePairingScannerViewController()
        controller.onLink = onLink
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(
        _ controller: HomePairingScannerViewController,
        context: Context
    ) {}
}

final class HomePairingScannerViewController: UIViewController,
    AVCaptureMetadataOutputObjectsDelegate {
    var onLink: (@MainActor (URL) -> Void)?
    var onUnavailable: (@MainActor (String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didFinish = false

    static let deniedMessage = "Camera access is off for Hermes. Enter the pairing code instead."
    static let missingMessage = "The camera is unavailable. Enter the pairing code instead."

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.finishUnavailable(HomePairingScannerViewController.deniedMessage)
                    }
                }
            }
        default:
            finishUnavailable(HomePairingScannerViewController.deniedMessage)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            finishUnavailable(HomePairingScannerViewController.missingMessage)
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            finishUnavailable(HomePairingScannerViewController.missingMessage)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        nonisolated(unsafe) let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
    }

    private func stopSession() {
        nonisolated(unsafe) let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let values = metadataObjects.compactMap {
            ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue
        }
        // The delegate queue is `.main`.
        MainActor.assumeIsolated {
            self.handle(values)
        }
    }

    private func handle(_ values: [String]) {
        guard !didFinish else { return }
        for value in values {
            guard (try? HomePairingInvitation(linkText: value)) != nil,
                  let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            didFinish = true
            stopSession()
            onLink?(url)
            return
        }
    }

    private func finishUnavailable(_ message: String) {
        guard !didFinish else { return }
        didFinish = true
        onUnavailable?(message)
    }
}
#endif
