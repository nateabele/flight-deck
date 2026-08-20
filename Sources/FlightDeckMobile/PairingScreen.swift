import AVFoundation
import FleetKit
import SwiftUI
import UIKit

struct PairingScreen: View {
    let model: FleetModel

    @State private var typed = ""
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("Pair with your Mac")
                .font(.title2.weight(.semibold))
            Text("Open Flight Deck on your Mac, then Settings → Devices → Pair a Device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            QRScannerView { adopt($0) }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            DisclosureGroup("Can't scan? Type the code instead") {
                TextField("flightdeck1:…", text: $typed, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
                Button("Pair") { adopt(typed) }
                    .disabled(typed.isEmpty)
            }

            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    private func adopt(_ code: String) {
        do {
            try model.adopt(code: code)
            failure = nil
        } catch let error as PairingPayloadError {
            failure = Self.message(for: error)
        } catch {
            failure = "That code could not be used."
        }
    }

    /// Each failure says what to do next. "Invalid code" for all three would leave a user
    /// rescanning a code that will never work.
    static func message(for error: PairingPayloadError) -> String {
        switch error {
        case .notAPairingCode:
            return "That isn't a Flight Deck pairing code."
        case .unsupportedVersion:
            return "This code is from a newer version of Flight Deck. Update the app on your phone."
        case .malformed:
            return "That code is damaged. Show a new one on your Mac."
        }
    }
}

/// A `UIViewRepresentable` over `AVCaptureSession`, restricted to QR codes and calling
/// `onCode` once per distinct string seen — a fixed video feed of the same code must not
/// re-fire on every frame.
///
/// Not a separate file: the plan's file list for this task names only `PairingScreen.swift`
/// for the pairing screen, and this view has no reason to be reached from anywhere else.
struct QRScannerView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeUIView(context: Context) -> QRScannerContainerView {
        QRScannerContainerView(onCode: onCode)
    }

    func updateUIView(_ uiView: QRScannerContainerView, context: Context) {}
}

/// Owns the capture session and swaps between the live preview and the denied-access
/// message, so `QRScannerView` itself stays a thin representable.
///
/// A simulator has no camera, so this is the one piece of the phone app that is
/// structurally unverifiable without hardware — see the task's own verification-gap note.
final class QRScannerContainerView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private var lastCode: String?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    private let deniedLabel: UILabel = {
        let label = UILabel()
        label.text = "Flight Deck needs the camera to scan the code on your Mac. "
            + "You can enter the code by hand instead."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(frame: .zero)
        backgroundColor = .black
        addSubview(deniedLabel)
        NSLayoutConstraint.activate([
            deniedLabel.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            deniedLabel.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            deniedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        requestAccess()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this view is only ever built by SwiftUI")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    private func requestAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.showDenied()
                    }
                }
            }
        case .denied, .restricted:
            showDenied()
        @unknown default:
            showDenied()
        }
    }

    private func showDenied() {
        deniedLabel.isHidden = false
    }

    private func configureSession() {
        guard
            let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            showDenied()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showDenied()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        layer.insertSublayer(previewLayer, at: 0)
        self.previewLayer = previewLayer

        session.startRunning()
    }

    // `nonisolated` + `MainActor.assumeIsolated`, the same idiom `FleetModel` uses for
    // `FleetConnector`'s callbacks: `AVCaptureMetadataOutputObjectsDelegate` is a plain
    // nonisolated protocol requirement, but `setMetadataObjectsDelegate(self, queue: .main)`
    // below guarantees this fires on the main queue, so `assumeIsolated` states a fact the
    // compiler cannot see rather than hiding a real hazard.
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        MainActor.assumeIsolated {
            guard
                let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                object.type == .qr,
                let value = object.stringValue,
                value != lastCode
            else { return }
            lastCode = value
            onCode(value)
        }
    }
}
